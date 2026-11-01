// 图标：从 exe/ico 提取并转 PNG 缓存；名字相近的图标搜索
use crate::core::paths::{expand_path, gui_icon_dir, which};
use crate::core::scan::AppEntry;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

pub fn safe_filename(value: &str) -> String {
    let mut cleaned = String::new();
    for char in value.chars() {
        if char.is_alphanumeric() || matches!(char, '.' | '-' | '_') {
            cleaned.push(char);
        } else if char.is_whitespace() {
            cleaned.push('-');
        } else {
            cleaned.push('_');
        }
    }
    let trimmed = cleaned.trim_matches(|c: char| "-._".contains(c)).to_string();
    if trimmed.is_empty() { "windows-app".into() } else { trimmed }
}

pub fn normalize_icon_name(value: &str) -> String {
    value
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

fn icon_cache_key(source: &Path, icon_index: &str) -> String {
    let seed = match source.metadata() {
        Ok(meta) => format!(
            "{}\0{}\0{}\0{}",
            source.to_string_lossy(),
            meta.modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_nanos())
                .unwrap_or(0),
            meta.len(),
            icon_index
        ),
        Err(_) => format!("{}\0{}", source.to_string_lossy(), icon_index),
    };
    let mut hasher = Sha256::new();
    hasher.update(seed.as_bytes());
    format!("{:x}", hasher.finalize())[..16].to_string()
}

/// ico/png/svg → PNG，最长边不超过 256
pub fn convert_icon_to_png(source: &Path, target: &Path) -> bool {
    let dir = target.parent().map(|p| p.to_path_buf());
    if let Some(dir) = dir {
        let _ = std::fs::create_dir_all(dir);
    }
    let source = cxx_qt_lib::QString::from(source.to_string_lossy().as_ref());
    let target = cxx_qt_lib::QString::from(target.to_string_lossy().as_ref());
    crate::shim_bridge::icon_convert(&source, &target, 256)
}

fn icoextract_select(icon_index: i32) -> Vec<String> {
    if icon_index > 0 {
        vec!["-n".into(), icon_index.to_string()]
    } else if icon_index < 0 {
        vec!["-i".into(), (-icon_index).to_string()]
    } else {
        Vec::new()
    }
}

fn extract_exe_icon(source: &Path, target: &Path, icon_index: i32) -> bool {
    let Some(icoextract) = which("icoextract") else {
        return false;
    };
    let tmp = target.with_extension("ico.tmp");
    let _ = std::fs::create_dir_all(target.parent().unwrap_or(Path::new("/")));
    let mut command = std::process::Command::new(&icoextract);
    for arg in icoextract_select(icon_index) {
        command.arg(arg);
    }
    command.arg(source).arg(&tmp);
    let status = command.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
    let ok = matches!(status, Ok(status) if status.success())
        && tmp.is_file()
        && tmp.metadata().map(|m| m.len() > 0).unwrap_or(false);
    if ok {
        let converted = convert_icon_to_png(&tmp, target);
        let _ = std::fs::remove_file(&tmp);
        return converted;
    }
    let _ = std::fs::remove_file(&tmp);
    false
}

/// exe/ico → PNG：先 icoextract，失败再 wrestool 抽取组图标资源
fn extracted_icon_path(
    source: &Path,
    app_name: &str,
    target_dir: Option<&Path>,
    icon_index: i32,
) -> Option<PathBuf> {
    let target_dir = target_dir
        .map(|p| p.to_path_buf())
        .unwrap_or_else(gui_icon_dir);
    let index_text = if icon_index == 0 { String::new() } else { icon_index.to_string() };
    let target = target_dir.join(format!(
        "{}-{}.png",
        safe_filename(app_name),
        icon_cache_key(source, &index_text)
    ));
    if target.is_file() && target.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        return Some(target);
    }
    let suffix = source
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if suffix == "ico" && source.is_file() {
        return convert_icon_to_png(source, &target).then_some(target);
    }
    if !matches!(suffix.as_str(), "exe" | "dll" | "icl") || !source.is_file() {
        return None;
    }
    if extract_exe_icon(source, &target, icon_index) {
        return Some(target);
    }
    let Some(wrestool) = which("wrestool") else {
        return None;
    };
    let output = std::process::Command::new(wrestool)
        .arg("-x")
        .arg("-t")
        .arg("14")
        .arg(source)
        .output()
        .ok()?;
    if output.status.success() && !output.stdout.is_empty() {
        let tmp = target.with_extension("ico.tmp");
        if std::fs::write(&tmp, &output.stdout).is_ok() && convert_icon_to_png(&tmp, &target) {
            let _ = std::fs::remove_file(&tmp);
            return Some(target);
        }
        let _ = std::fs::remove_file(&tmp);
    }
    None
}

fn search_icon_tree(root: &Path, app_name: &str, limit: usize) -> Option<PathBuf> {
    if !root.is_dir() {
        return None;
    }
    let wanted = normalize_icon_name(app_name);
    if wanted.is_empty() {
        return None;
    }
    let mut best: Option<PathBuf> = None;
    let mut scanned = 0;
    fn walk(dir: &Path, wanted: &str, best: &mut Option<PathBuf>, scanned: &mut usize, limit: usize) {
        if *scanned > limit {
            return;
        }
        let Ok(read) = std::fs::read_dir(dir) else {
            return;
        };
        let mut entries: Vec<PathBuf> = read.flatten().map(|entry| entry.path()).collect();
        entries.sort();
        for path in entries {
            *scanned += 1;
            if *scanned > limit {
                return;
            }
            if path.is_dir() {
                walk(&path, wanted, best, scanned, limit);
            } else {
                let ext = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("")
                    .to_lowercase();
                if !matches!(ext.as_str(), "png" | "svg" | "ico" | "xpm") {
                    continue;
                }
                let stem = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("");
                let name = normalize_icon_name(stem);
                if name == wanted {
                    *best = Some(path.clone());
                    return;
                }
                if name.len() > 1 && (wanted.contains(&name) || name.contains(wanted)) && best.is_none() {
                    *best = Some(path.clone());
                }
            }
        }
    }
    walk(root, &wanted, &mut best, &mut scanned, limit);
    best
}

fn icon_candidates_near(path: &Path) -> Vec<PathBuf> {
    ["png", "svg", "ico", "xpm"]
        .iter()
        .map(|ext| path.with_extension(ext))
        .collect()
}

/// 应用的图标：快捷方式指向的 exe、周边文件、安装器缓存里同名图标
pub fn icon_for_app(prefix: &Path, app: &AppEntry, target_dir: Option<&Path>) -> String {
    let path = PathBuf::from(&app.path);
    let prefix = expand_path(&prefix.to_string_lossy());
    let mut extracted: Option<PathBuf> = None;
    if path.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()) == Some("lnk".into()) {
        let info = crate::core::lnk::parse_lnk(&path);
        if !info.icon.is_empty() {
            if let Some(icon_source) = crate::core::scan::windows_path_to_linux(&prefix, &info.icon) {
                extracted = extracted_icon_path(&icon_source, &app.name, target_dir, info.icon_index);
            }
        }
        if extracted.is_none() {
            let target_source = if !app.target_exe.is_empty() {
                Some(PathBuf::from(&app.target_exe))
            } else if !info.target.is_empty() {
                crate::core::scan::windows_path_to_linux(&prefix, &info.target)
            } else {
                None
            };
            if let Some(source) = target_source {
                extracted = extracted_icon_path(&source, &app.name, target_dir, 0);
            }
        }
    } else {
        extracted = extracted_icon_path(&path, &app.name, target_dir, 0);
    }

    if let Some(found) = extracted {
        return found.to_string_lossy().into_owned();
    }
    for candidate in icon_candidates_near(&path) {
        if candidate.is_file() {
            return candidate.to_string_lossy().into_owned();
        }
    }
    for root in [
        prefix.join("pfx/drive_c/windows/Installer"),
        prefix.join("pfx/drive_c/ProgramData"),
    ] {
        if let Some(icon) = search_icon_tree(&root, &app.name, 3000) {
            return icon.to_string_lossy().into_owned();
        }
    }
    "winrun".into()
}

/// 桌面图标名 → 本地 PNG 缓存；取不到时返回空串
/// 注意：走 Qt 的 QIcon，必须在主线程调用
pub fn theme_icon_png(name: &str) -> String {
    let name = name.trim();
    if name.is_empty() {
        return String::new();
    }
    if name.starts_with('/') {
        return name.to_string();
    }
    let dir = gui_icon_dir();
    let target = dir.join(format!("theme-{}.png", safe_filename(name)));
    if target.is_file() {
        return target.to_string_lossy().into_owned();
    }
    let _ = std::fs::create_dir_all(&dir);
    let source = cxx_qt_lib::QString::from(name);
    let destination = cxx_qt_lib::QString::from(target.to_string_lossy().as_ref());
    if crate::shim_bridge::theme_icon(&source, &destination, 64) {
        target.to_string_lossy().into_owned()
    } else {
        String::new()
    }
}
