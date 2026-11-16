//! MPEG-TS 解封装 + H264/AAC → MP4 无损转封装（不重编码）。
//!
//! 流程：m3u8 分片（AES-128 解密后）拼接为 TS → 解出 H264（AnnexB）与 AAC（ADTS）
//! 基本流 → 按 PES 组帧 → AVCC 化（4 字节长度前缀）→ mp4 crate 写出 MP4。
//! 视频时间基 90kHz（PES 原生），音频时间基 = 采样率。

use std::collections::HashMap;
use std::io::{Seek, Write};

use mp4::{
    AacConfig, AvcConfig, AudioObjectType, Bytes, ChannelConfig, FourCC, MediaConfig,
    Mp4Config, Mp4Sample, Mp4Writer, SampleFreqIndex, TrackConfig, TrackType,
};

/* ───────────────────────── TS 解封装 ───────────────────────── */



const TS_PACKET: usize = 188;

struct PesOut {
    stream_type: u8, // 0x1b = H264, 0x0f = AAC
    pts: u64,
    dts: u64,
    has_dts: bool,
    es: Vec<u8>,
}

/// 极简 TS 解封装：只认 PAT → PMT → H264/AAC 两个 ES。
#[derive(Default)]
struct TsDemuxer {
    pmt_pid: Option<u16>,
    /// pid → (stream_type, 正在重组的 PES 负载)
    streams: HashMap<u16, (u8, Vec<u8>)>,
}

impl TsDemuxer {
    fn feed(&mut self, data: &[u8], out: &mut Vec<PesOut>) {
        let mut off = 0;
        while off + TS_PACKET <= data.len() {
            let pkt = &data[off..off + TS_PACKET];
            off += TS_PACKET;
            if pkt[0] != 0x47 {
                continue; // 丢同步
            }
            let pusi = pkt[1] & 0x40 != 0;
            let pid = (((pkt[1] & 0x1f) as u16) << 8) | pkt[2] as u16;
            let afc = (pkt[3] >> 4) & 0x3;
            let mut pos = 4;
            if afc & 0x2 != 0 {
                pos = 5 + pkt[4] as usize; // 自适应字段长度
            }
            if afc & 0x1 == 0 || pos >= TS_PACKET {
                continue; // 无负载
            }
            let payload = &pkt[pos..];

            if pid == 0 {
                if pusi {
                    if let Some(pmt) = parse_pat(payload) {
                        self.pmt_pid = Some(pmt);
                    }
                }
                continue;
            }
            if Some(pid) == self.pmt_pid {
                if pusi {
                    parse_pmt(payload, &mut self.streams);
                }
                continue;
            }
            let Some((stype, buf)) = self.streams.get_mut(&pid) else {
                continue;
            };
            if pusi {
                // PES 无 pointer_field，载荷直接是 PES 头
                if !buf.is_empty() {
                    match parse_pes(buf, *stype) {
                        Some(p) => out.push(p),
                        None if std::env::var("HG_MUX_DEBUG").is_ok() => {
                            let hex: String =
                                buf.iter().take(24).map(|b| format!("{b:02x} ")).collect();
                            eprintln!("[pes parse fail] pid={pid} len={} head={hex}", buf.len());
                        }
                        None => {}
                    }
                    buf.clear();
                }
                buf.extend_from_slice(payload);
            } else if !buf.is_empty() {
                buf.extend_from_slice(payload);
            }
        }
    }

    /// 流结束（一个分片文件读完），冲刷尾部 PES。
    fn flush(&mut self, out: &mut Vec<PesOut>) {
        for (_, (stype, buf)) in self.streams.iter_mut() {
            if !buf.is_empty() {
                if let Some(p) = parse_pes(buf, *stype) {
                    out.push(p);
                }
                buf.clear();
            }
        }
    }
}

/// PAT：取第一个 program 的 PMT PID。
fn parse_pat(payload: &[u8]) -> Option<u16> {
    let skip = payload[0] as usize + 1; // pointer_field
    let t = payload.get(skip..)?;
    if t.first() != Some(&0x00) {
        return None;
    }
    let section_len = ((t[1] as usize & 0x0f) << 8) | t[2] as usize;
    let mut pos = 8;
    let end = 3 + section_len.saturating_sub(4).min(t.len());
    while pos + 4 <= end {
        let prog = ((t[pos] as u16) << 8) | t[pos + 1] as u16;
        let pmt = (((t[pos + 2] as u16) & 0x1f) << 8) | t[pos + 3] as u16;
        if prog != 0 {
            return Some(pmt);
        }
        pos += 4;
    }
    None
}

/// PMT：登记 ES PID → stream_type。
fn parse_pmt(payload: &[u8], streams: &mut HashMap<u16, (u8, Vec<u8>)>) {
    let skip = payload[0] as usize + 1;
    let Some(t) = payload.get(skip..) else { return };
    if t.first() != Some(&0x02) {
        return;
    }
    let section_len = ((t[1] as usize & 0x0f) << 8) | t[2] as usize;
    let prog_info_len = (((t[10] as usize) & 0x0f) << 8) | t[11] as usize;
    let mut pos = 12 + prog_info_len;
    let end = 3 + section_len.saturating_sub(4).min(t.len());
    while pos + 5 <= end {
        let stype = t[pos];
        let pid = (((t[pos + 1] as u16) & 0x1f) << 8) | t[pos + 2] as u16;
        let es_info_len = (((t[pos + 3] as usize) & 0x0f) << 8) | t[pos + 4] as usize;
        if stype == 0x1b || stype == 0x0f || stype == 0x24 {
            // 只注册不覆盖：PMT 会周期性重传，覆盖会毁掉正在重组的 PES 缓冲
            streams.entry(pid).or_insert((stype, Vec::new()));
        }
        pos += 5 + es_info_len;
    }
}

/// PES → (stream_type, pts, dts, ES)。
/// 布局：00 00 01 sid | len(2) | flags(2) | header_len(1) | header_data | es
fn parse_pes(buf: &[u8], stype: u8) -> Option<PesOut> {
    let idx = buf
        .windows(4)
        .position(|w| w[0] == 0 && w[1] == 0 && w[2] == 1)?;
    if idx + 9 > buf.len() {
        return None;
    }
    let pes_len = ((buf[idx + 4] as usize) << 8) | buf[idx + 5] as usize;
    let end = if pes_len > 0 {
        (idx + 6 + pes_len).min(buf.len())
    } else {
        buf.len()
    };
    let flags = buf[idx + 7]; // PTS/DTS 标志在第二个 flags 字节
    let header_len = buf[idx + 8] as usize;
    let mut hp = idx + 9;
    let mut pts = 0u64;
    let mut dts = 0u64;
    let flag_dts = flags & 0x40 != 0;
    if flags & 0x80 != 0 && hp + 5 <= buf.len() {
        pts = parse_pts(&buf[hp..hp + 5]);
        dts = pts;
        hp += 5;
    }
    if flag_dts && hp + 5 <= buf.len() {
        dts = parse_pts(&buf[hp..hp + 5]);
    }
    let data_start = (idx + 9 + header_len).min(end);
    if data_start >= end {
        return None;
    }
    let es = buf[data_start..end].to_vec();
    if es.is_empty() {
        return None;
    }
    Some(PesOut { stream_type: stype, pts, dts, has_dts: flag_dts, es })
}

fn parse_pts(b: &[u8]) -> u64 {
    // 5 字节布局：4b头 + PTS[32..30] | PTS[29..22] | PTS[21..15] | PTS[14..7] | PTS[6..0]
    (((b[0] as u64) >> 1 & 0x07) << 30)
        | ((b[1] as u64) << 22)
        | (((b[2] as u64) >> 1) << 15)
        | ((b[3] as u64) << 7)
        | ((b[4] as u64) >> 1)
}

/* ───────────────────────── H264：AnnexB → AVCC ───────────────────────── */

struct Nal {
    typ: u8,
    data: Vec<u8>,
}

fn split_annexb(es: &[u8]) -> Vec<Nal> {
    let mut starts: Vec<usize> = Vec::new();
    let n = es.len();
    let mut i = 0;
    while i + 3 < n {
        if es[i] == 0 && es[i + 1] == 0 {
            if es[i + 2] == 1 {
                starts.push(i + 3);
                i += 3;
                continue;
            }
            if es[i + 2] == 0 && i + 4 <= n && es[i + 3] == 1 {
                starts.push(i + 4);
                i += 4;
                continue;
            }
        }
        i += 1;
    }
    let mut nals = Vec::new();
    for (k, &s) in starts.iter().enumerate() {
        let e = starts
            .get(k + 1)
            .map(|&x| if es[x - 4..x - 2] == [0, 0] { x - 4 } else { x - 3 })
            .unwrap_or(n);
        if e > s {
            let data = es[s..e].to_vec();
            if !data.is_empty() {
                nals.push(Nal { typ: data[0] & 0x1f, data });
            }
        }
    }
    nals
}

/// SPS 解析取分辨率（去仿止字节后按 exp-golomb 读）。
fn sps_dimensions(sps: &[u8]) -> Option<(u16, u16)> {
    let mut rbsp = Vec::with_capacity(sps.len());
    let mut z = 0;
    for &b in &sps[1..] {
        if z == 2 && b == 0x03 {
            z = 0;
            continue;
        }
        z = if b == 0 { z + 1 } else { 0 };
        rbsp.push(b);
    }
    struct Br<'a> {
        d: &'a [u8],
        bit: usize,
    }
    impl<'a> Br<'a> {
        fn bit(&mut self) -> Option<u32> {
            let b = self.d.get(self.bit / 8)?;
            let v = (b >> (7 - self.bit % 8)) & 1;
            self.bit += 1;
            Some(v as u32)
        }
        fn bits(&mut self, n: usize) -> Option<u32> {
            let mut v = 0;
            for _ in 0..n {
                v = (v << 1) | self.bit()?;
            }
            Some(v)
        }
        fn ue(&mut self) -> Option<u32> {
            let mut zeros = 0;
            while self.bit()? == 0 {
                zeros += 1;
                if zeros > 31 {
                    return None;
                }
            }
            let mut v = 0u32;
            for _ in 0..zeros {
                v = (v << 1) | self.bit()?;
            }
            Some((1u32 << zeros).wrapping_sub(1) + v)
        }
        fn se(&mut self) -> Option<i32> {
            let ue = self.ue()?;
            Some(if ue % 2 == 1 { ((ue + 1) / 2) as i32 } else { -((ue / 2) as i32) })
        }
    }
    let mut br = Br { d: &rbsp, bit: 0 };
    let profile_idc = br.bits(8)?;
    br.bits(8)?; // constraints
    br.bits(8)?; // level_idc
    br.ue()?; // sps_id
    if matches!(profile_idc, 100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135) {
        let cfm = br.ue()?;
        if cfm == 3 {
            br.bit()?; // separate_colour_plane_flag
        }
        br.ue()?; // bit_depth_luma
        br.ue()?; // bit_depth_chroma
        br.bit()?; // qpprime_y_zero
        let scaling = br.bit()?;
        if scaling != 0 {
            // 跳过 scaling_list
            for _ in 0..(if cfm != 3 { 8 } else { 12 }) {
                if br.bit()? != 0 {
                    let size = if true { 16 } else { 64 };
                    let _ = size;
                    // 简化：不再精确解析，返回失败交给外层兜底
                    return None;
                }
            }
        }
        br.se()?; // pic_scaling_list_present 之后默认
    }
    br.ue()?; // log2_max_frame_num_minus4
    let poc_type = br.ue()?;
    match poc_type {
        0 => {
            br.ue()?;
        }
        1 => {
            br.bit()?;
            br.se()?;
            br.se()?;
            let n = br.ue()?;
            for _ in 0..n {
                if br.ue()? != 0 {
                    br.se()?;
                }
            }
        }
        _ => {}
    }
    br.ue()?; // max_num_ref_frames
    br.bit()?; // gaps_in_frame_num_value_allowed
    let w_mbs = br.ue()? as u32 + 1;
    let h_maps = br.ue()? as u32 + 1;
    let frame_mbs_only = br.bit()? == 1;
    br.bit()?; // direct_8x8_inference_flag
    let cropping = br.bit()? == 1;
    let (mut cl, mut cr, mut ct, mut cb) = (0u32, 0u32, 0u32, 0u32);
    if cropping {
        cl = br.ue()? as u32;
        cr = br.ue()? as u32;
        ct = br.ue()? as u32;
        cb = br.ue()? as u32;
    }
    let mut pw = w_mbs * 16;
    let mut ph = h_maps * 16 * if frame_mbs_only { 1 } else { 2 };
    pw -= (cl + cr).min(pw) * 2;
    ph -= (ct + cb).min(ph / 2) * 2 * if frame_mbs_only { 1 } else { 2 };
    if pw > 0 && ph > 0 {
        Some((pw as u16, ph as u16))
    } else {
        None
    }
}

/* ───────────────────────── AAC：ADTS → raw ───────────────────────── */

struct AacFrame {
    freq_index: u8,
    chan_conf: u8,
    raw: Vec<u8>,
}

fn parse_adts(es: &[u8]) -> Vec<AacFrame> {
    let mut frames = Vec::new();
    let mut i = 0;
    while i + 7 <= es.len() {
        if es[i] != 0xff || (es[i + 1] & 0xf0) != 0xf0 {
            i += 1;
            continue;
        }
        let freq_index = (es[i + 2] >> 2) & 0x0f;
        let chan = ((es[i + 2] & 0x01) << 2) | ((es[i + 3] >> 6) & 0x03);
        let len = (((es[i + 3] as usize) & 0x03) << 11)
            | ((es[i + 4] as usize) << 3)
            | ((es[i + 5] as usize) >> 5);
        if len < 7 || i + len > es.len() {
            i += 1;
            continue;
        }
        let hdr = if es[i + 1] & 0x01 == 0 { 9 } else { 7 }; // CRC 位 = 0 时多 2 字节
        if len > hdr {
            frames.push(AacFrame {
                freq_index,
                chan_conf: chan,
                raw: es[i + hdr..i + len].to_vec(),
            });
        }
        i += len;
    }
    frames
}

/* ───────────────────────── 主入口 ───────────────────────── */

#[derive(Debug)]
pub struct MuxResult {
    pub video_samples: usize,
    pub audio_samples: usize,
    pub width: u16,
    pub height: u16,
}

struct VSamp {
    dts: u64,
    pts: u64,
    sync: bool,
    duration: u32,
    has_dts: bool,
    data: Vec<u8>,
}

/// 逐分片累积器：自动检测并重对齐时间戳回绕/跳变。
struct MuxAccum {
    demux: TsDemuxer,
    video: Vec<VSamp>,
    aac_es: Vec<u8>,
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
    last_dts: Option<u64>,
    pts_max: Option<i64>,
    offset: i64,
}

impl MuxAccum {
    fn new() -> Self {
        Self {
            demux: TsDemuxer::default(),
            video: Vec::new(),
            aac_es: Vec::new(),
            sps: None,
            pps: None,
            last_dts: None,
            pts_max: None,
            offset: 0,
        }
    }

    fn feed_segment(&mut self, seg: &[u8]) {
        let mut pes = Vec::new();
        self.demux.feed(seg, &mut pes);
        self.demux.flush(&mut pes);
        if std::env::var("HG_MUX_DEBUG").is_ok() {
            let first = pes.iter().find(|p| p.stream_type == 0x1b || p.stream_type == 0x24);
            let last = pes.iter().rev().find(|p| p.stream_type == 0x1b || p.stream_type == 0x24);
            let _ = (first, last);
            // 逐 PES 打印（仅调试指定分片范围时）
            for (i, p) in pes.iter().enumerate() {
                if p.stream_type != 0x1b && p.stream_type != 0x24 { continue; }
                eprintln!("[pes] {i} pts={} dts={} has_dts={}", p.pts, p.dts, p.has_dts);
            }
        }

        for p in pes {
            let st = p.stream_type;
            let old_dts = p.dts as i64 + self.offset;
            let mut dts = old_dts;
            let mut pts = p.pts as i64 + self.offset;
            if st == 0x1b || st == 0x24 {
                // 时间基重置检测：有 DTS 时按解码序单调性；仅 PTS 时按 max + 阈值（B 帧乱序幅度有限）
                if let Some(pmax) = self.pts_max {
                    let clock = if p.has_dts { dts } else { pts };
                    if clock < pmax.saturating_sub(30_010) {
                        let delta = pmax as i64 + 3001 - clock;
                        self.offset += delta;
                        dts += delta;
                        pts += delta;
                        if std::env::var("HG_MUX_DEBUG").is_ok() {
                            eprintln!("[rebase] delta=+{delta} (clock {clock} -> {}, has_dts={})", pmax + 3001, p.has_dts);
                        }
                    }
                }
            }
            self.pts_max = Some(self.pts_max.map_or(pts, |m: i64| m.max(pts)));
            let dts = dts.max(0) as u64;
            let pts = pts.max(0) as u64;
            match st {
                0x1b | 0x24 => {
                    let nals = split_annexb(&p.es);
                    let mut sample_nals: Vec<&Nal> = Vec::new();
                    let mut sync = false;
                    for n in &nals {
                        match n.typ {
                            7 => self.sps = Some(n.data.clone()),
                            8 => self.pps = Some(n.data.clone()),
                            9 => {} // AUD 丢弃
                            5 => {
                                sync = true;
                                sample_nals.push(n);
                            }
                            _ => sample_nals.push(n),
                        }
                    }
                    if !sample_nals.is_empty() {
                        let mut data = Vec::new();
                        for n in &sample_nals {
                            data.extend_from_slice(&(n.data.len() as u32).to_be_bytes());
                            data.extend_from_slice(&n.data);
                        }
                        self.last_dts = Some(dts);
                        self.video.push(VSamp { dts, pts, sync, duration: 0, has_dts: p.has_dts, data });
                    }
                }
                0x0f => self.aac_es.extend_from_slice(&p.es),
                _ => {}
            }
        }
    }

    fn finish<W: Write + Seek>(mut self, out: W) -> Result<MuxResult, String> {
        if self.video.is_empty() {
            return Err("TS 中未解析出视频帧".into());
        }
        let pts_only = self.video.iter().all(|s| !s.has_dts);
        if pts_only {
            // 无 DTS：解码序 = 到达序（不动）；pts 重编为显示序号 * 帧时长
            let n = self.video.len();
            let mut order: Vec<usize> = (0..n).collect();
            order.sort_by_key(|&i| self.video[i].pts);
            let mut diffs: Vec<u64> = order
                .windows(2)
                .map(|w| self.video[w[1]].pts.saturating_sub(self.video[w[0]].pts))
                .filter(|d| *d > 0)
                .collect();
            diffs.sort_unstable();
            let fd = diffs.get(diffs.len() / 2).copied().filter(|d| *d > 0).unwrap_or(3001);
            if std::env::var("HG_MUX_DEBUG").is_ok() {
                eprintln!("[pts-only] n={n} fd={fd}");
            }
            let mut rank = vec![0usize; n];
            for (r, &idx) in order.iter().enumerate() {
                rank[idx] = r;
            }
            for i in 0..n {
                self.video[i].pts = rank[i] as u64 * fd;
                self.video[i].dts = i as u64 * fd;
                self.video[i].duration = fd as u32;
            }
        } else {
            self.video.sort_by_key(|s| s.dts);
            // 强制 dts 严格单调（个别分片中途重置时间基会产生重复/回退的 dts）
            {
                let mut prev: Option<u64> = None;
                for s in self.video.iter_mut() {
                    if let Some(p) = prev {
                        if s.dts <= p {
                            s.dts = p + 1;
                        }
                    }
                    prev = Some(s.dts);
                }
            }
        }
        for i in 0..self.video.len() {
            if self.video[i].duration > 0 {
                continue; // pts-only 模式已赋值
            }
            self.video[i].duration = if i + 1 < self.video.len() {
                let d = self.video[i + 1].dts.saturating_sub(self.video[i].dts);
                if d == 0 || d > 90_000 {
                    3001 // 29.97fps 兜底（90k / 3001 ≈ 29.99）
                } else {
                    d as u32
                }
            } else if self.video.len() >= 2 {
                self.video[self.video.len() - 2].duration
            } else {
                3001
            };
        }

        let aac_frames = parse_adts(&self.aac_es);
        if aac_frames.is_empty() {
            return Err(format!(
                "TS 中未解析出音频帧（aac_es={}B, 已注册流={:?}, pmt_pid={:?}）",
                self.aac_es.len(),
                self.demux.streams.iter().map(|(k, (t, b))| (k, t, b.len())).collect::<Vec<_>>(),
                self.demux.pmt_pid
            ));
        }
        let freq_index = aac_frames[0].freq_index;
        let chan_conf = aac_frames[0].chan_conf;
        let sample_rate = freq_to_rate(freq_index).ok_or("不支持的 AAC 采样率")?;

        let (width, height) = self
            .sps
            .as_ref()
            .and_then(|s| sps_dimensions(s))
            .unwrap_or((640, 360));
        let sps = self.sps.ok_or("缺少 H264 SPS")?;
        let pps = self.pps.ok_or("缺少 H264 PPS")?;

        let config = Mp4Config {
            major_brand: FourCC::from(*b"isom"),
            minor_version: 512,
            compatible_brands: vec![
                FourCC::from(*b"isom"),
                FourCC::from(*b"iso2"),
                FourCC::from(*b"avc1"),
                FourCC::from(*b"mp41"),
            ],
            timescale: 1000,
        };
        let mut writer =
            Mp4Writer::write_start(out, &config).map_err(|e| format!("mp4 初始化失败: {e}"))?;
        writer
            .add_track(&TrackConfig {
                track_type: TrackType::Video,
                timescale: 90000,
                language: "und".into(),
                media_conf: MediaConfig::AvcConfig(AvcConfig {
                    width,
                    height,
                    seq_param_set: sps,
                    pic_param_set: pps,
                }),
            })
            .map_err(|e| format!("mp4 视频轨失败: {e}"))?;
        writer
            .add_track(&TrackConfig {
                track_type: TrackType::Audio,
                timescale: sample_rate,
                language: "und".into(),
                media_conf: MediaConfig::AacConfig(AacConfig {
                    bitrate: 0,
                    profile: AudioObjectType::AacLowComplexity,
                    freq_index: freq_from_index(freq_index)?,
                    chan_conf: chan_from_index(chan_conf)?,
                }),
            })
            .map_err(|e| format!("mp4 音频轨失败: {e}"))?;

        for s in &self.video {
            writer
                .write_sample(
                    1,
                    &Mp4Sample {
                        start_time: s.dts,
                        duration: s.duration,
                        rendering_offset: (s.pts as i64 - s.dts as i64) as i32,
                        is_sync: s.sync,
                        bytes: Bytes::from(s.data.clone()),
                    },
                )
                .map_err(|e| format!("mp4 视频帧写入失败: {e}"))?;
        }
        for (i, f) in aac_frames.iter().enumerate() {
            writer
                .write_sample(
                    2,
                    &Mp4Sample {
                        start_time: (i as u64) * 1024,
                        duration: 1024,
                        rendering_offset: 0,
                        is_sync: true,
                        bytes: Bytes::from(f.raw.clone()),
                    },
                )
                .map_err(|e| format!("mp4 音频帧写入失败: {e}"))?;
        }
        writer.write_end().map_err(|e| format!("mp4 收尾失败: {e}"))?;

        Ok(MuxResult {
            video_samples: self.video.len(),
            audio_samples: aac_frames.len(),
            width,
            height,
        })
    }
}

/// 拼接后的（已解密）TS → MP4。失败返回 Err。
pub fn ts_to_mp4<W: Write + Seek>(ts: &[u8], out: W) -> Result<MuxResult, String> {
    let mut acc = MuxAccum::new();
    acc.feed_segment(ts);
    acc.finish(out)
}

/// 按分片喂入 → MP4。逐分片检测时间戳回绕并重对齐（站点流中途会重置时间基）。
pub fn ts_segments_to_mp4<W: Write + Seek>(segments: &[Vec<u8>], out: W) -> Result<MuxResult, String> {
    let mut acc = MuxAccum::new();
    for seg in segments {
        acc.feed_segment(seg);
    }
    acc.finish(out)
}

fn freq_to_rate(idx: u8) -> Option<u32> {
    Some(match idx {
        0 => 96000,
        1 => 88200,
        2 => 64000,
        3 => 48000,
        4 => 44100,
        5 => 32000,
        6 => 24000,
        7 => 22050,
        8 => 16000,
        9 => 12000,
        10 => 11025,
        11 => 8000,
        12 => 7350,
        _ => return None,
    })
}

fn freq_from_index(idx: u8) -> Result<SampleFreqIndex, String> {
    use SampleFreqIndex::*;
    Ok(match idx {
        0 => Freq96000,
        1 => Freq88200,
        2 => Freq64000,
        3 => Freq48000,
        4 => Freq44100,
        5 => Freq32000,
        6 => Freq24000,
        7 => Freq22050,
        8 => Freq16000,
        9 => Freq12000,
        10 => Freq11025,
        11 => Freq8000,
        12 => Freq7350,
        _ => return Err("采样率索引无效".into()),
    })
}

fn chan_from_index(idx: u8) -> Result<ChannelConfig, String> {
    use ChannelConfig::*;
    Ok(match idx {
        1 => Mono,
        2 => Stereo,
        3 => Three,
        4 => Four,
        5 => Five,
        6 => FiveOne,
        7 => SevenOne,
        _ => return Err("声道配置无效".into()),
    })
}

/* ───────────────────────── 测试：ffmpeg 造流 → 封装 → ffprobe 验证 ───────────────────────── */

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn test_ffmpeg_ts_to_mp4() {
        // 需要 ffmpeg/ffprobe（本机 PATH 有）
        let dir = std::env::temp_dir().join("hg_mux_test");
        let _ = std::fs::create_dir_all(&dir);
        let ts_path = dir.join("test.ts");
        let mp4_path = dir.join("out.mp4");

        // 生成 2 秒 320x240 15fps H264+AAC 的 TS（含 B 帧关掉：baseline）
        let gen = Command::new("ffmpeg")
            .args([
                "-y", "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x240:rate=15",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                "-c:v", "libx264", "-profile:v", "baseline", "-pix_fmt", "yuv420p",
                "-g", "15", "-c:a", "aac", "-ar", "44100", "-ac", "2",
                "-f", "mpegts", ts_path.to_str().unwrap(),
            ])
            .output()
            .expect("ffmpeg 生成失败");
        assert!(gen.status.success(), "ffmpeg stderr: {}", String::from_utf8_lossy(&gen.stderr));
        let ts = std::fs::read(&ts_path).unwrap();
        assert!(ts.len() > 10_000);

        let f = std::fs::File::create(&mp4_path).unwrap();
        let result = ts_to_mp4(&ts, f).expect("封装失败");
        println!("mux result: {result:?}");

        // ffprobe 验证
        let probe = Command::new("ffprobe")
            .args([
                "-v", "error", "-show_format", "-show_streams",
                mp4_path.to_str().unwrap(),
            ])
            .output()
            .expect("ffprobe 失败");
        let out = String::from_utf8_lossy(&probe.stdout);
        assert!(probe.status.success(), "ffprobe stderr: {}", String::from_utf8_lossy(&probe.stderr));
        assert!(out.contains("codec_name=h264"), "缺少 h264: {out}");
        assert!(out.contains("codec_name=aac"), "缺少 aac: {out}");
        assert!(out.contains("width=320"), "分辨率异常: {out}");
        // 时长 ≈ 2s
        let dur: f64 = out
            .lines()
            .find(|l| l.starts_with("duration="))
            .and_then(|l| l.split('=').nth(1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(0.0);
        assert!(dur > 1.5 && dur < 2.6, "时长异常: {dur}");
        println!("ffprobe duration: {dur}s");
    }
}
