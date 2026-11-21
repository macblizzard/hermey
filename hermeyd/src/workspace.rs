//! A bot's workspace — "Library" in the app: files it wrote (`workspace/`) and files the owner sent
//! (`attachments/`), read straight off the engine's profile directory.
//!
//! `GET /v1/workspace/{profile}`            → {profile, files:[{name,path,source,kind,size,modified,previewable}], truncated}
//! `GET /v1/workspace/{profile}/file?source=workspace|attachments&path=…` → the bytes
//!
//! Guards: both sides of a path are resolved and must stay inside the profile's own folder; symlinks
//! are skipped (a link named `notes.md` must not be able to hand out a host file).

use crate::routes::{require_device, AppState};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Component, Path as FsPath, PathBuf};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);
const MAX_FILES: usize = 400;

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

fn valid_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 64
        && profile.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn source_dir(st: &AppState, profile: &str, source: &str) -> Option<PathBuf> {
    let root = st.engine_home.join("profiles").join(profile);
    match source {
        "workspace" => Some(root.join("workspace")),
        "attachments" => Some(root.join("attachments")),
        _ => None,
    }
}

fn kind_of(path: &FsPath) -> String {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase())
        .filter(|e| !e.is_empty())
        .unwrap_or_else(|| "file".to_string())
}

/// Whether the app can draw these bytes directly.
fn previewable(kind: &str) -> bool {
    matches!(
        kind,
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" | "pdf" | "txt" | "md" | "csv"
            | "json" | "log" | "html" | "yaml" | "yml"
    )
}

/// Seconds since the epoch → `YYYY-MM-DDTHH:MM:SSZ` (civil-from-days, no chrono dependency).
fn iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mth = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mth <= 2 { y + 1 } else { y };
    format!("{y:04}-{mth:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

fn collect(root: &FsPath, source: &str, out: &mut Vec<Value>, cap: usize) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            if out.len() >= cap {
                return;
            }
            let path = entry.path();
            let meta = match std::fs::symlink_metadata(&path) {
                Ok(m) => m,
                Err(_) => continue,
            };
            if meta.file_type().is_symlink() {
                continue; // never follow: a link must not expose anything outside the folder
            }
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            if meta.is_dir() {
                stack.push(path);
                continue;
            }
            let rel = match path.strip_prefix(root) {
                Ok(r) => r.to_string_lossy().replace('\\', "/"),
                Err(_) => continue,
            };
            let kind = kind_of(&path);
            let modified = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| iso8601(d.as_secs()))
                .unwrap_or_else(|| iso8601(0));
            out.push(json!({
                "name": name,
                "path": rel,
                "source": source,
                "kind": kind,
                "size": meta.len(),
                "modified": modified,
                "previewable": previewable(&kind),
            }));
        }
    }
}

#[derive(Deserialize)]
pub struct ListQuery {
    pub limit: Option<usize>,
}

pub async fn list_workspace(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Query(q): Query<ListQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    let cap = q.limit.unwrap_or(MAX_FILES).clamp(1, MAX_FILES);
    let mut files = Vec::new();
    for source in ["workspace", "attachments"] {
        if let Some(dir) = source_dir(&st, &profile, source) {
            if dir.is_dir() {
                collect(&dir, source, &mut files, cap);
            }
        }
    }
    let truncated = files.len() >= cap;
    // Newest first: the sheet is a recent-files view, not a directory tree.
    files.sort_by(|a, b| {
        let key = |v: &Value| v.get("modified").and_then(|m| m.as_str()).unwrap_or("").to_string();
        key(b).cmp(&key(a))
    });
    Ok(Json(json!({"profile": profile, "files": files, "truncated": truncated})))
}

#[derive(Deserialize)]
pub struct FileQuery {
    /// Optional: the app opens a file by `path` alone and leaves the source to the host, so
    /// requiring it here 400'd the request before the handler was ever reached.
    #[serde(default)]
    pub source: Option<String>,
    pub path: String,
}

pub async fn workspace_file(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Query(q): Query<FileQuery>,
) -> Result<Response, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    // Resolve and confine: no `..`, no absolute paths, no symlinks at the leaf.
    let rel = FsPath::new(&q.path);
    if rel.is_absolute() || rel.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid path"));
    }
    // With no source named, the same relative path is looked for in `workspace` and then
    // `attachments` — the two directories the list route already draws from.
    let wanted: Vec<&str> = match q.source.as_deref().filter(|s| !s.is_empty()) {
        Some(source) => vec![source],
        None => vec!["workspace", "attachments"],
    };
    let mut target = None;
    for source in wanted {
        let root = source_dir(&st, &profile, source).ok_or_else(|| {
            bad(StatusCode::UNPROCESSABLE_ENTITY, "source must be workspace or attachments")
        })?;
        let candidate = root.join(rel);
        match std::fs::symlink_metadata(&candidate) {
            Ok(meta) if !meta.file_type().is_symlink() && meta.is_file() => {
                target = Some(candidate);
                break;
            }
            _ => {}
        }
    }
    let Some(target) = target else {
        return Err(bad(StatusCode::NOT_FOUND, "no such file"));
    };
    let bytes = std::fs::read(&target)
        .map_err(|_| bad(StatusCode::NOT_FOUND, "could not read that file"))?;

    let kind = kind_of(&target);
    let mime = match kind.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "txt" | "md" | "log" => "text/plain; charset=utf-8",
        "json" => "application/json",
        "csv" => "text/csv; charset=utf-8",
        "html" => "text/html; charset=utf-8",
        _ => "application/octet-stream",
    };
    let mut resp = Response::new(axum::body::Body::from(bytes));
    let h = resp.headers_mut();
    h.insert(axum::http::header::CONTENT_TYPE, mime.parse().unwrap());
    let name = target.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    h.insert(
        axum::http::header::CONTENT_DISPOSITION,
        format!("inline; filename=\"{}\"", name.replace('"', "")).parse().unwrap(),
    );
    Ok(resp)
}
