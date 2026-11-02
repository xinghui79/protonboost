//! 启动引擎：ProtonBoost 的核心——从发现运行器到拉起程序的整条链路
//!
//! - `runners`：从 Steam / lutris / 本地目录里找出可用的 Proton / Wine
//! - `runtime`：Proton 需要的 Steam Linux Runtime（没有就下）
//! - `session`：同前缀共享的会话与独立网络命名空间（pasta + keeper）
//! - `launch`：拼环境变量与命令行，把程序拉起来并写运行日志
//! - `update`：GE-Proton 的在线安装与版本更新

pub mod dbus_bridge;
pub mod launch;
pub mod logs;
pub mod overlay;
pub mod runners;
pub mod runtime;
pub mod session;
pub mod steam_forward;
pub mod update;

#[cfg(test)]
mod tests;
