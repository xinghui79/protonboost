// 运行器：解析 winrun --list-runner 输出，检查与执行更新
use crate::core::paths::resolve_sibling;
use std::path::PathBuf;

#[derive(Clone, Debug, Default)]
pub struct Runner {
    pub name: String,
    pub kind: String,
    pub source: String,
    pub path: String,
}

fn wrapper() -> PathBuf {
    resolve_sibling("winrun")
}

/// `winrun --list-runner` 的缩进文本 → 运行器列表
pub fn parse_runners(output: &str) -> Vec<Runner> {
    let mut runners = Vec::new();
    let mut name = String::new();
    let mut kind = String::new();
    let mut source = String::new();
    for line in output.lines() {
        if line.trim().is_empty() {
            continue;
        }
        if !line.contains(':') {
            name = line.trim().trim_start_matches("* ").trim().to_string();
        } else if let Some(value) = line.strip_prefix("      type:   ") {
            kind = value.to_string();
        } else if let Some(value) = line.strip_prefix("      source: ") {
            source = value.to_string();
        } else if let Some(value) = line.strip_prefix("      path:   ") {
            runners.push(Runner {
                name: name.clone(),
                kind: kind.clone(),
                source: source.clone(),
                path: value.to_string(),
            });
        }
    }
    runners
}

pub fn load_runners() -> Vec<Runner> {
    let output = std::process::Command::new(wrapper())
        .arg("--list-runner")
        .output();
    match output {
        Ok(output) => parse_runners(&String::from_utf8_lossy(&output.stdout)),
        Err(_) => Vec::new(),
    }
}

pub fn runner_label(runner: &Runner) -> String {
    let detail = if !runner.source.is_empty() {
        &runner.source
    } else {
        &runner.kind
    };
    if detail.is_empty() {
        runner.name.clone()
    } else {
        format!("{} · {}", runner.name, detail)
    }
}

/// 运行器路径 → 界面上的短名字（`.../compatibilitytools.d/WE-Proton Latest/proton` → `WE-Proton Latest`）
pub fn label_from_path(path: &str) -> String {
    let path = std::path::Path::new(path);
    if let Some(parent) = path.parent() {
        if let Some(name) = parent.file_name().and_then(|name| name.to_str()) {
            if !name.is_empty() && name != "compatibilitytools.d" {
                return name.to_string();
            }
        }
    }
    path.to_string_lossy().into_owned()
}

pub fn preferred_runner_path(runners: &[Runner]) -> String {
    for runner in runners {
        if runner.name == crate::core::scan::DEFAULT_RUNNER_DIR {
            return runner.path.clone();
        }
    }
    runners.first().map(|r| r.path.clone()).unwrap_or_default()
}

/// `winrun --check-update` 的 tab 分隔行 → 展示文本
pub fn describe_runner_updates(output: &str) -> String {
    let zh = crate::core::loc::zh();
    let mut lines = Vec::new();
    for line in output.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() != 5 {
            if !line.trim().is_empty() {
                lines.push(line.trim().to_string());
            }
            continue;
        }
        let (product, current, _arrow, latest, where_) = (parts[0], parts[1], parts[2], parts[3], parts[4]);
        let where_ = where_.trim_matches(['(', ')']);
        let where_ = if where_ == "local" {
            if zh { "本地".to_string() } else { "local".to_string() }
        } else {
            // GitHub 等地名首字母大写
            let mut chars = where_.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        };
        let product = match product {
            "ge" => "GE-Proton",
            "dw" => "DW-Proton",
            "we" => "WE-Proton",
            other => other,
        };
        lines.push(format!("{product} ({where_}): {current} → {latest}"));
    }
    lines.join("\n")
}

/// 检查更新（短超时），有更新时返回展示文本
pub fn check_update() -> String {
    let output = std::process::Command::new(wrapper())
        .arg("--check-update")
        .output();
    match output {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        }
        _ => String::new(),
    }
}

/// 执行更新，成功与否
pub fn update_runners() -> bool {
    std::process::Command::new(wrapper())
        .arg("--update")
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}
