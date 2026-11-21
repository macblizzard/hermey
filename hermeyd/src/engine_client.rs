//! Minimal JSON-RPC client to the engine.
//!
//! The relay splices a *client's* socket through unchanged; routes like rooms and previews need the
//! host service to ask the engine questions of its own. One short-lived connection per call is the
//! right trade here: these are low-frequency, idempotent reads/writes, and it keeps no engine state
//! (no cached socket that a restart invalidates).

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

/// An engine refusal, with the engine's own error code kept. Routes that must tell two refusals
/// apart (unknown bot `4064` vs unknown provider) map on this; everything else can flatten it.
#[derive(Debug, Clone)]
pub struct EngineError {
    pub code: Option<i64>,
    pub message: String,
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

/// Call one engine method. `token` is the engine's per-boot token (read per call by the caller).
pub async fn rpc(
    engine_ws: &str,
    token: Option<String>,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    rpc_strict(engine_ws, token, method, params).await.map_err(|e| e.message)
}

/// `rpc`, but a refusal keeps the engine's error code. Only the code is new information; the
/// message is unchanged so existing callers' strings stay stable.
pub async fn rpc_strict(
    engine_ws: &str,
    token: Option<String>,
    method: &str,
    params: Value,
) -> Result<Value, EngineError> {
    let url = match token {
        Some(t) if !t.is_empty() => {
            let sep = if engine_ws.contains('?') { '&' } else { '?' };
            format!("{engine_ws}{sep}token={t}")
        }
        _ => engine_ws.to_string(),
    };

    let (mut ws, _resp) = tokio_tungstenite::connect_async(&url)
        .await
        .map_err(|e| EngineError { code: None, message: format!("engine unreachable: {e}") })?;

    let request = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    ws.send(Message::Text(request.to_string().into()))
        .await
        .map_err(|e| EngineError { code: None, message: format!("engine send failed: {e}") })?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        let next = tokio::time::timeout_at(deadline, ws.next())
            .await
            .map_err(|_| EngineError { code: None, message: format!("engine timeout on {method}") })?;
        let msg = match next {
            Some(Ok(m)) => m,
            Some(Err(e)) => {
                return Err(EngineError { code: None, message: format!("engine ws error on {method}: {e}") })
            }
            None => {
                return Err(EngineError {
                    code: None,
                    message: format!("engine closed before answering {method}"),
                })
            }
        };
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Close(c) => {
                return Err(EngineError {
                    code: None,
                    message: format!("engine closed ({c:?}) during {method}"),
                })
            }
            _ => continue,
        };
        // The engine interleaves events (no id) with replies; only the reply matters here.
        let value: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if value.get("id").and_then(|i| i.as_i64()) != Some(1) {
            continue;
        }
        if let Some(err) = value.get("error") {
            return Err(EngineError {
                code: err.get("code").and_then(|c| c.as_i64()),
                message: format!("engine refused {method}: {err}"),
            });
        }
        return Ok(value.get("result").cloned().unwrap_or(Value::Null));
    }
}
