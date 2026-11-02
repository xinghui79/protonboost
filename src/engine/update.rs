//! WE-Proton 的版本检查与安装：开箱即用只需要在界面里点一次「下载」。
//! WE-Proton（SHORiN-KiWATA 基于 GE/DW 的魔改）自带 wintun，是加速器
//! 场景的唯一在线运行器——NDIS 内核驱动在 Wine 里没有实现。

use crate::core::paths::cache_home;
use crate::engine::runners::{local_runner_dir, product_dir_name, steam_runner_dir};
use sha2::{Digest, Sha512};
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

pub(crate) fn release_url(product: &str) -> Option<String> {
    match product {
        // WE-Proton：SHORiN-KiWATA 基于 GE/DW 的魔改，自带 wintun——
        // 加速器的 NDIS 内核驱动在 Wine 里没有实现，wintun 是唯一可行通路
        "we" => Some("https://api.github.com/repos/SHORiN-KiWATA/we-proton/releases/latest".into()),
        _ => None,
    }
}

pub(crate) fn blocking_arch(name: &str) -> bool {
    let lower = name.to_lowercase();
    match std::env::consts::ARCH {
        "x86_64" => lower.contains("aarch64") || lower.contains("arm64"),
        "aarch64" => lower.contains("x86_64") || lower.contains("amd64"),
        _ => false,
    }
}

fn fetch(url: &str) -> Option<Vec<u8>> {
    let output = Command::new("curl")
        .args(["-fsSL", "--connect-timeout", "20", "--max-time", "40", "-H", "User-Agent: protonboost"])
        .arg(url)
        .output()
        .ok()?;
    output.status.success().then_some(output.stdout)
}

/// GitHub 直连在部分网络（尤其国内）很慢甚至超时。下载相关的每一步都先直连、
/// 失败后按顺序换镜像重试。gh-proxy 风格镜像的用法是把完整 URL 接在镜像域名后面。
const GH_MIRRORS: &[&str] = &["", "https://ghfast.top", "https://gh-proxy.com", "https://ghproxy.net"];

/// 生效的镜像列表：PROTONBOOST_GH_MIRROR 指定的自定义镜像排最前，空串表示直连
pub(crate) fn mirrors() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Ok(value) = std::env::var("PROTONBOOST_GH_MIRROR") {
        let value = value.trim().trim_end_matches('/').to_string();
        if !value.is_empty() {
            out.push(value);
        }
    }
    out.extend(GH_MIRRORS.iter().map(|m| m.to_string()));
    out
}

/// 把 GitHub URL 换成经镜像代理的形式（直连时原样返回）
pub(crate) fn proxied(mirror: &str, url: &str) -> String {
    if mirror.is_empty() {
        url.to_string()
    } else {
        format!("{mirror}/{url}")
    }
}

/// 任一镜像取到就返回；都失败返回 None
fn fetch_any(url: &str) -> Option<Vec<u8>> {
    for mirror in mirrors() {
        if let Some(body) = fetch(&proxied(&mirror, url)) {
            return Some(body);
        }
    }
    None
}

pub fn latest_release(product: &str) -> Option<Release> {
    let url = release_url(product)?;
    let body = fetch_any(&url)?;
    parse_release(product, &body)
}

pub(crate) fn parse_release(_product: &str, body: &[u8]) -> Option<Release> {
    let data: serde_json::Value = serde_json::from_slice(body).ok()?;
    let tag = data
        .get("tag_name")
        .or_else(|| data.get("name"))
        .and_then(|value| value.as_str())
        .unwrap_or("latest")
        .to_string();

    // WE-Proton 资产：we-proton-<tag>.tar.xz + 同名 .sha512sum；
    // source 包靠排除 -source 前缀区分
    let archive_suffixes: &[&str] = &[".tar.xz"];
    let checksum_suffix = ".sha512sum";

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
pub(crate) fn version_key(value: &str) -> Vec<u64> {
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

pub(crate) fn version_newer(current: &str, latest: &str) -> bool {
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
    let _ = crate::engine::runners::discover().is_empty();
    for product in ["we"] {
        let Some(dir_name) = product_dir_name(product) else { continue };
        let targets: Vec<PathBuf> = install_dirs()
            .into_iter()
            .map(|dir| dir.join(dir_name))
            .filter(|dir| dir.exists())
            .collect();
        if targets.is_empty() {
            // 未安装 WE-Proton：始终给出下载候选（加速器的 NDIS 内核驱动
            // 在 Wine 里没有实现，UU 这类加速器必须走 WE 的 wintun 路线）
            if let Some(release) = latest_release(product) {
                found.push(Candidate {
                    product: product.to_string(),
                    target: steam_runner_dir().join(dir_name),
                    current: String::new(),
                    latest: release.tag.clone(),
                });
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

/// 流式算 SHA-512：压缩包有几百 MB，绝不能整个读进内存
fn sha512_file(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::with_capacity(1 << 20, file);
    let mut hasher = Sha512::new();
    std::io::copy(&mut reader, &mut hasher).ok()?;
    Some(format!("{:x}", hasher.finalize()))
}

pub fn install(candidates: &[Candidate]) -> Result<usize, String> {
    let downloads = cache_home().join("protonboost/downloads");
    std::fs::create_dir_all(&downloads).map_err(|err| err.to_string())?;
    let mut updated = 0;

    for candidate in candidates {
        let Some(release) = latest_release(&candidate.product) else {
            return Err(format!("查不到 {} 的最新版本", candidate.product));
        };
        let archive = downloads.join(&release.archive_name);
        // 先直连，失败后按顺序换镜像——国内直连 GitHub 通常很慢
        let mut downloaded = false;
        for mirror in mirrors() {
            let _ = std::fs::remove_file(&archive);
            // --speed-limit/--speed-time：30 秒内平均低于 100 KB/s 视为卡死，
            // 断开换下一个镜像，避免挂在慢速直连上耗几小时
            downloaded = Command::new("curl")
                .args(["-fsSL", "--connect-timeout", "30",
                       "--speed-time", "30", "--speed-limit", "102400", "-o"])
                .arg(&archive)
                .arg(proxied(&mirror, &release.archive_url))
                .status()
                .map(|status| status.success())
                .unwrap_or(false);
            if downloaded {
                break;
            }
        }
        if !downloaded {
            return Err(format!("下载失败：{}", release.archive_name));
        }

        // 校验文件拿不到就不能装：归档可能来自第三方镜像，必须有完整性验证
        let expected = fetch_any(&release.checksum_url)
            .and_then(|body| String::from_utf8(body).ok())
            .and_then(|text| text.split_whitespace().next().map(|value| value.to_string()))
            .filter(|value| !value.is_empty());
        let Some(expected) = expected else {
            let _ = std::fs::remove_file(&archive);
            return Err(format!("拉不到校验文件，已放弃安装：{}", release.archive_name));
        };
        if sha512_file(&archive).as_deref() != Some(expected.as_str()) {
            let _ = std::fs::remove_file(&archive);
            return Err(format!("校验失败：{}", release.archive_name));
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
        // 先把旧目录挪开再装新的：装失败（比如 downloads 在 ~/.cache、目标在
        // ~/.local/share，跨文件系统时 rename 走不了）能原样退回，不会把用户
        // 已装的运行器删了又装不上
        let backup = candidate
            .target
            .with_file_name(format!("{}.old-{}", candidate.target.file_name().and_then(|n| n.to_str()).unwrap_or("runner"), std::process::id()));
        let _ = std::fs::remove_dir_all(&backup);
        let had_old = std::fs::rename(&candidate.target, &backup).is_ok();
        if let Err(err) = move_dir(&root, &candidate.target) {
            if had_old {
                let _ = std::fs::rename(&backup, &candidate.target);
            }
            return Err(format!("安装失败：{err}"));
        }
        let _ = std::fs::remove_dir_all(&backup);
        let _ = std::fs::remove_dir_all(&staging);
        let _ = std::fs::remove_file(&archive);
        updated += 1;
    }
    Ok(updated)
}

/// 目录挪位置：先试 rename，跨文件系统时退回复制
fn move_dir(source: &Path, target: &Path) -> Result<(), String> {
    if std::fs::rename(source, target).is_ok() {
        return Ok(());
    }
    copy_tree(source, target)
}

fn copy_tree(source: &Path, target: &Path) -> Result<(), String> {
    std::fs::create_dir_all(target).map_err(|err| err.to_string())?;
    for entry in std::fs::read_dir(source).map_err(|err| err.to_string())?.flatten() {
        let from = entry.path();
        let to = target.join(entry.file_name());
        if from.is_dir() {
            copy_tree(&from, &to)?;
        } else {
            std::fs::copy(&from, &to).map_err(|err| err.to_string())?;
        }
    }
    Ok(())
}

/// 界面上的一行说明
pub fn describe(candidates: &[Candidate]) -> String {
    candidates
        .iter()
        .map(|candidate| {
            let current = if candidate.current.is_empty() { "—".to_string() } else { candidate.current.clone() };
            let label = "WE-Proton";
            format!("{label}: {current} → {}", candidate.latest)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

