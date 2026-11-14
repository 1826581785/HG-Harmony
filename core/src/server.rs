//! 本地媒体服务：127.0.0.1 极简 HTTP/1.1（GET/HEAD + 单区间 Range + Connection: close）。
//! 供 AVPlayer / Image 等原生组件直接取流，替代旧工程的 hg:// 自定义协议。

use crate::media::{handle, HResp};
use once_cell::sync::OnceCell;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

static BASE_URL: OnceCell<String> = OnceCell::new();

pub fn base_url() -> Option<&'static String> {
    BASE_URL.get()
}

/// 启动监听（随机端口），循环 accept。由 hg_media_start 在 tokio runtime 里 spawn。
pub async fn run() -> Result<(), String> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("本地媒体服务绑定失败: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| e.to_string())?
        .port();
    let base = format!("http://127.0.0.1:{port}");
    let _ = BASE_URL.set(base);
    loop {
        let (stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
        tokio::spawn(serve_conn(stream));
    }
}

async fn serve_conn(mut stream: TcpStream) {
    // 读到请求头结束（\r\n\r\n）；GET/HEAD 请求不读 body
    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    let mut tmp = [0u8; 4096];
    let header_end;
    loop {
        let n = match stream.read(&mut tmp).await {
            Ok(0) => return,
            Ok(n) => n,
            Err(_) => return,
        };
        buf.extend_from_slice(&tmp[..n]);
        if let Some(p) = find(&buf, b"\r\n\r\n") {
            header_end = p + 4;
            break;
        }
        if buf.len() > 65536 {
            return;
        }
    }
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = head.lines();
    let req_line = lines.next().unwrap_or("");
    let mut parts = req_line.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_uppercase();
    let target = parts.next().unwrap_or("/").to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };
    let range = lines
        .filter_map(|l| {
            let lower = l.to_ascii_lowercase();
            lower.strip_prefix("range: ").map(|_| l.to_string())
        })
        .next();

    let base = base_url().map(|s| s.as_str()).unwrap_or("http://127.0.0.1:0");
    let resp = handle(&path, &query, base).await;
    let is_head = method == "HEAD";
    let resp = apply_range(resp, range.as_deref());

    let reason = match resp.status {
        200 => "OK",
        206 => "Partial Content",
        400 => "Bad Request",
        404 => "Not Found",
        502 => "Bad Gateway",
        _ => "OK",
    };
    let mut head_out = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nCache-Control: {}\r\nAccess-Control-Allow-Origin: *\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nConnection: close\r\n",
        resp.status, reason, resp.ctype, resp.cache, resp.body.len()
    );
    if let Some((cr, _)) = &resp.range_info {
        head_out.push_str(&format!("Content-Range: {cr}\r\n"));
    }
    head_out.push_str("\r\n");

    let mut out: Vec<u8> = head_out.into_bytes();
    if !is_head {
        match &resp.range_info {
            Some((_, slice)) => out.extend_from_slice(slice),
            None => out.extend_from_slice(&resp.body),
        }
    }
    let _ = stream.write_all(&out).await;
    let _ = stream.flush().await;
    let _ = stream.shutdown().await;
}

/// 单区间 Range：bytes=start-end / bytes=start-
/// 返回 (状态, 体, Some((Content-Range, 切片))) 或原响应。
fn apply_range(resp: HResp, range: Option<&str>) -> HResp {
    let (start, end) = match parse_range(range, resp.body.len() as u64) {
        Some((s, e)) => (s, e),
        None => return HResp { range_info: None, ..resp },
    };
    if resp.status != 200 {
        return HResp { range_info: None, ..resp };
    }
    let slice = resp.body[start as usize..(end + 1) as usize].to_vec();
    let cr = format!("bytes {start}-{end}/{}", resp.body.len());
    HResp {
        status: 206,
        range_info: Some((cr, slice)),
        ..resp
    }
}

fn parse_range(range: Option<&str>, total: u64) -> Option<(u64, u64)> {
    if total == 0 {
        return None;
    }
    let spec = range?.strip_prefix("bytes=")?.trim().to_string();
    let (s, e) = spec.split_once('-')?;
    let start: u64 = s.trim().parse().ok()?;
    let end: u64 = if e.trim().is_empty() {
        total - 1
    } else {
        let ev: u64 = e.trim().parse().ok()?;
        ev.min(total - 1)
    };
    if start > end || start >= total {
        return None;
    }
    Some((start, end))
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.len() > haystack.len() {
        return None;
    }
    (0..=haystack.len() - needle.len()).find(|&i| &haystack[i..i + needle.len()] == needle)
}
