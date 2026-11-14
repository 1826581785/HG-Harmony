//! dx150-edge-v1：上游站点新版加密信封协议。
//!
//! 握手：POST {v:1,type:'hello',client_pub} → 服务端回 kid/sid/site/server_pub/salt
//! 派生：ECDH P-256 → HKDF-SHA256(salt, info+'\n'+direction) → AES-256-GCM 双向密钥
//! 调用：POST {v:1,type:'call',kid,sid,seq,ts,ciphertext}，密文内层 {request, authorization}
//! 响应：{v:1,type:'result',...ciphertext} → 内层 {status, headers, body}

use base64::engine::general_purpose::STANDARD as B64_STD;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64URL;
use base64::Engine;
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::agreement::{self, UnparsedPublicKey, ECDH_P256};
use ring::hkdf::{Salt, HKDF_SHA256};
use ring::rand::SystemRandom;
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

pub const PROTOCOL: &str = "dx150-edge-v1";
pub const MAX_SEQUENCE: u32 = 16384;

pub fn endpoint(scope: &str) -> &'static str {
    match scope {
        "user" => "/api/user/request",
        "playback" => "/api/playback/request",
        "dynamic" => "/api/dynamic/request",
        _ => "/api/public/request",
    }
}

pub fn is_public(scope: &str) -> bool {
    scope == "public"
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub struct Session {
    pub scope: String,
    info: String,
    kid: String,
    sid: String,
    clock_offset: i64,
    expires_at: i64,
    sequence: u32,
    req_key: [u8; 32],
    res_key: [u8; 32],
}

fn seal(key: &[u8; 32], iv: &[u8; 12], aad: &[u8], plain: &[u8]) -> Result<Vec<u8>, String> {
    let unbound = UnboundKey::new(&AES_256_GCM, key).map_err(|e| e.to_string())?;
    let mut buf = plain.to_vec();
    LessSafeKey::new(unbound)
        .seal_in_place_append_tag(Nonce::assume_unique_for_key(*iv), Aad::from(aad), &mut buf)
        .map_err(|e| e.to_string())?;
    Ok(buf)
}

fn open(key: &[u8; 32], iv: &[u8; 12], aad: &[u8], mut ct: Vec<u8>) -> Result<Vec<u8>, String> {
    let unbound = UnboundKey::new(&AES_256_GCM, key).map_err(|e| e.to_string())?;
    let plain = LessSafeKey::new(unbound)
        .open_in_place(Nonce::assume_unique_for_key(*iv), Aad::from(aad), &mut ct)
        .map_err(|_| "解密失败（密钥/序号/时间不匹配）".to_string())?;
    Ok(plain.to_vec())
}

fn as_str<'a>(v: &'a Value, k: &str) -> Result<&'a str, String> {
    v.get(k)
        .and_then(|x| x.as_str())
        .ok_or_else(|| format!("握手响应缺 {k}"))
}

impl Session {
    /// ECDH 握手建立会话。
    pub async fn open(scope: &str) -> Result<Self, String> {
        let rng = SystemRandom::new();
        let my = agreement::EphemeralPrivateKey::generate(&ECDH_P256, &rng)
            .map_err(|e| e.to_string())?;
        let my_pub = my.compute_public_key().map_err(|e| e.to_string())?;

        let (status, hello) = crate::net::post_json(
            &format!("{}{}", crate::net::BASE, endpoint(scope)),
            &json!({ "v": 1, "type": "hello", "client_pub": B64URL.encode(my_pub.as_ref()) }),
        )
        .await?;
        if status != 200 {
            return Err(format!("加密握手失败 ({status})"));
        }

        if hello.get("v").and_then(|v| v.as_i64()) != Some(1)
            || hello.get("type").and_then(|v| v.as_str()) != Some("hello")
        {
            return Err("握手响应类型无效".into());
        }
        let kid = as_str(&hello, "kid")?.to_string();
        let sid = as_str(&hello, "sid")?.to_string();
        let site = as_str(&hello, "site")?.to_string();
        let server_time = hello
            .get("server_time")
            .and_then(|v| v.as_i64())
            .ok_or("握手响应缺 server_time")?;
        let expires_in = hello
            .get("expires_at")
            .and_then(|v| v.as_i64())
            .ok_or("握手响应缺 expires_at")?
            - server_time;
        let server_pub = B64URL.decode(as_str(&hello, "server_pub")?)
            .map_err(|_| "server_pub 编码无效")?;
        let salt = B64URL.decode(as_str(&hello, "salt")?).map_err(|_| "salt 编码无效")?;
        if salt.len() != 32 {
            return Err("salt 长度无效".into());
        }

        let peer = UnparsedPublicKey::new(&ECDH_P256, server_pub);
        let shared = agreement::agree_ephemeral(my, &peer, |x| x.to_vec())
            .map_err(|e| e.to_string())?;

        let prk = Salt::new(HKDF_SHA256, &salt).extract(&shared);
        let info = [PROTOCOL, scope, &site, &kid, &sid].join("\n");
        let req_info = format!("{info}\nreq");
        let res_info = format!("{info}\nres");
        let mut req_key = [0u8; 32];
        let req_infos = [req_info.as_bytes()];
        let okm = prk
            .expand(&req_infos, HKDF_SHA256)
            .map_err(|e| e.to_string())?;
        okm.fill(&mut req_key).map_err(|e| e.to_string())?;
        let mut res_key = [0u8; 32];
        let res_infos = [res_info.as_bytes()];
        let okm = prk
            .expand(&res_infos, HKDF_SHA256)
            .map_err(|e| e.to_string())?;
        okm.fill(&mut res_key).map_err(|e| e.to_string())?;

        let t = now();
        Ok(Self {
            scope: scope.to_string(),
            info,
            kid,
            sid,
            clock_offset: server_time - t,
            expires_at: t + expires_in,
            sequence: 0,
            req_key,
            res_key,
        })
    }

    fn aad(&self, direction: &str, seq: u32, ts: i64) -> String {
        [self.info.as_str(), direction, &seq.to_string(), &ts.to_string()].join("\n")
    }

    fn nonce(seq: u32) -> [u8; 12] {
        let mut iv = [0u8; 12];
        iv[8..12].copy_from_slice(&seq.to_be_bytes());
        iv
    }

    fn stale(&self) -> bool {
        self.expires_at <= now() + 5 || self.sequence >= MAX_SEQUENCE
    }

    /// 发起一次加密调用。request 为内层业务请求对象，返回 (HTTP status, body)。
    pub async fn call(
        &mut self,
        request: Value,
        token: Option<&str>,
    ) -> Result<(u16, Vec<u8>), String> {
        if self.stale() {
            *self = Self::open(&self.scope).await?;
        }
        self.sequence += 1;
        let seq = self.sequence;
        let ts = now() + self.clock_offset;
        let iv = Self::nonce(seq);

        let mut packet = json!({ "request": request });
        if let Some(t) = token {
            if !t.is_empty() && !is_public(&self.scope) {
                packet["authorization"] = json!(format!("Bearer {t}"));
            }
        }
        let plain = serde_json::to_string(&packet).map_err(|e| e.to_string())?;
        let ct = seal(&self.req_key, &iv, self.aad("req", seq, ts).as_bytes(), plain.as_bytes())?;

        let body = json!({
            "v": 1, "type": "call",
            "kid": self.kid, "sid": self.sid,
            "seq": seq, "ts": ts,
            "ciphertext": B64URL.encode(ct),
        });
        let (outer_status, resp) = crate::net::post_json(
            &format!("{}{}", crate::net::BASE, endpoint(&self.scope)),
            &body,
        )
        .await?;
        if outer_status != 200 {
            if resp.get("error").and_then(|v| v.as_str()) == Some("session_expired") {
                return Err("SESSION_EXPIRED".into());
            }
            return Err(format!("加密接口请求失败 ({outer_status})"));
        }

        if resp.get("v").and_then(|v| v.as_i64()) != Some(1)
            || resp.get("type").and_then(|v| v.as_str()) != Some("result")
            || resp.get("sid").and_then(|v| v.as_str()) != Some(self.sid.as_str())
            || resp.get("kid").and_then(|v| v.as_str()) != Some(self.kid.as_str())
            || resp.get("seq").and_then(|v| v.as_i64()) != Some(seq as i64)
            || resp.get("ts").and_then(|v| v.as_i64()) != Some(ts)
        {
            return Err("加密接口响应不匹配".into());
        }
        let ct2 = B64URL.decode(as_str(&resp, "ciphertext")?)
            .map_err(|_| "响应密文编码无效")?;
        let plain2 = open(&self.res_key, &iv, self.aad("res", seq, ts).as_bytes(), ct2)?;
        let inner: Value =
            serde_json::from_slice(&plain2).map_err(|_| "加密接口响应格式无效".to_string())?;
        let status = inner
            .get("status")
            .and_then(|v| v.as_u64())
            .ok_or("加密接口响应缺 status")? as u16;
        let body = inner
            .get("body")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let bytes = if body.is_empty() {
            Vec::new()
        } else {
            B64_STD.decode(body).map_err(|_| "响应 body 编码无效")?
        };
        Ok((status, bytes))
    }
}
