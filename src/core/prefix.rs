// 前缀（prefix）的发现、分类与标注
use crate::core::paths::{expand_path, home, normalized};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub fn looks_like_wine_prefix(path: &Path) -> bool {
    path.is_dir()
        && path.join("drive_c").is_dir()
        && ["system.reg", "user.reg", "dosdevices"].iter().any(|name| path.join(name).exists())
}

pub fn looks_like_compat_prefix(path: &Path) -> bool {
    looks_like_wine_prefix(&path.join("pfx"))
}

pub fn is_steam_zero_prefix(path: &Path) -> bool {
    path.file_name().is_some_and(|name| name == "0")
        && path.parent().is_some_and(|parent| parent.file_name().is_some_and(|n| n == "compatdata"))
        && path
            .parent()
            .and_then(|parent| parent.parent())
            .is_some_and(|root| root.file_name().is_some_and(|n| n == "steamapps"))
}

fn add_unique_path(values: &mut Vec<PathBuf>, seen: &mut Vec<String>, path: &Path) {
    let path = normalized(path);
    if is_steam_zero_prefix(&path) {
        return;
    }
    let key = path.to_string_lossy().into_owned();
    if seen.contains(&key) {
        return;
    }
    seen.push(key);
    values.push(path);
}

/// 已登记的前缀：默认目录 + 各配置里用过的
pub fn collect_prefixes() -> Vec<PathBuf> {
    let mut values = Vec::new();
    let mut seen = Vec::new();
    values.push(crate::core::paths::default_prefix());
    if let Ok(read) = std::fs::read_dir(crate::core::paths::association_dir()) {
        for entry in read.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|ext| ext != "conf") {
                continue;
            }
            let data = crate::core::conf::read_key_values(&path);
            if let Some(prefix) = data.get("prefix") {
                if !prefix.is_empty() {
                    add_unique_path(&mut values, &mut seen, Path::new(prefix));
                }
            }
        }
    }
    let mut result = Vec::new();
    let mut keys = Vec::new();
    for value in values {
        let key = value.to_string_lossy().into_owned();
        if keys.contains(&key) {
            continue;
        }
        keys.push(key);
        result.push(value);
    }
    result
}

pub fn prefix_mtime(path: &Path) -> u64 {
    let target = if looks_like_compat_prefix(path) { path.join("pfx") } else { path.to_path_buf() };
    target
        .metadata()
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// 运行中进程的前缀：读 /proc/*/environ 里的 WINEPREFIX 等
pub fn collect_running_process_prefixes() -> Vec<PathBuf> {
    let mut counts: BTreeMap<String, (PathBuf, usize)> = BTreeMap::new();
    let mut prefixes: Vec<(String, PathBuf, usize)> = Vec::new();
    let Ok(read) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let Ok(environ) = std::fs::read(entry.path().join("environ")) else {
            continue;
        };
        let mut env = std::collections::HashMap::new();
        for item in environ.split(|b| *b == 0) {
            let pos = match item.iter().position(|&byte| byte == b'=') {
                Some(pos) => pos,
                None => continue,
            };
            env.insert(
                String::from_utf8_lossy(&item[..pos]).into_owned(),
                String::from_utf8_lossy(&item[pos + 1..]).into_owned(),
            );
        }
        for key in ["WINEPREFIX", "STEAM_COMPAT_DATA_PATH", "PROTONBOOST_PREFIX"] {
            let Some(value) = env.get(key) else { continue };
            let path = expand_path(value);
            let matched = match key {
                "WINEPREFIX" => looks_like_wine_prefix(&path),
                "STEAM_COMPAT_DATA_PATH" => looks_like_compat_prefix(&path),
                _ => true,
            };
            if !matched || is_steam_zero_prefix(&path) {
                continue;
            }
            let key = path.to_string_lossy().into_owned();
            let entry = prefixes.iter_mut().find(|(k, _, _)| *k == key);
            match entry {
                Some((_, _, count)) => *count += 1,
                None => prefixes.push((key, path, 1)),
            }
            let _ = &mut counts;
        }
    }
    let mut result: Vec<(usize, PathBuf)> =
        prefixes.into_iter().map(|(_, path, count)| (count, path)).collect();
    result.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.to_string_lossy().cmp(&b.1.to_string_lossy())));
    result.into_iter().map(|(_, path)| path).collect()
}

/// 常见位置里的 Wine 前缀
pub fn collect_common_prefixes() -> Vec<PathBuf> {
    let home = home();
    let mut values = Vec::new();
    let mut seen = Vec::new();
    let mut patterns: Vec<PathBuf> = vec![
        home.join(".wine"),
        home.join("Games/*"),
        home.join("games/*"),
        home.join("Applications/*"),
        home.join("Wine/*"),
        home.join("wine/*"),
        home.join("Prefixes/*"),
        home.join("prefixes/*"),
        home.join(".local/share/lutris/prefixes/*"),
        home.join(".local/share/bottles/bottles/*"),
        home.join(".var/app/com.usebottles.bottles/data/bottles/bottles/*"),
        home.join("Games/Heroic/*"),
        home.join("Games/legendary/*"),
        home.join("Games/epic/*"),
    ];
    for steamapps in [
        home.join(".local/share/Steam/steamapps/compatdata/*"),
        home.join(".steam/steam/steamapps/compatdata/*"),
        home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata/*"),
    ] {
        patterns.push(steamapps);
    }
    for pattern in &patterns {
        let (parent, tail) = match (pattern.parent(), pattern.file_name()) {
            (Some(parent), Some(tail)) => (parent, tail.to_string_lossy().into_owned()),
            _ => continue,
        };
        let Ok(read) = std::fs::read_dir(parent) else {
            continue;
        };
        let mut children: Vec<PathBuf> = read.flatten().map(|entry| entry.path()).collect();
        if tail != "*" {
            children.retain(|child| child.file_name().map(|name| name.to_string_lossy() == tail).unwrap_or(false));
        }
        children.sort();
        for child in children {
            if looks_like_compat_prefix(&child) || looks_like_wine_prefix(&child) {
                add_unique_path(&mut values, &mut seen, &child);
            }
        }
    }
    values.sort_by_key(|value| std::cmp::Reverse(prefix_mtime(value)));
    values
}

/// 折叠同一前缀的两种视图：外壳（compat 根，如 …/proton）与它的 Wine 内层
/// （…/proton/pfx）。进程环境里 PROTONBOOST_PREFIX 指向外壳、WINEPREFIX 指向
/// 内层，两者会各自进入列表，侧栏就会显示成两条；只保留外壳。
pub fn fold_inner_pfx(values: Vec<PathBuf>) -> Vec<PathBuf> {
    let inners: Vec<PathBuf> = values.iter().map(|other| other.join("pfx")).collect();
    values
        .into_iter()
        .filter(|path| !inners.contains(path))
        .collect()
}

/// 进程页的前缀列表：运行中的优先，其次登记的，再次常见位置
pub fn collect_process_prefixes() -> Vec<PathBuf> {
    let mut values = Vec::new();
    let mut seen = Vec::new();
    for group in [
        collect_running_process_prefixes(),
        collect_prefixes(),
        collect_common_prefixes(),
    ] {
        for prefix in group {
            add_unique_path(&mut values, &mut seen, &prefix);
        }
    }
    fold_inner_pfx(values)
}

/// 前缀里配置的 Proton：config_info 第二行是 runner 里 proton 脚本的位置
pub fn prefix_runner(prefix: &Path) -> String {
    let Ok(text) = std::fs::read_to_string(prefix.join("config_info")) else {
        return String::new();
    };
    let Some(line) = text.lines().nth(1) else {
        return String::new();
    };
    let path = PathBuf::from(line);
    let proton = path
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.parent())
        .map(|p| p.join("proton"));
    match proton {
        Some(proton) if proton.is_file() => normalized(&proton).to_string_lossy().into_owned(),
        _ => String::new(),
    }
}

pub fn netns_enabled(prefix: &Path) -> bool {
    let conf = prefix.join(".protonboost.conf");
    std::fs::read_to_string(&conf)
        .map(|text| text.lines().any(|line| line.trim() == "netns=1"))
        .unwrap_or(false)
}

/// 开关独立网络：保留 .protonboost.conf 里的其它键，只替换 netns 这一行
pub fn set_netns(prefix: &Path, enabled: bool) -> Result<(), String> {
    let conf = prefix.join(".protonboost.conf");
    let text = std::fs::read_to_string(&conf).unwrap_or_default();
    let mut lines: Vec<String> = text
        .lines()
        .filter(|line| !line.trim_start().starts_with("netns="))
        .map(|line| line.to_string())
        .collect();
    lines.push(format!("netns={}", if enabled { 1 } else { 0 }));
    std::fs::create_dir_all(prefix).map_err(|err| err.to_string())?;
    std::fs::write(&conf, lines.join("\n") + "\n").map_err(|err| err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 内层pfx折叠进外壳() {
        let shell = PathBuf::from("/home/u/.local/share/protonboost/proton");
        let values = vec![
            shell.clone(),
            shell.join("pfx"),
            PathBuf::from("/home/u/.wine"),
        ];
        let folded = fold_inner_pfx(values);
        assert_eq!(
            folded,
            vec![shell, PathBuf::from("/home/u/.wine")],
            "外壳保留、内层 pfx 被折叠掉，其它前缀不受影响"
        );
    }

    #[test]
    fn 没有内层时原样保留() {
        let values = vec![
            PathBuf::from("/home/u/.wine"),
            PathBuf::from("/home/u/Games/test"),
        ];
        assert_eq!(fold_inner_pfx(values.clone()), values);
    }
}
