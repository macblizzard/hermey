//! Parity routes: the last four things the apps ask for that this service did not answer yet.
//!
//! Each one mirrors a route the production bridge serves, field for field, because the clients were
//! written against that bridge and a 404 here is a screen that never finishes loading:
//!
//! ```text
//! GET  /v1/attachments/{profile}/{name}  -> the bytes of an image a transcript refers to
//! GET  /v1/backup.zip                    -> the /v1/backup document + each bot's icon, zipped
//! GET  /v1/backup/import-prompt          -> {version, prompt}: the schema, and the text that explains it
//! PUT  /v1/push/icon/{bot}               -> store the face a notification banner carries
//! GET  /v1/push/icon/{bot}.png           -> serve that face
//! ```
//!
//! The two integrations routes that belong to the Composio concern live in `integrations.rs` beside
//! the client they use; everything here is only about files this host owns.
//!
//! House rules, all of them borrowed from the neighbouring modules on purpose:
//!   * device auth through `require_device` — an image is not public because its name is random.
//!     Devices pair **host-wide**, not per profile, so any paired device may read any profile's
//!     `images/`/`attachments/` here (including the host-level `engine_home` candidates): the apps
//!     show several profiles on one device. The rule is written out, and pinned, in
//!     `attachment_refs.rs`'s module header;
//!   * one path component, never a traversal, and a symlink is refused rather than followed;
//!   * bytes are written beside the target, chmod 0600, then renamed, so a reader never sees half a
//!     file;
//!   * errors are `{"detail": "..."}` with the status the client expects.

use crate::auth::{random_token, sha256_hex};
use crate::routes::{require_device, AppState};
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

fn body_of(bytes: Vec<u8>, media_type: &'static str, extra: &[(&str, String)]) -> Response {
    let mut resp = Response::new(axum::body::Body::from(bytes));
    let h = resp.headers_mut();
    h.insert(header::CONTENT_TYPE, media_type.parse().unwrap());
    for (name, value) in extra {
        if let Ok(parsed) = value.parse() {
            // `name` is one of our own literals, never client input.
            h.insert(axum::http::HeaderName::from_bytes(name.as_bytes()).unwrap(), parsed);
        }
    }
    resp
}

// ---------------------------------------------------------------------------------------------
// GET /v1/attachments/{profile}/{name}
// ---------------------------------------------------------------------------------------------

/// The same ceiling the production bridge applies: a chat bubble, not a file store.
const MAX_ATTACHMENT_FILE_BYTES: u64 = 8 * 1024 * 1024;

/// Only what a chat bubble can draw. Anything else stays a file chip on the client.
fn image_media_type(name: &str) -> Option<&'static str> {
    let (_, extension) = name.rsplit_once('.')?;
    match extension.to_ascii_lowercase().as_str() {
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "heic" => Some("image/heic"),
        "heif" => Some("image/heif"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        "tiff" => Some("image/tiff"),
        "bmp" => Some("image/bmp"),
        _ => None,
    }
}

/// The three document types a bubble cannot draw but the app opens on press. They are served from
/// the profile's `attachments/` — where `file.attach` stages them — rather than `images/`, so the
/// image route above keeps looking in exactly the two places it always has.
fn office_media_type(name: &str) -> Option<&'static str> {
    let (_, extension) = name.rsplit_once('.')?;
    match extension.to_ascii_lowercase().as_str() {
        "pdf" => Some("application/pdf"),
        "docx" => Some("application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        "xlsx" => Some("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        _ => None,
    }
}

/// One path component, or `None`: no separators, no traversal, nothing hidden.
///
/// `Path` decoding happens before this runs, so `%2e%2e%2f` arrives here as `../` and is refused
/// like any other traversal rather than being reassembled into a path.
fn single_component(value: &str) -> Option<&str> {
    if value.is_empty() || value.len() > 255 {
        return None;
    }
    if value.chars().any(|c| matches!(c, '/' | '\\' | '\0' | '\n' | '\r')) {
        return None;
    }
    if value == "." || value == ".." || value.starts_with('.') {
        return None;
    }
    Some(value)
}

/// `GET /v1/attachments/{profile}/{name}` — give a paired device back a picture it once sent.
///
/// The transcript only carries the name (`@image:/…/upload_ab12.png`), which is useless to a device
/// that reinstalled or never had the bytes. A missing file is a 404, never an empty 200, so the
/// client can fall back to a named chip and invent nothing.
pub async fn attachment_file(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((profile, name)): Path<(String, String)>,
) -> Result<Response, Fail> {
    require_device(&st, &headers)?;

    let Some(profile) = single_component(&profile) else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid attachment path"));
    };
    let Some(name) = single_component(&name) else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid attachment path"));
    };

    let profiles_root = st.engine_home.join("profiles");
    // Two kinds, two folders, and the split is the extension's: a picture lives where the image
    // queue puts it (`images/`), a document where `file.attach` stages it (`attachments/`). The
    // image branch keeps the exact candidates, roots and errors it has always had — only the
    // office types gained a way in.
    let (media_type, candidates): (&'static str, [PathBuf; 2]) = if let Some(media) =
        image_media_type(name)
    {
        (
            media,
            [
                profiles_root.join(profile).join("images").join(name),
                st.engine_home.join("images").join(name),
            ],
        )
    } else if let Some(media) = office_media_type(name) {
        (
            media,
            [
                profiles_root.join(profile).join("attachments").join(name),
                st.engine_home.join("attachments").join(name),
            ],
        )
    } else {
        return Err(bad(StatusCode::BAD_REQUEST, "not an image attachment"));
    };
    let roots = [profiles_root, st.engine_home.clone()];

    for candidate in candidates {
        let Ok(meta) = std::fs::symlink_metadata(&candidate) else { continue };
        // The name check stops `../`; a symlink inside the folder named `x.png` would still follow
        // straight out of it, so it is refused rather than followed.
        if meta.file_type().is_symlink() || !meta.is_file() {
            continue;
        }
        let Ok(resolved) = candidate.canonicalize() else { continue };
        let inside = roots.iter().any(|base| {
            base.canonicalize().map(|base| resolved.starts_with(&base)).unwrap_or(false)
        });
        if !inside {
            continue;
        }
        if meta.len() > MAX_ATTACHMENT_FILE_BYTES {
            return Err(bad(StatusCode::PAYLOAD_TOO_LARGE, "attachment too large"));
        }
        let Ok(bytes) = std::fs::read(&resolved) else { continue };
        return Ok(body_of(
            bytes,
            media_type,
            &[("cache-control", "private, max-age=86400".to_string())],
        ));
    }
    Err(bad(StatusCode::NOT_FOUND, "attachment not found"))
}

// ---------------------------------------------------------------------------------------------
// GET /v1/backup.zip
// ---------------------------------------------------------------------------------------------

/// Mirrors `BACKUP_VERSION` in `bot_backup.py`. The document's own `version` is a different number
/// (it versions the JSON shape this service exports); this one versions the import format.
pub const BACKUP_VERSION: i64 = 2;

/// The prompt a person pastes into another product's bot so it writes a file this host can read.
///
/// Compiled in verbatim from the production constant (`include_str!`) rather than retyped: the text
/// and the schema change together, and `__VERSION__` is substituted at serve time exactly as the
/// bridge does. A copy in the source that drifted from the format would be worse than no prompt.
const IMPORT_PROMPT_TEMPLATE: &str = include_str!("import_prompt.txt");

/// Where this host keeps one icon per bot. Beside the attachments, under HERMEY_HOME, which is what
/// the service may actually write — the production bridge's `/var/lib/hermey/push-icons` is the same
/// place under its own home.
pub(crate) fn icon_dir(st: &AppState) -> PathBuf {
    st.attachments_dir
        .parent()
        .map(|parent| parent.join("push-icons"))
        .unwrap_or_else(|| st.attachments_dir.clone())
}

fn read_icon(st: &AppState, profile: &str) -> Option<Vec<u8>> {
    let path = icon_dir(st).join(format!("{profile}.png"));
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        return None;
    }
    std::fs::read(&path).ok()
}

/// `GET /v1/backup.zip` — the same document `/v1/backup` builds, with each bot's icon inside it.
///
/// A single JSON cannot carry a picture and an icon is part of what a bot looks like, so the archive
/// holds `backup.json` plus `icons/<profile>.png` — exactly the layout the import prompt describes.
/// Entries are **stored** (no deflate): a JSON document of a few hundred kilobytes does not need a
/// compressor, and stored entries keep this service free of a zip crate while staying a valid
/// archive (`unzip -t` and Python's `zipfile` both verify the CRC32 written here).
pub async fn backup_zip(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, Fail> {
    require_device(&st, &headers)?;

    let mut document = crate::backup::document(&st).await;
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();

    if let Some(bots) = document.get_mut("bots").and_then(|bots| bots.as_array_mut()) {
        for bot in bots.iter_mut() {
            let Some(profile) = bot.get("profile").and_then(|p| p.as_str()).map(str::to_string) else {
                continue;
            };
            let Some(bytes) = read_icon(&st, &profile) else { continue };
            // The key is what ties the picture to the bot in the archive; without it the importer
            // would see an untethered file. Absent icon ⇒ no key, same as the bridge's `icon: null`.
            bot["icon"] = json!(format!("icons/{profile}.png"));
            entries.push((format!("icons/{profile}.png"), bytes));
        }
    }

    let document_bytes = serde_json::to_vec_pretty(&document)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("cannot render the backup: {e}")))?;
    entries.insert(0, ("backup.json".to_string(), document_bytes));

    let archive = build_zip(&entries);
    Ok(body_of(
        archive,
        "application/zip",
        &[("content-disposition", "attachment; filename=\"hermey-bots.zip\"".to_string())],
    ))
}

/// `GET /v1/backup/import-prompt` — the text, and the version it describes.
pub async fn import_prompt(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let version = BACKUP_VERSION.to_string();
    Ok(Json(json!({
        "version": BACKUP_VERSION,
        "prompt": IMPORT_PROMPT_TEMPLATE.replace("__VERSION__", &version),
    })))
}

/// A stored-entry ZIP: local headers, the central directory, the end record. Sizes and CRCs are the
/// real ones, so `unzip -t` and Python's `zipfile.testzip()` both accept it.
fn build_zip(entries: &[(String, Vec<u8>)]) -> Vec<u8> {
    let (time, date) = dos_stamp();
    let mut out: Vec<u8> = Vec::new();
    let mut central: Vec<u8> = Vec::new();

    for (name, data) in entries {
        let offset = out.len() as u32;
        let crc = crc32(data);
        let name_bytes = name.as_bytes();
        let size = data.len() as u32;

        // Local file header.
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&0x0800u16.to_le_bytes()); // names are UTF-8
        out.extend_from_slice(&0u16.to_le_bytes()); // method 0 = stored
        out.extend_from_slice(&time.to_le_bytes());
        out.extend_from_slice(&date.to_le_bytes());
        out.extend_from_slice(&crc.to_le_bytes());
        out.extend_from_slice(&size.to_le_bytes());
        out.extend_from_slice(&size.to_le_bytes());
        out.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // no extra field
        out.extend_from_slice(name_bytes);
        out.extend_from_slice(data);

        // The matching central-directory record.
        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes()); // version made by
        central.extend_from_slice(&20u16.to_le_bytes()); // version needed
        central.extend_from_slice(&0x0800u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&time.to_le_bytes());
        central.extend_from_slice(&date.to_le_bytes());
        central.extend_from_slice(&crc.to_le_bytes());
        central.extend_from_slice(&size.to_le_bytes());
        central.extend_from_slice(&size.to_le_bytes());
        central.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes()); // extra
        central.extend_from_slice(&0u16.to_le_bytes()); // comment
        central.extend_from_slice(&0u16.to_le_bytes()); // disk number
        central.extend_from_slice(&0u16.to_le_bytes()); // internal attributes
        central.extend_from_slice(&(0o644u32 << 16).to_le_bytes()); // unix mode in the high bits
        central.extend_from_slice(&offset.to_le_bytes());
        central.extend_from_slice(name_bytes);
    }

    let central_offset = out.len() as u32;
    let central_size = central.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // this disk
    out.extend_from_slice(&0u16.to_le_bytes()); // disk with the central directory
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_offset.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // no archive comment
    out
}

/// CRC-32 (IEEE 802.3, the one ZIP uses). Computed here because the alternative is a crate whose
/// only job is this twenty-line table.
fn crc32(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (index, slot) in table.iter_mut().enumerate() {
        let mut value = index as u32;
        for _ in 0..8 {
            value = if value & 1 != 0 { 0xEDB8_8320 ^ (value >> 1) } else { value >> 1 };
        }
        *slot = value;
    }
    let mut crc = 0xFFFF_FFFFu32;
    for byte in data {
        crc = table[((crc ^ *byte as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

// --------------------------------------------------------------------------------------------- //
// Reading a zip back in (the import side of backup)                                              //
// -------------------------------------------------------------------------------------------- //

/// No entry may inflate beyond the ceiling the backup itself is under. This is also the zip-bomb
/// guard: an 8 MiB archive that claims a 4 GiB `backup.json` is refused here, before inflate runs.
const MAX_ZIP_ENTRY_BYTES: usize = 8 * 1024 * 1024;

/// Read every entry of a zip archive: `(name, bytes)` in archive order.
///
/// Walks local file headers front to back, which covers everything this route must read: our own
/// `build_zip` output, and archives Python's `zipfile` (or any seekable-output writer) produces —
/// those carry the real sizes in the header. An archive written as a stream (bit 3 set, sizes in a
/// data descriptor after the data) cannot be walked this way and is refused rather than half-read.
/// Method 0 is stored, method 8 is deflated; anything else the archive carries is not something a
/// Hermey backup contains, and is refused with the same "not a readable zip" answer.
pub fn read_zip(data: &[u8]) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut entries: Vec<(String, Vec<u8>)> = Vec::new();
    let mut pos = 0usize;
    loop {
        if pos + 30 > data.len() || &data[pos..pos + 4] != b"PK\x03\x04" {
            break;
        }
        let u16_at = |offset: usize| u16::from_le_bytes([data[offset], data[offset + 1]]);
        let u32_at = |offset: usize| {
            u32::from_le_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ])
        };
        let flags = u16_at(pos + 6);
        let method = u16_at(pos + 8);
        let compressed_size = u32_at(pos + 18) as usize;
        let uncompressed_size = u32_at(pos + 22) as usize;
        let name_len = u16_at(pos + 26) as usize;
        let extra_len = u16_at(pos + 28) as usize;
        if flags & 0x0008 != 0 {
            return Err("that file is not a readable zip (streamed archive without header sizes)".into());
        }
        let name_start = pos + 30;
        let data_start = name_start + name_len + extra_len;
        if data_start + compressed_size > data.len() {
            return Err("that file is not a readable zip (truncated entry)".into());
        }
        let name = String::from_utf8_lossy(&data[name_start..name_start + name_len]).to_string();
        let raw = &data[data_start..data_start + compressed_size];
        if !name.ends_with('/') && uncompressed_size <= MAX_ZIP_ENTRY_BYTES {
            let bytes = match method {
                0 => raw.to_vec(),
                8 => {
                    let mut decoder = flate2::read::DeflateDecoder::new(raw);
                    let mut out = Vec::with_capacity(uncompressed_size);
                    use std::io::Read as _;
                    match decoder.read_to_end(&mut out) {
                        Ok(_) if out.len() == uncompressed_size => out,
                        _ => return Err("that file is not a readable zip (bad deflate data)".into()),
                    }
                }
                _ => return Err(format!("that file is not a readable zip (method {method})")),
            };
            entries.push((name, bytes));
        }
        pos = data_start + compressed_size;
    }
    if entries.is_empty() {
        return Err("that file is not a readable zip".into());
    }
    Ok(entries)
}

/// The stem of an `icons/<profile>.png` entry name — the key the import matches bots with.
pub fn icon_key(name: &str) -> Option<String> {
    let rest = name.strip_prefix("icons/")?;
    let stem = rest.strip_suffix(".png")?;
    let stem = stem.rsplit(['/', '\\']).next().unwrap_or("");
    if stem.is_empty() {
        return None;
    }
    Some(stem.to_string())
}

/// The ZIP timestamp is MS-DOS packed: seconds are worth two, and the epoch starts in 1980.
fn dos_stamp() -> (u16, u16) {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;

    // Civil date from a day count (Howard Hinnant's algorithm, the same one backup.rs uses).
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    let year = year.max(1980);

    let date = (((year - 1980) as u16) << 9) | ((month as u16) << 5) | (day as u16);
    let time = (((rem / 3600) as u16) << 11)
        | ((((rem % 3600) / 60) as u16) << 5)
        | (((rem % 60) / 2) as u16);
    (time, date)
}

// ---------------------------------------------------------------------------------------------
// PUT /v1/push/icon/{bot} and GET /v1/push/icon/{bot}.png
// ---------------------------------------------------------------------------------------------

/// A notification image, not a wallpaper.
const MAX_ICON_BYTES: usize = 2 * 1024 * 1024;

/// Room for the base64 envelope around a 2 MiB image (4 MiB), so the size check that answers is the
/// one below — with its own `detail` — and not the framework's body ceiling.
pub const ICON_BODY_LIMIT: usize = 4 * 1024 * 1024;

const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";
const JPEG_MAGIC: &[u8] = b"\xff\xd8\xff";

/// A profile name is a directory name: letters, digits, dash, underscore; 64 at most.
pub(crate) fn valid_profile(name: &str) -> bool {
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

#[derive(Deserialize)]
struct IconUpload {
    /// Base64 image, which is how the app sends it: no encoder beyond what both sides already have.
    #[serde(default)]
    png: String,
    /// The renderer's own hash, so an unchanged face costs a request and no write.
    #[serde(default)]
    sha256: Option<String>,
}

/// Write bytes beside the target, 0600, then rename: a reader never sees half an image.
/// Shared with the backup import, which lands the zip's icons in the same directory.
pub(crate) fn write_private_atomic(dir: &std::path::Path, path: &std::path::Path, data: &[u8]) -> Result<(), Fail> {
    std::fs::create_dir_all(dir)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("cannot create icon dir: {e}")))?;
    // Unique per call: two uploads for one bot must not share a temporary name.
    let tmp = dir.join(format!(".{}.{}.tmp", random_token(6), path.file_name().and_then(|n| n.to_str()).unwrap_or("icon")));
    std::fs::write(&tmp, data)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("cannot store the icon: {e}")))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        bad(StatusCode::INTERNAL_SERVER_ERROR, format!("cannot save the icon: {e}"))
    })
}

/// `PUT /v1/push/icon/{bot}` — the face this bot's banners should show.
///
/// Two body shapes are accepted because two callers exist: the apps send JSON
/// (`{"png": "<base64>", "sha256": "…"}`, no encoder needed on either side), and anything scripted
/// can PUT the image itself with a normal `image/png` or `image/jpeg` content type. Either way the
/// bytes must actually be an image — a text file served as a picture is worse than no picture.
pub async fn push_icon_put(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(bot): Path<String>,
    body: Bytes,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&bot) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid profile"));
    }

    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();

    let (data, claimed_sha) = if content_type.starts_with("image/png")
        || content_type.starts_with("image/jpeg")
    {
        (body.to_vec(), None)
    } else {
        let upload: IconUpload = serde_json::from_slice(&body).map_err(|_| {
            bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                "expected image bytes with an image content type, or a JSON body with a base64 png",
            )
        })?;
        use base64::Engine as _;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(upload.png.as_bytes())
            .map_err(|_| bad(StatusCode::UNPROCESSABLE_ENTITY, "png is not base64"))?;
        (bytes, upload.sha256)
    };

    if !(data.starts_with(PNG_MAGIC) || data.starts_with(JPEG_MAGIC)) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "not a PNG or JPEG image"));
    }
    if data.len() > MAX_ICON_BYTES {
        return Err(bad(StatusCode::PAYLOAD_TOO_LARGE, "icon is too large"));
    }

    let digest = sha256_hex(&data);
    let dir = icon_dir(&st);
    let path = dir.join(format!("{bot}.png"));
    if claimed_sha.as_deref() == Some(digest.as_str()) && path.is_file() {
        return Ok(Json(json!({"profile": bot, "changed": false, "sha256": digest})));
    }
    write_private_atomic(&dir, &path, &data)?;
    Ok(Json(json!({"profile": bot, "changed": true, "sha256": digest})))
}

/// `GET /v1/push/icon/{bot}.png` — served without a device credential, exactly as the bridge does:
/// the notification relay fetches it and holds none, and the only thing it reveals is a bot's face.
pub async fn push_icon_get(
    State(st): State<Arc<AppState>>,
    Path(bot): Path<String>,
) -> Result<Response, Fail> {
    let name = bot.strip_suffix(".png").unwrap_or(bot.as_str());
    let bytes = match valid_profile(name).then(|| read_icon(&st, name)).flatten() {
        Some(bytes) => bytes,
        None => return Err(bad(StatusCode::NOT_FOUND, "no icon")),
    };
    Ok(body_of(bytes, "image/png", &[("cache-control", "no-cache".to_string())]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{scratch, state as test_state};

    #[test]
    fn crc32_matches_the_reference_vector() {
        // "123456789" -> 0xCBF43926, the check value from the CRC-32 specification.
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn traversal_is_refused_in_both_segments() {
        assert!(single_component("..").is_none());
        assert!(single_component("../etc").is_none());
        assert!(single_component("a/b").is_none());
        assert!(single_component(".hidden").is_none());
        assert!(single_component("upload_ab12.png").is_some());
        assert!(valid_profile("bob"));
        assert!(!valid_profile("Bob"));
        assert!(!valid_profile("../bob"));
        assert!(!valid_profile(""));
    }

    #[test]
    fn zip_has_the_central_directory_and_a_valid_crc() {
        let archive = build_zip(&[("backup.json".into(), b"{\"bots\":[]}".to_vec())]);
        assert_eq!(&archive[0..4], b"PK\x03\x04");
        assert!(archive.windows(4).any(|w| w == b"PK\x01\x02"));
        assert!(archive.windows(4).any(|w| w == b"PK\x05\x06"));
        assert_eq!(crc32(b"{\"bots\":[]}"), 0x763C_ACBC);
    }

    #[test]
    fn read_zip_round_trips_our_own_archive() {
        let archive = build_zip(&[
            ("backup.json".into(), b"{\"kind\":\"hermey-bot-backup\",\"bots\":[]}".to_vec()),
            ("icons/bob.png".into(), b"pngbytes".to_vec()),
        ]);
        let entries = read_zip(&archive).expect("our own archive must read back");
        let names: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(names, ["backup.json", "icons/bob.png"]);
        assert_eq!(entries[0].1, b"{\"kind\":\"hermey-bot-backup\",\"bots\":[]}");
        assert_eq!(icon_key("icons/bob.png").as_deref(), Some("bob"));
        assert!(icon_key("backup.json").is_none());
        assert!(icon_key("icons/sub/x.png").is_some()); // nested names keep their stem, as the bridge does
    }

    #[test]
    fn read_zip_refuses_junk() {
        assert!(read_zip(b"not a zip at all, just bytes").is_err());
        assert!(read_zip(b"").is_err());
    }

    // -- GET /v1/attachments/{profile}/{name} -------------------------------------------------

    fn device_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            header::HeaderValue::from_static("Bearer test-local-token"),
        );
        headers
    }

    async fn fetch(st: &Arc<AppState>, profile: &str, name: &str) -> Result<Response, Fail> {
        attachment_file(
            State(Arc::clone(st)),
            device_headers(),
            Path((profile.to_string(), name.to_string())),
        )
        .await
    }

    async fn body_bytes(response: Response) -> Vec<u8> {
        axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("the route builds its body from bytes it already holds")
            .to_vec()
    }

    /// The whole point of the route after the office work: a picture still comes from `images/`
    /// with the type it always had, and a document comes from `attachments/` with a type a viewer
    /// will open — same bearer, same size ceiling, same refusals.
    #[tokio::test]
    async fn pictures_and_documents_are_served_from_their_own_folders() {
        let dir = scratch("attachment-route");
        let st = Arc::new(test_state(&dir));
        let profile_dir = st.engine_home.join("profiles").join("cody");
        std::fs::create_dir_all(profile_dir.join("images")).unwrap();
        std::fs::create_dir_all(profile_dir.join("attachments")).unwrap();

        let png = vec![0x89, b'P', b'N', b'G', 1, 2, 3];
        std::fs::write(profile_dir.join("images").join("shot.png"), &png).unwrap();
        let xlsx = crate::office::fixtures::xlsx_fixture();
        std::fs::write(profile_dir.join("attachments").join("budget.xlsx"), &xlsx).unwrap();
        let pdf = crate::office::fixtures::pdf_fixture("Invoice 4711");
        std::fs::write(profile_dir.join("attachments").join("invoice.pdf"), &pdf).unwrap();

        // An image: byte-identical, and still an image's content type.
        let response = fetch(&st, "cody", "shot.png").await.expect("a picture is still served");
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "image/png"
        );
        assert_eq!(body_bytes(response).await, png);

        // A spreadsheet and a PDF: the two the apps now open on press.
        let response = fetch(&st, "cody", "budget.xlsx").await.expect("a workbook is served");
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        );
        assert_eq!(body_bytes(response).await, xlsx);

        let response = fetch(&st, "cody", "invoice.pdf").await.expect("a pdf is served");
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "application/pdf"
        );
        assert_eq!(body_bytes(response).await, pdf);

        // Everything else keeps the old answer, and a missing file is still a 404.
        let error = fetch(&st, "cody", "notes.txt").await.unwrap_err();
        assert_eq!(error.0, StatusCode::BAD_REQUEST);
        assert_eq!(error.1 .0["detail"], "not an image attachment");
        let error = fetch(&st, "cody", "absent.xlsx").await.unwrap_err();
        assert_eq!(error.0, StatusCode::NOT_FOUND);

        // One path component, still: a traversal never reaches the filesystem.
        let error = fetch(&st, "cody", "..").await.unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);
        let error = fetch(&st, "../cody", "budget.xlsx").await.unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
