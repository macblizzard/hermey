//! genui cards: the board host page, its assets, and the boards the plugin wrote.
//!
//! The apps draw a bot's generated-UI card in a `WKWebView` that loads `/v1/genui/host`. That page
//! needs React, imports the plugin's bundle, and then fetches one board — so a single card is several
//! requests. A device ticket is single-use, so a webview cannot mint one per subresource; hence the
//! **card session**: one ticket traded for a short-lived capability that only reads boards.
//!
//! ```text
//! POST /v1/genui/session?bot=          -> {session, ttl}
//! GET  /v1/genui/host?block=&bot=      -> the host page
//! GET  /v1/genui/assets/{name}         -> app.mjs | jsx.mjs | sdk.mjs | host.html
//! GET  /v1/genui/plugin.js             -> the installed plugin's own bundle
//! GET  /v1/genui/blocks/{id}?bot=      -> {blocks: [...]}
//! GET  /v1/genui/blocks/{id}/state?bot=-> {state: {...}} | {}
//! PUT  /v1/genui/blocks/{id}/state?bot=   body {state: {...}} -> 204
//! ```
//!
//! Two decisions worth keeping:
//!
//! * The shell (React + `host.html`) is **embedded in this binary** (`include_bytes!`). Serving it from
//!   an installed package directory means a service that answers "the genui shell is not installed" on
//!   a host where nobody copied files — a page that fails for a reason the user cannot act on.
//! * Only the **plugin bundle** is read from the engine (`plugins/hermes-genui/desktop/plugin.js`),
//!   because that is deliberately live: a plugin update reaches the apps without an app rebuild. When
//!   it is absent the honest answer is 503 "the genui plugin is not installed", not an empty card.

use crate::routes::AppState;
use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const SESSION_TTL: f64 = 120.0;
const MAX_SESSIONS: usize = 512;
const BOARD_LIMIT: u64 = 256 * 1024;
const STATE_LIMIT: u64 = 20 * 1024;
const BODY_LIMIT: usize = 32 * 1024;

const HOST_HTML: &[u8] = include_bytes!("../assets/genui/host.html");
const APP_MJS: &[u8] = include_bytes!("../assets/genui/app.mjs");
const JSX_MJS: &[u8] = include_bytes!("../assets/genui/jsx.mjs");
const SDK_MJS: &[u8] = include_bytes!("../assets/genui/sdk.mjs");

type Fail = (StatusCode, Json<Value>);

fn unauthorised() -> Fail {
    (StatusCode::UNAUTHORIZED, Json(json!({"error": "unauthorized"})))
}

fn not_found() -> Fail {
    (StatusCode::NOT_FOUND, Json(json!({"error": "not found"})))
}

/// `^[0-9a-f]{8}$` — a board id is not a path.
fn valid_block(id: &str) -> bool {
    id.len() == 8 && id.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

fn valid_bot(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

struct Sessions {
    map: Mutex<HashMap<String, (Instant, String)>>,
}

fn sessions() -> &'static Sessions {
    static SESSIONS: OnceLock<Sessions> = OnceLock::new();
    SESSIONS.get_or_init(|| Sessions { map: Mutex::new(HashMap::new()) })
}

fn mint_session(device_id: &str) -> String {
    let token = crate::auth::random_token(16);
    let mut map = sessions().map.lock().unwrap();
    if map.len() >= MAX_SESSIONS {
        // Expired entries first; a looping client must not be able to grow this without bound.
        let now = Instant::now();
        map.retain(|_, (expires, _)| *expires > now);
        if map.len() >= MAX_SESSIONS {
            map.clear();
        }
    }
    map.insert(token.clone(), (Instant::now() + Duration::from_secs_f64(SESSION_TTL), device_id.to_string()));
    token
}

fn session_device(token: &str) -> Option<String> {
    let mut map = sessions().map.lock().unwrap();
    let entry = map.get(token)?;
    if entry.0 <= Instant::now() {
        map.remove(token);
        return None;
    }
    Some(entry.1.clone())
}

fn header_credential(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// A device ticket (single-use) or a reusable access token — the same two doors the rest of the
/// service accepts, here also reachable as `?token=` because a webview cannot set headers.
fn device_from(st: &AppState, headers: &HeaderMap, cred: Option<&str>) -> Option<String> {
    let credential = cred
        .map(|c| c.trim().to_string())
        .filter(|c| !c.is_empty())
        .or_else(|| header_credential(headers))?;
    st.tickets
        .consume_ticket(&credential)
        .or_else(|| st.tickets.verify_access(&credential))
}

/// Either a card session (query param) or a device credential.
fn authorised(st: &AppState, headers: &HeaderMap, cred: Option<&str>, session: Option<&str>) -> bool {
    if let Some(session) = session.filter(|s| !s.is_empty()) {
        // A session is a capability, but revocation still has to land: the device behind it is
        // checked here too, so a revoked device cannot keep reading boards for two more minutes.
        return session_device(session).map(|d| st.store.device_active(&d)).unwrap_or(false);
    }
    device_from(st, headers, cred).is_some()
}

fn board_path(st: &AppState, bot: &str, block_id: &str) -> PathBuf {
    st.engine_home
        .join("profiles")
        .join(bot)
        .join("plugin-data")
        .join("hermes-genui")
        .join("blocks")
        .join(format!("{block_id}.json"))
}

#[derive(Deserialize)]
pub struct SessionQuery {
    #[serde(default)]
    pub bot: String,
    #[serde(default)]
    pub token: Option<String>,
}

pub async fn mint(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<SessionQuery>,
) -> Result<Json<Value>, Fail> {
    // The device is what the session stands for, so it must be known now: revocation later is
    // checked against it.
    let Some(device_id) = device_from(&st, &headers, q.token.as_deref()) else {
        return Err(unauthorised());
    };
    if !valid_bot(&q.bot) {
        return Err(not_found());
    }
    Ok(Json(json!({"session": mint_session(&device_id), "ttl": SESSION_TTL as i64})))
}

#[derive(Deserialize)]
pub struct CardQuery {
    #[serde(default)]
    pub bot: String,
    #[serde(default)]
    pub block: String,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub session: Option<String>,
}

fn bytes_response(bytes: &'static [u8], mime: &str) -> Response {
    let mut resp = bytes.to_vec().into_response();
    resp.headers_mut().insert(header::CONTENT_TYPE, mime.parse().unwrap());
    resp
}

pub async fn host(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<CardQuery>,
) -> Response {
    if !authorised(&st, &headers, q.token.as_deref(), q.session.as_deref()) {
        return unauthorised().into_response();
    }
    bytes_response(HOST_HTML, "text/html; charset=utf-8")
}

pub async fn asset(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(name): Path<String>,
    Query(q): Query<CardQuery>,
) -> Response {
    if !authorised(&st, &headers, q.token.as_deref(), q.session.as_deref()) {
        return unauthorised().into_response();
    }
    let (bytes, mime): (&'static [u8], &str) = match name.as_str() {
        "app.mjs" => (APP_MJS, "text/javascript; charset=utf-8"),
        "jsx.mjs" => (JSX_MJS, "text/javascript; charset=utf-8"),
        "sdk.mjs" => (SDK_MJS, "text/javascript; charset=utf-8"),
        "host.html" => (HOST_HTML, "text/html; charset=utf-8"),
        _ => return not_found().into_response(),
    };
    bytes_response(bytes, mime)
}

pub async fn plugin_bundle(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<CardQuery>,
) -> Response {
    if !authorised(&st, &headers, q.token.as_deref(), q.session.as_deref()) {
        return unauthorised().into_response();
    }
    let path = st
        .engine_home
        .join("plugins")
        .join("hermes-genui")
        .join("desktop")
        .join("plugin.js");
    match std::fs::read(&path) {
        Ok(bytes) => {
            let mut resp = bytes.into_response();
            resp.headers_mut()
                .insert(header::CONTENT_TYPE, "text/javascript; charset=utf-8".parse().unwrap());
            resp
        }
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error": "the genui plugin is not installed"})),
        )
            .into_response(),
    }
}

pub async fn block(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(block_id): Path<String>,
    Query(q): Query<CardQuery>,
) -> Result<Json<Value>, Fail> {
    if !authorised(&st, &headers, q.token.as_deref(), q.session.as_deref()) {
        return Err(unauthorised());
    }
    if !valid_block(&block_id) || !valid_bot(&q.bot) {
        return Err(not_found());
    }
    let path = board_path(&st, &q.bot, &block_id);
    let Ok(meta) = std::fs::metadata(&path) else { return Err(not_found()) };
    if meta.len() > BOARD_LIMIT {
        return Err(not_found());
    }
    let Ok(text) = std::fs::read_to_string(&path) else { return Err(not_found()) };
    let Ok(stored) = serde_json::from_str::<Value>(&text) else { return Err(not_found()) };
    // The renderer always wants {"blocks": [...]}; an older tool may have written the bare list.
    let blocks = match &stored {
        Value::Object(_) => stored.get("blocks").cloned(),
        Value::Array(_) => Some(stored),
        _ => None,
    };
    match blocks.and_then(|b| b.as_array().cloned()) {
        Some(blocks) => Ok(Json(json!({ "blocks": blocks }))),
        None => Err(not_found()),
    }
}

fn state_path(board: &std::path::Path, block_id: &str) -> PathBuf {
    board.with_file_name(format!("{block_id}.state.json"))
}

pub async fn block_state(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(block_id): Path<String>,
    Query(q): Query<CardQuery>,
) -> Result<Json<Value>, Fail> {
    if !authorised(&st, &headers, q.token.as_deref(), q.session.as_deref()) {
        return Err(unauthorised());
    }
    if !valid_block(&block_id) || !valid_bot(&q.bot) {
        return Err(not_found());
    }
    let board = board_path(&st, &q.bot, &block_id);
    if !board.is_file() {
        return Err(not_found());
    }
    // No state file is a normal board that has never been touched: an empty object, not an error.
    let Ok(text) = std::fs::read_to_string(state_path(&board, &block_id)) else {
        return Ok(Json(json!({})));
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(map)) if !map.is_empty() => Ok(Json(json!({ "state": map }))),
        _ => Ok(Json(json!({}))),
    }
}

pub async fn save_block_state(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(block_id): Path<String>,
    Query(q): Query<CardQuery>,
    body: Bytes,
) -> Result<StatusCode, Fail> {
    if !authorised(&st, &headers, q.token.as_deref(), q.session.as_deref()) {
        return Err(unauthorised());
    }
    if !valid_block(&block_id) || !valid_bot(&q.bot) {
        return Err(not_found());
    }
    if body.len() > BODY_LIMIT {
        return Err((StatusCode::PAYLOAD_TOO_LARGE, Json(json!({"error": "state too big"}))));
    }
    let board = board_path(&st, &q.bot, &block_id);
    if !board.is_file() {
        return Err(not_found());
    }
    let document: Value = serde_json::from_slice(&body)
        .map_err(|_| (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({"error": "not JSON"}))))?;
    let state = document.get("state").cloned().unwrap_or(Value::Null);
    if !state.is_object() {
        return Err((StatusCode::UNPROCESSABLE_ENTITY, Json(json!({"error": "state must be an object"}))));
    }
    let rendered = state.to_string();
    if rendered.len() as u64 > STATE_LIMIT {
        return Err((StatusCode::UNPROCESSABLE_ENTITY, Json(json!({"error": "state too big"}))));
    }
    let path = state_path(&board, &block_id);
    std::fs::write(&path, rendered)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "could not save"}))))?;
    Ok(StatusCode::NO_CONTENT)
}
