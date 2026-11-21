//! Bot lifecycle, one route: `POST /v1/bots/{profile}/purge`.
//!
//! Mirrors `bot_admin.py::purge_bot` field for field. Deleting a bot is irreversible by design, so
//! the bridge archives the profile's bytes FIRST and refuses the delete when the archive fails —
//! an archive that silently failed is indistinguishable from no archive. Everything here follows
//! that order:
//!
//! ```text
//! POST /v1/bots/{profile}/purge -> {"profile": …, "deleted": true, "archive": "<path>"}
//!   403  this bot cannot be deleted          ("default" is the install's own profile)
//!   422  invalid profile name                (not a directory name)
//!   404  no such bot
//!   500  archive failed / profile remains    (refuse rather than delete what we could not copy)
//! ```
//!
//! One deliberate difference from the bridge: there is no dashboard to ask here, because hermeyd
//! owns the profile directories itself (the same way `backup.rs` writes into them), so the delete
//! is `remove_dir_all` and the "did it really go" check is the same as the bridge's.

use crate::auth::random_token;
use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// The install's own home. Removing it would leave the host without the profile the engine serves.
const PROTECTED: [&str; 1] = ["default"];

/// How many deleted-bot archives to keep. They are mistake-catchers, not a backup service; without
/// a cap every delete leaves another tarball on the state disk forever.
const ARCHIVE_KEEP: usize = 20;

/// A profile name is a directory name and an alias; the engine enforces the same shape.
fn valid_profile(name: &str) -> bool {
    let bytes = name.as_bytes();
    let Some(first) = bytes.first() else { return false };
    if bytes.len() > 64 {
        return false;
    }
    if !(first.is_ascii_lowercase() || first.is_ascii_digit()) {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-' || *b == b'_')
}

/// `%Y%m%d-%H%M%S`, UTC: the stamp that keeps two archives of the same bot apart within a second.
/// The bridge stamps in local time; the only thing that reads this name back is a human un-tarring
/// a mistake, so UTC (what every other timestamp in this service uses) is fine.
fn stamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let d = doy - (153 * mp + 2) / 5 + 1;
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    format!("{y:04}{m:02}{d:02}-{hh:02}{mm:02}{ss:02}")
}

/// Keep the newest `ARCHIVE_KEEP` deleted-bot archives; the rest are stale copies.
fn prune_archives(archive_dir: &std::path::Path) {
    let mut archives: Vec<_> = std::fs::read_dir(archive_dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.is_file()
                        && p.extension().and_then(|e| e.to_str()) == Some("gz")
                        && p.to_string_lossy().ends_with(".tar.gz")
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    archives.sort_by_key(|path| {
        std::fs::metadata(path)
            .and_then(|m| m.modified())
            .ok()
            .map(|t| t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0))
            .unwrap_or(0)
    });
    archives.reverse(); // newest first
    for stale in archives.into_iter().skip(ARCHIVE_KEEP) {
        let _ = std::fs::remove_file(stale);
    }
}

pub async fn purge(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
) -> Result<Json<Value>, Fail> {
    let _caller = require_device(&st, &headers)?;
    if PROTECTED.contains(&profile.as_str()) {
        return Err(bad(StatusCode::FORBIDDEN, "this bot cannot be deleted"));
    }
    if !valid_profile(&profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile name"));
    }

    let root = st.engine_home.join("profiles");
    let directory = root.join(&profile);
    // A symlink named like a bot must not become the thing we tar up and rmtree: it is refused
    // rather than followed, the same rule the backup routes apply to every profile file.
    let meta = std::fs::symlink_metadata(&directory)
        .map_err(|_| bad(StatusCode::NOT_FOUND, "no such bot"))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(bad(StatusCode::NOT_FOUND, "no such bot"));
    }

    // The archive is a mistake-catcher, so it has to succeed before the point of no return.
    // Beside this service's own state — the same place the bridge keeps its deleted-bots.
    let archive_dir = st
        .attachments_dir
        .parent()
        .map(|parent| parent.join("deleted-bots"))
        .unwrap_or_else(|| st.attachments_dir.clone());
    std::fs::create_dir_all(&archive_dir)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("archive failed: {e}")))?;

    let final_name = format!("{profile}-{}.tar.gz", stamp());
    let tmp = archive_dir.join(format!(".{}.{}.tmp", random_token(6), final_name));
    let output = std::process::Command::new("tar")
        .arg("-czf")
        .arg(&tmp)
        .arg("-C")
        .arg(&root)
        .arg(&profile)
        .output()
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("archive failed: {e}")))?;
    if !output.status.success() {
        let _ = std::fs::remove_file(&tmp);
        let stderr = String::from_utf8_lossy(&output.stderr);
        // The last line of tar's complaint is the diagnosis; cap it so a runaway cannot flood the log.
        let reason = stderr
            .trim()
            .lines()
            .last()
            .unwrap_or("")
            .chars()
            .take(160)
            .collect::<String>();
        return Err(bad(StatusCode::INTERNAL_SERVER_ERROR, format!("archive failed: {reason}")));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    let archive = archive_dir.join(&final_name);
    std::fs::rename(&tmp, &archive)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("archive failed: {e}")))?;
    prune_archives(&archive_dir);

    // The delete itself. Refuse rather than delete what we could not verify is gone.
    std::fs::remove_dir_all(&directory)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("archive failed: {e}")))?;
    if directory.exists() {
        return Err(bad(
            StatusCode::INTERNAL_SERVER_ERROR,
            "the host reported success but the profile remains",
        ));
    }

    // A deleted bot must not keep a disabled marker that a later bot with the same name inherits.
    crate::bridge_routes::forget_disabled(&st, &profile);

    Ok(Json(json!({
        "profile": profile,
        "deleted": true,
        "archive": archive.to_string_lossy(),
    })))
}
