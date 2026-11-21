//! Whether the engine wants a token on its socket at all.
//!
//! A stock Hermes install answers `{"ok":true,"auth_required":false}` on `/api/health`: its loopback
//! WS is unauthenticated, so appending `?token=` to every connection is noise at best and a stale
//! cookie at worst. Older builds — and any install with auth turned on — still require the per-boot
//! token file. Which one is in front of this service is **asked**, once per boot and once per
//! `status`, never assumed: one unauthenticated GET of the engine's own health route.
//!
//! What stays: `HERMEYD_ENGINE_WS` (the protocol), `HERMEYD_ENGINE_HOME` (direct file reads — see
//! `previews`, `skills`, `bot_docs`) and `HERMEYD_ENGINE_TOKEN_FILE` (still the credential when one
//! is needed). Only *sending* the token becomes conditional.
//!
//! An inconclusive probe is not permission to skip the token. The engine may simply be down while
//! this service starts (it serves beside a dead engine today), so `Unknown` behaves exactly as the
//! service always has: require the file, append the token.

use serde_json::Value;
use std::path::Path;
use std::time::Duration;

/// The engine's answer to "do you want a token": two definite values and one honest "I could not
/// tell", which is deliberately not the same as "not required".
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineAuth {
    /// `/api/health` said `auth_required: false`. No token is minted or sent.
    NotRequired,
    /// `/api/health` said `auth_required: true`, or said nothing this build understands.
    Required,
    /// The probe did not answer (engine down, not HTTP, a body that is not JSON). The reason is for
    /// the operator, not for a decision: `Unknown` requires the token, exactly as before.
    Unknown(String),
}

impl EngineAuth {
    /// Whether a token should be read and appended to the engine URL.
    ///
    /// Only a definite `auth_required: false` turns this off. A failed probe keeps today's
    /// behaviour — a missing token must never be *assumed* to be fine.
    pub fn send_token(&self) -> bool {
        !matches!(self, EngineAuth::NotRequired)
    }

    /// The stable word `status --json` reports.
    pub fn as_str(&self) -> &'static str {
        match self {
            EngineAuth::NotRequired => "not-required",
            EngineAuth::Required => "required",
            EngineAuth::Unknown(_) => "unknown",
        }
    }

    /// The boot line. One line, naming the socket it is about and the decision — a silent change in
    /// whether a credential rides the socket is undebuggable from a journal.
    pub fn boot_line(&self, engine_ws: &str, token_file: &Path) -> String {
        match self {
            EngineAuth::NotRequired => format!(
                "engine: no token required by {engine_ws} (auth_required=false)"
            ),
            EngineAuth::Required => format!(
                "engine: token required by {engine_ws} (auth_required=true); sending {}",
                token_file.display()
            ),
            // The reason names the URL it tried (see `probe`), so the line does not repeat it.
            EngineAuth::Unknown(reason) => format!(
                "engine: could not confirm the token is unnecessary — {reason}; requiring the token \
                 at {} as before",
                token_file.display()
            ),
        }
    }
}

/// The engine's health URL, derived from the WS endpoint this service already has configured.
///
/// `/api/ws` and `/api/health` are siblings on one loopback listener, so no new setting is needed:
/// `ws://127.0.0.1:9121/api/ws` → `http://127.0.0.1:9121/api/health`. A query string (a token a
/// human pasted) is dropped — the health route must answer without one.
pub fn health_url(engine_ws: &str) -> String {
    let bare = engine_ws
        .split(['?', '#'])
        .next()
        .unwrap_or(engine_ws)
        .trim()
        .trim_end_matches('/');
    let (scheme, rest) = match bare.split_once("://") {
        Some((scheme, rest)) => (scheme, rest),
        None => ("ws", bare),
    };
    let scheme = match scheme.to_ascii_lowercase().as_str() {
        "wss" | "https" => "https",
        _ => "http",
    };
    let (authority, path) = match rest.split_once('/') {
        Some((authority, path)) => (authority, format!("/{path}")),
        None => (rest, String::new()),
    };
    let health = match path.trim_end_matches('/').strip_suffix("/ws") {
        Some(prefix) if prefix.is_empty() => "/health".to_string(),
        Some(prefix) => format!("{prefix}/health"),
        // Any other path: the route this engine family always serves.
        None => "/api/health".to_string(),
    };
    format!("{scheme}://{authority}{health}")
}

/// The decision from a parsed `/api/health` body, with no I/O — the test suite pins this.
pub fn interpret(body: &Value) -> EngineAuth {
    match body.get("auth_required") {
        Some(Value::Bool(false)) => EngineAuth::NotRequired,
        Some(Value::Bool(true)) => EngineAuth::Required,
        // `null`, `"false"`, `0`: a shape this build cannot vouch for. Strict is the safe side.
        Some(other) => EngineAuth::Unknown(format!("auth_required is not a boolean: {other}")),
        None => EngineAuth::Unknown("the body has no auth_required".to_string()),
    }
}

/// Where the answer came from, for the failure text: the URL, never the body.
pub async fn probe(engine_ws: &str) -> EngineAuth {
    let url = health_url(engine_ws);
    // Short: boot must not wait on an engine that is down, and `status` is a diagnostic, not a
    // monitor. A refused connect returns immediately; this timeout is for a hung listener.
    let client = match reqwest::Client::builder().timeout(Duration::from_secs(2)).build() {
        Ok(client) => client,
        Err(e) => return EngineAuth::Unknown(format!("no HTTP client: {e}")),
    };
    let response = match client.get(&url).send().await {
        Ok(response) => response,
        // `without_url` because the URL is already the first thing this sentence says: reqwest's
        // own message repeats it, and a line with the same URL three times is harder to read than
        // the fact it carries.
        Err(e) => {
            return EngineAuth::Unknown(format!("{url} did not answer: {}", e.without_url()))
        }
    };
    let status = response.status();
    if !status.is_success() {
        return EngineAuth::Unknown(format!("{url} answered {status}"));
    }
    let body: Value = match response.json().await {
        Ok(body) => body,
        Err(e) => return EngineAuth::Unknown(format!("{url} is not JSON: {e}")),
    };
    match interpret(&body) {
        EngineAuth::Unknown(reason) => EngineAuth::Unknown(format!("{url}: {reason}")),
        decided => decided,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// Strip `scheme://host:port` so a failure text can be asserted without the port.
    fn endpoint(url: &str) -> String {
        url.split_once("://")
            .map(|(_, rest)| rest.to_string())
            .unwrap_or_else(|| url.to_string())
    }

    /// The URL the probe and the boot line name: the WS endpoint's sibling, over HTTP.
    #[test]
    fn the_health_url_is_the_ws_endpoints_sibling() {
        assert_eq!(
            health_url("ws://127.0.0.1:9121/api/ws"),
            "http://127.0.0.1:9121/api/health"
        );
        assert_eq!(
            health_url("ws://127.0.0.1:9121/api/ws/"),
            "http://127.0.0.1:9121/api/health"
        );
        // A stale token in the URL must not be forwarded to a route that does not need one.
        assert_eq!(
            health_url("ws://127.0.0.1:9121/api/ws?token=abc"),
            "http://127.0.0.1:9121/api/health"
        );
        assert_eq!(
            health_url("wss://engine.example/api/ws"),
            "https://engine.example/api/health"
        );
        // No path at all: the route this engine family serves.
        assert_eq!(health_url("ws://127.0.0.1:9121"), "http://127.0.0.1:9121/api/health");
    }

    /// Stock Hermes: `auth_required: false` is the whole permission to skip the token.
    #[test]
    fn only_a_boolean_false_turns_the_token_off() {
        let auth = interpret(&json!({"ok": true, "auth_required": false}));
        assert_eq!(auth, EngineAuth::NotRequired);
        assert!(!auth.send_token());
        assert_eq!(auth.as_str(), "not-required");

        let auth = interpret(&json!({"ok": true, "auth_required": true}));
        assert_eq!(auth, EngineAuth::Required);
        assert!(auth.send_token());
        assert_eq!(auth.as_str(), "required");
    }

    /// A body this build cannot vouch for is inconclusive, and inconclusive keeps the token.
    #[test]
    fn an_ambiguous_or_missing_field_is_inconclusive_and_stays_strict() {
        for body in [
            json!({"ok": true}),
            json!({"auth_required": null}),
            json!({"auth_required": "false"}),
            json!({"auth_required": 0}),
        ] {
            let auth = interpret(&body);
            assert!(auth.send_token(), "{body} must not drop the token: {auth:?}");
            assert_eq!(auth.as_str(), "unknown");
        }
    }

    /// The three boot lines: the decision, and what it was decided from.
    #[test]
    fn the_boot_line_names_the_socket_and_the_decision() {
        let token = Path::new("/var/lib/hermeyd/engine.token");
        let ws = "ws://127.0.0.1:9121/api/ws";

        let line = EngineAuth::NotRequired.boot_line(ws, token);
        assert_eq!(
            line,
            "engine: no token required by ws://127.0.0.1:9121/api/ws (auth_required=false)"
        );

        let line = EngineAuth::Required.boot_line(ws, token);
        assert!(line.contains("token required by"), "{line}");
        assert!(line.contains("auth_required=true"), "{line}");
        assert!(line.contains("/var/lib/hermeyd/engine.token"), "{line}");

        let line = EngineAuth::Unknown(
            "http://127.0.0.1:9121/api/health did not answer: connection refused".into(),
        )
        .boot_line(ws, token);
        assert_eq!(
            line,
            "engine: could not confirm the token is unnecessary — http://127.0.0.1:9121/api/health \
             did not answer: connection refused; requiring the token at /var/lib/hermeyd/engine.token \
             as before"
        );
    }

    /// The probe itself, against a loopback server: the hermetic shape of the live engine.
    #[tokio::test]
    async fn the_probe_reads_auth_required_from_a_real_http_answer() {
        for (body, expected_required) in
            [(r#"{"ok":true,"auth_required":false}"#, false), (r#"{"auth_required":true}"#, true)]
        {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind a fake engine");
            let port = listener.local_addr().unwrap().port();
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { continue };
                    let mut buffer = [0u8; 2048];
                    let _ = stream.read(&mut buffer);
                    let response = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\
                         content-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = stream.write_all(response.as_bytes());
                }
            });

            let ws = format!("ws://127.0.0.1:{port}/api/ws");
            let auth = probe(&ws).await;
            assert_eq!(auth.send_token(), expected_required, "{auth:?}");
            if !expected_required {
                assert_eq!(auth, EngineAuth::NotRequired);
            }
        }
    }

    /// A dead engine is inconclusive, not permission: the token stays required.
    #[tokio::test]
    async fn a_probe_that_cannot_reach_the_engine_keeps_the_token() {
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.local_addr().unwrap().port()
        };
        let auth = probe(&format!("ws://127.0.0.1:{port}/api/ws")).await;
        assert_eq!(auth.as_str(), "unknown");
        assert!(auth.send_token(), "an unreachable engine must not drop the token");
        match &auth {
            EngineAuth::Unknown(reason) => {
                assert!(reason.contains(&endpoint(&format!("127.0.0.1:{port}/api/health"))), "{reason}")
            }
            other => panic!("expected Unknown, got {other:?}"),
        }
    }

    /// An HTTP error is inconclusive too — a 401 from a proxy must not read as "no token needed".
    #[tokio::test]
    async fn an_http_error_answer_is_inconclusive() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind a fake engine");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut buffer = [0u8; 2048];
                let _ = stream.read(&mut buffer);
                let _ = stream.write_all(
                    b"HTTP/1.1 503 Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                );
            }
        });
        let auth = probe(&format!("ws://127.0.0.1:{port}/api/ws")).await;
        assert_eq!(auth.as_str(), "unknown", "{auth:?}");
        assert!(auth.send_token());
    }
}
