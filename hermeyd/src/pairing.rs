//! Pairing codes: short numeric, single-use, expiring. Minted by the host (loopback) or by an
//! already-paired device; redeemed exactly once by a claiming client.

use rand::Rng;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub struct Pairing {
    codes: Mutex<HashMap<String, f64>>,
    ttl: f64,
}

impl Pairing {
    pub fn new(ttl_secs: f64) -> Self {
        Self { codes: Mutex::new(HashMap::new()), ttl: ttl_secs }
    }

    /// Mint a 6-digit code. Codes are unique among the live set, so a displayed code is unambiguous.
    pub fn mint(&self) -> (String, f64) {
        let mut rng = rand::thread_rng();
        let mut codes = self.codes.lock().unwrap();
        let expires_at = now() + self.ttl;
        loop {
            let code: String = (0..6).map(|_| char::from(b'0' + rng.gen_range(0..10))).collect();
            if !codes.contains_key(&code) {
                codes.insert(code.clone(), expires_at);
                return (code, expires_at);
            }
        }
    }

    /// Redeem once. A wrong, expired or already-used code is indistinguishable to the caller.
    pub fn redeem(&self, code: &str) -> bool {
        let mut codes = self.codes.lock().unwrap();
        let t = now();
        codes.retain(|_, exp| *exp > t);
        match codes.remove(code) {
            Some(exp) if exp > t => true,
            _ => false,
        }
    }
}
