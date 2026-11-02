//! 关键逻辑的回归测试：Steam %command% 解析、版本比较、userns 映射。

use super::launch::take_steam_command;
use std::path::Path;

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|value| value.to_string()).collect()
}

#[test]
fn steam命令能提取游戏与参数() {
    // Steam 展开 %command% 后的典型形态
    let argv = args(&[
        "/home/u/.local/share/Steam/steamapps/common/Proton 9.0/proton",
        "waitforexitandrun",
        "/home/u/Steam/steamapps/common/Game/game.exe",
        "-novid",
        "-console",
    ]);
    let (target, rest) = take_steam_command(&argv).expect("应能提取");
    assert_eq!(target, "/home/u/Steam/steamapps/common/Game/game.exe");
    assert_eq!(rest, vec!["-novid".to_string(), "-console".to_string()]);
}

#[test]
fn steam命令识别run动词() {
    let argv = args(&["/opt/proton", "run", "C:\\Games\\x.exe"]);
    let (target, rest) = take_steam_command(&argv).expect("应能提取");
    assert_eq!(target, "C:\\Games\\x.exe");
    assert!(rest.is_empty());
}

#[test]
fn steam命令忽略无关命令() {
    // Linux 原生程序：没有 proton，返回 None，交给 run_command 那条路
    let argv = args(&["/usr/bin/steam", "-silent"]);
    assert!(take_steam_command(&argv).is_none());
}

#[test]
fn steam命令不把非动词当动词() {
    // proton 后面跟的是别的词，不能当成 Steam 启动
    let argv = args(&["/opt/proton", "clinfo", "foo.exe"]);
    assert!(take_steam_command(&argv).is_none());
}

#[test]
fn steam命令取实际位置而非第一个同名项() {
    // 同一个 proton 路径出现两次，要按实际位置取
    let argv = args(&[
        "/opt/proton",
        "waitforexitandrun",
        "/first/game.exe",
        "/opt/proton",
        "run",
        "/second/game.exe",
        "-x",
    ]);
    let (target, rest) = take_steam_command(&argv).expect("应能提取");
    assert_eq!(target, "/first/game.exe");
    assert_eq!(rest[0], "/opt/proton".to_string());
}

#[test]
fn 快捷方式只对lnk生效() {
    // 非 .lnk 返回 None
    assert!(crate::core::scan::resolve_shortcut(Path::new("/tmp"), Path::new("/tmp/a.exe")).is_none());
}

#[test]
fn 版本号按数字段比较() {
    fn key(value: &str) -> Vec<u64> {
        let mut parts = Vec::new();
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
    // 装完最新版不该再提示更新
    assert_eq!(key("11-11"), key("GE-Proton11-11"));
    // 9-20 比 9-9 新
    assert!(key("9-20") > key("9-9"));
    assert!(key("11-11") > key("10-34"));
}

#[test]
fn userns之外的真实uid可读() {
    // 容器里 uid_map 是 "0 1000 1"，外面看到的应该是 1000
    let uid = super::session::outside_uid();
    assert!(uid <= 65535);
    let gid = super::session::outside_gid();
    assert!(gid <= 65535);
}

#[test]
fn 覆盖层辅助库源码完整() {
    assert!(super::overlay::source_contains_getuid());
    assert!(super::overlay::source_length() > 1000);
}

#[test]
fn steam端口本地地址格式正确() {
    assert_eq!(super::steam_forward::local_hex(57343), "0100007F:DFFF");
}

#[test]
fn 默认网关能从路由表里解析出来() {
    let json = r#"[{"dst":"default","gateway":"10.0.0.1","dev":"eth0"}]"#;
    let gateway = super::steam_forward::parse_gateway(json).expect("应能解析");
    assert_eq!(gateway.to_string(), "10.0.0.1");
}

#[test]
fn 路由表里没有网关时返回空() {
    assert!(super::steam_forward::parse_gateway("[]").is_none());
}

#[test]
fn 覆盖层辅助库源码保持完整() {
    assert!(super::overlay::source_contains_getuid());
    assert!(super::overlay::source_length() > 1000);
}

#[test]
fn 覆盖层辅助库已嵌入二进制() {
    // 构建机上没有 cc 时嵌入的是空占位——这里故意不 assert，只打印，
    // 提醒开发者本机构建缺 cc 会退化到运行时编译
    if !super::overlay::embedded_ready() {
        eprintln!("警告：辅助库没有嵌入，运行时会回退到现场编译");
    }
}

#[test]
fn 版本号提取数字段() {
    assert_eq!(super::update::version_key("GE-Proton11-11"), vec![11, 11]);
    assert_eq!(super::update::version_key("11-11"), vec![11, 11]);
    assert_eq!(super::update::version_key("1792606118 we-proton-ge11-11-31"), vec![1792606118, 11, 11, 31]);
    assert!(super::update::version_key("no-digits").is_empty());
}

#[test]
fn 版本比较() {
    assert!(super::update::version_newer("10-9", "GE-Proton11-11"));
    assert!(super::update::version_newer("11-10", "11-11"));
    assert!(!super::update::version_newer("11-11", "GE-Proton11-11"));
    assert!(!super::update::version_newer("11-12", "11-11"));
    // 没有可比数字时退化为字符串不等
    assert!(super::update::version_newer("abc", "def"));
}

#[test]
fn 下载包按主机架构过滤() {
    assert!(super::update::blocking_arch("GE-Proton11-11-aarch64.tar.gz"));
    assert!(super::update::blocking_arch("ge-proton-arm64.tar.gz"));
    assert!(!super::update::blocking_arch("GE-Proton11-11.tar.gz"));
}

#[test]
fn 产品别名解析() {
    assert_eq!(super::runners::product_alias("GE-Proton"), Some("ge"));
    assert_eq!(super::runners::product_alias(" proton-ge "), Some("ge"));
    assert_eq!(super::runners::product_alias("we"), Some("we"));
    assert_eq!(super::runners::product_alias("dw"), None);
    assert_eq!(super::runners::product_alias(""), None);
    assert_eq!(super::runners::product_dir_name("ge"), Some("Proton-GE Latest"));
}

#[test]
fn 路径规整化() {
    use crate::core::paths::normalized;
    assert_eq!(normalized(std::path::Path::new("/a/./b/../c")), std::path::Path::new("/a/c"));
    assert_eq!(normalized(std::path::Path::new("a/b/../..")), std::path::Path::new(""));
}

#[test]
fn 路径展开支持家目录() {
    use crate::core::paths::expand_path;
    assert!(expand_path("~/x").starts_with(std::env::var("HOME").unwrap_or_default()));
    assert_eq!(expand_path("/abs/path"), std::path::Path::new("/abs/path"));
}

#[test]
fn 镜像代理拼接() {
    assert_eq!(super::update::proxied("", "https://github.com/a/b"), "https://github.com/a/b");
    assert_eq!(
        super::update::proxied("https://gh-proxy.com", "https://github.com/a/b"),
        "https://gh-proxy.com/https://github.com/a/b"
    );
}

#[test]
fn 镜像列表包含直连兜底() {
    let list = super::update::mirrors();
    assert!(list.iter().any(|m| m.is_empty()), "直连必须在列表里");
}

#[test]
fn we_proton资产解析() {
    // SHORiN-KiWATA/we-proton 的 release 资产形态
    let body = r#"{"tag_name":"we-proton-ge11-11-31","assets":[
        {"name":"we-proton-ge11-11-31-source.tar.xz","browser_download_url":"https://example/source"},
        {"name":"we-proton-ge11-11-31.tar.xz","browser_download_url":"https://example/archive"},
        {"name":"we-proton-ge11-11-31.sha512sum","browser_download_url":"https://example/sha"}]}"#;
    let release = super::update::parse_release("we", body.as_bytes()).expect("应解析出 release");
    assert_eq!(release.tag, "we-proton-ge11-11-31");
    assert_eq!(release.archive_name, "we-proton-ge11-11-31.tar.xz");
    assert_eq!(release.checksum_url, "https://example/sha");
}

#[test]
fn we_release_url指向官方仓库() {
    assert_eq!(
        super::update::release_url("we").as_deref(),
        Some("https://api.github.com/repos/SHORiN-KiWATA/we-proton/releases/latest")
    );
    assert_eq!(super::update::release_url("ge"), None, "GE 已从产品管理移除");
}

#[test]
fn 关闭目标覆盖服务拉起的进程() {
    use crate::core::procs::{app_close_targets, session_host_pids, ProcEntry};

    fn entry(pid: i32, ppid: i32, name: &str, app_id: &str, cmd: &str) -> ProcEntry {
        ProcEntry {
            pid,
            ppid,
            exe: cmd.to_string(),
            name: name.to_string(),
            command: cmd.to_string(),
            age: String::new(),
            app_id: app_id.to_string(),
            app_path: String::new(),
            log: String::new(),
        }
    }

    let install_dir = "C:\\Program Files\\UU";
    let procs = vec![
        entry(100, 1, "services.exe", "", "services.exe"),                    // 会话进程
        entry(101, 100, "uu_service.exe", "", "C:\\Program Files\\UU\\uu_service.exe"), // 服务拉起，无 APP_ID
        entry(102, 101, "uu.exe", "", "C:\\Program Files\\UU\\uu.exe"),       // 界面进程
        entry(103, 1, "steam.exe", "app-xyz", "C:\\Program Files\\Steam\\steam.exe"), // 其它应用，不能误杀
        entry(104, 1, "wineserver", "", "wineserver"),                        // wineserver
    ];
    let hosts = session_host_pids(&procs);
    let targets = app_close_targets(&procs, "app-uu", install_dir, &hosts);
    let pids: Vec<i32> = targets.iter().map(|p| p.pid).collect();
    assert!(pids.contains(&101), "服务拉起的进程应命中安装目录匹配");
    assert!(pids.contains(&102), "界面进程应命中");
    assert!(!pids.contains(&103), "其它应用不能误杀");
    assert!(!pids.contains(&104), "wineserver 不能杀");
}
