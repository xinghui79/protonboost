// 构建脚本：用 cxx-qt 把 Rust 桥接与 QML 模块编译进二进制
use cxx_qt_build::{CxxQtBuilder, QmlModule};
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

fn main() {
    // QML 经 qmlcachegen 编成 .o 后由链接器拼进可执行文件，cargo 感知不到这些 .o 的变化，
    // 只改 QML 不会重链接（跑的还是旧界面）。这里把 QML 内容算成哈希塞进 rustc-env：
    // 内容一变，本 crate 的编译环境就跟着变，cargo 会重新编译并重链接。
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let mut qml_files: Vec<PathBuf> = std::fs::read_dir("qml")
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "qml"))
                .collect()
        })
        .unwrap_or_default();
    qml_files.sort();
    for file in &qml_files {
        println!("cargo:rerun-if-changed={}", file.display());
        if let Ok(bytes) = std::fs::read(file) {
            file.hash(&mut hasher);
            bytes.hash(&mut hasher);
        }
    }
    println!("cargo:rustc-env=WINRUN_QML_STAMP={:x}", hasher.finish());

    // 覆盖层 uid 辅助库：构建期编译成 .so 嵌进二进制，用户机器上就不再需要 C
    // 编译器。构建机上没有 cc 时写入空占位，运行时检测到不是有效 ELF 会回退
    // 到现场编译（老行为）。
    println!("cargo:rerun-if-changed=assets/overlay-uid/overlay-uid.c");
    let out_dir = std::env::var("OUT_DIR").unwrap_or_default();
    if !out_dir.is_empty() {
        for (bits, flag) in [("64", "-m64"), ("32", "-m32")] {
            let out = format!("{out_dir}/overlay-uid-{bits}.so");
            let ok = std::process::Command::new("cc")
                .args([
                    flag, "-shared", "-fPIC", "-O2", "-fno-stack-protector",
                    "-U_FORTIFY_SOURCE", "-x", "c",
                    "assets/overlay-uid/overlay-uid.c", "-o", &out,
                ])
                .status()
                .map(|status| status.success())
                .unwrap_or(false);
            if !ok {
                let _ = std::fs::write(&out, b"");
            }
        }
    }

    let qml = QmlModule::new("WinRun").qml_file("qml/Main.qml");

    CxxQtBuilder::new_qml_module(qml)
        .file("src/app/bridge.rs")
        .file("src/app/shim_bridge.rs")
        .cpp_file("src/app/shim.cpp")
        .qt_module("Gui")
        .qt_module("Quick")
        .qt_module("Qml")
        .qt_module("Widgets")
        .build();
}
