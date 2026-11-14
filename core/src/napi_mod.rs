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

/// 链路自检：能被 ArkTS 调到即代表 NAPI 桥接成功。
#[napi]
pub fn hello() -> String {
    format!("hg-core {} ready (rust on ohos)", env!("CARGO_PKG_VERSION"))
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

/* ───────────────────────── 媒体（阶段 2） ───────────────────────── */

/// 启动本地媒体服务（127.0.0.1 随机端口），返回 {base}。幂等。
#[napi]
pub async fn hg_media_start() -> String {
    if let Some(b) = crate::server::base_url() {
        return envelope(Ok(json!({ "base": b })));
    }
    tokio::spawn(crate::server::run());
    for _ in 0..60 {
        if let Some(b) = crate::server::base_url() {
            return envelope(Ok(json!({ "base": b })));
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    envelope(Err("本地媒体服务启动超时".into()))
}

/// 取播放地址（含 streams.main → video_url 兼容转换）。
#[napi]
pub async fn hg_play(id: i64, ep: i64) -> String {
    envelope(api().play(id, ep.max(1) as u32).await)
}

/// 生成经本地代理的媒体地址（需先 hg_media_start）。m3u8 → /hls，其它 → /seg。
#[napi]
pub fn hg_media_url(url: String) -> String {
    match crate::server::base_url() {
        Some(b) => envelope(Ok(json!({ "url": crate::media::proxy_url(b, &url) }))),
        None => envelope(Err("媒体服务未启动，请先调用 hg_media_start".into())),
    }
}

/// 媒体链路自检：播放地址 → 本地 /hls（校验 #EXTM3U）→ 首个分片（校验可取）。
#[napi]
pub async fn hg_media_selftest() -> String {
    let mut steps: Vec<Value> = Vec::new();

    // 确保服务已启动
    if crate::server::base_url().is_none() {
        tokio::spawn(crate::server::run());
        for _ in 0..60 {
            if crate::server::base_url().is_some() { break; }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    }
    let base = match crate::server::base_url() {
        Some(b) => b.clone(),
        None => return json!({ "ok": false, "steps": [{ "step": "media_server", "ok": false, "error": "启动超时" }] }).to_string(),
    };
    steps.push(json!({ "step": "media_server", "ok": true, "base": base }));

    // 取播放地址
    let play = match api().play(117, 3).await {
        Ok(v) => v,
        Err(e) => return json!({ "ok": false, "steps": steps, "error": e }).to_string(),
    };
    let video_url = play.get("video_url").and_then(|u| u.as_str()).unwrap_or("").to_string();
    steps.push(json!({ "step": "play_url", "ok": !video_url.is_empty(), "url_len": video_url.len() }));
    if video_url.is_empty() {
        return json!({ "ok": false, "steps": steps }).to_string();
    }

    // 经本地服务取播放列表
    let local = crate::media::proxy_url(&base, &video_url);
    match crate::net::client().get(&local).send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let text = resp.text().await.unwrap_or_default();
            let is_m3u8 = text.starts_with("#EXTM3U");
            steps.push(json!({ "step": "hls_proxy", "ok": status == 200 && is_m3u8, "status": status, "len": text.len() }));
            // 取第一个分片（或 AES key）验证透传
            let seg_line = text.lines().find(|l| !l.starts_with('#') && l.contains("/seg?u="));
            match seg_line {
                Some(seg) => match crate::net::client().get(seg.trim()).send().await {
                    Ok(r2) => {
                        let s2 = r2.status().as_u16();
                        let n2 = r2.bytes().await.map(|b| b.len()).unwrap_or(0);
                        steps.push(json!({ "step": "seg_or_key", "ok": s2 == 200 && n2 > 100, "status": s2, "len": n2 }));
                    }
                    Err(e) => steps.push(json!({ "step": "seg_or_key", "ok": false, "error": e.to_string() })),
                },
                None => steps.push(json!({ "step": "seg_or_key", "ok": false, "error": "改写后的列表里没有分片行" })),
            }
        }
        Err(e) => steps.push(json!({ "step": "hls_proxy", "ok": false, "error": e.to_string() })),
    }

    json!({ "ok": steps.iter().all(|s| s["ok"] == json!(true)), "steps": steps }).to_string()
}

/// 清空媒体内存缓存（对应旧 cache_clear 的媒体部分）。
#[napi]
pub fn hg_clear_media_cache() -> String {
    crate::media::clear_caches();
    envelope(Ok(json!({ "ok": true })))
}

/* ───────────────────────── 代理设置 ───────────────────────── */

/// 设置出网代理（http://host:port 或 socks5://host:port），空串恢复直连。
/// 持久化到 session.json，重启后自动恢复。
#[napi]
pub fn hg_set_proxy(addr: String) -> String {
    let a = addr.trim().to_string();
    if a.is_empty() {
        crate::net::set_proxy(None);
        api().session.set_proxy(String::new());
    } else {
        crate::net::set_proxy(Some(&a));
        api().session.set_proxy(a.clone());
    }
    envelope(Ok(json!({ "proxy": a })))
}

#[napi]
pub fn hg_get_proxy() -> String {
    api().session.proxy()
}
