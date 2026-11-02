//! Steam Linux Runtime：Proton 是按它自己的容器运行时构建的
//! 找不到就依次试下一份，都下不到就直接跑（部分功能会缺失）。

use crate::core::paths::{home, xdg};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::Command;

struct RuntimeInfo {
    dir_name: &'static str,
    short: &'static str,
    base_url: &'static str,
    archive: &'static str,
}

fn info(appid: &str) -> Option<RuntimeInfo> {
    match appid {
        "4183110" => Some(RuntimeInfo {
            dir_name: "SteamLinuxRuntime_4",
            short: "steamrt4",
            base_url: "https://repo.steampowered.com/steamrt4/images/latest-public-stable/",
            archive: "SteamLinuxRuntime_4.tar.xz",
        }),
        "1628350" => Some(RuntimeInfo {
            dir_name: "SteamLinuxRuntime_sniper",
            short: "steamrt3",
            base_url: "https://repo.steampowered.com/steamrt-images-sniper/snapshots/latest-container-runtime-public-beta/",
            archive: "SteamLinuxRuntime_sniper.tar.xz",
        }),
        _ => None,
    }
}

fn runtime_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join("protonboost/runtime")
}

fn steam_roots() -> Vec<PathBuf> {
    let mut roots = vec![
        home().join(".local/share/Steam"),
        home().join(".steam/root"),
        home().join(".steam/steam"),
        home().join(".var/app/com.valvesoftware.Steam/data/Steam"),
    ];
    for file in [
        home().join(".local/share/Steam/steamapps/libraryfolders.vdf"),
        home().join(".steam/root/steamapps/libraryfolders.vdf"),
    ] {
        if let Ok(text) = std::fs::read_to_string(&file) {
            for line in text.lines() {
                if let Some(rest) = line.trim().strip_prefix("\"path\"") {
                    if let Some(value) = rest.split('"').nth(1) {
                        if !value.is_empty() {
                            roots.push(crate::core::paths::expand_path(value));
                        }
                    }
                }
            }
        }
    }
    roots
}

/// proton 目录里 toolmanifest.vdf 声明的运行时
pub fn required_appid(proton: &Path) -> Option<String> {
    let manifest = proton.parent()?.join("toolmanifest.vdf");
    let text = std::fs::read_to_string(manifest).ok()?;
    for line in text.lines() {
        let Some(pos) = line.find("\"require_tool_appid\"") else {
            continue;
        };
        let rest = &line[pos..];
        let value: String = rest
            .chars()
            .skip_while(|c| !c.is_ascii_digit())
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if !value.is_empty() {
            return Some(value);
        }
    }
    None
}

fn find(short: &str) -> Option<PathBuf> {
    let mut candidates = vec![runtime_dir().join(short), xdg("XDG_DATA_HOME", ".local/share").join("umu").join(short)];
    for root in steam_roots() {
        candidates.push(root.join("steamapps/common").join(short));
    }
    if let Some(info) = ["steamrt4", "steamrt3"].iter().find(|value| **value == short) {
        let _ = info;
    }
    candidates.into_iter().find(|dir| dir.join("_v2-entry-point").is_file())
}

fn fetch(url: &str, target: &Path) -> bool {
    std::fs::create_dir_all(target.parent().unwrap_or(Path::new("/tmp"))).ok();
    Command::new("curl")
        .args(["-fsSL", "--connect-timeout", "30", "-o"])
        .arg(target)
        .arg(url)
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn fetch_text(url: &str) -> Option<String> {
    let output = Command::new("curl").args(["-fsSL", "--connect-timeout", "30"]).arg(url).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// 流式算 SHA-256：运行时包上百 MB，不能整个读进内存
fn sha256_file(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::with_capacity(1 << 20, file);
    let mut hasher = Sha256::new();
    std::io::copy(&mut reader, &mut hasher).ok()?;
    Some(format!("{:x}", hasher.finalize()))
}

fn download(info: &RuntimeInfo) -> bool {
    let sums_url = format!("{}SHA256SUMS", info.base_url);
    let Some(sums) = fetch_text(&sums_url) else {
        return false;
    };
    let expected = sums
        .lines()
        .find_map(|line| {
            let mut fields = line.split_whitespace();
            let hash = fields.next()?;
            let name = fields.next()?.trim_start_matches('*');
            (name == info.archive).then(|| hash.to_string())
        });
    let Some(expected) = expected else {
        return false;
    };

    let downloads = crate::core::paths::cache_home().join("protonboost/downloads");
    let _ = std::fs::create_dir_all(&downloads);
    let archive = downloads.join(info.archive);
    if !fetch(&format!("{}{}", info.base_url, info.archive), &archive) {
        return false;
    }
    if sha256_file(&archive).as_deref() != Some(expected.as_str()) {
        let _ = std::fs::remove_file(&archive);
        return false;
    }

    let root = runtime_dir();
    let _ = std::fs::create_dir_all(&root);
    let staging = root.join(format!(".extract-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&staging);
    let extracted = Command::new("tar")
        .arg("-xJf")
        .arg(&archive)
        .arg("-C")
        .arg(&staging)
        .status()
        .map(|status| status.success())
        .unwrap_or(false);
    if !extracted || !staging.join(info.dir_name).join("_v2-entry-point").is_file() {
        let _ = std::fs::remove_dir_all(&staging);
        let _ = std::fs::remove_file(&archive);
        return false;
    }
    let target = root.join(info.short);
    let _ = std::fs::remove_dir_all(&target);
    let moved = std::fs::rename(staging.join(info.dir_name), &target).is_ok();
    let _ = std::fs::remove_dir_all(&staging);
    let _ = std::fs::remove_file(&archive);
    moved
}

/// 老版 WE-Proton 是直接对宿主库链接的，只能直接跑
fn runner_is_old_weproton(proton: &Path) -> bool {
    let Some(dir) = proton.parent() else { return false };
    let Ok(version) = std::fs::read_to_string(dir.join("version")) else {
        return false;
    };
    let Some(label) = version.split_whitespace().last() else {
        return false;
    };
    if !label.starts_with("we-proton-") {
        return false;
    }
    label <= "we-proton-11.0-14-10"
}

/// 运行 Proton 需要的 `_v2-entry-point` 前缀；不需要或拿不到时返回空
pub fn entry_prefix(proton: &Path, verb: &str) -> Vec<String> {
    if std::env::var("PROTONBOOST_RUNTIME").map(|value| value == "0").unwrap_or(false) {
        return Vec::new();
    }
    let Some(appid) = required_appid(proton) else {
        return Vec::new();
    };
    let Some(info) = info(&appid) else {
        return Vec::new();
    };
    if runner_is_old_weproton(proton) {
        return Vec::new();
    }
    let dir = match find(info.short) {
        Some(dir) => Some(dir),
        None => download(&info).then(|| runtime_dir().join(info.short)),
    };
    let Some(dir) = dir.filter(|dir| dir.join("_v2-entry-point").is_file()) else {
        return Vec::new();
    };
    vec![
        dir.join("_v2-entry-point").to_string_lossy().into_owned(),
        format!("--verb={verb}"),
        "--".to_string(),
    ]
}
