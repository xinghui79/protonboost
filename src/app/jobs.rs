// 任务调度：工作线程做扫描/图标/子进程，结果经通道回主线程
use crate::core::conf::ConfigEntry;
use crate::core::procs;
use crate::core::scan::{self, AppEntry};
use crate::engine::launch::Request;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Mutex, OnceLock};

#[derive(Clone)]
pub struct AppRow {
    pub app_id: String,
    pub display_name: String,
    pub detail: String,
    pub icon: String,
    pub running: bool,
    pub has_log: bool,
    pub can_config: bool,
    pub is_steam: bool,
    pub steam_appid: String,
    pub kind: String,
    pub path: String,
    pub runner: String,
}

pub struct DirRow {
    pub name: String,
    pub path: String,
    pub detail: String,
    pub can_delete: bool,
}

pub struct ProcRow {
    pub pid: i32,
    pub name: String,
    pub age: String,
    pub command: String,
}

pub struct LinuxAppRow {
    pub id: String,
    pub name: String,
    pub path: String,
    pub icon: String,
}

pub struct ExeRow {
    pub path: String,
    pub name: String,
    pub detail: String,
}

pub enum Job {
    Apps { req: u64, prefix: PathBuf },
    Dirs { req: u64, prefix: PathBuf },
    Procs { req: u64, prefix: PathBuf },
    LinuxApps { req: u64 },
    Exes { prefix: PathBuf, dir: PathBuf },
    Launch { request: Request, label: String },
    LaunchCommand { prefix: PathBuf, argv: Vec<String>, label: String },
    UpdateCheck,
    UpdateRun,
    Icon { req: u64, app_id: String, prefix: PathBuf, path: String, kind: String, name: String },
}

pub enum ResultMsg {
    Apps { req: u64, items: Vec<AppRow>, apps: Vec<AppEntry> },
    Dirs { req: u64, items: Vec<DirRow> },
    Procs { req: u64, items: Vec<ProcRow> },
    LinuxApps { req: u64, items: Vec<LinuxAppRow> },
    Exes { title: String, items: Vec<ExeRow> },
    Launch { label: String, result: Result<Vec<String>, String> },
    UpdateCheck { text: String },
    UpdateRun { success: bool },
    Icon { req: u64, app_id: String, icon: String },
}

/// 后端事件：托盘、延时刷新等
pub enum Event {
    ToggleWindow,
    Quit,
    Refresh,
}

static JOBS: OnceLock<Sender<Job>> = OnceLock::new();
static RESULTS: OnceLock<Mutex<Receiver<ResultMsg>>> = OnceLock::new();
static EVENTS: OnceLock<Sender<Event>> = OnceLock::new();
static EVENT_RX: OnceLock<Mutex<Receiver<Event>>> = OnceLock::new();

/// 初始化通道与工作线程；在 main 里最先调用
pub fn init() {
    let (job_tx, job_rx) = channel::<Job>();
    let (result_tx, result_rx) = channel::<ResultMsg>();
    let (event_tx, event_rx) = channel::<Event>();
    let _ = JOBS.set(job_tx);
    let _ = RESULTS.set(Mutex::new(result_rx));
    let _ = EVENTS.set(event_tx);
    let _ = EVENT_RX.set(Mutex::new(event_rx));

    let job_rx = std::sync::Arc::new(Mutex::new(job_rx));
    for _ in 0..2 {
        let job_rx = std::sync::Arc::clone(&job_rx);
        let result_tx = result_tx.clone();
        std::thread::spawn(move || loop {
            let job = {
                let guard = match job_rx.lock() {
                    Ok(guard) => guard,
                    Err(_) => return,
                };
                guard.recv()
            };
            match job {
                Ok(job) => handle(job, &result_tx),
                Err(_) => return,
            }
        });
    }
}

pub fn events() -> &'static Sender<Event> {
    EVENTS.get().expect("jobs::init() must run first")
}

pub fn send(job: Job) {
    if let Some(sender) = JOBS.get() {
        let _ = sender.send(job);
    }
}

/// 主线程轮询：取一条扫描结果
pub fn try_result() -> Option<ResultMsg> {
    let receiver = RESULTS.get()?;
    let guard = receiver.lock().ok()?;
    guard.try_recv().ok()
}

/// 主线程轮询：取一条事件
pub fn try_event() -> Option<Event> {
    let receiver = EVENT_RX.get()?;
    let guard = receiver.lock().ok()?;
    guard.try_recv().ok()
}

/// 延时发刷新事件（启动程序后等一会再刷新列表）
pub fn refresh_after(milliseconds: u64) {
    let events = events().clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(milliseconds));
        let _ = events.send(Event::Refresh);
    });
}

fn handle(job: Job, tx: &Sender<ResultMsg>) {
    match job {
        Job::Apps { req, prefix } => {
            let apps = scan::scan_apps(&prefix);
            let running = procs::running_apps_for_prefix(&prefix);
            let items = build_app_rows(&prefix, &apps, &running);
            let _ = tx.send(ResultMsg::Apps { req, items: items.clone(), apps: apps.clone() });
            // 图标后台补齐：没有现成 PNG 缓存的逐个提取
            for (app, row) in apps.iter().zip(items.iter()) {
                if row.icon.is_empty() {
                    send(Job::Icon {
                        req,
                        app_id: row.app_id.clone(),
                        prefix: prefix.clone(),
                        path: app.path.clone(),
                        kind: app.kind.clone(),
                        name: app.name.clone(),
                    });
                }
            }
        }
        Job::Dirs { req, prefix } => {
            let apps = scan::scan_apps(&prefix);
            let dirs = scan::scan_install_dirs(&prefix, &apps);
            let items: Vec<DirRow> = dirs
                .iter()
                .map(|dir| DirRow {
                    name: dir.name.clone(),
                    path: dir.path.to_string_lossy().into_owned(),
                    detail: format!(
                        "{} · {} 个 exe · 已关联应用 {} 个",
                        scan::windows_display_path(&prefix, &dir.path),
                        dir.exe_count,
                        dir.linked_count
                    ),
                    can_delete: scan::can_delete_install_dir(&prefix, &dir.path),
                })
                .collect();
            let _ = tx.send(ResultMsg::Dirs { req, items });
        }
        Job::Procs { req, prefix } => {
            let items: Vec<ProcRow> = procs::scan_processes(&prefix)
                .into_iter()
                .map(|proc| ProcRow {
                    pid: proc.pid,
                    name: proc.name,
                    age: proc.age,
                    command: proc.command,
                })
                .collect();
            let _ = tx.send(ResultMsg::Procs { req, items });
        }
        Job::LinuxApps { req } => {
            let items: Vec<LinuxAppRow> = scan_linux_desktops()
                .into_iter()
                .map(|(id, name, path, icon)| LinuxAppRow { id, name, path, icon })
                .collect();
            let _ = tx.send(ResultMsg::LinuxApps { req, items });
        }
        Job::Exes { prefix, dir } => {
            let exes = scan::scan_exes_in_dir(&dir, 300);
            let items: Vec<ExeRow> = exes
                .into_iter()
                .map(|exe| ExeRow {
                    path: exe.path.to_string_lossy().into_owned(),
                    name: exe.name,
                    detail: exe.detail,
                })
                .collect();
            let _ = tx.send(ResultMsg::Exes {
                title: scan::windows_display_path(&prefix, &dir),
                items,
            });
        }
        Job::UpdateCheck => {
            let text = crate::engine::update::describe(&crate::engine::update::check());
            let _ = tx.send(ResultMsg::UpdateCheck { text });
        }
        Job::UpdateRun => {
            let candidates = crate::engine::update::check();
            let success = crate::engine::update::install(&candidates).is_ok();
            let _ = tx.send(ResultMsg::UpdateRun { success });
        }
        Job::Launch { request, label } => {
            let result = crate::engine::launch::launch(&request, crate::core::loc::zh())
                .map(|report| {
                    scan::mark_app_started(&request.prefix, &request.target);
                    report.notes
                });
            let _ = tx.send(ResultMsg::Launch { label, result });
        }
        Job::LaunchCommand { prefix, argv, label } => {
            let result = crate::engine::launch::run_command(&prefix, &argv);
            let _ = tx.send(ResultMsg::Launch {
                label,
                result: result.map(|_| Vec::new()),
            });
        }
        Job::Icon { req, app_id, prefix, path, kind, name } => {
            let app = AppEntry {
                path,
                name,
                kind,
                ..Default::default()
            };
            let icon = crate::core::icons::icon_for_app(&prefix, &app, None);
            let _ = tx.send(ResultMsg::Icon { req, app_id, icon });
        }
    }
}

fn build_app_rows(
    prefix: &std::path::Path,
    apps: &[AppEntry],
    running: &HashMap<String, (Vec<i32>, String, String)>,
) -> Vec<AppRow> {
    apps.iter()
        .map(|app| {
            let app_id = scan::app_identity(prefix, std::path::Path::new(&app.path));
            let is_running = running.contains_key(&app_id);
            let log = match running.get(&app_id) {
                Some((_, log, _)) if !log.is_empty() => Some(PathBuf::from(log)),
                _ => crate::core::paths::latest_log_for_app(&app_id),
            };
            let location = scan::app_location(prefix, app);
            let detail = if app.missing {
                format!("目标不存在 · {location}")
            } else {
                location
            };
            let detail = if !app.steam_appid.is_empty() {
                format!("Steam · {detail}")
            } else {
                detail
            };
            AppRow {
                app_id,
                display_name: scan::app_display_name(app),
                detail,
                icon: String::new(),
                running: is_running,
                has_log: log.is_some_and(|path| path.exists()),
                can_config: matches!(app.kind.as_str(), "saved-config" | "shortcut"),
                is_steam: !app.steam_appid.is_empty(),
                steam_appid: app.steam_appid.clone(),
                kind: app.kind.clone(),
                path: app.path.clone(),
                runner: app.runner.clone(),
            }
        })
        .collect()
}

/// [Desktop Entry] 段解析：跳过其他段，同键取第一个值
fn read_desktop_entry(path: &std::path::Path) -> Option<HashMap<String, String>> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut map = HashMap::new();
    let mut in_entry = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_entry = trimmed == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once('=') {
            map.entry(key.trim().to_string())
                .or_insert_with(|| value.trim().to_string());
        }
    }
    Some(map)
}

/// 桌面入口扫描：可启动的 Linux 程序（排除终端与 winrun 自己的）
fn scan_linux_desktops() -> Vec<(String, String, String, String)> {
    let mut seen: HashMap<String, (String, String, String, String)> = HashMap::new();
    let home = crate::core::paths::home();
    let bases = [
        PathBuf::from("/usr/local/share/applications"),
        PathBuf::from("/usr/share/applications"),
        home.join(".local/share/applications"),
    ];
    for base in bases {
        let Ok(read) = std::fs::read_dir(&base) else {
            continue;
        };
        let mut files: Vec<PathBuf> = read.flatten().map(|entry| entry.path()).collect();
        files.sort();
        for file in files {
            if file.extension().is_none_or(|ext| ext != "desktop") {
                continue;
            }
            let Some(section) = read_desktop_entry(&file) else {
                continue;
            };
            if section.get("Type").map(|t| t != "Application").unwrap_or(false) {
                continue;
            }
            if truthy(section.get("NoDisplay"))
                || truthy(section.get("Hidden"))
                || truthy(section.get("Terminal"))
            {
                continue;
            }
            let exec = section.get("Exec").cloned().unwrap_or_default();
            if exec.trim().is_empty() || exec.contains("winrun") || exec.contains("proton-wrapper") {
                continue;
            }
            let id = file
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            let name = section
                .get("Name[zh_CN]")
                .or_else(|| section.get("Name"))
                .cloned()
                .unwrap_or_else(|| id.clone());
            let icon = section.get("Icon").cloned().unwrap_or_default();
            let path = file.to_string_lossy().into_owned();
            seen.entry(id.clone()).or_insert((id, name, path, icon));
        }
    }
    let mut result: Vec<(String, String, String, String)> = seen.into_values().collect();
    result.sort_by(|a, b| a.1.to_lowercase().cmp(&b.1.to_lowercase()));
    result
}

fn truthy(value: Option<&String>) -> bool {
    value.is_some_and(|value| value.eq_ignore_ascii_case("true") || value == "1")
}

// ConfigEntry 在 ResultMsg 相关流程里保留完整类型，供后续扩展
#[allow(dead_code)]
fn _entry_type_hint(_: &ConfigEntry) {}
