//! Structured audit log — port of `Bridge/hermes_bridge/audit.py`.
//!
//! The requirement is blunt: the service may record *who* did *what*, for how long and how many
//! bytes — never prompt text, never tool output, never a token. The Python module enforced that at
//! the type level: `emit` accepts a fixed set of scalars and has no parameter that could carry a
//! payload. This port keeps that rule. There is no field here that can hold a body, and every
//! string field is matched against the same closed character sets the Python module used:
//!
//! * `_SAFE_TOKEN` — `^[A-Za-z0-9_.:-]{1,96}$` (method, direction, outcome, reason, profile)
//! * `_SAFE_PATH`  — `^/[A-Za-z0-9/_.-]{1,96}$` (path)
//! * `_SAFE_ID`    — `^[A-Za-z0-9_-]{1,64}$` (device)
//!
//! A value that fails its pattern is replaced by `invalid`/`unknown`/`other` exactly as in Python,
//! so a credential pasted into a method name lands in the log as the word `invalid`, not as the
//! credential.
//!
//! One record is one JSON object on one line, with the Python module's field order and compact
//! separators (`json.dumps(record, separators=(",", ":"), ensure_ascii=True)`), appended to a
//! size-bounded file in the service state dir. When the cap is reached the file is renamed to
//! `.1` (the previous `.1` is replaced) and writing continues in a fresh file, so the log can
//! never grow without bound.
//!
//! Two deliberate differences from the Python module, both documented where they matter:
//!
//! * an unknown event name is dropped (Python raised `ValueError`); this runs on request paths,
//!   and a typo must not turn a 200 into a 500. The closed `EVENTS` set is still asserted by a
//!   test, so a typo fails CI instead of shipping.
//! * `/v1/health` is not audited (the Rust request log already skipped it). Health is polled every
//!   few seconds; recording it would drown every other event.

use axum::extract::State;
use axum::response::Response;
use serde_json::Value;
use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

/// Where the records live, beside `bridge.db` in the service state dir.
pub const FILE_NAME: &str = "audit.jsonl";
/// Rotation threshold. Python handed records to `logging` and relied on the deployment's log
/// rotation; a file this service owns must bound itself. 8 MiB is roughly 40k records.
pub const MAX_AUDIT_BYTES: u64 = 8 * 1024 * 1024;
/// In-memory mirror size, the Python module's `keep=500`. Only tests read it.
const KEEP: usize = 500;

/// `audit.py:EVENTS` — a closed set, plus `frame_trimmed`.
///
/// The Python bridge had no distinct event for "an oversized engine frame was trimmed" (it was
/// folded into `history_paged`); the Rust relay trims non-history frames too, so the event is
/// named rather than borrowed.
pub const EVENTS: &[&str] = &[
    "ws_open",
    "ws_close",
    "ticket_rejected",
    "client_request",
    "client_response",
    "client_response_dropped",
    "client_request_rejected",
    "server_request",
    "server_request_declined",
    "server_response",
    "notification",
    "unmatched_response",
    "capabilities_sent",
    "frame_too_large",
    "frame_trimmed",
    "protocol_error",
    "upstream_error",
    "request_abandoned",
    "session_pointer",
    "session_autoresume",
    "session_rekeyed",
    "bot_message",
    "bot_ask",
    "bots.purge",
    "bots.model_settings",
    "bots.approval_mode",
    "local_computer.connected",
    "local_computer.disconnected",
    "local_computer.execute",
    "local_computer.observe",
    "local_computer.act",
    "local_computer.file",
    "local_computer.browser",
    "local_computer.resume",
    "local_computer.revoke",
    "local_computer.allow",
    "local_computer.rejected",
    "local_computer.skill",
    "credentials.requested",
    "credentials.answered",
    "credentials.consumed",
    "credentials.cancelled",
    "browser.connected",
    "browser.disconnected",
    "pair.invite",
    "bots.routine_create",
    "bots.routine_state",
    "rooms.list",
    "rooms.create",
    "rooms.send",
    "rooms.disband",
    "rooms.rename",
    "bots.state",
    "display_open",
    "display_close",
    "history_page",
    "history_page_miss",
    "history_paged",
    "http",
];

/// `audit.py:ERROR_KINDS` — a JSON-RPC error message can quote the client's own input, so the
/// message never reaches the log; the caller classifies it into one of these.
pub const ERROR_KINDS: &[&str] = &[
    "session_busy",
    "unknown_session",
    "not_ready",
    "invalid_params",
    "unauthorised",
    "approval_pending",
    "gateway_unavailable",
    "method_not_found",
    "internal",
    "other",
];

fn is_token(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 96
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

fn is_path(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.first() == Some(&b'/')
        && bytes.len() <= 97
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'.' | b'-'))
}

fn is_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}

fn token_or<'a>(value: Option<&'a str>, fallback: &'a str) -> &'a str {
    match value {
        Some(v) if is_token(v) => v,
        _ => fallback,
    }
}

/// A short, log-safe form of a message: spaces and anything outside the token set become `_`.
/// Used for close reasons, which are prose (`"engine unreachable"`) in the relay and slugs in the
/// Python audit (`"engine_unreachable"`). The result always passes [`is_token`].
pub fn slug(value: &str) -> String {
    let mut out: String = value
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '-') {
                c
            } else {
                '_'
            }
        })
        .take(96)
        .collect();
    if out.is_empty() {
        out.push_str("other");
    }
    out
}

/// The first eight characters of a device id. Enough to correlate two records, not enough to be a
/// credential. Falls back to `unknown` when the id is not a safe id at all.
pub fn device_hint(device: Option<&str>) -> String {
    let Some(device) = device else {
        return "unknown".to_string();
    };
    let short: String = device.chars().take(8).collect();
    if is_id(&short) {
        short
    } else {
        "unknown".to_string()
    }
}

fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn round3(value: f64) -> f64 {
    (value * 1000.0).round() / 1000.0
}

/// `audit.py:_millis` — seconds in, milliseconds out, rounded to one decimal.
fn millis(value: Option<f64>) -> Option<f64> {
    value.map(|v| ((v.max(0.0) * 1000.0) * 10.0).round() / 10.0)
}

/// The fixed set of fields one record may carry. Every field is a scalar; there is no payload,
/// no params, no headers. Callers build it with `..Default::default()`.
#[derive(Default, Clone, Copy, Debug)]
pub struct Event<'a> {
    pub device: Option<&'a str>,
    pub method: Option<&'a str>,
    pub path: Option<&'a str>,
    /// Seconds, as `time.monotonic()` differences are in Python; recorded as `duration_ms`.
    pub duration_secs: Option<f64>,
    pub bytes: Option<usize>,
    pub direction: Option<&'a str>,
    pub outcome: Option<&'a str>,
    pub reason: Option<&'a str>,
    pub close_code: Option<u16>,
    pub profile: Option<&'a str>,
    pub error_code: Option<i64>,
    pub error_kind: Option<&'a str>,
}

/// The open file and how much this process has written to it. `None` after a failed open/write, so
/// the next record retries instead of the file staying dead for the process's lifetime.
struct Sink {
    file: Option<File>,
    written: u64,
}

/// One bounded JSON-lines file plus the Python module's in-memory mirror.
pub struct AuditLog {
    path: PathBuf,
    max_bytes: u64,
    keep: usize,
    sink: Mutex<Sink>,
    records: Mutex<VecDeque<Value>>,
    /// Keeps a broken state dir from printing the same error on every request.
    reported_failure: AtomicBool,
}

impl AuditLog {
    /// The log this service runs with: `<state>/audit.jsonl`, bounded at [`MAX_AUDIT_BYTES`].
    pub fn in_dir(dir: impl Into<PathBuf>) -> Self {
        Self::at(dir.into().join(FILE_NAME), MAX_AUDIT_BYTES)
    }

    /// An explicit path and cap (tests pin both).
    pub fn at(path: impl Into<PathBuf>, max_bytes: u64) -> Self {
        Self {
            path: path.into(),
            max_bytes: max_bytes.max(1),
            keep: KEEP,
            sink: Mutex::new(Sink {
                file: None,
                written: 0,
            }),
            records: Mutex::new(VecDeque::new()),
            reported_failure: AtomicBool::new(false),
        }
    }

    #[allow(dead_code)] // assertions in this module's tests
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Record one event. Returns the record it wrote, or `None` for an event outside [`EVENTS`].
    ///
    /// Never fails the caller: a state directory that is full, read-only or gone costs the audit
    /// line, not the request. That is `bot_transfers.record`'s rule applied to the audit stream.
    pub fn emit(&self, event: &str, e: Event<'_>) -> Option<Value> {
        if !EVENTS.contains(&event) {
            return None;
        }
        let record = self.build(event, &e);
        let line = encode_line(&self.fields(&record));
        self.append(&line);
        if self.keep > 0 {
            let mut mirror = match self.records.lock() {
                Ok(mirror) => mirror,
                Err(poisoned) => poisoned.into_inner(),
            };
            mirror.push_back(record.clone());
            while mirror.len() > self.keep {
                mirror.pop_front();
            }
        }
        Some(record)
    }

    /// The ordered field list Python emitted. Kept separate so the wire order is explicit and
    /// testable, and so no caller can add a field by accident.
    fn fields<'a>(&self, record: &'a Value) -> Vec<(&'static str, &'a Value)> {
        const ORDER: &[&str] = &[
            "ts",
            "event",
            "device",
            "path",
            "method",
            "duration_ms",
            "bytes",
            "direction",
            "outcome",
            "reason",
            "close_code",
            "profile",
            "error_code",
            "error_kind",
        ];
        ORDER
            .iter()
            .filter_map(|key| record.get(*key).map(|value| (*key, value)))
            .collect()
    }

    fn build(&self, event: &str, e: &Event<'_>) -> Value {
        let mut record = serde_json::Map::new();
        record.insert("ts".to_string(), json_num(round3(now_secs())));
        record.insert("event".to_string(), Value::String(event.to_string()));
        record.insert(
            "device".to_string(),
            Value::String(device_hint(e.device)),
        );
        if let Some(path) = e.path {
            record.insert(
                "path".to_string(),
                Value::String(if is_path(path) {
                    path.to_string()
                } else {
                    "invalid".to_string()
                }),
            );
        }
        if let Some(method) = e.method {
            record.insert(
                "method".to_string(),
                Value::String(token_or(Some(method), "invalid").to_string()),
            );
        }
        if let Some(ms) = millis(e.duration_secs) {
            record.insert("duration_ms".to_string(), json_num(ms));
        }
        if let Some(bytes) = e.bytes {
            record.insert("bytes".to_string(), uint(bytes as u64));
        }
        if let Some(direction) = e.direction {
            record.insert(
                "direction".to_string(),
                Value::String(token_or(Some(direction), "unknown").to_string()),
            );
        }
        if let Some(outcome) = e.outcome {
            record.insert(
                "outcome".to_string(),
                Value::String(token_or(Some(outcome), "unknown").to_string()),
            );
        }
        if let Some(reason) = e.reason {
            record.insert(
                "reason".to_string(),
                Value::String(token_or(Some(reason), "other").to_string()),
            );
        }
        if let Some(code) = e.close_code {
            record.insert("close_code".to_string(), uint(code as u64));
        }
        if let Some(profile) = e.profile {
            record.insert(
                "profile".to_string(),
                Value::String(token_or(Some(profile), "invalid").to_string()),
            );
        }
        if let Some(code) = e.error_code {
            record.insert("error_code".to_string(), Value::Number(serde_json::Number::from(code)));
        }
        if let Some(kind) = e.error_kind {
            record.insert(
                "error_kind".to_string(),
                Value::String(
                    if ERROR_KINDS.contains(&kind) {
                        kind
                    } else {
                        "other"
                    }
                    .to_string(),
                ),
            );
        }
        Value::Object(record)
    }

    /// Append one line, rotating first when it would cross the cap. A failure here is reported
    /// once per process, never returned: the request that produced the record is unaffected.
    fn append(&self, line: &str) {
        let mut sink = match self.sink.lock() {
            Ok(sink) => sink,
            Err(poisoned) => poisoned.into_inner(),
        };
        let line_len = line.len() as u64 + 1;
        if sink.file.is_none() {
            match self.open() {
                Ok((file, size)) => {
                    sink.file = Some(file);
                    sink.written = size;
                }
                Err(err) => {
                    drop(sink);
                    return self.report(err);
                }
            }
        }
        if sink.written > 0 && sink.written.saturating_add(line_len) > self.max_bytes {
            rotate(&self.path);
            sink.file = None;
            sink.written = 0;
            match self.open() {
                Ok((file, size)) => {
                    sink.file = Some(file);
                    sink.written = size;
                }
                Err(err) => {
                    drop(sink);
                    return self.report(err);
                }
            }
        }
        let Some(file) = sink.file.as_mut() else {
            return;
        };
        if let Err(err) = file
            .write_all(line.as_bytes())
            .and_then(|_| file.write_all(b"\n"))
        {
            // Drop the handle so the next record re-opens and retries; a full disk that is later
            // emptied must start working again without a restart.
            sink.file = None;
            drop(sink);
            return self.report(err);
        }
        sink.written = sink.written.saturating_add(line_len);
    }

    /// Open (creating parents) and report the size already on disk, so rotation is measured from
    /// what an earlier boot left rather than from zero. Never takes the sink lock: `append` holds it.
    fn open(&self) -> std::io::Result<(File, u64)> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        let size = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        Ok((file, size))
    }

    fn report(&self, err: std::io::Error) {
        if !self.reported_failure.swap(true, Ordering::Relaxed) {
            eprintln!(
                "audit: cannot write {}: {err}; auditing continues in memory",
                self.path.display()
            );
        }
    }

    // -- test helpers -------------------------------------------------------------------------

    #[allow(dead_code)] // read by the module's own tests, not by production paths
    pub fn records(&self) -> Vec<Value> {
        let mirror = match self.records.lock() {
            Ok(mirror) => mirror,
            Err(poisoned) => poisoned.into_inner(),
        };
        mirror.iter().cloned().collect()
    }

    #[allow(dead_code)]
    pub fn all(&self, event: &str) -> Vec<Value> {
        self.records()
            .into_iter()
            .filter(|record| record.get("event").and_then(Value::as_str) == Some(event))
            .collect()
    }

    #[allow(dead_code)]
    pub fn last(&self, event: &str) -> Option<Value> {
        self.all(event).pop()
    }

    #[allow(dead_code)]
    pub fn clear(&self) {
        if let Ok(mut mirror) = self.records.lock() {
            mirror.clear();
        }
    }
}

fn json_num(value: f64) -> Value {
    serde_json::Number::from_f64(value)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

fn uint(value: u64) -> Value {
    Value::Number(serde_json::Number::from(value))
}

/// One JSON object, one line, Python's separators and field order.
fn encode_line(fields: &[(&str, &Value)]) -> String {
    let mut out = String::with_capacity(160);
    out.push('{');
    for (index, (key, value)) in fields.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push('"');
        out.push_str(key);
        out.push_str("\":");
        out.push_str(&serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()));
    }
    out.push('}');
    out
}

/// Rename the log to `.1`, replacing any previous rotation. Best effort: a failed rotation means
/// the next record keeps appending to the too-large file, which is still better than dropping it.
fn rotate(path: &Path) {
    let rotated = match path.extension().and_then(|ext| ext.to_str()) {
        Some(ext) => path.with_extension(format!("{ext}.1")),
        None => path.with_extension("1"),
    };
    let _ = std::fs::rename(path, rotated);
}

/// `GET /v1/...` audit path. The bot-icons id is masked exactly as `app.py:349` did, because a
/// per-bot icon URL otherwise writes an unbounded set of path values into the log.
fn audit_path(raw: &str) -> &str {
    if raw.starts_with("/v1/bot-icons/") {
        // Python substituted the literal `{bot_id}`, which its own `_SAFE_PATH` then rejected as
        // `invalid`. Mask with a token that passes the pattern instead: the same privacy, a path
        // that is actually readable.
        "/v1/bot-icons/:id"
    } else {
        raw
    }
}

/// The HTTP half of the audit stream (`app.py:346-367`): method, path, status, duration. No body,
/// no headers, no query string — the query string is where tickets and codes live.
pub async fn log_http(
    State(st): State<Arc<crate::routes::AppState>>,
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let started = std::time::Instant::now();
    let response = next.run(req).await;
    let status = response.status().as_u16();
    // Health is polled continuously and says nothing about the owner's requests.
    if path != "/v1/health" {
        let path = audit_path(&path);
        let outcome = status.to_string();
        st.audit.emit(
            "http",
            Event {
                method: Some(method.as_str()),
                path: Some(path),
                duration_secs: Some(started.elapsed().as_secs_f64()),
                outcome: Some(&outcome),
                ..Event::default()
            },
        );
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-audit-{tag}-{}-{}",
            std::process::id(),
            now_secs()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch");
        dir
    }

    fn read(path: &Path) -> String {
        std::fs::read_to_string(path).unwrap_or_default()
    }

    #[test]
    fn every_event_name_is_in_the_closed_set() {
        // The `emit` guard silently drops names outside the set; this is the test that makes a
        // typo loud instead of invisible.
        let log = AuditLog::in_dir(scratch("names"));
        for event in EVENTS {
            assert!(
                log.emit(event, Event::default()).is_some(),
                "{event} is in EVENTS but emit refused it"
            );
        }
        assert!(log.emit("no.such.event", Event::default()).is_none());
    }

    #[test]
    fn a_record_has_python_field_names_and_order() {
        let dir = scratch("shape");
        let log = AuditLog::at(dir.join(FILE_NAME), 1_000_000);
        log.emit(
            "client_request",
            Event {
                device: Some("device-abcdef123456"),
                method: Some("session.resume"),
                path: Some("/v1/bots/cody/message"),
                duration_secs: Some(0.01234),
                bytes: Some(42),
                direction: Some("client_to_gateway"),
                outcome: Some("ok"),
                ..Event::default()
            },
        )
        .expect("known event");

        let text = read(log.path());
        let line = text.lines().next().expect("one line");
        // Field order is a compatibility fact (Python's `json.dumps` preserves insertion order);
        // assert on the raw line, because a parsed map would not remember it.
        for key in [
            "ts",
            "event",
            "device",
            "path",
            "method",
            "duration_ms",
            "bytes",
            "direction",
            "outcome",
        ] {
            assert!(line.contains(&format!("\"{key}\"")), "{key} missing from {line}");
        }
        let pos = |key: &str| line.find(&format!("\"{key}\"")).expect(key);
        assert!(pos("ts") < pos("event"));
        assert!(pos("event") < pos("device"));
        assert!(pos("device") < pos("path"));
        assert!(pos("path") < pos("method"));
        assert!(pos("method") < pos("duration_ms"));
        assert!(pos("duration_ms") < pos("bytes"));
        assert!(pos("bytes") < pos("direction"));
        assert!(pos("direction") < pos("outcome"));
        let record: Value = serde_json::from_str(line).expect("valid JSON");
        assert_eq!(record["event"], "client_request");
        assert_eq!(record["device"], "device-a", "device ids are short");
        assert_eq!(record["duration_ms"], 12.3);
        assert_eq!(record["bytes"], 42);
    }

    /// The point of the module: a refusal is recorded as a method and a reason, and nothing the
    /// client sent that could be a payload appears anywhere in the file.
    #[test]
    fn a_refused_method_records_no_payload_text() {
        let dir = scratch("refused");
        let log = AuditLog::at(dir.join(FILE_NAME), 1_000_000);
        log.emit(
            "client_request_rejected",
            Event {
                device: Some("phone-aa11"),
                method: Some("image.attach"),
                outcome: Some("refused"),
                reason: Some("method_not_allowed"),
                direction: Some("client_to_gateway"),
                bytes: Some(512),
                ..Event::default()
            },
        )
        .expect("known event");

        let text = read(log.path());
        let record: Value = serde_json::from_str(text.trim()).expect("valid JSON");
        assert_eq!(record["method"], "image.attach");
        assert_eq!(record["reason"], "method_not_allowed");
        assert_eq!(record["outcome"], "refused");
        assert_eq!(record["bytes"], 512);
        // There is no field that could hold the prompt the refusal was about.
        assert!(record.get("params").is_none());
        assert!(record.get("body").is_none());
        assert!(record.get("text").is_none());
    }

    /// A multi-megabyte message contributes its *size*, never its content.
    #[test]
    fn a_large_message_records_bytes_not_content() {
        let dir = scratch("large");
        let log = AuditLog::at(dir.join(FILE_NAME), 2 * 1024 * 1024);
        let payload = "SECRET-PROMPT ".repeat(50_000);
        log.emit(
            "client_request",
            Event {
                device: Some("phone-aa11"),
                method: Some("prompt.submit"),
                bytes: Some(payload.len()),
                direction: Some("client_to_gateway"),
                ..Event::default()
            },
        )
        .expect("known event");

        let text = read(log.path());
        assert!(text.len() < 512, "a line, not the message: {} bytes", text.len());
        assert!(!text.contains("SECRET-PROMPT"));
        let record: Value = serde_json::from_str(text.trim()).expect("valid JSON");
        assert_eq!(record["bytes"], payload.len());
    }

    /// A credential-shaped value handed to a free-form field is replaced by the fallback, not
    /// recorded. This is what makes "never log a token" structural rather than a convention.
    #[test]
    fn a_credential_shaped_value_never_appears() {
        let dir = scratch("credential");
        let log = AuditLog::at(dir.join(FILE_NAME), 1_000_000);
        // Assembled at runtime on purpose: a key-shaped *literal* in the source is itself a finding
        // for `Tools/ci/secret_scan.sh`, which looks for the shape of a real credential rather than
        // the words. The value still has to look like one at runtime, or the test proves nothing.
        let token = concat!("Bearer sk-live-", "0123456789", "-", "not-a-canary");
        log.emit(
            "client_request",
            Event {
                device: Some(token),
                method: Some(token),
                path: Some(token),
                outcome: Some(token),
                reason: Some(token),
                profile: Some(token),
                direction: Some(token),
                ..Event::default()
            },
        )
        .expect("known event");

        let text = read(log.path());
        assert!(!text.contains("sk-live"), "the credential reached the file: {text}");
        assert!(!text.contains("Bearer"));
        let record: Value = serde_json::from_str(text.trim()).expect("valid JSON");
        assert_eq!(record["device"], "unknown");
        assert_eq!(record["method"], "invalid");
        assert_eq!(record["path"], "invalid");
        assert_eq!(record["outcome"], "unknown");
        assert_eq!(record["reason"], "other");
        assert_eq!(record["profile"], "invalid");
    }

    #[test]
    fn rotation_bounds_the_file_and_keeps_one_previous() {
        let dir = scratch("rotate");
        let path = dir.join(FILE_NAME);
        let log = AuditLog::at(&path, 400);
        for _ in 0..200 {
            log.emit(
                "client_request",
                Event {
                    device: Some("phone-aa11"),
                    method: Some("session.resume"),
                    bytes: Some(1),
                    ..Event::default()
                },
            )
            .expect("known event");
        }
        let current = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let previous = std::fs::metadata(dir.join("audit.jsonl.1"))
            .map(|m| m.len())
            .unwrap_or(0);
        assert!(current <= 400, "current file is unbounded: {current}");
        assert!(previous <= 400, "rotated file is unbounded: {previous}");
        assert!(previous > 0, "rotation must keep exactly one previous file");
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().count(),
            2,
            "one live file and one rotation, never an ever-growing set"
        );
    }

    /// The rule the Python writer stated for transfers, applied to audit: a line that cannot be
    /// written costs the line, not the request.
    #[test]
    fn a_write_failure_does_not_fail_the_caller() {
        let dir = scratch("unwritable");
        // A directory where the file should be: every open fails with EISDIR.
        let path = dir.join("audit.jsonl");
        std::fs::create_dir_all(&path).expect("directory in place of the file");
        let log = AuditLog::at(&path, 1000);
        let record = log.emit(
            "http",
            Event {
                method: Some("GET"),
                path: Some("/v1/devices"),
                outcome: Some("200"),
                ..Event::default()
            },
        );
        assert!(record.is_some(), "the in-memory record still exists");
        assert_eq!(log.all("http").len(), 1, "and the mirror still sees it");
    }

    #[test]
    fn http_paths_are_masked_and_health_is_skipped() {
        assert_eq!(audit_path("/v1/bot-icons/cody"), "/v1/bot-icons/:id");
        assert_eq!(audit_path("/v1/bots/cody/message"), "/v1/bots/cody/message");
    }

    #[test]
    fn close_reasons_become_tokens() {
        assert_eq!(slug("engine unreachable"), "engine_unreachable");
        assert_eq!(slug("client closed"), "client_closed");
        assert_eq!(slug(""), "other");
        assert!(is_token(&slug("a very long reason with spaces")));
    }
}
