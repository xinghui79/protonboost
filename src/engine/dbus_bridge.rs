//! D-Bus 会话桥：让独立网络里的程序用上宿主的会话总线
//!
//! pasta 把用户映射成命名空间里的 root，里面的程序（Wine 与未降权的
//! Linux 程序）带着 `uid 0` 去 SASL 认证；宿主的会话总线一查对端凭证是
//! uid 1000，不匹配就拒绝——托盘图标、桌面通知、fcitx5 输入法全部哑火。
//!
//! keeper 在会话目录里起一个代理 socket（`<会话目录>/bus`），客户端连上后
//! 把 `AUTH EXTERNAL <hex uid>` 里的 uid 改写成真实 uid 再转给宿主总线，
//! 其余字节（包括 NEGOTIATE_UNIX_FD 之后的文件描述符传递）全部透传。
//! 对客户端来说它就是一条普通的会话总线连接。
//!
//! 命名空间与宿主共享文件系统，所以客户端和桥之间用 unix socket 即可，
//! 不需要走 TCP——这也让 fd 传递（SCM_RIGHTS）能原样通过。
//!
//! fd 的收发直接走 libc 的 recvmsg/sendmsg：nix 的 socket 支持会多拉一个
//! 依赖，这里只用得到这一对调用，不值得。

use std::io::{Read, Write};
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// 宿主会话总线的地址：从 DBUS_SESSION_BUS_ADDRESS 里解析 unix path，
/// 没有该变量时退回 $XDG_RUNTIME_DIR/bus。
pub fn host_bus_address() -> Option<PathBuf> {
    let raw = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap_or_default();
    for part in raw.split(';') {
        if let Some(rest) = part.trim().strip_prefix("unix:") {
            for field in rest.split(',') {
                if let Some(path) = field.strip_prefix("path=") {
                    let path = PathBuf::from(path);
                    if path.exists() {
                        return Some(path);
                    }
                }
            }
        }
    }
    let fallback = crate::core::paths::xdg("XDG_RUNTIME_DIR", "/run/user/0").join("bus");
    fallback.exists().then_some(fallback)
}

/// keeper 入口：在 listen 位置起桥，连到宿主总线上。失败静默——
/// 没有总线环境（比如纯 tty）时程序照常跑。
pub fn start(listen: &Path, bus: &Path, real_uid: u32) {
    let Ok(listener) = UnixListener::bind(listen) else {
        return;
    };
    let bus = bus.to_path_buf();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let bus = bus.clone();
            std::thread::spawn(move || {
                serve(stream, &bus, real_uid);
            });
        }
    });
}

/// 服务一条客户端连接：改写认证阶段，之后双向透传（含 fd）
fn serve(client: UnixStream, bus: &Path, real_uid: u32) {
    let Ok(upstream) = UnixStream::connect(bus) else {
        return;
    };
    let client_reader = match client.try_clone() {
        Ok(reader) => reader,
        Err(_) => return,
    };
    let upstream_writer = match upstream.try_clone() {
        Ok(writer) => writer,
        Err(_) => return,
    };

    // 客户端 → 总线：先改写 AUTH 行，进入 BEGIN 后转纯透传（要过 fd）
    let auth = std::thread::spawn(move || {
        auth_pump(client_reader, upstream_writer, real_uid);
    });
    // 总线 → 客户端：纯透传（流的 owner 活到线程结束，fd 才不会提前关掉）
    let back_from = upstream;
    let back_to = client;
    std::thread::spawn(move || {
        let from = back_from.as_raw_fd();
        let to = back_to.as_raw_fd();
        pump(from, to);
    });
    let _ = auth.join();
}

/// SASL 阶段的客户端泵：逐行改写 `AUTH EXTERNAL <uid>`，看到 BEGIN 就地切换
fn auth_pump(mut reader: UnixStream, mut writer: UnixStream, real_uid: u32) {
    let mut rewriter = AuthRewriter::new(real_uid);
    let mut buf = [0u8; 4096];
    loop {
        let count = match reader.read(&mut buf) {
            Ok(count) => count,
            Err(_) => return,
        };
        if count == 0 {
            return;
        }
        let out = rewriter.feed(&buf[..count]);
        if write_all(&mut writer, &out).is_err() {
            return;
        }
        if rewriter.done() {
            // BEGIN 之后改走带 fd 转发的透传；
            // 流的所有权还在这两个变量手里，pump 只借裸 fd，函数返回时才关闭
            let from = reader.as_raw_fd();
            let to = writer.as_raw_fd();
            pump(from, to);
            return;
        }
    }
}

fn write_all(stream: &mut UnixStream, data: &[u8]) -> std::io::Result<()> {
    stream.write_all(data)
}

// ---------- libc 层：带 SCM_RIGHTS 的收发 ----------

/// recvmsg：返回 (字节数, 随消息到达的 fd)。对端关闭返回 None。
fn recv_with_fds(fd: RawFd, buf: &mut [u8]) -> Option<(usize, Vec<RawFd>)> {
    unsafe {
        let mut iov = nix::libc::iovec {
            iov_base: buf.as_mut_ptr().cast(),
            iov_len: buf.len(),
        };
        let mut cmsg_buf = [0u8; 512];
        let mut msg: nix::libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsg_buf.as_mut_ptr().cast();
        msg.msg_controllen = cmsg_buf.len();
        let count = nix::libc::recvmsg(fd, &mut msg, nix::libc::MSG_CMSG_CLOEXEC);
        if count < 0 {
            return None;
        }
        let mut fds = Vec::new();
        let mut hdr = nix::libc::CMSG_FIRSTHDR(&msg);
        while !hdr.is_null() {
            if (*hdr).cmsg_level == nix::libc::SOL_SOCKET
                && (*hdr).cmsg_type == nix::libc::SCM_RIGHTS
            {
                let payload = (*hdr).cmsg_len as usize - nix::libc::CMSG_LEN(0) as usize;
                let count = payload / std::mem::size_of::<RawFd>();
                let data = nix::libc::CMSG_DATA(hdr) as *const RawFd;
                for i in 0..count {
                    fds.push(*data.add(i));
                }
            }
            hdr = nix::libc::CMSG_NXTHDR(&msg, hdr);
        }
        Some((count as usize, fds))
    }
}

/// sendmsg：数据与 fd 一起发出去
fn send_with_fds(fd: RawFd, data: &[u8], fds: &[RawFd]) -> bool {
    unsafe {
        let mut iov = nix::libc::iovec {
            iov_base: data.as_ptr() as *mut nix::libc::c_void,
            iov_len: data.len(),
        };
        let space = nix::libc::CMSG_SPACE((fds.len() * 4) as u32) as usize;
        let mut cmsg_buf = vec![0u8; space];
        let mut msg: nix::libc::msghdr = std::mem::zeroed();
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsg_buf.as_mut_ptr().cast();
        msg.msg_controllen = cmsg_buf.len();

        let hdr = nix::libc::CMSG_FIRSTHDR(&msg);
        (*hdr).cmsg_level = nix::libc::SOL_SOCKET;
        (*hdr).cmsg_type = nix::libc::SCM_RIGHTS;
        (*hdr).cmsg_len = nix::libc::CMSG_LEN((fds.len() * 4) as u32) as usize;
        std::ptr::copy_nonoverlapping(fds.as_ptr(), nix::libc::CMSG_DATA(hdr).cast(), fds.len());

        nix::libc::sendmsg(fd, &msg, 0) >= 0
    }
}

/// 双向透传：带 ancillary 数据转发（SCM_RIGHTS 的文件描述符）
fn pump(from: RawFd, to: RawFd) {
    let mut buf = [0u8; 65536];
    loop {
        match recv_with_fds(from, &mut buf) {
            Some((0, _)) | None => return,
            Some((count, fds)) => {
                let data = &buf[..count];
                let ok = if fds.is_empty() {
                    write_fd(to, data)
                } else {
                    send_with_fds(to, data, &fds) && {
                        for fd in &fds {
                            unsafe { nix::libc::close(*fd) };
                        }
                        true
                    }
                };
                if !ok {
                    for fd in &fds {
                        unsafe { nix::libc::close(*fd) };
                    }
                    return;
                }
            }
        }
    }
}

fn write_fd(fd: RawFd, data: &[u8]) -> bool {
    let mut written = 0;
    while written < data.len() {
        let n = unsafe { nix::libc::write(fd, data[written..].as_ptr().cast(), data.len() - written) };
        if n <= 0 {
            return false;
        }
        written += n as usize;
    }
    true
}

/// SASL 认证阶段的行改写器。D-Bus 的 EXTERNAL 认证把 uid 的十进制字符串
/// 做十六进制编码后放在 `AUTH EXTERNAL ` 后面；命名空间里的客户端报的是
/// 自己视角的 uid（root 时是 0），总线认的是真实 uid——改写成后者。
pub(crate) struct AuthRewriter {
    uid: u32,
    done: bool,
    pending: Vec<u8>,
    saw_bom: bool,
}

impl AuthRewriter {
    pub(crate) fn new(uid: u32) -> Self {
        Self { uid, done: false, pending: Vec::new(), saw_bom: false }
    }

    pub(crate) fn done(&self) -> bool {
        self.done
    }

    pub(crate) fn feed(&mut self, chunk: &[u8]) -> Vec<u8> {
        if self.done {
            return chunk.to_vec();
        }
        self.pending.extend_from_slice(chunk);
        let mut out = Vec::with_capacity(self.pending.len());
        // SASL 流以一个 \0 开头，原样放行
        while !self.saw_bom && self.pending.first() == Some(&0) {
            self.pending.remove(0);
            out.push(0);
            self.saw_bom = true;
        }
        while let Some(pos) = find_line_end(&self.pending) {
            let line: Vec<u8> = self.pending.drain(..pos).collect();
            self.pending.drain(..2); // \r\n
            let text = String::from_utf8_lossy(&line).into_owned();
            let rewritten = if let Some(hex) = text.strip_prefix("AUTH EXTERNAL ") {
                // 只认合法的 hex 载荷，改写成真实 uid 的编码
                if is_hex(hex) && !hex.is_empty() {
                    format!("AUTH EXTERNAL {}", hex_encode(&self.uid.to_string()))
                } else {
                    text
                }
            } else {
                text
            };
            if rewritten == "BEGIN" {
                self.done = true;
            }
            out.extend_from_slice(rewritten.as_bytes());
            out.extend_from_slice(b"\r\n");
        }
        // BEGIN 与剩余字节可能同批到达（fd 协商前的数据一般没有），
        // 但为防丢，done 之后把没凑成行的尾巴直接放行
        if self.done && !self.pending.is_empty() {
            out.extend(self.pending.drain(..));
        }
        out
    }
}

/// 找到 `\r\n`，返回行尾位置（不含 CRLF）
fn find_line_end(data: &[u8]) -> Option<usize> {
    data.windows(2).position(|w| w == b"\r\n")
}

fn is_hex(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_hexdigit())
}

/// D-Bus SASL 的十六进制编码：对字符串逐字节编码，如 "1000" → "31303030"
pub(crate) fn hex_encode(text: &str) -> String {
    text.bytes().map(|b| format!("{b:02X}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 十六进制编码符合dbus规范() {
        assert_eq!(hex_encode("0"), "30");
        assert_eq!(hex_encode("1000"), "31303030");
    }

    #[test]
    fn 改写root的认证行() {
        let mut r = AuthRewriter::new(1000);
        let out = r.feed(b"\0AUTH EXTERNAL 30\r\n");
        assert_eq!(out, b"\0AUTH EXTERNAL 31303030\r\n");
        assert!(!r.done());
    }

    #[test]
    fn begin之后不再改写() {
        let mut r = AuthRewriter::new(1000);
        let _ = r.feed(b"\0AUTH EXTERNAL 30\r\n");
        let out = r.feed(b"OK 1234\r\nBEGIN\r\nhello");
        assert!(out.starts_with(b"OK 1234\r\nBEGIN\r\nhello"));
        assert!(r.done());
        // done 后的数据原样通过
        assert_eq!(r.feed(b"\0AUTH EXTERNAL 30\r\n"), b"\0AUTH EXTERNAL 30\r\n");
    }

    #[test]
    fn 分批到达也能改写() {
        let mut r = AuthRewriter::new(1000);
        let part1 = r.feed(b"\0AUTH EXT");
        let part2 = r.feed(b"ERNAL 30\r\n");
        let mut whole = part1;
        whole.extend(part2);
        assert_eq!(whole, b"\0AUTH EXTERNAL 31303030\r\n");
    }

    #[test]
    fn 非法载荷原样放行() {
        let mut r = AuthRewriter::new(1000);
        let out = r.feed(b"AUTH EXTERNAL zz\r\n");
        assert_eq!(out, b"AUTH EXTERNAL zz\r\n");
    }
}

#[cfg(test)]
mod e2e {
    use super::*;
    use std::io::Read;
    use std::time::Duration;

    /// 端到端：客户端(root视角) → 桥(改写uid) → 假总线(校验改写结果，
    /// 协商 fd，发一条带 fd 的消息) → 桥透传 → 客户端收到数据与 fd
    #[test]
    fn 桥完成认证改写与fd透传() {
        let dir = std::env::temp_dir();
        let bus_path = dir.join(format!("pb-e2e-bus-{}.sock", std::process::id()));
        let bridge_path = dir.join(format!("pb-e2e-bridge-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&bus_path);
        let _ = std::fs::remove_file(&bridge_path);

        // 假总线：校验桥送来的认证行是否已改写成 1000
        let server = UnixListener::bind(&bus_path).expect("bind 假总线");
        let expected = "AUTH EXTERNAL 31303030";
        let server_thread = std::thread::spawn(move || {
            let (mut conn, _) = server.accept().expect("accept");
            let mut got = Vec::new();
            let mut buf = [0u8; 512];
            // 收齐客户端的握手（AUTH、NEGOTIATE、BEGIN）
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            while !got.windows(5).any(|w| w == b"BEGIN") && std::time::Instant::now() < deadline {
                let n = conn.read(&mut buf).unwrap_or(0);
                if n == 0 {
                    break;
                }
                got.extend_from_slice(&buf[..n]);
            }
            let text = String::from_utf8_lossy(&got).into_owned();
            assert!(text.contains(expected), "认证行应已改写，实际: {text:?}");
            assert!(text.contains('\0'), "BOM 应原样透传");
            assert!(text.contains("NEGOTIATE_UNIX_FD"));
            conn.write_all(b"OK 0123456789abcdef0123456789abcdef\r\n").unwrap();
            conn.write_all(b"AGREE_UNIX_FD\r\n").unwrap();
            std::thread::sleep(Duration::from_millis(100));
            // 认证完成后发一条带 fd 的消息
            let fds = [1, 2]; // 值无所谓，验证透传
            assert!(send_with_fds(conn.as_raw_fd(), b"msg-with-fd", &fds));
            // 客户端方向的 fd 也应能透传回来：收一条
            let (count, back) = recv_with_fds(conn.as_raw_fd(), &mut buf).expect("收客户端消息");
            (count, back, String::from_utf8_lossy(&buf[..count]).into_owned())
        });

        start(&bridge_path, &bus_path, 1000);
        let mut deadline = 50;
        while !bridge_path.exists() && deadline > 0 {
            deadline -= 1;
            std::thread::sleep(Duration::from_millis(20));
        }

        // 客户端：以 root 视角认证（uid 0），走桥
        let mut client = UnixStream::connect(&bridge_path).expect("连桥");
        client.write_all(b"\0").unwrap();
        client.write_all(b"AUTH EXTERNAL 30\r\n").unwrap();
        client.write_all(b"NEGOTIATE_UNIX_FD\r\n").unwrap();
        client.write_all(b"BEGIN\r\n").unwrap();

        let mut seen_ok = false;
        let mut seen_agree = false;
        let mut buf = [0u8; 512];
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while (!seen_ok || !seen_agree) && std::time::Instant::now() < deadline {
            let n = client.read(&mut buf).unwrap_or(0);
            if n == 0 {
                break;
            }
            let text = String::from_utf8_lossy(&buf[..n]);
            if text.starts_with("OK ") || text.contains("\r\nOK ") {
                seen_ok = true;
            }
            if text.contains("AGREE_UNIX_FD") {
                seen_agree = true;
            }
        }
        assert!(seen_ok && seen_agree, "应完成 SASL 握手");

        // 客户端收到桥透传的带 fd 消息
        let (count, fds) = loop {
            if let Some((n, fds)) = recv_with_fds(client.as_raw_fd(), &mut buf) {
                if n > 0 {
                    break (n, fds);
                }
            }
        };
        assert_eq!(&buf[..count], b"msg-with-fd");
        assert_eq!(fds.len(), 2, "应收到透传的 2 个 fd");

        // 客户端 → 总线方向的 fd 透传
        assert!(send_with_fds(client.as_raw_fd(), b"back-with-fd", &[5]));

        let (_scount, sback, sdata) = server_thread.join().unwrap();
        assert_eq!(sdata.as_bytes(), b"back-with-fd");
        assert_eq!(sback.len(), 1);

        let _ = std::fs::remove_file(&bus_path);
        let _ = std::fs::remove_file(&bridge_path);
    }
}
