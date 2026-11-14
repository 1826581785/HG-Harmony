//! HGhub 业务核心层（Rust → OHOS NAPI）。
//!
//! 阶段 0：仅验证 Rust → NAPI → ArkTS 全链路。
//! 阶段 1 起平移旧工程 src-tauri/src/ 下的 net / dx150 / media / session / download / mux 模块。

use napi_derive_ohos::napi;

/// 链路自检：能被 ArkTS 调到即代表 NAPI 桥接成功。
#[napi]
pub fn hello() -> String {
    format!("hg-core {} ready (rust on ohos)", env!("CARGO_PKG_VERSION"))
}
