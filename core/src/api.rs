//! 业务命令：登录 / 列表 / 详情 / 播放 / 互动。
//! 从旧工程 src-tauri/src/api.rs 平移：去掉 tauri State，改为普通 struct + 全局单例。

use crate::net::{edge, BASE};
use crate::session::SessionStore;
use serde_json::{json, Value};

pub struct Api {
    pub session: SessionStore,
}

impl Api {
    pub fn new() -> Self {
        Self {
            session: SessionStore::new(),
        }
    }

    pub fn bind(&self, dir: &std::path::Path) {
        let _ = std::fs::create_dir_all(dir);
        self.session.bind(dir.to_path_buf());
    }

    fn token(&self) -> Option<String> {
        self.session.token()
    }

    async fn get(&self, path: &str) -> Result<Value, String> {
        let token = self.token();
        let visitor = self.session.visitor();
        edge("GET", path, None, token.as_deref(), Some(&visitor)).await
    }

    async fn post(&self, path: &str, body: Value) -> Result<Value, String> {
        let token = self.token();
        let visitor = self.session.visitor();
        edge("POST", path, Some(body), token.as_deref(), Some(&visitor)).await
    }

    async fn authed(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        let token = self
            .token()
            .ok_or_else(|| "请先登录".to_string())?;
        let visitor = self.session.visitor();
        edge(method, path, body, Some(&token), Some(&visitor)).await
    }

    /* ───────────────────────── 会话 ───────────────────────── */

    pub async fn boot(&self) -> Result<Value, String> {
        Ok(json!({
            "user": self.session.user(),
            "logged_in": self.session.token().is_some(),
            "base": BASE,
        }))
    }

    pub async fn login(&self, username: &str, password: &str) -> Result<Value, String> {
        let visitor = self.session.visitor();
        let data = edge(
            "POST",
            "/api/account/loginByPassword",
            Some(json!({ "username": username, "password": password })),
            None,
            Some(&visitor),
        )
        .await?;
        let token = data
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "登录返回缺少 token".to_string())?
            .to_string();
        let user = data.get("user").cloned().unwrap_or(Value::Null);
        self.session.set(token, user.clone());
        Ok(json!({ "user": user }))
    }

    pub async fn register(&self, username: &str, password: &str, email: &str) -> Result<Value, String> {
        let mut body = json!({
            "username": username,
            "password": password,
            "confirm_password": password,
        });
        if !email.trim().is_empty() {
            body["email"] = json!(email);
        }
        let visitor = self.session.visitor();
        let data = edge(
            "POST",
            "/api/account/registerByPassword",
            Some(body),
            None,
            Some(&visitor),
        )
        .await?;
        let token = data
            .get("token")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "注册返回缺少 token".to_string())?
            .to_string();
        let user = data.get("user").cloned().unwrap_or(Value::Null);
        self.session.set(token, user.clone());
        Ok(json!({ "user": user }))
    }

    pub async fn logout(&self) -> Result<Value, String> {
        let token = self.token();
        let visitor = self.session.visitor();
        let _ = edge("POST", "/api/account/logout", None, token.as_deref(), Some(&visitor)).await;
        self.session.clear();
        Ok(json!({ "ok": true }))
    }

    pub async fn me(&self) -> Result<Value, String> {
        let me = self.get("/api/account/me").await?;
        if self.session.token().is_some() {
            let user = me.clone();
            self.session.set_user(user);
        }
        Ok(me)
    }

    /* ───────────────────────── 列表 ───────────────────────── */

    pub async fn feed(&self, page: u32, size: u32) -> Result<Value, String> {
        self.get(&format!("/api/videos?page={page}&size={size}")).await
    }

    pub async fn category(&self, cate: &str, page: u32, size: u32) -> Result<Value, String> {
        self.get(&format!("/api/videos/category/{cate}?page={page}&size={size}")).await
    }

    pub async fn rank(&self, kind: &str) -> Result<Value, String> {
        let kind = match kind {
            "recommend" | "potential" => kind,
            _ => "hot",
        };
        self.get(&format!("/api/ranks/{kind}")).await
    }

    pub async fn search(&self, q: &str, page: u32, size: u32) -> Result<Value, String> {
        let encoded: String = url::form_urlencoded::byte_serialize(q.as_bytes()).collect();
        self.get(&format!("/api/search?q={encoded}&page={page}&size={size}")).await
    }

    pub async fn posts(&self, page: u32, size: u32) -> Result<Value, String> {
        self.get(&format!("/api/posts?page={page}&size={size}")).await
    }

    pub async fn post_detail(&self, id: i64) -> Result<Value, String> {
        self.get(&format!("/api/posts/{id}")).await
    }

    /* ───────────────────────── 详情 / 播放 ───────────────────────── */

    pub async fn video(&self, id: i64) -> Result<Value, String> {
        self.get(&format!("/api/videos/{id}")).await
    }

    pub async fn play(&self, id: i64, ep: u32) -> Result<Value, String> {
        // 官方新版取址：POST /api/videos/{id}/episodes/{ep}/playback（playback 域加密通道）
        let raw = self
            .post(&format!("/api/videos/{id}/episodes/{ep}/playback"), json!({}))
            .await?;
        // 兼容旧前端字段：streams.main / streams.preview → video_url
        let mut out = raw;
        let url = out
            .get("streams")
            .and_then(|s| s.get("main"))
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .or_else(|| {
                out.get("streams")
                    .and_then(|s| s.get("preview"))
                    .and_then(|v| v.as_str())
            })
            .unwrap_or("")
            .to_string();
        out["video_url"] = json!(url);
        Ok(out)
    }

    /* ───────────────────────── 评论 / 互动 ───────────────────────── */

    pub async fn comments(&self, id: i64, ep: u32, page: u32, size: u32) -> Result<Value, String> {
        self.get(&format!(
            "/api/videos/{id}/comments?ep={ep}&page={page}&size={size}"
        )).await
    }

    pub async fn comment_send(&self, id: i64, ep: u32, text: &str, reply_id: Option<i64>) -> Result<Value, String> {
        let mut body = json!({ "text": text });
        let path = match reply_id {
            Some(rid) if rid > 0 => {
                body["reply_id"] = json!(rid);
                format!("/api/videos/{id}/comments")
            }
            _ => format!("/api/videos/{id}/comments?ep={ep}"),
        };
        self.authed("POST", &path, Some(body)).await
    }

    pub async fn like(&self, id: i64, ep: u32, on: bool) -> Result<Value, String> {
        let method = if on { "POST" } else { "DELETE" };
        self.authed(method, &format!("/api/videos/{id}/like?ep={ep}"), None).await
    }

    pub async fn collect(&self, id: i64, on: bool) -> Result<Value, String> {
        let method = if on { "POST" } else { "DELETE" };
        self.authed(method, &format!("/api/videos/{id}/collect"), None).await
    }

    pub async fn follow(&self, uid: i64, on: bool) -> Result<Value, String> {
        let method = if on { "POST" } else { "DELETE" };
        self.authed(method, &format!("/api/users/{uid}/follow"), None).await
    }

    /* ───────────────────────── 图文帖互动 ───────────────────────── */

    pub async fn post_like(&self, id: i64, on: bool) -> Result<Value, String> {
        let method = if on { "POST" } else { "DELETE" };
        self.authed(method, &format!("/api/posts/{id}/like"), None).await
    }

    pub async fn post_collect(&self, id: i64, on: bool) -> Result<Value, String> {
        let method = if on { "POST" } else { "DELETE" };
        self.authed(method, &format!("/api/posts/{id}/collect"), None).await
    }

    pub async fn post_comments(&self, id: i64, page: u32, size: u32) -> Result<Value, String> {
        self.get(&format!("/api/posts/{id}/comments?page={page}&size={size}")).await
    }
}
