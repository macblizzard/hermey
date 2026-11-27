//! One bot speaking to another, in the conversation the owner actually sees.
//!
//! Ported from `Bridge/hermes_bridge/bot_message.py`, which is the contract the apps were written
//! against. Two routes, both loopback-only operator commands (no device ticket, like `/v1/pair/start`):
//!
//! ```text
//! POST /v1/bots/{profile}/message   {"text": "…", "from": "assistant", "from_profile": "cody"}
//!   -> {"profile", "from", "session_id", "text", "reply", "delivered": true}
//!
//!   … and optionally `"attachments": [{"name": "budget.xlsx", "data_base64": "…"}]` (at most four,
//!   8 MiB each, PDF/DOCX/XLSX/CSV/TXT). The host reads the document once and appends one labelled
//!   block per attachment/sheet to the message, so the engine sees the text rather than a filename.
//!   The response then also carries `attachments: [{name, kind, chars, truncated}]`.
//!
//! POST /v1/bots/{profile}/ask       {"question": "…", "from": "cody", "timeout": 300}
//!   -> {"profile", "from", "session_id", "question", "reply", "answered": <bool>}
//! ```
//!
//! Two things this file exists to make true:
//!
//! * a message addressed to a bot must land in **that bot's own chat** — the stored session pointer
//!   the apps open (`bot_sessions`), not a side session. The pointer is resolved here and resumed
//!   *with its profile*, because a multiplexed gateway resolves a stored id in the caller's default
//!   profile unless told otherwise;
//! * the exchange is **labelled** (`Assistant (cody) → Ops: …`), because the target's transcript
//!   renders every user row as if the owner typed it.
//!
//! A desktop pet is the one exception to the first rule. Its question arrives as
//! `from: "desktop-pet"` and is answered in a **separate, bounded session** of that bot's own —
//! minted once, reused, and rotated when it fills — because the endless conversation the app opens
//! carries the whole transcript, and a one-word greeting was paying for all of it (12–15s measured
//! against `20261103_160851_77da50`). Every other `from` keeps the old route byte for byte; see
//! `pet_model` for the fast model that session is pinned to, and `PET_WINDOW` for the cap.
//!
//! Delivery is *queued semantics*, not a promise of a reply: a busy session steers or queues (an
//! `ask` marks its prompt `queued: true` so a running turn holds it instead of swallowing it into
//! the reply). A timeout returns `delivered: true, reply: null`, so the caller reports "sent, no
//! answer yet" instead of "failed".
//!
//! Status codes, identical to the bridge: 404 (non-loopback, or a proxied caller), 422 (bad profile,
//! missing/blank/long text, bad `from`, bad `from_profile`, bad `timeout`), 409 (disabled bot, no
//! conversation yet, stale pointer), 413 (text over the cap), 502/503/504 (gateway faults).

use crate::engine_client::engine_url;
use crate::office;
use crate::routes::AppState;
use crate::transfers;
use axum::body::Bytes;
use axum::extract::{ConnectInfo, Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use futures_util::{SinkExt, StreamExt};
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use std::future::Future;
use std::net::SocketAddr;
use std::path::{Path as FsPath, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

type Fail = (StatusCode, Json<Value>);
type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A cron report can be long (the daily changelog is ~16k); clip only the absurd.
const MAX_TEXT: usize = 32_000;

/// How long to wait for the target bot's turn to finish. A bot answering with tools can take a
/// while; past this the caller is told it was delivered without an answer.
const REPLY_TIMEOUT_S: f64 = 150.0;

/// How long an `ask` waits for the owner to answer before giving up.
const ASK_TIMEOUT_S: f64 = 300.0;

/// How often an `ask` re-reads the bot's own conversation while it waits.
const POLL_INTERVAL: Duration = Duration::from_millis(500);

/// The sender the desktop pet puts on every balloon question.
///
/// It is a routing key, not a feature: this one string is the whole of the pet's surface in the
/// host. Everything else about the pet — the balloon, the geometry, the settings — is the Mac app's.
const PET_SENDER: &str = "desktop-pet";

/// What the pet's own session is called, so the owner can open it and read what the balloon said.
const PET_TITLE: &str = "Desktop Pet";

/// How long a pet's answer may be, appended to every balloon question.
///
/// The balloon is a small chat beside an icon, not a page: a two-paragraph answer is unreadable
/// there and costs the latency the pet's own session exists to avoid. It lives here, in the route
/// that assembles the message, rather than in the app's view, because a view can only cut text the
/// model already produced — the rule has to reach the model to make it shorter in the first place,
/// and this is the one place every balloon question (Mac, phone, a script) passes through. The app
/// still clamps what it *displays* as a backstop, since a prompt is not a contract.
///
/// One line, not a system prompt: `session.create` carries no prompt parameter (see
/// `docs/HERMEYD.md`), and the pet's session is the bot's own — the owner's real conversation must
/// not inherit this.
const PET_BREVITY: &str =
    "Reply in at most two sentences of plain text — no preamble, no lists, no headings.";

/// The pet session's window, counted in transcript rows, and what forces a fresh session.
///
/// Rotation rather than compaction: the gateway's compaction threshold is *profile* config, and a
/// config write would change the bot's normal conversation too — the one thing this change must not
/// do. Two rows per exchange makes this ~30 questions, and the pet's own transcript is the only
/// thing ever written there, so the window can never approach the endless conversation it replaced.
const PET_WINDOW: i64 = 60;

/// A document key owned by `bridge_routes` (`DOC_DISABLED`); the toggle writes it, this reads it.
const DOC_DISABLED: &str = "bots_disabled";

/// A proxy makes every caller look like 127.0.0.1, and this route writes into a real bot
/// conversation — the same header list `device_auth.py` refuses.
const PROXY_HEADERS: [&str; 4] = ["forwarded", "x-forwarded-for", "x-real-ip", "tailscale-user-login"];

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({ "detail": msg.into() })))
}

/// `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` — the shape the session pointer accepts. Never a path.
fn valid_profile(profile: &str) -> bool {
    let bytes = profile.as_bytes();
    match bytes.first() {
        Some(first) if first.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    bytes.len() <= 64
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}

/// `^[A-Za-z0-9 ._-]{1,40}$` — a bot may name itself; a newline or a colon would break the label.
fn valid_from(sender: &str) -> bool {
    let chars: Vec<char> = sender.chars().collect();
    (1..=40).contains(&chars.len())
        && chars
            .iter()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, ' ' | '.' | '_' | '-'))
}

/// Python's `str.title()`: a letter is uppercased when the previous character is not cased, and
/// lowercased otherwise — so `CODY` -> `Cody` and `don't` -> `Don'T`, exactly as the bridge labelled
/// rows the apps already render.
fn python_title(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut previous_cased = false;
    for ch in value.chars() {
        if previous_cased {
            out.extend(ch.to_lowercase());
        } else {
            out.extend(ch.to_uppercase());
        }
        previous_cased = ch.is_alphabetic();
    }
    out
}

/// The label the target bot reads, and the owner reads over its shoulder.
///
/// The sender's profile id is in brackets when the caller knows it: `Assistant (cody) → Ops:`. It
/// is what lets the apps turn this row back into a face and a name instead of a prefix.
fn label(sender: &str, target: &str, text: &str, sender_profile: Option<&str>) -> String {
    // The pet's wire id is `desktop-pet`; the name the bot and the owner read is `Desktop Pet`.
    // Title-casing the id gave `Desktop-Pet`, which is a slug leaking into a sentence.
    let sender_title = if sender == PET_SENDER { PET_TITLE.to_string() } else { python_title(sender) };
    let who = match sender_profile {
        Some(profile) => format!("{} ({profile})", sender_title),
        None => sender_title,
    };
    format!("{who} → {}: {}", python_title(target), text.trim())
}

/// A pet's question: the ordinary label, then the one line that bounds the answer.
///
/// A second line rather than a suffix, so the owner's own words stay intact at the top of the row
/// and the instruction reads as a rule rather than as part of his question.
fn pet_message(sender: &str, target: &str, text: &str, sender_profile: Option<&str>) -> String {
    format!(
        "{}\n{}",
        label(sender, target, text, sender_profile),
        PET_BREVITY
    )
}

fn unix_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Loopback, **or** a call that carries a real device ticket.
///
/// `require_loopback` alone made `ask` unusable from the apps: the phone and the Mac reach the host
/// through tailscale serve, every proxied request is refused by design ("not found"), and the pet could
/// therefore never ask anything — it showed the host's own "not found" in its balloon. A device that
/// already holds a ticket can do exactly this by typing in a conversation, so the ticket is the honest
/// boundary here; an unauthenticated proxied call still gets the same "not found" as an unknown route.
fn require_loopback_or_device(
    st: &AppState,
    peer: &SocketAddr,
    headers: &HeaderMap,
) -> Result<(), Fail> {
    if require_loopback(peer, headers).is_ok() {
        return Ok(());
    }
    match crate::routes::require_device(st, headers) {
        Ok(_) => Ok(()),
        // Same answer as an unknown route: nothing here is advertised to a caller without a ticket.
        Err(_) => Err(bad(StatusCode::NOT_FOUND, "not found")),
    }
}

/// `is_local_host_request`: direct loopback only, never a proxied one.
fn require_loopback(peer: &SocketAddr, headers: &HeaderMap) -> Result<(), Fail> {
    let proxied = PROXY_HEADERS.iter().any(|name| headers.contains_key(*name));
    // Deliberately the same answer as an unknown route: an operator command is not a thing to
    // advertise to the network.
    if proxied || !peer.ip().is_loopback() {
        return Err(bad(StatusCode::NOT_FOUND, "not found"));
    }
    Ok(())
}

/// Python's `body: dict` needs a JSON object; anything else was a 422 there too.
fn parse_body(raw: &[u8]) -> Result<Value, Fail> {
    let value: Value = serde_json::from_slice(raw)
        .map_err(|_| bad(StatusCode::UNPROCESSABLE_ENTITY, "body must be a JSON object"))?;
    if !value.is_object() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "body must be a JSON object"));
    }
    Ok(value)
}

/// A disabled bot has its schedules paused; a peer's message must not be the way around that.
fn disabled(st: &AppState, profile: &str) -> bool {
    st.store
        .doc_or(DOC_DISABLED, json!({ "disabled": [] }))
        .get("disabled")
        .and_then(|v| v.as_array())
        .map(|list| list.iter().any(|v| v.as_str() == Some(profile)))
        .unwrap_or(false)
}

// ---- request planning (pure: every status code is decided here) -----------------------------

#[derive(Debug)]
pub(crate) struct MessagePlan {
    pub sender: String,
    pub sender_profile: Option<String>,
    /// The caller's words without the label — what the transfer record and the apps show.
    pub text: String,
    /// The labelled row that is submitted into the target's conversation, with the attachments'
    /// extracted text after it.
    pub message: String,
    /// One `{name, kind, chars, truncated}` per attachment, in the order they were handed over.
    /// Empty for a plain message, which is what keeps the response byte-identical for every caller
    /// that never sends one.
    pub attachments: Vec<Value>,
}

#[derive(Debug)]
pub(crate) struct AskPlan {
    pub sender: String,
    pub sender_profile: Option<String>,
    pub text: String,
    pub message: String,
    pub timeout: f64,
    /// Which role the answer will be written under.
    ///
    /// The route was built for one bot asking another bot's *owner*, so it waited for a `user` row.
    /// A desktop pet asks the bot itself: the question is delivered as the `user` row and the answer
    /// arrives as `assistant`, so waiting for `user` meant every pet question timed out while the
    /// answer sat in the transcript.
    pub await_role: &'static str,
    /// `true` for a balloon question: it is answered in the pet's own bounded session instead of the
    /// bot's endless conversation. Derived from `sender`, never from a client-controlled field of its
    /// own, so a caller cannot claim the fast path by naming a different parameter.
    pub pet: bool,
}

fn invalid_profile() -> Fail {
    bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile")
}

/// Validate `POST …/message` and build the row to submit. Order matters and follows the bridge:
/// disabled before the body, `text` before `from`.
pub(crate) fn plan_message(profile: &str, body: &Value, is_disabled: bool) -> Result<MessagePlan, Fail> {
    if !valid_profile(profile) {
        return Err(invalid_profile());
    }
    if is_disabled {
        return Err(bad(StatusCode::CONFLICT, format!("{profile} is disabled")));
    }

    let text = match body.get("text").and_then(|v| v.as_str()) {
        Some(text) if !text.trim().is_empty() => text,
        _ => return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "text is required")),
    };
    if text.chars().count() > MAX_TEXT {
        return Err(bad(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!("text longer than {MAX_TEXT} characters"),
        ));
    }
    let sender = match body.get("from") {
        None => "assistant",
        Some(value) => value.as_str().unwrap_or(""),
    };
    if !valid_from(sender) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid from"));
    }
    let sender_profile = sender_profile(body)?;
    let (blocks, attachments) = attachment_blocks(body)?;

    // The label stays the first line — both apps parse `Assistant (cody) → Ops:` off it — and the
    // document text follows as labelled blocks, so a bot reading the row sees the words first.
    let mut message = label(sender, profile, text, sender_profile.as_deref());
    if !blocks.is_empty() {
        message.push_str("\n\n");
        message.push_str(&blocks);
    }

    Ok(MessagePlan {
        text: text.trim().to_string(),
        message,
        sender: sender.to_string(),
        sender_profile,
        attachments,
    })
}

/// Validate `POST …/ask`. Same order as `plan_message`, then `timeout`.
pub(crate) fn plan_ask(profile: &str, body: &Value, is_disabled: bool) -> Result<AskPlan, Fail> {
    if !valid_profile(profile) {
        return Err(invalid_profile());
    }
    if is_disabled {
        return Err(bad(StatusCode::CONFLICT, format!("{profile} is disabled")));
    }

    let question = match body.get("question").and_then(|v| v.as_str()) {
        Some(text) if !text.trim().is_empty() => text,
        _ => return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "question is required")),
    };
    if question.chars().count() > MAX_TEXT {
        return Err(bad(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!("question longer than {MAX_TEXT} characters"),
        ));
    }
    let sender = match body.get("from") {
        None => "assistant",
        Some(value) => value.as_str().unwrap_or(""),
    };
    if !valid_from(sender) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid from"));
    }
    let sender_profile = sender_profile(body)?;

    // An `ask` is one question and one answer; a document with nowhere to be read would be a file
    // the caller believes it sent. Say so instead.
    if body
        .get("attachments")
        .filter(|value| !value.is_null())
        .and_then(|value| value.as_array())
        .map(|items| !items.is_empty())
        .unwrap_or(false)
    {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "ask does not take attachments: use message",
        ));
    }

    // A JSON `true` is a Python `int`, so the bridge accepted it as a one-second timeout; a boolean
    // is not a duration here and is refused rather than silently reinterpreted.
    let timeout = match body.get("timeout") {
        None => ASK_TIMEOUT_S,
        Some(value) if value.is_number() => match value.as_f64() {
            Some(seconds) if (1.0..=ASK_TIMEOUT_S).contains(&seconds) => seconds,
            _ => return Err(bad_ask_timeout()),
        },
        _ => return Err(bad_ask_timeout()),
    };

    let await_role = match body.get("await").and_then(|v| v.as_str()) {
        None | Some("owner") | Some("user") => "user",
        Some("bot") | Some("assistant") | Some("self") => "assistant",
        Some(_) => return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "await must be owner or bot")),
    };

    Ok(AskPlan {
        await_role,
        // The sender decides, and the sender is the only thing here the pet actually controls.
        pet: sender == PET_SENDER,
        text: question.trim().to_string(),
        message: if sender == PET_SENDER {
            pet_message(sender, profile, question, sender_profile.as_deref())
        } else {
            label(sender, profile, question, sender_profile.as_deref())
        },
        sender: sender.to_string(),
        sender_profile,
        timeout,
    })
}

/// Read every attachment into one block of labelled text, bounded twice over: per document
/// ([`office::MAX_EXTRACT_CHARS`]) and across the message
/// ([`office::MAX_MESSAGE_ATTACHMENT_CHARS`]).
///
/// Refusals are 422 with the same `{"detail": …}` shape the rest of the route uses, and each one
/// names the file: a caller that sent three documents needs to know which one was wrong.
fn attachment_blocks(body: &Value) -> Result<(String, Vec<Value>), Fail> {
    let Some(raw) = body.get("attachments").filter(|value| !value.is_null()) else {
        return Ok((String::new(), Vec::new()));
    };
    let Some(items) = raw.as_array() else {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "attachments must be a list",
        ));
    };
    if items.is_empty() {
        return Ok((String::new(), Vec::new()));
    }
    if items.len() > office::MAX_ATTACHMENTS_PER_MESSAGE {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!(
                "at most {} attachments per message",
                office::MAX_ATTACHMENTS_PER_MESSAGE
            ),
        ));
    }

    let mut blocks = String::new();
    let mut summaries = Vec::new();
    let mut spent = 0usize;
    for item in items {
        let Some(object) = item.as_object() else {
            return Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                "each attachment must be an object with a name and data_base64",
            ));
        };
        let name = object
            .get("name")
            .and_then(|value| value.as_str())
            .ok_or_else(|| {
                bad(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "each attachment needs a name",
                )
            })?;
        if !office::valid_attachment_name(name) {
            return Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("invalid attachment name: {name}"),
            ));
        }
        // Only the two byte-carrying keys, exactly as the relay allows: a caller cannot smuggle a
        // `path` alongside the bytes for a later layer to honour.
        if object
            .keys()
            .any(|key| !matches!(key.as_str(), "name" | "data_base64" | "data_url"))
        {
            return Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("{name}: only name and data_base64 (or data_url) are allowed"),
            ));
        }
        let data = match (
            object.get("data_base64").and_then(|value| value.as_str()),
            object.get("data_url").and_then(|value| value.as_str()),
        ) {
            (Some(base64), None) => base64,
            (None, Some(url)) => url,
            (Some(_), Some(_)) => {
                return Err(bad(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!("{name}: give data_base64 or data_url, not both"),
                ))
            }
            (None, None) => {
                return Err(bad(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!("{name}: data_base64 (or data_url) is required"),
                ))
            }
        };
        let bytes = office::decode_attachment(&office::Incoming { name, data })
            .map_err(|error| bad(StatusCode::UNPROCESSABLE_ENTITY, error.detail().to_string()))?;

        // Three documents at full length would crowd the bot's own prompt, so the message's budget
        // is spent in order and a document with no room left says so instead of arriving empty.
        let budget = office::MAX_EXTRACT_CHARS.min(office::MAX_MESSAGE_ATTACHMENT_CHARS - spent);
        if budget < 200 {
            blocks.push_str(&format!(
                "--- attachment: {name} (not included) ---\n\
                 [not included: this message already carries {} characters of attachments]\n",
                office::MAX_MESSAGE_ATTACHMENT_CHARS
            ));
            summaries.push(serde_json::json!({
                "name": name, "kind": null, "chars": 0, "truncated": true,
            }));
            continue;
        }

        let extraction = office::extract_with_budget(name, &bytes, budget)
            .map_err(|error| bad(StatusCode::UNPROCESSABLE_ENTITY, error.detail().to_string()))?;
        spent += extraction.chars();
        if !blocks.is_empty() {
            blocks.push('\n');
        }
        blocks.push_str(&extraction.block());
        summaries.push(extraction.summary());
    }

    Ok((blocks, summaries))
}

fn bad_ask_timeout() -> Fail {
    bad(
        StatusCode::UNPROCESSABLE_ENTITY,
        format!("timeout must be 1..{ASK_TIMEOUT_S:.0} seconds"),
    )
}

/// `from_profile` may be absent or null (both mean "the caller did not name itself"), otherwise it
/// must be a profile name.
pub(crate) fn sender_profile(body: &Value) -> Result<Option<String>, Fail> {
    match body.get("from_profile") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => match value.as_str() {
            Some(profile) if valid_profile(profile) => Ok(Some(profile.to_string())),
            _ => Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid from_profile")),
        },
    }
}

/// "No conversation yet" is a 409, not a 404: the bot exists, the app has just never opened it.
pub(crate) fn require_stored(stored: Option<String>, profile: &str, verb: &str) -> Result<String, Fail> {
    stored.ok_or_else(|| {
        bad(
            StatusCode::CONFLICT,
            format!("{profile} has no conversation yet: open it in the app once, then {verb}"),
        )
    })
}

// ---- the desktop pet's own session -------------------------------------------------------------

/// A model name built for latency rather than depth: the marker every shipped fast catalogue
/// carries (`deepseek-v4.1-flash`, `mimo-v2.6-flash`, `glm-5.3-flash`, `claude-haiku-…`).
fn is_fast_model(model: &str) -> bool {
    let lower = model.to_ascii_lowercase();
    ["flash", "fast", "mini", "lite", "nano", "haiku"]
        .iter()
        .any(|marker| lower.contains(marker))
}

/// The model the pet's session is pinned to: a fast name **this profile's own `config.yaml`
/// already carries**, or nothing.
///
/// The wire does allow a per-session model — `session.create` takes `model`/`provider`
/// (`tui_gateway/contracts/sessions.py:130-131`) and the gateway stores them as that session's
/// `model_override` (`tui_gateway/methods_session_model_guard.py:30-34`, consumed at
/// `tui_gateway/methods_session.py:396-400`) — but a name the config does not have is a provider
/// 404 on the pet's very first turn, which is exactly the failure the create-time model×provider
/// gate exists to refuse up front. So: the profile's own `model.default` when it already names a
/// fast model, else the first `fallback_providers` entry that does, else `None` and no pin — the
/// profile default is what the bot's conversation runs, so an unpinned pet loses nothing.
fn pet_model(st: &AppState, profile: &str) -> Option<(String, String)> {
    let path = st.engine_home.join("profiles").join(profile).join("config.yaml");
    let text = std::fs::read_to_string(path).ok()?;
    let doc: serde_yaml_ng::Value = serde_yaml_ng::from_str(&text).ok()?;
    let provider_of = |entry: &serde_yaml_ng::Value| {
        entry
            .get("provider")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    let model = doc.get("model")?;
    if let Some(default) = model.get("default").and_then(|v| v.as_str()) {
        if is_fast_model(default) {
            return Some((default.to_string(), provider_of(model)));
        }
    }
    for entry in doc.get("fallback_providers")?.as_sequence()? {
        if let Some(candidate) = entry.get("model").and_then(|v| v.as_str()) {
            if is_fast_model(candidate) {
                return Some((candidate.to_string(), provider_of(entry)));
            }
        }
    }
    None
}

/// How big the pet's own transcript is right now, read from the bot's `state.db`.
///
/// `None` — no row yet, or a database this host cannot open — counts as empty, which is the right
/// answer for a session that has not taken its first question.
fn pet_message_count(db_path: &FsPath, session_id: &str) -> Option<i64> {
    if !db_path.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    conn.busy_timeout(Duration::from_secs(2)).ok()?;
    conn.query_row(
        "SELECT COUNT(*) FROM messages WHERE session_id = ?1",
        rusqlite::params![session_id],
        |row| row.get::<_, i64>(0),
    )
    .ok()
}

// ---- delivery -------------------------------------------------------------------------------

#[derive(Clone, Copy)]
pub(crate) struct DeliverRequest<'a> {
    pub profile: &'a str,
    /// The stored pointer to resume. Empty only for a pet ask that has no session yet — that is
    /// what makes `pet` below a mint rather than a resume.
    pub stored: &'a str,
    pub message: &'a str,
    /// `queued: true` holds the prompt behind a running turn instead of steering into it. An `ask`
    /// is queued; a plain message is not.
    pub queued: bool,
    /// `Some` for a desktop-pet ask: land in the pet's own bounded session, minting it when
    /// `stored` is empty (or when the stored one has since been deleted). `None` — every other
    /// caller — resumes `stored` and changes nothing.
    pub pet: Option<PetMint<'a>>,
}

/// What a mint needs: a title the owner can recognise, and the fast model pinned for this session.
#[derive(Clone, Copy)]
pub(crate) struct PetMint<'a> {
    pub title: &'a str,
    /// `None` when the profile's config names no fast model: no pin, the profile default runs.
    pub model: Option<&'a str>,
    /// Empty when the config's fast entry does not name its own provider — the gateway then
    /// resolves the profile's, which is the same thing an unpinned session would do.
    pub provider: &'a str,
}

#[derive(Debug)]
pub(crate) struct Delivered {
    pub session_id: String,
    /// The stored pointer the transcript landed under, **only when it is not the one asked for** —
    /// a minted pet session answers with a key of its own, and that is the id the reply must be
    /// polled against and the pointer the store must keep. `None` on every resume.
    pub stored_session_id: Option<String>,
    /// The assistant text of the completion event — the row the apps render under the message.
    pub reply: Option<String>,
}

/// The seam the tests fake: everything that needs a live engine.
pub(crate) trait Deliverer {
    fn deliver<'a>(
        &'a self,
        req: DeliverRequest<'a>,
    ) -> Pin<Box<dyn Future<Output = Result<Delivered, Fail>> + Send + 'a>>;
}

struct LiveEngine {
    ws: String,
    token: Option<String>,
}

impl LiveEngine {
    fn new(st: &AppState) -> Self {
        // Read per call, and only when the engine asked for one: `engine_auth` decided at boot.
        Self { ws: st.engine_ws.clone(), token: st.engine_token() }
    }
}

impl Deliverer for LiveEngine {
    fn deliver<'a>(
        &'a self,
        req: DeliverRequest<'a>,
    ) -> Pin<Box<dyn Future<Output = Result<Delivered, Fail>> + Send + 'a>> {
        Box::pin(async move { deliver_live(&self.ws, self.token.as_deref(), req).await })
    }
}

enum Frame {
    Value(Value),
    Timeout,
    Closed,
}

/// One gateway frame, or a 502.
///
/// A gateway that answers with something that is not JSON (a stray log line, a half frame) used to
/// raise `JSONDecodeError` out of the bridge route — an unhandled 500 where the caller was promised
/// a queued delivery. It is an upstream fault, so it says so.
async fn read_frame(socket: &mut Ws, deadline: tokio::time::Instant) -> Result<Frame, Fail> {
    loop {
        let next = match tokio::time::timeout_at(deadline, socket.next()).await {
            Err(_) => return Ok(Frame::Timeout),
            Ok(None) => return Ok(Frame::Closed),
            Ok(Some(Err(_))) => return Ok(Frame::Closed),
            Ok(Some(Ok(message))) => message,
        };
        let text = match next {
            Message::Text(text) => text.to_string(),
            Message::Binary(bytes) => String::from_utf8_lossy(&bytes).to_string(),
            Message::Close(_) => return Ok(Frame::Closed),
            // Ping/pong/continuation are transport, not protocol: `websockets.recv()` never showed
            // them to the bridge either.
            _ => continue,
        };
        match serde_json::from_str::<Value>(&text) {
            Ok(value) if value.is_object() => return Ok(Frame::Value(value)),
            _ => return Err(bad(StatusCode::BAD_GATEWAY, "gateway sent an unreadable frame")),
        }
    }
}

fn frame_id(frame: &Value, wanted: i64) -> bool {
    frame.get("id").and_then(|v| v.as_i64()) == Some(wanted)
}

/// The event name, read from every place it may be: `params.type` today, the older shape at the top
/// of `params`, and a copy inside the payload on some events.
fn event_name<'a>(params: &'a Value, payload: &'a Value) -> Option<&'a str> {
    params
        .get("type")
        .or_else(|| params.get("event"))
        .or_else(|| payload.get("event"))
        .or_else(|| payload.get("type"))
        .and_then(|v| v.as_str())
}

/// JSON-RPC ids on the delivery socket. Fixed rather than sequential so a frame can never be read
/// as the answer to a different request when the path takes more than one hop.
const RPC_CAPABILITIES: i64 = 1;
/// The pet's own session, minted.
const RPC_CREATE: i64 = 2;
/// The stored session, resumed.
const RPC_RESUME: i64 = 3;
/// The question itself.
const RPC_SUBMIT: i64 = 4;

/// What `session.resume` answered: a runtime id, or the gateway's "this pointer is gone".
enum Resume {
    Resumed(String),
    Stale,
}

/// `session.resume` *within its profile* — the stored pointer, because a multiplexed gateway would
/// otherwise resolve it in the caller's default profile.
async fn resume_session(
    socket: &mut Ws,
    deadline: tokio::time::Instant,
    req: &DeliverRequest<'_>,
) -> Result<Resume, Fail> {
    socket
        .send(Message::Text(
            json!({
                "jsonrpc": "2.0", "id": RPC_RESUME, "method": "session.resume",
                "params": { "session_id": req.stored, "profile": req.profile },
            })
            .to_string()
            .into(),
        ))
        .await
        .map_err(|_| bad(StatusCode::BAD_GATEWAY, "gateway closed the connection"))?;
    loop {
        match read_frame(socket, deadline).await? {
            Frame::Value(frame) if frame_id(&frame, RPC_RESUME) => {
                if let Some(error) = frame.get("error") {
                    // -32001 is the gateway's "session not found"; the pointer is stale.
                    if error.get("code").and_then(|v| v.as_i64()) == Some(-32001) {
                        return Ok(Resume::Stale);
                    }
                    return Err(bad(StatusCode::BAD_GATEWAY, "gateway refused the session"));
                }
                // A result without a usable id is not an answer: keep reading.
                if let Some(id) = frame
                    .get("result")
                    .and_then(|r| r.get("session_id"))
                    .and_then(|v| v.as_str())
                    .filter(|id| !id.is_empty())
                {
                    return Ok(Resume::Resumed(id.to_string()));
                }
            }
            Frame::Value(_) => continue,
            Frame::Timeout => {
                return Err(bad(StatusCode::GATEWAY_TIMEOUT, "gateway did not resume the session"))
            }
            Frame::Closed => return Err(bad(StatusCode::BAD_GATEWAY, "gateway closed the connection")),
        }
    }
}

/// `session.create` for the desktop pet's own session: `(runtime id to submit into, stored key the
/// transcript is written under)`.
///
/// The stored key is what the next ask resumes and what the reply is polled against, so a create
/// that answers without one is a failure, not a fallback — a runtime id would not survive the next
/// connection and the pointer would silently stop working.
async fn create_pet_session(
    socket: &mut Ws,
    deadline: tokio::time::Instant,
    req: &DeliverRequest<'_>,
    mint: &PetMint<'_>,
) -> Result<(String, String), Fail> {
    let mut params = json!({ "profile": req.profile, "title": mint.title });
    if let Some(model) = mint.model {
        params["model"] = json!(model);
        if !mint.provider.is_empty() {
            params["provider"] = json!(mint.provider);
        }
    }
    socket
        .send(Message::Text(
            json!({ "jsonrpc": "2.0", "id": RPC_CREATE, "method": "session.create", "params": params })
                .to_string()
                .into(),
        ))
        .await
        .map_err(|_| bad(StatusCode::BAD_GATEWAY, "gateway closed the connection"))?;
    loop {
        match read_frame(socket, deadline).await? {
            Frame::Value(frame) if frame_id(&frame, RPC_CREATE) => {
                if frame.get("error").is_some() {
                    return Err(bad(StatusCode::BAD_GATEWAY, "gateway refused the session"));
                }
                let result = frame.get("result");
                let runtime = result
                    .and_then(|r| r.get("session_id"))
                    .and_then(|v| v.as_str())
                    .filter(|id| !id.is_empty())
                    .ok_or_else(|| bad(StatusCode::BAD_GATEWAY, "gateway created no session"))?
                    .to_string();
                let stored = result
                    .and_then(|r| r.get("stored_session_id"))
                    .and_then(|v| v.as_str())
                    .filter(|id| !id.is_empty())
                    .ok_or_else(|| bad(StatusCode::BAD_GATEWAY, "gateway created no session"))?
                    .to_string();
                return Ok((runtime, stored));
            }
            Frame::Value(_) => continue,
            Frame::Timeout => {
                return Err(bad(StatusCode::GATEWAY_TIMEOUT, "gateway did not create the session"))
            }
            Frame::Closed => return Err(bad(StatusCode::BAD_GATEWAY, "gateway closed the connection")),
        }
    }
}

/// Establish the session this question lands in: the pet's own when there is one to use, a fresh
/// mint when there is not, and — for a pet — a fresh mint when the stored one has been deleted.
async fn open_delivery_session(
    socket: &mut Ws,
    deadline: tokio::time::Instant,
    req: &DeliverRequest<'_>,
) -> Result<(String, Option<String>), Fail> {
    if let Some(mint) = req.pet {
        if req.stored.is_empty() {
            let (runtime, stored) = create_pet_session(socket, deadline, req, &mint).await?;
            return Ok((runtime, Some(stored)));
        }
        return match resume_session(socket, deadline, req).await? {
            Resume::Resumed(runtime) => Ok((runtime, None)),
            // The owner deleted the pet's session from the list: mint the next one rather than
            // failing every balloon question from here on.
            Resume::Stale => {
                let (runtime, stored) = create_pet_session(socket, deadline, req, &mint).await?;
                Ok((runtime, Some(stored)))
            }
        };
    }
    match resume_session(socket, deadline, req).await? {
        Resume::Resumed(runtime) => Ok((runtime, None)),
        Resume::Stale => Err(bad(
            StatusCode::CONFLICT,
            "the stored session no longer exists; open the bot in the app",
        )),
    }
}

/// Establish the session *within its profile*, submit, and wait for that session's completion.
async fn deliver_live(ws: &str, token: Option<&str>, req: DeliverRequest<'_>) -> Result<Delivered, Fail> {
    let url = engine_url(ws, token);
    // `max_size=None` in the bridge: a resume answers with the whole conversation, which can be
    // larger than tungstenite's 64 MiB default.
    let config = WebSocketConfig { max_message_size: None, max_frame_size: None, ..Default::default() };
    let (mut socket, _) = tokio_tungstenite::connect_async_with_config(
        url.as_str(),
        Some(config),
        false,
    )
    .await
    // No exception text: it can carry the dial URI, which carries the token.
    .map_err(|_| bad(StatusCode::SERVICE_UNAVAILABLE, "gateway unavailable"))?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs_f64(REPLY_TIMEOUT_S);
    let result = async {
        socket
            .send(Message::Text(
                json!({
                    "jsonrpc": "2.0", "id": RPC_CAPABILITIES, "method": "client.capabilities",
                    // No approvals: a bot speaking to a bot must never pick up a pending request
                    // meant for the owner's device.
                    "params": { "server_requests": false },
                })
                .to_string()
                .into(),
            ))
            .await
            .map_err(|_| bad(StatusCode::BAD_GATEWAY, "gateway closed the connection"))?;

        let (runtime_id, minted) = open_delivery_session(&mut socket, deadline, &req).await?;

        socket
            .send(Message::Text(
                json!({
                    "jsonrpc": "2.0", "id": RPC_SUBMIT, "method": "prompt.submit",
                    "params": {
                        "session_id": runtime_id, "profile": req.profile,
                        "text": req.message, "queued": req.queued,
                    },
                })
                .to_string()
                .into(),
            ))
            .await
            .map_err(|_| bad(StatusCode::BAD_GATEWAY, "gateway closed the connection"))?;

        let mut reply: Option<String> = None;
        loop {
            let frame = match read_frame(&mut socket, deadline).await? {
                Frame::Value(frame) => frame,
                // A timeout here is the documented "delivered, no answer yet", not a failure.
                Frame::Timeout | Frame::Closed => break,
            };
            if frame_id(&frame, RPC_SUBMIT) {
                if frame.get("error").is_some() {
                    return Err(bad(StatusCode::BAD_GATEWAY, "gateway refused the message"));
                }
                continue;
            }
            let params = frame.get("params").filter(|v| v.is_object()).cloned().unwrap_or(json!({}));
            let payload = params
                .get("payload")
                .filter(|v| v.is_object())
                .cloned()
                .unwrap_or_else(|| params.clone());
            if event_name(&params, &payload) == Some("message.complete") {
                let belongs = match payload.get("session_id") {
                    None | Some(Value::Null) => true,
                    Some(value) => value.as_str() == Some(runtime_id.as_str()),
                };
                if belongs {
                    // Only a string is a reply: `text` may be a structured value, and the apps
                    // decode `reply` as text or null.
                    reply = payload.get("text").and_then(|v| v.as_str()).map(str::to_string);
                    break;
                }
            }
        }
        Ok(Delivered { session_id: runtime_id, stored_session_id: minted, reply })
    }
    .await;

    let _ = socket.close(None).await;
    result
}

// ---- waiting for the owner's answer ---------------------------------------------------------

/// The first user row in one bot's conversation after a moment in time.
///
/// An `ask` writes its question as a user row (that is what the owner reads); the answer is the
/// *next* user row, which is the owner typing back. Only the stored session is read, because that is
/// the conversation the app opens.
fn owner_reply(db_path: &FsPath, session_id: &str, after: f64, role: &str) -> Option<String> {
    if !db_path.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    conn.busy_timeout(Duration::from_secs(2)).ok()?;
    conn.query_row(
        "SELECT content FROM messages \
         WHERE session_id = ?1 AND role = ?3 \
         AND content IS NOT NULL AND TRIM(content) <> '' \
         AND timestamp > ?2 \
         ORDER BY timestamp ASC, id ASC LIMIT 1",
        rusqlite::params![session_id, after, role],
        |row| row.get::<_, String>(0),
    )
    .ok()
}

/// Poll the bot's own conversation until the owner answers, or the timeout expires.
/// When the question landed, as the transcript recorded it.
///
/// `unix_now()` after `deliver` was the bug: delivery can take as long as the engine needs, so the
/// anchor could be *later* than the answer, and `timestamp > anchor` then matched nothing however long
/// the reply sat there. The question's own row is the only exact anchor.
fn question_row_time(db_path: &FsPath, session_id: &str, message: &str) -> Option<f64> {
    if !db_path.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(db_path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    conn.busy_timeout(Duration::from_secs(2)).ok()?;
    conn.query_row(
        "SELECT timestamp FROM messages \
         WHERE session_id = ?1 AND role = 'user' AND content = ?2 \
         ORDER BY timestamp DESC LIMIT 1",
        rusqlite::params![session_id, message],
        |row| row.get::<_, f64>(0),
    )
    .ok()
}

/// Every profile database this host could be writing to.
///
/// `engine_home` is an operator setting and on a host consolidated onto `~/.hermes` it still names the
/// old bundled tree, which holds no profiles at all — so a question was answered in the transcript and
/// never found. The candidates are checked for the profile itself, first match wins.
fn profile_databases(st: &AppState, profile: &str) -> Vec<PathBuf> {
    let mut roots = vec![st.engine_home.join("profiles")];
    if let Some(user_home) = std::env::var_os("HOME").map(PathBuf::from) {
        roots.push(user_home.join(".hermes").join("profiles"));
    }
    roots
        .into_iter()
        .map(|root| root.join(profile).join("state.db"))
        .filter(|db| db.is_file())
        .collect()
}

async fn wait_for_owner_reply(
    databases: Vec<PathBuf>,
    session_id: String,
    after: f64,
    timeout: f64,
    role: &'static str,
) -> Option<String> {
    let deadline = tokio::time::Instant::now()
        + Duration::from_secs_f64(timeout.clamp(1.0, ASK_TIMEOUT_S));
    while tokio::time::Instant::now() < deadline {
        // The engine owns these databases and may be writing this instant: read off the async
        // runtime so a busy page does not stall other requests.
        let (databases, session_id) = (databases.clone(), session_id.clone());
        let found = tokio::task::spawn_blocking(move || {
            databases
                .iter()
                .find_map(|db| owner_reply(db, &session_id, after, role))
        })
        .await
        .ok()
        .flatten();
        if found.is_some() {
            return found;
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
    None
}

// ---- the routes ------------------------------------------------------------------------------

/// The audit record says who spoke to whom and whether an answer came back; the words themselves
/// are the owner's conversation, not an audit artefact. `nbytes` is the labelled message's size,
/// never the message (Python did the same at `bot_message.py:129-135`).
fn audit(
    st: &AppState,
    kind: &str,
    profile: &str,
    method: &str,
    path: &str,
    nbytes: usize,
    outcome: &str,
) {
    st.audit.emit(
        kind,
        crate::audit::Event {
            profile: Some(profile),
            method: Some(method),
            path: Some(path),
            bytes: Some(nbytes),
            outcome: Some(outcome),
            ..crate::audit::Event::default()
        },
    );
}

fn message_body(profile: &str, plan: &MessagePlan, delivered: &Delivered) -> Value {
    let mut body = json!({
        "profile": profile,
        "from": plan.sender,
        "session_id": delivered.session_id,
        "text": plan.message,
        "reply": delivered.reply,
        "delivered": true,
    });
    // Only when there were attachments: six fields is the contract every existing caller reads, and
    // a message without a document must look exactly as it did.
    if !plan.attachments.is_empty() {
        body["attachments"] = Value::Array(plan.attachments.clone());
    }
    body
}

fn ask_body(profile: &str, plan: &AskPlan, session_id: &str, reply: Option<&str>) -> Value {
    json!({
        "profile": profile,
        "from": plan.sender,
        "session_id": session_id,
        "question": plan.message,
        "reply": reply,
        "answered": reply.is_some(),
    })
}

/// How a hand-off is recorded. Production passes `transfers::record`; the tests pass a recorder,
/// because the record's destination is resolved from the host's environment and a test must never
/// append to a real host's file.
pub(crate) trait RecordTransfer {
    #[allow(clippy::too_many_arguments)]
    fn record(
        &self,
        from_profile: Option<&str>,
        from_label: &str,
        to_profile: &str,
        session_id: Option<&str>,
        text: &str,
        at: f64,
    );
}

impl<F> RecordTransfer for F
where
    F: Fn(Option<&str>, &str, &str, Option<&str>, &str, f64),
{
    fn record(
        &self,
        from_profile: Option<&str>,
        from_label: &str,
        to_profile: &str,
        session_id: Option<&str>,
        text: &str,
        at: f64,
    ) {
        self(from_profile, from_label, to_profile, session_id, text, at)
    }
}

/// The production record: `transfers::record`, and a record that could not be written must not fail
/// the send.
pub(crate) fn record_transfer(
    st: &AppState,
) -> impl Fn(Option<&str>, &str, &str, Option<&str>, &str, f64) + '_ {
    move |from_profile, from_label, to_profile, session_id, text, at| {
        let _ = transfers::record(
            st,
            from_profile,
            from_label,
            to_profile,
            session_id,
            text,
            at,
        );
    }
}

/// The `message` route minus the HTTP plumbing — testable without an axum request.
pub(crate) async fn run_message<E: Deliverer + ?Sized, R: RecordTransfer + ?Sized>(
    st: &AppState,
    profile: &str,
    raw: &[u8],
    engine: &E,
    record: &R,
) -> Result<Value, Fail> {
    let body = parse_body(raw)?;
    let plan = plan_message(profile, &body, disabled(st, profile))?;
    let stored = require_stored(st.store.get_bot_session(profile), profile, "send")?;

    // Written by another bot, not by the owner: its reply *is* worth a banner.
    st.store.set_push_prompt(profile, "program");
    let delivered = engine
        .deliver(DeliverRequest {
            profile,
            stored: &stored,
            message: &plan.message,
            queued: false,
            pet: None,
        })
        .await?;

    // The label the apps draw: who spoke to whom, and the words without the prefix. The session id
    // is the conversation the message actually landed in — the id the engine answered with.
    record.record(
        plan.sender_profile.as_deref(),
        &plan.sender,
        profile,
        Some(&delivered.session_id),
        &plan.text,
        unix_now(),
    );
    audit(
        st,
        "bot_message",
        profile,
        &plan.sender,
        &format!("/v1/bots/{profile}/message"),
        plan.message.len(),
        if delivered.reply.is_some() { "replied" } else { "sent" },
    );
    Ok(message_body(profile, &plan, &delivered))
}

/// The `ask` route minus the HTTP plumbing.
pub(crate) async fn run_ask<E: Deliverer + ?Sized, R: RecordTransfer + ?Sized>(
    st: &AppState,
    profile: &str,
    raw: &[u8],
    engine: &E,
    record: &R,
) -> Result<Value, Fail> {
    let body = parse_body(raw)?;
    let plan = plan_ask(profile, &body, disabled(st, profile))?;
    let databases = profile_databases(st, profile);

    // Where the question lands. A balloon (`from: "desktop-pet"`) is answered in the pet's own
    // bounded session — minted on first use — and every other sender is answered in the endless
    // conversation the app opens, exactly as before. A pet ask needs no conversation yet: it makes
    // its own.
    let mut stored = if plan.pet {
        st.store.get_bot_pet_session(profile).unwrap_or_default()
    } else {
        require_stored(st.store.get_bot_session(profile), profile, "ask")?
    };
    // The window. A pet session that has filled rotates to a fresh one, so the transcript behind a
    // month of greetings is never what a one-word question has to carry.
    if plan.pet && !stored.is_empty() {
        let filled = databases
            .iter()
            .find_map(|db| pet_message_count(db, &stored))
            .unwrap_or(0)
            >= PET_WINDOW;
        if filled {
            stored.clear();
        }
    }
    // Read for a pet ask and for nothing else. It is needed whenever a mint *may* happen — the
    // first one, a rotated one, and one whose stored session was deleted out from under us — so it
    // is read up front rather than guessed at. A profile with no fast model of its own gets no pin
    // rather than a name we invented.
    let pinned = if plan.pet { pet_model(st, profile) } else { None };
    let (pinned_model, pinned_provider) = match &pinned {
        Some((model, provider)) => (Some(model.as_str()), provider.as_str()),
        None => (None, ""),
    };

    st.store.set_push_prompt(profile, "program");
    // Queued on purpose: a busy turn must hold the question, not steer it into the running reply.
    let delivered = engine
        .deliver(DeliverRequest {
            profile,
            stored: &stored,
            message: &plan.message,
            queued: true,
            pet: plan.pet.then(|| PetMint {
                title: PET_TITLE,
                model: pinned_model,
                provider: pinned_provider,
            }),
        })
        .await?;

    // A mint answers with a key of its own; that key is what the next ask resumes and what this
    // reply is polled against. A resume answers with none, and the pointer already in place stands.
    let poll = delivered.stored_session_id.clone().unwrap_or_else(|| stored.clone());
    if plan.pet && delivered.stored_session_id.is_some() {
        st.store.set_bot_pet_session(profile, &poll);
    }

    // The question's own row is the anchor; failing to find it (an engine that has not written yet)
    // falls back to now, which is only wrong by the delivery time.
    let asked_at = databases
        .iter()
        .find_map(|db| question_row_time(db, &poll, &plan.message))
        .unwrap_or_else(unix_now);
    // The stored id, not `delivered.session_id`: the engine hands back a *runtime* id, while the
    // transcript is written under the stored one. Querying the runtime id found nothing, which is
    // why a pet's question could sit answered in the chat and still time out.
    let reply = wait_for_owner_reply(
        databases,
        poll.clone(),
        asked_at,
        plan.timeout,
        plan.await_role,
    )
    .await;

    record.record(
        plan.sender_profile.as_deref(),
        &plan.sender,
        profile,
        Some(&delivered.session_id),
        &plan.text,
        unix_now(),
    );
    audit(
        st,
        "bot_ask",
        profile,
        &plan.sender,
        &format!("/v1/bots/{profile}/ask"),
        plan.message.len(),
        if reply.is_some() { "answered" } else { "timeout" },
    );
    Ok(ask_body(profile, &plan, &poll, reply.as_deref()))
}

/// `POST /v1/bots/{profile}/message` — deliver a message into a bot's canonical conversation.
pub async fn post_message(
    State(st): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    body: Bytes,
) -> Result<Json<Value>, Fail> {
    require_loopback(&peer, &headers)?;
    let engine = LiveEngine::new(&st);
    let record = record_transfer(&st);
    run_message(&st, &profile, &body, &engine, &record).await.map(Json)
}

/// `POST /v1/bots/{profile}/ask` — deliver a question, then wait for the owner's answer.
pub async fn post_ask(
    State(st): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    body: Bytes,
) -> Result<Json<Value>, Fail> {
    require_loopback_or_device(&st, &peer, &headers)?;
    let engine = LiveEngine::new(&st);
    let record = record_transfer(&st);
    run_ask(&st, &profile, &body, &engine, &record).await.map(Json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{RateLimiter, Tickets};
    use crate::display::DisplayHub;
    use crate::pairing::Pairing;
    use crate::store::Store;
    use std::sync::Mutex;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-bot-message-{tag}-{}-{}",
            std::process::id(),
            unix_now()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn test_state(dir: &FsPath) -> AppState {
        AppState {
            store: Store::open(&dir.join("bridge.db")).unwrap(),
            pairing: Pairing::new(600.0),
            tickets: Tickets::new(30.0, 300.0),
            limiter: RateLimiter::new(30, 60.0),
            salt: "test-salt".to_string(),
            public_host: "localhost".to_string(),
            engine_ws: "ws://127.0.0.1:1/api/ws".to_string(),
            engine_token_file: dir.join("engine.token"),
            // The pre-detection shape: a token file, and an engine that wants it.
            engine_auth: crate::engine_auth::EngineAuth::Required,
            engine_home: dir.join("engine"),
            local_computers: Default::default(),
            browsers: Default::default(),
            display: DisplayHub::spawn(
                "ws://127.0.0.1:1/api/ws".to_string(),
                Some(dir.join("engine.token")),
            ),
            relay_sockets: Default::default(),
            reactions: crate::reactions::Registry::in_dir(dir),
            home: dir.to_path_buf(),
            attachments_dir: dir.join("attachments"),
            local_token: std::sync::Arc::new(crate::local_token::LocalToken::from_value(
                "test-local-token",
                dir.join("local.token"),
            )),
            audit: std::sync::Arc::new(crate::audit::AuditLog::in_dir(dir)),
        }
    }

    /// `(profile, stored pointer the delivery was pointed at, message, queued, pet?)` — the last
    /// field is what the guard tests read: a balloon delivery must never be aimed at the bot's
    /// conversation, and a normal one must never be aimed at the pet's session.
    type Seen = (String, String, String, bool, bool);

    #[derive(Default)]
    struct FakeEngine {
        seen: Mutex<Vec<Seen>>,
        reply: Option<String>,
        fail: Option<(StatusCode, String)>,
        /// The stored key a *mint* answers with. `None` — the default — means the engine mints
        /// nothing, which is every conversation-path delivery.
        minted: Option<String>,
    }

    impl Deliverer for FakeEngine {
        fn deliver<'a>(
            &'a self,
            req: DeliverRequest<'a>,
        ) -> Pin<Box<dyn Future<Output = Result<Delivered, Fail>> + Send + 'a>> {
            Box::pin(async move {
                self.seen.lock().unwrap().push((
                    req.profile.to_string(),
                    req.stored.to_string(),
                    req.message.to_string(),
                    req.queued,
                    req.pet.is_some(),
                ));
                if let Some((status, detail)) = &self.fail {
                    return Err(bad(*status, detail.clone()));
                }
                // A resume answers with the runtime id; for the stored pointer they agree. A mint
                // answers with a key of its own, which is the one the caller must keep.
                let minted = if req.pet.is_some() { self.minted.clone() } else { None };
                Ok(Delivered {
                    session_id: minted
                        .clone()
                        .unwrap_or_else(|| req.stored.to_string()),
                    stored_session_id: minted,
                    reply: self.reply.clone(),
                })
            })
        }
    }

    /// The hand-off as it would have been written:
    /// (from_profile, from_label, to_profile, session_id, text, at).
    type Recorded = Vec<(Option<String>, String, String, Option<String>, String, f64)>;
    fn recorder(
        seen: &Mutex<Recorded>,
    ) -> impl Fn(Option<&str>, &str, &str, Option<&str>, &str, f64) + '_ {
        move |from_profile, from_label, to_profile, session_id, text, at| {
            seen.lock().unwrap().push((
                from_profile.map(str::to_string),
                from_label.to_string(),
                to_profile.to_string(),
                session_id.map(str::to_string),
                text.to_string(),
                at,
            ));
        }
    }

    // ---- labels and validation --------------------------------------------------------------

    #[test]
    fn the_label_carries_sender_profile_target_and_bare_words() {
        assert_eq!(
            label("assistant", "ops", "  hello there  ", None),
            "Assistant → Ops: hello there"
        );
        assert_eq!(
            label("assistant", "ops", "hello", Some("cody")),
            "Assistant (cody) → Ops: hello"
        );
        // Python's str.title() lowercases the tail of a word; the app's parser expects that.
        assert_eq!(python_title("OPS"), "Ops");
        assert_eq!(python_title("cody bot"), "Cody Bot");
    }

    #[test]
    fn a_message_plan_maps_the_body_field_for_field() {
        let body = json!({"text": "  ship it  ", "from": "cody", "from_profile": "cody"});
        let plan = plan_message("ops", &body, false).unwrap();
        assert_eq!(plan.sender, "cody");
        assert_eq!(plan.sender_profile.as_deref(), Some("cody"));
        assert_eq!(plan.text, "ship it", "the transfer line is the words without the prefix");
        assert_eq!(plan.message, "Cody (cody) → Ops: ship it");
    }

    #[test]
    fn an_absent_from_defaults_to_assistant_and_null_from_profile_means_unnamed() {
        let plan = plan_message("ops", &json!({"text": "hi", "from_profile": null}), false).unwrap();
        assert_eq!(plan.sender, "assistant");
        assert_eq!(plan.sender_profile, None);
        assert_eq!(plan.message, "Assistant → Ops: hi");
    }

    #[test]
    fn a_bad_profile_name_is_a_422_and_a_disabled_bot_is_a_409() {
        for name in ["../ops", "ops/../x", "", "-ops", "a".repeat(65).as_str()] {
            let (status, body) = plan_message(name, &json!({"text": "hi"}), false).unwrap_err();
            assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{name:?}");
            assert_eq!(body.0["detail"], "invalid profile");
        }
        let (status, body) = plan_message("ops", &json!({"text": "hi"}), true).unwrap_err();
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(body.0["detail"], "ops is disabled");
    }

    #[test]
    fn missing_blank_and_oversized_text_are_refused() {
        let (status, body) = plan_message("ops", &json!({"text": "   "}), false).unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body.0["detail"], "text is required");

        let (status, body) = plan_message("ops", &json!({}), false).unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body.0["detail"], "text is required");

        let long = "x".repeat(MAX_TEXT + 1);
        let (status, body) = plan_message("ops", &json!({"text": long}), false).unwrap_err();
        assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(body.0["detail"], "text longer than 32000 characters");

        let (status, body) = plan_message("ops", &json!({"text": "hi", "from": "a\nb"}), false)
            .unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body.0["detail"], "invalid from");

        let (status, _) = plan_message("ops", &json!({"text": "hi", "from_profile": "a b"}), false)
            .unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    }

    #[test]
    fn an_ask_timeout_is_a_number_of_seconds_in_range() {
        assert_eq!(plan_ask("ops", &json!({"question": "q"}), false).unwrap().timeout, 300.0);
        assert_eq!(
            plan_ask("ops", &json!({"question": "q", "timeout": 5}), false).unwrap().timeout,
            5.0
        );
        for timeout in [json!(0), json!(301), json!("soon"), json!(null), json!(true)] {
            let body = json!({"question": "q", "timeout": timeout});
            let (status, payload) = plan_ask("ops", &body, false).unwrap_err();
            assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{timeout}");
            assert_eq!(payload.0["detail"], "timeout must be 1..300 seconds");
        }
    }

    #[test]
    fn no_conversation_yet_is_a_409_naming_the_verb() {
        let (status, body) = require_stored(None, "ops", "send").unwrap_err();
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(
            body.0["detail"],
            "ops has no conversation yet: open it in the app once, then send"
        );
        assert_eq!(require_stored(Some("s1".into()), "ops", "ask").unwrap(), "s1");
    }

    // ---- attachments -------------------------------------------------------------------------

    fn base64(bytes: &[u8]) -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn a_message_without_attachments_is_unchanged_on_the_wire() {
        // The contract every existing caller reads: six fields, no `attachments`.
        let body = json!({"text": "hi"});
        let plan = plan_message("ops", &body, false).unwrap();
        assert!(plan.attachments.is_empty());
        assert_eq!(plan.message, "Assistant → Ops: hi");
        let value = message_body(
            "ops",
            &plan,
            &Delivered { session_id: "s1".to_string(), stored_session_id: None, reply: None },
        );
        assert_eq!(value.as_object().unwrap().len(), 6);
        assert!(value.get("attachments").is_none());
    }

    #[test]
    fn a_spreadsheet_is_extracted_into_the_message_it_travels_with() {
        let bytes = office::fixtures::xlsx_fixture();
        let body = json!({
            "text": "here is the sheet",
            "from": "cody",
            "from_profile": "cody",
            "attachments": [{"name": "budget.xlsx", "data_base64": base64(&bytes)}],
        });
        let plan = plan_message("ops", &body, false).unwrap();

        // The label is still the first line, the blocks follow it.
        assert!(plan.message.starts_with("Cody (cody) → Ops: here is the sheet\n\n"), "{}", plan.message);
        assert!(plan.message.contains("--- attachment: budget.xlsx (sheet: Q4"), "{}", plan.message);
        assert!(plan.message.contains("North | 42"), "{}", plan.message);
        // The transfer record keeps the caller's words only: the attachment is not the hand-off.
        assert_eq!(plan.text, "here is the sheet");

        // One summary per attachment, with what was actually read.
        assert_eq!(plan.attachments.len(), 1);
        assert_eq!(plan.attachments[0]["name"], "budget.xlsx");
        assert_eq!(plan.attachments[0]["kind"], "xlsx");
        assert!(plan.attachments[0]["chars"].as_u64().unwrap() > 0);
        assert_eq!(plan.attachments[0]["truncated"], false);

        let value = message_body(
            "ops",
            &plan,
            &Delivered { session_id: "s1".to_string(), stored_session_id: None, reply: None },
        );
        assert_eq!(value["attachments"][0]["name"], "budget.xlsx");
        assert_eq!(value.as_object().unwrap().len(), 7);
    }

    #[test]
    fn a_data_url_and_a_pdf_both_work_and_the_engine_text_is_the_block() {
        let bytes = office::fixtures::pdf_fixture("Invoice 4711");
        let data_url = format!("data:application/pdf;base64,{}", base64(&bytes));
        let body = json!({
            "text": "invoice attached",
            "attachments": [{"name": "invoice.pdf", "data_url": data_url}],
        });
        let plan = plan_message("ops", &body, false).unwrap();
        assert!(plan.message.contains("Invoice 4711"), "{}", plan.message);
        assert!(plan.message.contains("--- attachment: invoice.pdf (pdf, 1 page) ---"));
        assert_eq!(plan.attachments[0]["kind"], "pdf");

        // A docx too, in the same message: two files, two blocks, one label.
        let docx = office::fixtures::docx_fixture();
        let two = json!({
            "text": "two files",
            "attachments": [
                {"name": "invoice.pdf", "data_base64": base64(&bytes)},
                {"name": "report.docx", "data_base64": base64(&docx)},
            ],
        });
        let plan = plan_message("ops", &two, false).unwrap();
        assert_eq!(plan.attachments.len(), 2);
        assert!(plan.message.contains("--- attachment: invoice.pdf"));
        assert!(plan.message.contains("--- attachment: report.docx"));
        assert!(plan.message.contains("# Quarterly report"));
    }

    #[test]
    fn a_mislabelled_or_unsupported_attachment_is_refused_with_the_file_named() {
        let pdf = office::fixtures::pdf_fixture("x");
        let body = json!({
            "text": "here",
            "attachments": [{"name": "budget.xlsx", "data_base64": base64(&pdf)}],
        });
        let (status, payload) = plan_message("ops", &body, false).unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        let detail = payload.0["detail"].as_str().unwrap();
        assert!(detail.contains("budget.xlsx"), "{detail}");
        assert!(detail.contains("Excel"), "{detail}");

        for (name, data) in [
            ("scan.heic", base64(&[0xff, 0x00, 0x01])),
            ("notes.bin", base64(b"\x00\x01binary")),
        ] {
            let body = json!({"text": "here", "attachments": [{"name": name, "data_base64": data}]});
            let (status, payload) = plan_message("ops", &body, false).unwrap_err();
            assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{name}");
            assert!(payload.0["detail"].as_str().unwrap().contains(name));
        }

        // A traversing name is refused before anything is decoded.
        let body = json!({
            "text": "here",
            "attachments": [{"name": "../etc/passwd", "data_base64": base64(b"a,b\n")}],
        });
        let (status, payload) = plan_message("ops", &body, false).unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(payload.0["detail"], "invalid attachment name: ../etc/passwd");
    }

    #[test]
    fn the_attachment_list_itself_is_bounded_and_strict() {
        let one = base64(b"a,b\n1,2\n");
        let body = json!({"text": "x", "attachments": [{"name": "a.csv", "data_base64": one}]});
        assert!(plan_message("ops", &body, false).is_ok());

        // Wrong shape, too many, both encodings, no encoding, an extra field.
        for attachments in [
            json!("a.csv"),
            json!([{"name": "a.csv", "data_base64": one}, {"name": "b.csv", "data_base64": one},
                   {"name": "c.csv", "data_base64": one}, {"name": "d.csv", "data_base64": one},
                   {"name": "e.csv", "data_base64": one}]),
            json!([{"name": "a.csv", "data_base64": one, "data_url": format!("data:text/csv;base64,{one}")}]),
            json!([{"name": "a.csv"}]),
            json!([{"name": "a.csv", "data_base64": one, "path": "/etc/passwd"}]),
            json!([{"name": 7, "data_base64": one}]),
            json!([{ "data_base64": one }]),
        ] {
            let body = json!({"text": "x", "attachments": attachments});
            let (status, _) = plan_message("ops", &body, false).unwrap_err();
            assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{attachments}");
        }

        // A null is "no attachments", not an error: a client that always sends the key still works.
        let body = json!({"text": "x", "attachments": null});
        assert!(plan_message("ops", &body, false).unwrap().attachments.is_empty());
        let body = json!({"text": "x", "attachments": []});
        assert!(plan_message("ops", &body, false).unwrap().attachments.is_empty());
    }

    #[test]
    fn an_ask_refuses_attachments_rather_than_dropping_them() {
        let body = json!({
            "question": "what is in this?",
            "attachments": [{"name": "a.csv", "data_base64": base64(b"a,b\n")}],
        });
        let (status, payload) = plan_ask("ops", &body, false).unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(payload.0["detail"], "ask does not take attachments: use message");
    }

    #[tokio::test]
    async fn a_delivered_attachment_reaches_the_engine_as_text() {
        let dir = scratch("attachments");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "s1");
        let engine = FakeEngine::default();
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());
        let bytes = office::fixtures::docx_fixture();
        let raw = json!({
            "text": "the report",
            "attachments": [{"name": "report.docx", "data_base64": base64(&bytes)}],
        })
        .to_string();

        let value = run_message(&st, "ops", raw.as_bytes(), &engine, &recorder(&recorded))
            .await
            .expect("delivered");

        // What the engine was actually asked to read: the text of the document, not its name.
        let seen = engine.seen.lock().unwrap();
        assert!(seen[0].2.contains("the report"));
        assert!(seen[0].2.contains("| Region | Revenue |"), "{}", seen[0].2);
        assert_eq!(value["attachments"][0]["kind"], "docx");
        // The record of the hand-off is still the words, not the document.
        assert_eq!(recorded.lock().unwrap()[0].4, "the report");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- the routes -------------------------------------------------------------------------

    #[tokio::test]
    async fn a_message_is_delivered_unqueued_and_the_response_matches_the_contract() {
        let dir = scratch("send");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "20260101_000000_abcdef");
        let engine = FakeEngine { reply: Some("on it".to_string()), ..Default::default() };
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let value = run_message(
            &st,
            "ops",
            br#"{"text":"ship it","from":"cody","from_profile":"cody"}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .expect("delivered");

        assert_eq!(value["profile"], "ops");
        assert_eq!(value["from"], "cody");
        assert_eq!(value["session_id"], "20260101_000000_abcdef");
        assert_eq!(value["text"], "Cody (cody) → Ops: ship it");
        assert_eq!(value["reply"], "on it");
        assert_eq!(value["delivered"], true);
        assert_eq!(value.as_object().unwrap().len(), 6, "no field beyond the contract");

        let seen = engine.seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].0, "ops");
        assert_eq!(seen[0].1, "20260101_000000_abcdef", "the stored pointer is what is resumed");
        assert_eq!(seen[0].2, "Cody (cody) → Ops: ship it");
        assert!(!seen[0].3, "a plain message must not be marked queued");
        assert!(!seen[0].4, "a message is never the pet's: the pet only ever asks");

        // The hand-off the apps read back: who spoke to whom, the bare words, no prefix.
        let entries = recorded.lock().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0.as_deref(), Some("cody"));
        assert_eq!(entries[0].1, "cody");
        assert_eq!(entries[0].2, "ops");
        assert_eq!(
            entries[0].3.as_deref(),
            Some("20260101_000000_abcdef"),
            "the row is tied to the conversation it landed in"
        );
        assert_eq!(entries[0].4, "ship it");
        assert!(entries[0].5 > 0.0);
        assert_eq!(st.store.push_prompt("ops").unwrap().1, "program");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The route's audit record: who spoke, to which bot, how many bytes — never the words.
    #[tokio::test]
    async fn the_delivery_is_audited_by_size_not_text() {
        let dir = scratch("audit");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "20260101_000000_abcdef");
        let engine = FakeEngine {
            reply: Some("on it".to_string()),
            ..FakeEngine::default()
        };
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        run_message(
            &st,
            "ops",
            br#"{"text":"ship it","from":"cody","from_profile":"cody"}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .unwrap();

        let record = st.audit.last("bot_message").expect("the send is recorded");
        assert_eq!(record["profile"], "ops");
        assert_eq!(record["method"], "cody");
        assert_eq!(record["outcome"], "replied");
        assert_eq!(record["bytes"], "Cody (cody) → Ops: ship it".len());
        assert!(record.get("text").is_none());
        let line = std::fs::read_to_string(st.audit.path()).unwrap_or_default();
        assert!(!line.contains("ship it"), "the message body reached the audit file");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_delivery_without_a_reply_is_still_delivered() {
        let dir = scratch("timeout");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "s1");
        let engine = FakeEngine::default();
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let value = run_message(&st, "ops", br#"{"text":"fyi"}"#, &engine, &recorder(&recorded))
            .await
            .unwrap();
        assert_eq!(value["delivered"], true);
        assert_eq!(value["reply"], Value::Null);
        assert_eq!(value["text"], "Assistant → Ops: fyi");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_ask_is_queued_and_returns_the_owners_next_user_row() {
        let dir = scratch("ask");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "s1");
        // The owner's answer, deliberately in the future so it is after the ask.
        let profile_dir = dir.join("engine").join("profiles").join("ops");
        std::fs::create_dir_all(&profile_dir).unwrap();
        let conn = Connection::open(profile_dir.join("state.db")).unwrap();
        conn.execute_batch(
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, \
             role TEXT, content TEXT, timestamp REAL);",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO messages (session_id, role, content, timestamp) \
             VALUES ('s1','user','yes, keep going', ?1)",
            rusqlite::params![unix_now() + 5.0],
        )
        .unwrap();
        drop(conn);

        let engine = FakeEngine::default();
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());
        let value = run_ask(
            &st,
            "ops",
            br#"{"question":"Should I keep going?","from":"cody"}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .expect("asked");

        assert_eq!(value["profile"], "ops");
        assert_eq!(value["from"], "cody");
        assert_eq!(value["session_id"], "s1");
        assert_eq!(value["question"], "Cody → Ops: Should I keep going?");
        assert_eq!(value["reply"], "yes, keep going");
        assert_eq!(value["answered"], true);
        assert_eq!(value.as_object().unwrap().len(), 6);

        let seen = engine.seen.lock().unwrap();
        assert!(seen[0].3, "an ask must be queued, not steered into a running turn");
        assert_eq!(seen[0].1, "s1", "a normal ask takes the bot's own conversation");
        assert!(!seen[0].4, "a normal ask is never the pet's");
        drop(seen);
        assert_eq!(
            st.store.get_bot_pet_session("ops"),
            None,
            "a normal ask must not give the pet a session of its own"
        );
        let entries = recorded.lock().unwrap();
        assert_eq!(entries[0].3.as_deref(), Some("s1"));
        assert_eq!(entries[0].4, "Should I keep going?");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_unanswered_ask_times_out_as_answered_false() {
        let dir = scratch("ask-timeout");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "s1");
        let engine = FakeEngine::default();
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let started = std::time::Instant::now();
        let value = run_ask(
            &st,
            "ops",
            br#"{"question":"Anyone there?","timeout":1}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .expect("a timeout is not an error");
        assert_eq!(value["answered"], false);
        assert_eq!(value["reply"], Value::Null);
        assert!(started.elapsed() >= Duration::from_millis(900), "it must actually wait");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- the desktop pet's bounded session ----------------------------------------------------

    /// Create (or keep using) a profile `state.db` where `session` already holds a row `role`
    /// written after "now" — the answer an ask is waiting for, so it resolves instead of waiting
    /// out its timeout. A pet waits for `assistant`; an owner-awaiting ask waits for `user`.
    fn answered_in(dir: &FsPath, profile: &str, session: &str, role: &str, content: &str) {
        let profile_dir = dir.join("engine").join("profiles").join(profile);
        std::fs::create_dir_all(&profile_dir).unwrap();
        let conn = Connection::open(profile_dir.join("state.db")).unwrap();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, \
             role TEXT, content TEXT, timestamp REAL);",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO messages (session_id, role, content, timestamp) \
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![session, role, content, unix_now() + 5.0],
        )
        .unwrap();
        drop(conn);
    }

    /// The same database with `rows` more transcript rows in `session` — the window's own filler.
    fn seed_messages(dir: &FsPath, profile: &str, session: &str, rows: i64) {
        answered_in(dir, profile, session, "assistant", "hi back");
        let profile_dir = dir.join("engine").join("profiles").join(profile);
        let conn = Connection::open(profile_dir.join("state.db")).unwrap();
        for index in 0..rows {
            conn.execute(
                "INSERT INTO messages (session_id, role, content, timestamp) VALUES (?1, 'user', ?2, ?3)",
                rusqlite::params![session, format!("q{index}"), unix_now() + index as f64],
            )
            .unwrap();
        }
        drop(conn);
    }

    #[test]
    fn only_the_balloons_own_sender_takes_the_pet_route() {
        assert!(
            plan_ask("ops", &json!({"question": "hi", "from": "desktop-pet"}), false)
                .unwrap()
                .pet
        );
        // Every other sender — including one that only looks close — keeps the conversation, and
        // so does a caller that sends no `from` at all.
        for sender in ["cody", "desktop pets", "Desktop-Pet", "desktop.pet", "assistant"] {
            assert!(
                !plan_ask("ops", &json!({"question": "hi", "from": sender}), false)
                    .unwrap()
                    .pet,
                "{sender}"
            );
        }
        assert!(!plan_ask("ops", &json!({"question": "hi"}), false).unwrap().pet);
    }

    #[test]
    fn a_pet_question_says_how_long_the_answer_may_be_and_other_asks_do_not() {
        let pet = plan_ask("ops", &json!({"question": "status?", "from": "desktop-pet"}), false)
            .unwrap();
        // The owner's words are still the first line, and the rule is one line of its own.
        assert!(pet.message.starts_with("Desktop Pet → Ops: status?"), "{}", pet.message);
        assert!(pet.message.ends_with(PET_BREVITY), "{}", pet.message);
        assert_eq!(pet.message.matches(PET_BREVITY).count(), 1, "one rule per question");
        assert!(PET_BREVITY.contains("two sentences"));
        assert!(PET_BREVITY.contains("plain text"));
        assert!(PET_BREVITY.contains("no lists"));

        // The bot's real chat — and every other sender — is byte for byte the label it always was.
        for sender in ["cody", "assistant", "desktop pets"] {
            let other = plan_ask("ops", &json!({"question": "hi", "from": sender}), false).unwrap();
            assert_eq!(other.message, label(sender, "ops", "hi", None), "{sender}");
            assert!(!other.message.contains(PET_BREVITY), "{sender}");
        }
    }

    #[tokio::test]
    async fn a_pet_ask_needs_no_conversation_and_mints_its_own_session() {
        let dir = scratch("pet-mint");
        let st = test_state(&dir);
        // No `bot_sessions` row at all: the endless conversation does not exist yet, and a balloon
        // question must not be the thing that needs it to.
        answered_in(&dir, "ops", "20260101_000001_petpet", "assistant", "hi back");
        let engine = FakeEngine {
            reply: Some("hi".to_string()),
            minted: Some("20260101_000001_petpet".to_string()),
            ..Default::default()
        };
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let value = run_ask(
            &st,
            "ops",
            br#"{"question":"hi","from":"desktop-pet","await":"bot","timeout":300}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .expect("the pet makes its own session, so no conversation is required");

        let seen = engine.seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].1, "", "a first pet ask resumes nothing — it mints");
        assert!(seen[0].4, "the delivery must be marked as the pet's");
        assert!(seen[0].3, "an ask is queued either way");
        drop(seen);

        // The minted key is the pointer the pet keeps and the id the answer is reported under.
        assert_eq!(
            st.store.get_bot_pet_session("ops").as_deref(),
            Some("20260101_000001_petpet")
        );
        assert_eq!(
            st.store.get_bot_session("ops"),
            None,
            "minting a pet session must not create a conversation the app would open"
        );
        assert_eq!(value["session_id"], "20260101_000001_petpet");
        assert_eq!(value["reply"], "hi back");
        assert_eq!(value["answered"], true);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_pet_ask_resumes_the_pets_session_and_leaves_the_conversation_alone() {
        let dir = scratch("pet-resume");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "endless");
        st.store.set_bot_pet_session("ops", "pet1");
        answered_in(&dir, "ops", "pet1", "assistant", "hi back");
        let engine = FakeEngine { reply: Some("hi".to_string()), ..Default::default() };
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let value = run_ask(
            &st,
            "ops",
            br#"{"question":"hi","from":"desktop-pet","await":"bot","timeout":300}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .expect("asked");

        let seen = engine.seen.lock().unwrap();
        assert_eq!(seen[0].1, "pet1", "the pet's own session is what is resumed");
        assert!(seen[0].4);
        drop(seen);
        assert_eq!(value["session_id"], "pet1");
        assert_eq!(value["reply"], "hi back");
        assert_eq!(
            st.store.get_bot_session("ops").as_deref(),
            Some("endless"),
            "the conversation the app opens is byte-for-byte where it was"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_normal_ask_still_takes_the_bots_conversation_and_never_the_pets() {
        let dir = scratch("pet-normal");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "endless");
        st.store.set_bot_pet_session("ops", "pet1");
        answered_in(&dir, "ops", "endless", "user", "yes, keep going");
        let engine = FakeEngine { reply: Some("yes, keep going".to_string()), ..Default::default() };
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let value = run_ask(
            &st,
            "ops",
            br#"{"question":"Should I keep going?","from":"cody"}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .expect("asked");

        let seen = engine.seen.lock().unwrap();
        assert_eq!(seen[0].1, "endless", "the bot's conversation is still the route");
        assert!(!seen[0].4, "a normal ask is never marked as the pet's");
        drop(seen);
        assert_eq!(value["session_id"], "endless");
        assert_eq!(value["reply"], "yes, keep going");
        assert_eq!(
            st.store.get_bot_pet_session("ops").as_deref(),
            Some("pet1"),
            "a normal ask must not move the pet's pointer"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_pet_window_at_the_cap_starts_over_instead_of_growing() {
        let dir = scratch("pet-window");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "endless");
        st.store.set_bot_pet_session("ops", "oldpet");
        seed_messages(&dir, "ops", "oldpet", PET_WINDOW);
        answered_in(&dir, "ops", "newpet", "assistant", "hi back");
        let engine = FakeEngine {
            reply: Some("hi".to_string()),
            minted: Some("newpet".to_string()),
            ..Default::default()
        };
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let value = run_ask(
            &st,
            "ops",
            br#"{"question":"hi","from":"desktop-pet","await":"bot","timeout":300}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .expect("asked");

        let seen = engine.seen.lock().unwrap();
        assert_eq!(seen[0].1, "", "a window at the cap rotates rather than grows");
        assert!(seen[0].4);
        drop(seen);
        assert_eq!(st.store.get_bot_pet_session("ops").as_deref(), Some("newpet"));
        assert_eq!(
            st.store.get_bot_session("ops").as_deref(),
            Some("endless"),
            "the conversation is not what rotated"
        );
        assert_eq!(value["session_id"], "newpet");
        assert_eq!(value["reply"], "hi back");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // `#[tokio::test]` because `test_state` builds the display hub, which needs a runtime — the
    // test itself is pure file reading.
    #[tokio::test]
    async fn the_pets_model_is_only_ever_a_name_the_profiles_own_config_carries() {
        let dir = scratch("pet-model");
        let st = test_state(&dir);
        let root = dir.join("engine").join("profiles").join("ops");
        std::fs::create_dir_all(&root).unwrap();
        let write = |doc: &str| std::fs::write(root.join("config.yaml"), doc).unwrap();

        // The shipped shape: the default is already a fast model, so it is the one pinned.
        write("model:\n  default: mimo-v2.6-flash\n  provider: opencode-go\nfallback_providers:\n\
               - provider: opencode-go\n  model: glm-5.3-flash\n");
        assert_eq!(
            pet_model(&st, "ops"),
            Some(("mimo-v2.6-flash".to_string(), "opencode-go".to_string()))
        );

        // A default that is not fast falls through to the first fast entry the config names itself.
        write("model:\n  default: gpt-5.2\n  provider: anthropic\nfallback_providers:\n\
               - provider: opencode-go\n  model: deepseek-v4.1-flash\n");
        assert_eq!(
            pet_model(&st, "ops"),
            Some(("deepseek-v4.1-flash".to_string(), "opencode-go".to_string()))
        );

        // No fast name anywhere: no pin at all, rather than a model we invented.
        write("model:\n  default: gpt-5.2\n  provider: anthropic\n");
        assert_eq!(pet_model(&st, "ops"), None);

        // A profile with no config file: same answer, no error.
        std::fs::remove_file(root.join("config.yaml")).unwrap();
        assert_eq!(pet_model(&st, "ops"), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_unknown_profile_is_a_422_and_a_bot_without_a_conversation_a_409() {
        let dir = scratch("errors");
        let st = test_state(&dir);
        let engine = FakeEngine::default();
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let (status, body) = run_message(
            &st,
            "ops/x",
            br#"{"text":"hi"}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .unwrap_err();
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body.0["detail"], "invalid profile");

        let (status, body) = run_message(
            &st,
            "ghost",
            br#"{"text":"hi"}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .unwrap_err();
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(
            body.0["detail"],
            "ghost has no conversation yet: open it in the app once, then send"
        );

        let (status, body) = run_ask(
            &st,
            "ghost",
            br#"{"question":"q"}"#,
            &engine,
            &recorder(&recorded),
        )
        .await
        .unwrap_err();
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(
            body.0["detail"],
            "ghost has no conversation yet: open it in the app once, then ask"
        );
        assert!(engine.seen.lock().unwrap().is_empty(), "a refused request never reaches the engine");
        assert!(recorded.lock().unwrap().is_empty(), "and it records no hand-off");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_gateway_refusal_keeps_its_status_and_writes_no_transfer() {
        let dir = scratch("refused");
        let st = test_state(&dir);
        st.store.set_bot_session("ops", "s1");
        let engine = FakeEngine {
            fail: Some((
                StatusCode::CONFLICT,
                "the stored session no longer exists; open the bot in the app".to_string(),
            )),
            ..Default::default()
        };
        let recorded: Mutex<Recorded> = Mutex::new(Vec::new());

        let (status, body) =
            run_message(&st, "ops", br#"{"text":"hi"}"#, &engine, &recorder(&recorded))
                .await
                .unwrap_err();
        assert_eq!(status, StatusCode::CONFLICT);
        assert!(body.0["detail"].as_str().unwrap().contains("no longer exists"));
        assert!(recorded.lock().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn only_a_direct_loopback_caller_passes_and_a_proxied_one_is_a_404() {
        let peer: SocketAddr = "127.0.0.1:5000".parse().unwrap();
        assert!(require_loopback(&peer, &HeaderMap::new()).is_ok());

        let mut proxied = HeaderMap::new();
        proxied.insert("x-forwarded-for", "1.2.3.4".parse().unwrap());
        let (status, body) = require_loopback(&peer, &proxied).unwrap_err();
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body.0["detail"], "not found");

        let remote: SocketAddr = "10.0.0.7:5000".parse().unwrap();
        let (status, _) = require_loopback(&remote, &HeaderMap::new()).unwrap_err();
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[test]
    fn the_owner_reply_query_skips_blank_and_assistant_rows() {
        let dir = scratch("owner-reply");
        let profile_dir = dir.join("aria");
        std::fs::create_dir_all(&profile_dir).unwrap();
        let conn = Connection::open(profile_dir.join("state.db")).unwrap();
        conn.execute_batch(
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, \
             role TEXT, content TEXT, timestamp REAL);",
        )
        .unwrap();
        for (role, content, at) in [
            ("user", "  ", 6.0),            // blank: not an answer
            ("assistant", "thinking", 7.0), // the bot's own row: not an answer
            ("user", "yes, keep going", 8.0),
        ] {
            conn.execute(
                "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('s1', ?, ?, ?)",
                rusqlite::params![role, content, at],
            )
            .unwrap();
        }
        drop(conn);

        assert_eq!(owner_reply(&dir.join("aria").join("state.db"), "s1", 5.0, "user").as_deref(), Some("yes, keep going"));
        // Nothing newer than the answer: the wait would keep polling.
        assert_eq!(owner_reply(&dir.join("aria").join("state.db"), "s1", 20.0, "user"), None);
        // Another conversation's rows are not this bot's answer.
        assert_eq!(owner_reply(&dir.join("aria").join("state.db"), "s2", 0.0, "user"), None);
        // A profile with no database at all is not an error.
        assert_eq!(owner_reply(&dir.join("ghost").join("state.db"), "s1", 0.0, "user"), None);

        // A desktop pet asks the bot itself: the bot's own row is the answer there, and the owner's
        // `user` row is the question. Waiting for the wrong side is what made every pet question time
        // out while the reply sat in the transcript.
        assert_eq!(
            owner_reply(&dir.join("aria").join("state.db"), "s1", 6.5, "assistant").as_deref(),
            Some("thinking")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
