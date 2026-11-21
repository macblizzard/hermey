//! The shared session pointer, one per bot profile.
//!
//! The iPhone and the Mac each used to keep "which conversation is this bot" in their own local
//! store, so opening the same bot on both minted two conversations. This is the one place they can
//! agree: a small row in SQLite, read when a bot opens and written after `session.create`.
//!
//! ```text
//! GET /v1/bots/{profile}/session -> {"profile": …, "stored_session_id": null|<id>}
//! PUT /v1/bots/{profile}/session   {"stored_session_id": "<id>"} -> the same shape
//!   422  invalid profile, or a missing/invalid stored_session_id (the row is untouched)
//! ```
//!
//! Mirrors `bot_sessions.py` field for field. An unknown bot is not a 404 — "no conversation yet"
//! is a normal answer. There is no delete: an unusable value leaves the previous pointer in place.
//! Both routes take a single-use ws ticket as the bearer, exactly like `/v1/devices` and
//! `/v1/bot-icons`, and the audit line names only who/what — never the stored value.

use crate::routes::{require_device, AppState};
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// A profile name arrives in a route segment and is only ever a key here (no filesystem path is
/// built from it), but the shape is still refused hard: the bridge allows a dot, never a separator.
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

/// A stored session key is `%Y%m%d_%H%M%S_` + six hex (`tui_gateway/session_registry.py`). Accept
/// the general shape and refuse anything that could be read as a path: no slash, no backslash, no
/// dot. Same rule, same message, as the bridge's `_SESSION_ID`.
fn valid_session_id(value: &str) -> bool {
    let bytes = value.as_bytes();
    match bytes.first() {
        Some(first) if first.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    bytes.len() <= 128
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

/// One line in the service log, with the bridge's audit field names. The value is never included:
/// a session id is a capability for that conversation.
fn audit(device_id: &str, method: &str, profile: &str, outcome: &str, reason: Option<&str>) {
    let who: String = device_id.chars().take(8).collect();
    match reason {
        Some(reason) => eprintln!(
            "audit session_pointer device_id={who} method={method} path=/v1/bots/{profile}/session \
             profile={profile} outcome={outcome} reason={reason}"
        ),
        None => eprintln!(
            "audit session_pointer device_id={who} method={method} path=/v1/bots/{profile}/session \
             profile={profile} outcome={outcome}"
        ),
    }
}

/// `GET /v1/bots/{profile}/session` — the pointer, or JSON null when nothing is stored yet.
pub async fn get_session(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        audit(&device, "GET", &profile, "rejected", Some("invalid_profile"));
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    let stored = st.store.get_bot_session(&profile);
    audit(
        &device,
        "GET",
        &profile,
        if stored.is_some() { "found" } else { "missing" },
        None,
    );
    Ok(Json(json!({"profile": profile, "stored_session_id": stored})))
}

/// Strict body: anything else in it is malformed, not "close enough" (the bridge's
/// `extra='forbid'`). Parsed by hand rather than with `Json<T>` so an empty body is a 422 like every
/// other unusable body instead of the extractor's 400/415.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionPointer {
    stored_session_id: String,
}

/// `PUT /v1/bots/{profile}/session` — last write wins; never a delete.
pub async fn put_session(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    body: Bytes,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        audit(&device, "PUT", &profile, "rejected", Some("invalid_profile"));
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }
    let pointer: SessionPointer = serde_json::from_slice(&body).map_err(|_| {
        audit(&device, "PUT", &profile, "rejected", Some("invalid_body"));
        bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "expected {\"stored_session_id\": \"<id>\"} and nothing else",
        )
    })?;
    let value = pointer.stored_session_id;
    if !valid_session_id(&value) {
        // Never a delete: an unusable value leaves the previous pointer in place.
        audit(
            &device,
            "PUT",
            &profile,
            "rejected",
            Some("invalid_session_id"),
        );
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "stored_session_id must be 1-128 chars of [A-Za-z0-9_-]",
        ));
    }
    st.store.set_bot_session(&profile, &value);
    audit(&device, "PUT", &profile, "stored", None);
    Ok(Json(json!({"profile": profile, "stored_session_id": value})))
}
