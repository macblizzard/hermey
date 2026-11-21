//! Browser fill targets: a browser extension joins over `/v1/browser/ws`, and `/v1/browser/act`
//! sends one instruction to it — probe the page, click a button, or fill login fields.
//!
//! Mirrors `browser_bridge.py` field for field. What drives a browser here is **not** an engine RPC
//! and not a bundled chromium: the backend is the Hermey sign-in extension loaded into the bot
//! screen's browser, which dials this host over loopback and waits for fills. The values travel
//! host → extension → page and never come back — a probe answers with counts and labels, never an
//! input's content.
//!
//! ```text
//! WS   /v1/browser/ws            the extension's socket; first frame is {"type":"hello","label":…}
//! GET  /v1/browser/targets   ->  {"browsers": [{"id", "label"}]}
//! POST /v1/browser/act           {"type": probe|click|clickHref|submit|fill|goto|ping, …}
//! ```
//!
//! `act` and `targets` answer without a device credential, exactly as the bridge serves them: the
//! caller beside the apps is the agent's own sign-in skill on this host (`hermey_signin.py`), which
//! holds no device credential — the ws dialer is the extension, which holds none either. Every
//! other `/v1` route stays device-authenticated.
//!
//! Because they are unauthenticated, these three routes are **not** on the main router (8788, which
//! `tailscale serve` publishes as https://host:8445). They are mounted on a second loopback listener
//! — `HERMEYD_BROWSER_PORT`, default 8790 — so a tailnet peer gets a 404 and only this host can list
//! or drive the extension. The extension dials `ws://127.0.0.1:8790/v1/browser/ws`; 8790 must never
//! be added to `tailscale serve`.
//!
//! Empty is a normal state, not an error: a registry with no browser answers 409 on `act`, which is
//! what the app shows ("no browser connected").

use crate::routes::AppState;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::Response;
use axum::Json;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// A fill must be quick: the card expires in two minutes and a human is watching the page.
const FILL_TIMEOUT: Duration = Duration::from_secs(10);

/// One connected browser tab-set, by its own id.
struct Browser {
    label: String,
    tx: tokio::sync::mpsc::UnboundedSender<Value>,
    pending: Mutex<HashMap<String, tokio::sync::oneshot::Sender<Value>>>,
}

/// Who is available to receive an instruction.
#[derive(Default)]
pub struct Registry {
    browsers: Mutex<HashMap<String, Browser>>,
}

impl Registry {
    /// One browser at a time, as the bridge registers them: a shared profile means at most one of
    /// them is really showing the owner's page, so a fresh hello replaces whatever came before.
    pub fn register(&self, label: &str, tx: tokio::sync::mpsc::UnboundedSender<Value>) -> String {
        let id = crate::auth::random_token(9);
        let mut browsers = self.browsers.lock().unwrap();
        browsers.clear();
        browsers.insert(
            id.clone(),
            Browser {
                label: label.to_string(),
                tx,
                pending: Mutex::new(HashMap::new()),
            },
        );
        id
    }

    pub fn unregister(&self, id: &str) {
        let Some(browser) = self.browsers.lock().unwrap().remove(id) else { return };
        for (_, future) in browser.pending.lock().unwrap().drain() {
            // Null is the "no reply" sentinel `command` filters out: nobody gets a fake answer.
            let _ = future.send(Value::Null);
        }
    }

    /// A reply, matched to the call that asked for it. The whole message, because a probe answers
    /// with the page's shape and not only a boolean.
    pub fn on_message(&self, id: &str, message: Value) {
        let mut future = None;
        {
            let browsers = self.browsers.lock().unwrap();
            if let Some(browser) = browsers.get(id) {
                if let Some(call_id) = message.get("id").and_then(|i| i.as_str()).map(str::to_string) {
                    future = browser.pending.lock().unwrap().remove(&call_id);
                }
            }
        }
        if let Some(future) = future {
            let _ = future.send(message);
        }
    }

    /// Send one instruction to every connected browser and take the first answer.
    ///
    /// Every, not the first: a browser that died without a clean close leaves its registration
    /// behind, and asking only that one made a plainly-connected browser look absent.
    async fn command(&self, payload: Value) -> Option<Value> {
        let call_id = crate::auth::random_token(9);
        let mut frame = payload.clone();
        frame["id"] = json!(call_id.clone());
        let mut targets: Vec<(String, tokio::sync::oneshot::Receiver<Value>)> = Vec::new();
        {
            let browsers = self.browsers.lock().unwrap();
            for (id, browser) in browsers.iter() {
                let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
                browser.pending.lock().unwrap().insert(call_id.clone(), reply_tx);
                if browser.tx.send(frame.clone()).is_err() {
                    browser.pending.lock().unwrap().remove(&call_id);
                    continue;
                }
                targets.push((id.clone(), reply_rx));
            }
        }
        if targets.is_empty() {
            return None;
        }
        // The first reply wins; the others are dropped with their sockets.
        let deadline = tokio::time::Instant::now() + FILL_TIMEOUT;
        for (id, reply_rx) in targets {
            match tokio::time::timeout_at(deadline, reply_rx).await {
                Ok(Ok(reply)) if !reply.is_null() => {
                    // Clean the leftovers out of every registration this call touched.
                    let browsers = self.browsers.lock().unwrap();
                    for browser in browsers.values() {
                        browser.pending.lock().unwrap().remove(&call_id);
                    }
                    return Some(reply);
                }
                _ => {
                    let browsers = self.browsers.lock().unwrap();
                    if let Some(browser) = browsers.get(&id) {
                        browser.pending.lock().unwrap().remove(&call_id);
                    } else {
                        drop(browsers);
                        self.unregister(&id);
                    }
                }
            }
        }
        None
    }

    pub fn list(&self) -> Vec<Value> {
        self.browsers
            .lock()
            .unwrap()
            .iter()
            .map(|(id, b)| json!({"id": id, "label": b.label}))
            .collect()
    }
}

/// `WS /v1/browser/ws` — one browser's socket. The first frame must be the hello; a socket that
/// cannot say hello is not a browser.
pub async fn channel(
    ws: WebSocketUpgrade,
    State(st): State<Arc<AppState>>,
) -> Response {
    ws.on_upgrade(move |socket| run_channel(socket, st))
}

async fn run_channel(mut socket: WebSocket, st: Arc<AppState>) {
    let hello = match tokio::time::timeout(Duration::from_secs(10), socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => serde_json::from_str::<Value>(&text).ok(),
        _ => None,
    };
    let Some(hello) = hello else { return };
    let label: String = hello
        .get("label")
        .and_then(|l| l.as_str())
        .unwrap_or("browser")
        .chars()
        .take(60)
        .collect();

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Value>();
    let id = st.browsers.register(&label, tx);
    eprintln!("browser connected: {id} ({label})");

    loop {
        tokio::select! {
            outbound = rx.recv() => {
                let Some(frame) = outbound else { break };
                if socket.send(Message::Text(frame.to_string().into())).await.is_err() {
                    break;
                }
            }
            incoming = socket.recv() => {
                let Some(Ok(message)) = incoming else { break };
                // Protocol-level pings are the peer's keepalive.
                if let Message::Ping(payload) = message {
                    let _ = socket.send(Message::Pong(payload)).await;
                    continue;
                }
                let Message::Text(text) = message else { continue };
                let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
                st.browsers.on_message(&id, frame);
            }
        }
    }

    st.browsers.unregister(&id);
    eprintln!("browser disconnected: {id}");
}

/// `POST /v1/browser/act` — one instruction for the browser: probe the page, click a button, or
/// fill fields. Scripted logins need to advance a page, and the values still never come back.
pub async fn act(
    State(st): State<Arc<AppState>>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, Fail> {
    let kind = body.get("type").and_then(|t| t.as_str()).unwrap_or("");
    if !matches!(kind, "probe" | "click" | "clickHref" | "submit" | "fill" | "goto" | "ping") {
        return Err(bad(StatusCode::BAD_REQUEST, "unknown instruction"));
    }
    let mut payload = json!({"type": kind});
    if matches!(kind, "click" | "clickHref") {
        payload["match"] = json!(body.get("match").and_then(|m| m.as_str()).unwrap_or(""));
    }
    if kind == "goto" {
        payload["url"] = json!(body.get("url").and_then(|u| u.as_str()).unwrap_or(""));
    }
    if kind == "fill" {
        payload["fields"] = body.get("fields").cloned().unwrap_or_else(|| json!([]));
    }
    match st.browsers.command(payload).await {
        Some(reply) => Ok(Json(reply)),
        None => Err(bad(StatusCode::CONFLICT, "no browser connected")),
    }
}

/// `GET /v1/browser/targets` — what the app shows: is a browser available to receive a sign-in?
pub async fn targets(State(st): State<Arc<AppState>>) -> Result<Json<Value>, Fail> {
    Ok(Json(json!({ "browsers": st.browsers.list() })))
}
