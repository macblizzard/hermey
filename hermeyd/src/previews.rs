//! The bot list's last-message line: every bot's newest turn, read from its own `state.db`.
//!
//! `GET  /v1/bots/previews`               → {previews: {profile: {text, role, at}}}
//! `POST /v1/bots/previews {"since":{…}}` → the same, plus {unread: {profile: n}}
//!
//! Both halves describe **one conversation per bot**: the one the app opens, which is the shared
//! stored session pointer (`GET /v1/bots/{profile}/session`), falling back to the profile's most
//! recently active session when there is no usable pointer. That scoping is the whole contract, not
//! a detail:
//!
//! * The device's read mark is `at` from this same answer (`AppModel.readPreviews` stores
//!   `preview.timestamp`, and `markRead` writes it back as `timeIntervalSince1970` — epoch
//!   **seconds**). A mark only means anything against the messages of the conversation it came
//!   from.
//! * A bot also works outside the chat it shows: cron runs, CLI turns, other runtimes, each in its
//!   own session row. Counting every session in the profile makes those turns unread forever — the
//!   mark advances to the pointer's newest message and the count still sees the other sessions'
//!   rows, so the badge never reaches zero. The preview would also advertise a line the transcript
//!   never shows. Production (`Bridge/hermes_bridge/bot_previews.py`) resolves the session once and
//!   uses it for both.
//!
//! Read-only and best-effort by design: the engine owns these databases and may be writing to them
//! this instant, so a locked or missing file yields no row for that bot rather than an error for the
//! whole list. One indexed query per bot.

use crate::routes::{require_device, AppState};
use axum::http::{HeaderMap, StatusCode};
use axum::extract::State;
use axum::Json;
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

const TEXT_LIMIT: usize = 180;

/// What counts as conversation: a message the list row may show, in either direction, excluding
/// the engine's own sentinels. `tool` and `system` rows are not conversation; room/system
/// injections start with a bracketed marker and would read as noise in a one-line preview;
/// `[SILENT]` / `NO_REPLY` are the engine's "I chose not to answer" sentinels, and a row that reads
/// `[SILENT]` is worse than the previous real line. The same filter is used for the preview and for
/// the unread count so a hidden row can never light a badge.
const PREVIEWABLE: &str = "content IS NOT NULL AND length(trim(content)) > 0 \
     AND upper(trim(content)) NOT IN ('[SILENT]', 'NO_REPLY') \
     AND content NOT LIKE '[Discussion:%' \
     AND content NOT LIKE '[Room%' \
     AND content NOT LIKE '[[%'";

fn collapse(text: &str) -> String {
    let mut out = String::with_capacity(text.len().min(TEXT_LIMIT * 2));
    let mut space = false;
    for ch in text.chars() {
        if ch.is_whitespace() {
            space = true;
            continue;
        }
        if space && !out.is_empty() {
            out.push(' ');
        }
        space = false;
        out.push(ch);
        if out.chars().count() >= TEXT_LIMIT {
            out.push('…');
            break;
        }
    }
    out
}

fn open_readonly(path: &std::path::Path) -> Option<Connection> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    conn.busy_timeout(Duration::from_millis(400)).ok()?;
    Some(conn)
}

/// The most recently active session that has a message worth previewing.
///
/// A profile keeps placeholder sessions (`local-…`) with no turns in them, and they are often the
/// newest rows — ordering by activity alone picks one of those and the row loses its third line.
/// The `EXISTS` is an indexed lookup per session.
fn newest_eligible_session(conn: &Connection) -> Option<String> {
    let sql = format!(
        "SELECT s.id FROM sessions s \
         WHERE EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id \
             AND m.role IN ('user','assistant') AND {PREVIEWABLE}) \
         ORDER BY COALESCE(s.last_activity_at, s.started_at, 0) DESC LIMIT 1"
    );
    // `last_activity_at` arrived in a later schema: a database without it still gets its third
    // line rather than none.
    let row = conn
        .query_row(&sql, [], |r| r.get::<_, String>(0))
        .or_else(|_| {
            conn.query_row(
                &format!(
                    "SELECT s.id FROM sessions s \
                     WHERE EXISTS (SELECT 1 FROM messages m WHERE m.session_id = s.id \
                         AND m.role IN ('user','assistant') AND {PREVIEWABLE}) \
                     ORDER BY COALESCE(s.started_at, 0) DESC LIMIT 1"
                ),
                [],
                |r| r.get::<_, String>(0),
            )
        })
        .ok()?;
    Some(row)
}

/// The one conversation this bot's row and badge describe: the stored pointer when it names a real
/// session with something to show, else the newest eligible session.
fn conversation(conn: &Connection, stored: Option<&str>) -> Option<String> {
    if let Some(stored) = stored {
        let known = conn
            .query_row("SELECT 1 FROM sessions WHERE id = ?1", [stored], |_| Ok(()))
            .is_ok();
        if known {
            let has_row = conn
                .query_row(
                    &format!(
                        "SELECT 1 FROM messages WHERE session_id = ?1 \
                         AND role IN ('user','assistant') AND {PREVIEWABLE} LIMIT 1"
                    ),
                    [stored],
                    |_| Ok(()),
                )
                .is_ok();
            if has_row {
                return Some(stored.to_string());
            }
        }
    }
    newest_eligible_session(conn)
}

/// The newest real turn of one session.
fn newest_turn(conn: &Connection, session: &str) -> Option<(String, String, f64)> {
    let sql = format!(
        "SELECT role, content, timestamp FROM messages \
         WHERE session_id = ?1 AND role IN ('user','assistant') AND {PREVIEWABLE} \
         ORDER BY timestamp DESC, id DESC LIMIT 1"
    );
    conn.query_row(&sql, [session], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, f64>(2)?,
        ))
    })
    .ok()
}

/// How many turns the bot wrote in this conversation after `since` (epoch seconds).
///
/// A mark of zero is no mark: a device that has never looked at this bot sends nothing at all, and
/// one that stores an unset mark sends `0` — counting all history for that would badge a bot whose
/// conversation has never been opened. Production draws the same line (`since <= 0` → 0).
fn unread_count(conn: &Connection, session: &str, since: f64) -> i64 {
    // Only the bot's own turns are news to the person reading, and a silent turn is not news at
    // all: the same sentinels the preview skips must not light a badge.
    if !(since > 0.0) {
        return 0;
    }
    let sql = format!(
        "SELECT COUNT(*) FROM messages WHERE session_id = ?1 AND role = 'assistant' \
         AND timestamp > ?2 AND {PREVIEWABLE}"
    );
    conn.query_row(&sql, rusqlite::params![session, since], |r| {
        r.get::<_, i64>(0)
    })
    .unwrap_or(0)
}

fn profile_dirs(st: &AppState) -> Vec<String> {
    let root = st.engine_home.join("profiles");
    let mut names: Vec<String> = std::fs::read_dir(&root)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.path().is_dir())
                .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
                .map(|e| e.file_name().to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

fn build(st: &AppState, marks: Option<&HashMap<String, f64>>) -> (Value, Value) {
    let mut previews = Map::new();
    let mut unread = Map::new();
    for profile in profile_dirs(st) {
        let db = st.engine_home.join("profiles").join(&profile).join("state.db");
        if !db.is_file() {
            continue;
        }
        let Some(conn) = open_readonly(&db) else { continue };
        let stored = st.store.get_bot_session(&profile);
        let Some(session) = conversation(&conn, stored.as_deref()) else {
            continue;
        };
        if let Some((role, content, at)) = newest_turn(&conn, &session) {
            let text = collapse(&content);
            if !text.is_empty() {
                previews.insert(
                    profile.clone(),
                    json!({"text": text, "role": role, "at": at}),
                );
            }
        }
        if let Some(marks) = marks {
            if let Some(since) = marks.get(&profile) {
                let n = unread_count(&conn, &session, *since);
                // Zero is never sent: the app treats an absent key as zero already.
                if n > 0 {
                    unread.insert(profile.clone(), json!(n));
                }
            }
        }
    }
    (Value::Object(previews), Value::Object(unread))
}

pub async fn previews_get(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_device(&st, &headers)?;
    let (previews, _) = build(&st, None);
    Ok(Json(json!({"previews": previews})))
}

#[derive(Deserialize, Default)]
pub struct PreviewMarks {
    #[serde(default)]
    pub since: Option<HashMap<String, f64>>,
}

pub async fn previews_post(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Option<Json<PreviewMarks>>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_device(&st, &headers)?;
    let marks = body.and_then(|Json(b)| b.since);
    let (previews, unread) = build(&st, marks.as_ref());
    Ok(Json(json!({"previews": previews, "unread": unread})))
}

#[cfg(test)]
mod tests {
    /// The mark a device sends back is the `at` this route handed out, and it must arrive as the
    /// same double. `serde_json` without the `float_roundtrip` feature parses a long decimal one
    /// ULP low, so `timestamp > since` stays true for the very message the mark was taken from and
    /// the badge can never be cleared — the count "comes back" after "mark all as read". This test
    /// fails the moment that feature is dropped from `Cargo.toml`.
    #[test]
    fn a_read_mark_round_trips_through_json_exactly() {
        use std::collections::HashMap;
        let text = r#"{"cody": 1795222533.1375353, "aria": 1795224395.6881695}"#;
        let parsed: HashMap<String, f64> = serde_json::from_str(text).unwrap();
        assert_eq!(parsed["cody"].to_bits(), 1795222533.1375353_f64.to_bits());
        assert_eq!(parsed["aria"].to_bits(), 1795224395.6881695_f64.to_bits());
    }
}
