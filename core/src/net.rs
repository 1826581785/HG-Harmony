//! 网络层：与上游站点对话。
//!
//! 上游已升级为 dx150-edge-v1 加密协议（ECDH + AES-GCM）：
//! - public 域（只读列表）：明文 POST /api/public/request + `X-HG-Public-JSON: 1`
//! - user / playback / dynamic 域：加密通道（见 dx150.rs）
//! - 未匹配路由：回落旧版 /api/edge/request 明文信封

use crate::dx150;
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Duration;
use tokio::sync::Mutex;

pub const BASE: &str = "https://huangguoai.com";

pub const UA: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 构建客户端；proxy 形如 http://host:port 或 socks5://host:port，None 为直连。
fn build_client(proxy: Option<&str>) -> reqwest::Client {
    let mut b = reqwest::Client::builder()
        .user_agent(UA)
        .timeout(Duration::from_secs(20))
        .connect_timeout(Duration::from_secs(10))
        .gzip(true)
        .brotli(true)
        .pool_idle_timeout(Duration::from_secs(60));
    if let Some(addr) = proxy {
        if let Ok(p) = reqwest::Proxy::all(addr) {
            b = b.proxy(p);
        }
    }
    b.build().expect("build http client")
}

static CLIENT_SLOT: Lazy<std::sync::RwLock<reqwest::Client>> =
    Lazy::new(|| std::sync::RwLock::new(build_client(None)));

/// 当前客户端（reqwest::Client 内部是 Arc，clone 廉价）。
pub fn client() -> reqwest::Client {
    CLIENT_SLOT.read().unwrap().clone()
}

/// 设置/清除全局代理（重建客户端）。对所有出网请求生效：
/// 业务 API、媒体拉流、下载共用此客户端。
pub fn set_proxy(addr: Option<&str>) {
    let mut w = CLIENT_SLOT.write().unwrap();
    *w = build_client(addr);
}

/// 各 scope 的加密会话（dx150 Session 内部处理过期重握手）。
static SESSIONS: Lazy<Mutex<HashMap<String, dx150::Session>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

/* ───────────────────────── scope 路由表（来自官方 window.__cloudfrontCompat.encryptedAPIRoutes） ───────────────────────── */

static ROUTES_RAW: &[&str] = &[
    // dynamic
    "POST /api/edge/image|dynamic",
    "GET /api/home|dynamic",
    "POST /api/media/covers|dynamic",
    "GET /api/posts/:id|dynamic",
    "GET /api/posts/:id/comments|dynamic",
    "POST /api/posts/:id/share|dynamic",
    "GET /api/search|dynamic",
    "GET /api/site/address-poster|dynamic",
    "POST /api/site/click|dynamic",
    "GET /api/site/entries|dynamic",
    "GET /api/site/go-home|dynamic",
    "POST /api/site/home-slots|dynamic",
    "POST /api/stats/click|dynamic",
    "POST /api/stats/origin|dynamic",
    "GET /api/users/:id|dynamic",
    "GET /api/videos/:id|dynamic",
    "GET /api/videos/:id/comments|dynamic",
    "GET /api/videos/:id/comments/:cid/replies|dynamic",
    "GET /api/videos/:id/next|dynamic",
    "POST /api/videos/:id/play|dynamic",
    "POST /api/videos/:id/visit|dynamic",
    "POST /api/videos/recommend|dynamic",
    "POST /api/videos/recommend/ref/:ref|dynamic",
    "GET /api/whoami|dynamic",
    // playback
    "POST /api/media/playback/previews|playback",
    "POST /api/media/prerolls/:id/playback|playback",
    "POST /api/posts/:id/playback|playback",
    "POST /api/videos/:id/episodes/:ep/playback|playback",
    "GET /api/videos/:id/play|playback",
    "GET /api/videos/:id/playback|playback",
    // public（明文）
    "GET /api/feed/post/today|public",
    "GET /api/feed/recommend|public",
    "GET /api/feed/today|public",
    "GET /api/home/latest|public",
    "GET /api/home/recommends|public",
    "GET /api/posts|public",
    "GET /api/posts/:id/adjacent|public",
    "GET /api/posts/:id/related|public",
    "GET /api/posts/category/:route|public",
    "GET /api/posts/tag/:tag|public",
    "GET /api/posts/user/:id|public",
    "GET /api/ranks/:type|public",
    "GET /api/search/hot|public",
    "GET /api/search/suggest|public",
    "GET /api/search/tags/hot|public",
    "GET /api/site/categories/post|public",
    "GET /api/site/categories/video|public",
    "GET /api/site/config|public",
    "GET /api/site/links|public",
    "GET /api/site/menus|public",
    "GET /api/site/meta|public",
    "GET /api/site/pages|public",
    "GET /api/site/pages/:slug|public",
    "GET /api/site/sorts/video|public",
    "GET /api/site/transit|public",
    "GET /api/site/watermark|public",
    "GET /api/tags|public",
    "GET /api/topics|public",
    "GET /api/topics/:slug|public",
    "GET /api/users/:id/stats|public",
    "GET /api/videos|public",
    "GET /api/videos/:id/related|public",
    "GET /api/videos/category/:route|public",
    "GET /api/videos/long|public",
    "GET /api/videos/report-reasons|public",
    "GET /api/videos/sort/:route|public",
    "GET /api/videos/tag/:tag|public",
    "GET /api/videos/user/:id|public",
    // user（加密）
    "POST /api/account/loginByPassword|user",
    "POST /api/account/logout|user",
    "GET /api/account/me|user",
    "POST /api/account/password|user",
    "PATCH /api/account/profile|user",
    "POST /api/account/registerByPassword|user",
    "POST /api/ai-wish|user",
    "DELETE /api/posts/:id/collect|user",
    "POST /api/posts/:id/collect|user",
    "POST /api/posts/:id/comments|user",
    "POST /api/posts/:id/comments/:cid/guest-like|user",
    "DELETE /api/posts/:id/comments/:cid/like|user",
    "POST /api/posts/:id/comments/:cid/like|user",
    "GET /api/posts/:id/comments/liked|user",
    "POST /api/posts/:id/guest-comments|user",
    "POST /api/posts/:id/guest-like|user",
    "GET /api/posts/:id/guest-liked|user",
    "DELETE /api/posts/:id/like|user",
    "POST /api/posts/:id/like|user",
    "POST /api/posts/:id/visit|user",
    "DELETE /api/users/:id/follow|user",
    "POST /api/users/:id/follow|user",
    "GET /api/users/me/collects|user",
    "GET /api/users/me/comments|user",
    "GET /api/users/me/follows|user",
    "GET /api/users/me/history|user",
    "POST /api/users/me/history|user",
    "POST /api/users/me/history/delete|user",
    "POST /api/users/me/history/sync|user",
    // videos 侧互动（官方路由表截断，按 posts 侧对称补齐）
    "DELETE /api/videos/:id/collect|user",
    "POST /api/videos/:id/collect|user",
    "POST /api/videos/:id/comments|user",
    "DELETE /api/videos/:id/comments/:cid/like|user",
    "POST /api/videos/:id/comments/:cid/like|user",
    "GET /api/videos/:id/comments/liked|user",
    "POST /api/videos/:id/guest-comments|user",
    "POST /api/videos/:id/guest-like|user",
    "GET /api/videos/:id/guest-liked|user",
    "DELETE /api/videos/:id/like|user",
    "POST /api/videos/:id/like|user",
    "POST /api/videos/:id/visit|user",
];

struct Route {
    method: String,
    scope: String,
    segments: Vec<String>,
    params: usize,
}

static ROUTES: Lazy<Vec<Route>> = Lazy::new(|| {
    ROUTES_RAW
        .iter()
        .filter_map(|raw| {
            let (path_part, scope) = raw.split_once('|')?;
            let (method, path) = path_part.split_once(' ')?;
            Some(Route {
                method: method.to_string(),
                scope: scope.to_string(),
                segments: path
                    .split('/')
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string())
                    .collect(),
                params: path.split(':').count() - 1,
            })
        })
        .collect()
});

/// 按「参数最少优先」匹配路由（与官方 requestScope 一致）。
fn scope_of(method: &str, path: &str) -> Option<String> {
    let p = path.split('?').next().unwrap_or(path);
    let segs: Vec<&str> = p.split('/').filter(|s| !s.is_empty()).collect();
    let mut best: Option<(usize, String)> = None;
    for r in ROUTES.iter() {
        if r.method != method {
            continue;
        }
        if r.segments.len() != segs.len() {
            continue;
        }
        let ok = r.segments.iter().zip(segs.iter()).all(|(rs, s)| {
            if rs == s {
                true
            } else if rs.starts_with(':') {
                if rs == ":id" || rs == ":cid" || rs == ":ep" {
                    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
                } else {
                    !s.is_empty()
                }
            } else {
                false
            }
        });
        if ok && best.as_ref().map_or(true, |(n, _)| r.params < *n) {
            best = Some((r.params, r.scope.clone()));
        }
    }
    best.map(|(_, s)| s)
}

/// 查询参数按名稳定排序（public 域要求）。
fn sort_query(path: &str) -> String {
    match path.split_once('?') {
        None => path.to_string(),
        Some((p, q)) => {
            let mut pairs: Vec<(&str, &str)> = q
                .split('&')
                .filter(|s| !s.is_empty())
                .map(|kv| match kv.split_once('=') {
                    Some((k, v)) => (k, v),
                    None => (kv, ""),
                })
                .collect();
            pairs.sort_by(|a, b| a.0.cmp(&b.0));
            let qs: Vec<String> = pairs
                .iter()
                .map(|(k, v)| {
                    if v.is_empty() {
                        k.to_string()
                    } else {
                        format!("{k}={v}")
                    }
                })
                .collect();
            format!("{p}?{}", qs.join("&"))
        }
    }
}

/* ───────────────────────── HTTP 底层 ───────────────────────── */

/// 明文 POST JSON，返回 (status, 解析后的 JSON)。
pub async fn post_json(url: &str, body: &Value) -> Result<(u16, Value), String> {
    post_json_h(url, body, &[]).await
}

/// 明文 POST JSON，可附加自定义头。
pub async fn post_json_h(
    url: &str,
    body: &Value,
    extra: &[(&str, &str)],
) -> Result<(u16, Value), String> {
    let mut req = client()
        .post(url)
        .header("Accept", "application/json")
        .header("Referer", format!("{BASE}/"))
        .json(body);
    for (k, v) in extra {
        req = req.header(*k, *v);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    let value = if text.trim().is_empty() {
        Value::Null
    } else {
        serde_json::from_str::<Value>(&text)
            .map_err(|e| format!("{e}: {}", &text[..text.len().min(160)]))?
    };
    Ok((status, value))
}

fn unwrap_business(value: Value) -> Result<Value, String> {
    if value.is_null() {
        return Ok(Value::Null);
    }
    if value.get("status").and_then(|v| v.as_i64()) == Some(1) {
        Ok(value.get("data").cloned().unwrap_or(Value::Null))
    } else {
        Err(value
            .get("msg")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("接口返回失败")
            .to_string())
    }
}

/// 统一重试（传输层偶发抖动）。
async fn with_retry<F, Fut, T>(mut f: F) -> Result<T, String>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, String>>,
{
    let mut last = String::from("network error");
    for attempt in 0..3 {
        match f().await {
            Ok(v) => return Ok(v),
            Err(e) => {
                last = e;
                if attempt < 2 {
                    tokio::time::sleep(Duration::from_millis(350 * (attempt as u64 + 1))).await;
                }
            }
        }
    }
    Err(last)
}

/* ───────────────────────── 三条通道 ───────────────────────── */

async fn public_edge(method: &str, path: &str, body: Option<&Value>) -> Result<Value, String> {
    let (encoded, ctype) = encode_body(body);
    let envelope = json!({
        "method": method,
        "path": sort_query(path),
        "body": encoded,
        "content_type": ctype,
    });
    let value = with_retry(|| async {
        let (status, value) = post_json_h(
            &format!("{BASE}/api/public/request"),
            &envelope,
            &[("X-HG-Public-JSON", "1")],
        )
        .await?;
        if status != 200 {
            return Err(format!("HTTP {status}"));
        }
        Ok(value)
    })
    .await?;
    unwrap_business(value)
}

fn encode_body(body: Option<&Value>) -> (String, &'static str) {
    match body {
        Some(v) => (
            B64.encode(serde_json::to_vec(v).unwrap_or_default()),
            "application/json",
        ),
        None => (String::new(), ""),
    }
}

async fn encrypted_edge(
    scope: &str,
    method: &str,
    path: &str,
    body: Option<&Value>,
    token: Option<&str>,
    visitor: Option<&str>,
) -> Result<Value, String> {
    let (encoded, ctype) = encode_body(body);
    let mut packet = json!({
        "method": method,
        "path": path,
        "body": encoded,
        "content_type": ctype,
    });
    if let Some(v) = visitor {
        if !v.is_empty() {
            packet["visitor_id"] = json!(v);
        }
    }

    let mut sessions = SESSIONS.lock().await;
    let scope = scope.to_string();
    let mut retry = 0;
    loop {
        if !sessions.contains_key(&scope) {
            let s = dx150::Session::open(&scope)
                .await
                .map_err(|e| format!("握手失败: {e}"))?;
            sessions.insert(scope.clone(), s);
        }
        let session = sessions.get_mut(&scope).expect("session inserted");
        match session.call(packet.clone(), token).await {
            Ok((status, bytes)) => {
                if status == 401 || status == 403 {
                    return Err("401".to_string());
                }
                if !(200..300).contains(&status) {
                    return Err(format!(
                        "HTTP {status}: {}",
                        String::from_utf8_lossy(&bytes)
                            .chars()
                            .take(160)
                            .collect::<String>()
                    ));
                }
                if bytes.is_empty() {
                    return Ok(Value::Null);
                }
                let value: Value = serde_json::from_slice(&bytes)
                    .map_err(|e| format!("{e}: {}", String::from_utf8_lossy(&bytes)))?;
                return unwrap_business(value);
            }
            Err(e) if e == "SESSION_EXPIRED" => {
                sessions.remove(&scope);
                if retry == 0 {
                    retry += 1;
                    continue;
                }
                return Err("加密会话已过期".into());
            }
            Err(e) => return Err(e),
        }
    }
}

/// 旧版明文信封（回落通道）。
async fn legacy_edge(
    method: &str,
    path: &str,
    body: Option<&Value>,
    token: Option<&str>,
) -> Result<Value, String> {
    let (encoded, ctype) = encode_body(body);
    let envelope = json!({
        "method": method,
        "path": path,
        "body": encoded,
        "content_type": ctype,
    });
    let value = with_retry(|| async {
        let mut req = client()
            .post(&format!("{BASE}/api/edge/request"))
            .header("Accept", "application/json")
            .header("Referer", format!("{BASE}/"))
            .json(&envelope);
        if let Some(t) = token {
            if !t.is_empty() {
                req = req.header("Authorization", format!("Bearer {t}"));
            }
        }
        let resp = req.send().await.map_err(|e| e.to_string())?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| e.to_string())?;
        if status.as_u16() == 401 || status.as_u16() == 403 {
            return Err("401".to_string());
        }
        if !status.is_success() {
            return Err(format!("HTTP {status}: {}", &text[..text.len().min(160)]));
        }
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str::<Value>(&text)
            .map_err(|e| format!("{e}: {}", &text[..text.len().min(160)]))
    })
    .await?;
    unwrap_business(value)
}

/// 业务请求总入口：按路由分派到三条通道。
pub async fn edge(
    method: &str,
    path: &str,
    body: Option<Value>,
    token: Option<&str>,
    visitor: Option<&str>,
) -> Result<Value, String> {
    match scope_of(method, path).as_deref() {
        Some("public") => public_edge(method, path, body.as_ref()).await,
        Some(scope) => {
            encrypted_edge(scope, method, path, body.as_ref(), token, visitor).await
        }
        None => legacy_edge(method, path, body.as_ref(), token).await,
    }
}

/// 拉原始字节（图片 / m3u8 / 分片）。
pub async fn fetch_bytes(url: &str) -> Result<(Option<String>, Vec<u8>), String> {
    let url = url.to_string();
    with_retry(|| {
        let url = url.clone();
        async move {
            let resp = client()
                .get(&url)
                .header("Referer", format!("{BASE}/"))
                .send()
                .await
                .map_err(|e| e.to_string())?;
            if !resp.status().is_success() {
                return Err(format!("HTTP {}", resp.status()));
            }
            let ctype = resp
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            let bytes = resp.bytes().await.map_err(|e| e.to_string())?.to_vec();
            Ok((ctype, bytes))
        }
    })
    .await
}
