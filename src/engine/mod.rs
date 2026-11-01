//! 启动引擎：原来 CLI（bin/winrun + lib/*.sh）干的活，搬到这里
//!
//! - `runners`：从 Steam / lutris / 本地目录里找出可用的 Proton / Wine
//! - `runtime`：Proton 需要的 Steam Linux Runtime（没有就下）
//! - `session`：同前缀共享的会话与独立网络命名空间（pasta + keeper）
//! - `launch`：拼环境变量与命令行，把程序拉起来并写运行日志
//! - `update`：GE / DW 运行器的版本检查与安装

pub mod launch;
pub mod logs;
pub mod runners;
pub mod runtime;
pub mod session;
pub mod update;
