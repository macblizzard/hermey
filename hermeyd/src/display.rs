//! Bot computer: the six `/v1/display/*` routes plus the viewer socket.
//!
//! The engine already runs the desktop (Xvfb + RFB behind a unix socket, `display.*` JSON-RPC), so
//! this is a translator, exactly like rooms. One thing is NOT a plain translate-and-forget:
//!
//! **`viewer_id` is minted per engine connection.** `display.lease.acquire` refuses an id the calling
//! connection never minted ("viewer_id was not minted for this connection; call display.observe
//! first"), and the app's flow is observe → lease with the id observe returned. A per-call connection
//! would therefore mint an id on socket A and be refused on socket B — the takeover would never work.
//! So display calls ride ONE long-lived engine socket (`DisplayHub`), while idle stateless routes keep
//! using short-lived ones.

use crate::display_container as sandbox;
use crate::routes::{require_device, AppState};
use axum::extract::ws::{Message as Ax, WebSocket, WebSocketUpgrade};
use tokio_tungstenite::tungstenite::Message as Tg;
use axum::extract::{Query, State, Path};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

fn valid_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 64
        && profile.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

type Reply = oneshot::Sender<Result<Value, String>>;

/// One serialised connection to the engine, so every display call shares a socket identity.
pub struct DisplayHub {
    tx: mpsc::Sender<(String, Value, Reply)>,
}

impl DisplayHub {
    /// `token_file: None` means the engine answered `auth_required: false` at boot: this socket is
    /// dialled with no credential, and no file is read. See `engine_auth`.
    pub fn spawn(engine_ws: String, token_file: Option<PathBuf>) -> Arc<Self> {
        let (tx, rx) = mpsc::channel::<(String, Value, Reply)>(32);
        tokio::spawn(actor(engine_ws, token_file, rx));
        Arc::new(Self { tx })
    }

    pub async fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send((method.to_string(), params, reply_tx))
            .await
            .map_err(|_| "display hub is not running".to_string())?;
        reply_rx.await.map_err(|_| "display hub dropped the call".to_string())?
    }
}

/// The URL this socket dials; the token rides it only when `engine_auth` said the engine wants one.
fn ws_url(engine_ws: &str, token: Option<&str>) -> String {
    crate::engine_client::engine_url(engine_ws, token)
}

async fn actor(
    engine_ws: String,
    token_file: Option<PathBuf>,
    mut rx: mpsc::Receiver<(String, Value, Reply)>,
) {
    let mut socket: Option<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    > = None;
    let mut next_id: i64 = 1;

    while let Some((method, params, reply)) = rx.recv().await {
        // The engine may restart under us (a rebuild, a crash). The hub holds one long-lived socket,
        // so the first call after that lands on a dead connection: retry ONCE on a fresh socket
        // instead of failing the request the user just made.
        let mut attempt = 0;
        let answer = loop {
            if socket.is_none() {
                // Re-read per (re)connect — the engine mints a fresh token each boot — but only when
                // a token was wanted at all.
                let token = token_file
                    .as_ref()
                    .and_then(|path| std::fs::read_to_string(path).ok())
                    .map(|s| s.trim().to_string());
                match tokio_tungstenite::connect_async(ws_url(&engine_ws, token.as_deref())).await {
                    Ok((s, _)) => socket = Some(s),
                    Err(e) => break Err(format!("engine unreachable: {e}")),
                }
            }
            let ws = socket.as_mut().expect("socket just ensured");
            let id = next_id;
            next_id += 1;
            let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
            if ws.send(Tg::Text(request.to_string().into())).await.is_err() {
                socket = None;
                attempt += 1;
                if attempt < 2 {
                    continue;
                }
                break Err("engine connection lost".to_string());
            }
            let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
            // `socket` is borrowed by `ws`, so a dead connection is recorded as a flag and applied
            // after the loop instead of assigning through the borrow.
            let mut lost = false;
            let mut outcome: Option<Result<Value, String>> = None;
            while outcome.is_none() {
                match tokio::time::timeout_at(deadline, ws.next()).await {
                    Err(_) => outcome = Some(Err(format!("engine timeout on {method}"))),
                    Ok(None) => {
                        lost = true;
                        outcome = Some(Err("engine closed the display socket".to_string()));
                    }
                    Ok(Some(Err(e))) => {
                        lost = true;
                        outcome = Some(Err(format!("engine ws error: {e}")));
                    }
                    Ok(Some(Ok(Tg::Text(text)))) => {
                        let Ok(msg) = serde_json::from_str::<Value>(&text) else { continue };
                        // Events and broadcasts interleave with answers; only our id is the answer.
                        if msg.get("id").and_then(|v| v.as_i64()) != Some(id) {
                            continue;
                        }
                        outcome = Some(match msg.get("error") {
                            Some(err) if !err.is_null() => Err(err
                                .get("message")
                                .and_then(|m| m.as_str())
                                .unwrap_or("the engine refused")
                                .to_string()),
                            _ => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
                        });
                    }
                    Ok(Some(Ok(Tg::Close(_)))) => {
                        lost = true;
                        outcome = Some(Err("engine closed the display socket".to_string()));
                    }
                    Ok(Some(Ok(_))) => continue,
                }
            }
            let result = outcome.unwrap_or_else(|| Err("no answer".to_string()));
            if lost {
                socket = None;
                attempt += 1;
                if attempt < 2 {
                    continue; // the next pass reconnects and resends once
                }
            }
            break result;
        };
        let _ = reply.send(answer);
    }
}

/// Engine snapshot → the `BotComputerStatus` the pane decodes.
fn status_view(snapshot: &Value) -> Value {
    let lease = snapshot.get("lease").cloned().filter(|l| !l.is_null()).map(|l| {
        json!({
            "holder": l.get("holder"),
            "epoch": l.get("epoch"),
            "since": l.get("since"),
            "viewerHash": l.get("viewer_hash").or_else(|| l.get("viewerHash")),
        })
    });
    json!({
        "profile": snapshot.get("profile"),
        "running": snapshot.get("running").and_then(|r| r.as_bool()).unwrap_or(false),
        "installed": snapshot.get("installed").and_then(|i| i.as_bool()).unwrap_or(true),
        "display": snapshot.get("display"),
        "geometry": snapshot.get("geometry"),
        "blocker": snapshot.get("blocker"),
        "lease": lease,
    })
}

#[derive(Deserialize)]
pub struct ProfileQuery {
    pub profile: String,
}

pub async fn status(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<ProfileQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&q.profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    if sandbox::active() {
        return Ok(Json(sandbox::status(&q.profile)));
    }
    let snap = st
        .display
        .call("display.status", json!({"profile": q.profile}))
        .await
        .map_err(|e| engine_err_blocking(e))?;
    Ok(Json(status_view(&snap)))
}

fn engine_err_blocking(e: String) -> Fail {
    bad(StatusCode::BAD_GATEWAY, e)
}

pub async fn thumbnail(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<ProfileQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&q.profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    if sandbox::active() {
        return Ok(Json(json!({"dataUrl": sandbox::thumbnail(&q.profile)})));
    }
    match st.display.call("display.thumbnail", json!({"profile": q.profile})).await {
        Ok(v) => {
            let data = v
                .get("dataUrl")
                .or_else(|| v.get("data_url"))
                .or_else(|| v.get("thumbnail"))
                .cloned()
                .unwrap_or(Value::Null);
            Ok(Json(json!({"dataUrl": data})))
        }
        // No picture is not an error for the pane: it shows a placeholder.
        Err(_) => Ok(Json(json!({"dataUrl": Value::Null}))),
    }
}

#[derive(Deserialize)]
pub struct StartBody {
    pub profile: String,
}

pub async fn start(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<StartBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&body.profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    if sandbox::active() {
        return match sandbox::start(&body.profile) {
            Ok(snapshot) => Ok(Json(snapshot)),
            Err(e) => Err(bad(StatusCode::CONFLICT, e)),
        };
    }
    let snap = st
        .display
        .call("display.start", json!({"profile": body.profile}))
        .await
        .map_err(engine_err_blocking)?;
    Ok(Json(status_view(&snap)))
}

#[derive(Deserialize)]
pub struct StopBody {
    pub profile: String,
    #[serde(default)]
    pub confirm: bool,
}

pub async fn stop(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<StopBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&body.profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    // Signalling without confirm is a user error, not a host error: answer before touching the screen.
    if !body.confirm {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "stopping the bot computer ends whatever is on screen; pass confirm: true",
        ));
    }
    if sandbox::active() {
        return Ok(Json(sandbox::stop(&body.profile)));
    }
    let snap = st
        .display
        .call(
            "display.stop",
            json!({"profile": body.profile, "force": true}),
        )
        .await
        .map_err(engine_err_blocking)?;
    Ok(Json(status_view(&snap)))
}

#[derive(Deserialize)]
pub struct LeaseBody {
    pub profile: String,
    /// The apps send `action: "acquire" | "release"`. Reading a boolean `acquire` here instead made
    /// every takeover call `display.lease.release` (absent field → serde default `false`), so the
    /// lease answered 200 and never changed hands. Kept as a fallback for older builds.
    #[serde(default)]
    pub action: Option<String>,
    #[serde(default)]
    pub acquire: Option<bool>,
    #[serde(default)]
    pub viewer_id: Option<String>,
}

/// Which way the pane wants the lease to move: `Some(true)` = take over, `Some(false)` = hand back,
/// `None` = the request named neither a valid action nor the legacy flag (a 422, never a guess).
///
/// This is a named function, not an inline match, because the mapping is the bug that shipped: a
/// body the apps really send (`{action: "acquire"}`) decoded to "release" and the UI reported a
/// successful takeover that had not happened.
fn lease_transition(action: Option<&str>, legacy_acquire: Option<bool>) -> Option<bool> {
    match action.map(|a| a.trim().to_ascii_lowercase()).as_deref() {
        Some("acquire") => Some(true),
        Some("release") => Some(false),
        // An unrecognised string is a client bug: refuse it rather than fall through to release.
        Some(_) => None,
        None => legacy_acquire,
    }
}

pub async fn lease(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<LeaseBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&body.profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    let Some(acquire) = lease_transition(body.action.as_deref(), body.acquire) else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "action must be acquire or release"));
    };
    let Some(viewer) = body.viewer_id.map(|v| v.trim().to_string()).filter(|v| !v.is_empty()) else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "viewer_id is required"));
    };
    let method = if acquire { "display.lease.acquire" } else { "display.lease.release" };
    let mut params = json!({"profile": body.profile, "viewer_id": viewer});
    if !acquire {
        // Without an explicit force a release is the holder's own hand-back, never an eviction.
        params["force"] = json!(false);
    }
    match st.display.call(method, params.clone()).await {
        Ok(v) => Ok(Json(json!({"lease": status_view(&v).get("lease").cloned().unwrap_or(Value::Null)}))),
        // The engine binds a viewer id to the socket that minted it. After an engine restart (or a
        // hub reconnect on its one retry) the id is no longer ours on the new socket, and takeover
        // fails with "was not minted" while the viewer is otherwise healthy. Re-observing with the
        // SAME id re-mints it on this connection without changing who the viewer is.
        Err(e) if acquire && e.contains("minted") => {
            let profile = params
                .get("profile")
                .and_then(|p| p.as_str())
                .unwrap_or_default()
                .to_string();
            let viewer_id = params.get("viewer_id").and_then(|v| v.as_str()).unwrap_or_default().to_string();
            st.display
                .call("display.observe", json!({"profile": profile, "viewer_id": viewer_id}))
                .await
                .map_err(|e| bad(StatusCode::CONFLICT, e))?;
            match st.display.call(method, params).await {
                Ok(v) => Ok(Json(json!({"lease": status_view(&v).get("lease").cloned().unwrap_or(Value::Null)}))),
                Err(e) => Err(bad(StatusCode::CONFLICT, e)),
            }
        }
        Err(e) => Err(bad(StatusCode::CONFLICT, e)),
    }
}

#[derive(Deserialize)]
pub struct ObserveBody {
    pub profile: String,
    #[serde(default)]
    pub viewer_id: Option<String>,
}

pub async fn observe(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<ObserveBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&body.profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    if sandbox::active() {
        let Some((ticket, _profile, _port)) = sandbox::mint_ticket(&body.profile) else {
            return Err(bad(StatusCode::CONFLICT, "this profile's bot desktop is not running; start it first"));
        };
        return Ok(Json(json!({
            "ticket": ticket,
            "path": "/v1/display/ws",
            "expires_in": 60,
            "viewer_id": crate::auth::random_token(12),
            "status": sandbox::status(&body.profile),
        })));
    }
    let mut params = json!({"profile": body.profile});
    if let Some(viewer) = body.viewer_id.clone() {
        params["viewer_id"] = json!(viewer);
    }
    let snap = st
        .display
        .call("display.observe", params)
        .await
        .map_err(|e| engine_err_blocking(e))?;

    let ticket = snap.get("ticket").cloned().unwrap_or(Value::Null);
    if ticket.is_null() {
        return Err(bad(StatusCode::BAD_GATEWAY, "the engine did not mint a viewer ticket"));
    }
    Ok(Json(json!({
        "ticket": ticket,
        "path": "/v1/display/ws",
        // Single use, and the pane re-observes when it lapses.
        "expires_in": 60,
        "viewer_id": snap.get("viewer_id"),
        "status": status_view(&snap),
    })))
}

#[derive(Deserialize)]
pub struct TicketQuery {
    pub display_ticket: String,
}

/// The viewer socket: the app dials `wss://…/v1/display/ws?display_ticket=…` and speaks RFB.
pub async fn display_ws(
    ws: WebSocketUpgrade,
    State(st): State<Arc<AppState>>,
    Query(q): Query<TicketQuery>,
) -> Response {
    // The display ticket is the ONLY credential this socket accepts: adding the engine token made
    // the engine refuse the upgrade (measured — ticket alone answers `RFB 003.008`).
    // `engine_ws` already ends in /api/ws, so the display path must be derived from the origin only —
    // appending blindly produced ws://…/api/ws/api/display/ws and an instant close.
    let origin = st.engine_ws.split("/api/").next().unwrap_or(&st.engine_ws).to_string();
    let upstream = format!(
        "{origin}/api/display/ws?display_ticket={}",
        urlencoding::encode(&q.display_ticket)
    );
    if sandbox::active() {
        let ticket = q.display_ticket.clone();
        return ws.on_upgrade(move |socket| sandbox::splice_viewer(socket, ticket));
    }
    ws.on_upgrade(move |socket| splice(socket, upstream))
}

async fn splice(mut client: WebSocket, upstream: String) {
    let Ok((mut server, _)) = tokio_tungstenite::connect_async(&upstream).await else {
        let _ = client.close().await;
        return;
    };
    loop {
        tokio::select! {
            from_client = client.recv() => {
                let Some(Ok(msg)) = from_client else { break };
                let out = match msg {
                    Ax::Binary(b) => Tg::Binary(b.to_vec()),
                    Ax::Text(t) => Tg::Text(t.to_string().into()),
                    Ax::Close(_) => { let _ = server.close(None).await; break; }
                    _ => continue,
                };
                if server.send(out).await.is_err() { break }
            }
            from_server = server.next() => {
                let Some(Ok(msg)) = from_server else { break };
                let out = match msg {
                    Tg::Binary(b) => Ax::Binary(b.into()),
                    Tg::Text(t) => Ax::Text(t.to_string().into()),
                    Tg::Close(_) => { let _ = client.close().await; break }
                    _ => continue,
                };
                if client.send(out).await.is_err() { break }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{lease_transition, LeaseBody};

    /// The exact body `BotComputerClient.lease` sends. It must decode as a takeover.
    #[test]
    fn client_acquire_body_is_a_takeover() {
        let body: LeaseBody = serde_json::from_str(
            r#"{"profile":"bob","action":"acquire","viewer_id":"v1"}"#,
        )
        .expect("the client's own body must decode");
        assert_eq!(lease_transition(body.action.as_deref(), body.acquire), Some(true));
        assert_eq!(body.viewer_id.as_deref(), Some("v1"));
    }

    #[test]
    fn client_release_body_is_a_hand_back() {
        let body: LeaseBody = serde_json::from_str(
            r#"{"profile":"bob","action":"release","viewer_id":"v1"}"#,
        )
        .unwrap();
        assert_eq!(lease_transition(body.action.as_deref(), body.acquire), Some(false));
    }

    /// A missing action must never default to "release" — that is precisely how a takeover silently
    /// answered 200 without moving the lease.
    #[test]
    fn missing_action_is_refused_not_assumed() {
        let body: LeaseBody = serde_json::from_str(r#"{"profile":"bob","viewer_id":"v1"}"#).unwrap();
        assert_eq!(body.action, None);
        assert_eq!(body.acquire, None);
        assert_eq!(lease_transition(body.action.as_deref(), body.acquire), None);
    }

    #[test]
    fn action_is_case_and_space_insensitive() {
        assert_eq!(lease_transition(Some("  ACQUIRE "), None), Some(true));
        assert_eq!(lease_transition(Some("Release"), None), Some(false));
        assert_eq!(lease_transition(Some("steal"), None), None);
    }

    /// Older builds sent only the boolean; it keeps working, in both directions.
    #[test]
    fn legacy_boolean_still_maps_both_ways() {
        assert_eq!(lease_transition(None, Some(true)), Some(true));
        assert_eq!(lease_transition(None, Some(false)), Some(false));
    }
}
