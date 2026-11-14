//! 会话持久化：token + 用户资料存到应用数据目录。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Session {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub user: serde_json::Value,
    /// 访客设备身份（32 位十六进制），对应官方 visitor_id。
    #[serde(default)]
    pub visitor: String,
    /// 出网代理地址（http:// 或 socks5://，空为直连）。
    #[serde(default)]
    pub proxy: String,
}

pub struct SessionStore {
    pub file: Mutex<Option<PathBuf>>,
    pub current: Mutex<Session>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self {
            file: Mutex::new(None),
            current: Mutex::new(Session::default()),
        }
    }

    pub fn bind(&self, dir: PathBuf) {
        let mut path = dir;
        path.push("session.json");
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Ok(sess) = serde_json::from_str::<Session>(&text) {
                *self.current.lock().unwrap() = sess;
            }
        }
        *self.file.lock().unwrap() = Some(path);
    }

    pub fn token(&self) -> Option<String> {
        let t = self.current.lock().unwrap().token.clone();
        if t.is_empty() {
            None
        } else {
            Some(t)
        }
    }

    pub fn user(&self) -> serde_json::Value {
        self.current.lock().unwrap().user.clone()
    }

    /// 访客身份：首次生成 32 位十六进制并持久化，后续复用。
    pub fn visitor(&self) -> String {
        {
            let cur = self.current.lock().unwrap();
            if !cur.visitor.is_empty() {
                return cur.visitor.clone();
            }
        }
        use ring::rand::{SecureRandom, SystemRandom};
        let mut bytes = [0u8; 16];
        let _ = SystemRandom::new().fill(&mut bytes);
        let v: String = bytes.iter().map(|x| format!("{x:02x}")).collect();
        let out = {
            let mut cur = self.current.lock().unwrap();
            if cur.visitor.is_empty() {
                cur.visitor = v.clone();
            }
            cur.visitor.clone()
        };
        self.persist();
        out
    }

    pub fn set(&self, token: String, user: serde_json::Value) {
        {
            let mut cur = self.current.lock().unwrap();
            cur.token = token;
            cur.user = user;
        }
        self.persist();
    }

    pub fn clear(&self) {
        {
            let mut cur = self.current.lock().unwrap();
            cur.token.clear();
            cur.user = serde_json::Value::Null;
        }
        self.persist();
    }

    fn persist(&self) {
        let snapshot = self.current.lock().unwrap().clone();
        if let Some(path) = self.file.lock().unwrap().as_ref() {
            if let Ok(text) = serde_json::to_string_pretty(&snapshot) {
                let _ = std::fs::write(path, text);
            }
        }
    }
}

impl SessionStore {
    /// 仅更新用户资料（token 不变）。
    pub fn set_user(&self, user: serde_json::Value) {
        {
            let mut cur = self.current.lock().unwrap();
            cur.user = user;
        }
        self.persist();
    }
}

impl SessionStore {
    pub fn proxy(&self) -> String {
        self.current.lock().unwrap().proxy.clone()
    }

    pub fn set_proxy(&self, addr: String) {
        {
            let mut cur = self.current.lock().unwrap();
            cur.proxy = addr;
        }
        self.persist();
    }
}
