// 单实例：第二个实例通过 unix 套接字通知第一个实例显示窗口
use std::io::Write as _;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::Sender;

pub fn socket_path() -> std::path::PathBuf {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    std::path::Path::new(&runtime).join("winrun-manager.sock")
}

/// 尝试通知已运行的实例；true = 已通知，本进程应退出
pub fn notify_existing() -> bool {
    match UnixStream::connect(&socket_path()) {
        Ok(mut stream) => {
            let _ = stream.write_all(b"show\n");
            true
        }
        Err(_) => false,
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
            let _ = tx.send(());
        }
    });
}

/// 清理退出时的套接字
pub fn cleanup() {
    let _ = std::fs::remove_file(&socket_path());
}
