//! NAPI 接口层：所有命令返回 JSON 信封字符串 `{ok, data|error}`，
//! 前端解析后无需处理 NAPI 异常类型。

use crate::api::Api;
use napi_derive_ohos::napi;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::OnceLock;

static API: Lazy<Api> = Lazy::new(Api::new);
static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

fn api() -> &'static Api {
    &API
}

/// 统一信封：Ok(v) → {ok:true,data}；Err(e) → {ok:false,error}
fn envelope(r: Result<Value, String>) -> String {
    match r {
        Ok(v) => json!({ "ok": true, "data": v }).to_string(),
        Err(e) => json!({ "ok": false, "error": e }).to_string(),
    }
}

/// 初始化数据目录（session.json 等），在 Ability onCreate 时调用一次。
#[napi]
pub fn hg_init(data_dir: String) -> String {
    let dir = PathBuf::from(&data_dir);
    let _ = DATA_DIR.set(dir.clone());
    api().bind(&dir);
    envelope(Ok(json!({ "ok": true, "dir": data_dir })))
}

#[napi]
pub fn hg_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[napi]
pub async fn hg_boot() -> String {
    envelope(api().boot().await)
}

#[napi]
pub async fn hg_login(username: String, password: String) -> String {
    envelope(api().login(&username, &password).await)
}

#[napi]
pub async fn hg_register(username: String, password: String, email: String) -> String {
    envelope(api().register(&username, &password, &email).await)
}

#[napi]
pub async fn hg_logout() -> String {
    envelope(api().logout().await)
}

#[napi]
pub async fn hg_me() -> String {
    envelope(api().me().await)
}

/// 通用业务调用（列表 / 详情 / 播放 / 互动等，内部自动带 token 与 visitor_id）。
#[napi]
pub async fn hg_edge(method: String, path: String, body: Option<String>) -> String {
    let parsed: Option<Value> = body
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .and_then(|s| serde_json::from_str(s).ok());
    let token = api().session.token();
    let visitor = api().session.visitor();
    let r = crate::net::edge(&method, &path, parsed, token.as_deref(), Some(&visitor)).await;
    envelope(r)
}

/// 链路自检：public 明文通道 + 加密通道各打一发，返回每步结果。
#[napi]
pub async fn hg_selftest() -> String {
    let mut steps: Vec<Value> = Vec::new();
    match api().feed(1, 2).await {
        Ok(v) => {
            let n = v.get("items").and_then(|i| i.as_array()).map_or(0, |a| a.len());
            steps.push(json!({ "step": "public_feed", "ok": true, "items": n }));
        }
        Err(e) => steps.push(json!({ "step": "public_feed", "ok": false, "error": e })),
    }
    match api().video(117).await {
        Ok(v) => {
            let eps = v.get("episode_count").and_then(|c| c.as_i64()).unwrap_or(0);
            steps.push(json!({ "step": "encrypted_video_detail", "ok": true, "episodes": eps }));
        }
        Err(e) => steps.push(json!({ "step": "encrypted_video_detail", "ok": false, "error": e })),
    }
    match api().play(117, 3).await {
        Ok(v) => {
            let url = v.get("video_url").and_then(|u| u.as_str()).unwrap_or("");
            steps.push(json!({ "step": "playback", "ok": !url.is_empty(), "url_len": url.len() }));
        }
        Err(e) => steps.push(json!({ "step": "playback", "ok": false, "error": e })),
    }
    json!({ "ok": steps.iter().all(|s| s["ok"] == json!(true)), "steps": steps }).to_string()
}
