// 应用配置文件（associations/*.conf）：KEY=VALUE，env_vars 做百分号转义
use crate::core::paths::{association_dir, expand_path};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// 与 Python 的 urllib.parse.quote 默认行为一致：除字母数字与 _.-~ 外全部转义
pub fn quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        let c = *byte as char;
        if c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-' | '~') {
            out.push(c);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

pub fn unquote(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).unwrap_or("");
            if let Ok(byte) = u8::from_str_radix(hex, 16) {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 逐行读 KEY=VALUE；env_vars 需要先反转义
pub fn read_key_values(path: &Path) -> BTreeMap<String, String> {
    let mut data = BTreeMap::new();
    let Ok(text) = std::fs::read_to_string(path) else {
        return data;
    };
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = if key == "env_vars" { unquote(value) } else { value.to_string() };
        data.insert(key.to_string(), value);
    }
    data
}

pub fn cache_file_for_path(exe: &str) -> PathBuf {
    let dir = association_dir();
    let _ = std::fs::create_dir_all(&dir);
    let mut hasher = Sha256::new();
    hasher.update(exe.as_bytes());
    let key = format!("{:x}", hasher.finalize());
    dir.join(format!("{key}.conf"))
}

/// exe 的应用配置：不存在时给默认值
pub fn default_entry() -> ConfigEntry {
    ConfigEntry {
        file: String::new(),
        name: String::new(),
        exe: String::new(),
        prefix: String::new(),
        runner: String::new(),
        program_args: String::new(),
        gamescope: false,
        gamescope_fullscreen: true,
        gamescope_res: String::new(),
        gamescope_fps: String::new(),
        gamescope_fsr: false,
        gamescope_args: String::new(),
        mangohud: false,
        wayland: false,
        env_vars: String::new(),
        steam_appid: String::new(),
        source: "configured".into(),
    }
}

#[derive(Clone, Debug, Default)]
pub struct ConfigEntry {
    pub file: String,
    pub name: String,
    pub exe: String,
    pub prefix: String,
    pub runner: String,
    pub program_args: String,
    pub gamescope: bool,
    pub gamescope_fullscreen: bool,
    pub gamescope_res: String,
    pub gamescope_fps: String,
    pub gamescope_fsr: bool,
    pub gamescope_args: String,
    pub mangohud: bool,
    pub wayland: bool,
    pub env_vars: String,
    pub steam_appid: String,
    pub source: String,
}

impl ConfigEntry {
    pub fn from_map(data: &BTreeMap<String, String>, file: &str) -> Self {
        let flag = |key: &str| data.get(key).is_some_and(|value| value == "1");
        ConfigEntry {
            file: file.to_string(),
            name: data.get("name").cloned().unwrap_or_default(),
            exe: data.get("exe").cloned().unwrap_or_default(),
            prefix: data.get("prefix").cloned().unwrap_or_default(),
            runner: data.get("runner").cloned().unwrap_or_default(),
            program_args: data.get("program_args").cloned().unwrap_or_default(),
            gamescope: flag("gamescope"),
            gamescope_fullscreen: data.get("gamescope_fullscreen").map(|v| v != "0").unwrap_or(true),
            gamescope_res: data.get("gamescope_res").cloned().unwrap_or_default(),
            gamescope_fps: data.get("gamescope_fps").cloned().unwrap_or_default(),
            gamescope_fsr: flag("gamescope_fsr"),
            gamescope_args: data.get("gamescope_args").cloned().unwrap_or_default(),
            mangohud: flag("mangohud"),
            wayland: flag("wayland"),
            env_vars: data.get("env_vars").cloned().unwrap_or_default(),
            steam_appid: data.get("steam_appid").cloned().unwrap_or_default(),
            source: data.get("source").cloned().unwrap_or_else(|| "configured".into()),
        }
    }

    pub fn read(exe: &str) -> Option<Self> {
        let path = cache_file_for_path(exe);
        let data = read_key_values(&path);
        if data.is_empty() {
            return None;
        }
        Some(Self::from_map(&data, &path.to_string_lossy()))
    }

    /// 写盘：改名时旧文件移动到新 exe 对应的哈希文件名
    pub fn write(&self) -> Result<PathBuf, String> {
        let path = cache_file_for_path(&self.exe);
        if !self.file.is_empty() && Path::new(&self.file) != path && Path::new(&self.file).is_file() {
            let _ = std::fs::remove_file(&self.file);
        }
        let mut text = String::new();
        if !self.name.is_empty() {
            text.push_str(&format!("name={}\n", self.name));
        }
        text.push_str(&format!(
            "exe={}\nprefix={}\nrunner={}\nprogram_args={}\n\
             gamescope={}\ngamescope_fullscreen={}\ngamescope_res={}\ngamescope_fps={}\n\
             gamescope_fsr={}\ngamescope_args={}\nmangohud={}\nwayland={}\nenv_vars={}\n",
            self.exe,
            self.prefix,
            self.runner,
            self.program_args,
            if self.gamescope { 1 } else { 0 },
            if self.gamescope_fullscreen { 1 } else { 0 },
            self.gamescope_res,
            self.gamescope_fps,
            if self.gamescope_fsr { 1 } else { 0 },
            self.gamescope_args,
            if self.mangohud { 1 } else { 0 },
            if self.wayland { 1 } else { 0 },
            quote(&self.env_vars),
        ));
        if !self.steam_appid.is_empty() {
            text.push_str(&format!("steam_appid={}\n", self.steam_appid));
        }
        text.push_str(&format!("source={}\n", self.source));
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|err| err.to_string())?;
        }
        std::fs::write(&path, text).map_err(|err| err.to_string())?;
        Ok(path)
    }
}

/// 按修改时间从新到旧列出全部配置；exe 没了且所在目录还在的（确实被删了
/// 这个文件）顺手清掉。目录也不在的先留着——可能是外置盘/网络盘没挂载，
/// 自动删会把用户的运行设置误清掉；这些条目在列表里带「目标不存在」标记
pub fn collect_cache_entries() -> Vec<ConfigEntry> {
    let dir = association_dir();
    let mut entries: Vec<(std::time::SystemTime, ConfigEntry)> = Vec::new();
    if let Ok(read) = std::fs::read_dir(&dir) {
        for entry in read.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|ext| ext != "conf") {
                continue;
            }
            let data = read_key_values(&path);
            let Some(exe) = data.get("exe").cloned() else {
                continue;
            };
            let exe_path = expand_path(&exe);
            if !exe_path.exists() && exe_path.parent().is_some_and(|p| p.is_dir()) {
                let _ = std::fs::remove_file(&path);
                continue;
            }
            let modified = entry.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
            let mut config = ConfigEntry::from_map(&data, &path.to_string_lossy());
            if config.name.is_empty() {
                config.name = crate::core::scan::inferred_exe_name(&exe_path, None);
            }
            entries.push((modified, config));
        }
    }
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    entries.into_iter().map(|(_, entry)| entry).collect()
}

/// 按 exe 找它保存过的配置：返回 (前缀, 配置)，导出的桌面入口启动时用
pub fn find_for_target(target: &std::path::Path) -> Option<(PathBuf, ConfigEntry)> {
    let key = target.to_string_lossy();
    let mut entry = ConfigEntry::read(&key)?;
    let prefix = if entry.prefix.is_empty() {
        crate::core::prefix::collect_prefixes().into_iter().next()?
    } else {
        expand_path(&entry.prefix)
    };
    if entry.prefix.is_empty() {
        entry.prefix = prefix.to_string_lossy().into_owned();
    }
    entry.exe = key.into_owned();
    Some((prefix, entry))
}
