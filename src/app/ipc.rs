// 单实例：第二个实例通过 unix 套接字通知第一个实例显示窗口
use std::io::{Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::Sender;

pub fn socket_path() -> std::path::PathBuf {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    std::path::Path::new(&runtime).join("protonboost.sock")
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
        // 等对方回一个确认，确认它真的活着
        match stream.read(&mut buf) {
            Ok(_) => Ok(()),
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
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = match stream {
                Ok(stream) => stream,
                Err(_) => continue,
            };
            let mut buf = [0u8; 16];
            let _ = std::io::Read::read(&mut stream, &mut buf);
            // 回一个确认：发起方据此判断对方确实活着
            let _ = stream.write_all(b"ok\n");
            let _ = tx.send(());
        }
    });
}

/// 清理退出时的套接字
pub fn cleanup() {
    let _ = std::fs::remove_file(&socket_path());
}
