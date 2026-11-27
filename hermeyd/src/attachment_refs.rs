//! One route for the reference a transcript carries: `GET /v1/attachments?profile=&path=`.
//!
//! A picture or a file the owner attaches is stored **on the host** and the message only carries a
//! path to it — `@image:/root/.hermes/profiles/cody/images/upload_1v5jm9lm.jpg`, or
//! `@file:.hermes/profiles/cody/attachments/MICs.xlsx` inside the engine's `📎 … — Attached Context
//! —` block. The device that uploaded it has the bytes; every other device has the string and has
//! to resolve it. `/v1/attachments/{profile}/{name}` (parity_gaps.rs) serves a *name* and only the
//! types a bubble can draw; this route serves the *reference*, whatever the file is, which is what
//! a second device actually holds.
//!
//! The scope is the whole security story, so it is stated once, here:
//!
//!   * the reference must name a folder segment of `images` or `attachments` — nothing else is
//!     served, so `@file:…/profiles/cody/state.db` is not a file this route knows about;
//!   * a `..` segment is refused before the filesystem is touched, and `.` / a hidden name with it;
//!   * when the reference names a profile (`…/profiles/<p>/…`) that profile must be the requested
//!     one — the route cannot be re-targeted from one profile onto another after the fact. This is
//!     *consistency inside one request*, not device scoping: see the next rule;
//!   * **a paired device is not bound to a profile.** Devices pair host-wide (`pairing.rs` records
//!     no profile) and the apps legitimately show several profiles' conversations on one device, so
//!     a paired device may read *any* profile's `images/`/`attachments/` — including the
//!     host-level `<engine_home>/images|attachments` candidates `parity_gaps.rs` keeps. That is the
//!     chosen rule (2026-11 audit): binding a device token to a profile would invalidate every
//!     pairing and break the cross-profile transcript views. What bounds the route is instead the
//!     pair above — a device bearer plus a reference that cannot leave the two folders of one
//!     profile. The rule is pinned by `a_paired_device_reads_any_profile_it_has_a_row_for`;
//!   * the file that is finally opened is the one inside `<engine_home>/profiles/<profile>/<folder>`
//!     with the reference's last component as its name: the reference is a *pointer*, and the path
//!     is rebuilt from parts this module validated, never from the string that arrived;
//!   * a symlink is refused rather than followed, and both the folder and the file are
//!     canonicalised and re-checked, so a symlinked folder cannot walk out either;
//!   * 32 MiB is the ceiling — larger than anything the upload path accepts (8 MiB), so a picture
//!     that travelled is always servable, and small enough that a hostile path cannot pull a
//!     database into a phone's memory.
//!
//! Errors are JSON `{"detail": …}` and are never an empty 200: the client draws a named
//! "unavailable" chip from that, which is the difference between an error that looks like an error
//! and a blank space where a picture should be.
//!
//! New in 0.8.26 (0.8.25 was the previous build): the route itself, `GET /v1/attachments?profile=&path=`.

use crate::routes::{require_device, AppState};
use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

/// 32 MiB. See the module note: above the upload path's own 8 MiB, below "a file store".
pub const MAX_REFERENCE_BYTES: u64 = 32 * 1024 * 1024;

/// The two folders a reference may point into. Anything else is not an attachment.
const FOLDERS: [&str; 2] = ["images", "attachments"];

/// Why a reference was refused. Each one maps to one status and one sentence, so a client (and a
/// test) can tell which rule answered without reading a stack trace.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Empty, a NUL, a backslash — not a path this host could ever have written.
    Malformed,
    /// `..`, or a `.`/hidden component: nothing legitimate needs either.
    Traversal,
    /// A reference naming a profile is only served to that profile.
    OtherProfile,
    /// An absolute path that is not this profile's file at all.
    OutsideProfile,
    /// The reference does not name `images/` or `attachments/`.
    NotAnAttachmentFolder,
    /// No such file, or not a regular file.
    NotFound,
    /// A symlink, or a path that resolves outside the profile's folder.
    Escape,
    /// Over [`MAX_REFERENCE_BYTES`].
    TooLarge(u64),
}

impl Refusal {
    pub fn status(self) -> StatusCode {
        match self {
            Refusal::NotFound => StatusCode::NOT_FOUND,
            Refusal::TooLarge(_) => StatusCode::PAYLOAD_TOO_LARGE,
            _ => StatusCode::UNPROCESSABLE_ENTITY,
        }
    }

    /// The `detail`. It names the rule, never the path that arrived: the body must not echo a
    /// string a client controls back into its own log.
    pub fn detail(self) -> String {
        match self {
            Refusal::Malformed => "invalid attachment reference".to_string(),
            Refusal::Traversal => "invalid attachment reference: no traversal".to_string(),
            Refusal::OtherProfile => "invalid attachment reference: another profile".to_string(),
            Refusal::OutsideProfile => {
                "invalid attachment reference: outside the profile".to_string()
            }
            Refusal::NotAnAttachmentFolder => {
                "invalid attachment reference: only images/ and attachments/".to_string()
            }
            Refusal::NotFound => "attachment not found".to_string(),
            Refusal::Escape => "invalid attachment reference: outside the profile".to_string(),
            Refusal::TooLarge(bytes) => format!("attachment too large ({bytes} bytes)"),
        }
    }
}

impl From<Refusal> for Fail {
    fn from(refusal: Refusal) -> Self {
        (refusal.status(), Json(json!({ "detail": refusal.detail() })))
    }
}

/// One reference, resolved: the file to open, and the folder it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolved {
    pub path: PathBuf,
    /// `images` or `attachments`.
    pub folder: &'static str,
    /// The last path component — the name a row shows and the name the bytes are cached under.
    pub name: String,
}

/// The reference with its wrappers off: `@image:`, `@file:`, backticks and quotes.
///
/// The engine wraps a path containing whitespace in backticks (`_format_ref_value`), and the
/// `📎` block spells the same file out again inside backticks, so all four shapes are read here.
fn bare_path(raw: &str) -> &str {
    let mut text = raw.trim();
    for marker in ["@image:", "@file:"] {
        if let Some(rest) = text.strip_prefix(marker) {
            text = rest.trim();
            break;
        }
    }
    for (open, close) in [('`', '`'), ('"', '"'), ('\'', '\'')] {
        if text.starts_with(open) {
            let inner = &text[open.len_utf8()..];
            if let Some(end) = inner.find(close) {
                return inner[..end].trim();
            }
            return inner.trim();
        }
    }
    text
}

/// Resolve a reference to a file inside `profiles_root/<profile>/{images,attachments}`.
///
/// Everything here is decidable without a filesystem except the last three checks; the point of the
/// split is that a bad reference never reaches `open`, and a test can prove that.
pub fn resolve(profiles_root: &Path, profile: &str, raw: &str) -> Result<Resolved, Refusal> {
    if !crate::parity_gaps::valid_profile(profile) {
        return Err(Refusal::Malformed);
    }
    let path = bare_path(raw);
    if path.is_empty()
        || path.len() > 4096
        || path.contains('\0')
        || path.contains('\r')
        || path.contains('\n')
        || path.contains('\\')
    {
        return Err(Refusal::Malformed);
    }

    // Split on the separator only. An absolute path and a profile-relative one are read the same
    // way, because the reference is a *pointer*: the parts are checked, then the path is rebuilt
    // from the profile folder, never joined to what arrived.
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    for segment in &segments {
        if *segment == ".." || *segment == "." {
            return Err(Refusal::Traversal);
        }
    }
    if segments.len() < 2 {
        // A bare name does not say which folder it is in, and guessing is how one folder's file
        // becomes the other's.
        return Err(Refusal::NotAnAttachmentFolder);
    }

    // A reference that names a profile must name *this* one, and an absolute path must name one at
    // all: `/var/lib/hermey/attachments/x.xlsx` is a real-looking absolute path that this host did
    // not write, so serving it (out of cody's folder) would be answering a question nobody asked.
    // A hidden *intermediate* segment is allowed — `.hermes` is exactly how the engine spells its
    // home — but a hidden file name is not: nothing the upload path writes starts with a dot.
    let profiles_at = segments.iter().position(|s| *s == "profiles");
    match profiles_at {
        Some(index) => {
            if segments.get(index + 1) != Some(&profile) {
                return Err(Refusal::OtherProfile);
            }
        }
        None if path.starts_with('/') => return Err(Refusal::OutsideProfile),
        None => {}
    }

    let name = segments[segments.len() - 1];
    if name.starts_with('.') {
        return Err(Refusal::Traversal);
    }
    if name.len() > 255 {
        return Err(Refusal::Malformed);
    }
    let folder = segments[segments.len() - 2];
    let Some(folder) = FOLDERS.iter().copied().find(|f| *f == folder) else {
        return Err(Refusal::NotAnAttachmentFolder);
    };
    if !plausible_name(name) {
        return Err(Refusal::Malformed);
    }

    Ok(Resolved {
        path: profiles_root.join(profile).join(folder).join(name),
        folder,
        name: name.to_string(),
    })
}

/// A name the upload path could actually have written: no separators (already true after the
/// split), and at least one character that is not whitespace or a dot.
fn plausible_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.starts_with('.')
        && name.chars().any(|c| !c.is_whitespace())
        && !name.chars().any(|c| c.is_control())
}

/// The content type a viewer should be handed. Best effort by extension, because the route serves
/// whatever the owner attached — a file it cannot name is still bytes the row can open, so the
/// fallback is the generic binary type rather than a refusal.
pub fn media_type(name: &str) -> &'static str {
    let extension = name.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase());
    match extension.as_deref() {
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("heic") => "image/heic",
        Some("heif") => "image/heif",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("tiff") | Some("tif") => "image/tiff",
        Some("bmp") => "image/bmp",
        Some("pdf") => "application/pdf",
        Some("docx") => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        Some("xlsx") => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        Some("pptx") => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        Some("doc") => "application/msword",
        Some("xls") => "application/vnd.ms-excel",
        Some("odt") => "application/vnd.oasis.opendocument.text",
        Some("ods") => "application/vnd.oasis.opendocument.spreadsheet",
        Some("txt") => "text/plain; charset=utf-8",
        Some("md") | Some("markdown") => "text/markdown; charset=utf-8",
        Some("csv") => "text/csv; charset=utf-8",
        Some("json") => "application/json",
        Some("zip") => "application/zip",
        Some("rtf") => "application/rtf",
        _ => "application/octet-stream",
    }
}

/// Open a resolved reference, refusing a symlink, an escape and an oversized file.
///
/// The candidate is canonicalised and re-checked against the canonical folder: a regular file inside
/// `images/` that is itself a symlink to `/etc/passwd` passes the first test (`symlink_metadata`
/// says so) and fails here.
pub fn open(resolved: &Resolved, profiles_root: &Path, profile: &str) -> Result<Vec<u8>, Refusal> {
    let meta = std::fs::symlink_metadata(&resolved.path).map_err(|_| Refusal::NotFound)?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        return Err(Refusal::Escape);
    }
    if meta.len() > MAX_REFERENCE_BYTES {
        return Err(Refusal::TooLarge(meta.len()));
    }
    // The folder is checked before it is trusted: `images/` being a symlink to another profile's
    // `images/` would otherwise hand that profile's files out under this one's name. Canonicalising
    // the folder would follow exactly that link and agree with the file, which is why the check has
    // to happen on the folder itself, not on where it points.
    let folder_path = profiles_root.join(profile).join(resolved.folder);
    let folder_meta = std::fs::symlink_metadata(&folder_path).map_err(|_| Refusal::NotFound)?;
    if folder_meta.file_type().is_symlink() || !folder_meta.is_dir() {
        return Err(Refusal::Escape);
    }
    let real = resolved.path.canonicalize().map_err(|_| Refusal::NotFound)?;
    let folder = folder_path.canonicalize().map_err(|_| Refusal::NotFound)?;
    let profile_root = profiles_root
        .join(profile)
        .canonicalize()
        .map_err(|_| Refusal::NotFound)?;
    // The file must be *directly* in the folder, not nested somewhere that merely began there, and
    // the folder must live inside the profile it belongs to.
    if real.parent() != Some(folder.as_path()) || !real.starts_with(&profile_root) {
        return Err(Refusal::Escape);
    }
    std::fs::read(&real).map_err(|_| Refusal::NotFound)
}

#[derive(Debug, Deserialize)]
pub struct ReferenceQuery {
    pub profile: Option<String>,
    pub path: Option<String>,
}

/// `GET /v1/attachments?profile=<p>&path=<reference>` — the bytes behind one reference.
///
/// No cache: a reference names a file that can be rewritten (an upload slot re-used, a document
/// re-attached), and a stale picture is worse than a fetch. The client keeps its own cache, keyed
/// by the reference string, which is the only place that knows a render is a re-render.
pub async fn attachment_by_reference(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<ReferenceQuery>,
) -> Result<Response, Fail> {
    require_device(&st, &headers)?;

    let Some(profile) = query.profile.as_deref() else {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({"detail": "profile is required"})),
        ));
    };
    let Some(path) = query.path.as_deref() else {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({"detail": "path is required"})),
        ));
    };

    let profiles_root = st.engine_home.join("profiles");
    let resolved = resolve(&profiles_root, profile, path)?;
    let bytes = open(&resolved, &profiles_root, profile)?;

    let mut response = Response::new(axum::body::Body::from(bytes));
    let h = response.headers_mut();
    h.insert(
        header::CONTENT_TYPE,
        media_type(&resolved.name).parse().unwrap(),
    );
    // Every answer is a fresh read, so nothing between here and the screen may keep it: the
    // reference is the cache key, and the client is the thing that holds the cache.
    h.insert(
        header::CACHE_CONTROL,
        header::HeaderValue::from_static("no-store, no-cache, must-revalidate, private"),
    );
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{scratch, state as test_state};
    use axum::extract::Query as AxumQuery;

    fn profiles(root: &Path) -> PathBuf {
        root.join("profiles")
    }

    fn cody(root: &Path) -> PathBuf {
        profiles(root).join("cody")
    }

    /// The two shapes the host actually stores, read from a live profile on this host before this
    /// module was written.
    const IMAGE_REF: &str = "@image:/root/.hermes/profiles/cody/images/upload_1v5jm9lm.jpg";
    const FILE_REF: &str = "@file:.hermes/profiles/cody/attachments/MICs.xlsx";

    #[test]
    fn both_stored_shapes_resolve_into_the_profiles_own_folders() {
        let root = scratch("ref-resolve");
        let image = resolve(&profiles(&root), "cody", IMAGE_REF).expect("an upload reference");
        assert_eq!(image.folder, "images");
        assert_eq!(image.name, "upload_1v5jm9lm.jpg");
        assert_eq!(image.path, cody(&root).join("images/upload_1v5jm9lm.jpg"));

        // The `@file:` shape is relative to the engine home, not absolute: it must land in the same
        // place as an absolute one naming the same file.
        let file = resolve(&profiles(&root), "cody", FILE_REF).expect("a file reference");
        assert_eq!(file.folder, "attachments");
        assert_eq!(file.name, "MICs.xlsx");
        assert_eq!(file.path, cody(&root).join("attachments/MICs.xlsx"));

        let absolute = resolve(
            &profiles(&root),
            "cody",
            "@file:/root/.hermes/profiles/cody/attachments/MICs.xlsx",
        )
        .expect("the absolute spelling of the same file");
        assert_eq!(absolute.path, file.path, "both spellings are one file");

        // Backticks and quotes are the engine's wrappers, not part of the name.
        let wrapped = resolve(
            &profiles(&root),
            "cody",
            "@file:`/home/a/profiles/cody/attachments/my report.pdf`",
        )
        .expect("a wrapped path");
        assert_eq!(wrapped.name, "my report.pdf");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn traversal_is_refused_before_anything_is_opened() {
        let root = scratch("ref-traversal");
        let root_profiles = profiles(&root);
        for raw in [
            "@image:/root/.hermes/profiles/cody/images/../../../../etc/passwd",
            "@file:.hermes/profiles/cody/attachments/../../secrets.env",
            "@image:images/../attachments/x.png",
            "@image:images/./upload_a.png",
            "@image:images/.hidden.png",
            "@image:.hermes/profiles/cody/images/.env",
        ] {
            let error = resolve(&root_profiles, "cody", raw).expect_err("must be refused");
            assert!(
                matches!(error, Refusal::Traversal | Refusal::OtherProfile),
                "{raw} gave {error:?}"
            );
            assert_eq!(error.status(), StatusCode::UNPROCESSABLE_ENTITY);
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_absolute_path_outside_the_profile_is_refused() {
        let root = scratch("ref-outside");
        let root_profiles = profiles(&root);
        for raw in [
            "/etc/passwd",
            "/root/.hermes/profiles/jason/images/upload_a.png",
            "@file:/var/lib/hermey/attachments/x.xlsx",
            "@image:/root/.hermes/profiles/cody/state.db",
            "@image:/root/.hermes/images/upload_a.png", // absolute, but no profile home named
        ] {
            let error = resolve(&root_profiles, "cody", raw).expect_err("must be refused");
            assert!(
                matches!(
                    error,
                    Refusal::OtherProfile
                        | Refusal::OutsideProfile
                        | Refusal::NotAnAttachmentFolder
                        | Refusal::Malformed
                ),
                "{raw} gave {error:?}"
            );
        }

        // The two rules stated on their own: another profile's reference is refused *for being
        // another profile*, and an absolute path with no profile home is refused as outside.
        assert_eq!(
            resolve(&root_profiles, "cody", "@image:/p/profiles/jason/images/a.png"),
            Err(Refusal::OtherProfile)
        );
        assert_eq!(
            resolve(&root_profiles, "cody", "@file:/srv/drop/attachments/a.xlsx"),
            Err(Refusal::OutsideProfile)
        );
        // ... while the engine's own relative spelling of this profile is served.
        assert!(resolve(&root_profiles, "cody", "@file:.hermes/profiles/cody/attachments/a.xlsx").is_ok());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn only_the_two_attachment_folders_are_served() {
        let root = scratch("ref-folders");
        let root_profiles = profiles(&root);
        for raw in [
            "@file:.hermes/profiles/cody/workspace/report.pdf",
            "@file:.hermes/profiles/cody/state.db",
            "@image:/root/.hermes/profiles/cody/logs/run.log",
            "@image:.hermes/profiles/cody/images/upload_a.png/nested.png",
            "MICs.xlsx",
            "",
        ] {
            let error = resolve(&root_profiles, "cody", raw).expect_err("must be refused");
            assert!(
                matches!(error, Refusal::NotAnAttachmentFolder | Refusal::Malformed),
                "{raw} gave {error:?}"
            );
        }
        // The two that are served say so.
        assert_eq!(resolve(&root_profiles, "cody", "@image:images/a.png").unwrap().folder, "images");
        assert_eq!(
            resolve(&root_profiles, "cody", "@file:attachments/a.xlsx").unwrap().folder,
            "attachments"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_that_escapes_is_refused_rather_than_followed() {
        use std::os::unix::fs::symlink;
        let root = scratch("ref-symlink");
        let profile = cody(&root);
        std::fs::create_dir_all(profile.join("images")).unwrap();
        std::fs::create_dir_all(profile.join("attachments")).unwrap();

        // A file outside the profile, reachable only through a link inside it.
        let secret = root.join("secret.env");
        std::fs::write(&secret, b"TOKEN=1").unwrap();
        symlink(&secret, profile.join("images").join("upload_escape.png")).unwrap();

        let resolved = resolve(&profiles(&root), "cody", "@image:images/upload_escape.png")
            .expect("the reference is well formed");
        assert_eq!(
            open(&resolved, &profiles(&root), "cody"),
            Err(Refusal::Escape),
            "a symlinked file is refused, never followed"
        );

        // A symlinked *folder* is caught by the canonical check instead: the file's real path is
        // under the other profile, not this one.
        std::fs::create_dir_all(profiles(&root).join("jason").join("images")).unwrap();
        std::fs::write(profiles(&root).join("jason/images/upload_b.png"), b"other").unwrap();
        std::fs::remove_dir_all(profile.join("attachments")).unwrap();
        symlink(profiles(&root).join("jason/images"), profile.join("attachments")).unwrap();
        let resolved = resolve(&profiles(&root), "cody", "@image:attachments/upload_b.png")
            .expect("the reference is well formed");
        assert_eq!(
            open(&resolved, &profiles(&root), "cody"),
            Err(Refusal::Escape),
            "a symlinked folder cannot hand out another profile's file"
        );

        // The harder case: a symlinked folder pointing *inside* this profile. The canonical path is
        // then inside `profiles/cody`, so only the folder's own type refuses it — which is why that
        // check exists as well as the path one.
        std::fs::remove_file(profile.join("attachments")).unwrap();
        std::fs::write(profile.join("images/upload_c.png"), b"image").unwrap();
        symlink(profile.join("images"), profile.join("attachments")).unwrap();
        let resolved = resolve(&profiles(&root), "cody", "@image:attachments/upload_c.png")
            .expect("the reference is well formed");
        assert_eq!(
            open(&resolved, &profiles(&root), "cody"),
            Err(Refusal::Escape),
            "a folder that is a symlink is not followed, even inward"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_size_ceiling_is_thirty_two_mebibytes_and_bites() {
        assert_eq!(MAX_REFERENCE_BYTES, 33_554_432);
        let root = scratch("ref-oversize");
        let profile = cody(&root);
        std::fs::create_dir_all(profile.join("attachments")).unwrap();
        let big = profile.join("attachments").join("huge.bin");
        let file = std::fs::File::create(&big).unwrap();
        // Sparse: the length is what the check reads, and no 32 MiB is written to the disk.
        file.set_len(MAX_REFERENCE_BYTES + 1).unwrap();
        drop(file);

        let resolved = resolve(&profiles(&root), "cody", "@file:attachments/huge.bin").unwrap();
        assert_eq!(
            open(&resolved, &profiles(&root), "cody"),
            Err(Refusal::TooLarge(MAX_REFERENCE_BYTES + 1))
        );
        assert_eq!(Refusal::TooLarge(1).status(), StatusCode::PAYLOAD_TOO_LARGE);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_missing_file_is_a_404_and_never_an_empty_body() {
        let root = scratch("ref-missing");
        std::fs::create_dir_all(cody(&root).join("images")).unwrap();
        let resolved = resolve(&profiles(&root), "cody", "@image:images/upload_absent.png").unwrap();
        assert_eq!(open(&resolved, &profiles(&root), "cody"), Err(Refusal::NotFound));
        let fail: Fail = Refusal::NotFound.into();
        assert_eq!(fail.0, StatusCode::NOT_FOUND);
        assert_eq!(fail.1 .0["detail"], "attachment not found");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_content_type_is_the_files_and_the_fallback_is_binary() {
        assert_eq!(media_type("upload_a.jpg"), "image/jpeg");
        assert_eq!(media_type("upload_a.HEIC"), "image/heic");
        assert_eq!(media_type("MICs.xlsx"), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        assert_eq!(media_type("notes.md"), "text/markdown; charset=utf-8");
        // Anything else is still openable, so it is bytes rather than a refusal.
        assert_eq!(media_type("archive.7z"), "application/octet-stream");
        assert_eq!(media_type("no-extension"), "application/octet-stream");
    }

    // -- the route ---------------------------------------------------------------------------

    fn device_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            "authorization",
            header::HeaderValue::from_static("Bearer test-local-token"),
        );
        headers
    }

    async fn fetch(st: &Arc<AppState>, profile: Option<&str>, path: Option<&str>) -> Result<Response, Fail> {
        attachment_by_reference(
            State(Arc::clone(st)),
            device_headers(),
            AxumQuery(ReferenceQuery {
                profile: profile.map(str::to_string),
                path: path.map(str::to_string),
            }),
        )
        .await
    }

    async fn body_bytes(response: Response) -> Vec<u8> {
        axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("the route builds its body from bytes it already holds")
            .to_vec()
    }

    #[tokio::test]
    async fn a_picture_and_a_workbook_come_back_byte_for_byte() {
        let dir = scratch("ref-route");
        let st = Arc::new(test_state(&dir));
        let profile = st.engine_home.join("profiles").join("cody");
        std::fs::create_dir_all(profile.join("images")).unwrap();
        std::fs::create_dir_all(profile.join("attachments")).unwrap();

        let jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];
        std::fs::write(profile.join("images/upload_1v5jm9lm.jpg"), &jpeg).unwrap();
        let xlsx = crate::office::fixtures::xlsx_fixture();
        std::fs::write(profile.join("attachments/MICs.xlsx"), &xlsx).unwrap();

        let response = fetch(&st, Some("cody"), Some(IMAGE_REF)).await.expect("the photo");
        assert_eq!(response.headers().get(header::CONTENT_TYPE).unwrap(), "image/jpeg");
        let cache = response.headers().get(header::CACHE_CONTROL).unwrap().to_str().unwrap();
        assert!(cache.contains("no-store"), "a re-read must not be served from a cache: {cache}");
        assert_eq!(body_bytes(response).await, jpeg);

        // The relative `@file:` shape, which is what the engine's `📎` block spells.
        let response = fetch(&st, Some("cody"), Some(FILE_REF)).await.expect("the workbook");
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        );
        assert_eq!(body_bytes(response).await, xlsx);

        // A bearer is required, like every other attachment route.
        let error = attachment_by_reference(
            State(Arc::clone(&st)),
            HeaderMap::new(),
            AxumQuery(ReferenceQuery { profile: Some("cody".into()), path: Some(IMAGE_REF.into()) }),
        )
        .await
        .unwrap_err();
        assert_eq!(error.0, StatusCode::UNAUTHORIZED);

        // Both query parameters are answered for, by name.
        let error = fetch(&st, None, Some(IMAGE_REF)).await.unwrap_err();
        assert_eq!(error.0, StatusCode::BAD_REQUEST);
        assert_eq!(error.1 .0["detail"], "profile is required");
        let error = fetch(&st, Some("cody"), None).await.unwrap_err();
        assert_eq!(error.0, StatusCode::BAD_REQUEST);
        assert_eq!(error.1 .0["detail"], "path is required");

        // A refusal is JSON with a sentence, not an empty body.
        let error = fetch(&st, Some("cody"), Some("@image:images/absent.jpg")).await.unwrap_err();
        assert_eq!(error.0, StatusCode::NOT_FOUND);
        assert_eq!(error.1 .0["detail"], "attachment not found");
        let error = fetch(&st, Some("cody"), Some("@image:../../etc/passwd")).await.unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);
        assert!(error.1 .0["detail"].as_str().unwrap().contains("no traversal"));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The chosen scoping rule, pinned so a future change has to rewrite it on purpose (see the
    /// module header): devices pair **host-wide**, so one paired device may read any profile's
    /// attachment folders — the apps show several profiles' conversations on one device. The
    /// boundary the route does enforce is per-request: a reference naming one profile cannot be
    /// re-targeted at another, and nothing outside `images/`/`attachments/` is ever served.
    #[tokio::test]
    async fn a_paired_device_reads_any_profile_it_has_a_row_for() {
        let dir = scratch("ref-cross-profile");
        let st = Arc::new(test_state(&dir));
        let profiles_root = st.engine_home.join("profiles");
        std::fs::create_dir_all(profiles_root.join("cody").join("images")).unwrap();
        std::fs::create_dir_all(profiles_root.join("jason").join("images")).unwrap();
        std::fs::write(profiles_root.join("jason/images/upload_mine.png"), b"jason-bytes").unwrap();

        // The same bearer that reads cody reads jason: one device, several profiles.
        let response = fetch(&st, Some("jason"), Some("@image:images/upload_mine.png"))
            .await
            .expect("a paired device reads another profile's upload");
        assert_eq!(body_bytes(response).await, b"jason-bytes".to_vec());

        // The per-request rule that *is* enforced: a reference's own profile segment must be the
        // requested one, so a cody row's path cannot be pasted as a jason request (and vice versa).
        let cody_ref = "@image:/root/.hermes/profiles/cody/images/upload_x.png";
        let error = fetch(&st, Some("jason"), Some(cody_ref)).await.unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);

        // And the folders themselves stay the boundary: outside them it is a refusal, whoever asks.
        let error = fetch(&st, Some("jason"), Some("@file:../hermeyd/bridge.db")).await.unwrap_err();
        assert_eq!(error.0, StatusCode::UNPROCESSABLE_ENTITY);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
