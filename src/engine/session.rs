//! 会话与独立网络命名空间（原 lib/session.sh + lib/helpers.sh 里的 keeper）
//!
//! 同前缀的程序共用一个 wineserver，也就共用它的显示方式与网络命名空间。
//! 前缀开了独立网络时，由 pasta 建一个命名空间，keeper 进程待在里面把网络
//! 撑住，程序用 nsenter 进去；前缀里最后一个程序退出后 keeper 收摊。

use crate::core::paths::cache_home;
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

pub const KEEPER_FLAG: &str = "--session-keeper";

static STOP: AtomicBool = AtomicBool::new(false);

pub fn runtime_root() -> PathBuf {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    Path::new(&runtime).join("winrun/sessions")
}

/// 每个前缀一个会话目录（前缀路径的哈希）
pub fn session_dir(prefix: &Path) -> PathBuf {
    let mut hasher = Sha256::new();
    hasher.update(prefix.to_string_lossy().as_bytes());
    let digest = format!("{:x}", hasher.finalize());
    runtime_root().join(&digest[..16])
}

pub fn netns_of(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/ns/net"))
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
}

pub fn host_netns() -> Option<String> {
    std::fs::read_link("/proc/self/ns/net")
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
}

fn read_trimmed(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
}

/// 活着的 keeper：pid 文件里的进程确实还在，且还在同一个命名空间里
pub fn keeper_pid(dir: &Path) -> Option<u32> {
    let pid: u32 = read_trimmed(&dir.join("keeper.pid"))?.parse().ok()?;
    let recorded = read_trimmed(&dir.join("netns"))?;
    let current = netns_of(pid)?;
    if current == recorded {
        Some(pid)
    } else {
        None
    }
}

/// 前缀的 wineserver：Wine 用前缀的设备号+inode 命名 server 目录，server 把它当工作目录
pub fn wineserver_pid(prefix: &Path) -> Option<u32> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::metadata(prefix.join("pfx")).ok()?;
    let suffix = format!("server-{:x}-{:x}", meta.dev(), meta.ino());
    let entries = std::fs::read_dir("/proc").ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid) = name.to_str().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        let cwd = match std::fs::read_link(format!("/proc/{pid}/cwd")) {
            Ok(cwd) => cwd.to_string_lossy().into_owned(),
            Err(_) => continue,
        };
        if cwd.starts_with("/tmp/.wine-") && cwd.ends_with(&suffix) {
            return Some(pid);
        }
    }
    None
}

pub fn prefix_netns_enabled(prefix: &Path) -> bool {
    crate::core::prefix::netns_enabled(prefix)
}

/// 写前缀自己的网络开关（`$PREFIX/.winrun.conf`）
pub fn set_prefix_netns(prefix: &Path, enabled: bool) {
    let file = prefix.join(".winrun.conf");
    let existing = std::fs::read_to_string(&file).unwrap_or_default();
    let mut lines: Vec<String> = existing
        .lines()
        .filter(|line| !line.trim().is_empty() && !line.trim_start().starts_with("netns="))
        .map(|line| line.to_string())
        .collect();
    lines.push(format!("netns={}", if enabled { 1 } else { 0 }));
    let _ = std::fs::create_dir_all(prefix);
    let _ = std::fs::write(&file, lines.join("\n") + "\n");
}

/// 启动一次性的会话信息，给 launch 拼命令用
#[derive(Default)]
pub struct Session {
    pub keeper: Option<u32>,
    pub netns: Option<String>,
    /// nsenter 前缀（进命名空间），没有独立网络时为空
    pub join: Vec<String>,
    pub env: Vec<(String, String)>,
    /// Proton 的 verb：新会话用 waitforexitandrun，加入已有会话用 run
    pub verb: String,
    /// 前缀里已经有程序在跑
    pub active: bool,
    pub notes: Vec<String>,
}

pub enum SessionError {
    NetnsBusy,
    NetnsOrphan,
    NoPasta,
    NoNsenter,
    KeeperFailed(String),
}

impl SessionError {
    pub fn message(&self, zh: bool) -> String {
        match (self, zh) {
            (SessionError::NetnsBusy, true) => "这个前置环境里有程序正在普通网络中运行，独立网络要等它们全部关闭后才生效。".into(),
            (SessionError::NetnsBusy, false) => "Programs of this prefix run on the normal network; close them first.".into(),
            (SessionError::NetnsOrphan, true) => "这个前置环境的独立网络会话已经断了，请先在进程页强制关闭它的进程。".into(),
            (SessionError::NetnsOrphan, false) => "This prefix's separate network session is gone; force close its processes first.".into(),
            (SessionError::NoPasta, true) => "这个前置环境开启了独立网络，但没有安装 passt（pasta）。".into(),
            (SessionError::NoPasta, false) => "This prefix uses a separate network, but passt (pasta) is not installed.".into(),
            (SessionError::NoNsenter, true) => "找不到 nsenter（util-linux）。".into(),
            (SessionError::NoNsenter, false) => "nsenter (util-linux) was not found.".into(),
            (SessionError::KeeperFailed(log), true) => format!("独立网络会话没能启动，见日志：{log}"),
            (SessionError::KeeperFailed(log), false) => format!("The separate network session did not start, see {log}"),
        }
    }
}

/// 决定这次启动怎么进入前缀的会话，需要时先把会话建起来
pub fn prepare(prefix: &Path, zh: bool) -> Result<Session, SessionError> {
    let dir = session_dir(prefix);
    let want_netns = prefix_netns_enabled(prefix);
    let mut keeper = keeper_pid(&dir);
    let wineserver = wineserver_pid(prefix);
    let mut session = Session {
        verb: "waitforexitandrun".into(),
        ..Default::default()
    };

    if let Some(wineserver) = wineserver {
        session.active = true;
        let ws_netns = netns_of(wineserver);
        let host = host_netns();
        if ws_netns.is_some() && ws_netns == host {
            if want_netns {
                return Err(SessionError::NetnsBusy);
            }
            keeper = None;
        } else if keeper.is_none() || netns_of(keeper.unwrap()) != ws_netns {
            return Err(SessionError::NetnsOrphan);
        }
        session.verb = "run".into();
    } else if keeper.is_none() && want_netns {
        keeper = Some(start_keeper(&dir, prefix)?);
    }

    if let Some(keeper) = keeper {
        session.keeper = Some(keeper);
        session.netns = netns_of(keeper);
        session.join = vec![
            "nsenter".into(),
            "-t".into(),
            keeper.to_string(),
            "-U".into(),
            "-n".into(),
            "--preserve-credentials".into(),
            "--".into(),
        ];
        // 加速器的 wintun.dll 会往 Windows 里装驱动；WE-Proton 自带的那个在命名空间里建 TUN
        session.env.push(("WINEDLLOVERRIDES".into(), "wintun=b".into()));
        // pasta 把用户映射成 root，会话总线不认，keeper 过的桥才认得
        if dir.join("bus").exists() {
            session
                .env
                .push(("DBUS_SESSION_BUS_ADDRESS".into(), format!("unix:path={}", dir.join("bus").display())));
        }
        if session.active {
            session.notes.push(if zh {
                "这个前置环境正在用独立网络运行，本次直接加入。".to_string()
            } else {
                "Joining the prefix's running separate network.".to_string()
            });
        }
    }
    Ok(session)
}

fn which(name: &str) -> bool {
    crate::core::paths::which(name).is_some()
}

fn start_keeper(dir: &Path, prefix: &Path) -> Result<u32, SessionError> {
    if !which("pasta") {
        return Err(SessionError::NoPasta);
    }
    if !which("nsenter") {
        return Err(SessionError::NoNsenter);
    }
    let _ = std::fs::create_dir_all(dir);
    for name in ["keeper.pid", "netns", "userns", "bus", "launch", "launch.pid"] {
        let _ = std::fs::remove_file(dir.join(name));
    }

    let log_path = cache_home()
        .join("winrun/logs")
        .join(format!("session-{}.log", dir.file_name().and_then(|n| n.to_str()).unwrap_or("x")));
    let _ = std::fs::create_dir_all(log_path.parent().unwrap_or(Path::new("/tmp")));
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .ok();

    let mac = namespace_mac_address();
    let self_exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("winrun-manager"));
    let no_pidns = Command::new("pasta")
        .arg("--help")
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).contains("--no-pidns"))
        .unwrap_or(false);

    let mut command = Command::new("pasta");
    command
        .arg("--config-net")
        .arg("--ns-mac-addr")
        .arg(&mac)
        .arg("-T")
        .arg("auto")
        .arg("-f");
    if no_pidns {
        command.arg("--no-pidns");
    }
    command
        .arg("--")
        .arg(&self_exe)
        .arg(KEEPER_FLAG)
        .arg(dir)
        .env("WINRUN_PREFIX", prefix)
        .env_remove("WINRUN_APP_ID")
        .env_remove("WINRUN_APP_PATH")
        .env_remove("WINRUN_LOG")
        .env_remove("LD_PRELOAD")
        .stdin(Stdio::null());

    match &log {
        Some(file) => {
            match file.try_clone() {
                Ok(handle) => command.stdout(Stdio::from(handle)),
                Err(_) => command.stdout(Stdio::null()),
            };
            match file.try_clone() {
                Ok(handle) => command.stderr(Stdio::from(handle)),
                Err(_) => command.stderr(Stdio::null()),
            };
        }
        None => {
            command.stdout(Stdio::null()).stderr(Stdio::null());
        }
    }
    use std::os::unix::process::CommandExt;
    command.process_group(0);
    if let Err(err) = command.spawn() {
        return Err(SessionError::KeeperFailed(format!("{}: {err}", log_path.display())));
    }

    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if let Some(pid) = keeper_pid(dir) {
            return Ok(pid);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(SessionError::KeeperFailed(log_path.display().to_string()))
}

/// 命名空间里用的 MAC：优先用宿主默认路由那块网卡，保证加速器里外看到同一块网卡
fn namespace_mac_address() -> String {
    if let Some(iface) = default_route_interface() {
        if let Ok(mac) = std::fs::read_to_string(format!("/sys/class/net/{iface}/address")) {
            let mac = mac.trim().to_string();
            if mac.len() == 17 && mac != "00:00:00:00:00:00" {
                return mac;
            }
        }
    }
    let machine_id = std::fs::read_to_string("/etc/machine-id").unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(format!("wegame-launcher netns {machine_id}").as_bytes());
    let digest = format!("{:x}", hasher.finalize());
    let first = (u8::from_str_radix(&digest[0..2], 16).unwrap_or(0) & 0xfc) | 0x02;
    format!(
        "{first:02x}:{}:{}:{}:{}:{}",
        &digest[2..4],
        &digest[4..6],
        &digest[6..8],
        &digest[8..10],
        &digest[10..12]
    )
}

fn default_route_interface() -> Option<String> {
    let text = std::fs::read_to_string("/proc/net/route").ok()?;
    let mut best: Option<(u32, String)> = None;
    for line in text.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 8 || fields[1] != "00000000" {
            continue;
        }
        let flags = u32::from_str_radix(fields[3], 16).unwrap_or(0);
        if flags & 1 == 0 {
            continue;
        }
        let metric: u32 = fields[6].parse().unwrap_or(0);
        if best.as_ref().is_none_or(|(best_metric, _)| metric < *best_metric) {
            best = Some((metric, fields[0].to_string()));
        }
    }
    best.map(|(_, iface)| iface)
}

// ── keeper：由 pasta 在命名空间里拉起 ─────────────────────────────
extern "C" fn on_signal(_signal: i32) {
    STOP.store(true, Ordering::SeqCst);
}

fn install_signal_handlers() {
    use nix::sys::signal::{signal, SigHandler, Signal};
    unsafe {
        for sig in [Signal::SIGTERM, Signal::SIGINT, Signal::SIGHUP] {
            let _ = signal(sig, SigHandler::Handler(on_signal));
        }
    }
}

fn processes_in_namespace(netns: &str) -> usize {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return 0;
    };
    let me = std::process::id();
    let mut count = 0;
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        if pid == me {
            continue;
        }
        if netns_of(pid).as_deref() == Some(netns) {
            count += 1;
        }
    }
    count
}

fn cleanup(dir: &Path) {
    if let Some(recorded) = read_trimmed(&dir.join("keeper.pid")) {
        if !recorded.is_empty() && recorded != std::process::id().to_string() {
            return;
        }
    }
    for name in ["keeper.pid", "netns", "userns", "bus", "launch", "launch.pid"] {
        let _ = std::fs::remove_file(dir.join(name));
    }
}

/// 给每个 DNS 服务器钉一条走当前网卡的宿主路由：加速器 TUN 模式会把所有
/// 求情都塞进它的网卡，几百次之后节点不再应答，游戏的域名就解析不出来了。
fn pin_nameserver_routes() {
    let Ok(text) = std::fs::read_to_string("/etc/resolv.conf") else {
        return;
    };
    for line in text.lines() {
        let mut fields = line.split_whitespace();
        if fields.next() != Some("nameserver") {
            continue;
        }
        let Some(server) = fields.next() else { continue };
        let server = server.split('%').next().unwrap_or(server);
        if server.starts_with("127.") || server == "::1" || server.starts_with("fe80") {
            continue;
        }
        let family = if server.contains(':') { "-6" } else { "-4" };
        let route = Command::new("ip").args([family, "route", "get", server]).output();
        let Ok(route) = route else { continue };
        let text = String::from_utf8_lossy(&route.stdout);
        let tokens: Vec<&str> = text.split_whitespace().collect();
        let Some(dev_pos) = tokens.iter().position(|token| *token == "dev") else {
            continue;
        };
        let Some(dev) = tokens.get(dev_pos + 1) else { continue };
        if *dev == "lo" {
            continue;
        }
        let mut command = Command::new("ip");
        command.args([family, "route", "replace", &format!("{server}/{}", if family == "-6" { 128 } else { 32 })]);
        if let Some(gateway_pos) = tokens.iter().position(|token| *token == "via") {
            if let Some(gateway) = tokens.get(gateway_pos + 1) {
                command.arg("via").arg(gateway);
            }
        }
        command.arg("dev").arg(dev);
        let _ = command.output();
    }
}

fn hold_session_lock(dir: &Path) -> Option<std::fs::File> {
    let path = dir.join("lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(path)
        .ok()?;
    use std::os::unix::io::AsRawFd;
    let result = unsafe { nix::libc::flock(file.as_raw_fd(), nix::libc::LOCK_EX | nix::libc::LOCK_NB) };
    if result == 0 { Some(file) } else { None }
}

fn unlock(file: std::fs::File) {
    use std::os::unix::io::AsRawFd;
    unsafe {
        nix::libc::flock(file.as_raw_fd(), nix::libc::LOCK_UN);
    }
}

/// keeper 主体：写会话标记，然后等这个命名空间里没人了再收摊
pub fn keeper_main(dir: &Path) -> ! {
    install_signal_handlers();
    let prefix = PathBuf::from(std::env::var("WINRUN_PREFIX").unwrap_or_default());
    let Ok(netns) = std::fs::read_link("/proc/self/ns/net") else {
        std::process::exit(1);
    };
    let netns = netns.to_string_lossy().into_owned();
    let userns = std::fs::read_link("/proc/self/ns/user")
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_default();

    let _ = std::fs::create_dir_all(dir);
    pin_nameserver_routes();
    let _ = std::fs::write(dir.join("netns"), &netns);
    let _ = std::fs::write(dir.join("userns"), &userns);
    let tmp = dir.join("keeper.pid.tmp");
    if std::fs::write(&tmp, std::process::id().to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, dir.join("keeper.pid"));
    }
    println!("session up: {} ({})", netns, prefix.display());

    let started = Instant::now();
    let mut seen = false;
    loop {
        if STOP.load(Ordering::SeqCst) {
            cleanup(dir);
            std::process::exit(0);
        }
        std::thread::sleep(Duration::from_secs(1));
        if processes_in_namespace(&netns) > 0 {
            seen = true;
            continue;
        }
        // 刚建好的会话给启动方一分钟时间进来
        if !seen && started.elapsed() < Duration::from_secs(60) {
            continue;
        }
        let Some(lock) = hold_session_lock(dir) else {
            continue;
        };
        if processes_in_namespace(&netns) > 0 {
            unlock(lock);
            seen = true;
            continue;
        }
        unlock(lock);
        cleanup(dir);
        let _ = std::io::stdout().flush();
        println!("session empty, closing");
        std::process::exit(0);
    }
}
