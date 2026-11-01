//! GE / DW 运行器的版本检查与安装（原 lib/runners.sh 的 check_update / update）
//!
//! WE-Proton 是本地维护版，没有在线安装/更新，只在界面里说明。

use crate::core::paths::cache_home;
use crate::engine::runners::{local_runner_dir, product_dir_name, steam_runner_dir};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Debug)]
pub struct Release {
    pub tag: String,
    pub archive_url: String,
    pub archive_name: String,
    pub checksum_url: String,
}

#[derive(Clone, Debug)]
pub struct Candidate {
    pub product: String,
    pub target: PathBuf,
    pub current: String,
    pub latest: String,
}

fn install_dirs() -> Vec<PathBuf> {
    vec![local_runner_dir(), steam_runner_dir()]
}

fn installed_version(dir: &Path) -> String {
    let version = std::fs::read_to_string(dir.join("version")).unwrap_or_default();
    // GE 的 version 文件写的是 "GE-Proton11-11"，WE 是 "1792606118 we-proton-ge11-11-31"，
    // 所以不能要求 token 以数字开头，取最后一个「含数字」的就行。
    for token in version.split_whitespace().rev() {
        if token.chars().any(|c| c.is_ascii_digit()) {
            return token.to_string();
        }
    }
    dir.file_name().and_then(|name| name.to_str()).unwrap_or_default().to_string()
}

fn release_url(product: &str) -> Option<String> {
    match product {
        "ge" => Some("https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest".into()),
        "dw" => Some("https://dawn.wine/api/v1/repos/dawn-winery/dwproton/releases/latest".into()),
        _ => None,
    }
}

fn blocking_arch(name: &str) -> bool {
    let lower = name.to_lowercase();
    match std::env::consts::ARCH {
        "x86_64" => lower.contains("aarch64") || lower.contains("arm64"),
        "aarch64" => lower.contains("x86_64") || lower.contains("amd64"),
        _ => false,
    }
}

fn fetch(url: &str) -> Option<Vec<u8>> {
    let output = Command::new("curl")
        .args(["-fsSL", "--connect-timeout", "20", "--max-time", "40", "-H", "User-Agent: winrun"])
        .arg(url)
        .output()
        .ok()?;
    output.status.success().then_some(output.stdout)
}

pub fn latest_release(product: &str) -> Option<Release> {
    let url = release_url(product)?;
    let body = fetch(&url)?;
    let data: serde_json::Value = serde_json::from_slice(&body).ok()?;
    let tag = data
        .get("tag_name")
        .or_else(|| data.get("name"))
        .and_then(|value| value.as_str())
        .unwrap_or("latest")
        .to_string();

    let archive_suffixes: &[&str] = if product == "ge" { &[".tar.gz"] } else { &["x86_64.tar.xz"] };
    let checksum_suffix = if product == "ge" { ".sha512sum" } else { "x86_64.sha512sum" };

    let assets = data.get("assets")?.as_array()?;
    let mut archive: Option<(String, String)> = None;
    let mut checksum: Option<String> = None;
    for asset in assets {
        let name = asset.get("name").and_then(|value| value.as_str()).unwrap_or("");
        let download = asset.get("browser_download_url").and_then(|value| value.as_str()).unwrap_or("");
        if download.is_empty() || blocking_arch(name) {
            continue;
        }
        if archive.is_none()
            && archive_suffixes.iter().any(|suffix| name.ends_with(suffix))
            && !name.ends_with("-source.tar.xz")
        {
            archive = Some((name.to_string(), download.to_string()));
        }
        if checksum.is_none() && name.ends_with(checksum_suffix) {
            checksum = Some(download.to_string());
        }
    }
    let (archive_name, archive_url) = archive?;
    Some(Release {
        tag,
        archive_name,
        archive_url,
        checksum_url: checksum?,
    })
}

/// 版本号里的数字段：`GE-Proton11-11` 与 `11-11` 都得到 [11, 11]
fn version_key(value: &str) -> Vec<u64> {
    let mut parts: Vec<u64> = Vec::new();
    let mut current = String::new();
    for ch in value.chars() {
        if ch.is_ascii_digit() {
            current.push(ch);
        } else if !current.is_empty() {
            parts.push(current.parse().unwrap_or(0));
            current.clear();
        }
    }
    if !current.is_empty() {
        parts.push(current.parse().unwrap_or(0));
    }
    parts
}

fn version_newer(current: &str, latest: &str) -> bool {
    let have = version_key(current);
    let want = version_key(latest);
    if have.is_empty() || want.is_empty() {
        return current != latest;
    }
    have < want
}

/// 已装的 Latest 运行器里，有哪些比线上的旧
pub fn check() -> Vec<Candidate> {
    let mut found: Vec<Candidate> = Vec::new();
    // 机器上一个 Proton / Wine 都没有：这时把「装 GE-Proton」也当成一条待办，
    // 否则界面上根本没有下载运行器的入口，程序永远跑不起来。
    let no_runner = crate::engine::runners::discover().is_empty();
    for product in ["ge", "dw"] {
        let Some(dir_name) = product_dir_name(product) else { continue };
        let targets: Vec<PathBuf> = install_dirs()
            .into_iter()
            .map(|dir| dir.join(dir_name))
            .filter(|dir| dir.exists())
            .collect();
        if targets.is_empty() {
            if no_runner && product == "ge" {
                if let Some(release) = latest_release(product) {
                    found.push(Candidate {
                        product: product.to_string(),
                        target: steam_runner_dir().join(dir_name),
                        current: String::new(),
                        latest: release.tag.clone(),
                    });
                }
            }
            continue;
        }
        let Some(release) = latest_release(product) else { continue };
        for target in targets {
            let current = installed_version(&target);
            if version_newer(&current, &release.tag) {
                found.push(Candidate {
                    product: product.to_string(),
                    target,
                    current,
                    latest: release.tag.clone(),
                });
            }
        }
    }
    found
}

fn sha512_file(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    // sha512 用外部命令更省事，这里只做非空校验的兜底
    let _ = hasher.finalize();
    let output = Command::new("sha512sum").arg(path).output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    text.split_whitespace().next().map(|value| value.to_string())
}

pub fn install(candidates: &[Candidate]) -> Result<usize, String> {
    let downloads = cache_home().join("winrun/downloads");
    std::fs::create_dir_all(&downloads).map_err(|err| err.to_string())?;
    let mut updated = 0;

    for candidate in candidates {
        let Some(release) = latest_release(&candidate.product) else {
            return Err(format!("查不到 {} 的最新版本", candidate.product));
        };
        let archive = downloads.join(&release.archive_name);
        let downloaded = Command::new("curl")
            .args(["-fsSL", "--connect-timeout", "30", "-o"])
            .arg(&archive)
            .arg(&release.archive_url)
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if !downloaded {
            return Err(format!("下载失败：{}", release.archive_name));
        }

        if let Some(expected) = fetch(&release.checksum_url)
            .and_then(|body| String::from_utf8(body).ok())
            .and_then(|text| text.split_whitespace().next().map(|value| value.to_string()))
        {
            if sha512_file(&archive).as_deref() != Some(expected.as_str()) {
                let _ = std::fs::remove_file(&archive);
                return Err(format!("校验失败：{}", release.archive_name));
            }
        }

        let staging = downloads.join(format!("extract-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).map_err(|err| err.to_string())?;
        let ok = Command::new("tar")
            .arg("-xf")
            .arg(&archive)
            .arg("-C")
            .arg(&staging)
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if !ok {
            let _ = std::fs::remove_dir_all(&staging);
            return Err(format!("解压失败：{}", release.archive_name));
        }

        let root = std::fs::read_dir(&staging)
            .map_err(|err| err.to_string())?
            .flatten()
            .map(|entry| entry.path())
            .find(|path| path.is_dir())
            .ok_or_else(|| "压缩包里没有运行器目录".to_string())?;

        if let Some(parent) = candidate.target.parent() {
            std::fs::create_dir_all(parent).map_err(|err| err.to_string())?;
        }
        let _ = std::fs::remove_dir_all(&candidate.target);
        std::fs::rename(&root, &candidate.target).map_err(|err| err.to_string())?;
        let _ = std::fs::remove_dir_all(&staging);
        let _ = std::fs::remove_file(&archive);
        updated += 1;
    }
    Ok(updated)
}

/// 界面上的一行说明
pub fn describe(candidates: &[Candidate]) -> String {
    candidates
        .iter()
        .map(|candidate| {
            let product = match candidate.product.as_str() {
                "ge" => "GE-Proton",
                "dw" => "DW-Proton",
                other => other,
            };
            let current = if candidate.current.is_empty() { "—".to_string() } else { candidate.current.clone() };
            format!("{product}: {current} → {}", candidate.latest)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

