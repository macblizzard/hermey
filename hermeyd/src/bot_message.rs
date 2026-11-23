//! One bot speaking to another, in the conversation the owner actually sees.
//!
//! Ported from `Bridge/hermes_bridge/bot_message.py`, which is the contract the apps were written
//! against. Two routes, both loopback-only operator commands (no device ticket, like `/v1/pair/start`):
//!
//! ```text
//! POST /v1/bots/{profile}/message   {"text": "…", "from": "assistant", "from_profile": "cody"}
//!   -> {"profile", "from", "session_id", "text", "reply", "delivered": true}
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
//! Delivery is *queued semantics*, not a promise of a reply: a busy session steers or queues (an
//! `ask` marks its prompt `queued: true` so a running turn holds it instead of swallowing it into
//! the reply). A timeout returns `delivered: true, reply: null`, so the caller reports "sent, no
//! answer yet" instead of "failed".
//!
//! Status codes, identical to the bridge: 404 (non-loopback, or a proxied caller), 422 (bad profile,
//! missing/blank/long text, bad `from`, bad `from_profile`, bad `timeout`), 409 (disabled bot, no
//! conversation yet, stale pointer), 413 (text over the cap), 502/503/504 (gateway faults).

use crate::engine_client::engine_url;
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
    let who = match sender_profile {
        Some(profile) => format!("{} ({profile})", python_title(sender)),
        None => python_title(sender),
    };
    format!("{who} → {}: {}", python_title(target), text.trim())
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
    /// The labelled row that is submitted into the target's conversation.
    pub message: String,
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

    Ok(MessagePlan {
        text: text.trim().to_string(),
        message: label(sender, profile, text, sender_profile.as_deref()),
        sender: sender.to_string(),
        sender_profile,
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
        text: question.trim().to_string(),
        message: label(sender, profile, question, sender_profile.as_deref()),
        sender: sender.to_string(),
        sender_profile,
        timeout,
    })
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

// ---- delivery -------------------------------------------------------------------------------

#[derive(Clone, Copy)]
pub(crate) struct DeliverRequest<'a> {
    pub profile: &'a str,
    pub stored: &'a str,
    pub message: &'a str,
    /// `queued: true` holds the prompt behind a running turn instead of steering into it. An `ask`
    /// is queued; a plain message is not.
    pub queued: bool,
}

#[derive(Debug)]
pub(crate) struct Delivered {
    pub session_id: String,
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

/// Resume the stored session *within its profile*, submit, and wait for that session's completion.
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
                    "jsonrpc": "2.0", "id": 1, "method": "client.capabilities",
                    // No approvals: a bot speaking to a bot must never pick up a pending request
                    // meant for the owner's device.
                    "params": { "server_requests": false },
                })
                .to_string()
                .into(),
            ))
            .await
            .map_err(|_| bad(StatusCode::BAD_GATEWAY, "gateway closed the connection"))?;
        socket
            .send(Message::Text(
                json!({
                    "jsonrpc": "2.0", "id": 2, "method": "session.resume",
                    "params": { "session_id": req.stored, "profile": req.profile },
                })
                .to_string()
                .into(),
            ))
            .await
            .map_err(|_| bad(StatusCode::BAD_GATEWAY, "gateway closed the connection"))?;

        let runtime_id = loop {
            match read_frame(&mut socket, deadline).await? {
                Frame::Value(frame) if frame_id(&frame, 2) => {
                    if let Some(error) = frame.get("error") {
                        // -32001 is the gateway's "session not found"; the pointer is stale.
                        if error.get("code").and_then(|v| v.as_i64()) == Some(-32001) {
                            return Err(bad(
                                StatusCode::CONFLICT,
                                "the stored session no longer exists; open the bot in the app",
                            ));
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
                        break id.to_string();
                    }
                }
                Frame::Value(_) => continue,
                Frame::Timeout => return Err(bad(StatusCode::GATEWAY_TIMEOUT, "gateway did not resume the session")),
                Frame::Closed => return Err(bad(StatusCode::BAD_GATEWAY, "gateway closed the connection")),
            }
        };

        socket
            .send(Message::Text(
                json!({
                    "jsonrpc": "2.0", "id": 3, "method": "prompt.submit",
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
            if frame_id(&frame, 3) {
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
        Ok(Delivered { session_id: runtime_id, reply })
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
    json!({
        "profile": profile,
        "from": plan.sender,
        "session_id": delivered.session_id,
        "text": plan.message,
        "reply": delivered.reply,
        "delivered": true,
    })
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
    let stored = require_stored(st.store.get_bot_session(profile), profile, "ask")?;

    st.store.set_push_prompt(profile, "program");
    // Queued on purpose: a busy turn must hold the question, not steer it into the running reply.
    let delivered = engine
        .deliver(DeliverRequest {
            profile,
            stored: &stored,
            message: &plan.message,
            queued: true,
        })
        .await?;

    let databases = profile_databases(st, profile);
    // The question's own row is the anchor; failing to find it (an engine that has not written yet)
    // falls back to now, which is only wrong by the delivery time.
    let asked_at = databases
        .iter()
        .find_map(|db| question_row_time(db, &stored, &plan.message))
        .unwrap_or_else(unix_now);
    // The stored id, not `delivered.session_id`: the engine hands back a *runtime* id, while the
    // transcript is written under the stored one. Querying the runtime id found nothing, which is
    // why a pet's question could sit answered in the chat and still time out.
    let reply = wait_for_owner_reply(
        databases,
        stored.clone(),
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
    Ok(ask_body(profile, &plan, &stored, reply.as_deref()))
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
            attachments_dir: dir.join("attachments"),
            local_token: std::sync::Arc::new(crate::local_token::LocalToken::from_value(
                "test-local-token",
                dir.join("local.token"),
            )),
            audit: std::sync::Arc::new(crate::audit::AuditLog::in_dir(dir)),
        }
    }

    #[derive(Default)]
    struct FakeEngine {
        seen: Mutex<Vec<(String, String, String, bool)>>,
        reply: Option<String>,
        fail: Option<(StatusCode, String)>,
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
                ));
                if let Some((status, detail)) = &self.fail {
                    return Err(bad(*status, detail.clone()));
                }
                Ok(Delivered {
                    // A resume answers with the runtime id; for the stored pointer they agree.
                    session_id: req.stored.to_string(),
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
