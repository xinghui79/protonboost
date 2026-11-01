//! Steam 覆盖层的 uid 辅助库
//!
//! 独立网络里，pasta 把用户映射成命名空间里的 root，游戏（Wine）也就跑在
//! root 下。Steam 的覆盖层（`gameoverlayrenderer.so`）在决定共享内存的名字时
//! 会问 `getuid()`，于是它去 `/dev/shm/u0-ValveIPCSharedObj-Steam` 找，
//! 而宿主上的 Steam 客户端用的是 `/dev/shm/u1000-…`——两边永远碰不上，
//! 覆盖层（FPS、成就、好友）就废了。
//!
//! 这里编译一个极小的共享库预加载进游戏：它用 `dl_iterate_phdr` 找到
//! 覆盖层自己的代码范围，**只有覆盖层问到 getuid() 时**才回答用户的真实 uid，
//! 其他调用者（Wine、加速器的 TUN 适配器）照旧看到 root。
//!
//! 需要系统装了 C 编译器（`cc`）。没有就跳过——游戏照常跑，只是没有覆盖层。

use crate::core::paths::cache_home;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::process::Command;

/// 辅助库的 C 源码。改动会让缓存键变化，重新编译。
const SOURCE: &str = r#"
/* Preloaded into a Steam game run in a session's network namespace, where the
 * user is root: Steam's overlay names what it shares with the Steam client
 * after getuid(), so it answers the overlay with the user the client runs as.
 * Every other caller, Wine among them, gets the real uid. */
#define _GNU_SOURCE
#include <link.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static uintptr_t overlay_start, overlay_end;

static int find_overlay(struct dl_phdr_info *info, size_t size, void *data)
{
    const char *name = info->dlpi_name;
    uintptr_t start = UINTPTR_MAX, end = 0;
    int i;

    (void)size;
    (void)data;
    if (!name || !strstr(name, "/gameoverlayrenderer.so"))
        return 0;
    for (i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *phdr = &info->dlpi_phdr[i];
        if (phdr->p_type != PT_LOAD)
            continue;
        if (info->dlpi_addr + phdr->p_vaddr < start)
            start = info->dlpi_addr + phdr->p_vaddr;
        if (info->dlpi_addr + phdr->p_vaddr + phdr->p_memsz > end)
            end = info->dlpi_addr + phdr->p_vaddr + phdr->p_memsz;
    }
    if (end) {
        overlay_start = start;
        overlay_end = end;
    }
    return 1;
}

static long overlay_uid(void)
{
    const char *value = getenv("WINRUN_OVERLAY_UID");
    long uid = 0;

    if (!value || !*value)
        return -1;
    for (; *value; value++) {
        if (*value < '0' || *value > '9')
            return -1;
        uid = uid * 10 + (*value - '0');
    }
    return uid;
}

uid_t getuid(void)
{
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    long uid;

    if (!overlay_end)
        dl_iterate_phdr(find_overlay, NULL);
    if (caller >= overlay_start && caller < overlay_end && (uid = overlay_uid()) >= 0)
        return (uid_t)uid;
    return (uid_t)syscall(SYS_getuid);
}
"#;

fn cache_dir() -> PathBuf {
    cache_home().join("winrun/overlay-uid")
}

/// 源码指纹：改了源码就重新编译
fn source_key() -> String {
    let mut hasher = Sha256::new();
    hasher.update(SOURCE.as_bytes());
    format!("{:x}", hasher.finalize())[..16].to_string()
}

/// 编译出 64 位的辅助库。系统没有 C 编译器时返回 None。
fn build(bits: u32) -> Option<PathBuf> {
    let dir = cache_dir().join(source_key());
    let _ = std::fs::create_dir_all(&dir);
    let out = dir.join(format!("overlay-uid-{bits}.so"));
    if out.is_file() {
        return Some(out);
    }
    let failed = dir.join(format!("overlay-uid-{bits}.so.failed"));
    if failed.exists() {
        return None;
    }

    let tmp = dir.join(format!("overlay-uid-{bits}.so.tmp"));
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

/// 系统有 C 编译器吗
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
    if !has_compiler() {
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
    out.push(("WINRUN_OVERLAY_UID".into(), overlay_uid.to_string()));
    out
}

/// 辅助库是否已经编译好了（界面里可以提示用户）
pub fn is_ready() -> bool {
    let dir = cache_dir().join(source_key());
    dir.join("overlay-uid-64.so").is_file()
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
