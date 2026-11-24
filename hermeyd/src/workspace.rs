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

/// The `Content-Type` a download of this kind gets. The office types are here because a bot writes
/// them and the app must be able to hand the bytes to something: `application/octet-stream` for a
/// `.xlsx` is a file no spreadsheet on earth will open by itself.
fn mime_of(kind: &str) -> &'static str {
    match kind {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "txt" | "md" | "log" => "text/plain; charset=utf-8",
        "json" => "application/json",
        "csv" => "text/csv; charset=utf-8",
        "html" => "text/html; charset=utf-8",
        _ => "application/octet-stream",
    }
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

/// Find one file inside a profile's `workspace/` or `attachments/`, or refuse.
///
/// Split out of the handler so the guards are testable without an HTTP request, because they are the
/// whole of the security here: a bot writes the link, and a bot writes the file.
///
/// A **relative, traversal-free** `path` is required, the leaf may not be a symlink, and — the case a
/// leaf check alone misses — a symlinked *directory* on the way in (`workspace/link/etc/passwd`
/// resolves to `/etc/passwd` while every component of the relative path looks innocent) is caught by
/// resolving both sides and requiring the file to still be inside its folder.
fn resolve_file(st: &AppState, profile: &str, q: &FileQuery) -> Result<PathBuf, Fail> {
    if !valid_profile(profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    let rel = FsPath::new(&q.path);
    if rel.is_absolute()
        || rel
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::Prefix(_) | Component::RootDir))
    {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid path"));
    }
    // With no source named, the same relative path is looked for in `workspace` and then
    // `attachments` — the two directories the list route already draws from.
    let wanted: Vec<&str> = match q.source.as_deref().filter(|s| !s.is_empty()) {
        Some(source) => vec![source],
        None => vec!["workspace", "attachments"],
    };
    for source in wanted {
        let root = source_dir(st, profile, source).ok_or_else(|| {
            bad(StatusCode::UNPROCESSABLE_ENTITY, "source must be workspace or attachments")
        })?;
        let candidate = root.join(rel);
        let Ok(meta) = std::fs::symlink_metadata(&candidate) else {
            continue;
        };
        if meta.file_type().is_symlink() || !meta.is_file() {
            continue;
        }
        let (Ok(resolved), Ok(real_root)) = (candidate.canonicalize(), root.canonicalize()) else {
            continue;
        };
        if !resolved.starts_with(&real_root) {
            continue;
        }
        return Ok(resolved);
    }
    Err(bad(StatusCode::NOT_FOUND, "no such file"))
}

pub async fn workspace_file(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Query(q): Query<FileQuery>,
) -> Result<Response, Fail> {
    require_device(&st, &headers)?;
    let target = resolve_file(&st, &profile, &q)?;
    let bytes = std::fs::read(&target)
        .map_err(|_| bad(StatusCode::NOT_FOUND, "could not read that file"))?;

    let kind = kind_of(&target);
    let mime = mime_of(&kind);
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

#[cfg(test)]
mod tests {
    use super::*;

    use crate::test_support::{scratch, state as test_state};

    fn query(path: &str, source: Option<&str>) -> FileQuery {
        FileQuery { source: source.map(str::to_string), path: path.to_string() }
    }

    /// The whole point of the route: a file a bot just wrote is fetchable by the app, at the path it
    /// linked to, with a content type the app can open.
    #[tokio::test]
    async fn a_file_a_bot_wrote_is_served_with_its_type() {
        let dir = scratch("serve");
        let st = test_state(&dir);
        let workspace = st.engine_home.join("profiles").join("cody").join("workspace");
        std::fs::create_dir_all(workspace.join("reports")).unwrap();
        std::fs::write(workspace.join("reports").join("q4.xlsx"), b"PK\x03\x04").unwrap();
        std::fs::write(workspace.join("notes.md"), b"# notes").unwrap();

        let found = resolve_file(&st, "cody", &query("reports/q4.xlsx", Some("workspace")))
            .expect("a file the bot wrote is inside the workspace");
        assert_eq!(found, workspace.join("reports").join("q4.xlsx"));
        assert_eq!(mime_of(&kind_of(&found)), mime_of("xlsx"));

        // With no source named, the same relative path is found in `workspace` first.
        assert!(resolve_file(&st, "cody", &query("notes.md", None)).is_ok());
        // And in `attachments` when that is where it is.
        let attachments = st.engine_home.join("profiles").join("cody").join("attachments");
        std::fs::create_dir_all(&attachments).unwrap();
        std::fs::write(attachments.join("sent.pdf"), b"%PDF-1.4").unwrap();
        let found = resolve_file(&st, "cody", &query("sent.pdf", Some("attachments"))).unwrap();
        assert_eq!(found, attachments.join("sent.pdf"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_office_types_come_back_with_the_right_content_type() {
        assert_eq!(
            mime_of("docx"),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        );
        assert_eq!(
            mime_of("xlsx"),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        );
        assert_eq!(mime_of("pdf"), "application/pdf");
        // Everything else is still the honest fallback.
        assert_eq!(mime_of("heic"), "application/octet-stream");
    }

    #[tokio::test]
    async fn a_path_outside_the_workspace_is_refused() {
        let dir = scratch("traversal");
        let st = test_state(&dir);
        let workspace = st.engine_home.join("profiles").join("cody").join("workspace");
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::write(dir.join("secret.txt"), b"not yours").unwrap();

        for path in ["../secret.txt", "a/../../secret.txt", "/etc/passwd", "reports/../../../etc/passwd"] {
            let error = resolve_file(&st, "cody", &query(path, Some("workspace"))).unwrap_err();
            assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY, "{path}");
            assert_eq!(error.1 .0["detail"], "invalid path", "{path}");
        }

        // A profile name is a folder name, never a path.
        let error = resolve_file(&st, "../cody", &query("notes.md", None)).unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);

        // An unknown source is refused rather than guessed at.
        let error = resolve_file(&st, "cody", &query("notes.md", Some("etc"))).unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(error.1 .0["detail"], "source must be workspace or attachments");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_symlink_cannot_carry_a_download_out_of_the_folder() {
        let dir = scratch("symlink");
        let st = test_state(&dir);
        let workspace = st.engine_home.join("profiles").join("cody").join("workspace");
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::write(dir.join("secret.txt"), b"not yours").unwrap();

        // A link at the leaf.
        #[cfg(unix)]
        std::os::unix::fs::symlink(dir.join("secret.txt"), workspace.join("shortcut.txt")).unwrap();
        // A link on the way in: every component of `link/secret.txt` looks innocent.
        #[cfg(unix)]
        std::os::unix::fs::symlink(&dir, workspace.join("link")).unwrap();

        for path in ["shortcut.txt", "link/secret.txt"] {
            if path == "shortcut.txt" && !workspace.join("shortcut.txt").exists() {
                continue;
            }
            let error = resolve_file(&st, "cody", &query(path, Some("workspace"))).unwrap_err();
            assert_eq!(error.0, StatusCode::NOT_FOUND, "{path}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_missing_file_is_a_404_not_an_empty_answer() {
        let dir = scratch("missing");
        let st = test_state(&dir);
        let error = resolve_file(&st, "cody", &query("nothing.xlsx", Some("workspace"))).unwrap_err();
        assert_eq!(error.0, StatusCode::NOT_FOUND);
        assert_eq!(error.1 .0["detail"], "no such file");

        // A directory is not a file, however neatly it is named.
        std::fs::create_dir_all(
            st.engine_home.join("profiles").join("cody").join("workspace").join("folder"),
        )
        .unwrap();
        let error = resolve_file(&st, "cody", &query("folder", Some("workspace"))).unwrap_err();
        assert_eq!(error.0, StatusCode::NOT_FOUND);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
