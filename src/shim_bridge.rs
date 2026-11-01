// 桥接 shim.cpp 里的 QApplication 与托盘；回调走全局通道，避免捕获环境
#[cxx::bridge]
pub mod ffi {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;

        include!("shim.h");

        type QApplication;

        #[rust_name = "log_bridge"]
        fn winrun_install_log_bridge();

        #[rust_name = "app_new"]
        fn winrun_app_new() -> UniquePtr<QApplication>;

        #[rust_name = "app_exec"]
        fn winrun_app_exec(app: &QApplication) -> i32;

        #[rust_name = "app_quit"]
        fn winrun_app_quit();

        #[rust_name = "icon_convert"]
        fn winrun_icon_convert(source: &QString, target: &QString, max_size: i32) -> bool;

        #[rust_name = "theme_icon"]
        fn winrun_theme_icon(name: &QString, target: &QString, size: i32) -> bool;

        #[rust_name = "tray_create"]
        fn winrun_tray_create(
            icon_path: &QString,
            on_open: unsafe fn(),
            on_quit: unsafe fn(),
        );

        #[rust_name = "tray_set_menu_title"]
        fn winrun_tray_set_menu_title(open: &QString, quit: &QString);

        #[rust_name = "tray_cleanup"]
        fn winrun_tray_cleanup();

        #[rust_name = "grab_windows"]
        fn winrun_grab_windows(path: &QString, delay_ms: i32);
    }
}

pub use ffi::{
    app_exec, app_new, app_quit, grab_windows, icon_convert, log_bridge, theme_icon,
    tray_cleanup, tray_create, tray_set_menu_title,
};
