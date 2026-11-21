//! Local computers: an owner's Mac offers itself as a machine bots may use.
//!
//! The Mac app holds a **socket to this host**; nothing is reachable inbound to the Mac. The host routes
//! work down that socket and waits for the answer.
//!
//! ```text
//! GET  /v1/local-computers                  -> [{device_id, name, connected, connected_at, last_seen}]
//! WS   /v1/local-computers/ws?ticket=       the Mac's channel
//! POST /v1/local-computers/{id}/execute     {command|argv, cwd?, timeout_ms?}
//! POST /v1/local-computers/{id}/observe     -> screenshot + active window
//! POST /v1/local-computers/{id}/act         {actions:[…], bot}
//! POST /v1/local-computers/{id}/file        {op: read|write|list|mkdir, path, content_base64?}
//! POST /v1/local-computers/{id}/browser     {op: navigate|snapshot|act|downloads, …}
//! GET  /v1/local-computers/skill            -> what the Mac reports about the computer-use skill
//! DELETE /v1/local-computers/{id}           revoke
//! POST /v1/local-computers/{id}/enable      undo a revoke
//! ```
//!
//! Consent model, matching the bridge exactly:
//!
//! * **The Mac decides.** It dials out, it can be revoked, and a revoke is undoable (`enable`) — revoking
//!   once was a one-way door that left a Mac reconnecting forever with no way back.
//! * **Accept first, then close with a code.** Closing a websocket before `accept()` reaches the client as
//!   a bare HTTP error, so a rejected Mac shows nothing useful: `4401` bad ticket, `4403` revoked.
//! * **Freshness is explicit.** The host pings every 20 s and treats a computer as stale after 55 s, and
//!   answers the Mac's own pings, because a peer that closes instead of ponging churns the link.
//! * **Results are redacted** before they leave the host, so a command's output cannot carry a credential
//!   into the app's transcript.

use crate::routes::{require_device, AppState};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, oneshot};

/// Calls in flight, keyed by the id this host minted. A Mac answers with the same id.
mod replies {
    use super::*;
    use std::sync::OnceLock;

    type Table = Mutex<HashMap<String, oneshot::Sender<Value>>>;

    fn table() -> &'static Table {
        static TABLE: OnceLock<Table> = OnceLock::new();
        TABLE.get_or_init(|| Mutex::new(HashMap::new()))
    }

    pub fn register(id: &str, tx: oneshot::Sender<Value>) {
        table().lock().unwrap().insert(id.to_string(), tx);
    }

    pub fn resolve(id: &str, value: Value) {
        if let Some(tx) = table().lock().unwrap().remove(id) {
            let _ = tx.send(value);
        }
    }

    pub fn drop_pending(id: &str) {
        table().lock().unwrap().remove(id);
    }
}

/// Progress frames of a streamed execute, keyed by the same call id. The Mac sends `progress`
/// frames while a command still runs; `execute-stream` forwards each one as its own NDJSON line.
mod progress {
    use super::*;
    use std::sync::OnceLock;

    type Table = Mutex<HashMap<String, mpsc::UnboundedSender<Value>>>;

    fn table() -> &'static Table {
        static TABLE: OnceLock<Table> = OnceLock::new();
        TABLE.get_or_init(|| Mutex::new(HashMap::new()))
    }

    pub fn register(id: &str, tx: mpsc::UnboundedSender<Value>) {
        table().lock().unwrap().insert(id.to_string(), tx);
    }

    /// Forward one progress frame to the streaming caller, if one is still listening.
    pub fn forward(id: &str, value: Value) -> bool {
        let table = table().lock().unwrap();
        table.get(id).map(|tx| tx.send(value).is_ok()).unwrap_or(false)
    }

    pub fn drop_pending(id: &str) {
        table().lock().unwrap().remove(id);
    }
}

/// axum's WebSocket has no `close_with`; a close frame carries the code the Mac shows.
async fn close_with(socket: &mut WebSocket, code: u16, reason: &str) {
    let _ = socket
        .send(Message::Close(Some(axum::extract::ws::CloseFrame {
            code,
            reason: reason.to_string().into(),
        })))
        .await;
}

const PING_EVERY: Duration = Duration::from_secs(20);
const STALE_AFTER: Duration = Duration::from_secs(55);
const DEFAULT_TIMEOUT_MS: u64 = 900_000;
const MAX_TIMEOUT_MS: u64 = 1_800_000;
const CLOSE_BAD_TICKET: u16 = 4401;
const CLOSE_REVOKED: u16 = 4403;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

fn now_epoch() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// One live Mac.
struct Computer {
    name: String,
    connected_at: f64,
    last_seen: Instant,
    tx: mpsc::UnboundedSender<Value>,
}

#[derive(Default)]
pub struct Registry {
    computers: Mutex<HashMap<String, Computer>>,
    revoked: Mutex<Vec<String>>,
}

impl Registry {
    pub fn list(&self) -> Vec<Value> {
        let map = self.computers.lock().unwrap();
        map.iter()
            .map(|(id, c)| {
                json!({
                    "device_id": id,
                    "name": c.name,
                    "connected": c.last_seen.elapsed() < STALE_AFTER,
                    "connected_at": c.connected_at,
                    "last_seen": now_epoch() - c.last_seen.elapsed().as_secs_f64(),
                })
            })
            .collect()
    }

    fn is_revoked(&self, device_id: &str) -> bool {
        self.revoked.lock().unwrap().iter().any(|id| id == device_id)
    }

    fn revoke(&self, device_id: &str) -> bool {
        {
            let mut revoked = self.revoked.lock().unwrap();
            if !revoked.iter().any(|id| id == device_id) {
                revoked.push(device_id.to_string());
            }
        }
        // Dropping the sender closes the channel; the socket task sees it and closes with 4403.
        self.computers.lock().unwrap().remove(device_id).is_some()
    }

    fn allow(&self, device_id: &str) -> bool {
        let mut revoked = self.revoked.lock().unwrap();
        let before = revoked.len();
        revoked.retain(|id| id != device_id);
        revoked.len() != before
    }

    fn connected(&self, device_id: &str) -> Option<mpsc::UnboundedSender<Value>> {
        let map = self.computers.lock().unwrap();
        map.get(device_id).map(|c| c.tx.clone())
    }

    fn touch(&self, device_id: &str) {
        if let Some(c) = self.computers.lock().unwrap().get_mut(device_id) {
            c.last_seen = Instant::now();
        }
    }
}

/// Send one frame and wait for the Mac's answer with the same `id`. With `progress` set, any
/// `progress` frames the Mac streams for this call are forwarded to that sender as they arrive.
async fn dispatch_with_progress(
    st: &AppState,
    device_id: &str,
    payload: Value,
    timeout_ms: u64,
    progress: Option<mpsc::UnboundedSender<Value>>,
) -> Result<Value, Fail> {
    let Some(tx) = st.local_computers.connected(device_id) else {
        return Err(bad(StatusCode::SERVICE_UNAVAILABLE, "that computer is not connected"));
    };
    let call_id = crate::auth::random_token(9);
    let (reply_tx, reply_rx) = oneshot::channel();
    replies::register(&call_id, reply_tx);
    if let Some(progress_tx) = progress {
        progress::register(&call_id, progress_tx);
    }

    let mut frame = payload;
    frame["id"] = json!(call_id);
    if tx.send(frame).is_err() {
        replies::drop_pending(&call_id);
        progress::drop_pending(&call_id);
        return Err(bad(StatusCode::SERVICE_UNAVAILABLE, "that computer is not connected"));
    }

    let deadline = Duration::from_millis(timeout_ms.clamp(1_000, MAX_TIMEOUT_MS));
    let result = match tokio::time::timeout(deadline, reply_rx).await {
        Ok(Ok(value)) => Ok(redact(value)),
        Ok(Err(_)) => Err(bad(StatusCode::BAD_GATEWAY, "the computer dropped the call")),
        Err(_) => {
            replies::drop_pending(&call_id);
            Err(bad(StatusCode::GATEWAY_TIMEOUT, "the computer did not answer in time"))
        }
    };
    progress::drop_pending(&call_id);
    result
}

/// Send one frame and wait for the Mac's answer with the same `id`.
async fn dispatch(
    st: &AppState,
    device_id: &str,
    payload: Value,
    timeout_ms: u64,
) -> Result<Value, Fail> {
    dispatch_with_progress(st, device_id, payload, timeout_ms, None).await
}

/// Strip anything that looks like a credential before it reaches the app's transcript.
///
/// The replacement text must not contain the marker it replaced: replacing `api_key=…` with
/// `api_key[redacted]` re-matched on the next pass and looped forever, which showed up as a request that
/// never returned rather than as a crash. Scan with a cursor past each replacement, and keep every slice
/// on a char boundary — a byte offset from the lowercased string can land mid-character.
const SECRET_MARKERS: [&str; 9] = [
    "api_key", "api-key", "apikey", "authorization:", "bearer ", "password=", "token=", "secret=",
    "sk-",
];

fn scrub(text: &str) -> String {
    let mut out = text.to_string();
    for marker in SECRET_MARKERS {
        let mut cursor = 0usize;
        // Hard cap: a loop that cannot terminate in theory must terminate in practice — an unbounded
        // redaction pass once showed up as a request that never returned.
        for _ in 0..64 {
            let lower = out.to_lowercase();
            let Some(rel) = lower.get(cursor..).and_then(|tail| tail.find(marker)) else { break };
            let start = cursor + rel;
            let mut end = (start + marker.len() + 64).min(out.len());
            while end > start && !out.is_char_boundary(end) {
                end -= 1;
            }
            out.replace_range(start..end, "[redacted]");
            cursor = start + "[redacted]".len();
            if cursor >= out.len() {
                break;
            }
        }
    }
    out
}

fn redact(mut value: Value) -> Value {
    // Uses the module-level `scrub`: an older nested copy of this function lived inside `redact`, so
    // fixing the top-level one left the live path looping forever. One implementation, one place.
    match &mut value {
        Value::String(s) => Value::String(scrub(s)),
        Value::Array(items) => {
            for item in items.iter_mut() {
                *item = redact(item.clone());
            }
            value
        }
        Value::Object(map) => {
            for (_, v) in map.iter_mut() {
                *v = redact(v.clone());
            }
            value
        }
        _ => value,
    }
}

#[derive(Deserialize)]
pub struct TicketQuery {
    pub ticket: String,
}

pub async fn channel(
    ws: WebSocketUpgrade,
    State(st): State<Arc<AppState>>,
    Query(q): Query<TicketQuery>,
) -> Response {
    ws.on_upgrade(move |socket| run_channel(socket, st, q.ticket))
}

async fn run_channel(mut socket: WebSocket, st: Arc<AppState>, ticket: String) {
    // The socket is accepted first: closing before the upgrade reaches the Mac as a bare HTTP error and
    // shows nothing useful in its status line.
    let Some(device_id) = st.tickets.consume_ticket(ticket.trim()) else {
        close_with(&mut socket, CLOSE_BAD_TICKET, "ticket invalid or already used").await;
        return;
    };
    if st.local_computers.is_revoked(&device_id) {
        close_with(&mut socket, CLOSE_REVOKED, "this computer was revoked").await;
        return;
    }

    let mut name = device_id.clone();
    // The first frame must be the hello; anything else is a client we do not understand.
    match tokio::time::timeout(Duration::from_secs(10), socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => {
            if let Ok(frame) = serde_json::from_str::<Value>(&text) {
                if frame.get("type").and_then(|t| t.as_str()) != Some("hello") {
                    close_with(&mut socket, CLOSE_BAD_TICKET, "expected hello").await;
                    return;
                }
                if let Some(given) = frame.get("name").and_then(|n| n.as_str()) {
                    if !given.trim().is_empty() {
                        name = given.trim().chars().take(64).collect();
                    }
                }
            }
        }
        _ => {
            close_with(&mut socket, CLOSE_BAD_TICKET, "expected hello").await;
            return;
        }
    }

    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    st.local_computers.computers.lock().unwrap().insert(
        device_id.clone(),
        Computer { name: name.clone(), connected_at: now_epoch(), last_seen: Instant::now(), tx },
    );
    eprintln!("local computer connected: {device_id} ({name})");

    // `interval` fires its first tick immediately, which pinged a Mac the instant it connected. Start
    // one period out; the Mac answers pings either way, but an immediate one looks like churn.
    let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING_EVERY, PING_EVERY);
    loop {
        tokio::select! {
            outbound = rx.recv() => {
                let Some(frame) = outbound else {
                    // Registry dropped us: a revoke, or a newer socket replaced this one.
                    close_with(&mut socket, CLOSE_REVOKED, "this computer was revoked").await;
                    break;
                };
                if socket.send(Message::Text(frame.to_string().into())).await.is_err() {
                    break;
                }
            }
            incoming = socket.recv() => {
                let Some(Ok(message)) = incoming else { break };
                // Protocol-level pings are the peer's keepalive: unanswered, the client times the link
                // out and drops it mid-call (measured: websockets sent 1011 "keepalive ping timeout").
                if let Message::Ping(payload) = message {
                    let _ = socket.send(Message::Pong(payload)).await;
                    continue;
                }
                let Message::Text(text) = message else { continue };
                let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
                st.local_computers.touch(&device_id);
                match frame.get("type").and_then(|t| t.as_str()).unwrap_or("") {
                    "ping" => {
                        // The Mac pings too, so it can tell a live host from a socket that outlived it.
                        let _ = socket.send(Message::Text(json!({"type":"pong"}).to_string().into())).await;
                    }
                    "pong" => {}
                    "result" | "error" | "progress" => {
                        if let Some(call_id) = frame.get("id").and_then(|i| i.as_str()) {
                            if frame.get("type").and_then(|t| t.as_str()) == Some("progress") {
                                // A streamed execute is listening; without one this is dropped.
                                progress::forward(call_id, frame.clone());
                            } else {
                                replies::resolve(call_id, frame.clone());
                            }
                        }
                    }
                    _ => {}
                }
            }
            _ = ping.tick() => {
                if socket.send(Message::Text(json!({"type":"ping"}).to_string().into())).await.is_err() {
                    break;
                }
            }
        }
    }

    st.local_computers.computers.lock().unwrap().remove(&device_id);
    eprintln!("local computer disconnected: {device_id}");
}

pub async fn list(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    Ok(Json(json!(st.local_computers.list())))
}

#[derive(Deserialize)]
pub struct ExecuteBody {
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub argv: Option<Vec<String>>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

pub async fn execute(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    Json(body): Json<ExecuteBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    let mut payload = json!({"type": "execute"});
    if let Some(argv) = body.argv {
        payload["argv"] = json!(argv);
    } else if let Some(command) = body.command {
        payload["command"] = json!(command);
    } else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a command is required"));
    }
    if let Some(cwd) = body.cwd {
        payload["cwd"] = json!(cwd);
    }
    if let Some(ms) = body.timeout_ms {
        payload["timeout_ms"] = json!(ms);
    }
    let timeout = body.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    dispatch(&st, &device_id, payload, timeout).await.map(Json)
}

#[derive(Deserialize)]
pub struct ActBody {
    pub actions: Vec<Value>,
    #[serde(default)]
    pub bot: Option<String>,
}

pub async fn act(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    Json(body): Json<ActBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    if body.actions.is_empty() || body.actions.len() > 24 {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "1 to 24 actions per batch"));
    }
    let payload = json!({"type": "act", "actions": body.actions, "bot": body.bot});
    dispatch(&st, &device_id, payload, 60_000).await.map(Json)
}

pub async fn observe(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    dispatch(&st, &device_id, json!({"type": "observe"}), 30_000).await.map(Json)
}

pub async fn revoke(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    let was_connected = st.local_computers.revoke(&device_id);
    Ok(Json(json!({"device_id": device_id, "revoked": true, "was_connected": was_connected})))
}

pub async fn enable(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    let changed = st.local_computers.allow(&device_id);
    Ok(Json(json!({"device_id": device_id, "revoked": false, "changed": changed})))
}

pub async fn skill_placeholder() -> Response {
    // The skill is installed by the Mac app; this host has nothing to report until one connects.
    (StatusCode::NOT_FOUND, Json(json!({"detail": "no computer has reported a skill"}))).into_response()
}

/// `POST /v1/local-computers/skill` — the Mac's *Install* button.
///
/// The skills, their scripts and their rendered instructions are shipped inside this binary, so the
/// button re-runs the same install that boot performs (`skills::install`), exactly as the bridge's
/// route calls `agent_skills.install()`. It is idempotent by content: a second press writes nothing
/// and reports `current`, a changed template is picked up, and a skill the owner wrote themselves is
/// reported as `foreign` and left alone.
///
/// The hermeyd this replaces answered 501 ("written by the bridge, not by hermeyd"), which was true
/// while the bridge was the only writer and false — silently — on a hermeyd-only host, where no bot
/// ever received the instructions.
pub async fn skill_install(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    // Scripts live beside this service's own state, the one directory the unit lets it write
    // (`attachments_dir` is `<state>/attachments`). Same derivation as bot_admin::purge.
    let state_home = st
        .attachments_dir
        .parent()
        .map(std::path::Path::to_path_buf)
        .unwrap_or_else(|| st.attachments_dir.clone());
    let report = crate::skills::install(
        &st.engine_home,
        &state_home,
        crate::skills::host_os(),
        &crate::skills::Endpoints::from_process_env(&state_home),
    );
    Ok(Json(json!({
        "host": crate::skills::host_os(),
        "cli": report.cli.as_ref().map(|p| p.to_string_lossy().to_string()),
        "installed": report.installed(),
        "written": report.written(),
        "current": report.current(),
        "failed": report.failed(),
        "scripts_written": report.scripts_written,
        "script_error": report.script_error,
        "skills": Value::Object(report.skill_outcomes()),
        "targets": report.profiles.iter().map(|p| json!({
            "profile": p.profile,
            "dir": p.dir.to_string_lossy(),
            "written": p.count(&crate::skills::Outcome::Written),
            "current": p.count(&crate::skills::Outcome::Current),
            "failed": p.count(&crate::skills::Outcome::Failed(String::new())),
        })).collect::<Vec<_>>(),
    })))
}

// ---- execute-stream / file / resume -------------------------------------------------------------
// The three routes the bridge's local_computers.py serves beside execute. Same consent model: the
// Mac is dialed through its own channel, the answer is redacted, and nothing here touches the Mac
// beyond the frame it already understands.

/// The command part of an execute body, shared by `execute` and `execute-stream`: argv or a single
/// command string, plus optional cwd and timeout_ms.
fn execute_payload(body: &Value) -> Result<(Value, u64), Fail> {
    let mut payload = json!({"type": "execute"});
    if let Some(argv) = body.get("argv").and_then(|a| a.as_array()) {
        if argv.is_empty() || !argv.iter().all(|x| x.is_string()) {
            return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "argv must be a non-empty list of strings"));
        }
        payload["argv"] = json!(argv);
    } else if let Some(command) = body.get("command").and_then(|c| c.as_str()) {
        payload["command"] = json!(command);
    } else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a command is required"));
    }
    let timeout = match body.get("timeout_ms") {
        Some(value) => {
            let Some(ms) = value.as_u64() else {
                return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "timeout_ms must be an integer"));
            };
            if !(1_000..=MAX_TIMEOUT_MS).contains(&ms) {
                return Err(bad(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    format!("timeout_ms must be 1000..{MAX_TIMEOUT_MS}"),
                ));
            }
            ms
        }
        None => DEFAULT_TIMEOUT_MS,
    };
    payload["timeout_ms"] = json!(timeout);
    if let Some(cwd) = body.get("cwd").and_then(|c| c.as_str()) {
        payload["cwd"] = json!(cwd);
    }
    Ok((payload, timeout))
}

/// `POST /v1/local-computers/{device_id}/execute-stream` — one command, answered as NDJSON:
/// progress lines as they arrive, then the final result. A caller that does not read still gets its
/// answer, because the queue is bounded by the command's own output cap.
pub async fn execute_stream(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    Json(body): Json<Value>,
) -> Result<Response, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    // A caller that is not connected answers 503 before the stream starts — a stream has already
    // spent its status code by the time the Mac would fail to answer.
    if st.local_computers.connected(&device_id).is_none() {
        return Err(bad(StatusCode::SERVICE_UNAVAILABLE, "that computer is not connected"));
    }
    let (payload, timeout) = execute_payload(&body)?;

    let (progress_tx, mut progress_rx) = mpsc::unbounded_channel::<Value>();
    let (line_tx, line_rx) = mpsc::unbounded_channel::<Result<axum::body::Bytes, std::io::Error>>();
    let st2 = Arc::clone(&st);
    let dev = device_id.clone();
    let producer = tokio::spawn(async move {
        dispatch_with_progress(&st2, &dev, payload, timeout, Some(progress_tx)).await
    });
    tokio::spawn(async move {
        let mut saw_progress = false;
        while let Some(frame) = progress_rx.recv().await {
            // Progress is redacted before it leaves the host, exactly like a final frame.
            saw_progress = true;
            let line = serde_json::to_string(&redact(frame)).unwrap_or_else(|_| "{}".into());
            if line_tx.send(Ok(axum::body::Bytes::from(format!("{line}\n")))).is_err() {
                break;
            }
        }
        // The producer dropped its sender, so the queue is drained; now the final frame.
        let final_frame = match producer.await {
            Ok(Ok(value)) if saw_progress => {
                // The caller already saw every byte through the progress lines; repeating the whole
                // stream in the final frame would print the build twice.
                let mut trimmed = value.clone();
                if let Some(map) = trimmed.as_object_mut() {
                    map.remove("stdout");
                    map.remove("stderr");
                }
                trimmed
            }
            Ok(Ok(value)) => value,
            Ok(Err((status, fail))) => {
                // The stream has already started, so the failure is a final NDJSON line, not a
                // status code. It carries the same detail the non-streaming route would answer.
                let detail = fail
                    .0
                    .get("detail")
                    .and_then(|d| d.as_str())
                    .unwrap_or("the call failed")
                    .to_string();
                json!({"type": "error", "error": status.as_u16(), "detail": detail})
            }
            Err(_) => json!({"type": "error", "error": "the call could not complete"}),
        };
        let line = serde_json::to_string(&final_frame).unwrap_or_else(|_| "{}".into());
        let _ = line_tx.send(Ok(axum::body::Bytes::from(format!("{line}\n"))));
    });

    let stream = futures_util::stream::unfold(line_rx, |mut rx| async move {
        rx.recv().await.map(|item| (item, rx))
    });
    let mut response = Response::new(axum::body::Body::from_stream(stream));
    response.headers_mut().insert(
        axum::http::header::CONTENT_TYPE,
        axum::http::HeaderValue::from_static("application/x-ndjson"),
    );
    Ok(response)
}

/// `POST /v1/local-computers/{device_id}/file` — one workspace file operation: read, write, list or
/// mkdir. Paths are relative to the workspace and never leave it; a write is base64 and capped.
pub async fn file_op(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    let op = body.get("op").and_then(|o| o.as_str()).unwrap_or("");
    if !matches!(op, "read" | "write" | "list" | "mkdir") {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "op must be read, write, list or mkdir"));
    }
    let path = body.get("path").and_then(|p| p.as_str()).unwrap_or("");
    if path.is_empty() || path.starts_with('/') || path.split('/').any(|part| part == "..") {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "path must be relative to the workspace"));
    }
    let mut payload = json!({"type": "file", "op": op, "path": path});
    if op == "write" {
        let encoded = body
            .get("content_base64")
            .and_then(|c| c.as_str())
            .ok_or_else(|| bad(StatusCode::UNPROCESSABLE_ENTITY, "content_base64 is required"))?;
        use base64::Engine as _;
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(encoded.as_bytes())
            .map_err(|_| bad(StatusCode::UNPROCESSABLE_ENTITY, "content_base64 is not base64"))?;
        if decoded.len() > 4_000_000 {
            return Err(bad(StatusCode::PAYLOAD_TOO_LARGE, "file exceeds 4 MB"));
        }
        payload["content_base64"] = json!(encoded);
    }

    let result = dispatch(&st, &device_id, payload, 60_000).await?;
    let failed = result.get("error").map(|e| !e.is_null()).unwrap_or(false)
        || result.get("exit_code").and_then(|e| e.as_i64()).unwrap_or(0) != 0;
    if failed {
        let detail = result
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("the file operation failed")
            .to_string();
        return Err(bad(StatusCode::CONFLICT, scrub(&detail)));
    }
    let Some(file) = result.get("file").cloned() else {
        return Err(bad(StatusCode::BAD_GATEWAY, "the Mac returned no file payload"));
    };
    if !file.is_object() {
        return Err(bad(StatusCode::BAD_GATEWAY, "the Mac returned no file payload"));
    }
    Ok(Json(redact_file_payload(file)))
}

/// Decode `content_base64`, scrub it, and re-encode — but only when something changed, so a clean
/// payload is returned byte for byte.
fn redact_file_payload(mut file: Value) -> Value {
    let encoded = file.get("content_base64").and_then(|c| c.as_str()).map(str::to_string);
    let Some(encoded) = encoded else { return file };
    use base64::Engine as _;
    let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(encoded.as_bytes()) else {
        return file;
    };
    let Ok(text) = String::from_utf8(raw) else { return file };
    let clean = scrub(&text);
    if clean != text {
        let reencoded = base64::engine::general_purpose::STANDARD.encode(clean.as_bytes());
        file["content_base64"] = json!(reencoded);
    }
    file
}

/// `POST /v1/local-computers/{device_id}/resume` — hand control back to the bot after a takeover.
/// The Mac pauses on physical input and waits; this is the explicit release. Deliberately not an
/// approval: the owner is already looking at the machine.
pub async fn resume(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    let result = dispatch(&st, &device_id, json!({"type": "resume"}), 10_000).await?;
    let failed = result.get("error").map(|e| !e.is_null()).unwrap_or(false)
        || result.get("exit_code").and_then(|e| e.as_i64()).unwrap_or(0) != 0;
    if failed {
        let detail = result
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("the computer refused to resume")
            .to_string();
        return Err(bad(StatusCode::CONFLICT, scrub(&detail)));
    }
    Ok(Json(json!({"resumed": true})))
}

/// `POST /v1/local-computers/{device_id}/browser` — the Mac's own logged-in browser, driven through
/// its channel. Four operations, exactly as the bridge's `local_computers.py` serves them:
///
/// * `navigate` — `{url}`, http/https only;
/// * `snapshot` — the current page's shape;
/// * `act` — `{actions}`, 1..10 page actions;
/// * `downloads` — what the browser has downloaded.
///
/// The answer is the Mac's `browser` object, redacted like every other result.
pub async fn browser(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_id(&device_id) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid computer id"));
    }
    let op = body.get("op").and_then(|o| o.as_str()).unwrap_or("");
    if !matches!(op, "navigate" | "snapshot" | "act" | "downloads") {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "unsupported browser operation"));
    }
    let mut payload = json!({"type": "browser", "op": op});
    if op == "navigate" {
        let url = body.get("url").and_then(|u| u.as_str()).unwrap_or("");
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "url must be http or https"));
        }
        payload["url"] = json!(url);
    }
    if op == "act" {
        let actions = body.get("actions").and_then(|a| a.as_array()).cloned().unwrap_or_default();
        if actions.is_empty() || actions.len() > 10 {
            return Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                "actions must be a list of 1..10 objects",
            ));
        }
        payload["actions"] = json!(actions);
    }

    let result = dispatch(&st, &device_id, payload, 60_000).await?;
    let failed = result.get("error").map(|e| !e.is_null()).unwrap_or(false)
        || result.get("exit_code").and_then(|e| e.as_i64()).unwrap_or(0) != 0;
    if failed {
        let detail = result
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("the browser call failed")
            .to_string();
        return Err(bad(StatusCode::CONFLICT, scrub(&detail)));
    }
    // The bridge answers with `result["browser"]`; a Mac that answered nothing is a 502, not an
    // empty 200 that the app would render as a blank page.
    match result.get("browser") {
        Some(value) if value.is_object() => Ok(Json(value.clone())),
        _ => Err(bad(StatusCode::BAD_GATEWAY, "the Mac returned no browser payload")),
    }
}

#[cfg(test)]
mod redact_tests {
    use super::scrub;

    #[test]
    fn scrubs_secrets_and_terminates() {
        let out = scrub("token=abc123 and api_key=sk-live-9 done");
        assert!(!out.contains("abc123"), "token value survived: {out}");
        assert!(!out.contains("sk-live-9"), "api key survived: {out}");
        assert!(out.contains("[redacted]"), "nothing was replaced: {out}");
    }

    #[test]
    fn leaves_plain_text_alone() {
        assert_eq!(scrub("hello world"), "hello world");
    }
}
