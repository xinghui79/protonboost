// 导出桌面文件、重命名、清理：把应用变成本机可启动的桌面入口
use crate::core::conf::{cache_file_for_path, ConfigEntry};
use crate::core::paths::{data_home, exported_app_dir, exported_icon_dir, which};
use crate::core::scan::{app_display_name, app_identity, AppEntry};
use std::path::{Path, PathBuf};

pub fn safe_filename(value: &str) -> String {
    crate::core::icons::safe_filename(value)
}

fn desktop_arg(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

pub fn desktop_paths_for_app(prefix: &Path, app: &AppEntry, display_name: Option<&str>) -> (PathBuf, PathBuf) {
    let base = safe_filename(display_name.unwrap_or(&app_display_name(app)));
    let key = app_identity(prefix, Path::new(&app.path));
    let dir = exported_app_dir();
    (dir.join(format!("{base}.desktop")), dir.join(format!("{base}-{key}.desktop")))
}

pub fn icon_paths_for_app(prefix: &Path, app: &AppEntry, display_name: Option<&str>) -> (PathBuf, PathBuf) {
    let base = safe_filename(display_name.unwrap_or(&app_display_name(app)));
    let key = app_identity(prefix, Path::new(&app.path));
    let dir = exported_icon_dir();
    (dir.join(format!("{base}.png")), dir.join(format!("{base}-{key}.png")))
}

fn read_desktop_x_keys(path: &Path) -> (String, String, String) {
    let mut id = String::new();
    let mut prefix_key = String::new();
    let mut path_key = String::new();
    if let Ok(text) = std::fs::read_to_string(path) {
        for line in text.lines() {
            if let Some(value) = line.strip_prefix("X-WinRun-ID=") {
                id = value.to_string();
            } else if let Some(value) = line.strip_prefix("X-WinRun-Prefix=") {
                prefix_key = value.to_string();
            } else if let Some(value) = line.strip_prefix("X-WinRun-Path=") {
                path_key = value.to_string();
            }
        }
    }
    (id, prefix_key, path_key)
}

fn desktop_matches_app(path: &Path, prefix: &Path, app: &AppEntry) -> bool {
    let (id, prefix_key, path_key) = read_desktop_x_keys(path);
    id == app_identity(prefix, Path::new(&app.path))
        || (prefix_key == prefix.to_string_lossy() && path_key == app.path)
}

pub fn exported_desktop_path(prefix: &Path, app: &AppEntry, display_name: Option<&str>) -> PathBuf {
    let (preferred, hashed) = desktop_paths_for_app(prefix, app, display_name);
    if !preferred.exists() || desktop_matches_app(&preferred, prefix, app) {
        return preferred;
    }
    hashed
}

pub fn exported_icon_path(prefix: &Path, app: &AppEntry, display_name: Option<&str>) -> PathBuf {
    let (preferred, hashed) = icon_paths_for_app(prefix, app, display_name);
    let desktop = exported_desktop_path(prefix, app, display_name);
    let preferred_stem = preferred.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let desktop_stem = desktop.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    if desktop_stem == preferred_stem {
        preferred
    } else {
        hashed
    }
}

/// 生成桌面文件：Exec 走 winrun；图标用应用图标
pub fn export_app(prefix: &Path, app: &AppEntry, manager: &Path, display_name: Option<&str>) -> PathBuf {
    let link = Path::new(&app.path);
    let name = display_name
        .map(|n| n.trim().to_string())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| app_display_name(app));
    let target = exported_desktop_path(prefix, app, Some(&name));
    if let Some(parent) = target.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // 桌面入口直接叫管理器按保存的配置启动，不再经过命令行
    let exec_line = format!(
        "{} --run {}",
        desktop_arg(&manager.to_string_lossy()),
        desktop_arg(&link.to_string_lossy())
    );
    let icon_path = exported_icon_path(prefix, app, Some(&name));
    let mut icon_app = app.clone();
    icon_app.display_name = name.clone();
    let mut icon = crate::core::icons::icon_for_app(prefix, &icon_app, icon_path.parent());
    if icon != "winrun" && Path::new(&icon).is_file() && Path::new(&icon) != icon_path {
        if let Some(parent) = icon_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::copy(&icon, &icon_path);
        icon = icon_path.to_string_lossy().into_owned();
    }
    let text = format!(
        "[Desktop Entry]\nType=Application\nName={name}\nComment=Run {name} with winrun\n\
         Exec={exec_line}\nIcon={icon}\nTerminal=false\nCategories=Utility;X-Wine;\n\
         X-WinRun-ID={}\nX-WinRun-Prefix={}\nX-WinRun-Path={}\n",
        app_identity(prefix, link),
        prefix.to_string_lossy(),
        link.to_string_lossy()
    );
    let _ = std::fs::write(&target, text);
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o644));
    target
}

pub fn delete_exported_app(prefix: &Path, app: &AppEntry) -> PathBuf {
    let target = exported_desktop_path(prefix, app, None);
    let _ = std::fs::remove_file(&target);
    target
}

/// 改名时同步：图标缓存文件改名、桌面文件的 Name/Icon 重写
pub fn rename_icon_cache_files(old_name: &str, new_name: &str) -> Vec<(String, String)> {
    let old_base = safe_filename(old_name);
    let new_base = safe_filename(new_name);
    let mut renamed = Vec::new();
    if old_base == new_base {
        return renamed;
    }
    let dir = exported_icon_dir();
    let Ok(read) = std::fs::read_dir(&dir) else {
        return renamed;
    };
    let mut names: Vec<String> = read
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".png"))
        .filter(|name| name.as_str() == format!("{old_base}.png") || name.starts_with(&format!("{old_base}-")))
        .collect();
    names.sort();
    for name in names {
        let icon = dir.join(&name);
        let suffix = &name[old_base.len()..];
        let target = dir.join(format!("{new_base}{suffix}"));
        if target.exists() {
            renamed.push((icon.to_string_lossy().into_owned(), target.to_string_lossy().into_owned()));
            continue;
        }
        if std::fs::rename(&icon, &target).is_ok() {
            renamed.push((icon.to_string_lossy().into_owned(), target.to_string_lossy().into_owned()));
        }
    }
    renamed
}

pub fn rewrite_desktop_name(path: &Path, name: &str) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    let mut lines: Vec<String> = Vec::new();
    let mut changed = false;
    for line in text.lines() {
        if line.starts_with("Name=") {
            lines.push(format!("Name={name}"));
            changed = true;
        } else {
            lines.push(line.to_string());
        }
    }
    if !changed {
        lines.insert(2, format!("Name={name}"));
    }
    let _ = std::fs::write(path, lines.join("\n") + "\n");
}

pub fn rewrite_desktop_icon(path: &Path, renamed: &[(String, String)]) {
    if !path.is_file() || renamed.is_empty() {
        return;
    }
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    let mut lines = Vec::new();
    let mut changed = false;
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("Icon=") {
            if let Some((_, target)) = renamed.iter().find(|(old, _)| old == value) {
                lines.push(format!("Icon={target}"));
                changed = true;
                continue;
            }
        }
        lines.push(line.to_string());
    }
    if changed {
        let _ = std::fs::write(path, lines.join("\n") + "\n");
    }
}

pub fn maybe_update_desktop_database() {
    if which("update-desktop-database").is_none() {
        return;
    }
    let _ = std::process::Command::new("update-desktop-database")
        .arg(data_home().join("applications"))
        .status();
}

/// 应用的配置项：列表行里展示的那份
pub fn app_cache_entry(prefix: &Path, app: &AppEntry) -> ConfigEntry {
    let file = if app.file.is_empty() {
        cache_file_for_path(&app.path).to_string_lossy().into_owned()
    } else {
        app.file.clone()
    };
    ConfigEntry {
        file,
        name: app_display_name(app),
        exe: app.path.clone(),
        prefix: if app.prefix.is_empty() {
            prefix.to_string_lossy().into_owned()
        } else {
            app.prefix.clone()
        },
        runner: app.runner.clone(),
        program_args: app.program_args.clone(),
        gamescope: app.gamescope == "1",
        gamescope_fullscreen: app.gamescope_fullscreen != "0",
        gamescope_res: app.gamescope_res.clone(),
        gamescope_fps: app.gamescope_fps.clone(),
        gamescope_fsr: app.gamescope_fsr == "1",
        gamescope_args: app.gamescope_args.clone(),
        mangohud: app.mangohud == "1",
        wayland: app.wayland == "1",
        env_vars: app.env_vars.clone(),
        steam_appid: app.steam_appid.clone(),
        source: if app.source.is_empty() { "configured".into() } else { app.source.clone() },
    }
}
