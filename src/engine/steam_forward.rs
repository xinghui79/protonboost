//! Steam 客户端端口转发
//!
//! 游戏通过 `127.0.0.1:57343` 找 Steam 客户端。在独立网络命名空间里，
//! 这个地址是命名空间自己的回环，宿主的 Steam 客户端听不见。
//!
//! 这里在命名空间里监听这个端口，把连接转给宿主上的 Steam 客户端
//! （经由默认网关，pasta 会把网关地址转成宿主的回环）。
//! 只有宿主上确实有 Steam 在监听时才占用这个端口；宿主上没有时放开，
//! 让命名空间里自己启动的 Steam 接管。

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

/// Steam 客户端的端口
const STEAM_PORT: u16 = 57343;

/// 命名空间的默认网关（宿主那一侧）
fn default_gateway() -> Option<std::net::Ipv4Addr> {
    let output = std::process::Command::new("ip")
        .args(["-j", "-4", "route", "show", "default"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    // 简单的 JSON 取 "gateway" 字段
    let index = text.find("\"gateway\"")?;
    let rest = &text[index + 9..];
    let start = rest.find('"')? + 1;
    let end = rest[start..].find('"')? + start;
    rest[start..end].parse().ok()
}

/// 宿主上有没有进程在监听 Steam 端口
///
/// pasta（我们的父进程）与 init 跑在宿主的网络命名空间里，
/// 所以它们的 socket 表里能看到宿主上的监听。
fn host_steam_listening() -> bool {
    let local = format!("0100007F:{STEAM_PORT:04X}");
    let parent = parent_pid();
    for pid in [parent, Some(1)].into_iter().flatten() {
        let path = format!("/proc/{pid}/net/tcp");
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for line in text.lines().skip(1) {
            let fields: Vec<&str> = line.split_whitespace().collect();
            // local_address 是第 1 列，状态是第 3 列（0A = LISTEN）
            if fields.len() > 3 && fields[1] == local && fields[3] == "0A" {
                return true;
            }
        }
    }
    false
}

/// 父进程 pid（/proc/self/stat 第 4 个字段）
fn parent_pid() -> Option<u32> {
    let text = std::fs::read_to_string("/proc/self/stat").ok()?;
    // comm 字段可能含空格，取最后一个 ')' 之后的部分
    let rest = text.rsplit_once(')')?.1;
    rest.split_whitespace().nth(1)?.parse().ok()
}

/// 把一路连接的数据原样搬到另一路
fn copy_both(client: TcpStream, upstream: TcpStream) {
    let client_writer = client.try_clone().ok();
    let upstream_writer = upstream.try_clone().ok();
    let client_reader = client;
    let upstream_reader = upstream;

    // 上游 → 客户端
    let mut out = client_writer;
    let mut input = upstream_reader.try_clone().ok();
    std::thread::spawn(move || {
        let mut buffer = [0u8; 65536];
        while let Some(source) = input.as_mut() {
            match source.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(count) => {
                    let Some(sink) = out.as_mut() else { break };
                    if sink.write_all(&buffer[..count]).is_err() {
                        break;
                    }
                }
            }
        }
    });

    // 客户端 → 上游
    let mut out = upstream_writer;
    let mut input = client_reader.try_clone().ok();
    let mut buffer = [0u8; 65536];
    while let Some(source) = input.as_mut() {
        match source.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => {
                let Some(sink) = out.as_mut() else { break };
                if sink.write_all(&buffer[..count]).is_err() {
                    break;
                }
            }
        }
    }
}

/// 转发器的状态
pub struct SteamForward {
    gateway: Option<std::net::Ipv4Addr>,
    listener: Option<TcpListener>,
}

impl SteamForward {
    pub fn new() -> Self {
        Self {
            gateway: default_gateway(),
            listener: None,
        }
    }

    /// 按宿主上 Steam 的状态启停转发
    ///
    /// keeper 每秒调一次。accept 不开常驻线程：监听 socket 由 self 持有、
    /// 非阻塞地收下这一秒内到达的连接。否则宿主 Steam 重启后，accept 线程
    /// 里的克隆 fd 会让监听一直活着，重新 bind 端口永远 EADDRINUSE，
    /// 转发就静默失效了。
    pub fn update(&mut self) {
        if !host_steam_listening() {
            // 连监听一起关掉；宿主 Steam 回来时下一次 update 会重新 bind
            self.listener = None;
            return;
        }
        let Some(gateway) = self.gateway else {
            return;
        };
        if self.listener.is_none() {
            let listener = match TcpListener::bind(("127.0.0.1", STEAM_PORT)) {
                Ok(listener) => listener,
                // 命名空间里已经有 Steam 占了这个端口（自己启动的那个）
                Err(_) => return,
            };
            listener.set_nonblocking(true).ok();
            self.listener = Some(listener);
            println!("session: forwarding Steam port {STEAM_PORT} to the host");
        }
        let Some(listener) = self.listener.as_ref() else {
            return;
        };
        let gateway = gateway.to_string();
        while let Ok((client, _)) = listener.accept() {
            let gateway = gateway.clone();
            std::thread::spawn(move || {
                let Ok(upstream) = TcpStream::connect((gateway.as_str(), STEAM_PORT)) else {
                    return;
                };
                copy_both(client, upstream);
            });
        }
    }

}

impl Default for SteamForward {
    fn default() -> Self {
        Self::new()
    }
}

/// 供测试：本地地址的十六进制表示（/proc/net/tcp 用）
#[cfg(test)]
pub fn local_hex(port: u16) -> String {
    format!("0100007F:{port:04X}")
}

/// 供测试：解析默认网关
#[cfg(test)]
pub fn parse_gateway(json: &str) -> Option<std::net::Ipv4Addr> {
    let index = json.find("\"gateway\"")?;
    let rest = &json[index + 9..];
    let start = rest.find('"')? + 1;
    let end = rest[start..].find('"')? + start;
    rest[start..end].parse().ok()
}

