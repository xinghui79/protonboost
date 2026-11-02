// ProtonBoost 管理器：Rust + Qt6 (QML)
//
// cxx-qt 会按 QML 侧看到的属性名生成 processPrefixes / uiEvents 这类方法与字段，
// 与 Rust 的 snake_case 约定冲突，这里统一放行。
#![allow(non_snake_case, non_camel_case_types)]

mod app;
mod core;
mod engine;

// 让 crate::bridge / crate::jobs 这些短路径继续可用（模块实际在子目录里）
pub use app::{bridge, ipc, jobs, shim_bridge};

use cxx_qt_lib::{QString, QQmlApplicationEngine, QUrl};
use std::path::PathBuf;

// QML 内容指纹（见 build.rs）：只改 QML 时靠它触发重编译与重链接
const QML_STAMP: &str = env!("PROTONBOOST_QML_STAMP");

fn print_usage() {
    println!(
        "protonboost {} —— 在 Linux 上用 Proton / Wine 跑 Windows 程序

用法:
  protonboost                    打开管理器
  protonboost --run <exe>        按保存的配置启动（桌面入口用）
  protonboost --configure <exe>  只打开某个程序的运行设置
  protonboost --exec <命令...>   在前缀会话里跑一条命令（Steam 启动选项）
  protonboost --list-runner      列出找到的 Proton / Wine
  protonboost --dump-scan [前缀] 打印前缀扫描结果，排查界面为什么是空的
  protonboost --doctor            环境诊断（缺什么、什么在哪儿）
  protonboost --version          版本",
        env!("CARGO_PKG_VERSION")
    );
}


/// 环境诊断：把缺什么、什么在哪儿一次列清楚
///
/// 出问题时（程序起不来、加速器不生效、覆盖层没有）先跑这个，
/// 比逐个猜要快得多。
fn doctor() {
    println!("ProtonBoost 诊断");
    println!();

    println!("命令:");
    for (label, name) in [
        ("curl", "curl"),
        ("tar", "tar"),
        ("sha512sum", "sha512sum"),
        ("pasta（独立网络）", "pasta"),
        ("nsenter（进命名空间）", "nsenter"),
        ("unshare（降权）", "unshare"),
        ("cc（覆盖层辅助库）", "cc"),
        ("notify-send（通知）", "notify-send"),
    ] {
        match core::paths::which(name) {
            Some(path) => println!("  [有] {label:<22} {}", path.display()),
            None => println!("  [缺] {label:<22} {name}"),
        }
    }

    println!();
    println!("路径:");
    let prefix = core::paths::default_prefix();
    println!("  前置环境               {}", prefix.display());
    println!("    pfx（C 盘）           {}", prefix.join("pfx").display());
    println!("    存在                  {}", if prefix.join("pfx").is_dir() { "是" } else { "否（首次启动会自动初始化）" });
    println!("  缓存                   {}", core::paths::cache_home().join("protonboost").display());
    println!("  独立网络开关           {}", prefix.join(".protonboost.conf").display());

    println!();
    println!("运行器:");
    let runners = engine::runners::discover();
    if runners.is_empty() {
        println!("  [缺] 一个都没找到。程序启动需要 Proton 或 Wine。");
        println!("       在管理器里点「下载 GE-Proton」，或自己装系统 wine。");
    } else {
        for runner in &runners {
            println!("  [有] {:<20} {} ({})", runner.name, runner.path, runner.kind);
        }
    }

    println!();
    println!("独立网络:");
    let netns = core::prefix::netns_enabled(&prefix);
    println!("  当前前缀               {}", if netns { "已开启" } else { "未开启" });
    println!("  真实 uid（命名空间外） {}", engine::session::outside_uid());
    println!(
        "  覆盖层辅助库           {}{}",
        if engine::overlay::is_ready() { "内嵌" } else { "缺失（构建时缺 cc，装上后重新编译）" },
        if engine::overlay::has_compiler() { "" } else { "（本机也没有 cc，无法回退编译）" }
    );

    println!();
    println!("Steam 端口转发:");
    println!("  端口                   57343（命名空间里的游戏用它连宿主 Steam）");
}

fn main() {
    let _qml_stamp = QML_STAMP;
    // 管道被提前关闭时（如 `--list-runner | head`）安静退出，不要 panic
    unsafe { nix::sys::signal::signal(nix::sys::signal::Signal::SIGPIPE, nix::sys::signal::SigHandler::SigDfl).ok() };

    let args: Vec<String> = std::env::args().collect();

    // 由前一次启动的 pasta 拉起的会话守护进程：撑住独立网络，等程序退出
    if let Some(pos) = args.iter().position(|arg| arg == engine::session::KEEPER_FLAG) {
        let dir = args.get(pos + 1).cloned().unwrap_or_default();
        engine::session::keeper_main(std::path::Path::new(&dir));
    }

    // 运行模式（导出的桌面入口用）：--run <exe>
    // 版本与用法：脚本、打包、issue 里都用得上，别为了问一句版本把 GUI 拉起来
    if args.iter().any(|arg| arg == "--version" || arg == "-V") {
        println!("protonboost {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        print_usage();
        return;
    }

    if let Some(pos) = args.iter().position(|arg| arg == "--run") {
        let exe = args.get(pos + 1).cloned().unwrap_or_default();
        run_saved(&exe);
        return;
    }

    // 启动模式：--configure <exe> 只显示配置对话框
    let configure_mode = match args.iter().position(|arg| arg == "--configure") {
        Some(pos) => {
            let exe = args.get(pos + 1).cloned().unwrap_or_default();
            let _ = bridge::STARTUP.set(exe);
            true
        }
        None => false,
    };

    // 命令透传（Steam 启动选项用）：--exec <命令...>
    // 在前缀的会话里跑一条 Linux 命令，等它结束并沿用它的退出码。
    if let Some(pos) = args.iter().position(|arg| arg == "--exec") {
        let command: Vec<String> = args[pos + 1..].to_vec();
        let prefix = core::paths::default_prefix();
        std::process::exit(engine::launch::exec_foreground(&prefix, &command));
    }

    // 调试：直接输出扫描结果
    if let Some(pos) = args.iter().position(|arg| arg == "--dump-scan") {
        // 不带参数就看默认前缀
        let path = match args.get(pos + 1) {
            Some(value) if !value.starts_with("--") => core::paths::expand_path(value),
            _ => core::paths::default_prefix(),
        };
        println!("prefix: {}", path.to_string_lossy());
        println!("shortcut roots:");
        for (source, root) in core::scan::shortcut_roots(&path) {
            println!("  {} → {} (exists: {})", source, root.to_string_lossy(), root.is_dir());
        }
        let apps = core::scan::scan_apps(&path);
        println!("apps: {}", apps.len());
        for app in apps {
            println!("  [{}] {} | {}", app.kind, app.path, core::scan::app_display_name(&app));
        }
        let dirs = core::scan::scan_install_dirs(&path, &[]);
        println!("dirs: {}", dirs.len());
        // 进程页的前缀列表比应用页多（含运行中的和常见位置的），排查「同名前缀」看这里
        println!("process prefixes:");
        for prefix in core::prefix::collect_process_prefixes() {
            println!("  {}", prefix.to_string_lossy());
        }
        return;
    }

    // 调试：列出发现的运行器
    if args.iter().any(|arg| arg == "--list-runner") {
        for runner in engine::runners::discover() {
            println!("{}\t{}\t{}", runner.name, runner.kind, runner.path);
        }
        return;
    }

    // 环境诊断：出问题时先跑这个
    if args.iter().any(|arg| arg == "--doctor") {
        doctor();
        return;
    }

    jobs::init();

    // 单实例：管理器已运行时通知它显示窗口后退出
    if !configure_mode && ipc::notify_existing() {
        return;
    }
    let (tx, rx) = std::sync::mpsc::channel::<()>();
    ipc::listen(tx);
    {
        let events = jobs::events().clone();
        std::thread::spawn(move || {
            while rx.recv().is_ok() {
                let _ = events.send(jobs::Event::ToggleWindow);
            }
        });
    }

    cxx_qt::init_crate!(protonboost);
    cxx_qt::init_qml_module!("ProtonBoost");

    shim_bridge::log_bridge();
    let mut app = shim_bridge::app_new(&QString::from(env!("CARGO_PKG_VERSION")));

    // 窗口/任务栏图标
    let icon_path = tray_icon_path();
    if icon_path.is_file() {
        shim_bridge::set_window_icon(&QString::from(icon_path.to_string_lossy().as_ref()));
    }

    // 托盘（独立配置窗口不需要）
    if !configure_mode {
        let (open_text, quit_text) = if core::loc::zh() {
            ("打开 ProtonBoost", "退出")
        } else {
            ("Open ProtonBoost", "Quit")
        };
        shim_bridge::tray_create(
            &QString::from(tray_icon_path().to_string_lossy().as_ref()),
            tray_toggle,
            tray_quit,
        );
        shim_bridge::tray_set_menu_title(&QString::from(open_text), &QString::from(quit_text));
    }

    let mut qml_engine = QQmlApplicationEngine::new();
    if let Some(qml_engine) = qml_engine.as_mut() {
        qml_engine.load(&QUrl::from("qrc:/qt/qml/ProtonBoost/qml/Main.qml"));
    }

    // 开发用：PROTONBOOST_SHOT=<png 路径> 时渲染完截图再退出（配合 offscreen 平台做无头验收）
    if let Ok(shot) = std::env::var("PROTONBOOST_SHOT") {
        let delay = std::env::var("PROTONBOOST_SHOT_DELAY")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
            .unwrap_or(1500);
        shim_bridge::grab_windows(&QString::from(shot.as_str()), delay);
    }

    if let Some(app) = app.as_mut() {
        let code = shim_bridge::app_exec(&app);
        ipc::cleanup();
        std::process::exit(code);
    }
}

/// 按保存的配置直接启动一个程序（不给界面，导出的 .desktop 用）
fn run_saved(exe: &str) {
    let target = core::paths::expand_path(exe);
    let Some((prefix, entry)) = core::conf::find_for_target(&target) else {
        eprintln!("protonboost: 没有找到 {} 的配置", target.display());
        std::process::exit(1);
    };
    let request = engine::launch::Request {
        prefix,
        target,
        args: engine::launch::split_args(&entry.program_args),
        runner: if entry.runner.is_empty() { None } else { engine::runners::resolve(&entry.runner) },
        gamescope: entry.gamescope,
        gamescope_fullscreen: entry.gamescope_fullscreen,
        gamescope_res: entry.gamescope_res.clone(),
        gamescope_fps: entry.gamescope_fps.clone(),
        gamescope_fsr: entry.gamescope_fsr,
        gamescope_extra: entry.gamescope_args.clone(),
        mangohud: entry.mangohud,
        wayland: entry.wayland,
        env: engine::launch::parse_env_vars(&entry.env_vars),
        steam_appid: entry.steam_appid.clone(),
    };
    match engine::launch::launch(&request, core::loc::zh()) {
        Ok(_) => {}
        Err(err) => {
            eprintln!("protonboost: {err}");
            std::process::exit(1);
        }
    }
}

fn tray_icon_path() -> PathBuf {
    let candidates = [
        core::paths::data_home().join("icons/hicolor/512x512/apps/protonboost.png"),
        core::paths::data_home().join("icons/protonboost/apps"),
        PathBuf::from("/usr/share/icons/hicolor/512x512/apps/protonboost.png"),
    ];
    for candidate in candidates {
        if candidate.is_file() {
            return candidate;
        }
    }
    // 仓库内的图标（源码运行时）
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.ancestors().nth(3).map(|dir| dir.to_path_buf()))
        .map(|dir| dir.join("icons/protonboost.png"))
        .filter(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("protonboost"))
}

fn tray_toggle() {
    let _ = jobs::events().send(jobs::Event::ToggleWindow);
}

fn tray_quit() {
    let _ = jobs::events().send(jobs::Event::Quit);
}
