//! A bot's own documents: what it remembers (`memories/MEMORY.md` + `USER.md`) and the owner's note
//! (`NOTES.md`).
//!
//! Read straight off the engine's profile directory — these files *are* the agent's memory, so a copy
//! anywhere else would be a second truth. Guards that matter: the profile name must be a plain name
//! (no traversal), and a symlink is refused rather than followed (a link named MEMORY.md must not be
//! able to hand a device any host file).

use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// A profile name is a directory name: letters, digits, dash, underscore only.
fn profile_dir(st: &AppState, profile: &str) -> Result<PathBuf, Fail> {
    let ok = !profile.is_empty()
        && profile.len() <= 64
        && profile.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if !ok {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    Ok(st.engine_home.join("profiles").join(profile))
}

/// Read one document. `present` and `error` are distinct on purpose: "no file yet" is ordinary for a
/// new bot, "there is a file and I could not read it" is a fault the owner may need to fix.
fn document(path: &FsPath, name: &str, label: &str) -> Value {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => json!({
            "name": name, "label": label, "text": "", "chars": 0,
            "present": false, "error": "this is a symlink, not a memory file"
        }),
        Ok(_) => match std::fs::read_to_string(path) {
            Ok(text) => json!({
                "name": name, "label": label,
                "chars": text.chars().count(), "text": text, "present": !text.trim().is_empty()
            }),
            Err(e) => json!({
                "name": name, "label": label, "text": "", "chars": 0,
                "present": false, "error": format!("could not read it: {e}")
            }),
        },
        Err(_) => json!({
            "name": name, "label": label, "text": "", "chars": 0, "present": false
        }),
    }
}

/// `GET /v1/bots/{profile}/memory` — the two documents replayed into every turn.
pub async fn memory_get(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let dir = profile_dir(&st, &profile)?;
    let memories = dir.join("memories");
    Ok(Json(json!({
        "memory": document(&memories.join("MEMORY.md"), "MEMORY.md", "What it noted for itself"),
        "user": document(&memories.join("USER.md"), "USER.md", "What it knows about you"),
    })))
}

#[derive(Deserialize)]
pub struct NotesPut {
    #[serde(default)]
    pub text: String,
}

fn notes_document(profile: &str, path: &FsPath) -> Value {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => String::new(),
    };
    // ISO-8601, not epoch seconds: the app parses this string with a date formatter, so a number
    // decoded as nil and the note showed no "edited" time at all.
    let updated_at = std::fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| crate::backup::iso_at(d.as_secs()))
        .unwrap_or_else(crate::backup::now_iso);
    json!({
        "profile": profile,
        "notes": {
            "text": text,
            "chars": text.chars().count(),
            "present": !text.trim().is_empty(),
            "updated_at": updated_at,
        }
    })
}

/// `GET /v1/bots/{profile}/notes` — the owner's own note. Never injected into a turn.
pub async fn notes_get(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let dir = profile_dir(&st, &profile)?;
    Ok(Json(notes_document(&profile, &dir.join("NOTES.md"))))
}

/// `PUT /v1/bots/{profile}/notes` — whole document, last write wins.
pub async fn notes_put(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Json(body): Json<NotesPut>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let dir = profile_dir(&st, &profile)?;
    if !dir.is_dir() {
        return Err(bad(StatusCode::NOT_FOUND, "no such bot"));
    }
    let path = dir.join("NOTES.md");
    if std::fs::symlink_metadata(&path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err(bad(StatusCode::CONFLICT, "refusing to write through a symlink"));
    }
    // Write beside the target then rename: a half-written note is worse than the previous one.
    let tmp = dir.join(".NOTES.md.tmp");
    std::fs::write(&tmp, body.text.as_bytes())
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("could not write: {e}")))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, &path)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("could not save: {e}")))?;
    Ok(Json(notes_document(&profile, &path)))
}
