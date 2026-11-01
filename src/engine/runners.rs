//! 运行器发现与解析（原 lib/utils.sh 的 collect_runners 与 lib/product.sh）

use crate::core::paths::{expand_path, home, xdg};
use std::collections::HashSet;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Runner {
    /// 目录名，例如 `WE-Proton Latest`
    pub name: String,
    /// proton | wine
    pub kind: String,
    /// steam | local | lutris | steam-library …
    pub source: String,
    /// proton / wine 可执行文件的绝对路径
    pub path: String,
}

pub const DEFAULT_PRODUCT: &str = "we";

pub fn steam_runner_dir() -> PathBuf {
    home().join(".local/share/Steam/compatibilitytools.d")
}

pub fn local_runner_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join("proton/runners")
}

pub fn steam_root_dir() -> PathBuf {
    let first = home().join(".local/share/Steam");
    if first.is_dir() {
        return first;
    }
    home().join(".steam/root")
}

/// ge / dw / we 的产品别名 → 规范名
pub fn product_alias(value: &str) -> Option<&'static str> {
    match value.trim().to_lowercase().as_str() {
        "ge" | "ge-proton" | "proton-ge" => Some("ge"),
        "dw" | "dwproton" | "dw-proton" | "dw_proton" => Some("dw"),
        "we" | "weproton" | "we-proton" | "we_proton" => Some("we"),
        _ => None,
    }
}

/// 产品 → compatibilitytools.d 里的 Latest 目录名
pub fn product_dir_name(product: &str) -> Option<&'static str> {
    match product {
        "ge" => Some("Proton-GE Latest"),
        "dw" => Some("DW-Proton Latest"),
        "we" => Some("WE-Proton Latest"),
        _ => None,
    }
}

/// 界面上的短名字：`WE-Proton Latest · Steam`
pub fn label(runner: &Runner) -> String {
    let detail = if runner.source.is_empty() { &runner.kind } else { &runner.source };
    if detail.is_empty() {
        runner.name.clone()
    } else {
        format!("{} · {}", runner.name, detail)
    }
}

/// 只有路径时的兜底名字：`.../compatibilitytools.d/WE-Proton Latest/proton` → `WE-Proton Latest`
pub fn label_from_path(path: &str) -> String {
    let path = Path::new(path);
    if let Some(parent) = path.parent() {
        if let Some(name) = parent.file_name().and_then(|name| name.to_str()) {
            if !name.is_empty() && name != "compatibilitytools.d" {
                return name.to_string();
            }
        }
    }
    path.to_string_lossy().into_owned()
}

pub fn name_from_path(kind: &str, path: &Path) -> String {
    let mut root = path.parent().unwrap_or(Path::new("/")).to_path_buf();
    if kind != "proton" {
        for _ in 0..2 {
            if root.file_name().is_some_and(|name| name == "bin" || name == "files") {
                root = root.parent().unwrap_or(Path::new("/")).to_path_buf();
            }
        }
    }
    root.file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("runner")
        .to_string()
}

fn is_executable(path: &Path) -> bool {
    path.metadata()
        .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// 架构检查：`file` 说得出来又不匹配时跳过，说不出来（脚本包装）就当匹配
fn arch_matches(path: &Path) -> bool {
    let mut binary = path.to_path_buf();
    if path.file_name().is_some_and(|name| name == "proton") {
        let root = path.parent().unwrap_or(Path::new("/"));
        let candidates = [
            root.join("files/bin/wine64"),
            root.join("files/bin/wine"),
            root.join("bin/wine64"),
            root.join("bin/wine"),
        ];
        match candidates.iter().find(|candidate| candidate.is_file()) {
            Some(found) => binary = found.clone(),
            None => return true,
        }
    }
    let output = std::process::Command::new("file")
        .arg("-L")
        .arg("-b")
        .arg(&binary)
        .output();
    let Ok(output) = output else {
        return true;
    };
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let host = std::env::consts::ARCH;
    let runner_arch = if text.contains("ARM aarch64") || text.contains("ARM64") {
        "aarch64"
    } else if text.contains("x86-64") || text.contains("x86_64") || text.contains("AMD x86-64") {
        "x86_64"
    } else if text.contains("Intel 80386") || text.contains("80386") {
        "x86"
    } else {
        return true;
    };
    runner_arch == host || (host == "x86_64" && runner_arch == "x86")
}

struct Collector {
    runners: Vec<Runner>,
    seen: HashSet<String>,
}

impl Collector {
    fn add(&mut self, kind: &str, source: &str, path: &Path) {
        if !is_executable(path) || !arch_matches(path) {
            return;
        }
        let real = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let key = real.to_string_lossy().into_owned();
        if !self.seen.insert(key.clone()) {
            return;
        }
        self.runners.push(Runner {
            name: name_from_path(kind, path),
            kind: kind.to_string(),
            source: source.to_string(),
            path: key,
        });
    }

    /// 通配的一批路径：目录里每个子目录下的 proton / wine
    fn add_glob(&mut self, kind: &str, source: &str, base: &Path, leaf: &str) {
        let Ok(entries) = std::fs::read_dir(base) else {
            return;
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path().join(leaf))
            .filter(|path| is_executable(path))
            .collect();
        paths.sort();
        for path in paths {
            self.add(kind, source, &path);
        }
    }
}

fn steam_libraries() -> Vec<PathBuf> {
    let mut libraries = Vec::new();
    for file in [
        home().join(".local/share/Steam/steamapps/libraryfolders.vdf"),
        home().join(".steam/root/steamapps/libraryfolders.vdf"),
    ] {
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        for line in text.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("\"path\"") {
                if let Some(value) = rest.split('"').nth(1) {
                    if !value.is_empty() {
                        libraries.push(expand_path(value));
                    }
                }
            }
        }
    }
    libraries
}

/// 找出机器上所有可用运行器，顺序即优先级
pub fn discover() -> Vec<Runner> {
    let mut collector = Collector { runners: Vec::new(), seen: HashSet::new() };
    let steam_dir = home().join(".local/share/Steam");
    let steam_root = home().join(".steam/root");
    let local_dir = local_runner_dir();
    let default_dir = product_dir_name(DEFAULT_PRODUCT).unwrap_or("WE-Proton Latest");

    for variable in ["WINRUN_RUNNER", "PROTON_GE_PATH"] {
        if let Ok(value) = std::env::var(variable) {
            if !value.trim().is_empty() {
                if let Some(runner) = resolve(&value) {
                    collector.add(&runner.kind, "env", Path::new(&runner.path));
                }
            }
        }
    }

    // 默认运行器排最前
    for base in [steam_runner_dir(), local_dir.clone()] {
        collector.add("proton", "steam", &base.join(default_dir).join("proton"));
    }

    for base in [steam_dir.join("compatibilitytools.d"), steam_root.join("compatibilitytools.d")] {
        for product in ["DW-Proton Latest", "Proton-GE Latest"] {
            collector.add("proton", "steam", &base.join(product).join("proton"));
        }
        collector.add_glob("proton", "steam", &base, "proton");
    }
    collector.add_glob("proton", "local", &local_dir, "proton");

    for base in [
        PathBuf::from("/usr/share/steam/compatibilitytools.d"),
        PathBuf::from("/usr/lib/steam/compatibilitytools.d"),
    ] {
        collector.add_glob("proton", "steam-system", &base, "proton");
    }

    collector.add_glob(
        "proton",
        "steam-flatpak",
        &home().join(".var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"),
        "proton",
    );

    for base in [
        home().join(".local/share/lutris/runners/proton"),
        home().join(".local/share/lutris/runners/wine"),
        home().join(".var/app/net.lutris.Lutris/data/lutris/runners/proton"),
        home().join(".var/app/net.lutris.Lutris/data/lutris/runners/wine"),
    ] {
        collector.add_glob("proton", "lutris", &base, "proton");
    }

    // Steam 自带的 Proton
    for base in [
        steam_dir.join("steamapps/common"),
        steam_root.join("steamapps/common"),
    ] {
        let Ok(entries) = std::fs::read_dir(&base) else {
            continue;
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("Proton"))
            })
            .map(|path| path.join("proton"))
            .filter(|path| is_executable(path))
            .collect();
        paths.sort();
        for path in paths {
            collector.add("proton", "steam-official", &path);
        }
    }

    for library in steam_libraries() {
        let base = library.join("steamapps/common");
        let Ok(entries) = std::fs::read_dir(&base) else {
            continue;
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("Proton"))
            })
            .map(|path| path.join("proton"))
            .filter(|path| is_executable(path))
            .collect();
        paths.sort();
        for path in paths {
            collector.add("proton", "steam-library", &path);
        }
    }

    // lutris 里的纯 wine（没有自带 proton 的才算）
    for base in [
        home().join(".local/share/lutris/runners/wine"),
        home().join(".var/app/net.lutris.Lutris/data/lutris/runners/wine"),
    ] {
        let Ok(entries) = std::fs::read_dir(&base) else {
            continue;
        };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .flat_map(|dir| [dir.join("files/bin/wine"), dir.join("bin/wine")])
            .filter(|path| is_executable(path))
            .collect();
        paths.sort();
        for path in paths {
            let root = path.parent().and_then(|bin| bin.parent()).unwrap_or(Path::new("/"));
            let root = if root.ends_with("files") {
                root.parent().unwrap_or(Path::new("/"))
            } else {
                root
            };
            if root.join("proton").exists() {
                continue;
            }
            collector.add("wine", "lutris-wine", &path);
        }
    }

    collector.runners
}

/// `--runner` 参数或界面里的选择 → 运行器
pub fn resolve(input: &str) -> Option<Runner> {
    let input = input.trim();
    if input.is_empty() {
        return None;
    }
    if let Some(product) = product_alias(input) {
        let dir_name = product_dir_name(product)?;
        let runners = discover();
        if let Some(runner) = runners.iter().find(|runner| runner.name == dir_name) {
            return Some(runner.clone());
        }
        for base in [steam_runner_dir(), local_runner_dir()] {
            for candidate in base.ancestors().take(1) {
                let _ = candidate;
            }
            let path = base.join(dir_name).join("proton");
            if is_executable(&path) {
                return Some(Runner {
                    name: dir_name.to_string(),
                    kind: "proton".into(),
                    source: "steam".into(),
                    path: path.to_string_lossy().into_owned(),
                });
            }
        }
        return None;
    }

    let path = expand_path(input);
    if path.is_dir() {
        let proton = path.join("proton");
        if is_executable(&proton) {
            return Some(Runner {
                name: name_from_path("proton", &proton),
                kind: "proton".into(),
                source: "path".into(),
                path: proton.to_string_lossy().into_owned(),
            });
        }
        for wine in [path.join("files/bin/wine"), path.join("bin/wine")] {
            if is_executable(&wine) {
                return Some(Runner {
                    name: name_from_path("wine", &wine),
                    kind: "wine".into(),
                    source: "path".into(),
                    path: wine.to_string_lossy().into_owned(),
                });
            }
        }
        return None;
    }
    if is_executable(&path) {
        let kind = match path.file_name().and_then(|name| name.to_str()) {
            Some("wine") | Some("wine64") => "wine",
            _ => "proton",
        };
        return Some(Runner {
            name: name_from_path(kind, &path),
            kind: kind.into(),
            source: "path".into(),
            path: path.to_string_lossy().into_owned(),
        });
    }
    None
}

/// 前缀里记着的运行器，没有就用第一个可用的
pub fn for_prefix(prefix: &Path) -> Option<Runner> {
    let stored = crate::core::prefix::prefix_runner(prefix);
    if !stored.is_empty() {
        if let Some(runner) = resolve(&stored) {
            return Some(runner);
        }
    }
    discover().into_iter().next()
}
