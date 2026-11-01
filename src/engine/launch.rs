//! 拼命令行、拉起程序（原 lib/launch.sh 与 lib/prefix.sh 的启动部分）

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
    env.push(("WINRUN_APP_ID".into(), app_id.clone()));
    env.push(("WINRUN_APP_PATH".into(), request.target.to_string_lossy().into_owned()));
    env.push(("WINRUN_PREFIX".into(), request.prefix.to_string_lossy().into_owned()));
    env.push(("WINRUN_LOG".into(), logs::latest_log(&app_id).to_string_lossy().into_owned()));

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
            compat.push(("UMU_ID".into(), "winrun".into()));
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
    let log_path = crate::core::paths::cache_home().join("winrun/logs/init.log");
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
    let child = command.spawn().map_err(|err| err.to_string())?;

    // 等 wineserver 起来，再确认程序确实进了会话
    let deadline = Instant::now() + Duration::from_secs(120);
    while Instant::now() < deadline {
        if session::wineserver_pid(&request.prefix).is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let _ = child.id();
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

    let mut command = if session.join.is_empty() {
        let mut command = Command::new(&argv[0]);
        command.args(&argv[1..]);
        command
    } else {
        let mut command = Command::new(&session.join[0]);
        command.args(&session.join[1..]).args(argv);
        command
    };
    command
        .env("WINRUN_PREFIX", prefix)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone().map_err(|err| err.to_string())?))
        .stderr(Stdio::from(log));
    use std::os::unix::process::CommandExt;
    command.process_group(0);
    command.spawn().map(|_| ()).map_err(|err| err.to_string())
}

/// 前台跑一条命令并等它结束（`--exec` 用，给 Steam 启动选项）：
/// 前缀开了独立网络时进同一个命名空间，返回它的退出码。
pub fn exec_foreground(prefix: &Path, argv: &[String]) -> i32 {
    if argv.is_empty() {
        eprintln!("winrun: --exec 后面没有命令");
        return 2;
    }
    let zh = crate::core::loc::zh();
    let session = match session::prepare(prefix, zh) {
        Ok(session) => session,
        Err(err) => {
            eprintln!("winrun: {}", err.message(zh));
            return 1;
        }
    };
    let mut command = if session.join.is_empty() {
        let mut command = Command::new(&argv[0]);
        command.args(&argv[1..]);
        command
    } else {
        let mut command = Command::new(&session.join[0]);
        command.args(&session.join[1..]).args(argv);
        command
    };
    command.env("WINRUN_PREFIX", prefix);
    match command.status() {
        Ok(status) => status.code().unwrap_or(0),
        Err(err) => {
            eprintln!("winrun: {err}");
            1
        }
    }
}
