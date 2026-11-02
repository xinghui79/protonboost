//! 运行日志：`~/.cache/protonboost/logs/<app-id>/latest.log`（原 lib/core.sh 的 setup_run_logging）

use crate::core::paths::cache_home;
use crate::core::scan;
use std::fs::File;
use std::path::{Path, PathBuf};

pub fn app_id(prefix: &Path, target: &Path) -> String {
    scan::app_key(prefix, target)
}

pub fn log_dir(app_id: &str) -> PathBuf {
    cache_home().join("protonboost/logs").join(app_id)
}

pub fn latest_log(app_id: &str) -> PathBuf {
    log_dir(app_id).join("latest.log")
}

/// 本次运行拿到的日志文件；上一次的日志先清掉，界面上只看得到本次
pub fn start_run(app_id: &str) -> std::io::Result<File> {
    let dir = log_dir(app_id);
    std::fs::create_dir_all(&dir)?;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if entry.path().extension().is_some_and(|ext| ext == "log") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    File::create(dir.join("latest.log"))
}
