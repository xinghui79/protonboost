// cxx-qt 桥接：Backend 是暴露给 QML 的唯一后端对象
// 数据以 QVariant 列表整批下发；扫描/图标在 worker 线程，poll() 负责回收
use crate::core::conf::ConfigEntry;
use crate::core::icons;
use crate::core::paths::expand_path;
use crate::core::procs;
use crate::engine::launch::{self as engine_launch, Request as LaunchRequest};
use crate::engine::runners as engine_runners;
use crate::core::scan::{self, AppEntry};
use crate::jobs::{self, Event, Job};
use cxx_qt::CxxQtType;
use cxx_qt_lib::{QList, QMap, QMapPair_QString_QVariant, QString, QVariant};
use std::collections::HashSet;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::OnceLock;

pub static STARTUP: OnceLock<String> = OnceLock::new();

pub type QList_QVariant = QList<QVariant>;
pub type QMap_QString_QVariant = QMap<QMapPair_QString_QVariant>;
type QVariantList = QList_QVariant;
type QVariantMap = QMap_QString_QVariant;

const COMMON_RESOLUTIONS: &[&str] = &["1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"];
const COMMON_FPS: &[&str] = &["30", "40", "45", "60", "90", "120", "144", "165", "240"];

#[cxx_qt::bridge(namespace = "protonboost")]
pub mod ffi {
    #[namespace = ""]
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
        include!("cxx-qt-lib/qvariant.h");
        type QVariant = cxx_qt_lib::QVariant;
        include!("cxx-qt-lib/core/qlist/qlist_QVariant.h");
        type QList_QVariant = cxx_qt_lib::QList<cxx_qt_lib::QVariant>;
        include!("cxx-qt-lib/core/qmap/qmap_QString_QVariant.h");
        type QMap_QString_QVariant = cxx_qt_lib::QMap<cxx_qt_lib::QMapPair_QString_QVariant>;
    }

    unsafe extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, status)]
        #[qproperty(bool, zh)]
        #[qproperty(QList_QVariant, prefixes)]
        #[qproperty(QList_QVariant, processPrefixes)]
        #[qproperty(QList_QVariant, apps)]
        #[qproperty(QList_QVariant, dirs)]
        #[qproperty(QList_QVariant, procs)]
        #[qproperty(QList_QVariant, linux_apps)]
        #[qproperty(bool, update_available)]
        #[qproperty(QString, update_details)]
        #[qproperty(QMap_QString_QVariant, config_entry)]
        #[qproperty(QString, config_icon)]
        #[qproperty(QList_QVariant, config_runners)]
        #[qproperty(QList_QVariant, config_resolutions)]
        #[qproperty(QList_QVariant, config_fps)]
        #[qproperty(bool, netns)]
        #[qproperty(bool, tray_available)]
        #[qproperty(i32, runner_count)]
        #[qproperty(bool, overlay_ready)]
        #[qproperty(QString, exes_title)]
        #[qproperty(QList_QVariant, exes_items)]
        #[qproperty(QString, uiEvents)]
        type Backend = super::BackendRust;

        // 数据轮询与前缀
        #[qinvokable]
        fn poll(self: Pin<&mut Backend>);

        #[qinvokable]
        fn reload_prefixes(self: Pin<&mut Backend>);

        #[qinvokable]
        fn refresh_page(self: Pin<&mut Backend>, page: &QString, prefix: &QString);

        #[qinvokable]
        fn set_prefix_netns(self: Pin<&mut Backend>, prefix: &QString, enabled: bool);

        // 启动与进程
        #[qinvokable]
        fn run_path(self: Pin<&mut Backend>, path: &QString, prefix: &QString, runner: &QString);

        #[qinvokable]
        fn run_steam_game(self: Pin<&mut Backend>, appid: &QString, path: &QString, prefix: &QString);

        #[qinvokable]
        fn close_app(self: Pin<&mut Backend>, app_id: &QString, prefix: &QString);

        #[qinvokable]
        fn kill_proc(self: Pin<&mut Backend>, pid: i32, force: bool);

        #[qinvokable]
        fn kill_all_processes(self: Pin<&mut Backend>, prefix: &QString);

        #[qinvokable]
        fn launch_linux(self: Pin<&mut Backend>, prefix: &QString, command: &QString);

        #[qinvokable]
        fn launch_desktop(self: Pin<&mut Backend>, prefix: &QString, desktop_path: &QString, name: &QString);

        // 文件与配置
        #[qinvokable]
        fn open_folder(self: Pin<&mut Backend>, path: &QString);

        #[qinvokable]
        fn log_text(self: Pin<&mut Backend>, app_id: &QString) -> QString;

        #[qinvokable]
        fn log_dir(self: Pin<&mut Backend>, app_id: &QString) -> QString;

        // 详情栏只要尾部几行，不用把整份日志搬进内存
        #[qinvokable]
        fn log_tail(self: Pin<&mut Backend>, app_id: &QString, lines: i32) -> QString;

        #[qinvokable]
        fn show_dir_exes(self: Pin<&mut Backend>, prefix: &QString, dir_path: &QString);

        #[qinvokable]
        fn open_config(self: Pin<&mut Backend>, app_id: &QString, prefix: &QString);

        #[qinvokable]
        fn new_config(self: Pin<&mut Backend>, prefix: &QString);

        #[qinvokable]
        fn config_from_exe(self: Pin<&mut Backend>, prefix: &QString, exe: &QString);

        #[qinvokable]
        fn save_config(self: Pin<&mut Backend>, entry: &QMap_QString_QVariant);

        #[qinvokable]
        fn delete_app(self: Pin<&mut Backend>, app_id: &QString, prefix: &QString);

        #[qinvokable]
        fn export_app(self: Pin<&mut Backend>, app_id: &QString, prefix: &QString);

        #[qinvokable]
        fn rename_app(self: Pin<&mut Backend>, app_id: &QString, prefix: &QString, new_name: &QString);

        #[qinvokable]
        fn delete_install_dir(self: Pin<&mut Backend>, path: &QString);

        #[qinvokable]
        fn delete_prefix(self: Pin<&mut Backend>, path: &QString);

        // 运行器更新
        #[qinvokable]
        fn check_updates(self: Pin<&mut Backend>);

        #[qinvokable]
        fn update_runners_now(self: Pin<&mut Backend>);

        // 启动模式（--configure <exe> 时独立窗口只显示配置对话框）
        #[qinvokable]
        fn startup_exe(self: Pin<&mut Backend>) -> QString;

        #[qinvokable]
        fn initial_page(self: Pin<&mut Backend>) -> QString;

        #[qinvokable]
        fn configure_exe(self: Pin<&mut Backend>, exe: &QString);


        // 事件总线：uiEvents 属性值是待处理事件名（CSV），QML 处理完调 clearUiEvents
        #[qinvokable]
        fn quit_app(self: Pin<&mut Backend>);

        #[qinvokable]
        fn clear_ui_events(self: Pin<&mut Backend>);
    }
}

fn push_event(backend: std::pin::Pin<&mut ffi::Backend>, name: &str) {
    // 必须走 setter：直接写字段不会发 NOTIFY，QML 侧收不到
    let current = backend.rust().uiEvents.to_string();
    let next = if current.is_empty() {
        name.to_string()
    } else {
        format!("{current},{name}")
    };
    backend.set_uiEvents(QString::from(next));
}

#[derive(Default)]
pub struct BackendRust {
    status: QString,
    zh: bool,
    prefixes: QList_QVariant,
    processPrefixes: QList_QVariant,
    apps: QList_QVariant,
    dirs: QList_QVariant,
    procs: QList_QVariant,
    linux_apps: QList_QVariant,
    update_available: bool,
    update_details: QString,
    netns: bool,
    tray_available: bool,
    tray_checked: bool,
    runner_count: i32,
    overlay_ready: bool,
    config_entry: QMap_QString_QVariant,
    config_icon: QString,
    config_runners: QList_QVariant,
    config_resolutions: QList_QVariant,
    config_fps: QList_QVariant,
    exes_title: QString,
    exes_items: QList_QVariant,
    uiEvents: QString,

    current_apps: Vec<AppEntry>,
    current_prefix: String,
    req_apps: u64,
    req_dirs: u64,
    req_procs: u64,
    req_linux: u64,
    icons_requested: HashSet<String>,
    status_deadline_ms: u64,
    update_running: bool,
}

// ── QVariant 构造小工具 ──────────────────────────────────────
fn qvar_str(value: &str) -> QVariant {
    QVariant::from(&QString::from(value))
}

fn qvar_bool(value: bool) -> QVariant {
    QVariant::from(&value)
}

fn qvar_int(value: i32) -> QVariant {
    QVariant::from(&value)
}

fn build_list(rows: Vec<Vec<(&str, QVariant)>>) -> QVariantList {
    let mut list = QVariantList::default();
    for row in rows {
        let mut map: QVariantMap = QMap::default();
        for (key, value) in row {
            map.insert(QString::from(key), value);
        }
        list.append(QVariant::from(&map));
    }
    list
}

fn map_get_str(map: &QMap_QString_QVariant, key: &str) -> String {
    map.get(&QString::from(key))
        .and_then(|value| value.value::<QString>())
        .map(|value| value.to_string())
        .unwrap_or_default()
}

fn map_get_bool(map: &QMap_QString_QVariant, key: &str) -> bool {
    map_get_str(map, key) == "1" || map_get_str(map, key) == "true"
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn spawn_detached(command: &mut std::process::Command) -> Result<(), String> {
    use std::os::unix::process::CommandExt;
    command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .process_group(0)
        .spawn()
        .map(|_| ())
        .map_err(|err| err.to_string())
}

/// 管理器自己的可执行文件：导出的桌面入口指向它
fn manager_path() -> PathBuf {
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from("protonboost"))
}

/// 简易 shlex：支持单双引号的命令拆分
fn shlex_split(text: &str) -> Result<Vec<String>, ()> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut chars = text.chars().peekable();
    let mut has_token = false;
    while let Some(char) = chars.next() {
        match char {
            ' ' | '\t' => {
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
    Ok(parts)
}

impl ffi::Backend {
    // ── 数据轮询 ────────────────────────────────────────────
    pub fn poll(mut self: Pin<&mut Self>) {
        if !self.as_mut().rust().zh {
            self.as_mut().set_zh(crate::core::loc::zh());
        }
        if !self.as_mut().rust().tray_checked {
            self.as_mut().rust_mut().tray_checked = true;
            self.as_mut().set_tray_available(crate::shim_bridge::tray_available());
        }

        // 状态栏 4 秒后自动清空
        if self.as_mut().rust_mut().status_deadline_ms != 0 && now_ms() > self.as_mut().rust_mut().status_deadline_ms {
            self.as_mut().rust_mut().status_deadline_ms = 0;
            self.as_mut().set_status(QString::from(""));
        }

        while let Some(message) = jobs::try_result() {
            match message {
                jobs::ResultMsg::Apps { req, items, apps } => {
                    if req != self.as_mut().rust_mut().req_apps {
                        continue;
                    }
                    self.as_mut().rust_mut().current_apps = apps;
                    let list = build_list(
                        items
                            .iter()
                            .map(|row| {
                                vec![
                                    ("appId", qvar_str(&row.app_id)),
                                    ("name", qvar_str(&row.display_name)),
                                    ("detail", qvar_str(&row.detail)),
                                    ("meta", qvar_str(&row.meta)),
                                    ("icon", qvar_str(if row.icon.is_empty() { "protonboost" } else { &row.icon })),
                                    ("running", qvar_bool(row.running)),
                                    ("hasLog", qvar_bool(row.has_log)),
                                    ("canConfig", qvar_bool(row.can_config)),
                                    ("isSteam", qvar_bool(row.is_steam)),
                                    ("steamAppid", qvar_str(&row.steam_appid)),
                                    ("kind", qvar_str(&row.kind)),
                                    ("path", qvar_str(&row.path)),
                                    ("winPath", qvar_str(&row.win_path)),
                                    ("runner", qvar_str(&row.runner)),
                                ]
                            })
                            .collect(),
                    );
                    self.as_mut().set_apps(list);
                }
                jobs::ResultMsg::Icon { req, app_id, icon } => {
                    if req != self.as_mut().rust_mut().req_apps || icon == "protonboost" {
                        continue;
                    }
                    // 把解析出的图标写回应用列表
                    let mut updated = QVariantList::default();
                    let count = self.apps().len();
                    for index in 0..count {
                        let item = match self.apps().get(index) {
                            Some(item) => item.clone(),
                            None => continue,
                        };
                        let mut replaced = item.clone();
                        if let Some(map) = item.value::<QVariantMap>() {
                            let matches = map
                                .get(&QString::from("appId"))
                                .and_then(|value| value.value::<QString>())
                                .map(|value| value.to_string() == app_id)
                                .unwrap_or(false);
                            if matches {
                                let mut new_map: QVariantMap = QMap::default();
                                for (key, value) in map.iter() {
                                    if key.to_string() == "icon" {
                                        new_map.insert(QString::from("icon"), qvar_str(&icon));
                                    } else {
                                        new_map.insert(key.clone(), value.clone());
                                    }
                                }
                                replaced = QVariant::from(&new_map);
                            }
                        }
                        updated.append(replaced);
                    }
                    self.as_mut().set_apps(updated);
                }
                jobs::ResultMsg::Dirs { req, items } => {
                    if req != self.as_mut().rust_mut().req_dirs {
                        continue;
                    }
                    let list = build_list(
                        items
                            .iter()
                            .map(|row| {
                                vec![
                                    ("name", qvar_str(&row.name)),
                                    ("path", qvar_str(&row.path)),
                                    ("detail", qvar_str(&row.detail)),
                                    ("canDelete", qvar_bool(row.can_delete)),
                                ]
                            })
                            .collect(),
                    );
                    self.as_mut().set_dirs(list);
                }
                jobs::ResultMsg::Procs { req, items } => {
                    if req != self.as_mut().rust_mut().req_procs {
                        continue;
                    }
                    let list = build_list(
                        items
                            .iter()
                            .map(|row| {
                                vec![
                                    ("pid", qvar_int(row.pid)),
                                    ("title", qvar_str(&format!("{}  PID {}  {}", row.name, row.pid, row.age))),
                                    ("command", qvar_str(&row.command)),
                                ]
                            })
                            .collect(),
                    );
                    self.as_mut().set_procs(list);
                }
                jobs::ResultMsg::LinuxApps { req, items } => {
                    if req != self.as_mut().rust_mut().req_linux {
                        continue;
                    }
                    let list = build_list(
                        items
                            .iter()
                            .map(|row| {
                                vec![
                                    ("id", qvar_str(&row.id)),
                                    ("name", qvar_str(&row.name)),
                                    ("path", qvar_str(&row.path)),
                                    // 主题图标名在这条线程（主线程）解析成 PNG 缓存路径
                                    ("icon", qvar_str(&icons::theme_icon_png(&row.icon))),
                                ]
                            })
                            .collect(),
                    );
                    self.as_mut().set_linux_apps(list);
                }
                jobs::ResultMsg::Exes { title, items } => {
                    let list = build_list(
                        items
                            .iter()
                            .map(|row| {
                                vec![
                                    ("path", qvar_str(&row.path)),
                                    ("name", qvar_str(&row.name)),
                                    ("detail", qvar_str(&row.detail)),
                                ]
                            })
                            .collect(),
                    );
                    self.as_mut().set_exes_title(QString::from(title));
                    self.as_mut().set_exes_items(list);
                    push_event(self.as_mut(), "exes");
                }
                jobs::ResultMsg::Launch { label, result } => {
                    let zh = crate::core::loc::zh();
                    match result {
                        Ok(notes) => {
                            let mut message = if zh { format!("运行：{label}") } else { format!("Run: {label}") };
                            if let Some(note) = notes.first() {
                                message.push_str(" · ");
                                message.push_str(note);
                            }
                            self.as_mut().set_status(QString::from(message));
                            let prefix = self.as_mut().rust().current_prefix.clone();
                            self.as_mut().refresh_apps_now(&prefix);
                            jobs::refresh_after(1500);
                        }
                        Err(err) => {
                            let message = if zh { format!("启动失败：{err}") } else { format!("Launch failed: {err}") };
                            self.as_mut().set_status(QString::from(message));
                        }
                    }
                }
                jobs::ResultMsg::UpdateCheck { text } => {
                    let available = !text.is_empty();
                    self.as_mut().set_update_available(available);
                    if available {
                        self.as_mut().set_update_details(QString::from(text));
                    }
                }
                jobs::ResultMsg::UpdateRun { installed, error } => {
                    self.as_mut().rust_mut().update_running = false;
                    let zh = crate::core::loc::zh();
                    let message = match error {
                        Some(err) => format!("{}: {err}", if zh { "更新失败" } else { "Update failed" }),
                        None => {
                            if zh {
                                format!("已安装 {installed} 个运行器")
                            } else {
                                format!("Installed {installed} runner(s)")
                            }
                        }
                    };
                    self.as_mut().set_status(QString::from(message));
                    if installed > 0 {
                        self.as_mut().set_update_available(false);
                    }
                    self.as_mut().reload_prefixes();
                    self.as_mut().check_updates();
                }
            }
        }

        while let Some(event) = jobs::try_event() {
            match event {
                Event::ToggleWindow => push_event(self.as_mut(), "toggle"),
                Event::Quit => {
                    crate::shim_bridge::tray_cleanup();
                    crate::shim_bridge::app_quit();
                }
                Event::Refresh => {
                    let prefix = self.as_mut().rust_mut().current_prefix.clone();
                    self.as_mut().refresh_apps_now(&prefix);
                }
            }
        }
    }

    pub fn reload_prefixes(mut self: Pin<&mut Self>) {
        self.as_mut().set_zh(crate::core::loc::zh());
        let prefixes = crate::core::prefix::collect_prefixes();
        let process_prefixes = crate::core::prefix::collect_process_prefixes();

        let prefix_list = build_list(
            prefixes
                .iter()
                .map(|path| {
                    vec![
                        ("path", qvar_str(&path.to_string_lossy())),
                        ("netns", qvar_bool(crate::core::prefix::netns_enabled(path))),
                    ]
                })
                .collect(),
        );
        self.as_mut().set_prefixes(prefix_list);

        // 进程页前缀：Steam 游戏名做标注，重复的加路径
        let names = crate::core::steam::app_names();
        let mut labels: Vec<(String, PathBuf)> = process_prefixes
            .iter()
            .map(|path| {
                let label = scan::process_prefix_label(path, &names);
                (label, path.clone())
            })
            .collect();
        let mut counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
        for (label, _) in &labels {
            *counts.entry(label.clone()).or_insert(0) += 1;
        }
        let mut seen = HashSet::new();
        labels.retain(|(label, path)| {
            let key = format!("{}\0{}", label, path.to_string_lossy());
            seen.insert(key)
        });
        let process_list = build_list(
            labels
                .iter()
                .map(|(label, path)| {
                    let shown = if counts[label] > 1 {
                        format!("{label} · {}", path.to_string_lossy())
                    } else {
                        label.clone()
                    };
                    vec![
                        ("label", qvar_str(&shown)),
                        ("path", qvar_str(&path.to_string_lossy())),
                        ("netns", qvar_bool(crate::core::prefix::netns_enabled(path))),
                    ]
                })
                .collect(),
        );
        self.as_mut().set_processPrefixes(process_list);
        self.as_mut().set_runner_count(engine_runners::discover().len() as i32);
        self.as_mut().set_overlay_ready(crate::engine::overlay::is_ready());

        // 首次加载时给状态栏一句交代
        if self.as_mut().rust().status.to_string().is_empty() {
            let count = prefixes.len();
            let text = if crate::core::loc::zh() {
                match count {
                    0 => "没有找到前置环境".to_string(),
                    _ => format!("已就绪 · {count} 个前置环境"),
                }
            } else {
                match count {
                    0 => "No prefixes found".to_string(),
                    _ => format!("Ready · {count} prefixes"),
                }
            };
            self.as_mut().set_status(QString::from(text));
        }
    }

    pub fn refresh_page(mut self: Pin<&mut Self>, page: &QString, prefix: &QString) {
        let page = page.to_string();
        let prefix_path = expand_path(&prefix.to_string());
        let netns = crate::core::prefix::netns_enabled(&prefix_path);
        {
            let mut rust = self.as_mut().rust_mut();
            match page.as_str() {
                "apps" => {
                    rust.req_apps += 1;
                    rust.current_prefix = prefix_path.to_string_lossy().into_owned();
                    rust.icons_requested.clear();
                    jobs::send(Job::Apps { req: rust.req_apps, prefix: prefix_path });
                }
                "dirs" => {
                    rust.req_dirs += 1;
                    jobs::send(Job::Dirs { req: rust.req_dirs, prefix: prefix_path });
                }
                "procs" => {
                    rust.req_procs += 1;
                    jobs::send(Job::Procs { req: rust.req_procs, prefix: prefix_path });
                }
                "linux" => {
                    rust.req_linux += 1;
                    jobs::send(Job::LinuxApps { req: rust.req_linux });
                }
                _ => {}
            }
        }
        self.as_mut().set_netns(netns);
    }

    /// 状态栏那个「独立网络」开关：直接改前缀的 .protonboost.conf
    pub fn set_prefix_netns(mut self: Pin<&mut Self>, prefix: &QString, enabled: bool) {
        let path = expand_path(&prefix.to_string());
        if path.as_os_str().is_empty() {
            return;
        }
        let zh = crate::core::loc::zh();
        match crate::core::prefix::set_netns(&path, enabled) {
            Ok(()) => {
                self.as_mut().set_netns(enabled);
                let name = path
                    .file_name()
                    .map(|name| name.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let message = match (zh, enabled) {
                    (true, true) => format!("{name}：独立网络已开启（下次启动生效）"),
                    (true, false) => format!("{name}：独立网络已关闭"),
                    (false, true) => format!("{name}: isolated network on (applies to the next launch)"),
                    (false, false) => format!("{name}: isolated network off"),
                };
                self.as_mut().set_status(QString::from(message));
                self.as_mut().reload_prefixes();
            }
            Err(err) => self.as_mut().set_status(QString::from(format!(
                "{}: {err}",
                if zh { "无法保存网络设置" } else { "Cannot save network setting" }
            ))),
        }
    }

    fn refresh_apps_now(mut self: Pin<&mut Self>, prefix: &str) {
        let mut rust = self.as_mut().rust_mut();
        rust.req_apps += 1;
        rust.icons_requested.clear();
        let path = if prefix.is_empty() {
            expand_path(&rust.current_prefix.clone())
        } else {
            expand_path(prefix)
        };
        rust.current_prefix = path.to_string_lossy().into_owned();
        jobs::send(Job::Apps { req: rust.req_apps, prefix: path });
        rust.req_dirs += 1;
        let dirs_path = PathBuf::from(rust.current_prefix.clone());
        jobs::send(Job::Dirs { req: rust.req_dirs, prefix: dirs_path });
    }

    // ── 启动与进程 ──────────────────────────────────────────
    pub fn run_path(mut self: Pin<&mut Self>, path: &QString, prefix: &QString, runner: &QString) {
        let target = expand_path(&path.to_string());
        if target.as_os_str().is_empty() {
            return;
        }
        let prefix_path = expand_path(&prefix.to_string());
        let key = target.to_string_lossy().into_owned();
        let entry = ConfigEntry::read(&key).unwrap_or_else(|| {
            let mut entry = crate::core::conf::default_entry();
            entry.exe = key.clone();
            entry.prefix = prefix_path.to_string_lossy().into_owned();
            entry
        });
        let runner_value = if runner.to_string().is_empty() { entry.runner.clone() } else { runner.to_string() };
        let label = target
            .file_stem()
            .and_then(|name| name.to_str())
            .unwrap_or(&key)
            .to_string();

        let request = LaunchRequest {
            prefix: prefix_path,
            target,
            args: engine_launch::split_args(&entry.program_args),
            runner: engine_runners::resolve(&runner_value),
            gamescope: entry.gamescope,
            gamescope_fullscreen: entry.gamescope_fullscreen,
            gamescope_res: entry.gamescope_res.clone(),
            gamescope_fps: entry.gamescope_fps.clone(),
            gamescope_fsr: entry.gamescope_fsr,
            gamescope_extra: entry.gamescope_args.clone(),
            mangohud: entry.mangohud,
            wayland: entry.wayland,
            env: engine_launch::parse_env_vars(&entry.env_vars),
            steam_appid: entry.steam_appid.clone(),
        };

        let zh = crate::core::loc::zh();
        self.as_mut().set_status(QString::from(if zh {
            format!("正在启动 {label}…")
        } else {
            format!("Starting {label}…")
        }));
        jobs::send(Job::Launch { request, label });
    }

    pub fn run_steam_game(mut self: Pin<&mut Self>, appid: &QString, path: &QString, prefix: &QString) {
        let appid_str = appid.to_string();
        let mut command = std::process::Command::new("xdg-open");
        command.arg(format!("steam://rungameid/{appid_str}"));
        let _ = spawn_detached(&mut command);
        scan::mark_app_started(
            &expand_path(&prefix.to_string()),
            std::path::Path::new(&path.to_string()),
        );
        let zh = crate::core::loc::zh();
        self.as_mut().set_status(QString::from(format!(
            "{}: {appid_str}",
            if zh { "通过 Steam 启动" } else { "Start through Steam" }
        )));
        let prefix_clone = prefix.to_string();
        self.as_mut().refresh_apps_now(&prefix_clone);
        jobs::refresh_after(800);
    }

    pub fn close_app(mut self: Pin<&mut Self>, app_id: &QString, prefix: &QString) {
        let app_id_str = app_id.to_string();
        let prefix_path = expand_path(&prefix.to_string());
        let everything = procs::scan_processes(&prefix_path);
        let hosts = procs::session_host_pids(&everything);
        let own = procs::app_own_processes(&everything, &app_id_str, &hosts);
        let targets: Vec<procs::ProcEntry> = {
            let wine_only: Vec<procs::ProcEntry> =
                own.iter().filter(|p| procs::is_wine_process(p)).cloned().collect();
            if wine_only.is_empty() { own } else { wine_only }
        };
        let count = targets.len();
        for proc in &targets {
            let _ = procs::kill_pid(proc.pid, false);
        }
        let zh = crate::core::loc::zh();
        self.as_mut().set_status(QString::from(format!(
            "{}: {count}",
            if zh { "关闭" } else { "Close" }
        )));
        // 三秒后还在的强制结束
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(3));
            for proc in &targets {
                if let Ok(comm) = std::fs::read_to_string(format!("/proc/{}/comm", proc.pid)) {
                    if comm.trim() == proc.name {
                        let _ = procs::kill_pid(proc.pid, true);
                    }
                }
            }
            let _ = jobs::events().send(Event::Refresh);
        });
    }

    pub fn kill_proc(mut self: Pin<&mut Self>, pid: i32, force: bool) {
        if let Err(err) = procs::kill_pid(pid, force) {
            self.as_mut().set_status(QString::from(err));
        }
        let prefix = self.as_mut().rust_mut().current_prefix.clone();
        self.as_mut().refresh_page(&QString::from("procs"), &QString::from(&prefix));
    }

    pub fn kill_all_processes(mut self: Pin<&mut Self>, prefix: &QString) {
        let prefix_path = expand_path(&prefix.to_string());
        let all = procs::scan_processes(&prefix_path);
        let count = all.len();
        for proc in &all {
            let _ = procs::kill_pid(proc.pid, true);
        }
        let zh = crate::core::loc::zh();
        self.as_mut().set_status(QString::from(format!(
            "{}: {count}",
            if zh { "强制关闭所有进程" } else { "Force Close All Processes" }
        )));
        self.as_mut().refresh_page(&QString::from("procs"), prefix);
    }

    pub fn launch_linux(mut self: Pin<&mut Self>, prefix: &QString, command: &QString) {
        let text = command.to_string().trim().to_string();
        if text.is_empty() {
            return;
        }
        let Ok(argv) = shlex_split(&text) else {
            let zh = crate::core::loc::zh();
            self.as_mut().set_status(QString::from(if zh { "无法解析命令" } else { "Cannot parse command" }));
            return;
        };
        self.launch_argv(prefix, &argv, &text);
    }

    pub fn launch_desktop(self: Pin<&mut Self>, prefix: &QString, desktop_path: &QString, name: &QString) {
        let argv = vec![
            "gio".to_string(),
            "launch".to_string(),
            desktop_path.to_string(),
        ];
        self.launch_argv(prefix, &argv, &name.to_string());
    }

    fn launch_argv(self: Pin<&mut Self>, prefix: &QString, argv: &[String], display: &str) {
        jobs::send(Job::LaunchCommand {
            prefix: expand_path(&prefix.to_string()),
            argv: argv.to_vec(),
            label: display.to_string(),
        });
    }

    // ── 文件与配置 ──────────────────────────────────────────
    pub fn open_folder(self: Pin<&mut Self>, path: &QString) {
        let mut command = std::process::Command::new("xdg-open");
        command.arg(path.to_string());
        let _ = spawn_detached(&mut command);
    }

    pub fn log_text(self: Pin<&mut Self>, app_id: &QString) -> QString {
        let id = app_id.to_string();
        let text = crate::core::paths::latest_log_for_app(&id)
            .and_then(|path| std::fs::read_to_string(path).ok())
            .unwrap_or_default();
        QString::from(text)
    }

    pub fn log_dir(self: Pin<&mut Self>, app_id: &QString) -> QString {
        let id = app_id.to_string();
        QString::from(crate::core::paths::app_log_dir(&id).to_string_lossy().into_owned())
    }

    pub fn log_tail(self: Pin<&mut Self>, app_id: &QString, lines: i32) -> QString {
        let id = app_id.to_string();
        let limit = lines.clamp(1, 200) as usize;
        let text = crate::core::paths::latest_log_for_app(&id)
            .and_then(|path| std::fs::read_to_string(path).ok())
            .unwrap_or_default();
        if text.is_empty() {
            return QString::from("");
        }
        let all: Vec<&str> = text.lines().collect();
        let start = all.len().saturating_sub(limit);
        let mut tail = all[start..].join("\n");
        // 单行特别长时再截一下，避免把详情栏撑坏
        if tail.chars().count() > 2000 {
            tail = tail.chars().skip(tail.chars().count() - 2000).collect();
        }
        QString::from(tail)
    }

    pub fn show_dir_exes(self: Pin<&mut Self>, prefix: &QString, dir_path: &QString) {
        // 扫描交给工作线程，结果到了再开弹层（大目录不至于卡界面）
        jobs::send(Job::Exes {
            prefix: expand_path(&prefix.to_string()),
            dir: expand_path(&dir_path.to_string()),
        });
    }

    fn emit_config(mut self: Pin<&mut Self>, entry: ConfigEntry) {
        let runners_list = engine_runners::discover();
        let runner_list = build_list(
            runners_list
                .iter()
                .map(|runner| {
                    vec![
                        ("label", qvar_str(&engine_runners::label(runner))),
                        ("path", qvar_str(&runner.path)),
                    ]
                })
                .collect(),
        );
        let resolutions = build_list(
            COMMON_RESOLUTIONS
                .iter()
                .map(|value| vec![("value", qvar_str(value))])
                .collect(),
        );
        let fps = build_list(
            COMMON_FPS.iter().map(|value| vec![("value", qvar_str(value))]).collect(),
        );
        let mut map: QVariantMap = QMap::default();
        let put = |map: &mut QVariantMap, key: &str, value: &str| {
            map.insert(QString::from(key), qvar_str(value));
        };
        put(&mut map, "file", &entry.file);
        put(&mut map, "name", &entry.name);
        put(&mut map, "exe", &entry.exe);
        put(&mut map, "prefix", &entry.prefix);
        // 运行器在界面上显示成「名称 · 来源」，存盘时再映射回路径
        let runner_label = runners_list
            .iter()
            .find(|runner| runner.path == entry.runner)
            .map(engine_runners::label)
            .unwrap_or_else(|| engine_runners::label_from_path(&entry.runner));
        put(&mut map, "runner", &runner_label);
        put(&mut map, "runnerPath", &entry.runner);
        put(&mut map, "programArgs", &entry.program_args);
        map.insert(QString::from("gamescope"), qvar_bool(entry.gamescope));
        map.insert(QString::from("gamescopeFullscreen"), qvar_bool(entry.gamescope_fullscreen));
        put(&mut map, "gamescopeRes", &entry.gamescope_res);
        put(&mut map, "gamescopeFps", &entry.gamescope_fps);
        map.insert(QString::from("gamescopeFsr"), qvar_bool(entry.gamescope_fsr));
        put(&mut map, "gamescopeArgs", &entry.gamescope_args);
        map.insert(QString::from("mangohud"), qvar_bool(entry.mangohud));
        map.insert(QString::from("wayland"), qvar_bool(entry.wayland));
        put(&mut map, "envVars", &entry.env_vars);
        put(&mut map, "steamAppid", &entry.steam_appid);
        put(&mut map, "source", &entry.source);
        put(&mut map, "displayName", &entry.name);

        // 配置弹层顶部用程序自己的图标；取不到时 QML 退回首字母
        let icon = if entry.exe.is_empty() {
            String::new()
        } else {
            let app = AppEntry {
                path: entry.exe.clone(),
                name: if entry.name.is_empty() {
                    scan::inferred_exe_name(std::path::Path::new(&entry.exe), None)
                } else {
                    entry.name.clone()
                },
                kind: "saved-config".into(),
                ..Default::default()
            };
            let found = icons::icon_for_app_quick(&expand_path(&entry.prefix), &app);
            if found == "protonboost" { String::new() } else { found }
        };
        self.as_mut().set_config_icon(QString::from(icon));

        self.as_mut().set_config_entry(map);
        self.as_mut().set_config_runners(runner_list);
        self.as_mut().set_config_resolutions(resolutions);
        self.as_mut().set_config_fps(fps);
        push_event(self.as_mut(), "config");
    }

    pub fn open_config(self: Pin<&mut Self>, app_id: &QString, prefix: &QString) {
        let id = app_id.to_string();
        let prefix_path = expand_path(&prefix.to_string());
        let entry = self
            .rust()
            .current_apps
            .iter()
            .find(|app| scan::app_identity(&prefix_path, std::path::Path::new(&app.path)) == id)
            .map(|app| crate::core::export::app_cache_entry(&prefix_path, app))
            .unwrap_or_else(crate::core::conf::default_entry);
        self.emit_config(entry);
    }

    pub fn new_config(self: Pin<&mut Self>, prefix: &QString) {
        let prefix_path = expand_path(&prefix.to_string());
        let mut entry = crate::core::conf::default_entry();
        entry.prefix = prefix_path.to_string_lossy().into_owned();
        entry.runner = default_runner_for(&prefix_path);
        self.emit_config(entry);
    }

    pub fn config_from_exe(self: Pin<&mut Self>, prefix: &QString, exe: &QString) {
        let prefix_path = expand_path(&prefix.to_string());
        let exe_path = expand_path(&exe.to_string());
        let mut entry = crate::core::conf::default_entry();
        entry.name = scan::inferred_exe_name(&exe_path, Some(&prefix_path));
        entry.exe = exe_path.to_string_lossy().into_owned();
        entry.prefix = prefix_path.to_string_lossy().into_owned();
        entry.runner = default_runner_for(&prefix_path);
        entry.source = "install-dir".into();
        self.emit_config(entry);
    }

    pub fn save_config(mut self: Pin<&mut Self>, entry: &QMap_QString_QVariant) {
        let prefix_value = map_get_str(entry, "prefix");
        let runner_value = map_get_str(entry, "runner");
        let runner = resolve_runner(&runner_value)
            .or_else(|| {
                let path = map_get_str(entry, "runnerPath");
                if path.is_empty() { None } else { Some(path) }
            })
            .unwrap_or_else(|| default_runner_for(std::path::Path::new(&expand_path(&prefix_value))));
        let mut config = ConfigEntry {
            file: map_get_str(entry, "file"),
            name: map_get_str(entry, "name"),
            exe: map_get_str(entry, "exe"),
            prefix: prefix_value,
            runner,
            program_args: map_get_str(entry, "programArgs"),
            gamescope: map_get_bool(entry, "gamescope"),
            gamescope_fullscreen: map_get_bool(entry, "gamescopeFullscreen"),
            gamescope_res: map_get_str(entry, "gamescopeRes"),
            gamescope_fps: map_get_str(entry, "gamescopeFps"),
            gamescope_fsr: map_get_bool(entry, "gamescopeFsr"),
            gamescope_args: map_get_str(entry, "gamescopeArgs"),
            mangohud: map_get_bool(entry, "mangohud"),
            wayland: map_get_bool(entry, "wayland") && !map_get_bool(entry, "gamescope"),
            env_vars: map_get_str(entry, "envVars"),
            steam_appid: map_get_str(entry, "steamAppid"),
            source: "configured".into(),
        };
        if config.name.is_empty() {
            config.name = map_get_str(entry, "displayName");
        }
        let exe = config.exe.clone();
        let path = config.write();
        let message = if crate::core::loc::zh() {
            format!("配置: {exe} → {}", path.to_string_lossy())
        } else {
            format!("Config: {exe} → {}", path.to_string_lossy())
        };
        self.as_mut().set_status(QString::from(message));
        let prefix = self.as_mut().rust_mut().current_prefix.clone();
        self.as_mut().refresh_apps_now(&prefix);
        self.as_mut().reload_prefixes();
    }

    pub fn delete_app(mut self: Pin<&mut Self>, app_id: &QString, prefix: &QString) {
        let id = app_id.to_string();
        let prefix_path = expand_path(&prefix.to_string());
        let Some(app) = self
            .rust()
            .current_apps
            .iter()
            .find(|app| scan::app_identity(&prefix_path, std::path::Path::new(&app.path)) == id)
            .cloned()
        else {
            return;
        };
        let desktop = crate::core::export::delete_exported_app(&prefix_path, &app);
        for file in scan::app_cache_files(&prefix_path, &app) {
            let _ = std::fs::remove_file(&file);
        }
        crate::core::export::maybe_update_desktop_database();
        let zh = crate::core::loc::zh();
        let mut status = format!(
            "{}: {}",
            if zh { "已删除" } else { "Removed" },
            desktop.to_string_lossy()
        );
        if app.kind == "shortcut" {
            status.push_str(if zh {
                "（快捷方式仍在前缀里，会继续列出）"
            } else {
                " (the shortcut is still listed)"
            });
        }
        self.as_mut().set_status(QString::from(status));
        let prefix_str = prefix_path.to_string_lossy().into_owned();
        self.as_mut().refresh_apps_now(&prefix_str);
    }

    pub fn export_app(mut self: Pin<&mut Self>, app_id: &QString, prefix: &QString) {
        let id = app_id.to_string();
        let prefix_path = expand_path(&prefix.to_string());
        let Some(app) = self
            .rust()
            .current_apps
            .iter()
            .find(|app| scan::app_identity(&prefix_path, std::path::Path::new(&app.path)) == id)
            .cloned()
        else {
            return;
        };
        let target = crate::core::export::export_app(&prefix_path, &app, &manager_path(), None);
        crate::core::export::maybe_update_desktop_database();
        let zh = crate::core::loc::zh();
        self.as_mut().set_status(QString::from(format!(
            "{}: {}",
            if zh { "已导出" } else { "Exported" },
            target.to_string_lossy()
        )));
        let prefix_str = prefix_path.to_string_lossy().into_owned();
        self.as_mut().refresh_apps_now(&prefix_str);
    }

    pub fn rename_app(mut self: Pin<&mut Self>, app_id: &QString, prefix: &QString, new_name: &QString) {
        let id = app_id.to_string();
        let name = new_name.to_string().trim().to_string();
        if name.is_empty() {
            return;
        }
        let prefix_path = expand_path(&prefix.to_string());
        let Some(app) = self
            .rust()
            .current_apps
            .iter()
            .find(|app| scan::app_identity(&prefix_path, std::path::Path::new(&app.path)) == id)
            .cloned()
        else {
            return;
        };
        let old_name = scan::app_display_name(&app);
        let renamed = crate::core::export::rename_icon_cache_files(&old_name, &name);
        let mut entry = crate::core::export::app_cache_entry(&prefix_path, &app);
        entry.name = name.clone();
        entry.write();
        let desktop = crate::core::export::exported_desktop_path(&prefix_path, &app, None);
        if desktop.is_file() {
            crate::core::export::rewrite_desktop_name(&desktop, &name);
            crate::core::export::rewrite_desktop_icon(&desktop, &renamed);
        }
        let zh = crate::core::loc::zh();
        self.as_mut().set_status(QString::from(format!(
            "{}: {name}",
            if zh { "重命名" } else { "Rename" }
        )));
        let prefix_str = prefix_path.to_string_lossy().into_owned();
        self.as_mut().refresh_apps_now(&prefix_str);
    }

    pub fn delete_install_dir(mut self: Pin<&mut Self>, path: &QString) {
        let path = expand_path(&path.to_string());
        let zh = crate::core::loc::zh();
        match std::fs::remove_dir_all(&path) {
            Ok(()) => {
                self.as_mut().set_status(QString::from(format!(
                    "{}: {}",
                    if zh { "已删除" } else { "Removed" },
                    path.to_string_lossy()
                )));
            }
            Err(err) => {
                self.as_mut().set_status(QString::from(format!(
                    "{}: {err}",
                    if zh { "错误" } else { "Error" }
                )));
            }
        }
        let prefix = self.as_mut().rust_mut().current_prefix.clone();
        self.as_mut().refresh_apps_now(&prefix);
    }

    pub fn delete_prefix(mut self: Pin<&mut Self>, path: &QString) {
        let path = expand_path(&path.to_string());
        let zh = crate::core::loc::zh();
        if !procs::scan_processes(&path).is_empty() {
            self.as_mut().set_status(QString::from(if zh {
                "此前置环境仍有运行中的进程，请先关闭。"
            } else {
                "This prefix still has running processes."
            }));
            return;
        }
        if !scan::can_delete_prefix(&path) {
            self.as_mut().set_status(QString::from(if zh {
                "出于安全原因，不能删除此前置环境。"
            } else {
                "This prefix cannot be deleted for safety reasons."
            }));
            return;
        }
        match std::fs::remove_dir_all(&path) {
            Ok(()) => {
                self.as_mut().set_status(QString::from(format!(
                    "{}: {}",
                    if zh { "已删除" } else { "Removed" },
                    path.to_string_lossy()
                )));
            }
            Err(err) => {
                self.as_mut().set_status(QString::from(format!(
                    "{}: {err}",
                    if zh { "错误" } else { "Error" }
                )));
            }
        }
        self.as_mut().reload_prefixes();
    }

    // ── 运行器更新 ──────────────────────────────────────────
    pub fn check_updates(mut self: Pin<&mut Self>) {
        if self.as_mut().rust_mut().update_running {
            return;
        }
        jobs::send(Job::UpdateCheck);
    }

    pub fn update_runners_now(mut self: Pin<&mut Self>) {
        let zh = crate::core::loc::zh();
        {
            let mut rust = self.as_mut().rust_mut();
            if rust.update_running {
                return;
            }
            rust.update_running = true;
        }
        self.as_mut().set_status(QString::from(if zh {
            "正在下载 WE-Proton（约 345 MB），可能要几分钟…"
        } else {
            "Downloading WE-Proton (~345 MB), this may take a few minutes…"
        }));
        jobs::send(Job::UpdateRun);
    }

    pub fn quit_app(self: Pin<&mut Self>) {
        let _ = jobs::events().send(Event::Quit);
    }

    pub fn clear_ui_events(mut self: Pin<&mut Self>) {
        self.as_mut().rust_mut().uiEvents = QString::from("");
    }

    pub fn startup_exe(self: Pin<&mut Self>) -> QString {
        QString::from(STARTUP.get().cloned().unwrap_or_default())
    }

    pub fn configure_exe(mut self: Pin<&mut Self>, exe: &QString) {
        let exe_str = exe.to_string();
        let prefix_path = crate::core::paths::default_prefix();
        // 桌面入口给的是 Linux 路径；也接受 C:\... 这样的 Windows 路径
        let looks_windows = exe_str.contains('\\') || exe_str.chars().nth(1) == Some(':');
        let exe_path = if looks_windows {
            scan::windows_path_to_linux(&prefix_path, &exe_str).unwrap_or_else(|| expand_path(&exe_str))
        } else {
            expand_path(&exe_str)
        };
        let key = exe_path.to_string_lossy().into_owned();
        let entry = ConfigEntry::read(&key).unwrap_or_else(|| {
            let mut entry = crate::core::conf::default_entry();
            entry.exe = key.clone();
            entry.prefix = prefix_path.to_string_lossy().into_owned();
            entry.runner = default_runner_for(&prefix_path);
            entry.name = scan::inferred_exe_name(&exe_path, Some(&prefix_path));
            entry
        });
        self.as_mut().emit_config(entry);
    }

    pub fn initial_page(self: Pin<&mut Self>) -> QString {
        let valid = ["apps", "linux", "procs"];
        let page = std::env::var("PROTONBOOST_PAGE").unwrap_or_else(|_| "apps".into());
        let page = page.rsplit('=').next().unwrap_or("apps").to_string();
        if valid.contains(&page.as_str()) {
            QString::from(page)
        } else {
            QString::from("apps")
        }
    }
}

fn default_runner_for(prefix: &std::path::Path) -> String {
    let from_prefix = crate::core::prefix::prefix_runner(prefix);
    if !from_prefix.is_empty() {
        return from_prefix;
    }
    engine_runners::for_prefix(prefix).map(|runner| runner.path).unwrap_or_default()
}

/// 界面上的运行器文案 → 运行器路径；识别不出时返回 None
fn resolve_runner(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    if value.contains('/') {
        return Some(value.to_string());
    }
    engine_runners::discover()
        .iter()
        .find(|runner| engine_runners::label(runner) == value)
        .map(|runner| runner.path.clone())
}
