// 应用扫描：Windows 快捷方式 → 应用列表；安装目录与 exe 评分
use crate::core::conf::{cache_file_for_path, read_key_values, collect_cache_entries};
use crate::core::lnk;
use crate::core::loc::zh;
use crate::core::paths::{app_log_dir, expand_path, home, normalized};
use crate::core::prefix::looks_like_wine_prefix;
use crate::core::steam::app_id_for_prefix;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub const GENERIC_EXE_NAMES: &[&str] = &[
    "app", "bootstrap", "client", "game", "launcher", "launcher_main", "main", "run", "start",
];
pub const GENERIC_DIR_NAMES: &[&str] = &[
    "bin", "build", "debug", "dist", "files", "release", "runtime", "runtimes", "win32", "win64",
    "x64", "x86",
];
pub const IGNORED_INSTALL_DIR_NAMES: &[&str] = &[
    "$recycle.bin", "common files", "desktop", "directx", "drivers", "installer", "microsoft",
    "microsoft shared", "package cache", "packages", "programdata", "redist", "redistributable",
    "temp", "tmp", "vc", "vcredist", "windows", "internet explorer", "microsoft.net",
    "modifiablewindowsapps", "windows mail", "steam", "windows media player", "windows nt",
    "windows photo viewer",
];
pub const LOW_VALUE_EXE_WORDS: &[&str] = &[
    "7z", "cefsubprocess", "crash", "crashreport", "crashreporter", "dxsetup", "helper", "install",
    "installer", "patch", "qtwebengineprocess", "redist", "repair", "report", "service", "setup",
    "unins", "uninstall", "unitycrashhandler", "update", "updater", "vc_redist", "vcredist",
];
pub const UNINSTALLER_WORDS: &[&str] = &["unins", "卸载"];

// ── 扫描出的应用条目 ─────────────────────────────────────────
#[derive(Clone, Debug, Default)]
pub struct AppEntry {
    pub name: String,
    pub display_name: String,
    pub source: String,
    pub path: String,
    pub target_exe: String,
    pub args: String,
    pub missing: bool,
    pub file: String,
    pub kind: String,
    pub last_used: f64,
    pub runner: String,
    pub prefix: String,
    pub program_args: String,
    pub gamescope: String,
    pub gamescope_fullscreen: String,
    pub gamescope_res: String,
    pub gamescope_fps: String,
    pub gamescope_fsr: String,
    pub gamescope_args: String,
    pub mangohud: String,
    pub wayland: String,
    pub env_vars: String,
    pub steam_appid: String,
}

pub fn app_key(prefix: &Path, path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("{}\0{}", prefix.to_string_lossy(), path.to_string_lossy()));
    format!("{:x}", hasher.finalize())[..10].to_string()
}

pub fn app_identity(prefix: &Path, path: &Path) -> String {
    app_key(prefix, path)
}

pub fn app_display_name(app: &AppEntry) -> String {
    if !app.display_name.is_empty() {
        app.display_name.clone()
    } else if !app.name.is_empty() {
        app.name.clone()
    } else {
        "windows-app".into()
    }
}

pub fn app_is_uninstaller(app: &AppEntry) -> bool {
    let stem = Path::new(if app.target_exe.is_empty() { &app.path } else { &app.target_exe })
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let display = app_display_name(app);
    let names = [app.name.as_str(), display.as_str(), stem];
    names.iter().any(|name| {
        let lower = name.to_lowercase();
        UNINSTALLER_WORDS.iter().any(|word| lower.contains(word))
    })
}

/// 应用最近一次启动：日志目录的时间
pub fn app_last_used(prefix: &Path, path: &Path) -> f64 {
    let dir = app_log_dir(&app_identity(prefix, path));
    dir.metadata()
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub fn mark_app_started(prefix: &Path, path: &Path) {
    let dir = app_log_dir(&app_identity(prefix, path));
    let _ = std::fs::create_dir_all(&dir);
    let now = std::time::SystemTime::now();
    let _ = std::fs::OpenOptions::new().write(true).open(&dir).and_then(|f| {
        f.set_modified(now)
    });
}

fn collation_key(text: &str) -> String {
    // 中文名按本地习惯排序：这里直接用小写即可，locale 排序交给后续可改进
    text.to_lowercase()
}

pub fn app_sort_key(app: &AppEntry) -> (bool, bool, std::cmp::Reverse<u64>, bool, String) {
    (
        app.missing,
        app_is_uninstaller(app),
        std::cmp::Reverse(app.last_used as u64),
        app.kind != "shortcut",
        collation_key(&app_display_name(app)),
    )
}

// ── Wine 用户目录与显示路径 ──────────────────────────────────
pub fn wine_user_dirs(drive_c: &Path) -> Vec<PathBuf> {
    let users = drive_c.join("users");
    let Ok(read) = std::fs::read_dir(&users) else {
        return Vec::new();
    };
    let mut names: Vec<String> = read
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let user = std::env::var("USER").unwrap_or_default();
    let mut preferred = Vec::new();
    for name in ["steamuser", user.as_str()] {
        if !name.is_empty() && names.contains(&name.to_string()) {
            preferred.push(name.to_string());
        }
    }
    let rest: Vec<String> = names
        .into_iter()
        .filter(|name| !preferred.contains(name) && name.to_lowercase() != "public")
        .collect();
    preferred
        .into_iter()
        .chain(rest)
        .map(|name| users.join(name))
        .collect()
}

/// 程序所在位置：前缀里按 Windows 的叫法
pub fn windows_display_path(prefix: &Path, path: &Path) -> String {
    let prefix = expand_path(&prefix.to_string_lossy());
    let path = expand_path(&path.to_string_lossy());
    let drive_c = prefix.join("pfx/drive_c");
    match path.strip_prefix(&drive_c) {
        Ok(rel) => format!("C:\\{}", rel.to_string_lossy().replace('/', "\\")),
        Err(_) => path.to_string_lossy().into_owned(),
    }
}


// ── Windows 路径 → Linux 路径 ────────────────────────────────
pub fn windows_path_to_linux(prefix: &Path, value: &str) -> Option<PathBuf> {
    let value = value.trim().trim_matches('"');
    if value.is_empty() {
        return None;
    }
    let drive_c = prefix.join("pfx/drive_c");
    let users = wine_user_dirs(&drive_c);
    let first_user = users
        .first()
        .map(|p| p.file_name().unwrap_or_default().to_string_lossy().into_owned())
        .unwrap_or_else(|| "steamuser".into());
    let profile = format!("C:\\users\\{first_user}");
    let appdata = format!("{profile}\\AppData\\Roaming");
    let localappdata = format!("{profile}\\AppData\\Local");
    let env_map: HashMap<&str, String> = HashMap::from([
        ("systemroot", "C:\\windows".to_string()),
        ("windir", "C:\\windows".to_string()),
        ("systemdrive", "C:".to_string()),
        ("programfiles", "C:\\Program Files".to_string()),
        ("programfiles(x86)", "C:\\Program Files (x86)".to_string()),
        ("programw6432", "C:\\Program Files".to_string()),
        ("programdata", "C:\\ProgramData".to_string()),
        ("allusersprofile", "C:\\ProgramData".to_string()),
        ("public", "C:\\users\\Public".to_string()),
        ("userprofile", profile.clone()),
        ("appdata", appdata),
        ("localappdata", localappdata),
    ]);
    let mut result = String::new();
    let mut rest = value;
    while let Some(start) = rest.find('%') {
        result.push_str(&rest[..start]);
        let Some(end) = rest[start + 1..].find('%') else {
            result.push('%');
            rest = &rest[start + 1..];
            break;
        };
        let name = rest[start + 1..start + 1 + end].to_lowercase();
        result.push_str(&env_map.get(name.as_str()).cloned().unwrap_or_else(|| rest[start..start + end + 2].to_string()));
        rest = &rest[start + end + 2..];
    }
    result.push_str(rest);
    let value = result.replace('/', "\\");
    let bytes = value.as_bytes();
    if bytes.len() >= 3 && bytes[1] == b':' && bytes[2] == b'\\' {
        let drive = bytes[0].to_ascii_lowercase() as char;
        let tail = value[3..].replace('\\', "/");
        return Some(path_on_disk(match drive {
            'c' => drive_c.join(tail),
            _ => prefix.join("pfx/dosdevices").join(format!("{drive}:")).join(tail),
        }));
    }
    let candidate = expand_path(&value);
    if candidate.is_absolute() {
        Some(candidate)
    } else {
        None
    }
}

/// 盘上的实际拼法：Windows 不分大小写，快捷方式里的写法可能不同
pub fn path_on_disk(path: PathBuf) -> PathBuf {
    if path.exists() {
        return path;
    }
    let mut current = PathBuf::from(path.components().next().map(|c| c.as_os_str()).unwrap_or_default());
    for part in path.components().skip(1) {
        let part = part.as_os_str().to_string_lossy().into_owned();
        let candidate = current.join(&part);
        if !candidate.exists() {
            let Ok(read) = std::fs::read_dir(&current) else {
                return path;
            };
            let lower = part.to_lowercase();
            match read
                .flatten()
                .find(|entry| entry.file_name().to_string_lossy().to_lowercase() == lower)
            {
                Some(entry) => current = entry.path(),
                None => return path,
            }
        } else {
            current = candidate;
        }
    }
    current
}

// ── 快捷方式来源目录 ─────────────────────────────────────────
pub fn shortcut_roots(prefix: &Path) -> Vec<(String, PathBuf)> {
    let pfx = prefix.join("pfx/drive_c");
    let users = wine_user_dirs(&pfx);
    let mut roots = Vec::new();
    for user in &users {
        roots.push(("Start Menu".to_string(), user.join("AppData/Roaming/Microsoft/Windows/Start Menu/Programs")));
    }
    roots.push(("All Users".to_string(), pfx.join("ProgramData/Microsoft/Windows/Start Menu/Programs")));
    for user in &users {
        roots.push(("Desktop".to_string(), user.join("Desktop")));
    }
    roots.push(("Public Desktop".to_string(), pfx.join("users/Public/Desktop")));
    roots
}

fn collect_lnk_files(root: &Path, out: &mut Vec<PathBuf>) {
    let Ok(read) = std::fs::read_dir(root) else {
        return;
    };
    let mut entries: Vec<PathBuf> = read.flatten().map(|entry| entry.path()).collect();
    entries.sort_by_key(|path| path.to_string_lossy().to_lowercase());
    for path in entries {
        if path.is_dir() {
            collect_lnk_files(&path, out);
        } else if path.extension().is_some_and(|ext| ext.eq_ignore_ascii_case("lnk")) {
            out.push(path);
        }
    }
}

// ── 应用扫描主流程 ───────────────────────────────────────────
pub fn scan_apps(prefix: &Path) -> Vec<AppEntry> {
    let prefix = expand_path(&prefix.to_string_lossy());
    let mut shortcuts: HashMap<String, AppEntry> = HashMap::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut shortcut_targets: HashSet<String> = HashSet::new();

    for (source, root) in shortcut_roots(&prefix) {
        if !root.is_dir() {
            continue;
        }
        let mut lnks = Vec::new();
        collect_lnk_files(&root, &mut lnks);
        for link in lnks {
            let real = normalized(&link).to_string_lossy().into_owned();
            if !seen.insert(real.clone()) {
                continue;
            }
            let info = lnk::parse_lnk(&link);
            let target_path = if info.target.is_empty() {
                None
            } else {
                windows_path_to_linux(&prefix, &info.target)
            };
            if let Some(target) = &target_path {
                shortcut_targets.insert(normalized(target).to_string_lossy().into_owned());
            }
            let cache_path = cache_file_for_path(&link.to_string_lossy());
            let shortcut_cache = read_key_values(&cache_path);
            let source_value = source.clone();
            let mut app = AppEntry {
                name: link.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string(),
                display_name: shortcut_cache.get("name").cloned().unwrap_or_else(|| {
                    link.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
                }),
                source: source_value,
                path: link.to_string_lossy().into_owned(),
                target_exe: target_path
                    .as_ref()
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default(),
                args: info.args.clone(),
                missing: target_path.as_ref().is_some_and(|p| !p.exists()),
                file: if shortcut_cache.is_empty() {
                    String::new()
                } else {
                    cache_path.to_string_lossy().into_owned()
                },
                kind: "shortcut".into(),
                last_used: app_last_used(&prefix, &link),
                ..Default::default()
            };
            for key in ["runner", "program_args", "gamescope", "gamescope_fullscreen", "gamescope_res",
                        "gamescope_fps", "gamescope_fsr", "gamescope_args", "mangohud", "wayland",
                        "env_vars", "steam_appid"] {
                if let Some(value) = shortcut_cache.get(key) {
                    match key {
                        "runner" => app.runner = value.clone(),
                        "program_args" => app.program_args = value.clone(),
                        "gamescope" => app.gamescope = value.clone(),
                        "gamescope_fullscreen" => app.gamescope_fullscreen = value.clone(),
                        "gamescope_res" => app.gamescope_res = value.clone(),
                        "gamescope_fps" => app.gamescope_fps = value.clone(),
                        "gamescope_fsr" => app.gamescope_fsr = value.clone(),
                        "gamescope_args" => app.gamescope_args = value.clone(),
                        "mangohud" => app.mangohud = value.clone(),
                        "wayland" => app.wayland = value.clone(),
                        "env_vars" => app.env_vars = value.clone(),
                        "steam_appid" => app.steam_appid = value.clone(),
                        _ => {}
                    }
                }
            }
            let key = match &target_path {
                Some(target) => format!("{}\0{}", normalized(target).to_string_lossy().to_lowercase(), app.args),
                None => real,
            };
            let replace = match shortcuts.get(&key) {
                None => true,
                Some(listed) => !app.file.is_empty() && listed.file.is_empty(),
            };
            let last_used = match shortcuts.get(&key) {
                Some(listed) => listed.last_used.max(app.last_used),
                None => app.last_used,
            };
            if replace {
                app.last_used = last_used;
                shortcuts.insert(key, app);
            } else if let Some(listed) = shortcuts.get_mut(&key) {
                listed.last_used = last_used;
            }
        }
    }

    let mut apps: Vec<AppEntry> = shortcuts.into_values().collect();
    for app in &mut apps {
        if !app.target_exe.is_empty() {
            app.last_used = app
                .last_used
                .max(app_last_used(&prefix, Path::new(&app.target_exe)));
        }
    }

    for entry in collect_cache_entries() {
        if entry.prefix.is_empty() || entry.exe.is_empty() {
            continue;
        }
        if expand_path(&entry.prefix) != prefix {
            continue;
        }
        let exe_path = expand_path(&entry.exe);
        let real = normalized(&exe_path).to_string_lossy().into_owned();
        if seen.contains(&real) || shortcut_targets.contains(&real) {
            continue;
        }
        seen.insert(real);
        let display_name = if entry.name.is_empty() {
            inferred_exe_name(&exe_path, Some(&prefix))
        } else {
            entry.name.clone()
        };
        apps.push(AppEntry {
            name: exe_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string(),
            display_name,
            source: if entry.source.is_empty() { "configured".into() } else { entry.source.clone() },
            path: exe_path.to_string_lossy().into_owned(),
            runner: entry.runner.clone(),
            prefix: if entry.prefix.is_empty() { prefix.to_string_lossy().into_owned() } else { entry.prefix.clone() },
            file: entry.file.clone(),
            program_args: entry.program_args.clone(),
            gamescope: if entry.gamescope { "1".into() } else { "0".into() },
            gamescope_fullscreen: if entry.gamescope_fullscreen { "1".into() } else { "0".into() },
            gamescope_res: entry.gamescope_res.clone(),
            gamescope_fps: entry.gamescope_fps.clone(),
            gamescope_fsr: if entry.gamescope_fsr { "1".into() } else { "0".into() },
            gamescope_args: entry.gamescope_args.clone(),
            mangohud: if entry.mangohud { "1".into() } else { "0".into() },
            wayland: if entry.wayland { "1".into() } else { "0".into() },
            env_vars: entry.env_vars.clone(),
            steam_appid: entry.steam_appid.clone(),
            kind: "saved-config".into(),
            last_used: app_last_used(&prefix, &exe_path),
            ..Default::default()
        });
    }

    apps.sort_by_key(app_sort_key);
    apps
}

// ── exe 名称推断与评分 ───────────────────────────────────────
fn version_like(value: &str) -> bool {
    let replaced = value.replace(['_', '-'], ".");
    let parts: Vec<&str> = replaced.split('.').collect();
    parts.len() > 1 && parts.iter().all(|part| part.is_empty() || part.chars().all(|c| c.is_ascii_digit()))
}

pub fn under_known_install_root(prefix: &Path, path: &Path) -> bool {
    let path = expand_path(&path.to_string_lossy());
    windows_install_roots(prefix)
        .iter()
        .any(|root| path.starts_with(expand_path(&root.to_string_lossy())))
}

/// exe 名太泛（game.exe 之类）时用上一级目录名
pub fn inferred_exe_name(path: &Path, prefix: Option<&Path>) -> String {
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    if !GENERIC_EXE_NAMES.contains(&stem.to_lowercase().as_str()) {
        return stem;
    }
    let Some(prefix) = prefix else {
        return stem;
    };
    if !under_known_install_root(prefix, path) {
        return stem;
    }
    for parent in path.ancestors().skip(1) {
        let name = parent.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let lower = name.to_lowercase();
        if name.is_empty() || GENERIC_DIR_NAMES.contains(&lower.as_str()) || version_like(name) {
            continue;
        }
        if matches!(lower.as_str(), "program files" | "program files (x86)" | "drive_c" | "pfx") {
            break;
        }
        return name.to_string();
    }
    stem
}

pub fn windows_install_roots(prefix: &Path) -> Vec<PathBuf> {
    let pfx = prefix.join("pfx/drive_c");
    let mut roots = vec![pfx.join("Program Files"), pfx.join("Program Files (x86)")];
    for user in wine_user_dirs(&pfx) {
        roots.push(user.join("AppData/Local"));
        roots.push(user.join("AppData/Roaming"));
    }
    roots
}

fn normalize_match_name(value: &str) -> String {
    value.chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_lowercase()
}

fn is_ignored_install_dir(path: &Path) -> bool {
    let lower = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_lowercase();
    if lower.is_empty() || IGNORED_INSTALL_DIR_NAMES.contains(&lower.as_str()) {
        return true;
    }
    lower.starts_with("windows ")
        || ["redist", "vcredist", "webview", "crashreport", "uninstall"]
            .iter()
            .any(|word| lower.contains(word))
}

fn is_low_value_exe(path: &Path) -> bool {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_lowercase()
        .replace(['-', ' '], "_");
    LOW_VALUE_EXE_WORDS.iter().any(|word| stem.contains(word))
}

pub fn file_size_label(path: &Path) -> String {
    let Ok(size) = std::fs::metadata(path).map(|m| m.len()) else {
        return String::new();
    };
    if size >= 1024 * 1024 {
        format!("{:.1} MB", size as f64 / 1024.0 / 1024.0)
    } else if size >= 1024 {
        format!("{} KB", size / 1024)
    } else {
        format!("{size} B")
    }
}

fn safe_relative_path(root: &Path, path: &Path) -> String {
    match path.strip_prefix(root) {
        Ok(rel) => {
            let parent = rel.parent().unwrap_or(Path::new(""));
            let text = parent.to_string_lossy();
            if text.is_empty() {
                if zh() { "根目录".into() } else { "root".into() }
            } else {
                text.into_owned()
            }
        }
        Err(_) => path.to_string_lossy().into_owned(),
    }
}

#[derive(Clone, Debug)]
pub struct ExeEntry {
    pub path: PathBuf,
    pub name: String,
    pub low_value: bool,
    pub score: i32,
    pub detail: String,
}

pub fn scan_exes_in_dir(directory: &Path, limit: usize) -> Vec<ExeEntry> {
    let directory = expand_path(&directory.to_string_lossy());
    if !directory.is_dir() {
        return Vec::new();
    }
    let root_name = normalize_match_name(
        directory.file_name().and_then(|n| n.to_str()).unwrap_or(""),
    );
    let mut files = Vec::new();
    collect_exe_files(&directory, limit, &mut files);
    let mut result: Vec<ExeEntry> = files
        .into_iter()
        .map(|exe| {
            let mut score = 0;
            let stem = normalize_match_name(exe.file_stem().and_then(|s| s.to_str()).unwrap_or(""));
            if !stem.is_empty() && !root_name.is_empty()
                && (stem == root_name || stem.contains(&root_name) || root_name.contains(&stem))
            {
                score += 80;
            }
            if exe.parent() == Some(directory.as_path()) {
                score += 35;
            }
            let parent_name = exe
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_lowercase();
            if matches!(parent_name.as_str(), "bin" | "game" | "games" | "launcher" | "client") {
                score += 12;
            }
            if std::fs::metadata(&exe).map(|m| m.len() >= 1024 * 1024).unwrap_or(false) {
                score += 10;
            }
            let low_value = is_low_value_exe(&exe);
            if low_value {
                score -= 100;
            }
            let name = exe.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
            let detail = format!(
                "{} · {}",
                safe_relative_path(&directory, &exe),
                file_size_label(&exe)
            )
            .trim_matches(|c| c == '·' || c == ' ')
            .to_string();
            ExeEntry { path: exe, name, low_value, score, detail }
        })
        .collect();
    result.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then_with(|| a.low_value.cmp(&b.low_value))
            .then_with(|| {
                a.path
                    .to_string_lossy()
                    .to_lowercase()
                    .cmp(&b.path.to_string_lossy().to_lowercase())
            })
    });
    result
}

fn collect_exe_files(directory: &Path, limit: usize, out: &mut Vec<PathBuf>) {
    if out.len() >= limit {
        return;
    }
    let Ok(read) = std::fs::read_dir(directory) else {
        return;
    };
    let mut entries: Vec<PathBuf> = read.flatten().map(|entry| entry.path()).collect();
    entries.sort_by_key(|path| path.to_string_lossy().to_lowercase());
    for path in entries {
        if path.is_dir() {
            collect_exe_files(&path, limit, out);
        } else if path.extension().is_some_and(|ext| ext.eq_ignore_ascii_case("exe")) {
            out.push(path);
            if out.len() >= limit {
                return;
            }
        }
    }
}

pub fn app_path_under_dir(app: &AppEntry, directory: &Path) -> bool {
    for value in [&app.path, &app.target_exe] {
        if value.is_empty() {
            continue;
        }
        if expand_path(value).starts_with(directory) {
            return true;
        }
    }
    false
}

#[derive(Clone, Debug)]
pub struct DirEntry {
    pub name: String,
    pub path: PathBuf,
    pub exe_count: usize,
    pub linked_count: usize,
    pub mtime: f64,
}

pub fn scan_install_dirs(prefix: &Path, apps: &[AppEntry]) -> Vec<DirEntry> {
    let prefix = expand_path(&prefix.to_string_lossy());
    let mut roots = windows_install_roots(&prefix);
    roots.push(prefix.join("pfx/drive_c/ProgramData"));
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    for root in roots {
        if !root.is_dir() {
            continue;
        }
        let Ok(read) = std::fs::read_dir(&root) else {
            continue;
        };
        let mut children: Vec<PathBuf> = read
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.is_dir())
            .collect();
        children.sort_by_key(|path| path.to_string_lossy().to_lowercase());
        for child in children {
            let child = normalized(&child);
            if !seen.insert(child.to_string_lossy().into_owned()) || is_ignored_install_dir(&child) {
                continue;
            }
            let exes = scan_exes_in_dir(&child, 120);
            let linked = apps.iter().filter(|app| app_path_under_dir(app, &child)).count();
            if exes.is_empty() && linked == 0 {
                continue;
            }
            let mtime = child
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            result.push(DirEntry {
                name: child
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("")
                    .to_string(),
                path: child,
                exe_count: exes.len(),
                linked_count: linked,
                mtime,
            });
        }
    }
    result.sort_by(|a, b| {
        b.linked_count
            .cmp(&a.linked_count)
            .then_with(|| b.mtime.partial_cmp(&a.mtime).unwrap_or(std::cmp::Ordering::Equal))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    result
}

// ── 删除保护 ────────────────────────────────────────────────
pub fn can_delete_install_dir(prefix: &Path, directory: &Path) -> bool {
    let prefix = expand_path(&prefix.to_string_lossy());
    let directory = expand_path(&directory.to_string_lossy());
    let mut roots = windows_install_roots(&prefix);
    roots.push(prefix.join("pfx/drive_c/ProgramData"));
    let blocked: Vec<PathBuf> = vec![
        prefix.clone(),
        prefix.join("pfx"),
        prefix.join("pfx/drive_c"),
        prefix.join("pfx/drive_c/Program Files"),
        prefix.join("pfx/drive_c/Program Files (x86)"),
        prefix.join("pfx/drive_c/ProgramData"),
        prefix.join("pfx/drive_c/users"),
        prefix.join("pfx/drive_c/windows"),
    ];
    if blocked.contains(&directory) || directory.is_symlink() || !directory.is_dir() {
        return false;
    }
    for root in roots {
        let root = expand_path(&root.to_string_lossy());
        if let Ok(rel) = directory.strip_prefix(&root) {
            let parts: Vec<_> = rel.components().collect();
            return !parts.is_empty()
                && !matches!(parts[0], std::path::Component::CurDir | std::path::Component::ParentDir);
        }
    }
    false
}

pub fn can_delete_prefix(prefix: &Path) -> bool {
    let prefix = expand_path(&prefix.to_string_lossy());
    let home = home();
    let blocked: Vec<PathBuf> = vec![
        home.clone(),
        home.join(".local"),
        home.join(".local/share"),
        home.join(".local/share/Steam"),
        home.join(".local/share/Steam/steamapps"),
        home.join(".local/share/Steam/steamapps/compatdata"),
        home.join(".steam"),
        home.join(".steam/steam"),
        home.join(".steam/steam/steamapps"),
        home.join(".steam/steam/steamapps/compatdata"),
        home.join(".var"),
        home.join(".var/app"),
        home.join(".var/app/com.valvesoftware.Steam"),
        home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam"),
        home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps"),
        home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata"),
        PathBuf::from("/"),
    ];
    prefix.is_dir()
        && !prefix.is_symlink()
        && !blocked.contains(&prefix)
        && (looks_like_wine_prefix(&prefix) || crate::core::prefix::looks_like_compat_prefix(&prefix))
}

/// 应用的所有配置文件：自己的、快捷方式与程序的、同程序其他路径拼法的
pub fn app_cache_files(prefix: &Path, app: &AppEntry) -> Vec<PathBuf> {
    let mut paths = vec![PathBuf::from(&app.path)];
    if !app.target_exe.is_empty() {
        paths.push(PathBuf::from(&app.target_exe));
    }
    let mut files: Vec<PathBuf> = Vec::new();
    if !app.file.is_empty() {
        files.push(PathBuf::from(&app.file));
    }
    for path in &paths {
        files.push(cache_file_for_path(&path.to_string_lossy()));
    }
    let real: HashSet<String> = paths
        .iter()
        .map(|path| normalized(&expand_path(&path.to_string_lossy())).to_string_lossy().into_owned())
        .collect();
    if let Ok(read) = std::fs::read_dir(crate::core::paths::association_dir()) {
        for entry in read.flatten() {
            let conf = entry.path();
            if conf.extension().is_none_or(|ext| ext != "conf") {
                continue;
            }
            let data = read_key_values(&conf);
            let Some(exe) = data.get("exe") else {
                continue;
            };
            if data
                .get("prefix")
                .map(|p| expand_path(p) == expand_path(&prefix.to_string_lossy()))
                .unwrap_or_else(|| expand_path(&home().join(".proton").to_string_lossy()) == expand_path(&prefix.to_string_lossy()))
            {
                continue;
            }
            let expanded = normalized(&expand_path(exe)).to_string_lossy().into_owned();
            if real.contains(&expanded) {
                files.push(conf);
            }
        }
    }
    files
}

/// Steam 前缀标注（进程页用）
pub fn process_prefix_label(prefix: &Path, names: &HashMap<String, String>) -> String {
    let appid = app_id_for_prefix(prefix);
    if !appid.is_empty() {
        if let Some(name) = names.get(&appid) {
            return format!("{name} · Steam");
        }
        return "Steam".into();
    }
    prefix.to_string_lossy().into_owned()
}
