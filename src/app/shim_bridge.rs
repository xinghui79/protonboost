// 桥接 shim.cpp 里的 QApplication 与托盘；回调走全局通道，避免捕获环境
#[cxx::bridge]
pub mod ffi {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;

        include!("shim.h");

        type QApplication;

        #[rust_name = "log_bridge"]
        fn protonboost_install_log_bridge();

        #[rust_name = "set_window_icon"]
        fn protonboost_set_window_icon(icon_path: &QString);

        #[rust_name = "app_new"]
        fn protonboost_app_new(version: &QString) -> UniquePtr<QApplication>;

        #[rust_name = "app_exec"]
        fn protonboost_app_exec(app: &QApplication) -> i32;

        #[rust_name = "app_quit"]
        fn protonboost_app_quit();

        #[rust_name = "icon_convert"]
        fn protonboost_icon_convert(source: &QString, target: &QString, max_size: i32) -> bool;

        #[rust_name = "theme_icon"]
        fn protonboost_theme_icon(name: &QString, target: &QString, size: i32) -> bool;

        #[rust_name = "tray_available"]
        fn protonboost_tray_available() -> bool;

        #[rust_name = "tray_create"]
        fn protonboost_tray_create(
            icon_path: &QString,
            on_open: unsafe fn(),
            on_quit: unsafe fn(),
        );

        #[rust_name = "tray_set_menu_title"]
        fn protonboost_tray_set_menu_title(open: &QString, quit: &QString);

        #[rust_name = "tray_cleanup"]
        fn protonboost_tray_cleanup();

        #[rust_name = "grab_windows"]
        fn protonboost_grab_windows(path: &QString, delay_ms: i32);
    }
}

pub use ffi::{
    app_exec, app_new, app_quit, grab_windows, icon_convert, log_bridge, set_window_icon, theme_icon,
    tray_available,
    tray_cleanup, tray_create, tray_set_menu_title,
};
