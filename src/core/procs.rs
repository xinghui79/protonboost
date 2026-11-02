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
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(pid) = name.parse::<i32>() else {
            continue;
        };
        if pid == my_pid {
            continue;
        }
        let env = process_env(pid);
        let matched = wineprefixes.iter().any(|p| env.get("WINEPREFIX").is_some_and(|v| v == p))
            || env.get("STEAM_COMPAT_DATA_PATH").is_some_and(|v| *v == steam_data)
            || env.get("PROTONBOOST_PREFIX").is_some_and(|v| *v == steam_data);
        if !matched {
            continue;
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
        result.push(ProcEntry {
            pid,
            ppid: process_parent(pid),
            exe,
            name: comm.clone(),
            command: if command.is_empty() { comm } else { command },
            age: process_start_time(pid),
            app_id: env.get("PROTONBOOST_APP_ID").cloned().unwrap_or_default(),
            app_path: env.get("PROTONBOOST_APP_PATH").cloned().unwrap_or_default(),
            log: env.get("PROTONBOOST_LOG").cloned().unwrap_or_default(),
        });
    }
    result.sort_by_key(|proc| proc.pid);
    result
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

pub fn is_wine_process(proc: &ProcEntry) -> bool {
    Path::new(&proc.exe)
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|name| name.starts_with("wine"))
        && proc.name != "wineserver"
}

pub fn app_own_processes(procs: &[ProcEntry], app_id: &str, hosts: &HashSet<i32>) -> Vec<ProcEntry> {
    procs
        .iter()
        .filter(|proc| {
            proc.app_id == app_id
                && !WINE_SESSION_PROCESSES.contains(&proc.name.as_str())
                && !hosts.contains(&proc.pid)
        })
        .cloned()
        .collect()
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
            && (proc.command.contains(install_dir) || proc.exe.contains(install_dir));
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
