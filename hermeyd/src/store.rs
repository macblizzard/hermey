//! Device registry + durable state. SQLite (WAL) under `$HERMEY_HOME/bridge.db`.
//!
//! Deliberately the *only* durable state this service owns: devices and their refresh tokens.
//! Bots, sessions and transcripts belong to the engine, so an engine swap cannot touch pairing.

use crate::pairing::now;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::path::Path;
use std::sync::Mutex;

#[derive(Clone, Debug, Serialize)]
pub struct Device {
    pub device_id: String,
    pub name: String,
    pub platform: String,
    pub created_at: f64,
    pub last_seen_at: Option<f64>,
    pub revoked: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Attachment {
    pub attachment_id: String,
    pub device_id: String,
    pub name: String,
    pub size: i64,
    pub sha256: String,
    pub created_at: f64,
}

pub struct Store {
    conn: Mutex<Connection>,
}

/// One card's JSON, capped at the card contract's own ceiling (32 KB).
const CARD_SNAPSHOT_MAX_BYTES: u64 = 32 * 1024;

/// Six months. Long enough that "reopen the thread next week" is never a 404, short enough that
/// the table is bounded by recent conversation rather than by all of it.
const CARD_SNAPSHOT_RETENTION_SECONDS: f64 = 180.0 * 86_400.0;

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA foreign_keys=ON;
             CREATE TABLE IF NOT EXISTS devices (
                 device_id   TEXT PRIMARY KEY,
                 name        TEXT NOT NULL,
                 platform    TEXT NOT NULL,
                 public_key  TEXT NOT NULL,
                 refresh_hash TEXT NOT NULL,
                 created_at  REAL NOT NULL,
                 last_seen_at REAL,
                 revoked     INTEGER NOT NULL DEFAULT 0
             );
             CREATE INDEX IF NOT EXISTS idx_devices_revoked ON devices(revoked);
             CREATE TABLE IF NOT EXISTS attachments (
                 attachment_id TEXT PRIMARY KEY,
                 device_id     TEXT NOT NULL,
                 name          TEXT NOT NULL,
                 size          INTEGER NOT NULL,
                 sha256        TEXT NOT NULL,
                 created_at    REAL NOT NULL
             );
             CREATE INDEX IF NOT EXISTS idx_attachments_device ON attachments(device_id);
             CREATE TABLE IF NOT EXISTS documents (
                 key        TEXT PRIMARY KEY,
                 json       TEXT NOT NULL,
                 updated_at REAL NOT NULL
             );
             -- The shared session pointer, one row per bot profile. A pointer, not a transcript:
             -- two paired devices read it to agree on which conversation is open for a bot.
             CREATE TABLE IF NOT EXISTS bot_sessions (
                 profile           TEXT PRIMARY KEY,
                 stored_session_id TEXT NOT NULL,
                 updated_at        REAL NOT NULL
             );
             -- The desktop pet's OWN conversation, one row per bot profile. Separate from
             -- `bot_sessions` on purpose: a balloon question is answered in a small bounded
             -- session, while the pointer above is the endless transcript the app opens.
             CREATE TABLE IF NOT EXISTS pet_sessions (
                 profile           TEXT PRIMARY KEY,
                 stored_session_id TEXT NOT NULL,
                 updated_at        REAL NOT NULL
             );
             -- Bark relay targets, one row per device: where this device's banners go. The key is a
             -- credential (`http://host:port/<KEY>`), so the database file itself is 0600 — see
             -- `restrict_db_permissions` — and nothing here is ever logged or echoed.
             CREATE TABLE IF NOT EXISTS push_targets (
                 device_id    TEXT PRIMARY KEY,
                 provider     TEXT NOT NULL,
                 endpoint     TEXT NOT NULL,
                 key          TEXT NOT NULL,
                 preset_bot   TEXT,
                 updated_at   REAL NOT NULL
             );
             -- The newest bot message already announced, per profile. One row is the whole guard: it
             -- deduplicates a restart and throttles a chatty bot to one banner per interval.
             CREATE TABLE IF NOT EXISTS push_watch (
                 profile      TEXT PRIMARY KEY,
                 last_at      REAL NOT NULL
             );
             -- Who last put a prompt into a bot: `human` means the reply is the answer to something
             -- the owner just asked, which is not news worth a banner.
             CREATE TABLE IF NOT EXISTS push_prompts (
                 profile      TEXT PRIMARY KEY,
                 at           REAL NOT NULL,
                 source       TEXT NOT NULL
             );
             -- Per-message snapshots of an agent card (`/v1/cards/{id}`). The file the marker names
             -- lives in the bot's working directory and can be cleaned up or rewritten by a later
             -- turn, so the first successful read is kept here and a reopened thread draws it.
             -- Message-addressed on purpose: two messages naming the same file never collide, and a
             -- later rewrite cannot change what an earlier message showed. `json` is capped at the
             -- card contract's 32 KB by the writer.
             CREATE TABLE IF NOT EXISTS card_snapshots (
                 session_id TEXT NOT NULL,
                 message_id TEXT NOT NULL,
                 card_id    TEXT NOT NULL,
                 json       TEXT NOT NULL,
                 mtime      TEXT NOT NULL,
                 updated_at REAL NOT NULL,
                 PRIMARY KEY (session_id, message_id, card_id)
             );
             CREATE INDEX IF NOT EXISTS idx_card_snapshots_updated
                 ON card_snapshots(updated_at);",
        )?;
        restrict_db_permissions(path);
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// Whether a device may still act (exists and was not revoked). Card sessions check this on
    /// every read, so revoking a device ends its boards immediately rather than in two minutes.
    pub fn device_active(&self, device_id: &str) -> bool {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT revoked FROM devices WHERE device_id = ?1",
            params![device_id],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .ok()
        .flatten()
        .map(|revoked| revoked == 0)
        .unwrap_or(false)
    }

    pub fn count_active(&self) -> i64 {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM devices WHERE revoked = 0", [], |r| r.get::<_, i64>(0))
            .unwrap_or(0)
    }

    pub fn add_device(
        &self,
        device_id: &str,
        name: &str,
        platform: &str,
        public_key: &str,
        refresh_hash: &str,
    ) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO devices (device_id, name, platform, public_key, refresh_hash, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![device_id, name, platform, public_key, refresh_hash, now()],
        );
    }

    /// Verify a refresh token for a device id. Returns None for unknown, revoked or mismatched.
    pub fn verify_refresh(&self, device_id: &str, refresh_hash: &str) -> Option<Device> {
        let conn = self.conn.lock().unwrap();
        let row = conn
            .query_row(
                "SELECT device_id, name, platform, created_at, last_seen_at, revoked, refresh_hash
                 FROM devices WHERE device_id = ?1",
                params![device_id],
                |r| {
                    Ok((
                        Device {
                            device_id: r.get(0)?,
                            name: r.get(1)?,
                            platform: r.get(2)?,
                            created_at: r.get(3)?,
                            last_seen_at: r.get(4)?,
                            revoked: r.get::<_, i64>(5)? != 0,
                        },
                        r.get::<_, String>(6)?,
                    ))
                },
            )
            .optional()
            .ok()
            .flatten()?;

        let (device, stored_hash) = row;
        if device.revoked || !constant_time_eq(stored_hash.as_bytes(), refresh_hash.as_bytes()) {
            return None;
        }
        Some(device)
    }

    pub fn touch(&self, device_id: &str) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "UPDATE devices SET last_seen_at = ?2 WHERE device_id = ?1",
            params![device_id, now()],
        );
    }

    pub fn list(&self) -> Vec<Device> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = match conn.prepare(
            "SELECT device_id, name, platform, created_at, last_seen_at, revoked
             FROM devices ORDER BY created_at DESC",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let rows = stmt.query_map([], |r| {
            Ok(Device {
                device_id: r.get(0)?,
                name: r.get(1)?,
                platform: r.get(2)?,
                created_at: r.get(3)?,
                last_seen_at: r.get(4)?,
                revoked: r.get::<_, i64>(5)? != 0,
            })
        });
        match rows {
            Ok(iter) => iter.filter_map(|r| r.ok()).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Revoke and null the refresh hash in the same statement, so a revoke lands even if a request
    /// was already in flight with a valid token.
    pub fn revoke(&self, device_id: &str) -> bool {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE devices SET revoked = 1, refresh_hash = '' WHERE device_id = ?1 AND revoked = 0",
            params![device_id],
        )
        .map(|n| n > 0)
        .unwrap_or(false)
    }

    /// Purge a revoked device's row, exactly as the bridge's `registry.delete_revoked` does:
    /// one atomic statement, and "active" and "missing" are distinct answers.
    pub fn delete_revoked(&self, device_id: &str) -> &'static str {
        let conn = self.conn.lock().unwrap();
        let deleted = conn
            .execute("DELETE FROM devices WHERE device_id = ?1 AND revoked = 1", params![device_id])
            .map(|n| n > 0)
            .unwrap_or(false);
        if deleted {
            return "deleted";
        }
        let exists = conn
            .query_row("SELECT 1 FROM devices WHERE device_id = ?1", params![device_id], |_| Ok(()))
            .optional()
            .ok()
            .flatten()
            .is_some();
        if exists { "active" } else { "missing" }
    }

    pub fn add_attachment(&self, a: &Attachment) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO attachments (attachment_id, device_id, name, size, sha256, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![a.attachment_id, a.device_id, a.name, a.size, a.sha256, a.created_at],
        );
    }

    pub fn get_attachment(&self, attachment_id: &str) -> Option<Attachment> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT attachment_id, device_id, name, size, sha256, created_at
             FROM attachments WHERE attachment_id = ?1",
            params![attachment_id],
            |r| {
                Ok(Attachment {
                    attachment_id: r.get(0)?,
                    device_id: r.get(1)?,
                    name: r.get(2)?,
                    size: r.get(3)?,
                    sha256: r.get(4)?,
                    created_at: r.get(5)?,
                })
            },
        )
        .optional()
        .ok()
        .flatten()
    }

    /// Owner-scoped delete: a device can only remove what it uploaded.
    pub fn delete_attachment(&self, attachment_id: &str, device_id: &str) -> bool {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM attachments WHERE attachment_id = ?1 AND device_id = ?2",
            params![attachment_id, device_id],
        )
        .map(|n| n > 0)
        .unwrap_or(false)
    }

    // ---- bridge-owned documents -------------------------------------------------
    // Categories, defaults, icons, disabled bots and approvals are *ours*: the engine has no opinion
    // on them and they must survive an engine swap. One JSON document per key, in SQLite.

    pub fn doc_or(&self, key: &str, default: serde_json::Value) -> serde_json::Value {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT json FROM documents WHERE key = ?1", params![key], |r| {
            r.get::<_, String>(0)
        })
        .optional()
        .ok()
        .flatten()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(default)
    }

    pub fn set_doc(&self, key: &str, value: &serde_json::Value) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO documents (key, json, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET json = ?2, updated_at = ?3",
            params![key, value.to_string(), now()],
        );
    }

    // ---- shared session pointers -----------------------------------------------
    // One row per bot profile: which conversation the paired devices should open. Keyed by profile
    // alone (every paired device is the same owner), upserted on write so the last write wins.

    pub fn get_bot_session(&self, profile: &str) -> Option<String> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT stored_session_id FROM bot_sessions WHERE profile = ?1",
            params![profile],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .ok()
        .flatten()
    }

    pub fn set_bot_session(&self, profile: &str, stored_session_id: &str) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO bot_sessions (profile, stored_session_id, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(profile) DO UPDATE SET stored_session_id = ?2, updated_at = ?3",
            params![profile, stored_session_id, now()],
        );
    }

    /// The desktop pet's own session for one bot, or `None` when it has not been minted yet.
    ///
    /// Deliberately a different table from `bot_sessions`: that pointer is the conversation the
    /// app opens, and a balloon question must not be answered in it.
    pub fn get_bot_pet_session(&self, profile: &str) -> Option<String> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT stored_session_id FROM pet_sessions WHERE profile = ?1",
            params![profile],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .ok()
        .flatten()
    }

    /// Point the pet at a session — the mint, and again whenever the window is rotated.
    pub fn set_bot_pet_session(&self, profile: &str, stored_session_id: &str) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO pet_sessions (profile, stored_session_id, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(profile) DO UPDATE SET stored_session_id = ?2, updated_at = ?3",
            params![profile, stored_session_id, now()],
        );
    }

    // ---- push -------------------------------------------------------------------
    // The Bark relay: where a device's banners go, what has already been announced, and who asked
    // for the last prompt. `key` is a credential: it lives here and nowhere else — not in a log
    // line, not in a response body.

    /// Register (or replace) one device's relay. `preset_bot` is left alone on replace: it is the
    /// device's "I am reading this bot" claim, not part of the target.
    pub fn set_push_target(&self, device_id: &str, provider: &str, endpoint: &str, key: &str) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO push_targets (device_id, provider, endpoint, key, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(device_id) DO UPDATE SET provider = excluded.provider,
                 endpoint = excluded.endpoint, key = excluded.key, updated_at = excluded.updated_at",
            params![device_id, provider, endpoint, key, now()],
        );
    }

    pub fn push_target(&self, device_id: &str) -> Option<PushTarget> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT device_id, provider, endpoint, key, preset_bot, updated_at
             FROM push_targets WHERE device_id = ?1",
            params![device_id],
            row_to_target,
        )
        .optional()
        .ok()
        .flatten()
    }

    pub fn push_targets(&self) -> Vec<PushTarget> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = match conn.prepare(
            "SELECT device_id, provider, endpoint, key, preset_bot, updated_at FROM push_targets",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let rows = stmt.query_map([], row_to_target);
        match rows {
            Ok(iter) => iter.filter_map(|r| r.ok()).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// The bot this device says it is looking at, stamped so a phone that slept mid-chat cannot
    /// silence a bot forever.
    pub fn set_push_presence(&self, device_id: &str, bot: Option<&str>) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "UPDATE push_targets SET preset_bot = ?2, updated_at = ?3 WHERE device_id = ?1",
            params![device_id, bot, now()],
        );
    }

    pub fn push_watch(&self, profile: &str) -> Option<f64> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT last_at FROM push_watch WHERE profile = ?1",
            params![profile],
            |r| r.get::<_, f64>(0),
        )
        .optional()
        .ok()
        .flatten()
    }

    pub fn set_push_watch(&self, profile: &str, last_at: f64) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO push_watch (profile, last_at) VALUES (?1, ?2)
             ON CONFLICT(profile) DO UPDATE SET last_at = excluded.last_at",
            params![profile, last_at],
        );
    }

    pub fn push_prompt(&self, profile: &str) -> Option<(f64, String)> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT at, source FROM push_prompts WHERE profile = ?1",
            params![profile],
            |r| Ok((r.get::<_, f64>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .ok()
        .flatten()
    }

    // ---- card snapshots ----------------------------------------------------------
    // One row per `(session, message, card)`: what that message showed the last time the card was
    // readable. See `cards.rs` for the route that writes and reads these.

    /// The last state a reader of this message saw, or `None` when no read has succeeded yet.
    pub fn card_snapshot(&self, session: &str, message: &str, card_id: &str) -> Option<(String, String)> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT json, mtime FROM card_snapshots
             WHERE session_id = ?1 AND message_id = ?2 AND card_id = ?3",
            params![session, message, card_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .ok()
        .flatten()
    }

    /// Insert the first read, then move it forward on every poll. A card larger than the contract's
    /// 32 KB is not stored at all — the route refuses it before reaching here, and this is the
    /// belt-and-braces cap on what the table can grow to.
    pub fn put_card_snapshot(
        &self,
        session: &str,
        message: &str,
        card_id: &str,
        json: &str,
        mtime: &str,
    ) {
        if json.len() as u64 > CARD_SNAPSHOT_MAX_BYTES {
            return;
        }
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO card_snapshots (session_id, message_id, card_id, json, mtime, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(session_id, message_id, card_id) DO UPDATE SET
                 json = excluded.json, mtime = excluded.mtime, updated_at = excluded.updated_at",
            params![session, message, card_id, json, mtime, now()],
        );
        // Retention, not a quota: a week-old thread still draws its cards, a season-old one may
        // not. Without this the table is the one piece of state that only ever grows.
        let _ = conn.execute(
            "DELETE FROM card_snapshots WHERE updated_at < ?1",
            params![now() - CARD_SNAPSHOT_RETENTION_SECONDS],
        );
    }

    /// Written by whatever knows a prompt came from a human. Nothing in this service does yet —
    /// the app's own turn goes straight to the engine over the spliced socket, and parsing every
    /// relay frame to guess is worse than the row simply being absent (an absent row means "do not
    /// suppress", which is the safe direction). The reader is live, so imported rows from a host
    /// that did stamp prompts keep working.
    #[allow(dead_code)]
    pub fn set_push_prompt(&self, profile: &str, source: &str) {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute(
            "INSERT INTO push_prompts (profile, at, source) VALUES (?1, ?2, ?3)
             ON CONFLICT(profile) DO UPDATE SET at = excluded.at, source = excluded.source",
            params![profile, now(), source],
        );
    }
}

#[derive(Clone, Debug)]
pub struct PushTarget {
    pub device_id: String,
    pub provider: String,
    pub endpoint: String,
    /// The Bark device key. A credential: never log it, never return it.
    pub key: String,
    pub preset_bot: Option<String>,
    pub updated_at: f64,
}

fn row_to_target(r: &rusqlite::Row<'_>) -> rusqlite::Result<PushTarget> {
    Ok(PushTarget {
        device_id: r.get(0)?,
        provider: r.get(1)?,
        endpoint: r.get(2)?,
        key: r.get(3)?,
        preset_bot: r.get(4)?,
        updated_at: r.get(5)?,
    })
}

/// `bridge.db` now holds a push credential, so it is readable by its owner alone. WAL keeps the
/// newest pages in `-wal`/`-shm`, and a 0644 sidecar leaks as much as a 0644 database.
fn restrict_db_permissions(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        for suffix in ["", "-wal", "-shm"] {
            let candidate = path.with_file_name(format!("{name}{suffix}"));
            if candidate.exists() {
                let _ = std::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o600));
            }
        }
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// Compare secrets without an early return, so a wrong token cannot be recovered from timing.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}
