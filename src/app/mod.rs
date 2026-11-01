//! 应用层：QML 后端、任务调度、单实例，以及 Rust 侧没有 Qt 绑定的部分
//!
//! cxx-qt 要求参与同一个 QML 模块的桥接文件放在同一目录（QTBUG-93443），
//! 所以 bridge / shim_bridge 与它们的 C++ 帮手都放在这里。

pub mod bridge;
pub mod ipc;
pub mod jobs;
pub mod shim_bridge;
