// 进程：读 /proc 匹配前缀，结束进程
use crate::core::paths::expand_path;
use nix::sys::signal::{kill, Signal};
use nix::unistd::Pid;
use std::collections::{HashMap, HashSet};
use std::path::Path;

#[derive(Clone, Debug, Default)]
pub struct ProcEntry {
    pub pid: i32,
    pub ppid: i32,
    pub exe: String,
    pub name: String,
    pub command: String,
    pub age: String,
    pub app_id: String,
    pub app_path: String,
    pub log: String,
}

/// Wine 自己的进程服务整个前缀，带着最先启动的那个应用的 ID
pub const WINE_SESSION_PROCESSES: &[&str] = &[
    "wineserver", "services.exe", "winedevice.exe", "explorer.exe", "plugplay.exe", "svchost.exe",
    "rpcss.exe", "tabtip.exe", "csrss.exe", "lsass.exe",
];

pub fn process_parent(pid: i32) -> i32 {
    let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return 0;
    };
    let Some(after) = stat.rsplit_once(')').map(|(_, rest)| rest) else {
        return 0;
    };
    after
        .split_whitespace()
        .nth(1)
        .and_then(|field| field.parse().ok())
        .unwrap_or(0)
}

pub fn process_start_time(pid: i32) -> String {
    let started = std::fs::metadata(format!("/proc/{pid}"))
        .and_then(|m| m.created().or_else(|_| m.modified()));
    let Ok(started) = started else {
        return String::new();
    };
    let Ok(elapsed) = started.elapsed() else {
        return String::new();
    };
    let seconds = elapsed.as_secs();
    if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else {
        format!("{}h{}m", seconds / 3600, seconds % 3600 / 60)
    }
}

/// 进程的启动时刻（/proc/<pid>/stat 第 22 字段，开机以来的 tick 数）。
/// 延时强杀前用它确认 pid 没有被复用：时刻变了就说明是另一个进程
pub fn process_start_ticks(pid: i32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.rsplit_once(')')?.1;
    after.split_whitespace().nth(19)?.parse().ok()
}

/// 路径串里是否出现 dir 之下的路径（按分隔符对齐）。
/// 直接 contains 会把 `…/Game2` 算进 `…/Game` 头上，兄弟目录被连坐
pub fn mentions_path_under(value: &str, dir: &str) -> bool {
    if dir.is_empty() || value.is_empty() {
        return false;
    }
    let boundary = |bytes: &[u8], index: usize| -> bool {
        matches!(bytes.get(index), None | Some(b'/') | Some(b'\\') | Some(b'"'))
    };
    let value = value.as_bytes();
    let dir = dir.as_bytes();
    let mut start = 0;
    while let Some(pos) = value[start..]
        .windows(dir.len())
        .position(|window| window == dir)
    {
        let pos = start + pos;
        let end = pos + dir.len();
        // 前面是分隔符、引号或 =（键值对参数）都算路径起点；后面是分隔符
        // 或结尾才算完整目录名——`…/Game` 不能匹配 `…/Game2`
        let before_ok = pos == 0 || matches!(value[pos - 1], b'/' | b'\\' | b'"' | b'=');
        if before_ok && boundary(value, end) {
            return true;
        }
        start = pos + 1;
    }
    false
}

fn process_env(pid: i32) -> HashMap<String, String> {
    let mut env = HashMap::new();
    let Ok(bytes) = std::fs::read(format!("/proc/{pid}/environ")) else {
        return env;
    };
    for item in bytes.split(|b| *b == 0) {
        let Some(pos) = item.iter().position(|&byte| byte == b'=') else {
            continue;
        };
        env.insert(
            String::from_utf8_lossy(&item[..pos]).into_owned(),
            String::from_utf8_lossy(&item[pos + 1..]).into_owned(),
        );
    }
    env
}

pub fn scan_processes(prefix: &Path) -> Vec<ProcEntry> {
    let prefix = expand_path(&prefix.to_string_lossy());
    let mut wineprefixes: Vec<String> = Vec::new();
    if crate::core::prefix::looks_like_compat_prefix(&prefix)
        || !crate::core::prefix::looks_like_wine_prefix(&prefix)
    {
        wineprefixes.push(prefix.join("pfx").to_string_lossy().into_owned());
    }
    if crate::core::prefix::looks_like_wine_prefix(&prefix) {
        wineprefixes.push(prefix.to_string_lossy().into_owned());
    }
    let steam_data = prefix.to_string_lossy().into_owned();

    let mut result = Vec::new();
    let Ok(read) = std::fs::read_dir("/proc") else {
        return result;
    };
    let my_pid = std::process::id() as i32;
    let mut pids: Vec<i32> = read
        .flatten()
        .filter_map(|entry| entry.file_name().to_string_lossy().parse::<i32>().ok())
        .filter(|pid| *pid != my_pid)
        .collect();
    pids.sort_unstable();

    // 并行扫描：每个进程要读 environ/cmdline/exe/comm 多次 IO，
    // UU + Steam 运行时系统进程几百个，串行是刷新延迟的大头。
    // 分 8 块用 scoped thread 并行，块内结果合并后统一排序。
    let result = if pids.len() < 32 {
        for pid in &pids {
            if let Some(entry) = scan_one(*pid, &wineprefixes, &steam_data) {
                result.push(entry);
            }
        }
        result
    } else {
        let chunk_size = pids.len().div_ceil(8);
        let chunks: Vec<&[i32]> = pids.chunks(chunk_size).collect();
        let merged = std::thread::scope(|scope| {
            let mut handles = Vec::new();
            for chunk in chunks {
                // 引用是 Copy，显式重绑定后 move 进子线程
                let wp: &[String] = &wineprefixes;
                let sd: &str = &steam_data;
                let chunk: &[i32] = chunk;
                handles.push(scope.spawn(move || {
                    let mut out = Vec::new();
                    for pid in chunk {
                        if let Some(entry) = scan_one(*pid, wp, sd) {
                            out.push(entry);
                        }
                    }
                    out
                }));
            }
            handles
                .into_iter()
                .flat_map(|handle| handle.join().unwrap_or_default())
                .collect::<Vec<ProcEntry>>()
        });
        merged
    };

    let mut result = result;
    result.sort_by_key(|proc| proc.pid);
    result
}

/// 扫描单个进程：是否属于该前缀，是则返回条目
fn scan_one(
    pid: i32,
    wineprefixes: &[String],
    steam_data: &str,
) -> Option<ProcEntry> {
    let env = process_env(pid);
    let matched = wineprefixes.iter().any(|p| env.get("WINEPREFIX").is_some_and(|v| v == p))
        || env.get("STEAM_COMPAT_DATA_PATH").is_some_and(|v| *v == steam_data)
        || env.get("PROTONBOOST_PREFIX").is_some_and(|v| *v == steam_data);
    if !matched {
        return None;
    }
    let command = std::fs::read(format!("/proc/{pid}/cmdline"))
        .map(|bytes| String::from_utf8_lossy(&bytes).replace('\0', " ").trim().to_string())
        .unwrap_or_default();
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .map(|text| text.trim().to_string())
        .unwrap_or_default();
    let exe = std::fs::read_link(format!("/proc/{pid}/exe"))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    Some(ProcEntry {
        pid,
        ppid: process_parent(pid),
        exe,
        name: comm.clone(),
        command: if command.is_empty() { comm } else { command },
        age: process_start_time(pid),
        app_id: env.get("PROTONBOOST_APP_ID").cloned().unwrap_or_default(),
        app_path: env.get("PROTONBOOST_APP_PATH").cloned().unwrap_or_default(),
        log: env.get("PROTONBOOST_LOG").cloned().unwrap_or_default(),
    })
}

/// 会话主进程的启动链：Steam runtime 领养了 wineserver，不能跟着程序一起结束
pub fn session_host_pids(procs: &[ProcEntry]) -> HashSet<i32> {
    let mut hosts = HashSet::new();
    for proc in procs {
        if proc.name != "wineserver" {
            continue;
        }
        let mut pid = proc.ppid;
        for _ in 0..64 {
            if pid <= 1 {
                break;
            }
            hosts.insert(pid);
            pid = process_parent(pid);
        }
    }
    hosts
}

/// 关闭应用的目标进程集合：APP_ID 匹配的 + 命令行/可执行文件落在应用
/// 安装目录内的（UU 这类应用被关闭后，其 Windows 服务会重新拉起界面/
/// 托盘进程，那些进程由 services.exe 启动、环境里没有 APP_ID，会漏判）
/// + 上述进程的全部后代。
pub fn app_close_targets(
    procs: &[ProcEntry],
    app_id: &str,
    install_dir: &str,
    hosts: &HashSet<i32>,
) -> Vec<ProcEntry> {
    let install_dir = install_dir.trim_end_matches(['/', '\\']);
    let mut matched: Vec<&ProcEntry> = Vec::new();
    for proc in procs {
        if WINE_SESSION_PROCESSES.contains(&proc.name.as_str()) || hosts.contains(&proc.pid) {
            continue;
        }
        let from_app_id = !app_id.is_empty() && proc.app_id == app_id;
        let from_dir = !install_dir.is_empty()
            && (mentions_path_under(&proc.command, install_dir)
                || mentions_path_under(&proc.exe, install_dir));
        if from_app_id || from_dir {
            matched.push(proc);
        }
    }

    // 后代追踪：按 ppid 递归收集派生进程
    let mut children: std::collections::HashMap<i32, Vec<i32>> = std::collections::HashMap::new();
    for proc in procs {
        children.entry(proc.ppid).or_default().push(proc.pid);
    }
    let mut seen: std::collections::HashSet<i32> = matched.iter().map(|p| p.pid).collect();
    let mut queue: Vec<i32> = seen.iter().copied().collect();
    while let Some(pid) = queue.pop() {
        if let Some(kids) = children.get(&pid) {
            for kid in kids {
                if seen.insert(*kid) {
                    queue.push(*kid);
                }
            }
        }
    }

    procs
        .iter()
        .filter(|proc| seen.contains(&proc.pid))
        .cloned()
        .collect()
}

/// 运行中的应用：app_id → pids/log/path
pub fn running_apps_for_prefix(prefix: &Path) -> HashMap<String, (Vec<i32>, String, String)> {
    let mut running: HashMap<String, (Vec<i32>, String, String)> = HashMap::new();
    let procs = scan_processes(prefix);
    let hosts = session_host_pids(&procs);
    for proc in &procs {
        if proc.app_id.is_empty()
            || WINE_SESSION_PROCESSES.contains(&proc.name.as_str())
            || hosts.contains(&proc.pid)
        {
            continue;
        }
        let entry = running
            .entry(proc.app_id.clone())
            .or_insert_with(|| (Vec::new(), proc.log.clone(), proc.app_path.clone()));
        entry.0.push(proc.pid);
        if !proc.log.is_empty() {
            entry.1 = proc.log.clone();
        }
    }
    running
}

pub fn kill_pid(pid: i32, force: bool) -> Result<(), String> {
    let signal = if force { Signal::SIGKILL } else { Signal::SIGTERM };
    kill(Pid::from_raw(pid), signal).map_err(|err| err.to_string())
}
