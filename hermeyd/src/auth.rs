//! Credentials for paired devices: short-lived access tokens, 30-second single-use WS tickets,
//! a per-client limiter so pairing claims cannot be brute-forced, and refresh-token hashing.
//!
//! Refresh tokens are stored salted + hashed (never in the clear), and compared in constant time.

use crate::pairing::now;
use rand::Rng;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::Mutex;

pub struct Tickets {
    /// ticket -> (device_id, expires_at)
    tickets: Mutex<HashMap<String, (String, f64)>>,
    /// access token -> (device_id, expires_at)
    access: Mutex<HashMap<String, (String, f64)>>,
    ticket_ttl: f64,
    access_ttl: f64,
}

impl Tickets {
    pub fn new(ticket_ttl_secs: f64, access_ttl_secs: f64) -> Self {
        Self {
            tickets: Mutex::new(HashMap::new()),
            access: Mutex::new(HashMap::new()),
            ticket_ttl: ticket_ttl_secs,
            access_ttl: access_ttl_secs,
        }
    }

    pub fn mint_ticket(&self, device_id: &str) -> String {
        let token = random_token(32);
        let mut t = self.tickets.lock().unwrap();
        let expiry = now() + self.ticket_ttl;
        let ts = now();
        t.retain(|_, (_, exp)| *exp > ts);
        t.insert(token.clone(), (device_id.to_string(), expiry));
        token
    }

    /// Consume a ticket. Single use is the whole point: a second redemption fails.
    #[allow(dead_code)] // used by the WS relay, which is the next slice
    pub fn consume_ticket(&self, ticket: &str) -> Option<String> {
        let mut t = self.tickets.lock().unwrap();
        let ts = now();
        t.retain(|_, (_, exp)| *exp > ts);
        match t.remove(ticket) {
            Some((device, exp)) if exp > ts => Some(device),
            _ => None,
        }
    }

    pub fn mint_access(&self, device_id: &str) -> String {
        let token = random_token(32);
        let mut a = self.access.lock().unwrap();
        let expiry = now() + self.access_ttl;
        let ts = now();
        a.retain(|_, (_, exp)| *exp > ts);
        a.insert(token.clone(), (device_id.to_string(), expiry));
        token
    }

    pub fn verify_access(&self, token: &str) -> Option<String> {
        let mut a = self.access.lock().unwrap();
        let ts = now();
        a.retain(|_, (_, exp)| *exp > ts);
        a.get(token).filter(|(_, exp)| *exp > ts).map(|(d, _)| d.clone())
    }

    pub fn access_ttl(&self) -> u64 {
        self.access_ttl as u64
    }

    #[allow(dead_code)] // reported by the WS relay handshake
    pub fn ticket_ttl(&self) -> u64 {
        self.ticket_ttl as u64
    }
}

/// Request log. Every path the app asks for is a compatibility fact: a 404 here is a screen that will
/// never finish loading, and the client then sits on "connecting" until its socket times out.
pub async fn log_requests(
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let started = std::time::Instant::now();
    let resp = next.run(req).await;
    let status = resp.status().as_u16();
    if path != "/v1/health" {
        eprintln!("http {method} {path} -> {status} ({} ms)", started.elapsed().as_millis());
    }
    resp
}

/// Fixed-window limiter keyed by client address: `max` attempts per `window` seconds.
pub struct RateLimiter {
    hits: Mutex<HashMap<String, (u32, f64)>>,
    max: u32,
    window: f64,
}

impl RateLimiter {
    pub fn new(max: u32, window_secs: f64) -> Self {
        Self { hits: Mutex::new(HashMap::new()), max, window: window_secs }
    }

    /// Ok(()) when allowed, Err(retry_after_secs) when refused.
    pub fn check(&self, key: &str) -> Result<(), u64> {
        let mut h = self.hits.lock().unwrap();
        let ts = now();
        let entry = h.entry(key.to_string()).or_insert((0, ts + self.window));
        if ts >= entry.1 {
            *entry = (0, ts + self.window);
        }
        if entry.0 >= self.max {
            return Err(((entry.1 - ts).max(1.0)) as u64);
        }
        entry.0 += 1;
        Ok(())
    }
}

pub fn random_token(bytes: usize) -> String {
    use base64::Engine as _;
    let mut buf = vec![0u8; bytes];
    rand::thread_rng().fill(&mut buf[..]);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf)
}

/// Hex SHA-256 of arbitrary bytes — used to prove an upload arrived intact.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// Salted SHA-256 of a refresh token. The token carries 256 bits of entropy, so a fast hash with a
/// per-host salt is the right primitive here (this is a bearer secret, not a human password).
pub fn hash_refresh(salt: &str, token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(token.as_bytes());
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

pub fn load_or_create_salt(path: &std::path::Path) -> std::io::Result<String> {
    if let Ok(existing) = std::fs::read_to_string(path) {
        let trimmed = existing.trim().to_string();
        if trimmed.len() >= 32 {
            return Ok(trimmed);
        }
    }
    let salt = random_token(24);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, &salt)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(salt)
}
