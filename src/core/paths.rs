// XDG 路径与项目目录
use std::path::PathBuf;

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
}

pub fn xdg(var: &str, fallback: &str) -> PathBuf {
    match std::env::var(var) {
        Ok(value) if !value.is_empty() => PathBuf::from(value),
        _ => home().join(fallback),
    }
}

pub fn cache_home() -> PathBuf {
    xdg("XDG_CACHE_HOME", ".cache")
}

pub fn data_home() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share")
}

pub fn association_dir() -> PathBuf {
    cache_home().join("winrun/associations")
}

pub fn gui_icon_dir() -> PathBuf {
    cache_home().join("winrun/icons")
}

pub fn exported_icon_dir() -> PathBuf {
    data_home().join("icons/winrun/apps")
}

pub fn exported_app_dir() -> PathBuf {
    data_home().join("applications/winrun")
}

pub fn run_log_root() -> PathBuf {
    cache_home().join("winrun/logs")
}

pub fn app_log_dir(app_id: &str) -> PathBuf {
    run_log_root().join(app_id)
}

/// 应用最近一次日志：latest.log 优先，其次按修改时间最新的 *.log
pub fn latest_log_for_app(app_id: &str) -> Option<PathBuf> {
    let dir = app_log_dir(app_id);
    let latest = dir.join("latest.log");
    if latest.is_file() {
        return Some(latest);
    }
    let mut logs: Vec<(std::time::SystemTime, PathBuf)> = std::fs::read_dir(&dir)
        .ok()?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "log"))
        .filter_map(|path| {
            let time = path.metadata().ok()?.modified().ok()?;
            Some((time, path))
        })
        .collect();
    logs.sort_by(|a, b| b.0.cmp(&a.0));
    logs.into_iter().next().map(|(_, path)| path)
}

/// 展开路径并规整化（不要求存在）
pub fn expand_path(value: &str) -> PathBuf {
    let value = value.trim();
    let expanded = if let Some(rest) = value.strip_prefix("~/") {
        home().join(rest)
    } else if value == "~" {
        home()
    } else {
        PathBuf::from(value)
    };
    normalized(&expanded)
}

/// 不跟随符号链接的路径规整化：去掉 . 与多余的 ..
pub fn normalized(path: &std::path::Path) -> PathBuf {
    use std::path::{Component, PathBuf};
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !result.pop() {
                    result.push("..");
                }
            }
            other => result.push(other.as_os_str()),
        }
    }
    result
}

/// 在同级目录里找可执行文件：安装目录里的兄弟程序
pub fn resolve_sibling(name: &str) -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    PathBuf::from(name)
}

/// 在 PATH 里找命令
pub fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var("PATH").ok()?;
    for part in path.split(':') {
        if part.is_empty() {
            continue;
        }
        let candidate = PathBuf::from(part).join(name);
        if candidate.is_file() {
            use std::os::unix::fs::PermissionsExt;
            if candidate.metadata().map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false) {
                return Some(candidate);
            }
        }
    }
    None
}
