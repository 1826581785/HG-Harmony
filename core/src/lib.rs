//!  业务核心层（Rust → OHOS NAPI）。
//!
//! 模块结构与旧工程 src-tauri/src/ 一一对应：
//! - net / dx150 / session：逐字平移（crate::net 内部引用路径不变）
//! - api：业务命令层（去掉 tauri State，改为全局单例）
//! - napi_mod：NAPI 接口层（JSON 信封字符串返回）

pub mod api;
pub mod dx150;
pub mod media;
pub mod napi_mod;
pub mod net;
pub mod server;
pub mod session;
