//! 下载管理：m3u8 → 分片下载 → AES-128 解密 → 拼接 → MP4 封装 → 应用沙箱 Download 目录。
//!
//! 平移自旧工程 src-tauri/src/download.rs，改动点：
//! - 去 Tauri：全局单例 `dl()`，状态推送改经 NAPI ThreadsafeFunction（JSON 任务列表快照）
//! - 落盘全部在应用沙箱（filesDir）：分片缓存 `<dir>/downloads/<id>/`，成品 `<dir>/Download/`
//! - 删除 need_permission 状态（沙箱写盘无需权限；保存到系统图库由 ArkTS 侧 photoAccessHelper 完成）
//! - 播放地址复用 api().play()（streams.main/preview → video_url 转换内置）

use crate::api::Api;
use crate::mux;
use crate::net;
use aes::cipher::{BlockDecryptMut, KeyIvInit};
use napi_ohos::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use once_cell::sync::Lazy;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::{Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex as AsyncMutex, Notify};
use url::Url;

type Aes128CbcDec = cbc::Decryptor<aes::Aes128>;

/* ───────────────────────── 状态模型 ───────────────────────── */

#[derive(Debug, Clone, Serialize, PartialEq, serde::Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    #[default]
    Queued,
    Running,
    Paused,
    Muxing,
    Saving,
    Done,
    Failed,
}

#[derive(Debug, Clone, Serialize, serde::Deserialize, Default)]
#[serde(default)]
pub struct Task {
    pub id: u64,
    pub video_id: i64,
    pub ep: u32,
    pub title: String,
    pub ep_title: String,
    pub status: Status,
    pub seg_done: u32,
    pub seg_total: u32,
    /// 已下载（MB）
    pub mb_done: f64,
    /// 估算总大小（MB）
    pub mb_total: f64,
    /// 当前网速（MB/s）
    pub speed: f64,
    pub error: Option<String>,
    /// 已保存的文件名（Done 时有值）
    pub file: Option<String>,
    pub created: u64,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

struct Signal {
    pause: AtomicBool,
    cancel: AtomicBool,
    notify: Notify,
}

impl Signal {
    fn new() -> Self {
        Self { pause: AtomicBool::new(false), cancel: AtomicBool::new(false), notify: Notify::new() }
    }
}

/// 状态回调（NAPI 注册，ArkTS 侧更新 AppStorage）。值为整个任务列表快照的 JSON 字符串。
static STATE_CB: OnceLock<ThreadsafeFunction<String>> = OnceLock::new();

pub fn set_state_callback(cb: ThreadsafeFunction<String>) {
    let _ = STATE_CB.set(cb);
}

/// 全局下载管理器（data_dir 由 hg_init 时绑定）。
static DL: Lazy<DownloadManager> = Lazy::new(DownloadManager::new);
static DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

pub fn init(data_dir: &Path) {
    let _ = DATA_DIR.set(data_dir.to_path_buf());
    let _ = DL.persist_path.set(data_dir.join("downloads.json"));
}

pub fn dl() -> &'static DownloadManager {
    &DL
}

pub struct DownloadManager {
    /// UI 快照（顺序 = 添加顺序）
    tasks: StdMutex<Vec<Task>>,
    /// id → 控制信号
    signals: StdMutex<HashMap<u64, Arc<Signal>>>,
    /// 正在运行的 worker（防重复 spawn）
    running: StdMutex<HashSet<u64>>,
    /// 同时只允许一个任务下载
    slot: AsyncMutex<()>,
    next_id: AtomicU64,
    persist_path: OnceLock<PathBuf>,
}

fn sanitize(name: &str) -> String {
    name.chars()
        .map(|c| match c {
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            _ => c,
        })
        .collect::<String>()
        .trim()
        .to_string()
}

fn data_dir() -> &'static Path {
    DATA_DIR.get().map(|p| p.as_path()).unwrap_or_else(|| Path::new("."))
}

/// 成品目录（应用沙箱 Download）
pub fn download_dir() -> PathBuf {
    data_dir().join("Download")
}

/// 分片缓存根目录
fn seg_root() -> PathBuf {
    data_dir().join("downloads")
}

impl DownloadManager {
    fn new() -> Self {
        Self {
            tasks: StdMutex::new(Vec::new()),
            signals: StdMutex::new(HashMap::new()),
            running: StdMutex::new(HashSet::new()),
            slot: AsyncMutex::new(()),
            next_id: AtomicU64::new(1),
            persist_path: OnceLock::new(),
        }
    }

    fn persist(&self) {
        if let Some(p) = self.persist_path.get() {
            let tasks = self.tasks.lock().unwrap().clone();
            let _ = std::fs::write(p, serde_json::to_vec(&tasks).unwrap_or_default());
        }
    }

    fn push_event(&self) {
        let tasks = self.tasks.lock().unwrap().clone();
        if let Ok(json) = serde_json::to_string(&tasks) {
            if let Some(cb) = STATE_CB.get() {
                cb.call(Ok(json), ThreadsafeFunctionCallMode::NonBlocking);
            }
        }
        self.persist();
    }

    fn snapshot_of(&self, id: u64) -> Option<Task> {
        self.tasks.lock().unwrap().iter().find(|t| t.id == id).cloned()
    }

    fn update<F: FnOnce(&mut Task)>(&self, id: u64, f: F) {
        let mut tasks = self.tasks.lock().unwrap();
        if let Some(t) = tasks.iter_mut().find(|t| t.id == id) {
            f(t);
        }
        drop(tasks);
        self.push_event();
    }

    /// 添加任务。同剧同集已完成 → None（前端提示重复）。
    pub fn add(&self, api: &'static Api, video_id: i64, ep: u32, title: String, ep_title: String) -> Option<u64> {
        let mut tasks = self.tasks.lock().unwrap();
        if tasks.iter().any(|t| {
            t.video_id == video_id && t.ep == ep && matches!(t.status, Status::Done)
        }) {
            return None;
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        tasks.push(Task {
            id,
            video_id,
            ep,
            title,
            ep_title,
            status: Status::Queued,
            seg_done: 0,
            seg_total: 0,
            mb_done: 0.0,
            mb_total: 0.0,
            speed: 0.0,
            error: None,
            file: None,
            created: now(),
        });
        drop(tasks);
        self.signals.lock().unwrap().insert(id, Arc::new(Signal::new()));
        self.push_event();
        self.spawn_worker(api, id);
        Some(id)
    }

    pub fn pause(&self, id: u64) {
        if let Some(sig) = self.signals.lock().unwrap().get(&id) {
            sig.pause.store(true, Ordering::SeqCst);
            sig.notify.notify_waiters();
        }
        // 状态由 worker 在下一个边界翻转；排队中的任务直接标 Paused
        self.update(id, |t| {
            if matches!(t.status, Status::Queued) {
                t.status = Status::Paused;
            }
        });
    }

    pub fn resume(&self, api: &'static Api, id: u64) {
        if let Some(sig) = self.signals.lock().unwrap().get(&id) {
            sig.pause.store(false, Ordering::SeqCst);
            sig.notify.notify_waiters();
        }
        // worker 活着会自己回 Running；若 worker 已退出（重启恢复），下面幂等拉起
        self.update(id, |t| {
            if matches!(t.status, Status::Paused) {
                t.status = Status::Queued;
            }
        });
        self.spawn_worker(api, id);
    }

    pub fn retry(&self, api: &'static Api, id: u64) {
        if let Some(sig) = self.signals.lock().unwrap().get(&id) {
            sig.pause.store(false, Ordering::SeqCst);
            sig.cancel.store(false, Ordering::SeqCst);
            sig.notify.notify_waiters();
        }
        self.update(id, |t| {
            if matches!(t.status, Status::Failed) {
                t.status = Status::Queued;
                t.error = None;
            }
        });
        self.spawn_worker(api, id);
    }

    /// 删除任务：清分片缓存 + 移出列表（已保存的成品文件不动）。
    pub fn remove(&self, id: u64) {
        if let Some(sig) = self.signals.lock().unwrap().get(&id) {
            sig.cancel.store(true, Ordering::SeqCst);
            sig.notify.notify_waiters();
        }
        self.running.lock().unwrap().remove(&id);
        let dir = seg_root().join(id.to_string());
        let _ = std::fs::remove_dir_all(dir);
        self.tasks.lock().unwrap().retain(|t| t.id != id);
        self.push_event();
    }

    /// 应用启动：恢复持久化的任务（中断的任务回队列续传）+ 清理无主分片缓存。
    pub fn restore(&self, api: &'static Api) {
        let saved: Vec<Task> = std::fs::read(self.persist_path.get().unwrap_or(&PathBuf::new()))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let mut max_id = 0u64;
        let mut to_spawn = Vec::new();
        {
            let mut tasks = self.tasks.lock().unwrap();
            for mut t in saved {
                max_id = max_id.max(t.id);
                if matches!(
                    t.status,
                    Status::Running | Status::Queued | Status::Muxing | Status::Saving
                ) {
                    t.status = Status::Queued;
                    t.speed = 0.0;
                    to_spawn.push(t.id);
                }
                tasks.push(t);
            }
        }
        self.next_id.store(max_id + 1, Ordering::SeqCst);
        for id in to_spawn {
            self.signals
                .lock()
                .unwrap()
                .entry(id)
                .or_insert_with(|| Arc::new(Signal::new()));
            self.spawn_worker(api, id);
        }
        // 清理不在任务列表里的残留分片缓存（正常完成的已在成功时清除）
        if let Ok(entries) = std::fs::read_dir(seg_root()) {
            let active: HashSet<u64> =
                self.tasks.lock().unwrap().iter().map(|t| t.id).collect();
            for e in entries.flatten() {
                if let Ok(tid) = e.file_name().to_string_lossy().parse::<u64>() {
                    if !active.contains(&tid) {
                        let _ = std::fs::remove_dir_all(e.path());
                    }
                }
            }
        }
        self.push_event();
    }

    fn spawn_worker(&self, api: &'static Api, id: u64) {
        if !self.running.lock().unwrap().insert(id) {
            return; // worker 已在跑
        }
        let Some(task) = self.snapshot_of(id) else {
            self.running.lock().unwrap().remove(&id);
            return;
        };
        let Some(sig) = self.signals.lock().unwrap().get(&id).cloned() else {
            self.running.lock().unwrap().remove(&id);
            return;
        };
        tokio::spawn(async move {
            worker(api, id, task.video_id, task.ep, sig).await;
        });
    }

    pub fn list(&self) -> Vec<Task> {
        self.tasks.lock().unwrap().clone()
    }

    /// 校验已完成任务的文件是否还在磁盘上，被外部删除的记录自动移出列表。
    pub fn verify_done_files(&self) {
        let dir = download_dir();
        let mut changed = false;
        self.tasks.lock().unwrap().retain(|t| {
            if t.status == Status::Done {
                match &t.file {
                    Some(f) if dir.join(f).exists() => true,
                    // 文件不存在（被清理/移动）→ 移除记录
                    _ => {
                        changed = true;
                        false
                    }
                }
            } else {
                true
            }
        });
        if changed {
            self.push_event();
        }
    }
}

/* ───────────────────────── worker ───────────────────────── */

/// worker 主循环：排队拿单任务槽 → 下载（可暂停/取消）→ 出错标记。
async fn worker(api: &'static Api, id: u64, video_id: i64, ep: u32, sig: Arc<Signal>) {
    let dm = dl();
    loop {
        // 暂停等待
        loop {
            if sig.cancel.load(Ordering::SeqCst) {
                dm.running.lock().unwrap().remove(&id);
                return;
            }
            if !sig.pause.load(Ordering::SeqCst) {
                break;
            }
            dm.update(id, |t| {
                if matches!(t.status, Status::Running | Status::Muxing | Status::Saving) {
                    t.status = Status::Paused;
                    t.speed = 0.0;
                }
            });
            sig.notify.notified().await;
        }
        let _slot = dm.slot.lock().await; // 排队（同时只一个任务下载）
        if sig.pause.load(Ordering::SeqCst) {
            drop(_slot);
            continue; // 拿到槽时又被暂停 → 释放槽回去等
        }
        dm.update(id, |t| t.status = Status::Running);

        match run_download(dm, id, video_id, ep, &sig, api).await {
            Ok(file) => {
                dm.update(id, |t| {
                    t.status = Status::Done;
                    t.file = Some(file);
                    t.speed = 0.0;
                });
                dm.running.lock().unwrap().remove(&id);
                return;
            }
            Err(e) if e == "PAUSED" => {
                drop(_slot);
                continue; // 回循环：标 Paused、等恢复
            }
            Err(e) if e == "CANCELLED" => {
                dm.running.lock().unwrap().remove(&id);
                return;
            }
            Err(e) => {
                dm.update(id, |t| {
                    t.status = Status::Failed;
                    t.error = Some(e);
                    t.speed = 0.0;
                });
                dm.running.lock().unwrap().remove(&id);
                return;
            }
        }
    }
}

async fn run_download(
    dm: &DownloadManager,
    id: u64,
    video_id: i64,
    ep: u32,
    sig: &Signal,
    api: &'static Api,
) -> Result<String, String> {
    // 边界检查
    macro_rules! boundary {
        () => {
            if sig.cancel.load(Ordering::SeqCst) {
                return Err("CANCELLED".into());
            }
            if sig.pause.load(Ordering::SeqCst) {
                return Err("PAUSED".into());
            }
        };
    }
    boundary!();

    // 1. 取播放地址（每次运行现取，auth_key 有时效）
    let raw = api.play(video_id, ep).await?;
    let url = raw
        .get("video_url")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or("播放地址为空")?
        .to_string();

    // 2. 解析 m3u8（master → 选最高 BANDWIDTH）
    let (playlist_url, m3u8) = resolve_master(&url).await?;
    let (key_uri, iv_hex, seg_uris, media_seq) = parse_m3u8(&m3u8)?;

    // 3. key + iv
    let key = if let Some(ku) = &key_uri {
        let kurl = join_url(&playlist_url, ku)?;
        let (_, kb) = net::fetch_bytes(&kurl).await?;
        if kb.len() != 16 {
            return Err(format!("key 长度异常: {}", kb.len()));
        }
        Some(kb)
    } else {
        None
    };
    let iv: [u8; 16] = match &iv_hex {
        Some(h) => parse_iv_hex(h),
        None => {
            let mut iv = [0u8; 16];
            iv[12..16].copy_from_slice(&media_seq.to_be_bytes());
            iv
        }
    };

    // 4. 分片下载（缓存目录：filesDir/downloads/<id>/）
    let seg_dir = seg_root().join(id.to_string());
    std::fs::create_dir_all(&seg_dir).map_err(|e| e.to_string())?;

    dm.update(id, |t| {
        t.seg_total = seg_uris.len() as u32;
    });

    let mut done_bytes: u64 = 0;
    let mut tick_last = Instant::now();
    let mut tick_bytes: u64 = 0;
    let mut speed: f64 = 0.0;

    for (i, seg) in seg_uris.iter().enumerate() {
        boundary!();
        let path = seg_dir.join(format!("{i:05}.seg"));
        if !path.exists() {
            let surl = join_url(&playlist_url, seg)?;
            let (_, bytes) = net::fetch_bytes(&surl).await?;
            let data = if let Some(k) = &key {
                if bytes.len() % 16 != 0 {
                    return Err(format!("分片 {i} 长度非 16 倍数"));
                }
                let mut plain = bytes.clone();
                let mut dec = Aes128CbcDec::new(k.as_slice().into(), (&iv).into());
                for chunk in plain.chunks_mut(16) {
                    dec.decrypt_block_mut(chunk.into());
                }
                strip_pkcs7(&plain).to_vec()
            } else {
                bytes
            };
            let tmp = seg_dir.join(format!("{i:05}.tmp"));
            std::fs::write(&tmp, &data).map_err(|e| e.to_string())?;
            std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
            tick_bytes += data.len() as u64;
        }
        let sz = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        done_bytes += sz;

        let elapsed = tick_last.elapsed();
        if elapsed >= Duration::from_millis(400) {
            let inst = tick_bytes as f64 / elapsed.as_secs_f64();
            speed = if speed == 0.0 { inst } else { speed * 0.6 + inst * 0.4 };
            tick_last = Instant::now();
            tick_bytes = 0;
            let spd = speed / 1048576.0;
            let total_est = if done_bytes > 0 {
                (done_bytes as f64 / (i + 1) as f64) * seg_uris.len() as f64 / 1048576.0
            } else {
                0.0
            };
            dm.update(id, |t| {
                t.seg_done = (i + 1) as u32;
                t.mb_done = done_bytes as f64 / 1048576.0;
                t.mb_total = total_est;
                t.speed = spd;
            });
        } else {
            dm.update(id, |t| {
                t.seg_done = (i + 1) as u32;
                t.mb_done = done_bytes as f64 / 1048576.0;
            });
        }
    }
    dm.update(id, |t| {
        t.speed = 0.0;
        t.mb_total = t.mb_done;
        t.mb_done = done_bytes as f64 / 1048576.0;
        t.seg_done = seg_uris.len() as u32;
    });

    // 5. 逐分片读入 + 封装（分段喂入，自动对齐时间戳回绕）
    boundary!();
    dm.update(id, |t| t.status = Status::Muxing);
    let mut segments: Vec<Vec<u8>> = Vec::with_capacity(seg_uris.len());
    for i in 0..seg_uris.len() {
        boundary!();
        let path = seg_dir.join(format!("{i:05}.seg"));
        let data = std::fs::read(&path).map_err(|e| e.to_string())?;
        segments.push(data);
    }

    boundary!();
    dm.update(id, |t| t.status = Status::Saving);
    let tmp_mp4 = seg_dir.join("out.mp4");
    {
        let f = std::fs::File::create(&tmp_mp4).map_err(|e| e.to_string())?;
        let mut f = std::io::BufWriter::new(f);
        mux::ts_segments_to_mp4(&segments, &mut f).map_err(|e| format!("MP4 封装失败: {e}"))?;
        use std::io::Write;
        f.flush().map_err(|e| e.to_string())?;
    }
    drop(segments);

    // 6. 落盘（应用沙箱 Download/；保存到系统图库由 ArkTS 侧完成）
    let task = dm.snapshot_of(id).ok_or("内部错误：任务不存在")?;
    let base = sanitize(&task.title);
    if base.is_empty() {
        return Err("剧名为空，无法命名文件".into());
    }
    let fname_t = format!("{base}_第{}集", task.ep);
    let dir = download_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let final_path = unique_path(&dir, &fname_t, "mp4");
    std::fs::copy(&tmp_mp4, &final_path).map_err(|e| e.to_string())?;

    // 7. 清分片（HG_KEEP_SEGS=1 时保留，供离线诊断转封装问题）
    if std::env::var("HG_KEEP_SEGS").map(|v| v == "1").unwrap_or(false) {
        let meta = format!(
            "video_id={} ep={} title={} playlist={}",
            video_id, ep, task.title, url
        );
        let _ = std::fs::write(seg_root().join(format!("{id}.meta.txt")), meta);
    } else {
        let _ = std::fs::remove_dir_all(&seg_dir);
    }

    let name = final_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    Ok(name)
}

fn strip_pkcs7(data: &[u8]) -> &[u8] {
    if let Some(&p) = data.last() {
        if (1..=16).contains(&p) && data.len() > p as usize {
            if data[data.len() - p as usize..].iter().all(|&b| b == p) {
                return &data[..data.len() - p as usize];
            }
        }
    }
    data
}

fn parse_iv_hex(h: &str) -> [u8; 16] {
    let mut iv = [0u8; 16];
    let h = h.trim().trim_start_matches("0x").trim_start_matches("0X");
    let bytes = h.as_bytes();
    // 十六进制右对齐填充（IV 通常完整 32 字符，容错短串）
    let mut i = 0;
    let chunks: Vec<&[u8]> = bytes.rchunks(2).collect();
    for c in chunks.into_iter().take(16) {
        let s = std::str::from_utf8(c).unwrap_or("0");
        if let Ok(v) = u8::from_str_radix(s, 16) {
            if i < 16 {
                iv[15 - i] = v;
            }
        }
        i += 1;
    }
    iv
}

/// master 播放列表 → 选最高 BANDWIDTH 的变体。返回 (最终媒体列表 URL, 文本)。
async fn resolve_master(url: &str) -> Result<(String, String), String> {
    let (_, text) = net::fetch_bytes(url).await?;
    let text = String::from_utf8_lossy(&text).to_string();
    if !text.contains("#EXT-X-STREAM-INF") {
        return Ok((url.to_string(), text));
    }
    let mut best: (u64, Option<String>) = (0, None);
    let mut lines = text.lines();
    while let Some(line) = lines.next() {
        if let Some(attr) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            let bw = attr
                .split(',')
                .find_map(|kv| {
                    kv.trim()
                        .strip_prefix("BANDWIDTH=")
                        .and_then(|v| v.parse::<u64>().ok())
                })
                .unwrap_or(0);
            let uri = lines.next().map(|s| s.trim().to_string());
            if let Some(uri) = uri {
                if bw >= best.0 {
                    best = (bw, Some(uri));
                }
            }
        }
    }
    let Some(uri) = best.1 else {
        return Ok((url.to_string(), text));
    };
    let child = join_url(url, &uri)?;
    let (_, t2) = net::fetch_bytes(&child).await?;
    Ok((child, String::from_utf8_lossy(&t2).to_string()))
}

/// 极简 m3u8 解析（单 key 场景）。返回 (key uri, iv, 分片 uri 列表, media sequence)。
fn parse_m3u8(text: &str) -> Result<(Option<String>, Option<String>, Vec<String>, u64), String> {
    if !text.contains("#EXTM3U") {
        return Err("响应不是 m3u8".into());
    }
    let mut key_uri = None;
    let mut iv = None;
    let mut segs = Vec::new();
    let mut seq = 0u64;
    for line in text.lines() {
        let line = line.trim();
        if let Some(a) = line.strip_prefix("#EXT-X-KEY:") {
            let method = a
                .split(',')
                .find_map(|kv| kv.trim().strip_prefix("METHOD=").map(|s| s.to_string()));
            if method.as_deref() != Some("AES-128") {
                return Err(format!("不支持的加密方式: {:?}", method.unwrap_or_default()));
            }
            if let Some(u) = a.split(',').find_map(|kv| {
                kv.trim()
                    .strip_prefix("URI=\"")
                    .map(|s| s.trim_end_matches('"').to_string())
            }) {
                key_uri = Some(u);
            }
            if let Some(v) = a
                .split(',')
                .find_map(|kv| kv.trim().strip_prefix("IV=").map(|s| s.to_string()))
            {
                iv = Some(v);
            }
        } else if let Some(s) = line.strip_prefix("#EXT-X-MEDIA-SEQUENCE:") {
            seq = s.trim().parse().unwrap_or(0);
        } else if !line.starts_with('#') && !line.is_empty() {
            segs.push(line.to_string());
        }
    }
    if segs.is_empty() {
        return Err("m3u8 无分片".into());
    }
    Ok((key_uri, iv, segs, seq))
}

fn join_url(base: &str, uri: &str) -> Result<String, String> {
    if uri.starts_with("http://") || uri.starts_with("https://") {
        return Ok(uri.to_string());
    }
    let joined = Url::parse(base)
        .map_err(|e| e.to_string())?
        .join(uri)
        .map_err(|e| e.to_string())?;
    Ok(joined.to_string())
}

fn unique_path(dir: &Path, stem: &str, ext: &str) -> PathBuf {
    let mut p = dir.join(format!("{stem}.{ext}"));
    let mut n = 1;
    while p.exists() {
        p = dir.join(format!("{stem} ({n}).{ext}"));
        n += 1;
    }
    p
}
