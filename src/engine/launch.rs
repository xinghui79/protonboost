//! 拼环境变量与命令行：把运行器、运行时、独立网络、覆盖层辅助库
//! 组装成一次真正的启动，并跟踪进程写运行日志

use crate::engine::logs;
use crate::engine::runners::{self, Runner};
use crate::engine::runtime;
use crate::engine::session;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// 一次启动需要的全部信息
pub struct Request {
    pub prefix: PathBuf,
    pub target: PathBuf,
    /// 目标自己的参数（已拆分好）
    pub args: Vec<String>,
    pub runner: Option<Runner>,
    pub gamescope: bool,
    pub gamescope_fullscreen: bool,
    pub gamescope_res: String,
    pub gamescope_fps: String,
    pub gamescope_fsr: bool,
    pub gamescope_extra: String,
    pub mangohud: bool,
    pub wayland: bool,
    /// 程序自己的环境变量（配置里的 env_vars，已解码）
    pub env: Vec<(String, String)>,
    pub steam_appid: String,
}

impl Default for Request {
    fn default() -> Self {
        Self {
            prefix: PathBuf::new(),
            target: PathBuf::new(),
            args: Vec::new(),
            runner: None,
            gamescope: false,
            gamescope_fullscreen: true,
            gamescope_res: String::new(),
            gamescope_fps: String::new(),
            gamescope_fsr: false,
            gamescope_extra: String::new(),
            mangohud: false,
            wayland: false,
            env: Vec::new(),
            steam_appid: String::new(),
        }
    }
}

pub struct Report {
    pub notes: Vec<String>,
}

/// 拆分 shell 风格的参数串（引号与反斜杠）
pub fn split_args(text: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut has_token = false;
    let mut chars = text.chars().peekable();
    while let Some(char) = chars.next() {
        match char {
            ' ' | '\t' | '\n' => {
                if has_token {
                    parts.push(std::mem::take(&mut current));
                    has_token = false;
                }
            }
            '\'' | '"' => {
                has_token = true;
                let quote = char;
                for inner in chars.by_ref() {
                    if inner == quote {
                        break;
                    }
                    current.push(inner);
                }
            }
            '\\' => {
                has_token = true;
                if let Some(next) = chars.next() {
                    current.push(next);
                }
            }
            _ => {
                has_token = true;
                current.push(char);
            }
        }
    }
    if has_token {
        parts.push(current);
    }
    parts
}

/// 配置里的 env_vars：URL 编码 + shell 风格拆分
pub fn parse_env_vars(encoded: &str) -> Vec<(String, String)> {
    let decoded = percent_decode(encoded);
    split_args(&decoded)
        .into_iter()
        .filter_map(|item| {
            let (key, value) = item.split_once('=')?;
            if key.is_empty() {
                return None;
            }
            Some((key.to_string(), value.to_string()))
        })
        .collect()
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).unwrap_or("");
            if let Ok(value) = u8::from_str_radix(hex, 16) {
                out.push(value);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn steam_client_path() -> PathBuf {
    runners::steam_root_dir()
}

fn gamescope_args(request: &Request) -> Vec<String> {
    let mut args = Vec::new();
    if request.gamescope_fullscreen {
        args.push("-f".into());
    }
    if let Some((width, height)) = request.gamescope_res.split_once('x') {
        args.push("-w".into());
        args.push(width.into());
        args.push("-h".into());
        args.push(height.into());
    }
    if !request.gamescope_fps.trim().is_empty() {
        args.push("-r".into());
        args.push(request.gamescope_fps.trim().into());
    }
    if request.gamescope_fsr {
        args.push("-F".into());
        args.push("fsr".into());
    }
    args.extend(split_args(&request.gamescope_extra));
    args
}

/// 拼出完整的 argv（含 env / nsenter / runtime / 运行器）
fn build_command(request: &Request, runner: &Runner, session: &session::Session) -> (Vec<String>, Vec<(String, String)>) {
    let mut argv: Vec<String> = Vec::new();
    let mut env: Vec<(String, String)> = Vec::new();

    if request.mangohud {
        env.push(("MANGOHUD".into(), "1".into()));
    }
    for (key, value) in &request.env {
        env.push((key.clone(), value.clone()));
    }
    // 程序自己的环境变量优先于会话默认值
    let has_env = |env: &Vec<(String, String)>, key: &str| env.iter().any(|(name, _)| name == key);

    let app_id = logs::app_id(&request.prefix, &request.target);
    env.push(("PROTONBOOST_APP_ID".into(), app_id.clone()));
    env.push(("PROTONBOOST_APP_PATH".into(), request.target.to_string_lossy().into_owned()));
    env.push(("PROTONBOOST_PREFIX".into(), request.prefix.to_string_lossy().into_owned()));
    env.push(("PROTONBOOST_LOG".into(), logs::latest_log(&app_id).to_string_lossy().into_owned()));

    // Wine 的新 WoW64 用 64 位宿主库跑 32 位程序，WE-Proton 的 wintun 加速引擎要的就是它
    if runner.kind == "proton" && !has_env(&env, "PROTON_USE_WOW64") {
        env.push(("PROTON_USE_WOW64".into(), "1".into()));
    }
    if request.wayland && !request.gamescope {
        if runner.kind == "proton" {
            env.push(("PROTON_ENABLE_WAYLAND".into(), "1".into()));
        } else {
            env.push(("WINE_GRAPHICS_DRIVER".into(), "wayland".into()));
        }
    }
    for (key, value) in &session.env {
        if !has_env(&env, key) {
            env.push((key.clone(), value.clone()));
        }
    }

    // Steam 覆盖层在独立网络里找不到宿主上的 Steam 客户端：它按 getuid() 拼
    // 共享内存的名字，而命名空间里 Wine 是 root、宿主客户端是普通用户。
    // 这里预加载一个小库，只让覆盖层看到真实 uid。
    for (key, value) in crate::engine::overlay::prepare_env(
        session.netns.is_some(),
        std::env::var("LD_PRELOAD").ok().as_deref(),
        session::outside_uid(),
    ) {
        if !has_env(&env, &key) {
            env.push((key, value));
        }
    }

    if request.gamescope {
        argv.push("gamescope".into());
        argv.extend(gamescope_args(request));
        argv.push("--".into());
    }
    // gamescope 留在宿主命名空间，程序自己进会话
    argv.extend(session.join.iter().cloned());

    if runner.kind == "proton" {
        let verb = if session.verb.is_empty() { "waitforexitandrun" } else { session.verb.as_str() };
        let mut compat: Vec<(String, String)> = vec![
            ("STEAM_COMPAT_DATA_PATH".into(), request.prefix.to_string_lossy().into_owned()),
            ("STEAM_COMPAT_CLIENT_INSTALL_PATH".into(), steam_client_path().to_string_lossy().into_owned()),
            (
                "SteamAppId".into(),
                if request.steam_appid.is_empty() { "0".into() } else { request.steam_appid.clone() },
            ),
            ("SteamGameId".into(), request.steam_appid.clone()),
        ];
        if request.steam_appid.is_empty() {
            compat.push(("UMU_ID".into(), "protonboost".into()));
            compat.push(("UMU_USE_STEAM".into(), "0".into()));
        }
        env.extend(compat);
        argv.extend(runtime::entry_prefix(Path::new(&runner.path), verb));
        argv.push(runner.path.clone());
        // Proton 自己也要一个动词：`proton waitforexitandrun <exe>`。
        // --verb= 是给 pressure-vessel 的，不能顶替它，缺了 Proton 会报 "Need a verb."
        argv.push(verb.to_string());
        // 快捷方式要换成它指向的 exe，Proton 不认 .lnk
        let (target, shortcut_args) = match crate::core::scan::resolve_shortcut(
            &request.prefix,
            &request.target,
        ) {
            Some((exe, args)) if exe.exists() => (exe, args),
            _ => (request.target.clone(), Vec::new()),
        };
        argv.push(target.to_string_lossy().into_owned());
        argv.extend(shortcut_args);
        argv.extend(request.args.iter().cloned());
    } else {
        let pfx = request.prefix.join("pfx");
        env.push(("WINEPREFIX".into(), pfx.to_string_lossy().into_owned()));
        argv.push(runner.path.clone());
        argv.push(request.target.to_string_lossy().into_owned());
        argv.extend(request.args.iter().cloned());
    }
    (argv, env)
}

/// 前缀还没建过：跑一次 wineboot，之后默认进独立网络
pub fn init_prefix(prefix: &Path, runner: &Runner) -> Result<(), String> {
    let log_path = crate::core::paths::cache_home().join("protonboost/logs/init.log");
    let _ = std::fs::create_dir_all(log_path.parent().unwrap_or(Path::new("/tmp")));
    let mut log = std::fs::File::create(&log_path).map_err(|err| err.to_string())?;

    let request = Request {
        prefix: prefix.to_path_buf(),
        target: PathBuf::from("wineboot"),
        args: vec!["-u".into()],
        runner: Some(runner.clone()),
        ..Default::default()
    };
    // 初始化时不进会话、不开 gamescope
    let plain = session::Session { verb: "waitforexitandrun".into(), ..Default::default() };
    let (argv, env) = build_command(&request, runner, &plain);
    writeln!(log, "初始化前置环境：{}", prefix.display()).ok();

    let mut command = Command::new(&argv[0]);
    command.args(&argv[1..]);
    for (key, value) in &env {
        command.env(key, value);
    }
    command.stdout(Stdio::from(log.try_clone().map_err(|err| err.to_string())?));
    command.stderr(Stdio::from(log));
    let status = command.status().map_err(|err| err.to_string())?;
    if !status.success() {
        return Err(format!(
            "前置环境初始化失败（退出码 {}），日志：{}",
            status.code().unwrap_or(-1),
            log_path.display()
        ));
    }
    session::set_prefix_netns(prefix, true);
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline && session::wineserver_pid(prefix).is_some() {
        std::thread::sleep(Duration::from_millis(200));
    }
    Ok(())
}

pub fn ensure_prefix(prefix: &Path, runner: &Runner) -> Result<(), String> {
    // 前缀外壳目录必须先存在：Proton 的 setup_prefix 会在里面创建
    // pfx.lock 等文件，父目录缺失时 filelock 直接 ENOENT
    std::fs::create_dir_all(prefix).map_err(|err| err.to_string())?;
    if prefix.join("pfx").is_dir() {
        Ok(())
    } else {
        init_prefix(prefix, runner)
    }
}

/// 启动一个 Windows 程序
pub fn launch(request: &Request, zh: bool) -> Result<Report, String> {
    if request.target.as_os_str().is_empty() {
        return Err(if zh { "没有要运行的程序".into() } else { "Nothing to run".to_string() });
    }
    let runner = request
        .runner
        .clone()
        .or_else(|| runners::for_prefix(&request.prefix))
        .ok_or_else(|| {
            if zh { "没有找到可用的运行器（Proton / Wine）".to_string() } else { "No Proton / Wine runner found".to_string() }
        })?;

    ensure_prefix(&request.prefix, &runner)?;
    let session = session::prepare(&request.prefix, zh).map_err(|err| err.message(zh))?;

    let app_id = logs::app_id(&request.prefix, &request.target);
    let mut log = logs::start_run(&app_id).map_err(|err| err.to_string())?;
    let (argv, env) = build_command(request, &runner, &session);

    writeln!(log, "Log: {}", logs::latest_log(&app_id).display()).ok();
    writeln!(log, "App ID: {app_id}").ok();
    writeln!(log, "Target: {}", request.target.display()).ok();
    writeln!(log, "Prefix: {}", request.prefix.display()).ok();
    writeln!(log, "Runner: {} ({})", runner.path, runner.kind).ok();
    writeln!(log, "Command: {}", argv.join(" ")).ok();
    writeln!(log, "--- output ---").ok();

    let mut command = Command::new(&argv[0]);
    command.args(&argv[1..]);
    for (key, value) in &env {
        command.env(key, value);
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone().map_err(|err| err.to_string())?))
        .stderr(Stdio::from(log));
    use std::os::unix::process::CommandExt;
    command.process_group(0);
    let mut child = command.spawn().map_err(|err| err.to_string())?;

    // 等 wineserver 起来，再确认程序确实进了会话
    let deadline = Instant::now() + Duration::from_secs(120);
    while Instant::now() < deadline {
        if session::wineserver_pid(&request.prefix).is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    // 不等游戏退出，但也不能把子进程变僵尸（GUI 常驻，没人替我们收尸）：
    // 交给独立线程 wait
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(Report { notes: session.notes })
}

/// 在前缀的会话里跑一条 Linux 命令（Linux 程序页用）：
/// 前缀开了独立网络时进同一个命名空间，否则就在宿主网络里跑。
pub fn run_command(prefix: &Path, argv: &[String]) -> Result<(), String> {
    if argv.is_empty() {
        return Err("没有要运行的程序".into());
    }
    let zh = crate::core::loc::zh();
    let session = session::prepare(prefix, zh).map_err(|err| err.message(zh))?;
    let app_id = logs::app_id(prefix, Path::new(&argv[0]));
    let log = logs::start_run(&app_id).map_err(|err| err.to_string())?;

    // Linux 程序用「以普通用户身份进入会话」的前缀：
    // pasta 把用户映射成 root，Steam 这类程序会拒绝以 root 运行。
    let join = if session.join_as_user.is_empty() {
        &session.join
    } else {
        &session.join_as_user
    };

    let mut command = if join.is_empty() {
        let mut command = Command::new(&argv[0]);
        command.args(&argv[1..]);
        command
    } else {
        let mut command = Command::new(&join[0]);
        command.args(&join[1..]).args(argv);
        command
    };
    command
        .env("PROTONBOOST_PREFIX", prefix)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone().map_err(|err| err.to_string())?))
        .stderr(Stdio::from(log));
    use std::os::unix::process::CommandExt;
    command.process_group(0);
    let mut child = command.spawn().map_err(|err| err.to_string())?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

/// 从 Steam 传来的 `%command%` 里找出真正的游戏程序。
///
/// Steam 展开 `%command%` 后是一长串：Steam 自己的运行器前缀 + `proton` +
/// 动词 + 游戏 exe + 参数。把 `proton <动词>` 之后的那段截出来，游戏就能
/// 在 ProtonBoost 的前缀和独立网络里跑，而不是 Steam 给它建的那一套。
///
/// 找不到就返回 None（那说明 %command% 指向的是 Linux 原生程序，
/// 交给 run_command 那条路处理）。
pub fn take_steam_command(argv: &[String]) -> Option<(String, Vec<String>)> {
    // 找 proton 后面跟着已知动词的那一处。
    // 用 enumerate 而不是 windows(3)：同一个 proton 路径可能出现多次，
    // 必须按实际位置取，不能用 position 找「第一个同名项」。
    for (index, window) in argv.windows(3).enumerate() {
        let exe = &window[0];
        let verb = &window[1];
        if !is_proton_path(exe) {
            continue;
        }
        if !matches!(verb.as_str(), "waitforexitandrun" | "run" | "runinprefix") {
            continue;
        }
        let target = window[2].clone();
        // 剩下的参数从动词之后开始
        let rest: Vec<String> = argv.iter().skip(index + 3).cloned().collect();
        return Some((target, rest));
    }
    None
}

/// 是不是 Proton 的启动脚本
fn is_proton_path(value: &str) -> bool {
    let lower = value.to_lowercase();
    lower.ends_with("/proton") || lower.ends_with("\\proton") || lower == "proton"
}

/// Steam 启动的游戏要不要按它自己的 app id 走（决定 UMU_ID 怎么设）
pub fn steam_app_id_from_env() -> Option<String> {
    let value = std::env::var("SteamAppId").ok()?;
    let value = value.trim().to_string();
    if value.is_empty() || value == "0" {
        return None;
    }
    Some(value)
}

/// 前台跑一条命令并等它结束（`--exec` 用，给 Steam 启动选项）：
/// 前缀开了独立网络时进同一个命名空间，返回它的退出码。
pub fn exec_foreground(prefix: &Path, argv: &[String]) -> i32 {
    if argv.is_empty() {
        eprintln!("protonboost: --exec 后面没有命令");
        return 2;
    }
    let zh = crate::core::loc::zh();

    // Steam 的 %command%：把游戏从 Steam 的运行器里取出来，改用 ProtonBoost 的前缀跑。
    // 这样它和加速器在同一个前缀、同一个独立网络里。
    if let Some((target, args)) = take_steam_command(argv) {
        let runner = runners::for_prefix(prefix);
        let Some(runner) = runner else {
            eprintln!(
                "protonboost: {}",
                if zh {
                    "没有找到可用的运行器（Proton / Wine）"
                } else {
                    "No Proton / Wine runner found"
                }
            );
            return 1;
        };
        let request = Request {
            prefix: prefix.to_path_buf(),
            target: PathBuf::from(&target),
            args,
            runner: Some(runner),
            steam_appid: steam_app_id_from_env().unwrap_or_default(),
            ..Default::default()
        };
        return match launch(&request, zh) {
            Ok(_) => 0,
            Err(err) => {
                eprintln!("protonboost: {err}");
                1
            }
        };
    }

    let session = match session::prepare(prefix, zh) {
        Ok(session) => session,
        Err(err) => {
            eprintln!("protonboost: {}", err.message(zh));
            return 1;
        }
    };
    // 和 run_command 一样：Linux 程序以普通用户身份进会话，Steam 才肯跑
    let join = if session.join_as_user.is_empty() {
        &session.join
    } else {
        &session.join_as_user
    };
    let mut command = if join.is_empty() {
        let mut command = Command::new(&argv[0]);
        command.args(&argv[1..]);
        command
    } else {
        let mut command = Command::new(&join[0]);
        command.args(&join[1..]).args(argv);
        command
    };
    command.env("PROTONBOOST_PREFIX", prefix);
    match command.status() {
        Ok(status) => status.code().unwrap_or(0),
        Err(err) => {
            eprintln!("protonboost: {err}");
            1
        }
    }
}
