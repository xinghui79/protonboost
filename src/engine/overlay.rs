//! Steam 覆盖层的 uid 辅助库
//!
//! 独立网络里，pasta 把用户映射成命名空间里的 root，游戏（Wine）也就跑在
//! root 下。Steam 的覆盖层（`gameoverlayrenderer.so`）在决定共享内存的名字时
//! 会问 `getuid()`，于是它去 `/dev/shm/u0-ValveIPCSharedObj-Steam` 找，
//! 而宿主上的 Steam 客户端用的是 `/dev/shm/u1000-…`——两边永远碰不上，
//! 覆盖层（FPS、成就、好友）就废了。
//!
//! 这里准备一个极小的共享库预加载进游戏：它用 `dl_iterate_phdr` 找到
//! 覆盖层自己的代码范围，**只有覆盖层问到 getuid() 时**才回答用户的真实 uid，
//! 其他调用者（Wine、加速器的 TUN 适配器）照旧看到 root。
//!
//! 编译好的 `.so` 在构建期就嵌进二进制（见 build.rs），用户机器上不需要
//! C 编译器。只有嵌入产物缺架构（比如在别的架构上构建）时才回退到
//! 现场 `cc` 编译。

use crate::core::paths::cache_home;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::Command;

/// 辅助库的 C 源码，单一来源是 native/overlay-uid/overlay-uid.c。
/// 改动会让缓存键变化，重新铺缓存。
const SOURCE: &str = include_str!("../../native/overlay-uid/overlay-uid.c");

/// 构建期编译好的辅助库（见 build.rs）。没有编译器时是空占位。
const EMBEDDED_64: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/overlay-uid-64.so"));
const EMBEDDED_32: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/overlay-uid-32.so"));

/// 嵌入产物是否可用：是 ELF，且架构匹配当前主机（64 位匹配主机架构，
/// 32 位匹配主机架构的 32 位变体）。
fn embedded(bits: u32) -> Option<&'static [u8]> {
    let bytes = if bits == 64 { EMBEDDED_64 } else { EMBEDDED_32 };
    if bytes.len() < 20 || !bytes.starts_with(b"\x7fELF") {
        return None;
    }
    // e_machine 在 ELF 头偏移 18 处，小端 u16
    let machine = u16::from_le_bytes([bytes[18], bytes[19]]);
    let ok = match (std::env::consts::ARCH, bits) {
        ("x86_64", 64) => machine == 62,  // EM_X86_64
        ("x86_64", 32) => machine == 3,   // EM_386
        ("aarch64", 64) => machine == 183, // EM_AARCH64
        ("aarch64", 32) => machine == 40, // EM_ARM
        _ => false,
    };
    ok.then_some(bytes)
}

fn cache_dir() -> PathBuf {
    cache_home().join("protonboost/overlay-uid")
}

/// 源码指纹：改了源码就重新铺缓存
fn source_key() -> String {
    let mut hasher = Sha256::new();
    hasher.update(SOURCE.as_bytes());
    format!("{:x}", hasher.finalize())[..16].to_string()
}

fn cached(bits: u32) -> PathBuf {
    cache_dir().join(source_key()).join(format!("overlay-uid-{bits}.so"))
}

/// 把嵌入的产物铺到缓存目录
fn install_embedded(bits: u32, out: &Path) -> bool {
    let Some(bytes) = embedded(bits) else {
        return false;
    };
    if std::fs::write(out, bytes).is_err() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(out, std::fs::Permissions::from_mode(0o755));
    }
    true
}

/// 准备好 64/32 位的辅助库，返回路径。嵌入产物优先，没有才现场编译。
fn build(bits: u32) -> Option<PathBuf> {
    let dir = cache_dir().join(source_key());
    let _ = std::fs::create_dir_all(&dir);
    let out = cached(bits);
    if out.is_file() {
        return Some(out);
    }
    let failed = dir.join(format!("overlay-uid-{bits}.so.failed"));
    if failed.exists() {
        return None;
    }

    // 嵌入的优先：用户机器上不需要编译器
    let tmp = dir.join(format!("overlay-uid-{bits}.so.tmp"));
    if install_embedded(bits, &tmp) {
        std::fs::rename(&tmp, &out).ok()?;
        return Some(out);
    }

    // 回退：现场编译（嵌入产物缺架构时才会走到这）
    let mut command = Command::new("cc");
    command
        .arg(format!("-m{bits}"))
        .arg("-shared")
        .arg("-fPIC")
        .arg("-O2")
        .arg("-fno-stack-protector")
        .arg("-U_FORTIFY_SOURCE")
        .arg("-x")
        .arg("c")
        .arg("-")
        .arg("-o")
        .arg(&tmp);
    command.stdin(std::process::Stdio::piped());
    command.stdout(std::process::Stdio::null());
    command.stderr(std::process::Stdio::null());

    let mut child = command.spawn().ok()?;
    if let Some(stdin) = child.stdin.as_mut() {
        use std::io::Write;
        stdin.write_all(SOURCE.as_bytes()).ok()?;
    }
    let status = child.wait().ok()?;
    if !status.success() {
        let _ = std::fs::remove_file(&tmp);
        let _ = std::fs::write(&failed, b"");
        return None;
    }
    std::fs::rename(&tmp, &out).ok()?;
    Some(out)
}

/// 系统有 C 编译器吗（嵌入产物缺失时的回退手段）
pub fn has_compiler() -> bool {
    crate::core::paths::which("cc").is_some()
}

/// 为这次启动准备覆盖层要用的环境变量。
///
/// 只有当游戏带着 Steam 的覆盖层（LD_PRELOAD 里有 gameoverlayrenderer.so）
/// 且确实在独立网络里时才需要。返回一个 (变量名, 值) 列表，没有需要时是空的。
pub fn prepare_env(
    in_netns: bool,
    preload: Option<&str>,
    overlay_uid: u32,
) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if !in_netns {
        return out;
    }
    let Some(preload) = preload else {
        return out;
    };
    if !preload.contains("gameoverlayrenderer.so") {
        return out;
    }
    let mut libs = Vec::new();
    for bits in [64u32, 32u32] {
        if let Some(lib) = build(bits) {
            libs.push(lib.to_string_lossy().into_owned());
        }
    }
    if libs.is_empty() {
        return out;
    }
    let joined = format!("{preload}:{}", libs.join(":"));
    out.push(("LD_PRELOAD".into(), joined));
    out.push(("PROTONBOOST_OVERLAY_UID".into(), overlay_uid.to_string()));
    out
}

/// 辅助库是否可用（嵌入产物有效或缓存里已铺好；界面里可以提示用户）
pub fn is_ready() -> bool {
    if embedded(64).is_some() {
        return true;
    }
    cached(64).is_file()
}

/// 供测试：确认源码里有 getuid 覆盖
#[cfg(test)]
pub fn source_contains_getuid() -> bool {
    SOURCE.contains("uid_t getuid(void)")
}

/// 供测试：源码长度
#[cfg(test)]
pub fn source_length() -> usize {
    SOURCE.len()
}

/// 供测试：嵌入产物在当前主机上可用
#[cfg(test)]
pub fn embedded_ready() -> bool {
    embedded(64).is_some()
}
