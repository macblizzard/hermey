//! Full-text-lite search across every bot's conversation.
//!
//! `GET /v1/search?q=&limit=&offset=` →
//! `{query, total, more, results:[{profile, session_id, role, at, snippet, match}]}`
//!
//! Deliberate choices, matching the production bridge so the page behaves the same:
//!
//! * A query shorter than two characters answers empty instead of erroring — the app fires this as
//!   the person types, and one keystroke is not a search.
//! * Per bot there is a cap, so one busy profile cannot fill the page; the page is then assembled and
//!   paged globally, newest first.
//! * Every database is opened **read-only**: the engine owns these files and may be writing now, so an
//!   unreadable or mid-migration profile contributes nothing rather than failing the whole search.

use crate::routes::{require_device, AppState};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

type Fail = (StatusCode, Json<Value>);

const MIN_QUERY: usize = 2;
const MAX_QUERY: usize = 120;
const PER_BOT: usize = 20;
const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 100;
const SNIPPET_PAD: usize = 80;
const MAX_CONTENT_CHARS: usize = 100_000;

#[derive(Deserialize)]
pub struct SearchQuery {
    #[serde(default)]
    pub q: String,
    pub limit: Option<usize>,
    pub offset: Option<usize>,
}

fn flat(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The line around the first match, and the matched text as it was written.
fn snippet(text: &str, needle: &str) -> (String, String) {
    let body = flat(text);
    let hay = body.to_lowercase();
    let pin = needle.to_lowercase();
    let Some(byte_index) = hay.find(&pin) else {
        return (body.chars().take(SNIPPET_PAD * 2).collect(), String::new());
    };
    // Char boundaries: the needle may be multi-byte, and slicing by byte would panic.
    let start_chars = hay[..byte_index].chars().count();
    let needle_chars = pin.chars().count();
    let total = body.chars().count();
    let start = start_chars.saturating_sub(SNIPPET_PAD);
    let end = (start_chars + needle_chars + SNIPPET_PAD).min(total);
    let mut out: String = body.chars().skip(start).take(end - start).collect();
    if start > 0 {
        out.insert(0, '…');
    }
    if end < total {
        out.push('…');
    }
    let matched: String = body.chars().skip(start_chars).take(needle_chars).collect();
    (out, matched)
}

fn search_one(db: &Path, profile: &str, needle: &str) -> Vec<Value> {
    let Ok(conn) = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY) else {
        return vec![];
    };
    let _ = conn.busy_timeout(Duration::from_millis(400));
    let Ok(mut stmt) = conn.prepare(
        "SELECT session_id, role, content, timestamp FROM messages \
         WHERE role IN ('user','assistant') AND content IS NOT NULL AND content LIKE ?1 \
         ORDER BY timestamp DESC, id DESC LIMIT ?2",
    ) else {
        return vec![];
    };
    let pattern = format!("%{needle}%");
    let rows = stmt.query_map((pattern, PER_BOT as i64), |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, f64>(3)?,
        ))
    });
    let Ok(rows) = rows else { return vec![] };

    let mut found = Vec::new();
    for row in rows.flatten() {
        let (session_id, role, content, at) = row;
        let trimmed: String = content.chars().take(MAX_CONTENT_CHARS).collect();
        let (snip, matched) = snippet(&trimmed, needle);
        found.push(json!({
            "profile": profile,
            "session_id": session_id,
            "role": role,
            "at": at,
            "snippet": snip,
            "match": matched,
        }));
    }
    found
}

fn profile_dirs(st: &AppState) -> Vec<(String, std::path::PathBuf)> {
    let root = st.engine_home.join("profiles");
    let mut out: Vec<(String, std::path::PathBuf)> = std::fs::read_dir(&root)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.path().is_dir())
                .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
                .map(|e| (e.file_name().to_string_lossy().to_string(), e.path().join("state.db")))
                .filter(|(_, db)| db.is_file())
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

pub async fn search(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<SearchQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let needle: String = q.q.trim().chars().take(MAX_QUERY).collect();
    if needle.chars().count() < MIN_QUERY {
        return Ok(Json(json!({"query": needle, "total": 0, "more": false, "results": []})));
    }
    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let offset = q.offset.unwrap_or(0);

    let mut results: Vec<Value> = Vec::new();
    for (profile, db) in profile_dirs(&st) {
        results.extend(search_one(&db, &profile, &needle));
    }
    results.sort_by(|a, b| {
        let key = |v: &Value| v.get("at").and_then(|x| x.as_f64()).unwrap_or(0.0);
        key(b).partial_cmp(&key(a)).unwrap_or(std::cmp::Ordering::Equal)
    });

    let total = results.len();
    let page: Vec<Value> = results.into_iter().skip(offset).take(limit).collect();
    Ok(Json(json!({
        "query": needle,
        "total": total,
        "more": offset + limit < total,
        "results": page,
    })))
}
