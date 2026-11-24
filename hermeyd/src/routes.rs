//! HTTP surface. Shapes mirror the production bridge field-for-field so a client that pairs to one
//! can pair to the other: /v1/health, /v1/pair/start, /v1/pair/claim, /v1/token, /v1/devices.

use crate::auth::{hash_refresh, random_token, Tickets};
use crate::pairing::{now, Pairing};
use crate::store::Store;
use axum::extract::ws::WebSocketUpgrade;
use axum::extract::{ConnectInfo, Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::Arc;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_DEVICES: i64 = 32;
pub const PAIRING_CODE_TTL_SECONDS: f64 = 600.0;

pub struct AppState {
    /// Macs that offered themselves as computers, and the revoke list.
    pub local_computers: crate::local_computers::Registry,
    /// Browser fill targets: the sign-in extension's socket registry.
    pub browsers: crate::browser::Registry,
    /// One serialised engine socket: display viewer ids are minted per connection, so observe and
    /// the takeover that follows it must ride the same one.
    pub display: Arc<crate::display::DisplayHub>,
    /// Open app-facing relays, grouped by device, so `DELETE /v1/devices/{id}` can close the
    /// conversations a revoked device already has open, and so the upgrade path can enforce
    /// `relay::MAX_SOCKETS_PER_DEVICE` / `relay::MAX_SOCKETS_TOTAL` by evicting (see
    /// `relay::Registry`).
    pub relay_sockets: crate::relay::Registry,
    /// Reactions, one emoji per message per conversation, agreed by every device.
    ///
    /// The host is the only place a Mac and a phone can meet, so they live here (`reactions.rs`):
    /// one JSON document beside `bridge.db`, and a live frame on `relay_sockets` whenever one
    /// changes.
    pub reactions: crate::reactions::Registry,
    pub store: Store,
    pub pairing: Pairing,
    pub tickets: Tickets,
    pub limiter: crate::auth::RateLimiter,
    pub salt: String,
    pub public_host: String,
    /// Engine's loopback WS endpoint, e.g. `ws://127.0.0.1:9121/api/ws`.
    pub engine_ws: String,
    /// File holding the engine's per-boot token (written by run-engine.sh). Still the credential
    /// when one is needed; `engine_auth` decides whether it is.
    pub engine_token_file: std::path::PathBuf,
    /// What the engine's `/api/health` said about needing a token, probed once at boot.
    /// [`AppState::engine_token`] is the only reader that has to care.
    pub engine_auth: crate::engine_auth::EngineAuth,
    /// The engine's home (HERMES_HOME): profiles, memories, skills live under it.
    pub engine_home: std::path::PathBuf,
    /// Where uploaded bytes live. Metadata in SQLite, bytes on disk.
    pub attachments_dir: std::path::PathBuf,
    /// The service's own state directory — what `state_home()` resolved. Self-update keeps its
    /// record (`update-state.json`) here, beside `bridge.db` and `audit.jsonl`.
    pub home: std::path::PathBuf,
    /// The service-owned bearer on-host scripts read from `<state>/local.token`. Accepted by
    /// `require_device`, under `local_token::LOCAL_PRINCIPAL`. See `local_token.rs`.
    pub local_token: Arc<crate::local_token::LocalToken>,
    /// The structured audit stream: one bounded JSON-lines file, scalars only. See `audit.rs`.
    pub audit: Arc<crate::audit::AuditLog>,
}

impl AppState {
    /// The bearer to put on an engine connection, or `None` when the engine said it wants none.
    ///
    /// Read per call, not at startup: the engine mints a fresh token on every boot. Read at all only
    /// when the boot probe found the socket refusing a tokenless upgrade — otherwise the file is not
    /// a credential, it is a leftover, and appending it would be a query string the engine never
    /// asked for.
    pub fn engine_token(&self) -> Option<String> {
        if !self.engine_auth.send_token() {
            return None;
        }
        std::fs::read_to_string(&self.engine_token_file)
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }
}

/// 25 MiB. Deliberately small enough that a phone photo fits after downscaling and a runaway upload
/// cannot fill the host. The client applies its own ceiling too; both sides say the limit out loud.
pub const MAX_ATTACHMENT_BYTES: usize = 25 * 1024 * 1024;

/// Strip a client-supplied filename down to something that cannot leave the attachment directory:
/// no separators, no leading dots, no control characters, bounded length.
fn safe_name(raw: &str) -> String {
    let base = raw.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = base
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') { c } else { '_' })
        .collect();
    let cleaned = cleaned.trim_matches(|c| c == '.' || c == ' ').to_string();
    if cleaned.is_empty() {
        "file".to_string()
    } else {
        cleaned.chars().take(120).collect()
    }
}

/// `POST /v1/attachments` — raw bytes in the body, filename in `x-hermey-filename`.
/// Raw body (not multipart) on purpose: one code path, no parser to get wrong, trivially scriptable.
pub async fn upload_attachment(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let device = require_device(&st, &headers)?;
    if body.is_empty() {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"detail": "empty body"}))));
    }
    let raw_name = headers
        .get("x-hermey-filename")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("file");
    let name = safe_name(raw_name);
    let attachment_id = random_token(16);

    std::fs::create_dir_all(&st.attachments_dir).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"detail": format!("cannot create attachment dir: {e}")})),
        )
    })?;
    let path = st.attachments_dir.join(format!("{attachment_id}-{name}"));
    std::fs::write(&path, &body).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"detail": format!("cannot store attachment: {e}")})),
        )
    })?;

    let record = crate::store::Attachment {
        attachment_id: attachment_id.clone(),
        device_id: device,
        name: name.clone(),
        size: body.len() as i64,
        sha256: crate::auth::sha256_hex(&body),
        created_at: now(),
    };
    st.store.add_attachment(&record);

    Ok(Json(json!({
        "attachment_id": attachment_id,
        "name": name,
        "size": record.size,
        "sha256": record.sha256,
    })))
}

/// `GET /v1/attachments/{id}` — owner-scoped. Another device's id answers 404, not 403: existence is
/// not a fact to leak.
pub async fn download_attachment(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(attachment_id): Path<String>,
) -> Result<Response, (StatusCode, Json<Value>)> {
    let device = require_device(&st, &headers)?;
    let record = st
        .store
        .get_attachment(&attachment_id)
        .filter(|a| a.device_id == device)
        .ok_or_else(|| (StatusCode::NOT_FOUND, Json(json!({"detail": "no such attachment"}))))?;

    let path = st.attachments_dir.join(format!("{}-{}", record.attachment_id, record.name));
    let bytes = std::fs::read(&path).map_err(|_| {
        (StatusCode::NOT_FOUND, Json(json!({"detail": "attachment bytes missing"})))
    })?;

    let mut resp = Response::new(axum::body::Body::from(bytes));
    let h = resp.headers_mut();
    h.insert(axum::http::header::CONTENT_TYPE, "application/octet-stream".parse().unwrap());
    h.insert(
        axum::http::header::CONTENT_DISPOSITION,
        format!("attachment; filename=\"{}\"", record.name).parse().unwrap(),
    );
    h.insert("x-hermey-sha256", record.sha256.parse().unwrap());
    Ok(resp)
}

pub async fn delete_attachment(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(attachment_id): Path<String>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let device = require_device(&st, &headers)?;
    // Resolve the record first: the stored filename is `<id>-<sanitised name>`, and guessing it would
    // leave the bytes behind forever.
    let record = st
        .store
        .get_attachment(&attachment_id)
        .filter(|a| a.device_id == device)
        .ok_or_else(|| (StatusCode::NOT_FOUND, Json(json!({"detail": "no such attachment"}))))?;
    if !st.store.delete_attachment(&attachment_id, &device) {
        return Err((StatusCode::NOT_FOUND, Json(json!({"detail": "no such attachment"}))));
    }
    let _ = std::fs::remove_file(
        st.attachments_dir.join(format!("{}-{}", record.attachment_id, record.name)),
    );
    Ok(Json(json!({"deleted": true, "attachment_id": attachment_id})))
}

#[derive(Deserialize)]
pub struct WsQuery {
    #[serde(default)]
    pub ws_ticket: Option<String>,
    #[serde(default)]
    pub ticket: Option<String>,
}

/// `/v1/ws` — the app-facing socket. A client must hold a ticket minted by `/v1/token`; the ticket is
/// consumed here, so a reconnect needs a fresh one (that is what makes a leaked ticket worthless).
pub async fn ws_upgrade(
    State(st): State<Arc<AppState>>,
    Query(q): Query<WsQuery>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, (StatusCode, Json<Value>)> {
    let ticket = q
        .ws_ticket
        .or(q.ticket)
        .or_else(|| bearer(&headers))
        .ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"detail": "missing ws ticket"}))))?;

    let device = st.tickets.consume_ticket(&ticket).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            Json(json!({"detail": "invalid, expired or already-used ws ticket"})),
        )
    })?;
    // A ticket can outlive the revoke that was meant to end the device: without this check a
    // revoked device reopens a conversation for the rest of the ticket's 30 seconds, undoing the
    // socket close `revoke` just performed. (`proxy.py::test_revoked_device_cannot_open_a_socket`.)
    if !st.store.device_active(&device) {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({"detail": "device revoked"})),
        ));
    }

    // Read per connection, not at startup: the engine mints a fresh token on every boot. `None`
    // when the probe found the socket accepting a tokenless upgrade, so the relay dials bare.
    let engine_token = st.engine_token();

    // Socket caps, enforced here so a device that is already at its limit has another socket
    // evicted for it instead of being refused (`proxy.py:226-241` refused with 4429; we only refuse
    // when nothing can be closed). Refusing a WebSocket upgrade is an HTTP answer: the app never
    // sees a socket that opens and immediately dies.
    if let Err(refusal) = st.relay_sockets.admit(&device) {
        eprintln!(
            "relay: refused an upgrade for device {}: {}",
            truncate(&device),
            refusal.detail()
        );
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({ "detail": refusal.detail(), "retry_after": 2 })),
        ));
    }

    let engine_ws = st.engine_ws.clone();
    let relay_sockets = st.relay_sockets.clone();
    let audit = Arc::clone(&st.audit);
    let engine_home = st.engine_home.clone();
    let device_id = device.clone();
    Ok(ws.on_upgrade(move |socket| async move {
        println!("relay: device {} attached", truncate(&device));
        crate::relay::relay_guarded(
            socket,
            engine_ws,
            engine_token,
            Some(device_id),
            relay_sockets,
            crate::relay::Limits::default(),
            Some(audit),
            engine_home,
        )
        .await;
    }))
}

fn truncate(s: &str) -> String {
    if s.len() > 8 { format!("{}…", &s[..8]) } else { s.to_string() }
}

#[derive(Deserialize)]
pub struct ClaimRequest {
    pub code: String,
    #[serde(default)]
    pub public_key: String,
    #[serde(default = "default_device_name")]
    pub device_name: String,
    #[serde(default = "default_platform")]
    pub platform: String,
}

fn default_device_name() -> String {
    "device".to_string()
}
fn default_platform() -> String {
    "unknown".to_string()
}

#[derive(Deserialize)]
pub struct TokenRequest {
    pub device_id: String,
    pub refresh_token: String,
}

#[derive(Serialize)]
pub struct Health {
    pub status: &'static str,
    pub protocol_version: u32,
    pub ws: bool,
}

pub async fn health() -> Json<Health> {
    // Unauthenticated: says only that the service is alive. No device count, no versions of anything
    // installed — that was a free fingerprint on the production bridge.
    Json(Health { status: "ok", protocol_version: PROTOCOL_VERSION, ws: true })
}

fn is_loopback(addr: &SocketAddr) -> bool {
    addr.ip().is_loopback()
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(|s| s.trim().to_string())
}

/// `GET /v1/pair/host` — the host a pairing URL would name, without minting anything.
///
/// `pair/start` already reports the field, but minting a single-use code to read it is a side
/// effect (a live code appears in the log and in the store's uniqueness set). This answers the same
/// value from the same state. Bearer-checked: the published listener is reachable from the tailnet,
/// and the hostname of this machine is not something an unauthenticated peer needs handed to it.
pub async fn pair_host(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_device(&st, &headers)?;
    Ok(Json(json!({
        "host": st.public_host,
        "protocol_version": PROTOCOL_VERSION,
    })))
}

pub async fn pair_start(
    State(st): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    // Host-only mint. A paired device may also mint (that grants nothing it lacks), but an
    // unauthenticated remote caller must not.
    if !is_loopback(&peer) {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({"detail": "pairing codes are minted on the host"})),
        ));
    }
    let (code, expires_at) = st.pairing.mint();
    eprintln!("pair/start: minted code (len {}) expiring in {:.0}s", code.len(), expires_at - now());
    Ok(Json(json!({
        "code": code,
        "expires_at": expires_at,
        "host": st.public_host,
        "protocol_version": PROTOCOL_VERSION,
    })))
}

pub async fn pair_claim(
    State(st): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(body): Json<ClaimRequest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    if let Err(retry_after) = st.limiter.check(&peer.ip().to_string()) {
        eprintln!("pair/claim: rate limited from {} (retry {retry_after}s)", peer.ip());
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({"detail": "too many pairing attempts", "retry_after": retry_after})),
        ));
    }
    if !st.pairing.redeem(&body.code) {
        // Never log the code itself; the shape of the attempt is what diagnoses this.
        eprintln!(
            "pair/claim: CODE REJECTED (invalid/expired/already used) from {} — code_len={} key_len={} name={:?} platform={:?}",
            peer.ip(), body.code.len(), body.public_key.trim().len(), body.device_name, body.platform
        );
        return Err((
            StatusCode::UNAUTHORIZED,
            Json(json!({"detail": "pairing code invalid or expired"})),
        ));
    }
    let key = body.public_key.trim();
    if key.len() < 32 || key.len() > 512 {
        eprintln!("pair/claim: KEY REJECTED len={} from {}", key.len(), peer.ip());
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({"detail": "public_key must be 32-512 characters"})),
        ));
    }
    if st.store.count_active() >= MAX_DEVICES {
        eprintln!("pair/claim: device limit reached ({MAX_DEVICES})");
        return Err((
            StatusCode::CONFLICT,
            Json(json!({"detail": "device limit reached; revoke one first"})),
        ));
    }

    let device_id = random_token(12);
    let refresh = random_token(32);
    let stored = hash_refresh(&st.salt, &refresh);
    st.store
        .add_device(&device_id, &body.device_name, &body.platform, key, &stored);

    Ok(Json(json!({
        "device_id": device_id,
        "refresh_token": refresh,
        "protocol_version": PROTOCOL_VERSION,
    })))
}

pub async fn token(
    State(st): State<Arc<AppState>>,
    Json(body): Json<TokenRequest>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let presented = hash_refresh(&st.salt, &body.refresh_token);
    let device = st.store.verify_refresh(&body.device_id, &presented).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            Json(json!({"detail": "unknown device or bad refresh token"})),
        )
    })?;
    let ticket = st.tickets.mint_ticket(&device.device_id);
    let access = st.tickets.mint_access(&device.device_id);
    st.store.touch(&device.device_id);
    Ok(Json(json!({
        "access_token": access,
        "ws_ticket": ticket,
        "expires_in": st.tickets.access_ttl(),
    })))
}

pub async fn devices(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_device(&st, &headers)?;
    Ok(Json(json!(st.store.list())))
}

pub async fn revoke(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let caller = require_device(&st, &headers)?;
    let revoked = st.store.revoke(&device_id);
    // A revoked device must stop talking now, not when its next ticket expires: its open
    // conversation would otherwise keep relaying prompts (`proxy.py::LiveSessions`).
    let closed = st.relay_sockets.close_device(&device_id);
    if closed > 0 {
        eprintln!("devices: closed {closed} live socket(s) for revoked device");
    }
    Ok(Json(json!({
        "revoked": revoked,
        "device_id": device_id,
        "by": caller,
        "revoked_at": now(),
        "sockets_closed": closed,
    })))
}

/// `DELETE /v1/devices/{device_id}/revoked` — remove a row that is *already* revoked, so the device
/// list does not fill up with tombstones. Not a second revoke: an active device answers 409 and an
/// unknown id 404, matching the bridge's `delete_revoked` (`app.py::delete_revoked_device`).
pub async fn delete_revoked_device(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_device(&st, &headers)?;
    match st.store.delete_revoked(&device_id) {
        "active" => Err((
            StatusCode::CONFLICT,
            Json(json!({"detail": "device is not revoked"})),
        )),
        "missing" => Err((
            StatusCode::NOT_FOUND,
            Json(json!({"detail": "unknown device"})),
        )),
        _ => Ok(Json(json!({ "deleted": device_id }))),
    }
}

pub(crate) fn require_device(st: &AppState, headers: &HeaderMap) -> Result<String, (StatusCode, Json<Value>)> {
    let token = bearer(headers).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            Json(json!({"detail": "missing bearer token"})),
        )
    })?;
    // The local CLI token first: one constant-time comparison against memory, no map touched, and a
    // service-owned principal that no device can impersonate. It exists so a bundled script on this
    // host can call the same routes the apps do without the routes being open to every local process.
    if st.local_token.matches(&token) {
        return Ok(crate::local_token::LOCAL_PRINCIPAL.to_string());
    }
    // Production semantics: the apps mint a FRESH 30s single-use ticket per request and send it as the
    // bearer. So a ticket is the primary credential here — consumed on use, worthless afterwards.
    // A reusable access token stays supported for long-lived callers (scripts, the relay).
    if let Some(device) = st.tickets.consume_ticket(&token) {
        return Ok(device);
    }
    st.tickets.verify_access(&token).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            Json(json!({"detail": "unknown, expired or already-used token"})),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";

    fn scratch(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-routes-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn state(dir: &Path) -> Arc<AppState> {
        state_with_engine(dir, "ws://127.0.0.1:9121/api/ws")
    }

    fn state_with_engine(dir: &Path, engine_ws: &str) -> Arc<AppState> {
        let engine_ws = engine_ws.to_string();
        let token_file = dir.join("engine.token");
        Arc::new(AppState {
            store: Store::open(&dir.join("bridge.db")).expect("store"),
            pairing: Pairing::new(PAIRING_CODE_TTL_SECONDS),
            tickets: Tickets::new(30.0, 300.0),
            limiter: crate::auth::RateLimiter::new(30, 60.0),
            salt: "salt-".repeat(8),
            public_host: "localhost".to_string(),
            engine_ws: engine_ws.clone(),
            engine_token_file: token_file.clone(),
            // Tests keep the pre-detection shape unless they say otherwise: a token file that is
            // read and appended. `no_token_is_read_when_the_engine_wants_none` flips it.
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

    fn auth(value: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {value}").parse().unwrap(),
        );
        headers
    }

    /// The defect this closes: a bundled script on this host had no credential, so every route it
    /// called answered 401. The local bearer must be accepted exactly where a device bearer is,
    /// and nowhere does an unauthenticated call start working.
    #[tokio::test]
    async fn the_local_token_is_accepted_where_an_unauthenticated_call_is_refused() {
        let dir = scratch("local");
        let st = state(&dir);

        let missing = devices(State(Arc::clone(&st)), HeaderMap::new()).await;
        assert_eq!(missing.unwrap_err().0, StatusCode::UNAUTHORIZED);

        let wrong = devices(State(Arc::clone(&st)), auth("not-the-local-token")).await;
        assert_eq!(wrong.unwrap_err().0, StatusCode::UNAUTHORIZED);

        let ok = devices(State(Arc::clone(&st)), auth(LOCAL)).await;
        assert!(ok.is_ok(), "the local bearer must be accepted on a device route");

        let principal = require_device(&st, &auth(LOCAL)).expect("local principal");
        assert_eq!(principal, crate::local_token::LOCAL_PRINCIPAL);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The HTTP half of the audit stream, mounted the way `main.rs` mounts it: a real request, a
    /// real layer, a record with the status and duration but no body.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_http_route_log_writes_one_record_per_request() {
        let dir = scratch("http-audit");
        let st = state(&dir);
        let app = axum::Router::new()
            .route("/v1/devices", axum::routing::get(devices))
            .route("/v1/health", axum::routing::get(health))
            .layer(axum::middleware::from_fn_with_state(
                Arc::clone(&st),
                crate::audit::log_http,
            ))
            .with_state(Arc::clone(&st));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let response = reqwest::get(format!("http://{addr}/v1/devices")).await.unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let record = st.audit.last("http").expect("a request is audited");
        assert_eq!(record["method"], "GET");
        assert_eq!(record["path"], "/v1/devices");
        assert_eq!(record["outcome"], "401");
        assert!(record.get("bytes").is_none(), "no body size, no body");
        assert!(record["duration_ms"].as_f64().is_some());

        // Health is polled continuously; it must not fill the file.
        let health_response = reqwest::get(format!("http://{addr}/v1/health")).await.unwrap();
        assert_eq!(health_response.status(), StatusCode::OK);
        assert_eq!(st.audit.all("http").len(), 1, "health is not audited");

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Adding a local principal must not change the device path it rides beside: a WS ticket is
    /// still single-use, and a revoked/unknown token is still refused.
    #[tokio::test]
    async fn the_device_ticket_path_is_unchanged_beside_the_local_token() {
        let dir = scratch("ticket");
        let st = state(&dir);

        let ticket = st.tickets.mint_ticket("device-abc");
        assert_eq!(require_device(&st, &auth(&ticket)).unwrap(), "device-abc");
        assert_eq!(
            require_device(&st, &auth(&ticket)).unwrap_err().0,
            StatusCode::UNAUTHORIZED,
            "a ticket must stay single-use"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `status` cannot read the service's environment, so it asks this route. It must answer with
    /// the same field `pair/start` reports, and it must not be an unauthenticated oracle for the
    /// machine's hostname.
    #[tokio::test]
    async fn pair_host_reports_the_pairing_host_without_minting_a_code() {
        let dir = scratch("pair-host");
        let st = state(&dir);

        let refused = pair_host(State(Arc::clone(&st)), HeaderMap::new()).await;
        assert_eq!(refused.unwrap_err().0, StatusCode::UNAUTHORIZED);

        let ok = pair_host(State(Arc::clone(&st)), auth(LOCAL)).await.expect("local bearer");
        assert_eq!(ok.0.get("host").and_then(Value::as_str), Some("localhost"));
        assert_eq!(
            ok.0.get("protocol_version").and_then(Value::as_u64),
            Some(PROTOCOL_VERSION as u64)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An engine address nothing listens on, so a test can prove an *upgrade* was admitted without
    /// a real engine behind it: the dial is refused immediately and the relay closes 1011.
    fn closed_engine() -> &'static str {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        Box::leak(format!("ws://{addr}/api/ws").into_boxed_str())
    }

    /// Serve the real upgrade handler, exactly as `main.rs` mounts it.
    async fn serve(st: Arc<AppState>) -> (SocketAddr, tokio::task::JoinHandle<()>) {
        let app = axum::Router::new()
            .route("/v1/ws", axum::routing::get(ws_upgrade))
            .with_state(st);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        (addr, server)
    }

    /// Fill a device's registry with sockets whose control queue is already full: they can never be
    /// closed, so `admit` cannot free a slot.
    fn wedged_sockets(
        st: &AppState,
        device: &str,
    ) -> Vec<tokio::sync::mpsc::Receiver<crate::relay::Control>> {
        let mut keep = Vec::new();
        for _ in 0..crate::relay::MAX_SOCKETS_PER_DEVICE {
            let (tx, rx) = tokio::sync::mpsc::channel::<crate::relay::Control>(1);
            tx.try_send(crate::relay::Control::Close(1000, "noise".into()))
                .expect("the queue is empty");
            st.relay_sockets.register(device, tx);
            keep.push(rx);
        }
        keep
    }

    /// `proxy.py:525-529` refused a fifth socket outright. Here the refusal only happens when no
    /// socket can be closed — and then it is an HTTP answer, not a socket that opens and dies.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_upgrade_is_refused_when_no_socket_can_be_evicted() {
        let dir = scratch("cap-refuse");
        let st = state_with_engine(&dir, closed_engine());
        st.store
            .add_device("device-a", "phone", "ios", &"k".repeat(40), "stored");
        let _keep = wedged_sockets(&st, "device-a");
        let ticket = st.tickets.mint_ticket("device-a");
        let (addr, server) = serve(st.clone()).await;

        let result =
            tokio_tungstenite::connect_async(format!("ws://{addr}/v1/ws?ws_ticket={ticket}")).await;
        match result {
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) => assert_eq!(
                response.status(),
                StatusCode::TOO_MANY_REQUESTS,
                "the upgrade is refused, not opened and killed"
            ),
            Ok(_) => panic!("a socket opened while no slot could be freed"),
            Err(other) => panic!("unexpected handshake failure: {other}"),
        }
        assert_eq!(
            st.relay_sockets.count("device-a"),
            crate::relay::MAX_SOCKETS_PER_DEVICE,
            "the four conversations that are running keep running"
        );

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The upgrade path itself evicts: a device at its cap gets in, and only its own longest-idle
    /// socket is closed.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_upgrade_at_the_cap_evicts_the_oldest_socket_instead_of_refusing() {
        let dir = scratch("cap-evict");
        let st = state_with_engine(&dir, closed_engine());
        st.store
            .add_device("device-a", "phone", "ios", &"k".repeat(40), "stored");
        st.store
            .add_device("device-b", "tablet", "ios", &"j".repeat(40), "stored");

        let mut a = Vec::new();
        for _ in 0..crate::relay::MAX_SOCKETS_PER_DEVICE {
            let (tx, rx) = tokio::sync::mpsc::channel(8);
            st.relay_sockets.register("device-a", tx);
            a.push(rx);
        }
        let (b_tx, mut b_rx) = tokio::sync::mpsc::channel(8);
        st.relay_sockets.register("device-b", b_tx);

        let ticket = st.tickets.mint_ticket("device-a");
        let (addr, server) = serve(st.clone()).await;
        let (_client, _) =
            tokio_tungstenite::connect_async(format!("ws://{addr}/v1/ws?ws_ticket={ticket}"))
                .await
                .expect("the upgrade is admitted by evicting the oldest socket");

        assert_eq!(
            a.remove(0).try_recv(),
            Ok(crate::relay::Control::Close(
                crate::relay::CLOSE_EVICTED,
                "device_cap".into()
            )),
            "the oldest socket of this device made room"
        );
        for receiver in a.iter_mut() {
            assert!(
                receiver.try_recv().is_err(),
                "a newer socket was cut as well"
            );
        }
        assert!(
            b_rx.try_recv().is_err(),
            "another device's socket must never be evicted for this one"
        );
        assert_eq!(st.relay_sockets.count("device-b"), 1);

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The point of the probe. A token file that exists is not a reason to send it: when the engine
    /// answered `auth_required: false`, `engine_token()` is `None` and every connection — RPC, relay,
    /// display, bot message — is dialled without `?token=`.
    #[tokio::test]
    async fn no_token_is_read_when_the_engine_wants_none() {
        let dir = scratch("engine-auth-off");
        let st = state(&dir);
        std::fs::write(&st.engine_token_file, "left-over-from-a-previous-build").unwrap();

        // Still the strict shape while the decision says "required": the file is read.
        assert_eq!(
            st.engine_token().as_deref(),
            Some("left-over-from-a-previous-build")
        );
        let required_url =
            crate::engine_client::engine_url(&st.engine_ws, st.engine_token().as_deref());
        assert!(
            required_url.contains("token=left-over-from-a-previous-build"),
            "a required engine gets the token: {required_url}"
        );

        let mut off = state(&dir);
        let state_off = Arc::get_mut(&mut off).expect("sole owner in a test");
        state_off.engine_auth = crate::engine_auth::EngineAuth::NotRequired;

        assert_eq!(off.engine_token(), None, "auth_required=false must not send the file");
        let url = crate::engine_client::engine_url(&off.engine_ws, off.engine_token().as_deref());
        assert_eq!(url, "ws://127.0.0.1:9121/api/ws", "the URL carries no token parameter");
        assert!(!url.contains("token="), "{url}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Inconclusive keeps today's behaviour: the probe could not answer, so the token is still read
    /// and still sent. A missing credential must never be *assumed* to be fine.
    #[tokio::test]
    async fn an_inconclusive_probe_still_sends_the_token() {
        let dir = scratch("engine-auth-unknown");
        let mut st = state(&dir);
        std::fs::write(&st.engine_token_file, "per-boot-token").unwrap();
        Arc::get_mut(&mut st).expect("sole owner").engine_auth =
            crate::engine_auth::EngineAuth::Unknown("engine down".to_string());
        assert_eq!(st.engine_token().as_deref(), Some("per-boot-token"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
