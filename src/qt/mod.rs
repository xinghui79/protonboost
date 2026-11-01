//! Qt 层：QML 后端与 Rust 没有 Qt 绑定的部分（QApplication、托盘、图标、截图）
//!
//! cxx-qt 要求参与同一模块的 Rust 文件都在同一个目录下（QTBUG-93443），
//! 所以 backend 与 shim 桥接放在一起。

pub mod bridge;
pub mod shim_bridge;
