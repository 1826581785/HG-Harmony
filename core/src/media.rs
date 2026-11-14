//! 媒体层：封面解密 + HLS 代理。
//! 平移自旧工程 src-tauri/src/media.rs：
//! - 响应体从 tauri::http::Response 换为自有 HResp
//! - URL 前缀从自定义协议 hg://localhost 换为本地 HTTP 服务 http://127.0.0.1:<port>

use crate::net::fetch_bytes;
use aes::cipher::{BlockDecrypt, KeyInit};
use aes::Aes128;
use once_cell::sync::Lazy;
use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

const IMG_KEY: &[u8] = b"f5d965df75336270";
const IMG_IV: &[u8] = b"97b60394abc2fbe1";

static IMG_CACHE: Lazy<Mutex<HashMap<String, Arc<Vec<u8>>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static PL_CACHE: Lazy<Mutex<HashMap<String, Arc<String>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

const IMG_CACHE_MAX: usize = 240;
const PL_CACHE_MAX: usize = 60;

fn cache_put<V: Clone>(map: &Mutex<HashMap<String, V>>, key: String, val: V, max: usize) {
    let mut m = map.lock().unwrap();
    if m.len() >= max {
        if let Some(k) = m.keys().next().cloned() {
            m.remove(&k);
        }
    }
    m.insert(key, val);
}

/* ───────────────────────── AES ───────────────────────── */

fn aes_cbc_decrypt(data: &[u8]) -> Option<Vec<u8>> {
    if data.is_empty() || data.len() % 16 != 0 {
        return None;
    }
    let cipher = Aes128::new_from_slice(IMG_KEY).ok()?;
    let mut prev = [0u8; 16];
    prev.copy_from_slice(IMG_IV);
    let mut out = Vec::with_capacity(data.len());
    for chunk in data.chunks(16) {
        let mut ct = [0u8; 16];
        ct.copy_from_slice(chunk);
        let mut block = ct;
        cipher.decrypt_block((&mut block).into());
        for i in 0..16 {
            out.push(block[i] ^ prev[i]);
        }
        prev = ct;
    }
    Some(out)
}

fn strip_padding(mut buf: Vec<u8>) -> Vec<u8> {
    let pad = *buf.last().unwrap_or(&0) as usize;
    if pad > 0 && pad <= 16 && buf.len() >= pad {
        if buf[buf.len() - pad..].iter().all(|b| *b as usize == pad) {
            buf.truncate(buf.len() - pad);
        }
    }
    buf
}

fn image_kind(buf: &[u8]) -> Option<&'static str> {
    if buf.len() < 12 {
        return None;
    }
    if buf[0] == 0xFF && buf[1] == 0xD8 {
        return Some("image/jpeg");
    }
    if buf.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        return Some("image/png");
    }
    if buf.starts_with(b"GIF8") {
        return Some("image/gif");
    }
    if buf.starts_with(b"RIFF") && &buf[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    None
}

/// 取封面：命中缓存直接返回，否则下载并按需解密。
pub async fn load_image(url: &str) -> Result<(String, Arc<Vec<u8>>), String> {
    if let Some(hit) = IMG_CACHE.lock().unwrap().get(url).cloned() {
        let kind = image_kind(&hit).unwrap_or("image/jpeg");
        return Ok((kind.to_string(), hit));
    }
    let (_, bytes) = fetch_bytes(url).await?;
    let plain = if image_kind(&bytes).is_some() {
        bytes
    } else {
        let dec = aes_cbc_decrypt(&bytes).ok_or_else(|| "封面解密失败".to_string())?;
        strip_padding(dec)
    };
    let kind = image_kind(&plain).unwrap_or("image/jpeg").to_string();
    let arc = Arc::new(plain);
    cache_put(&IMG_CACHE, url.to_string(), arc.clone(), IMG_CACHE_MAX);
    Ok((kind, arc))
}

/* ───────────────────────── HLS ───────────────────────── */

pub(crate) fn enc(s: &str) -> String {
    utf8_percent_encode(s, NON_ALPHANUMERIC).to_string()
}

pub(crate) fn dec(s: &str) -> String {
    percent_decode_str(s).decode_utf8_lossy().to_string()
}

fn absolutize(base: &str, target: &str) -> String {
    if target.starts_with("http://") || target.starts_with("https://") {
        return target.to_string();
    }
    if let Ok(b) = url::Url::parse(base) {
        if let Ok(j) = b.join(target) {
            return j.to_string();
        }
    }
    target.to_string()
}

fn rewrite_uri_attr(line: &str, prefix: &str) -> String {
    // #EXT-X-KEY:...URI="xxx" / #EXT-X-MAP:URI="xxx"
    if let Some(start) = line.find("URI=\"") {
        let rest = &line[start + 5..];
        if let Some(end) = rest.find('"') {
            let uri = &rest[..end];
            let new = format!("{prefix}/seg?u={}", enc(uri));
            return format!("{}{}{}", &line[..start + 5], new, &rest[end..]);
        }
    }
    line.to_string()
}

/// 取 m3u8 并把 key / 分片地址改写到本地服务地址。
pub async fn load_playlist(url: &str, prefix: &str) -> Result<Arc<String>, String> {
    if let Some(hit) = PL_CACHE.lock().unwrap().get(url).cloned() {
        return Ok(hit);
    }
    let (_, bytes) = fetch_bytes(url).await?;
    let text = String::from_utf8_lossy(&bytes).to_string();

    let mut out = String::with_capacity(text.len() + 512);
    for raw in text.lines() {
        let line = raw.trim_end();
        if line.is_empty() {
            out.push('\n');
            continue;
        }
        if line.starts_with('#') {
            if line.starts_with("#EXT-X-KEY") || line.starts_with("#EXT-X-MAP") {
                // 先把相对 URI 绝对化再改写
                let absolute = absolutize_uri_in_attr(url, line);
                out.push_str(&rewrite_uri_attr(&absolute, prefix));
            } else {
                out.push_str(line);
            }
        } else {
            let absolute = absolutize(url, line);
            out.push_str(&format!("{prefix}/seg?u={}", enc(&absolute)));
        }
        out.push('\n');
    }

    let arc = Arc::new(out);
    cache_put(&PL_CACHE, url.to_string(), arc.clone(), PL_CACHE_MAX);
    Ok(arc)
}

fn absolutize_uri_in_attr(base: &str, line: &str) -> String {
    if let Some(start) = line.find("URI=\"") {
        let rest = &line[start + 5..];
        if let Some(end) = rest.find('"') {
            let uri = &rest[..end];
            let abs = absolutize(base, uri);
            return format!("{}{}{}", &line[..start + 5], abs, &rest[end..]);
        }
    }
    line.to_string()
}

/// 清空封面 / 播放列表内存缓存
pub fn clear_caches() {
    if let Ok(mut g) = IMG_CACHE.lock() { g.clear(); }
    if let Ok(mut g) = PL_CACHE.lock() { g.clear(); }
}

/* ───────────────────────── 响应 ───────────────────────── */

pub struct HResp {
    pub status: u16,
    pub ctype: String,
    pub cache: String,
    pub body: Vec<u8>,
    /// Range 命中时：(Content-Range 值, 切片)。server.rs 据此回 206。
    pub range_info: Option<(String, Vec<u8>)>,
}

fn respond(status: u16, ctype: &str, body: Vec<u8>, cache: &str) -> HResp {
    HResp {
        status,
        ctype: ctype.to_string(),
        cache: cache.to_string(),
        body,
        range_info: None,
    }
}

/// 统一入口：`/img?u=` / `/hls?u=` / `/seg?u=`（base 为本地服务根地址）。
pub async fn handle(path: &str, query: &str, base: &str) -> HResp {
    let target = query
        .split('&')
        .find_map(|kv| kv.strip_prefix("u="))
        .map(dec)
        .unwrap_or_default();

    if target.is_empty() {
        return respond(400, "text/plain", b"missing u".to_vec(), "no-store");
    }

    match path {
        "/img" => match load_image(&target).await {
            Ok((kind, bytes)) => respond(200, &kind, bytes.as_ref().clone(), "public, max-age=86400"),
            Err(e) => respond(502, "text/plain", e.into_bytes(), "no-store"),
        },
        "/hls" => match load_playlist(&target, base).await {
            Ok(text) => respond(
                200,
                "application/vnd.apple.mpegurl",
                text.as_bytes().to_vec(),
                "no-store",
            ),
            Err(e) => respond(502, "text/plain", e.into_bytes(), "no-store"),
        },
        "/seg" => match fetch_bytes(&target).await {
            Ok((ctype, bytes)) => respond(
                200,
                ctype.as_deref().unwrap_or("application/octet-stream"),
                bytes,
                "public, max-age=3600",
            ),
            Err(e) => respond(502, "text/plain", e.into_bytes(), "no-store"),
        },
        _ => respond(404, "text/plain", b"not found".to_vec(), "no-store"),
    }
}

/// 生成经本地代理的媒体地址：m3u8 → /hls（改写），其它 → /seg（透传）。
pub fn proxy_url(base: &str, url: &str) -> String {
    if i_test(url) {
        format!("{base}/hls?u={}", enc(url))
    } else {
        format!("{base}/seg?u={}", enc(url))
    }
}

/// Rust 没有内联正则；这里手写 m3u8 判定（等价于旧前端的 /\.m3u8(\?|$)/i）。
fn i_test(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    if let Some(p) = lower.find(".m3u8") {
        let rest = &lower[p + 5..];
        rest.is_empty() || rest.starts_with('?')
    } else {
        false
    }
}
