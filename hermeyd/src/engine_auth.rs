//! Whether the engine wants a token on its socket at all.
//!
//! The question is answered **by the socket**, not by `/api/health`. `auth_required` there states
//! whether the dashboard's OAuth gate is engaged (a non-loopback bind or a public URL); a loopback
//! `hermes serve` answers `false` while its `/api/ws` still demands the per-boot session token and
//! refuses a tokenless upgrade with HTTP 403. Reading that `false` as "no credential needed" made
//! this service dial bare and fail every relay and RPC with 403 — measured 2026-11-21 against a
//! stock v0.23.0 engine: `/api/health` → `{"ok":true,"auth_required":false}`, `/api/ws?token=…` →
//! accepted, `/api/ws` without → `403 Forbidden`.
//!
//! So the probe performs exactly the upgrade it is deciding about: one tokenless dial, at boot and
//! once per `status`.
//!
//! * accepted → `NotRequired`: the engine really does not check, and `?token=` is noise.
//! * refused with 401/403 → `Required`: that is the engine asking for the credential.
//! * anything else (no answer, a 5xx, a socket closed before the upgrade completed) → `Unknown`,
//!   which sends the token exactly as the service always has. An engine that is merely busy is not
//!   evidence that it stopped wanting a credential, and sending the right token is never worse than
//!   omitting it: an engine that does not check ignores the query string.
//!
//! What stays: `HERMEYD_ENGINE_WS` (the protocol), `HERMEYD_ENGINE_HOME` (direct file reads — see
//! `previews`, `skills`, `bot_docs`) and `HERMEYD_ENGINE_TOKEN_FILE` (the credential when one is
//! needed). Only *sending* the token becomes conditional.

use std::path::Path;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Error as WsError;

/// How long the probe waits for an engine to answer the upgrade. A refused connect returns at once;
/// this bound is for a listener that accepts TCP and then says nothing.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// The engine's answer to "do you want a token": two definite values and one honest "I could not
/// tell", which is deliberately not the same as "not required".
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineAuth {
    /// A tokenless upgrade was accepted. No token is read or sent.
    NotRequired,
    /// A tokenless upgrade was refused with 401/403: this engine wants the credential.
    Required,
    /// The probe reached no verdict (engine down, not answering, refusing for another reason). The
    /// reason is for the operator, not for a decision: `Unknown` sends the token.
    Unknown(String),
}

impl EngineAuth {
    /// Whether a token should be read and appended to the engine URL.
    ///
    /// Only a definite accepted upgrade turns this off. A failed probe keeps the service's original
    /// behaviour — a missing credential must never be *assumed* to be fine.
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
                "engine: no token required by {engine_ws} (a tokenless upgrade was accepted)"
            ),
            EngineAuth::Required => format!(
                "engine: token required by {engine_ws} (a tokenless upgrade was refused); sending {}",
                token_file.display()
            ),
            // The reason already names the socket it tried, so the line does not repeat it.
            EngineAuth::Unknown(reason) => format!(
                "engine: could not confirm the token is unnecessary — {reason}; requiring the token \
                 at {} as before",
                token_file.display()
            ),
        }
    }
}

/// The configured socket with any query string dropped: the probe must ask for an *unauthenticated*
/// upgrade, so a token a human pasted into `HERMEYD_ENGINE_WS` must not ride along and turn a
/// refusal into an accept.
fn bare_socket(engine_ws: &str) -> String {
    engine_ws
        .split(['?', '#'])
        .next()
        .unwrap_or(engine_ws)
        .trim()
        .to_string()
}

/// Ask the socket itself, with no credential.
pub async fn probe(engine_ws: &str) -> EngineAuth {
    let url = bare_socket(engine_ws);
    let attempt =
        tokio::time::timeout(PROBE_TIMEOUT, tokio_tungstenite::connect_async(url.as_str())).await;
    match attempt {
        Err(_) => EngineAuth::Unknown(format!(
            "{url} did not answer within {} s",
            PROBE_TIMEOUT.as_secs()
        )),
        // Accepted without a token: nothing to send. Close at once — this is a question, not a
        // session, and an idle socket on the engine would hold a client slot for nothing.
        Ok(Ok((mut socket, _response))) => {
            let _ = socket.close(None).await;
            EngineAuth::NotRequired
        }
        Ok(Err(WsError::Http(response))) => match response.status().as_u16() {
            401 | 403 => EngineAuth::Required,
            // A 5xx, a 404 on a wrong path, a proxy's own refusal: none of these say "no credential
            // needed", so they are not permission to stop sending one.
            code => EngineAuth::Unknown(format!("{url} refused the upgrade with HTTP {code}")),
        },
        Ok(Err(err)) => EngineAuth::Unknown(format!("{url} did not answer: {err}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// Serve one request on a fresh loopback port and answer it, so the probe meets a real socket
    /// rather than a mock.
    async fn one_shot(answer: Vec<u8>) -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buffer = [0u8; 2048];
            let _ = tokio::io::AsyncReadExt::read(&mut stream, &mut buffer).await;
            let _ = tokio::io::AsyncWriteExt::write_all(&mut stream, &answer).await;
            let _ = tokio::io::AsyncWriteExt::flush(&mut stream).await;
        });
        port
    }

    /// An engine that does not check: the upgrade is completed, and that is permission to stop
    /// sending a token.
    #[tokio::test]
    async fn an_accepted_tokenless_upgrade_means_not_required() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                let (stream, _) = listener.accept().unwrap();
                stream.set_nonblocking(true).unwrap();
                let stream = tokio::net::TcpStream::from_std(stream).unwrap();
                let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
                let _ = ws.close(None).await;
            });
        });

        let auth = probe(&format!("ws://127.0.0.1:{port}/api/ws")).await;
        assert_eq!(auth, EngineAuth::NotRequired);
        assert!(!auth.send_token());
        assert_eq!(auth.as_str(), "not-required");
    }

    /// The live shape of a stock engine: a tokenless upgrade is refused, which is the credential
    /// being asked for — not a mystery to route around.
    #[tokio::test]
    async fn a_refused_tokenless_upgrade_means_required() {
        for code in ["401 Unauthorized", "403 Forbidden"] {
            let answer = format!(
                "HTTP/1.1 {code}\r\ncontent-type: application/json\r\ncontent-length: 2\r\n\
                 connection: close\r\n\r\n{{}}"
            );
            let port = one_shot(answer.into_bytes()).await;
            let auth = probe(&format!("ws://127.0.0.1:{port}/api/ws")).await;
            assert_eq!(auth, EngineAuth::Required, "{code}");
            assert!(auth.send_token());
            assert_eq!(auth.as_str(), "required");
        }
    }

    /// Anything that is not a definite refusal of the credential keeps the token: an engine that is
    /// busy or answering on the wrong path is not evidence that it stopped wanting one.
    #[tokio::test]
    async fn an_inconclusive_answer_is_unknown_and_still_sends_the_token() {
        for answer in [
            "HTTP/1.1 503 Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        ] {
            let port = one_shot(answer.as_bytes().to_vec()).await;
            let auth = probe(&format!("ws://127.0.0.1:{port}/api/ws")).await;
            assert!(auth.send_token(), "{answer}: {auth:?}");
            assert_eq!(auth.as_str(), "unknown");
        }
    }

    /// A dead engine is inconclusive, not permission.
    #[tokio::test]
    async fn a_probe_that_cannot_connect_keeps_the_token() {
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.local_addr().unwrap().port()
        };
        let auth = probe(&format!("ws://127.0.0.1:{port}/api/ws")).await;
        assert_eq!(auth.as_str(), "unknown");
        assert!(
            auth.send_token(),
            "an unreachable engine must not drop the token"
        );
        match &auth {
            EngineAuth::Unknown(reason) => {
                assert!(reason.contains(&format!("127.0.0.1:{port}/api/ws")), "{reason}")
            }
            other => panic!("expected Unknown, got {other:?}"),
        }
    }

    /// The probe asks without a credential: a token pasted into the configured URL must not turn
    /// the question into an answer it was handed.
    #[test]
    fn the_probe_drops_a_token_from_the_configured_url() {
        assert_eq!(
            bare_socket("ws://127.0.0.1:9121/api/ws?token=abc"),
            "ws://127.0.0.1:9121/api/ws"
        );
        assert_eq!(
            bare_socket("ws://127.0.0.1:9121/api/ws"),
            "ws://127.0.0.1:9121/api/ws"
        );
    }

    /// The three boot lines: the decision, and what it was decided from.
    #[test]
    fn the_boot_line_names_the_socket_and_the_decision() {
        let token = Path::new("/var/lib/hermeyd/engine.token");
        let ws = "ws://127.0.0.1:9121/api/ws";

        let line = EngineAuth::NotRequired.boot_line(ws, token);
        assert_eq!(
            line,
            "engine: no token required by ws://127.0.0.1:9121/api/ws \
             (a tokenless upgrade was accepted)"
        );

        let line = EngineAuth::Required.boot_line(ws, token);
        assert!(line.contains("token required by"), "{line}");
        assert!(line.contains("a tokenless upgrade was refused"), "{line}");
        assert!(line.contains("/var/lib/hermeyd/engine.token"), "{line}");

        let line = EngineAuth::Unknown(
            "ws://127.0.0.1:9121/api/ws did not answer: connection refused".into(),
        )
        .boot_line(ws, token);
        assert_eq!(
            line,
            "engine: could not confirm the token is unnecessary — ws://127.0.0.1:9121/api/ws did \
             not answer: connection refused; requiring the token at \
             /var/lib/hermeyd/engine.token as before"
        );
    }
}
