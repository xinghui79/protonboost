// Steam：appmanifest 里的游戏名，用于进程页与前缀标注
use crate::core::paths::home;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

fn steamapps_dirs() -> Vec<PathBuf> {
    vec![
        home().join(".local/share/Steam/steamapps"),
        home().join(".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps"),
    ]
}

/// appmanifest_*.acf 里的 appid → 游戏名
pub fn app_names() -> HashMap<String, String> {
    let mut names = HashMap::new();
    for steamapps in steamapps_dirs() {
        let Ok(read) = std::fs::read_dir(&steamapps) else {
            continue;
        };
        for entry in read.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(appid) = name
                .strip_prefix("appmanifest_")
                .and_then(|rest| rest.strip_suffix(".acf"))
                .map(|id| id.to_string())
            else {
                continue;
            };
            let Ok(text) = std::fs::read_to_string(entry.path()) else {
                continue;
            };
            if let Some(game_name) = manifest_value(&text, "name") {
                if !game_name.is_empty() {
                    names.insert(appid, game_name);
                }
            }
        }
    }
    names
}

/// VDF 文本里某个键的第一个值
fn manifest_value(text: &str, key: &str) -> Option<String> {
    for line in text.lines() {
        let parts: Vec<&str> = line.trim().split('"').collect();
        if parts.len() >= 4 && parts[1] == key {
            return Some(parts[3].to_string());
        }
    }
    None
}

/// 前缀是 Steam 的 compatdata/<appid> 时返回 appid
pub fn app_id_for_prefix(prefix: &Path) -> String {
    let name = prefix.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let parent = prefix.parent().and_then(|p| p.file_name()).unwrap_or_default();
    let root = prefix
        .parent()
        .and_then(|p| p.parent())
        .and_then(|p| p.file_name())
        .unwrap_or_default();
    if name.chars().all(|c| c.is_ascii_digit())
        && !name.is_empty()
        && parent == "compatdata"
        && root == "steamapps"
    {
        return name.to_string();
    }
    String::new()
}
