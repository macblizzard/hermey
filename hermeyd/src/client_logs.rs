//! The client log, written where an operator can read it: `POST /v1/client-logs`.
//!
//! ```text
//! POST /v1/client-logs        (device bearer)
//!   {device, appVersion, appBuild, osVersion, scope, level?, category?, search?, capturedAt, text}
//!   -> 201 {path, bytes, device}
//!   -> 400 {detail}   the body was not a log upload, or carried no lines
//!   -> 401 {detail}   missing/expired/already-used bearer (`require_device`)
//!   -> 409 {detail}   a log from this device for this minute is already on disk; nothing was truncated
//!   -> 413 {detail}   the text is over 2 MiB
//! ```
//!
//! The owner's request: *"wouldn't it better if u save the log on server side as well so that i wont
//! have to paste the whole log for u to investigate?"* Pasting a log into a chat means it arrives
//! reformatted, truncated by the messenger, and gone from this host's disk; a file does not.
//!
//! **What is written, and what is not.** The app's `text` is written verbatim — it is the same string
//! its Copy action would put on the clipboard — under a short `#` header naming the device, the app
//! build, the OS, when the log was captured, and which filters were on. Nothing else is stored, and
//! there is no field for a credential: the client log has never carried a card or secret value, and
//! this route adds no content to it. The header is metadata the app already displays in its own sheet.
//!
//! **One file per device per minute, never overwritten.** `/var/log/hermey/client-<device>-<stamp>.log`
//! is opened with `create_new`, so a second upload inside the same minute answers 409 rather than
//! truncating the first — a log someone is reading must not change under them. 0640 root:root, the
//! same privacy as the rest of `/var/log/hermey`: readable by an operator on this host, by nobody else.
//!
//! **Not on the relay.** This is an ordinary bearer POST — the app posts it over `URLSession`, not the
//! WS socket — so a conversation streaming a large transcript cannot delay the upload, and the upload
//! cannot hold a relay slot. The two ceilings (this module's `MAX_LOG_BYTES` and the framework body
//! limit in `main.rs`) exist because the phone refuses a log over 2 MiB before sending it; a client
//! that does not is refused here with a sentence rather than a truncated file.

use crate::routes::{require_device, AppState};
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

/// The ceiling both ends apply to the log text: 2 MiB. The app checks it before a byte leaves the
/// device; this is the same number, because a ceiling only one side enforces is not a ceiling.
pub const MAX_LOG_BYTES: usize = 2 * 1024 * 1024;

/// The framework's own body ceiling, well above [`MAX_LOG_BYTES`]: a JSON envelope escapes newlines
/// and quotes, so 2 MiB of log is more than 2 MiB on the wire. Setting it higher is what lets the
/// 413 a client sees be this module's sentence ("over 2 MiB") instead of an empty rejection from the
/// body extractor.
pub const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;

/// Where logs land. Overridable so a scratch host, a test or a non-standard install can move it
/// without moving the code; production is the service's own convention, `/var/log/hermey`.
const DEFAULT_LOG_DIR: &str = "/var/log/hermey";

/// The file mode: root writes it, root's group may read it, nothing else can.
const FILE_MODE: u32 = 0o640;
/// The directory mode, applied when this server creates `/var/log/hermey` for the first time.
const DIR_MODE: u32 = 0o750;

/// A device name is a filename fragment: this many characters of it is plenty to tell two devices
/// apart, and short enough to leave the timestamp readable in a `ls`.
const MAX_SLUG: usize = 40;

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({ "detail": msg.into() })))
}

/// The upload as the app sends it (`ClientLogUploadPayload` in `Sources/HermesKit/ClientLogUpload.swift`).
///
/// Every field is optional on the wire: a missing header field makes a thinner `#` block, never a
/// failed upload. The one field that is required in practice is `text`, and an empty one is refused —
/// a file containing only a header tells whoever reads it nothing.
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Upload {
    device: String,
    app_version: String,
    app_build: String,
    os_version: String,
    scope: String,
    level: Option<String>,
    category: Option<String>,
    search: Option<String>,
    captured_at: f64,
    text: String,
}

/// `POST /v1/client-logs` — the one way a log gets onto this host.
pub async fn post_log(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<(StatusCode, Json<Value>), Fail> {
    // The same device credential every app route takes: a fresh single-use ticket (or a reusable
    // access token), so an upload is attributable to a paired device and nothing else can post one.
    let device = require_device(&st, &headers)?;

    let upload: Upload = serde_json::from_slice(&body)
        .map_err(|_| bad(StatusCode::BAD_REQUEST, "the body was not a client-log upload"))?;
    if upload.text.trim().is_empty() {
        return Err(bad(StatusCode::BAD_REQUEST, "the upload carries no log lines"));
    }
    // Over the ceiling: refused in this module's own words, and nothing is created on disk. A
    // truncated log is worse than a refused one — it reads as complete.
    if upload.text.len() > MAX_LOG_BYTES {
        return Err(bad(StatusCode::PAYLOAD_TOO_LARGE, too_large(&upload.text)));
    }

    let now = now_secs();
    let dir = log_dir();
    let head = header_block(&upload, &device, now);
    let path = write_log(&dir, &slug(&upload.device), &utc_stamp(now), &head, &upload.text)?;
    let bytes = head.len() + upload.text.len();

    Ok((
        StatusCode::CREATED,
        Json(json!({
            "path": path.display().to_string(),
            "bytes": bytes,
            "device": upload.device,
        })),
    ))
}

/// The 413's sentence. One number, spelled once: the same 2 MiB the phone refuses to exceed.
fn too_large(text: &str) -> String {
    format!(
        "this log is {} bytes, over the {} a host will store; copy a portion of it instead",
        text.len(),
        MAX_LOG_BYTES
    )
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn log_dir() -> PathBuf {
    std::env::var_os("HERMEYD_LOG_DIR")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| PathBuf::from(DEFAULT_LOG_DIR))
}

/// The `#` block above the log. Every line is a fact the app also shows in its own sheet, so a file
/// found on this host explains itself without the phone beside it.
///
/// `device` here is the authenticated device's id, not the name it typed: the name is cosmetic and
/// the id is what `GET /v1/devices` lists.
fn header_block(upload: &Upload, device_id: &str, saved_at: u64) -> String {
    let mut out = String::from("# hermey client log\n");
    out.push_str(&format!("# device: {}\n", one_line(&upload.device, "unnamed")));
    out.push_str(&format!("# device-id: {}\n", one_line(device_id, "unknown")));
    out.push_str(&format!(
        "# app: Hermey {} (build {})\n",
        one_line(&upload.app_version, "?"),
        one_line(&upload.app_build, "?")
    ));
    out.push_str(&format!("# os: {}\n", one_line(&upload.os_version, "?")));
    out.push_str(&format!(
        "# captured: {} (device clock)\n",
        if upload.captured_at > 0.0 {
            iso8601(upload.captured_at as u64)
        } else {
            "unknown".to_string()
        }
    ));
    out.push_str(&format!("# saved: {}\n", iso8601(saved_at)));
    out.push_str(&format!("# copy: {}\n", one_line(&upload.scope, "all")));
    out.push_str(&format!("# filters: {}\n", filter_summary(upload)));
    out.push_str(&format!("# lines: {}\n", upload.text.lines().count()));
    out.push('\n');
    out
}

fn filter_summary(upload: &Upload) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(level) = upload.level.as_deref().filter(|v| !v.is_empty()) {
        parts.push(format!("level={}", one_line(level, "")));
    }
    if let Some(category) = upload.category.as_deref().filter(|v| !v.is_empty()) {
        parts.push(format!("category={}", one_line(category, "")));
    }
    if let Some(search) = upload.search.as_deref().filter(|v| !v.is_empty()) {
        parts.push(format!("search={:?}", one_line(search, "")));
    }
    if parts.is_empty() {
        "none".to_string()
    } else {
        parts.join(" ")
    }
}

/// A header value is one line: a device called `Mo\nhost: evil` must not be able to forge a header.
/// Newlines and control characters become spaces, and an empty value gets the given fallback.
fn one_line(value: &str, fallback: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.chars().take(120).collect()
    }
}

/// A device name as a filename fragment: lowercase ASCII letters, digits and single dashes.
///
/// Everything else collapses to `-`, because the name comes from the device and may be Arabic, an
/// emoji or a path. An empty result becomes `device` so the file always carries a device.
fn slug(name: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in name.chars() {
        if out.len() >= MAX_SLUG {
            break;
        }
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash && !out.is_empty() {
            out.push('-');
            last_dash = true;
        }
    }
    let trimmed = out.trim_end_matches('-');
    if trimmed.is_empty() {
        "device".to_string()
    } else {
        trimmed.to_string()
    }
}

/// The filename's stamp: `20261125T2130Z`. Minute resolution, as the owner asked, and UTC so two
/// readers in two timezones agree about which file is newer.
fn utc_stamp(secs: u64) -> String {
    let (y, m, d) = civil_date((secs / 86_400) as i64);
    let rem = secs % 86_400;
    format!("{y:04}{m:02}{d:02}T{:02}{:02}Z", rem / 3600, (rem % 3600) / 60)
}

/// `YYYY-MM-DDTHH:MM:SSZ`, the header's own reading of the same clock.
fn iso8601(secs: u64) -> String {
    let (y, m, d) = civil_date((secs / 86_400) as i64);
    let rem = secs % 86_400;
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Days since the epoch → a civil date. Howard Hinnant's `civil_from_days`, which is four lines of
/// arithmetic and no dependency (`chrono` would be one more crate for one filename).
fn civil_date(days: i64) -> (i64, u64, u64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Create the directory 0750 if it is missing, then write one file into it that cannot already exist.
///
/// `create_new` is the whole of "never overwrite": the open fails with `AlreadyExists` rather than
/// truncating, so a second upload in the same minute answers 409 and the first file is untouched.
/// The mode is set at creation and again immediately after, because `OpenOptions::mode` is masked by
/// the process umask — a 0640 request through a 0027 umask would otherwise land 0640 only by luck.
fn write_log(dir: &Path, device: &str, stamp: &str, head: &str, text: &str) -> Result<PathBuf, Fail> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(DIR_MODE)
        .create(dir)
        .map_err(|e| {
            bad(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("cannot create {}: {e}", dir.display()),
            )
        })?;

    let path = dir.join(format!("client-{device}-{stamp}.log"));
    let mut file = match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(FILE_MODE)
        .open(&path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(bad(
                StatusCode::CONFLICT,
                format!(
                    "{} already exists — a log from this device for that minute is on the host and \
                     nothing was overwritten; send again in a minute for a second file",
                    path.display()
                ),
            ));
        }
        Err(e) => {
            return Err(bad(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("cannot create {}: {e}", path.display()),
            ));
        }
    };
    // Before the content: a file that is briefly 0600 is fine, one that is briefly 0644 is not.
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(FILE_MODE));

    let written = file
        .write_all(head.as_bytes())
        .and_then(|_| file.write_all(text.as_bytes()))
        .and_then(|_| file.flush());
    if let Err(e) = written {
        // A half-written log is not a log: remove it rather than leave a file that reads complete.
        drop(file);
        let _ = std::fs::remove_file(&path);
        return Err(bad(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("cannot write {}: {e}", path.display()),
        ));
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn scratch(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-clientlogs-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn upload() -> Upload {
        Upload {
            device: "Mo’s iPhone".to_string(),
            app_version: "0.1.662".to_string(),
            app_build: "662".to_string(),
            os_version: "iOS 18.2".to_string(),
            scope: "all".to_string(),
            level: Some("Errors".to_string()),
            category: Some("bridge".to_string()),
            search: Some("timeout".to_string()),
            captured_at: 1_764_000_000.0,
            text: "21:30:01  E  bridge  session.resume failed: timeout\n".to_string(),
        }
    }

    #[test]
    fn the_filename_carries_the_device_and_a_utc_minute() {
        let stamp = utc_stamp(1_764_123_456);
        assert_eq!(stamp, "20251126T0217Z");
        assert_eq!(slug("Mo’s iPhone"), "mo-s-iphone");
        assert_eq!(slug("../../etc/passwd"), "etc-passwd");
        assert_eq!(slug(""), "device");
        assert_eq!(slug("☃"), "device");
        assert!(slug(&"a".repeat(200)).len() <= MAX_SLUG);
    }

    #[test]
    fn the_header_names_the_device_the_build_and_the_filters() {
        let head = header_block(&upload(), "dev-42", 1_764_123_456);
        assert!(head.starts_with("# hermey client log\n"));
        assert!(head.contains("# device: Mo’s iPhone"));
        assert!(head.contains("# device-id: dev-42"));
        assert!(head.contains("# app: Hermey 0.1.662 (build 662)"));
        assert!(head.contains("# os: iOS 18.2"));
        assert!(head.contains("# captured: 2025-11-24T16:00:00Z"));
        assert!(head.contains("# saved: 2025-11-26T02:17:36Z"));
        assert!(head.contains("# filters: level=Errors category=bridge search=\"timeout\""));
        assert!(head.ends_with("\n\n"), "the log must start on its own line");
    }

    #[test]
    fn a_header_cannot_be_forged_by_a_device_name() {
        let mut poisoned = upload();
        poisoned.device = "phone\n# device-id: root".to_string();
        let head = header_block(&poisoned, "dev-42", 1_764_123_456);
        // Every line but the log's own is a `#` line, and the newline in the name became a space.
        assert!(!head.contains("\n# device-id: root"));
        assert!(head.contains("# device: phone # device-id: root"));
    }

    #[test]
    fn the_file_is_private_and_the_log_inside_is_verbatim() {
        let dir = scratch("write");
        let text = "21:30:01  E  bridge  session.resume failed: timeout\n";
        let head = header_block(&upload(), "dev-42", 1_764_123_456);

        let path = write_log(&dir, "mo-s-iphone", "20261125T2130Z", &head, text).expect("written");
        assert_eq!(
            path.file_name().unwrap().to_string_lossy(),
            "client-mo-s-iphone-20261125T2130Z.log"
        );
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o640, "the log is root's to read, and root's group's");
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.ends_with(text), "the app's bytes are not rewritten");
        assert_eq!(body.matches(text).count(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_second_upload_for_the_same_minute_is_refused_not_truncated() {
        let dir = scratch("collide");
        let head = header_block(&upload(), "dev-42", 1_764_123_456);
        let first = write_log(&dir, "iphone", "20261125T2130Z", &head, "first\n").expect("first");
        let before = std::fs::read_to_string(&first).unwrap();

        let second = write_log(&dir, "iphone", "20261125T2130Z", &head, "second\n");
        match second {
            Err((status, body)) => {
                assert_eq!(status, StatusCode::CONFLICT);
                let detail = body.0["detail"].as_str().unwrap_or_default();
                assert!(detail.contains("already exists"), "the refusal says why: {detail}");
                assert!(detail.contains("nothing was overwritten"));
            }
            Ok(path) => panic!("a collision must not write: {}", path.display()),
        }
        assert_eq!(std::fs::read_to_string(&first).unwrap(), before, "the first file is untouched");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_ceiling_is_two_mebibytes_and_says_so() {
        assert_eq!(MAX_LOG_BYTES, 2 * 1024 * 1024);
        assert!(MAX_BODY_BYTES > MAX_LOG_BYTES, "the framework limit must sit above the handler's");
        let sentence = too_large(&"x".repeat(MAX_LOG_BYTES + 1));
        assert!(sentence.contains("over the 2097152"));
        assert!(sentence.contains("copy a portion"));
    }
}
