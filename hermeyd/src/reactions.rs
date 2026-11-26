//! Reactions: one emoji per message, per conversation, agreed by every device that opens it.
//!
//! The two apps used to keep reactions in device-local `@AppStorage`, so the Mac's menu offered to
//! remove a "**local** reaction" and the phone never saw it. The host is the only place two devices
//! can meet, so it owns them now:
//!
//! ```text
//! GET /v1/reactions?bot=<profile>&session=<session id>
//!   -> 200 {"reactions": {"row:41": {"emoji": "👍", "by": "Mo's Mac"}}}
//!
//! PUT /v1/reactions
//!   {"bot":"cody","session":"20261123_101500_ab12cd","message":"row:41",
//!    "emoji":"👍","by":"Mo's Mac"}
//!   -> 200 {"message":"row:41","emoji":"👍","by":"Mo's Mac","at":1795…}
//!   an empty `emoji` removes it -> 200 {"message":"row:41","emoji":null,…}
//!   -> 422 {"error":"bad_message"|"bad_emoji"|"bad_bot"|"bad_session"|"bad_by", "detail":…}
//! ```
//!
//! **The key.** A reaction belongs to `(bot, session, message)` where `message` is the apps' own
//! message key — `row:<rowID>` for a row the host persisted, `live:<entry.id>` for one it has not.
//! That is the same token both apps already compute for `TranscriptRowView.reactionKey` /
//! `MobileTranscript.reactionKey`; the host scopes it by bot and session (which are in the query),
//! and the apps prepend their own host label when they key their in-memory map. The host therefore
//! never has to know a device's label for the *host*, which is what lets a Mac called `casa` and a
//! phone label that disagrees still see the same reaction.
//!
//! One emoji per message, and a new one replaces the old — exactly what both apps do today, so a
//! second device reacting to the same message is an update rather than a second badge.
//!
//! **Storage** is one JSON document in the hermeyd state directory (`reactions.json`), written
//! atomically (temp file, then rename) and capped at [`MAX_REACTIONS`] entries across every
//! conversation, oldest evicted first. No database: this is a handful of bytes per message, and the
//! same file is what an operator can read, back up, or delete to clear every badge.
//!
//! **Live** changes are broadcast to every open `/v1/ws` socket as the engine's own event envelope
//! (`{"jsonrpc":"2.0","method":"event","params":{"type":"reaction.updated",…}}`), so both apps apply
//! a change the moment either device makes it. The frame is built by [`frame`] and published through
//! `relay::Registry`, which is the one place that knows every live app socket.

use crate::routes::{require_device, AppState};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

type Fail = (StatusCode, Json<Value>);

/// The whole store's ceiling. A reaction is ~100 bytes, so this is a few hundred KB on disk; past it
/// the oldest entry goes, because a badge on a message nobody has opened in a year is not worth an
/// unbounded file.
pub const MAX_REACTIONS: usize = 5_000;

/// A reaction is one emoji. Eight bytes is generous for a single glyph (`❤️` is six: U+2764 + VS16)
/// and still refuses a sentence pasted into the field.
const MAX_EMOJI_BYTES: usize = 8;

/// `row:`/`live:` + the id the app already carries. Long enough for any row id or entry id, short
/// enough that the map cannot be used as storage.
const MAX_MESSAGE_LEN: usize = 160;

/// The ceiling `bot_sessions.rs` and `cards.rs` use for the same value.
const MAX_SESSION_LEN: usize = 128;

/// A device name, for "who reacted". A person's Mac is called something a person typed.
const MAX_BY_CHARS: usize = 64;

/// The two prefixes the apps' message keys use. Anything else is not a message this host can place:
/// `row:` is a persisted transcript row, `live:` a row that has no host id yet.
const MESSAGE_PREFIXES: [&str; 2] = ["row:", "live:"];

// ---------------------------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------------------------

/// One reaction, as it lives on disk and in memory.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub bot: String,
    pub session: String,
    /// `row:<rowID>` or `live:<entry.id>` — the apps' message key.
    pub message: String,
    pub emoji: String,
    /// The device that set it, as it named itself. Shown on the other device's badge.
    pub by: String,
    /// Unix seconds, so the cap evicts by age rather than by file order.
    #[serde(default)]
    pub at: f64,
}

fn document_version() -> u32 {
    1
}

#[derive(Serialize, Deserialize)]
struct Document {
    #[serde(default = "document_version")]
    version: u32,
    #[serde(default)]
    reactions: Vec<Entry>,
}

struct Mem {
    loaded: bool,
    entries: VecDeque<Entry>,
}

/// The one store. Held in `AppState`, so every route shares one in-memory copy and one file.
pub struct Registry {
    path: PathBuf,
    inner: Mutex<Mem>,
}

impl Registry {
    /// `dir` is hermeyd's state directory: `reactions.json` lives beside `bridge.db`.
    pub fn in_dir(dir: impl Into<PathBuf>) -> Self {
        Self {
            path: dir.into().join("reactions.json"),
            inner: Mutex::new(Mem { loaded: false, entries: VecDeque::new() }),
        }
    }

    /// Every reaction in one conversation, in the order they were set. Only that bot+session: a
    /// reaction is not a fact about any other conversation, and returning it would make one bot's
    /// badge appear in another's transcript.
    pub fn conversation(&self, bot: &str, session: &str) -> Vec<Entry> {
        let mem = self.load();
        mem.entries
            .iter()
            .filter(|e| e.bot == bot && e.session == session)
            .cloned()
            .collect()
    }

    /// Set one reaction, or clear it when `emoji` is `None`. A message carries at most one.
    ///
    /// The file is written *before* the in-memory copy moves: a write that fails leaves the answer
    /// the caller gets (a 500) and the state they can read agreeing with each other, instead of a
    /// reaction that is live on the socket and gone after a restart.
    pub fn record(&self, bot: &str, session: &str, message: &str, emoji: Option<&str>, by: &str, at: f64) -> std::io::Result<()> {
        let mut mem = self.load();
        let mut next: VecDeque<Entry> = mem
            .entries
            .iter()
            .filter(|e| !(e.bot == bot && e.session == session && e.message == message))
            .cloned()
            .collect();
        if let Some(emoji) = emoji {
            next.push_back(Entry {
                bot: bot.to_string(),
                session: session.to_string(),
                message: message.to_string(),
                emoji: emoji.to_string(),
                by: by.to_string(),
                at,
            });
            while next.len() > MAX_REACTIONS {
                next.pop_front();
            }
        }
        write_document(&self.path, &next)?;
        mem.entries = next;
        Ok(())
    }

    fn load(&self) -> MutexGuard<'_, Mem> {
        let mut mem = lock(&self.inner);
        if !mem.loaded {
            mem.entries = read_document(&self.path).into_iter().collect();
            mem.loaded = true;
        }
        mem
    }
}

/// A panic while holding the lock must not wedge every later reaction for the life of the service.
fn lock(inner: &Mutex<Mem>) -> MutexGuard<'_, Mem> {
    inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A missing or unreadable document is an empty store, not an error: the first write recreates it.
/// A *corrupt* one is reported once on stderr and then treated the same way — refusing every write
/// would leave the owner with two apps that can never agree again and no way to see why.
fn read_document(path: &Path) -> Vec<Entry> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    match serde_json::from_str::<Document>(&text) {
        Ok(document) => {
            let mut entries: VecDeque<Entry> = document.reactions.into_iter().collect();
            while entries.len() > MAX_REACTIONS {
                entries.pop_front();
            }
            entries.into()
        }
        Err(err) => {
            eprintln!("reactions: ignoring an unreadable {}: {err}", path.display());
            Vec::new()
        }
    }
}

/// Temp file, then rename: a reader (or a crash) never sees half a document.
fn write_document(path: &Path, entries: &VecDeque<Entry>) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let document = Document {
        version: document_version(),
        reactions: entries.iter().cloned().collect(),
    };
    let text = serde_json::to_string(&document).unwrap_or_else(|_| "{\"version\":1,\"reactions\":[]}".to_string());
    let temp = path.with_extension(format!("json.tmp-{}", std::process::id()));
    std::fs::write(&temp, text)?;
    std::fs::rename(&temp, path)
}

// ---------------------------------------------------------------------------------------------
// Validation (pure, so every refusal is testable without a socket)
// ---------------------------------------------------------------------------------------------

fn bad(status: StatusCode, code: &str, detail: impl Into<String>) -> Fail {
    (status, Json(json!({ "error": code, "detail": detail.into() })))
}

fn invalid(code: &str, detail: &str) -> Fail {
    bad(StatusCode::UNPROCESSABLE_ENTITY, code, detail)
}

/// `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` — a Hermes profile name. Never a path.
pub fn valid_bot(bot: &str) -> bool {
    match bot.as_bytes().first() {
        Some(first) if first.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    bot.len() <= 64
        && bot
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}

/// `[A-Za-z0-9_-]{1,128}` — the shape `cards.rs` and `bot_sessions.rs` accept for a session id.
pub fn valid_session(session: &str) -> bool {
    !session.is_empty()
        && session.len() <= MAX_SESSION_LEN
        && session
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// A message key: `row:` or `live:` and then the id the app already carries.
///
/// The id is deliberately permissive (`:` and `.` included, because a tool call id and a live entry
/// id both appear here) but bounded and free of control characters and whitespace — this value is
/// only ever a map key, and a key that cannot be typed is a bug in the caller, not a message.
pub fn valid_message(message: &str) -> bool {
    if message.is_empty() || message.len() > MAX_MESSAGE_LEN {
        return false;
    }
    let Some(rest) = MESSAGE_PREFIXES
        .iter()
        .find_map(|prefix| message.strip_prefix(prefix))
    else {
        return false;
    };
    !rest.is_empty()
        && rest
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':'))
}

/// One emoji, 1–8 bytes. An empty string is not an emoji: removal is `None`, and the route turns an
/// empty field into that, so this is the check for a value that is meant to be shown.
pub fn valid_emoji(emoji: &str) -> bool {
    !emoji.is_empty() && emoji.len() <= MAX_EMOJI_BYTES
}

/// "Who reacted": a device's own name. Printable, no control characters, bounded.
pub fn valid_by(by: &str) -> bool {
    let trimmed = by.trim();
    !trimmed.is_empty()
        && trimmed.chars().count() <= MAX_BY_CHARS
        && !trimmed.chars().any(|c| c.is_control())
}

// ---------------------------------------------------------------------------------------------
// The routes
// ---------------------------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct GetQuery {
    #[serde(default)]
    pub bot: String,
    #[serde(default)]
    pub session: String,
}

#[derive(Deserialize)]
pub struct PutBody {
    #[serde(default)]
    pub bot: String,
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub message: String,
    /// Empty (or absent) removes the reaction.
    #[serde(default)]
    pub emoji: String,
    #[serde(default)]
    pub by: String,
}

/// What one `PUT` means once it has been validated. Pure, so the status codes are decided in one
/// place and the handler below is only plumbing.
#[derive(Debug, PartialEq)]
pub struct Plan {
    pub bot: String,
    pub session: String,
    pub message: String,
    /// `None` removes.
    pub emoji: Option<String>,
    pub by: String,
}

pub fn plan_put(body: &PutBody) -> Result<Plan, Fail> {
    if !valid_bot(&body.bot) {
        return Err(invalid("bad_bot", "bot must be a profile name"));
    }
    if !valid_session(&body.session) {
        return Err(invalid("bad_session", "session must be 1-128 characters of [A-Za-z0-9_-]"));
    }
    if !valid_message(&body.message) {
        return Err(invalid(
            "bad_message",
            "message must start with row: or live: and carry a bounded id",
        ));
    }
    if body.emoji.is_empty() {
        // Removal: `by` still names the device that cleared it, because the other device's badge
        // disappears either way and the log is the only place that can say who did it.
    } else if !valid_emoji(&body.emoji) {
        return Err(invalid("bad_emoji", "emoji must be 1-8 bytes"));
    }
    if !valid_by(&body.by) {
        return Err(invalid("bad_by", "by must be a device name of at most 64 characters"));
    }
    Ok(Plan {
        bot: body.bot.clone(),
        session: body.session.clone(),
        message: body.message.clone(),
        emoji: if body.emoji.is_empty() { None } else { Some(body.emoji.clone()) },
        by: body.by.trim().to_string(),
    })
}

/// The frame every open app socket receives. Shaped exactly like an engine event — `method:"event"`,
/// the real name in `params.type`, the body in `params.payload` — because that is the envelope both
/// apps already decode, and a second shape would need a second decoder.
pub fn frame(bot: &str, session: &str, message: &str, emoji: Option<&str>, by: &str) -> String {
    json!({
        "jsonrpc": "2.0",
        "method": "event",
        "params": {
            "type": "reaction.updated",
            "session_id": session,
            "payload": {
                "bot": bot,
                "session": session,
                "message": message,
                "emoji": emoji,
                "by": by,
            },
        },
    })
    .to_string()
}

/// `GET /v1/reactions?bot=<profile>&session=<session id>`
pub async fn get_reactions(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<GetQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_bot(&q.bot) {
        return Err(invalid("bad_bot", "bot must be a profile name"));
    }
    if !valid_session(&q.session) {
        return Err(invalid("bad_session", "session must be 1-128 characters of [A-Za-z0-9_-]"));
    }
    let mut reactions = Map::new();
    for entry in st.reactions.conversation(&q.bot, &q.session) {
        reactions.insert(
            entry.message,
            json!({ "emoji": entry.emoji, "by": entry.by }),
        );
    }
    Ok(Json(json!({ "reactions": reactions })))
}

/// `PUT /v1/reactions` — set or clear one reaction, then tell every open socket.
pub async fn put_reaction(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<PutBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let plan = plan_put(&body)?;
    let at = crate::pairing::now();
    st.reactions
        .record(&plan.bot, &plan.session, &plan.message, plan.emoji.as_deref(), &plan.by, at)
        .map_err(|err| {
            bad(
                StatusCode::INTERNAL_SERVER_ERROR,
                "unwritable",
                format!("cannot store the reaction: {err}"),
            )
        })?;

    // After the write, so a device that sees the event and reloads finds the same value. Publishing
    // first would let the other app's reload answer with the old one.
    let _ = st.relay_sockets.publish(frame(
        &plan.bot,
        &plan.session,
        &plan.message,
        plan.emoji.as_deref(),
        &plan.by,
    ));

    Ok(Json(json!({
        "message": plan.message,
        "emoji": plan.emoji,
        "by": plan.by,
        "at": at,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{RateLimiter, Tickets};
    use crate::display::DisplayHub;
    use crate::pairing::Pairing;
    use crate::store::Store;
    use std::time::{SystemTime, UNIX_EPOCH};

    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";
    const BOT: &str = "cody";
    const SESSION: &str = "20261123_101500_ab12cd";

    fn scratch(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-reactions-{tag}-{}-{nanos}",
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
            limiter: RateLimiter::new(30, 60.0),
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
            display: DisplayHub::spawn(engine_ws, Some(token_file)),
            relay_sockets: Default::default(),
            reactions: Registry::in_dir(dir),
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

    fn get_q(bot: &str, session: &str) -> GetQuery {
        GetQuery { bot: bot.to_string(), session: session.to_string() }
    }

    fn put_body(bot: &str, session: &str, message: &str, emoji: &str, by: &str) -> PutBody {
        PutBody {
            bot: bot.to_string(),
            session: session.to_string(),
            message: message.to_string(),
            emoji: emoji.to_string(),
            by: by.to_string(),
        }
    }

    /// The map the route answers with, read back through the same door the apps use.
    fn reactions_of(value: &Value) -> Vec<(String, String, String)> {
        value["reactions"]
            .as_object()
            .map(|map| {
                map.iter()
                    .map(|(message, row)| {
                        (
                            message.clone(),
                            row["emoji"].as_str().unwrap_or("").to_string(),
                            row["by"].as_str().unwrap_or("").to_string(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn a_reaction_is_put_read_and_replaced() {
        let dir = scratch("put");
        let st = state(&dir);

        put_reaction(
            State(Arc::clone(&st)),
            auth(),
            Json(put_body(BOT, SESSION, "row:41", "👍", "Mo's Mac")),
        )
        .await
        .expect("stored");

        let read = get_reactions(State(Arc::clone(&st)), auth(), Query(get_q(BOT, SESSION)))
            .await
            .expect("read");
        assert_eq!(
            reactions_of(&read.0),
            vec![("row:41".to_string(), "👍".to_string(), "Mo's Mac".to_string())]
        );

        // A second device reacting replaces rather than adding: one message, one emoji.
        put_reaction(
            State(Arc::clone(&st)),
            auth(),
            Json(put_body(BOT, SESSION, "row:41", "🎉", "iPhone")),
        )
        .await
        .expect("replaced");
        let read = get_reactions(State(Arc::clone(&st)), auth(), Query(get_q(BOT, SESSION)))
            .await
            .expect("read");
        assert_eq!(
            reactions_of(&read.0),
            vec![("row:41".to_string(), "🎉".to_string(), "iPhone".to_string())]
        );

        // An empty emoji removes it.
        let removed = put_reaction(
            State(Arc::clone(&st)),
            auth(),
            Json(put_body(BOT, SESSION, "row:41", "", "Mo's Mac")),
        )
        .await
        .expect("removed");
        assert_eq!(removed.0["emoji"], Value::Null);
        let read = get_reactions(State(Arc::clone(&st)), auth(), Query(get_q(BOT, SESSION)))
            .await
            .expect("read");
        assert!(reactions_of(&read.0).is_empty(), "a cleared reaction is gone");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn each_bot_and_session_keeps_its_own_reactions() {
        let dir = scratch("isolation");
        let st = state(&dir);

        for (bot, session, message) in [
            ("cody", SESSION, "row:1"),
            ("cody", "20261123_110000_ffffff", "row:1"),
            ("ops", SESSION, "row:1"),
        ] {
            put_reaction(
                State(Arc::clone(&st)),
                auth(),
                Json(put_body(bot, session, message, "👍", "Mo's Mac")),
            )
            .await
            .expect("stored");
        }

        let cody = get_reactions(State(Arc::clone(&st)), auth(), Query(get_q("cody", SESSION)))
            .await
            .expect("read");
        assert_eq!(reactions_of(&cody.0).len(), 1, "another session's row leaked in");

        let other_session =
            get_reactions(State(Arc::clone(&st)), auth(), Query(get_q("cody", "20261123_110000_ffffff")))
                .await
                .expect("read");
        assert_eq!(reactions_of(&other_session.0).len(), 1);

        let ops = get_reactions(State(Arc::clone(&st)), auth(), Query(get_q("ops", SESSION)))
            .await
            .expect("read");
        assert_eq!(reactions_of(&ops.0).len(), 1, "another bot's row leaked in");

        // A conversation nobody has reacted in answers with an empty map, not a 404.
        let empty = get_reactions(
            State(Arc::clone(&st)),
            auth(),
            Query(get_q("aria", "20260101_000000_aaaaaa")),
        )
        .await
        .expect("an empty answer is an answer");
        assert_eq!(empty.0["reactions"].as_object().map(|m| m.len()), Some(0));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Both apps' keys are `row:<rowID>` / `live:<entry.id>`; anything else is refused before it
    /// becomes a key in the store.
    #[test]
    fn only_row_and_live_message_keys_are_accepted() {
        for good in ["row:41", "row:0", "live:r12", "live:user-3", "live:tcall_abc.1"] {
            assert!(valid_message(good), "{good}");
        }
        for bad in [
            "",
            "41",
            "row:",
            "live:",
            "msg:41",
            "row:41\n",
            "row:../../etc/passwd",
            "row:with space",
            "row:41/..",
            "ROW:41",
        ] {
            assert!(!valid_message(bad), "{bad:?}");
        }
        assert!(!valid_message(&format!("row:{}", "a".repeat(MAX_MESSAGE_LEN))), "over length");
    }

    #[test]
    fn an_emoji_is_one_short_glyph_and_a_device_name_is_printable() {
        assert!(valid_emoji("👍"));
        assert!(valid_emoji("❤️"), "six bytes, and it is one emoji");
        assert!(!valid_emoji(""));
        assert!(!valid_emoji("👍👍👍"), "three glyphs is not a reaction");
        assert!(!valid_emoji(&"a".repeat(MAX_EMOJI_BYTES + 1)));

        assert!(valid_by("Mo's Mac"));
        assert!(valid_by("iPhone"));
        assert!(!valid_by(""));
        assert!(!valid_by("   "));
        assert!(!valid_by("a\nb"));
        assert!(!valid_by(&"a".repeat(MAX_BY_CHARS + 1)));
    }

    #[test]
    fn profiles_and_sessions_are_the_shapes_the_other_routes_accept() {
        assert!(valid_bot("cody"));
        assert!(valid_bot("cody.v2-bot"));
        assert!(!valid_bot(""));
        assert!(!valid_bot("../ops"));
        assert!(!valid_bot("-ops"));
        assert!(!valid_bot("a b"));
        assert!(!valid_bot(&"a".repeat(65)));

        assert!(valid_session(SESSION));
        assert!(!valid_session(""));
        assert!(!valid_session("a b"));
        assert!(!valid_session(&"a".repeat(MAX_SESSION_LEN + 1)));
    }

    #[tokio::test]
    async fn every_bad_field_is_a_422_with_its_own_code() {
        let dir = scratch("refusals");
        let st = state(&dir);

        let cases: [(&str, PutBody); 6] = [
            ("bad_bot", put_body("../ops", SESSION, "row:1", "👍", "Mac")),
            ("bad_session", put_body(BOT, "a b", "row:1", "👍", "Mac")),
            ("bad_message", put_body(BOT, SESSION, "41", "👍", "Mac")),
            ("bad_message", put_body(BOT, SESSION, "live:", "👍", "Mac")),
            ("bad_emoji", put_body(BOT, SESSION, "row:1", "👍👍👍", "Mac")),
            ("bad_by", put_body(BOT, SESSION, "row:1", "👍", "")),
        ];
        for (code, body) in cases {
            let (status, payload) = put_reaction(State(Arc::clone(&st)), auth(), Json(body))
                .await
                .unwrap_err();
            assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{code}");
            assert_eq!(payload.0["error"], code);
        }

        let (status, payload) = get_reactions(
            State(Arc::clone(&st)),
            auth(),
            Query(get_q("../ops", SESSION)),
        )
        .await
        .unwrap_err();
        assert_eq!((status, payload.0["error"].as_str()), (StatusCode::UNPROCESSABLE_ENTITY, Some("bad_bot")));

        // Nothing above was stored: a refused request must not leave a row behind.
        let read = get_reactions(State(Arc::clone(&st)), auth(), Query(get_q(BOT, SESSION)))
            .await
            .expect("read");
        assert!(reactions_of(&read.0).is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_request_without_a_device_bearer_is_refused() {
        let dir = scratch("auth");
        let st = state(&dir);
        let refused = get_reactions(State(Arc::clone(&st)), HeaderMap::new(), Query(get_q(BOT, SESSION)))
            .await
            .unwrap_err();
        assert_eq!(refused.0, StatusCode::UNAUTHORIZED);

        let refused = put_reaction(
            State(Arc::clone(&st)),
            HeaderMap::new(),
            Json(put_body(BOT, SESSION, "row:1", "👍", "Mac")),
        )
        .await
        .unwrap_err();
        assert_eq!(refused.0, StatusCode::UNAUTHORIZED);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Persistence is the whole point: a restart must not lose the two devices' agreement.
    #[tokio::test]
    async fn the_store_survives_a_reopen_and_lives_in_one_atomic_file() {
        let dir = scratch("persist");
        {
            let st = state(&dir);
            put_reaction(
                State(Arc::clone(&st)),
                auth(),
                Json(put_body(BOT, SESSION, "row:41", "👍", "Mo's Mac")),
            )
            .await
            .expect("stored");
        }

        let reopened = Registry::in_dir(&dir);
        let entries = reopened.conversation(BOT, SESSION);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].emoji, "👍");
        assert_eq!(entries[0].by, "Mo's Mac");

        // One file, and no temp file left beside it.
        let names: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|name| name.starts_with("reactions"))
            .collect();
        assert_eq!(names, vec!["reactions.json".to_string()], "{names:?}");
        let raw: Value = serde_json::from_str(&std::fs::read_to_string(&dir.join("reactions.json")).unwrap()).unwrap();
        assert_eq!(raw["version"], 1);
        assert_eq!(raw["reactions"].as_array().map(|a| a.len()), Some(1));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A file that cannot be parsed must not turn every later reaction into a 500.
    #[tokio::test]
    async fn a_corrupt_document_is_ignored_and_the_next_write_replaces_it() {
        let dir = scratch("corrupt");
        std::fs::write(dir.join("reactions.json"), "{not json").unwrap();
        let st = state(&dir);

        put_reaction(
            State(Arc::clone(&st)),
            auth(),
            Json(put_body(BOT, SESSION, "row:1", "👍", "Mac")),
        )
        .await
        .expect("a corrupt file is not a refusal");

        let read = get_reactions(State(Arc::clone(&st)), auth(), Query(get_q(BOT, SESSION)))
            .await
            .expect("read");
        assert_eq!(reactions_of(&read.0).len(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The cap: the file cannot grow without bound, and what goes is the oldest.
    #[tokio::test]
    async fn the_store_is_capped_and_evicts_the_oldest() {
        let dir = scratch("cap");
        // Seeded in one write: the invariant under test is the eviction, not 5 000 round trips.
        let seeded: VecDeque<Entry> = (0..MAX_REACTIONS)
            .map(|i| Entry {
                bot: BOT.to_string(),
                session: SESSION.to_string(),
                message: format!("row:{i}"),
                emoji: "👍".to_string(),
                by: "Mac".to_string(),
                at: i as f64,
            })
            .collect();
        write_document(&dir.join("reactions.json"), &seeded).expect("seeded");
        let registry = Registry::in_dir(&dir);
        assert_eq!(registry.conversation(BOT, SESSION).len(), MAX_REACTIONS, "the store loaded full");

        for i in MAX_REACTIONS..(MAX_REACTIONS + 3) {
            registry
                .record(BOT, SESSION, &format!("row:{i}"), Some("👍"), "Mac", i as f64)
                .expect("stored");
        }

        let entries = registry.conversation(BOT, SESSION);
        assert_eq!(entries.len(), MAX_REACTIONS, "the file does not grow past the cap");
        assert_eq!(entries.first().map(|e| e.message.as_str()), Some("row:3"), "the oldest three went");
        let newest = format!("row:{}", MAX_REACTIONS + 2);
        assert_eq!(entries.last().map(|e| e.message.as_str()), Some(newest.as_str()));

        // And the file says the same thing, so a restart cannot resurrect what was evicted.
        let reopened = Registry::in_dir(&dir);
        assert_eq!(reopened.conversation(BOT, SESSION).len(), MAX_REACTIONS);
        assert!(reopened.conversation(BOT, SESSION).iter().all(|e| e.message != "row:0"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The frame is the engine's envelope, because that is the one both apps already decode.
    #[test]
    fn the_broadcast_frame_is_the_engine_event_envelope() {
        let text = frame(BOT, SESSION, "row:41", Some("👍"), "Mo's Mac");
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["method"], "event");
        assert_eq!(value["params"]["type"], "reaction.updated");
        assert_eq!(value["params"]["session_id"], SESSION);
        assert_eq!(value["params"]["payload"]["bot"], BOT);
        assert_eq!(value["params"]["payload"]["session"], SESSION);
        assert_eq!(value["params"]["payload"]["message"], "row:41");
        assert_eq!(value["params"]["payload"]["emoji"], "👍");
        assert_eq!(value["params"]["payload"]["by"], "Mo's Mac");

        // A removal says so with a null, not by omitting the field: a client that reads `emoji`
        // must be able to tell "cleared" from "this event is not about me".
        let cleared: Value = serde_json::from_str(&frame(BOT, SESSION, "row:41", None, "Mac")).unwrap();
        assert_eq!(cleared["params"]["payload"]["emoji"], Value::Null);
        assert!(cleared["params"]["payload"].get("emoji").is_some());
    }

    /// The route publishes on the live registry: a subscribed socket hears the change without
    /// asking for it.
    #[tokio::test]
    async fn a_put_reaches_every_live_socket() {
        let dir = scratch("publish");
        let st = state(&dir);
        let mut heard = st.relay_sockets.subscribe();

        put_reaction(
            State(Arc::clone(&st)),
            auth(),
            Json(put_body(BOT, SESSION, "row:41", "👍", "Mo's Mac")),
        )
        .await
        .expect("stored");

        let line = tokio::time::timeout(std::time::Duration::from_secs(2), heard.recv())
            .await
            .expect("the frame was published")
            .expect("the channel is open");
        let value: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["params"]["type"], "reaction.updated");
        assert_eq!(value["params"]["payload"]["emoji"], "👍");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A bearer for one paired device. Access tokens are the long-lived credential the relay and a
    /// script use, and each names its own device — which is what makes this two devices rather than
    /// one caller twice.
    fn device_header(st: &Arc<AppState>, device: &str) -> HeaderMap {
        let token = st.tickets.mint_access(device);
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {token}").parse().unwrap(),
        );
        headers
    }

    /// The next frame the host publishes, decoded.
    async fn next_frame(heard: &mut tokio::sync::broadcast::Receiver<String>) -> Value {
        let line = tokio::time::timeout(std::time::Duration::from_secs(2), heard.recv())
            .await
            .expect("the frame was published")
            .expect("the channel is open");
        serde_json::from_str(&line).expect("a JSON frame")
    }

    /// The report, at the route level: "I gave a thumbs-up on the Mac and it never reached the
    /// phone; on the phone I gave a heart and it never reached the PC."
    ///
    /// Two paired devices, one message. A writes and B reads the same emoji; B replaces it and A's
    /// socket hears the replacement (one badge, not two); B clears it and both the next read and the
    /// live frame agree it is gone. This is the part of the path the host owns — the frames it emits
    /// are the ones both apps decode — so a break in it is a break the apps cannot fix.
    #[tokio::test]
    async fn two_devices_agree_on_one_reaction_and_on_its_removal() {
        let dir = scratch("two-devices");
        let st = state(&dir);
        let mac = device_header(&st, "device-mac");
        let phone = device_header(&st, "device-phone");
        let mut heard = st.relay_sockets.subscribe();

        put_reaction(
            State(Arc::clone(&st)),
            mac.clone(),
            Json(put_body(BOT, SESSION, "row:7", "👍", "Mo's Mac")),
        )
        .await
        .expect("the Mac's reaction is stored");
        let set = next_frame(&mut heard).await;
        assert_eq!(set["params"]["type"], "reaction.updated");
        assert_eq!(set["params"]["payload"]["message"], "row:7");
        assert_eq!(set["params"]["payload"]["emoji"], "👍");

        let on_phone = get_reactions(State(Arc::clone(&st)), phone.clone(), Query(get_q(BOT, SESSION)))
            .await
            .expect("the phone can read it");
        assert_eq!(
            reactions_of(&on_phone.0),
            vec![("row:7".to_string(), "👍".to_string(), "Mo's Mac".to_string())]
        );

        // The phone reacts to the same message: it replaces rather than adding a second badge, and
        // the Mac's open socket hears it without asking.
        put_reaction(
            State(Arc::clone(&st)),
            phone.clone(),
            Json(put_body(BOT, SESSION, "row:7", "❤️", "iPhone")),
        )
        .await
        .expect("the phone's replaces it");
        let replaced = next_frame(&mut heard).await;
        assert_eq!(replaced["params"]["payload"]["emoji"], "❤️");
        assert_eq!(replaced["params"]["payload"]["by"], "iPhone");
        let on_mac = get_reactions(State(Arc::clone(&st)), mac.clone(), Query(get_q(BOT, SESSION)))
            .await
            .expect("the Mac reads the same conversation");
        assert_eq!(reactions_of(&on_mac.0).len(), 1, "one message wears one reaction");

        // Cleared on the phone: the frame says `null` (not "absent"), and the Mac's next read is
        // empty — so the badge cannot survive on either device.
        put_reaction(
            State(Arc::clone(&st)),
            phone.clone(),
            Json(put_body(BOT, SESSION, "row:7", "", "iPhone")),
        )
        .await
        .expect("cleared");
        let cleared = next_frame(&mut heard).await;
        assert!(cleared["params"]["payload"]["emoji"].is_null());
        let after = get_reactions(State(Arc::clone(&st)), mac, Query(get_q(BOT, SESSION)))
            .await
            .expect("read");
        assert!(reactions_of(&after.0).is_empty(), "a cleared reaction is gone on both");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
