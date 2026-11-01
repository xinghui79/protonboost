// WinRun 管理器：Rust + Qt6 (QML)
//
// cxx-qt 会按 QML 侧看到的属性名生成 processPrefixes / uiEvents 这类方法与字段，
// 与 Rust 的 snake_case 约定冲突，这里统一放行。
#![allow(non_snake_case, non_camel_case_types)]

mod bridge;
mod core;
mod ipc;
mod jobs;
mod shim_bridge;

use cxx_qt_lib::{QString, QQmlApplicationEngine, QUrl};
use std::path::PathBuf;

// QML 内容指纹（见 build.rs）：只改 QML 时靠它触发重编译与重链接
const QML_STAMP: &str = env!("WINRUN_QML_STAMP");

fn main() {
    let _qml_stamp = QML_STAMP;

    // 启动模式：--configure <exe> 只显示配置对话框
    let args: Vec<String> = std::env::args().collect();
    let configure_mode = match args.iter().position(|arg| arg == "--configure") {
        Some(pos) => {
            let exe = args.get(pos + 1).cloned().unwrap_or_default();
            let _ = bridge::STARTUP.set(exe);
            true
        }
        None => false,
    };

    // 调试：直接输出扫描结果
    if let Some(pos) = args.iter().position(|arg| arg == "--dump-scan") {
        let prefix = args.get(pos + 1).cloned().unwrap_or_default();
        let path = core::paths::expand_path(&prefix);
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

    cxx_qt::init_crate!(winrun_manager);
    cxx_qt::init_qml_module!("WinRun");

    shim_bridge::log_bridge();
    let mut app = shim_bridge::app_new();

    // 托盘（独立配置窗口不需要）
    if !configure_mode {
        let (open_text, quit_text) = if core::loc::zh() {
            ("打开 WinRun", "退出")
        } else {
            ("Open WinRun", "Quit")
        };
        shim_bridge::tray_create(
            &QString::from(tray_icon_path().to_string_lossy().as_ref()),
            tray_toggle,
            tray_quit,
        );
        shim_bridge::tray_set_menu_title(&QString::from(open_text), &QString::from(quit_text));
    }

    let mut engine = QQmlApplicationEngine::new();
    if let Some(engine) = engine.as_mut() {
        engine.load(&QUrl::from("qrc:/qt/qml/WinRun/qml/Main.qml"));
    }

    // 开发用：WINRUN_SHOT=<png 路径> 时渲染完截图再退出（配合 offscreen 平台做无头验收）
    if let Ok(shot) = std::env::var("WINRUN_SHOT") {
        let delay = std::env::var("WINRUN_SHOT_DELAY")
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

fn tray_icon_path() -> PathBuf {
    let candidates = [
        core::paths::data_home().join("icons/hicolor/512x512/apps/winrun.png"),
        core::paths::data_home().join("icons/winrun/apps"),
        PathBuf::from("/usr/share/icons/hicolor/512x512/apps/winrun.png"),
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
        .map(|dir| dir.join("icons/hicolor/512x512/apps/winrun.png"))
        .filter(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("winrun"))
}

fn tray_toggle() {
    let _ = jobs::events().send(jobs::Event::ToggleWindow);
}

fn tray_quit() {
    let _ = jobs::events().send(jobs::Event::Quit);
}
