//! Agent cards (`card.v1`): one GET route that resolves a card file the bot wrote, plus the
//! per-message snapshot that lets a reopened thread draw the card after the file is gone.
//!
//! ```text
//! GET /v1/cards/{id}?session=<session id>&message=<message id>
//!   -> 200 {"card": {...}, "mtime": "2026-11-22T21:04:06.120Z", "final": false}
//!   -> 400 {"error": "bad_id"}
//!   -> 403 {"error": "outside_base"}
//!   -> 404 {"error": "no_such_card"}
//!   -> 413 {"error": "too_large"}
//!   -> 422 {"error": "bad_card"}
//! ```
//!
//! Why the engine resolves the file and the client sends only an id: the client has the
//! transcript, not the host filesystem, and a path from a client is a path we would have to
//! sanitise. Here the id is matched against `^[A-Za-z0-9_-]{1,40}$` *before* a path is built, and
//! the path that results is canonicalised and must still be `<base>/cards/<id>.json` — a symlink
//! out of the directory is refused (`outside_base`), not followed.
//!
//! `<base>` is the session's `cwd` when the engine recorded one, else `profiles/<name>` for the
//! profile that owns the session. A session row is read from `profiles/<name>/state.db`
//! read-only — the same door `previews.rs` and `search.rs` use; nothing about the engine's
//! database is written from here.
//!
//! Snapshots: the first successful read of `(session, message, card)` is stored in [`Store`], and
//! every later successful read moves it forward (the spec's live poll). When the file is gone the
//! snapshot is served instead, so a thread opened a week later still draws its approval. Two
//! messages that name the same file therefore keep their own copy: a later turn rewriting the file
//! cannot rewrite what an earlier message showed.
//!
//! A snapshot is only a fallback for a *missing* file. A file that exists but is too large, is not
//! JSON, or resolves outside the base is refused with its own code — the client shows "not
//! available" for that card rather than a stale one.
//!
//! Kind schemas: `approval`, `task` and `draft-email` are validated by the app's `CardModel`, whose
//! rules predate this route. The `infographic` kind — a short structured answer with one real
//! picture — is validated *here*, on arrival, because it is the first kind that names a remote URL:
//! `image` and `link.url` must be http(s), the title, facts and highlight are length-bounded, and
//! every refusal names the field (`facts[2].value must be 1-80 characters`) so the bot can fix what
//! it wrote. A card that fails is refused with `422 bad_card` and never snapshotted.

use crate::routes::{require_device, AppState};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Read;
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The contract's ceiling, and also the snapshot's: a card is data, not an upload.
pub const MAX_CARD_BYTES: u64 = 32 * 1024;

// The ceilings an `infographic` card is held to. A card is a glance: a title that needs two lines is
// a paragraph, and a value that wraps twice is a sentence the reply should have carried instead.
const MIN_INFO_FACTS: usize = 3;
const MAX_INFO_FACTS: usize = 8;
const MAX_INFO_TITLE: usize = 120;
const MAX_INFO_SUBTITLE: usize = 160;
const MAX_INFO_FACT_LABEL: usize = 40;
const MAX_INFO_FACT_VALUE: usize = 80;
const MAX_INFO_HIGHLIGHT: usize = 40;
/// A seller or an availability note is one short row, never a paragraph.
const MAX_INFO_ASIDE: usize = 60;
const MAX_INFO_CAPTION: usize = 120;
const MAX_INFO_SOURCE: usize = 80;
const MAX_INFO_LINK_LABEL: usize = 40;
/// Long enough for a real product page, short enough that a card cannot become a URL dump.
const MAX_CARD_URL: usize = 2048;

/// Longest id the marker contract allows (`^[A-Za-z0-9_-]{1,40}$`).
const MAX_ID_LEN: usize = 40;

/// Session ids are `%Y%m%d_%H%M%S_` + six hex, and placeholders can be longer; 128 is the ceiling
/// `bot_sessions.rs` enforces for the same value.
const MAX_SESSION_LEN: usize = 128;

type Fail = (StatusCode, Json<Value>);

/// Every refusal the client branches on. Distinct variants on purpose: "the file is gone" and "the
/// file points outside the cards directory" are not the same answer, and one 404 for both would
/// hide a broken bot.
#[derive(Debug, PartialEq, Eq)]
pub enum CardError {
    BadId,
    OutsideBase,
    TooLarge,
    BadCard,
    /// A card of a kind this route validates that broke that kind's own schema. The payload names
    /// the field: a bot that wrote a 400-character title has to be told *which* field to fix, not
    /// only that the document is refused.
    BadField(String),
    Missing,
}

impl CardError {
    fn code(&self) -> &'static str {
        match self {
            CardError::BadId => "bad_id",
            CardError::OutsideBase => "outside_base",
            CardError::TooLarge => "too_large",
            // A broken field and a broken document are the same class to a client: this card cannot
            // be drawn. The `detail` is what tells the two apart.
            CardError::BadCard | CardError::BadField(_) => "bad_card",
            CardError::Missing => "no_such_card",
        }
    }

    fn into_fail(self, detail: impl Into<String>) -> Fail {
        let status = match self {
            CardError::BadId => StatusCode::BAD_REQUEST,
            CardError::OutsideBase => StatusCode::FORBIDDEN,
            CardError::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            CardError::BadCard | CardError::BadField(_) => StatusCode::UNPROCESSABLE_ENTITY,
            CardError::Missing => StatusCode::NOT_FOUND,
        };
        (
            status,
            Json(json!({ "error": self.code(), "detail": detail.into() })),
        )
    }
}

#[derive(Deserialize)]
pub struct CardQuery {
    /// The session that owns the card. Required: it is what makes the base directory knowable.
    #[serde(default)]
    pub session: String,
    /// The message whose marker named this card. It is the snapshot's second key, so two messages
    /// showing the same file keep separate copies. Absent is a distinct key (`""`), never another
    /// message's row.
    #[serde(default, alias = "message_id")]
    pub message: String,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_LEN
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn valid_session(session: &str) -> bool {
    !session.is_empty()
        && session.len() <= MAX_SESSION_LEN
        && session
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Where a session's card files live: its recorded working directory, else the profile directory.
#[derive(Debug)]
struct Session {
    profile: String,
    cwd: Option<PathBuf>,
}

impl Session {
    fn base(&self, st: &AppState) -> PathBuf {
        // A relative cwd would resolve against *this service's* working directory, which is not
        // the bot's; treating it as absent is the only honest reading. The engine writes absolute
        // paths, so this only fires on a hand-edited row.
        if let Some(cwd) = self.cwd.as_ref().filter(|p| p.is_absolute()) {
            return cwd.clone();
        }
        st.engine_home.join("profiles").join(&self.profile)
    }
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

fn open_readonly(path: &FsPath) -> Option<Connection> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    conn.busy_timeout(Duration::from_millis(400)).ok()?;
    Some(conn)
}

/// The session row, wherever it lives. The route only receives the id, so the owning profile is
/// whichever `state.db` has that row — the same enumeration the search and preview routes do.
fn find_session(st: &AppState, session: &str) -> Option<Session> {
    if !valid_session(session) {
        return None;
    }
    for profile in profile_dirs(st) {
        let db = st
            .engine_home
            .join("profiles")
            .join(&profile)
            .join("state.db");
        if !db.is_file() {
            continue;
        }
        let Some(conn) = open_readonly(&db) else {
            continue;
        };
        let known = conn
            .query_row(
                "SELECT 1 FROM sessions WHERE id = ?1",
                [session],
                |_| Ok(()),
            )
            .is_ok();
        if !known {
            continue;
        }
        // An older schema has no `cwd`: the column is optional, the session is not.
        let cwd: Option<String> = conn
            .query_row("SELECT cwd FROM sessions WHERE id = ?1", [session], |r| {
                r.get::<_, Option<String>>(0)
            })
            .ok()
            .flatten()
            .filter(|c| !c.trim().is_empty());
        return Some(Session {
            profile,
            cwd: cwd.map(PathBuf::from),
        });
    }
    None
}

/// The file, its mtime, validated. See the module docs for the order the guards run in.
fn read_card(base: &FsPath, id: &str) -> Result<(Value, String), CardError> {
    if !valid_id(id) {
        return Err(CardError::BadId);
    }
    let Ok(canon_base) = std::fs::canonicalize(base) else {
        return Err(CardError::Missing);
    };
    let Ok(canon_cards) = std::fs::canonicalize(canon_base.join("cards")) else {
        return Err(CardError::Missing);
    };
    // A `cards` directory that is itself a symlink out of the base is an escape, not a layout.
    if !canon_cards.starts_with(&canon_base) {
        return Err(CardError::OutsideBase);
    }
    // `id` is alphanumeric/`-`/`_` only, so this join cannot leave `canon_cards`.
    let candidate = canon_cards.join(format!("{id}.json"));
    let file = match std::fs::File::open(&candidate) {
        Ok(f) => f,
        Err(_) => return Err(CardError::Missing),
    };
    let Ok(meta) = file.metadata() else {
        return Err(CardError::Missing);
    };
    // The path we validated must name the file we opened: a symlink swapped between open and
    // resolve is exactly how a containment check gets defeated.
    let Ok(canon_file) = std::fs::canonicalize(&candidate) else {
        return Err(CardError::Missing);
    };
    if canon_file.parent() != Some(canon_cards.as_path()) || !canon_file.starts_with(&canon_base) {
        return Err(CardError::OutsideBase);
    }
    same_inode(&meta, &canon_file)?;
    if meta.len() > MAX_CARD_BYTES {
        return Err(CardError::TooLarge);
    }
    let mut buf = Vec::with_capacity(meta.len().min(MAX_CARD_BYTES) as usize + 1);
    if (&file)
        .take(MAX_CARD_BYTES + 1)
        .read_to_end(&mut buf)
        .is_err()
    {
        return Err(CardError::Missing);
    }
    // The file can grow after `metadata`: the read is what the limit is measured against.
    if buf.len() as u64 > MAX_CARD_BYTES {
        return Err(CardError::TooLarge);
    }
    let card: Value = serde_json::from_slice(&buf).map_err(|_| CardError::BadCard)?;
    if !card.is_object() {
        return Err(CardError::BadCard);
    }
    // A kind that carries its own schema is checked before the read counts as a good one: an
    // invalid card must not be snapshotted, or it would keep drawing after the bot fixed the file.
    validate_kind(&card).map_err(CardError::BadField)?;
    let mtime = meta
        .modified()
        .map(iso8601)
        .unwrap_or_else(|_| iso8601(SystemTime::now()));
    Ok((card, mtime))
}

#[cfg(unix)]
fn same_inode(opened: &std::fs::Metadata, path: &FsPath) -> Result<(), CardError> {
    use std::os::unix::fs::MetadataExt;
    let on_disk = std::fs::metadata(path).map_err(|_| CardError::Missing)?;
    if on_disk.dev() != opened.dev() || on_disk.ino() != opened.ino() {
        return Err(CardError::OutsideBase);
    }
    Ok(())
}

#[cfg(not(unix))]
fn same_inode(_: &std::fs::Metadata, _: &FsPath) -> Result<(), CardError> {
    Ok(())
}

/// `http://` or `https://`, an authority, and no whitespace.
///
/// Deliberately a scheme gate rather than a URL parser: the client hands the string to `URL`, and
/// what this route has to guarantee is that a card cannot name a `file:`, `data:` or `javascript:`
/// URL dressed as a picture — and that it is not a 4 KB redirect chain.
fn is_http_url(value: &str) -> bool {
    let value = value.trim();
    if value.is_empty() || value.chars().count() > MAX_CARD_URL {
        return false;
    }
    if value.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    let rest = match value.get(..8) {
        Some(prefix) if prefix.eq_ignore_ascii_case("https://") => &value[8..],
        _ => match value.get(..7) {
            Some(prefix) if prefix.eq_ignore_ascii_case("http://") => &value[7..],
            _ => return false,
        },
    };
    // An authority is the part before the first `/`, `?` or `#`, and it cannot be empty: `http://`
    // alone is not an address any client can open.
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    !authority.is_empty() && !authority.starts_with('/') && !authority.contains('@')
}

fn bounded_text(value: Option<&Value>, max: usize) -> Result<Option<String>, ()> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            let text = s.trim();
            if text.chars().count() > max {
                return Err(());
            }
            Ok(Some(text.to_string()))
        }
        _ => Err(()),
    }
}

fn required_text(value: Option<&Value>, max: usize) -> Result<String, ()> {
    match bounded_text(value, max)? {
        Some(text) if !text.is_empty() => Ok(text),
        _ => Err(()),
    }
}

/// The `infographic` schema: a short title, one real picture, the number that matters, three to
/// eight facts, an optional link and a source line.
///
/// Only this kind is checked here. The other three predate this route and are validated by the
/// app's `CardModel`; this one is checked on arrival because it is the first kind that carries a
/// remote URL, and a host that served `image: "javascript:…"` would be handing the client something
/// no renderer should have to defend against.
///
/// Every refusal names the field (`facts[2].value …`), because the bot that wrote the file is the
/// one who can fix it.
fn validate_infographic(card: &Value) -> Result<(), String> {
    required_text(card.get("title"), MAX_INFO_TITLE)
        .map_err(|_| format!("title must be 1-{MAX_INFO_TITLE} characters"))?;

    bounded_text(card.get("subtitle"), MAX_INFO_SUBTITLE).map_err(|_| {
        format!("subtitle must be a string of at most {MAX_INFO_SUBTITLE} characters")
    })?;

    let facts = match card.get("facts") {
        Some(Value::Array(items)) => items,
        _ => {
            return Err(format!(
                "facts must be a list of {MIN_INFO_FACTS}-{MAX_INFO_FACTS} {{label, value}} objects"
            ))
        }
    };
    if facts.len() < MIN_INFO_FACTS || facts.len() > MAX_INFO_FACTS {
        return Err(format!(
            "facts must hold {MIN_INFO_FACTS}-{MAX_INFO_FACTS} entries, not {}",
            facts.len()
        ));
    }
    for (index, fact) in facts.iter().enumerate() {
        required_text(fact.get("label"), MAX_INFO_FACT_LABEL).map_err(|_| {
            format!("facts[{index}].label must be 1-{MAX_INFO_FACT_LABEL} characters")
        })?;
        required_text(fact.get("value"), MAX_INFO_FACT_VALUE).map_err(|_| {
            format!("facts[{index}].value must be 1-{MAX_INFO_FACT_VALUE} characters")
        })?;
    }

    match card.get("highlight") {
        None | Some(Value::Null) => {}
        Some(Value::Object(highlight)) => {
            required_text(highlight.get("value"), MAX_INFO_HIGHLIGHT).map_err(|_| {
                format!("highlight.value must be 1-{MAX_INFO_HIGHLIGHT} characters")
            })?;
            for (field, max) in [
                ("label", MAX_INFO_HIGHLIGHT),
                ("seller", MAX_INFO_ASIDE),
                ("availability", MAX_INFO_ASIDE),
            ] {
                bounded_text(highlight.get(field), max)
                    .map_err(|_| format!("highlight.{field} must be at most {max} characters"))?;
            }
        }
        _ => {
            return Err(
                "highlight must be an object {value, label?, seller?, availability?}".to_string(),
            )
        }
    }

    let image = match card.get("image") {
        None | Some(Value::Null) => None,
        Some(value) => {
            if url_too_long(Some(value)) {
                return Err(format!("image must be at most {MAX_CARD_URL} characters"));
            }
            match value.as_str() {
                Some(url) if is_http_url(url) => Some(url.trim().to_string()),
                _ => return Err("image must be an http(s) URL".to_string()),
            }
        }
    };
    let caption = bounded_text(card.get("imageCaption"), MAX_INFO_CAPTION)
        .map_err(|_| format!("imageCaption must be at most {MAX_INFO_CAPTION} characters"))?;
    if image.is_none() && caption.is_some() {
        // A caption over no picture is a claim about something the card does not show.
        return Err("imageCaption needs an image".to_string());
    }

    match card.get("link") {
        None | Some(Value::Null) => {}
        Some(Value::Object(link)) => {
            required_text(link.get("label"), MAX_INFO_LINK_LABEL)
                .map_err(|_| format!("link.label must be 1-{MAX_INFO_LINK_LABEL} characters"))?;
            match link.get("url").and_then(Value::as_str) {
                Some(url) if is_http_url(url) => {}
                Some(_) if url_too_long(link.get("url")) => {
                    return Err(format!(
                        "link.url must be at most {MAX_CARD_URL} characters"
                    ))
                }
                _ => return Err("link.url must be an http(s) URL".to_string()),
            }
        }
        _ => return Err("link must be an object {label, url}".to_string()),
    }

    bounded_text(card.get("source"), MAX_INFO_SOURCE)
        .map_err(|_| format!("source must be at most {MAX_INFO_SOURCE} characters"))?;

    Ok(())
}

/// A URL that failed the scheme gate still needs its own answer when the only fault is its length.
fn url_too_long(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .map(|url| url.chars().count() > MAX_CARD_URL)
        .unwrap_or(false)
}

/// The kinds this route validates, and the ones it leaves to the client.
fn validate_kind(card: &Value) -> Result<(), String> {
    match card.get("kind").and_then(Value::as_str) {
        Some("infographic") => validate_infographic(card),
        _ => Ok(()),
    }
}

/// The skill's own stop rule: `resolved` set, or a terminal state. `awaiting-approval` is the
/// whole point of an approval card, so it is emphatically not final.
pub fn is_final(card: &Value) -> bool {
    let resolved = card.get("resolved").map(|r| !r.is_null()).unwrap_or(false);
    if resolved {
        return true;
    }
    // An infographic is a still picture of an answer: nothing about it is going to change, so a
    // reader should never keep re-reading it.
    if card.get("kind").and_then(Value::as_str) == Some("infographic") {
        return true;
    }
    matches!(
        card.pointer("/status/state").and_then(Value::as_str),
        Some("done") | Some("error")
    )
}

/// `2026-11-22T21:04:06.120Z` — no date crate, so the civil conversion is here. `mtime` only has
/// to be a stable string the client can compare and display; milliseconds keep a rewrite inside
/// the same second visible to the 3 s poll.
fn iso8601(t: SystemTime) -> String {
    let since = t.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = since.as_secs() as i64;
    let millis = since.subsec_millis();
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant's `civil_from_days`: days since 1970-01-01 to a proleptic Gregorian date.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11], March-based
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `GET /v1/cards/{id}?session=<session id>&message=<message id>`
pub async fn get_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(card_id): Path<String>,
    Query(q): Query<CardQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&card_id) {
        return Err(CardError::BadId.into_fail("id must be 1-40 characters of [A-Za-z0-9_-]"));
    }

    // The live file wins while it is readable; a refusal is remembered so the answer below can be
    // its own code rather than "missing" once the snapshot lookup misses too.
    let mut refusal: Option<CardError> = None;
    if let Some(session) = find_session(&st, &q.session) {
        let base = session.base(&st);
        match read_card(&base, &card_id) {
            Ok((card, mtime)) => {
                // First read persists; a later poll moves the row forward. A file that is missing
                // is not a read and must not erase what a reader already saw.
                st.store.put_card_snapshot(
                    &q.session,
                    &q.message,
                    &card_id,
                    &card.to_string(),
                    &mtime,
                );
                return Ok(Json(json!({
                    "card": card,
                    "mtime": mtime,
                    "final": is_final(&card),
                })));
            }
            Err(CardError::Missing) => {}
            Err(other) => refusal = Some(other),
        }
    }

    // Only a file that is gone falls back to the snapshot: too large, malformed or outside the base
    // are answers about the file as it is now, and hiding them behind an old copy would drawn a
    // card the bot has already replaced with something broken.
    if let Some((text, mtime)) = st.store.card_snapshot(&q.session, &q.message, &card_id) {
        if let Ok(card) = serde_json::from_str::<Value>(&text) {
            return Ok(Json(json!({
                "card": card,
                "mtime": mtime,
                "final": is_final(&card),
            })));
        }
    }

    if let Some(refusal) = refusal {
        let detail = match &refusal {
            CardError::TooLarge => "card file is larger than 32 KB".to_string(),
            CardError::OutsideBase => "card file resolves outside the cards directory".to_string(),
            CardError::BadCard => "card file is not a JSON object".to_string(),
            // The field is the whole message: this is the one refusal a bot reads and fixes.
            CardError::BadField(field) => format!("infographic card: {field}"),
            _ => "card file is not readable".to_string(),
        };
        return Err(refusal.into_fail(detail));
    }
    Err(CardError::Missing.into_fail("no card file and no snapshot for this message"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::Tickets;
    use crate::pairing::Pairing;
    use crate::routes::AppState;
    use crate::store::Store;
    use std::path::Path;

    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";
    const SESSION: &str = "20261122_120000_abcdef";
    const CARD: &str = "c-9b";

    fn scratch(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-cards-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn state(dir: &Path) -> Arc<AppState> {
        let engine_ws = "ws://127.0.0.1:9121/api/ws".to_string();
        let token_file = dir.join("engine.token");
        Arc::new(AppState {
            store: Store::open(&dir.join("bridge.db")).expect("store"),
            pairing: Pairing::new(600.0),
            tickets: Tickets::new(30.0, 300.0),
            limiter: crate::auth::RateLimiter::new(30, 60.0),
            salt: "salt-".repeat(8),
            public_host: "localhost".to_string(),
            engine_ws: engine_ws.clone(),
            engine_token_file: token_file.clone(),
            engine_auth: crate::engine_auth::EngineAuth::Required,
            engine_home: dir.join("engine"),
            home: dir.to_path_buf(),
            attachments_dir: dir.join("attachments"),
            local_token: Arc::new(crate::local_token::LocalToken::from_value(
                LOCAL,
                dir.join("local.token"),
            )),
            local_computers: Default::default(),
            browsers: Default::default(),
            display: crate::display::DisplayHub::spawn(engine_ws, Some(token_file)),
            relay_sockets: Default::default(),
            reactions: crate::reactions::Registry::in_dir(dir),
            audit: Arc::new(crate::audit::AuditLog::in_dir(dir)),
        })
    }

    fn auth() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {LOCAL}").parse().unwrap(),
        );
        headers
    }

    /// A session row, exactly the columns the engine writes that this route reads.
    fn session_row(engine_home: &Path, profile: &str, session: &str, cwd: Option<&Path>) {
        let dir = engine_home.join("profiles").join(profile);
        std::fs::create_dir_all(&dir).unwrap();
        let conn = Connection::open(dir.join("state.db")).unwrap();
        conn.execute_batch(
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, profile_name TEXT)",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, cwd, profile_name) VALUES (?1, ?2, ?3)",
            rusqlite::params![
                session,
                cwd.map(|p| p.to_string_lossy().to_string()),
                profile
            ],
        )
        .unwrap();
    }

    fn write_card(dir: &Path, id: &str, body: &str) -> PathBuf {
        let cards = dir.join("cards");
        std::fs::create_dir_all(&cards).unwrap();
        let path = cards.join(format!("{id}.json"));
        std::fs::write(&path, body).unwrap();
        path
    }

    fn valid_card(title: &str) -> String {
        json!({
            "schema": "card.v1",
            "kind": "approval",
            "title": title,
            "status": {"state": "awaiting-approval"},
            "body": [{"type": "text", "text": "Book the cabin?"}],
            "actions": [
                {"label": "Approve", "send": "APPROVE c-9b book the cabin", "style": "primary"},
                {"label": "No", "send": "NO c-9b", "style": "danger"}
            ],
            "resolved": null
        })
        .to_string()
    }

    async fn fetch(
        st: &Arc<AppState>,
        headers: HeaderMap,
        id: &str,
        session: &str,
        message: &str,
    ) -> Result<Json<Value>, Fail> {
        get_card(
            State(Arc::clone(st)),
            headers,
            Path(id.to_string()),
            Query(CardQuery {
                session: session.to_string(),
                message: message.to_string(),
            }),
        )
        .await
    }

    fn err_code(fail: Fail) -> (StatusCode, String) {
        let code = fail
            .1
             .0
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("<none>")
            .to_string();
        (fail.0, code)
    }

    /// The human half of a refusal: the field a fixed bot has to change.
    fn err_detail(fail: Fail) -> String {
        fail.1
             .0
            .get("detail")
            .and_then(Value::as_str)
            .unwrap_or("<none>")
            .to_string()
    }

    /// An `infographic` document: the shape a bot writes for "where is the Golden Gate Bridge".
    ///
    /// The picture URL is textual and never fetched: a test that reached the network would be a
    /// test that fails on a train. A real one is a public Wikimedia Commons file, e.g.
    /// `https://upload.wikimedia.org/wikipedia/commons/0/0c/GoldenGateBridge-001.jpg`.
    fn infographic() -> Value {
        json!({
            "schema": "card.v1",
            "kind": "infographic",
            "title": "Golden Gate Bridge",
            "subtitle": "San Francisco, California",
            "image": "https://example.com/golden-gate.jpg",
            "imageCaption": "The bridge from Fort Point",
            "highlight": { "label": "Main span", "value": "1,280 m" },
            "facts": [
                { "label": "Opened", "value": "27 May 1937" },
                { "label": "Total length", "value": "2,737 m" },
                { "label": "Clearance", "value": "67 m" },
                { "label": "Colour", "value": "International Orange" }
            ],
            "link": { "label": "Wikipedia", "url": "https://example.com/golden-gate" },
            "source": "Wikipedia"
        })
    }

    fn serve(dir: &Path, tag: &str) -> (Arc<AppState>, PathBuf) {
        let st = state(dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        session_row(&st.engine_home, tag, SESSION, Some(&cwd));
        (st, cwd)
    }

    #[tokio::test]
    async fn a_card_is_served_with_its_mtime_and_is_not_final() {
        let dir = scratch("serve");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        write_card(&cwd, CARD, &valid_card("Book the cabin"));
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        let ok = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("served");
        assert_eq!(ok.0["card"]["title"], "Book the cabin");
        assert_eq!(ok.0["final"], false);
        let mtime = ok.0["mtime"].as_str().expect("mtime is a string");
        assert!(
            mtime.ends_with('Z') && mtime.len() == 24,
            "iso8601: {mtime}"
        );
        assert_eq!(
            ok.0.as_object().unwrap().len(),
            3,
            "exactly card, mtime, final"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_request_without_a_device_bearer_is_refused() {
        let dir = scratch("auth");
        let st = state(&dir);
        let refused = fetch(&st, HeaderMap::new(), CARD, SESSION, "m-1")
            .await
            .unwrap_err();
        assert_eq!(refused.0, StatusCode::UNAUTHORIZED);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `..`, an absolute path, a separator and over-length are all refused before a path is built.
    #[tokio::test]
    async fn ids_that_could_be_paths_are_bad_ids() {
        let dir = scratch("bad-id");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        for id in [
            "..",
            "../c-9b",
            "../../etc/passwd",
            "/etc/passwd",
            "cards/c-9b",
            "a b",
            "c-9b.json",
            "",
        ] {
            let (status, code) =
                err_code(fetch(&st, auth(), id, SESSION, "m-1").await.unwrap_err());
            assert_eq!(status, StatusCode::BAD_REQUEST, "id {id:?}");
            assert_eq!(code, "bad_id", "id {id:?}");
        }
        // 41 characters is one over; 40 is legal.
        let long = "a".repeat(41);
        let (status, code) = err_code(fetch(&st, auth(), &long, SESSION, "m-1").await.unwrap_err());
        assert_eq!((status, code.as_str()), (StatusCode::BAD_REQUEST, "bad_id"));
        let at_limit = "a".repeat(40);
        let (_, code) = err_code(
            fetch(&st, auth(), &at_limit, SESSION, "m-1")
                .await
                .unwrap_err(),
        );
        assert_eq!(code, "no_such_card", "40 characters is a legal id");
        // Hyphen and underscore are legal; `c_9-b` must reach the filesystem, not the id guard.
        write_card(&cwd, "c_9-b", &valid_card("Underscore"));
        let ok = fetch(&st, auth(), "c_9-b", SESSION, "m-1")
            .await
            .expect("served");
        assert_eq!(ok.0["card"]["title"], "Underscore");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The card file is a symlink to something outside the base: the path names a valid id and the
    /// file exists, so only the canonical comparison can catch it.
    #[tokio::test]
    async fn a_symlinked_card_file_out_of_the_base_is_refused() {
        let dir = scratch("symlink-file");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        let cards = cwd.join("cards");
        std::fs::create_dir_all(&cards).unwrap();
        let secret = dir.join("secret.json");
        std::fs::write(&secret, valid_card("Leaked")).unwrap();
        std::os::unix::fs::symlink(&secret, cards.join(format!("{CARD}.json"))).unwrap();
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::FORBIDDEN, "outside_base")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The `cards` directory itself is a symlink out of the base — same escape, one level up.
    #[tokio::test]
    async fn a_symlinked_cards_directory_is_refused() {
        let dir = scratch("symlink-dir");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        let elsewhere = dir.join("elsewhere");
        write_card(&elsewhere, CARD, &valid_card("Elsewhere"));
        std::os::unix::fs::symlink(elsewhere.join("cards"), cwd.join("cards")).unwrap();
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::FORBIDDEN, "outside_base")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_missing_file_is_no_such_card() {
        let dir = scratch("missing");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::NOT_FOUND, "no_such_card")
        );

        // No session at all is the same answer: there is nothing to serve.
        let (status, code) = err_code(
            fetch(&st, auth(), CARD, "20200101_000000_ffffff", "m-1")
                .await
                .unwrap_err(),
        );
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::NOT_FOUND, "no_such_card")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_file_over_32_kb_is_too_large_and_one_at_the_limit_is_served() {
        let dir = scratch("oversize");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        // 40 KB of well-formed JSON: the size guard answers, not the parser.
        let mut huge = valid_card("Huge");
        huge.push_str(&" ".repeat(MAX_CARD_BYTES as usize));
        write_card(&cwd, CARD, &huge);
        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::PAYLOAD_TOO_LARGE, "too_large")
        );

        // Exactly 32 KB is inside the contract.
        let mut exact = valid_card("Exact");
        let pad = MAX_CARD_BYTES as usize - exact.len();
        exact.push_str(&" ".repeat(pad));
        assert_eq!(exact.len() as u64, MAX_CARD_BYTES);
        write_card(&cwd, CARD, &exact);
        let ok = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("32 KB is allowed");
        assert_eq!(ok.0["card"]["title"], "Exact");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_broken_file_is_bad_card_not_a_card() {
        let dir = scratch("bad-card");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        write_card(&cwd, CARD, "{not json");
        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::UNPROCESSABLE_ENTITY, "bad_card")
        );

        // A bare array is JSON but not a card: the client decodes an object.
        write_card(&cwd, CARD, "[]");
        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::UNPROCESSABLE_ENTITY, "bad_card")
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The whole reason the snapshot exists: the thread is reopened after the bot's working
    /// directory was cleaned, and the card must still draw.
    #[tokio::test]
    async fn a_snapshot_is_served_after_the_file_is_deleted() {
        let dir = scratch("snapshot");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        let path = write_card(&cwd, CARD, &valid_card("Book the cabin"));
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        let first = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("first read");
        let mtime = first.0["mtime"].as_str().unwrap().to_string();
        std::fs::remove_file(&path).unwrap();

        let again = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("from snapshot");
        assert_eq!(again.0["card"]["title"], "Book the cabin");
        assert_eq!(again.0["mtime"], mtime, "the snapshot keeps its own mtime");
        assert_eq!(again.0["final"], false);

        // Two messages naming the same card never share a row: this one was never read, so it has
        // nothing to draw and says so.
        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-2").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::NOT_FOUND, "no_such_card")
        );

        // A deleted file does not erase history either: the session row can go too.
        std::fs::remove_dir_all(st.engine_home.join("profiles")).unwrap();
        let orphan = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("snapshot without a session");
        assert_eq!(orphan.0["card"]["title"], "Book the cabin");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Live polling moves the snapshot forward, so the last state a reader saw is the state a
    /// later reader sees.
    #[tokio::test]
    async fn a_poll_moves_the_snapshot_forward() {
        let dir = scratch("snapshot-forward");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        let path = write_card(&cwd, CARD, &valid_card("Book the cabin"));
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        let _ = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("pending");

        let mut resolved: Value = serde_json::from_str(&valid_card("Book the cabin")).unwrap();
        resolved["resolved"] = json!({"action": "Approve", "at": 1795222533.1});
        std::fs::write(&path, resolved.to_string()).unwrap();

        let polled = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("poll");
        assert_eq!(polled.0["final"], true, "resolved is final");
        assert_eq!(polled.0["card"]["resolved"]["action"], "Approve");

        std::fs::remove_file(&path).unwrap();
        let after = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("snapshot");
        assert_eq!(after.0["final"], true);
        assert_eq!(after.0["card"]["resolved"]["action"], "Approve");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A session with no cwd writes cards beside the profile, which is the settled fallback.
    #[tokio::test]
    async fn a_session_without_a_cwd_uses_the_profile_directory() {
        let dir = scratch("no-cwd");
        let st = state(&dir);
        session_row(&st.engine_home, "cody", SESSION, None);
        let profile_dir = st.engine_home.join("profiles").join("cody");
        write_card(&profile_dir, CARD, &valid_card("Profile card"));

        let ok = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("profile fallback");
        assert_eq!(ok.0["card"]["title"], "Profile card");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The card a short query deserves: one real picture, the number that matters, four facts.
    ///
    /// It has no `status` at all — an infographic is finished the moment it is written — and the
    /// route says so with `final: true`, so nothing ever re-reads it.
    #[tokio::test]
    async fn an_infographic_is_served_and_is_already_final() {
        let dir = scratch("info");
        let (st, cwd) = serve(&dir, "cody");
        write_card(&cwd, CARD, &infographic().to_string());

        let ok = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("served");
        assert_eq!(ok.0["card"]["kind"], "infographic");
        assert_eq!(ok.0["card"]["title"], "Golden Gate Bridge");
        assert_eq!(ok.0["card"]["facts"].as_array().unwrap().len(), 4);
        assert_eq!(ok.0["final"], true, "an infographic is never polled");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The picture is optional: a card about a shop's opening hours still lays out without one.
    #[tokio::test]
    async fn an_infographic_with_no_image_still_serves() {
        let dir = scratch("info-no-image");
        let (st, cwd) = serve(&dir, "cody");
        let mut card = infographic();
        card.as_object_mut().unwrap().remove("image");
        card.as_object_mut().unwrap().remove("imageCaption");
        write_card(&cwd, CARD, &card.to_string());

        let ok = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("served");
        assert!(ok.0["card"].get("image").is_none());
        assert_eq!(ok.0["card"]["title"], "Golden Gate Bridge");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Every refusal names the field, because the bot that wrote the file is the one who fixes it.
    #[tokio::test]
    async fn a_field_outside_its_bound_is_refused_by_name() {
        let dir = scratch("info-fields");
        let (st, cwd) = serve(&dir, "cody");

        let cases: Vec<(&str, Value, &str)> = vec![
            (
                "title",
                {
                    let mut card = infographic();
                    card["title"] = json!("t".repeat(MAX_INFO_TITLE + 1));
                    card
                },
                "title must be 1-120 characters",
            ),
            (
                "title-missing",
                {
                    let mut card = infographic();
                    card.as_object_mut().unwrap().remove("title");
                    card
                },
                "title must be 1-120 characters",
            ),
            (
                "facts-too-few",
                {
                    let mut card = infographic();
                    card["facts"] = json!([
                        { "label": "Opened", "value": "1937" },
                        { "label": "Length", "value": "2,737 m" }
                    ]);
                    card
                },
                "facts must hold 3-8 entries, not 2",
            ),
            (
                "facts-too-many",
                {
                    let mut card = infographic();
                    card["facts"] = json!(vec![
                        json!({ "label": "L", "value": "v" });
                        MAX_INFO_FACTS + 1
                    ]);
                    card
                },
                "facts must hold 3-8 entries, not 9",
            ),
            (
                "fact-value",
                {
                    let mut card = infographic();
                    card["facts"][1]["value"] = json!("v".repeat(MAX_INFO_FACT_VALUE + 1));
                    card
                },
                "facts[1].value must be 1-80 characters",
            ),
            (
                "highlight-seller",
                {
                    let mut card = infographic();
                    card["highlight"]["seller"] = json!("s".repeat(MAX_INFO_ASIDE + 1));
                    card
                },
                "highlight.seller must be at most 60 characters",
            ),
            (
                "source",
                {
                    let mut card = infographic();
                    card["source"] = json!("s".repeat(MAX_INFO_SOURCE + 1));
                    card
                },
                "source must be at most 80 characters",
            ),
            (
                "link",
                {
                    let mut card = infographic();
                    card["link"]["url"] = json!("example.com/nowhere");
                    card
                },
                "link.url must be an http(s) URL",
            ),
        ];

        for (name, card, expected) in cases {
            write_card(&cwd, CARD, &card.to_string());
            let (status, body) = fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err();
            let code = body
                .0
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("<none>")
                .to_string();
            let detail = body
                .0
                .get("detail")
                .and_then(Value::as_str)
                .unwrap_or("<none>")
                .to_string();
            assert_eq!(
                (status, code.as_str()),
                (StatusCode::UNPROCESSABLE_ENTITY, "bad_card"),
                "{name}"
            );
            assert!(detail.contains(expected), "{name}: {detail}");
            assert!(detail.contains("infographic card"), "{name}: {detail}");
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An image is a URL, and only a scheme a client can actually load.
    #[tokio::test]
    async fn an_image_that_is_not_http_is_refused() {
        let dir = scratch("info-image");
        let (st, cwd) = serve(&dir, "cody");

        for url in [
            "file:///etc/passwd",
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            "//example.com/a.jpg",
            "example.com/a.jpg",
            "http://",
            "https://exa mple.com/a.jpg",
        ] {
            let mut card = infographic();
            card["image"] = json!(url);
            write_card(&cwd, CARD, &card.to_string());
            let refused = fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err();
            assert_eq!(refused.0, StatusCode::UNPROCESSABLE_ENTITY, "{url}");
            assert!(
                err_detail(refused).contains("image must be an http(s) URL"),
                "{url}"
            );
        }

        // …and a URL that is only too long is told so, rather than called a bad scheme.
        let mut card = infographic();
        card["image"] = json!(format!("https://example.com/{}", "a".repeat(MAX_CARD_URL)));
        write_card(&cwd, CARD, &card.to_string());
        let detail = err_detail(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert!(
            detail.contains("image must be at most 2048 characters"),
            "{detail}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A caption with no picture is a claim about something the card does not show.
    #[tokio::test]
    async fn a_caption_without_an_image_is_refused() {
        let dir = scratch("info-caption");
        let (st, cwd) = serve(&dir, "cody");
        let mut card = infographic();
        card.as_object_mut().unwrap().remove("image");
        write_card(&cwd, CARD, &card.to_string());

        let detail = err_detail(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert!(detail.contains("imageCaption needs an image"), "{detail}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A product: the price is the highlight, and the seller and availability ride with it.
    #[tokio::test]
    async fn a_product_infographic_carries_price_seller_and_availability() {
        let dir = scratch("info-product");
        let (st, cwd) = serve(&dir, "cody");
        let card = json!({
            "schema": "card.v1",
            "kind": "infographic",
            "title": "Anker 737 Power Bank",
            "subtitle": "24,000 mAh, 140 W",
            "image": "https://example.com/anker-737.jpg",
            "imageCaption": "Front and side",
            "highlight": {
                "label": "Price",
                "value": "€ 129.99",
                "seller": "Sold by Anker Direct DE",
                "availability": "In stock"
            },
            "facts": [
                { "label": "Capacity", "value": "24,000 mAh" },
                { "label": "Output", "value": "140 W" },
                { "label": "Ports", "value": "2 × USB-C, 1 × USB-A" }
            ],
            "link": { "label": "Open on amazon.de", "url": "https://example.com/dp/B0B4Q1KZ2F" },
            "source": "amazon.de · checked just now"
        });
        write_card(&cwd, CARD, &card.to_string());

        let ok = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("served");
        assert_eq!(ok.0["card"]["highlight"]["value"], "€ 129.99");
        assert_eq!(
            ok.0["card"]["highlight"]["seller"],
            "Sold by Anker Direct DE"
        );
        assert_eq!(ok.0["card"]["highlight"]["availability"], "In stock");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The other kinds are untouched: their schema is the client's, and this route still serves an
    /// approval card that has no facts at all.
    #[tokio::test]
    async fn another_kind_is_not_held_to_the_infographic_schema() {
        let dir = scratch("info-other-kind");
        let (st, cwd) = serve(&dir, "cody");
        write_card(&cwd, CARD, &valid_card("Book the cabin"));

        let ok = fetch(&st, auth(), CARD, SESSION, "m-1")
            .await
            .expect("served");
        assert_eq!(ok.0["card"]["kind"], "approval");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A refused card is not a read: nothing is snapshotted, so a deleted file has nothing to draw
    /// and a fixed file is what the next reader gets.
    #[tokio::test]
    async fn a_refused_infographic_is_never_snapshotted() {
        let dir = scratch("info-snapshot");
        let (st, cwd) = serve(&dir, "cody");
        let mut broken = infographic();
        broken["title"] = json!("t".repeat(MAX_INFO_TITLE + 1));
        let path = write_card(&cwd, CARD, &broken.to_string());

        let _ = fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err();
        std::fs::remove_file(&path).unwrap();
        let (status, code) = err_code(fetch(&st, auth(), CARD, SESSION, "m-1").await.unwrap_err());
        assert_eq!(
            (status, code.as_str()),
            (StatusCode::NOT_FOUND, "no_such_card"),
            "a refused card left no snapshot behind"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn http_urls_are_the_only_scheme_an_image_may_name() {
        assert!(is_http_url("https://upload.wikimedia.org/a.jpg"));
        assert!(is_http_url("http://example.com/a.jpg?w=800"));
        assert!(is_http_url("HTTPS://EXAMPLE.COM/a.jpg"));
        assert!(is_http_url("https://localhost:8080/a.jpg"));
        assert!(!is_http_url("file:///etc/passwd"));
        assert!(!is_http_url("data:image/png;base64,AAAA"));
        assert!(!is_http_url("javascript:alert(1)"));
        assert!(!is_http_url("//example.com/a.jpg"));
        assert!(!is_http_url("example.com/a.jpg"));
        assert!(!is_http_url("https://"));
        assert!(!is_http_url("https:///a.jpg"));
        assert!(!is_http_url("https://user:pass@example.com/a.jpg"));
        assert!(!is_http_url("https://example.com/a b.jpg"));
        assert!(!is_http_url(&format!(
            "https://example.com/{}",
            "a".repeat(MAX_CARD_URL)
        )));
    }

    /// Only `done`/`error`/`resolved` stop the poll: an approval is exactly what must keep polling.
    #[test]
    fn final_follows_the_skills_stop_rule() {
        let card = |state: &str, resolved: Value| json!({"status": {"state": state}, "resolved": resolved});
        assert!(!is_final(&card("awaiting-approval", Value::Null)));
        assert!(!is_final(&card("pending", Value::Null)));
        assert!(!is_final(&card("running", Value::Null)));
        assert!(is_final(&card("done", Value::Null)));
        assert!(is_final(&card("error", Value::Null)));
        assert!(is_final(&card(
            "awaiting-approval",
            json!({"action": "Approve"})
        )));
        // A card without a status object is the client's problem, not a final one.
        assert!(!is_final(&json!({"title": "x"})));
        // An infographic is a still picture of an answer: final without a status at all.
        assert!(is_final(
            &json!({"kind": "infographic", "title": "Golden Gate Bridge"})
        ));
    }

    #[test]
    fn iso8601_renders_a_known_instant() {
        assert_eq!(
            iso8601(UNIX_EPOCH + Duration::from_millis(1_795_222_346_120)),
            "2026-11-21T00:52:26.120Z"
        );
        assert_eq!(iso8601(UNIX_EPOCH), "1970-01-01T00:00:00.000Z");
        // A leap day, so the civil conversion is not just "day 1 of every month".
        assert_eq!(
            iso8601(UNIX_EPOCH + Duration::from_secs(1_709_164_800)),
            "2024-02-29T00:00:00.000Z"
        );
    }

    /// The real router, because a percent-encoded `..` is decoded by axum before the handler sees
    /// it. This is the attack the id guard exists for, so it is exercised through HTTP.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_percent_encoded_traversal_is_refused_by_the_mounted_route() {
        let dir = scratch("http");
        let st = state(&dir);
        let cwd = dir.join("bot-cwd");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::write(dir.join("secret.json"), valid_card("Leaked")).unwrap();
        session_row(&st.engine_home, "cody", SESSION, Some(&cwd));

        let app = axum::Router::new()
            .route("/v1/cards/{card_id}", axum::routing::get(get_card))
            .with_state(Arc::clone(&st));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let client = reqwest::Client::new();
        let response = client
            .get(format!(
                "http://{addr}/v1/cards/..%2F..%2Fsecret.json?session={SESSION}&message=m-1"
            ))
            .header("authorization", format!("Bearer {LOCAL}"))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body: Value = response.json().await.unwrap();
        assert_eq!(body["error"], "bad_id");

        // The same route answers for a real card, so the refusal above is the guard, not a 404 for
        // a route that was never mounted.
        write_card(&cwd, CARD, &valid_card("Book the cabin"));
        let response = client
            .get(format!(
                "http://{addr}/v1/cards/{CARD}?session={SESSION}&message=m-1"
            ))
            .header("authorization", format!("Bearer {LOCAL}"))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body: Value = response.json().await.unwrap();
        assert_eq!(body["card"]["title"], "Book the cabin");

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
