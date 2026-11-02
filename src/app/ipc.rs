// 单实例：第二个实例通过 unix 套接字通知第一个实例显示窗口
use std::io::{Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;

/// 本进程是否真的 bind 过套接字（configure 等模式没有）：退出时只清自己的
static SOCKET_OWNED: AtomicBool = AtomicBool::new(false);

pub fn socket_path() -> std::path::PathBuf {
    // XDG_RUNTIME_DIR 缺失时不能直接用 /tmp 的固定名：全局可写目录里其他
    // 用户能抢占套接字或伪造 ack，按 uid 隔开
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| format!("/tmp/protonboost-{}", user_id()));
    std::path::Path::new(&runtime).join("protonboost.sock")
}

fn user_id() -> u32 {
    nix::unistd::Uid::current().as_raw()
}

/// 尝试通知已运行的实例；true = 已通知，本进程应退出
///
/// 套接字文件可能在进程被强杀后残留。连不上就说明没人监听，
/// 把它清掉，否则以后每次启动都会误判成「已有实例」而静默退出。
pub fn notify_existing() -> bool {
    let path = socket_path();
    let result = UnixStream::connect(&path).and_then(|mut stream| {
        // 设个超时：对方僵死时别把自己也挂住
        stream.set_read_timeout(Some(std::time::Duration::from_millis(500)))?;
        stream.write_all(b"show\n")?;
        let mut buf = [0u8; 8];
        // 等对方回一个确认，确认它真的活着（没读到字节 = 对端没确认）
        match stream.read(&mut buf) {
            Ok(n) if n > 0 => Ok(()),
            Ok(_) => Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "no ack")),
            Err(err) => Err(err),
        }
    });
    match result {
        Ok(()) => true,
        Err(err) => {
            // 连不上、或者对方没应答：清掉残留，当作没有实例
            if err.kind() != std::io::ErrorKind::NotFound {
                let _ = std::fs::remove_file(&path);
            }
            false
        }
    }
}

/// 监听套接字，收到消息时向通道发送事件
pub fn listen(tx: Sender<()>) {
    let path = socket_path();
    let _ = std::fs::remove_file(&path);
    let Ok(listener) = UnixListener::bind(&path) else {
        return;
    };
    SOCKET_OWNED.store(true, Ordering::SeqCst);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = match stream {
                Ok(stream) => stream,
                Err(_) => continue,
            };
            // 对方连上后不发数据会让这条监听线程永远停在这里，单实例就此
            // 卡死：读最多等 500ms，没话说的连接直接丢弃
            let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(500)));
            let mut buf = [0u8; 16];
            match stream.read(&mut buf) {
                Ok(n) if n > 0 => {
                    // 回一个确认：发起方据此判断对方确实活着
                    let _ = stream.write_all(b"ok\n");
                    let _ = tx.send(());
                }
                _ => {}
            }
        }
    });
}

/// 清理退出时的套接字：只清自己 bind 过的，别删到别人（configure 实例、
/// 迟一步 bind 的管理器）名下的
pub fn cleanup() {
    if SOCKET_OWNED.load(Ordering::SeqCst) {
        let _ = std::fs::remove_file(socket_path());
    }
}
