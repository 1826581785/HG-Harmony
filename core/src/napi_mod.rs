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

pub(crate) fn api() -> &'static Api {
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
    crate::download::init(&dir);
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

/// 封面代理地址（走 /img 解密通道；站点封面是 AES-128-CBC 密文）。
#[napi]
pub fn hg_img_url(url: String) -> String {
    match crate::server::base_url() {
        Some(b) => envelope(Ok(json!({ "url": format!("{}/img?u={}", b, crate::media::enc(&url)) }))),
        None => envelope(Err("媒体服务未启动，请先调用 hg_media_start".into())),
    }
}

/* ───────────────────────── 下载引擎（阶段 6） ───────────────────────── */

/// 注册下载状态回调：每次任务列表变化时推送整个快照的 JSON 字符串。
#[napi]
pub fn hg_dl_on_state(callback: napi_ohos::threadsafe_function::ThreadsafeFunction<String>) -> String {
    crate::download::set_state_callback(callback);
    envelope(Ok(json!({ "ok": true })))
}

/// 添加下载任务。返回 {id}；同剧同集已完成时 id 为 null。
#[napi]
pub async fn hg_dl_add(video_id: i64, ep: i64, title: String, ep_title: String) -> String {
    let id = crate::download::dl().add(api(), video_id, ep.max(1) as u32, title, ep_title);
    envelope(Ok(json!({ "id": id.map(|v| v as f64) })))
}

/// 任务列表快照（进入下载页时拉取 + 校验已下载文件存在性）。
#[napi]
pub async fn hg_dl_list() -> String {
    crate::download::dl().verify_done_files();
    let tasks = crate::download::dl().list();
    envelope(serde_json::to_value(&tasks).map_err(|e| e.to_string()).map(|v| json!({ "tasks": v })))
}

/// 校验已完成文件存在性（被外部删除的记录自动移出）。
#[napi]
pub async fn hg_dl_verify() -> String {
    crate::download::dl().verify_done_files();
    envelope(Ok(json!({ "ok": true })))
}

#[napi]
pub async fn hg_dl_pause(id: f64) -> String {
    crate::download::dl().pause(id as u64);
    envelope(Ok(json!({ "ok": true })))
}

#[napi]
pub async fn hg_dl_resume(id: f64) -> String {
    crate::download::dl().resume(api(), id as u64);
    envelope(Ok(json!({ "ok": true })))
}

#[napi]
pub async fn hg_dl_retry(id: f64) -> String {
    crate::download::dl().retry(api(), id as u64);
    envelope(Ok(json!({ "ok": true })))
}

#[napi]
pub async fn hg_dl_remove(id: f64) -> String {
    crate::download::dl().remove(id as u64);
    envelope(Ok(json!({ "ok": true })))
}

/// 应用启动恢复：读 downloads.json，中断任务回队列续传 + 清残留分片缓存。
#[napi]
pub async fn hg_dl_restore() -> String {
    crate::download::dl().restore(api());
    envelope(Ok(json!({ "ok": true })))
}

/// 已完成任务成品文件的绝对路径（供 ArkTS 保存到系统图库）。
#[napi]
pub fn hg_dl_file(id: f64) -> String {
    let tid = id as u64;
    let dm = crate::download::dl();
    let task = dm.list().into_iter().find(|t| t.id == tid);
    match task {
        Some(t) => match (&t.file, t.status) {
            (Some(f), crate::download::Status::Done) => {
                envelope(Ok(json!({ "path": crate::download::download_dir().join(&f) })))
            }
            _ => envelope(Err("任务未完成".into())),
        },
        None => envelope(Err("任务不存在".into())),
    }
}
