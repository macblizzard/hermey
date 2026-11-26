//! A bot's own documents: what it remembers (`memories/MEMORY.md` + `USER.md`) and the owner's note
//! (`NOTES.md`).
//!
//! ```text
//! GET /v1/bots/{profile}/memory         -> 200 {memory: {…}, user: {…}}
//! GET /v1/bots/{profile}/memory/{name}  -> 200 {name, label, text, chars, bytes, limit, present, modified_at}
//!                                       -> 422 {"detail": "a memory document is MEMORY.md or USER.md, …"}
//! PUT /v1/bots/{profile}/memory/{name}  -> 200 {name, label, text, chars, bytes, limit, present, modified_at}
//!                                       -> 422 {"detail": "a memory document is MEMORY.md or USER.md, …"}
//!                                       -> 404 {"detail": "no such bot"}
//!                                       -> 413 {"detail": "that document is larger than 262144 bytes …"}
//!                                       -> 409 {"detail": "MEMORY.md would hold … of a …-character budget …"}
//! ```
//!
//! Read straight off the engine's profile directory — these files *are* the agent's memory, so a copy
//! anywhere else would be a second truth. Guards that matter: the profile name must be a plain name
//! (no traversal), the document name must be one of exactly two literals (never a path), and a symlink
//! is refused rather than followed (a link named MEMORY.md must not be able to hand a device any host
//! file, nor receive a write aimed through it).
//!
//! **The document name is an allow-list, not a path.** `DOCUMENTS` is the whole of what the memory
//! routes can open: every one of them resolves the name through `document_spec` and answers 422,
//! naming the two files, for anything else. No caller's string is joined onto a directory, so there is
//! no traversal to defend against — a request cannot express one.
//!
//! **The budget is the runtime's, not this module's.** `tools/memory_tool_store.py` counts a document
//! as its entries joined by `ENTRY_DELIMITER` after each is stripped, against
//! `memory.memory_char_limit` / `memory.user_char_limit` — the same keys `agent/agent_init.py` hands to
//! `MemoryStore` (2200 / 1375 unless the bot's `config.yaml` overrides them). `counted` below is that
//! function, so the number the pane shows is the number the memory tool enforces. A save is refused
//! *before* the file is touched, with the limit and the overage in the sentence; nothing is truncated.
//!
//! **A memory write is a temp file and a rename**, never an in-place truncation: the agent may read
//! this file on a turn that starts mid-save, and a half-written memory is worse than the previous one.
//! The document's own mode is preserved (0600 for one that does not exist yet) because these files are
//! the bot's private notes. `NOTES.md` keeps its own writer below, which has always done the same.

use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

/// The largest memory document this host will accept, in bytes.
///
/// A memory file is replayed into every turn, so an enormous one is a cost the owner did not choose.
/// 256 KiB sits far above any real memory (the runtime's own budget caps the *counted* text at a few
/// thousand characters): this bounds a request, it does not shape a memory.
pub const MAX_DOCUMENT_BYTES: usize = 256 * 1024;

/// The separator the runtime joins entries with. A document is stored as its entries joined by this,
/// so the count a save is measured against splits on it too — see `counted`.
const ENTRY_DELIMITER: &str = "\n§\n";

/// The two limits the runtime falls back to when a profile's `config.yaml` says nothing.
const DEFAULT_MEMORY_LIMIT: u64 = 2200;
const DEFAULT_USER_LIMIT: u64 = 1375;

/// Every memory document this module can read or write: file name, the runtime's target name, and the
/// line the pane prints under the heading.
const DOCUMENTS: [(&str, &str, &str); 2] = [
    ("MEMORY.md", "memory", "What it noted for itself"),
    ("USER.md", "user", "What it knows about you"),
];

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

/// The allow-list's only door: a document name resolves to its runtime target and label, or to nothing.
///
/// Deliberately an equality match over two literals. `../MEMORY.md`, `..%2FMEMORY.md` and
/// `MEMORY.md/../USER.md` all fail here for the same reason — none of them *is* `MEMORY.md`.
fn document_spec(name: &str) -> Option<(&'static str, &'static str)> {
    DOCUMENTS
        .iter()
        .find(|(file, _, _)| *file == name)
        .map(|(_, target, label)| (*target, *label))
}

/// The sentence a refused name answers with: what *is* accepted, by name.
fn names_sentence() -> String {
    format!(
        "a memory document is {} or {}; nothing else is readable or writable here",
        DOCUMENTS[0].0, DOCUMENTS[1].0
    )
}

fn document_path(dir: &FsPath, name: &str) -> PathBuf {
    dir.join("memories").join(name)
}

/// The runtime's character count for a document.
///
/// `MemoryStore._char_count` is `len(ENTRY_DELIMITER.join(entries))`, where `entries` are the stripped,
/// non-empty halves of the raw file. Reproduced here so the pane's number is the memory tool's number:
/// counting raw bytes would let a save pass this check and then be refused by the agent's own tool, or
/// the reverse — and the pane would be showing a budget nobody enforces.
fn counted(text: &str) -> usize {
    text.split(ENTRY_DELIMITER)
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect::<Vec<_>>()
        .join(ENTRY_DELIMITER)
        .chars()
        .count()
}

/// This document's character budget, from the bot's own `config.yaml`.
///
/// `memory.memory_char_limit` / `memory.user_char_limit` — exactly the keys `agent_init.rs` passes to
/// `MemoryStore`. A missing file, unparseable YAML or a non-numeric value falls back to the runtime's
/// defaults rather than refusing a save over a config this module could not read.
fn limit_for(dir: &FsPath, target: &str) -> usize {
    let fallback = if target == "user" {
        DEFAULT_USER_LIMIT
    } else {
        DEFAULT_MEMORY_LIMIT
    };
    let key = if target == "user" {
        "user_char_limit"
    } else {
        "memory_char_limit"
    };
    let text = std::fs::read_to_string(dir.join("config.yaml")).unwrap_or_default();
    let doc: serde_yaml::Value = serde_yaml::from_str(&text).unwrap_or(serde_yaml::Value::Null);
    doc.get("memory")
        .and_then(|memory| memory.get(key))
        .and_then(serde_yaml::Value::as_u64)
        .filter(|limit| *limit > 0)
        .unwrap_or(fallback) as usize
}

fn modified_at(path: &FsPath) -> Option<String> {
    std::fs::metadata(path)
        .ok()
        .and_then(|meta| meta.modified().ok())
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|age| crate::backup::iso_at(age.as_secs()))
}

/// One document, with everything the pane needs to list it and open it.
///
/// `present` and `error` are distinct on purpose: "no file yet" is ordinary for a new bot, "there is a
/// file and I could not read it" is a fault the owner may need to fix.
fn document_value(dir: &FsPath, name: &str, target: &str, label: &str) -> Value {
    let path = document_path(dir, name);
    let limit = limit_for(dir, target);
    let shape = |text: &str, present: bool, error: Option<String>| {
        let mut value = json!({
            "name": name,
            "label": label,
            "text": text,
            "chars": counted(text),
            "bytes": text.len(),
            "limit": limit,
            "present": present,
            "modified_at": modified_at(&path),
        });
        if let Some(why) = error {
            value["error"] = json!(why);
        }
        value
    };

    match std::fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_symlink() => shape(
            "",
            false,
            Some("this is a symlink, not a memory file".to_string()),
        ),
        Ok(_) => match std::fs::read_to_string(&path) {
            Ok(text) => {
                let present = !text.trim().is_empty();
                shape(&text, present, None)
            }
            Err(e) => shape("", false, Some(format!("could not read it: {e}"))),
        },
        Err(_) => shape("", false, None),
    }
}

/// Write `text` to `path` as a temp file beside it, then rename that file into place.
///
/// Two properties this exists to keep:
///
/// * **nothing is ever partially written.** The target only ever holds an old complete document or a
///   new complete document; a crash, a full disk or a failed chmod leaves the old one, because the
///   temp file never becomes the target.
/// * **the mode is the file's own.** A memory document is `0600` because it is the bot's private
///   notes; a rewrite must not widen that. One being created for the first time gets `0600`.
fn write_atomic(path: &FsPath, text: &str) -> Result<(), Fail> {
    if std::fs::symlink_metadata(path)
        .map(|meta| meta.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err(bad(
            StatusCode::CONFLICT,
            "refusing to write through a symlink",
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| bad(StatusCode::INTERNAL_SERVER_ERROR, "no memory directory"))?;
    std::fs::create_dir_all(parent)
        .map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, format!("could not prepare: {e}")))?;

    let mode = std::fs::metadata(path)
        .map(|meta| mode_of(&meta))
        .unwrap_or(0o600);
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "memory".to_string());
    let tmp = parent.join(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        crate::auth::random_token(4)
    ));

    if let Err(e) = std::fs::write(&tmp, text.as_bytes()) {
        let _ = std::fs::remove_file(&tmp);
        return Err(bad(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not write: {e}"),
        ));
    }
    set_mode(&tmp, mode);
    if let Err(e) = std::fs::rename(&tmp, path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(bad(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not save: {e}"),
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn mode_of(meta: &std::fs::Metadata) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o777
}

#[cfg(not(unix))]
fn mode_of(_meta: &std::fs::Metadata) -> u32 {
    0o600
}

fn set_mode(path: &FsPath, mode: u32) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
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
    Ok(Json(json!({
        "memory": document_value(&dir, DOCUMENTS[0].0, DOCUMENTS[0].1, DOCUMENTS[0].2),
        "user": document_value(&dir, DOCUMENTS[1].0, DOCUMENTS[1].1, DOCUMENTS[1].2),
    })))
}

/// `GET /v1/bots/{profile}/memory/{name}` — one document, read fresh.
///
/// The pane lists both in one answer and then opens one with this: between the list and the tap the
/// agent may have written, and an editor that opened the list's copy would show — and then save back —
/// what was true a minute ago.
pub async fn memory_get_one(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((profile, name)): Path<(String, String)>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let dir = profile_dir(&st, &profile)?;
    let (target, label) = document_spec(&name)
        .ok_or_else(|| bad(StatusCode::UNPROCESSABLE_ENTITY, format!("{} (got `{name}`)", names_sentence())))?;
    Ok(Json(document_value(&dir, &name, target, label)))
}

#[derive(Deserialize)]
pub struct MemoryPut {
    #[serde(default)]
    pub text: String,
}

/// `PUT /v1/bots/{profile}/memory/{name}` — the whole document, last write wins.
///
/// Whole-document on purpose: what the pane holds is the owner's text, not an operation against the
/// runtime's entry list, and applying it as a batch of adds and removes would let this route and the
/// screen it answers disagree. The runtime re-reads the file on its next memory write, so the document
/// saved here is the one the agent starts from.
pub async fn memory_put(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((profile, name)): Path<(String, String)>,
    Json(body): Json<MemoryPut>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let dir = profile_dir(&st, &profile)?;
    // The allow-list first: a name that could reach outside this bot's own documents is refused before
    // anything is looked at, so no invented path is ever joined onto a directory.
    let (target, label) = document_spec(&name)
        .ok_or_else(|| bad(StatusCode::UNPROCESSABLE_ENTITY, format!("{} (got `{name}`)", names_sentence())))?;
    if !dir.is_dir() {
        return Err(bad(StatusCode::NOT_FOUND, "no such bot"));
    }
    // Two limits, two sentences, both before the file is touched: bytes bound the request, characters
    // are the budget the runtime enforces on the document's entries.
    if body.text.len() > MAX_DOCUMENT_BYTES {
        return Err(bad(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!(
                "that document is larger than {MAX_DOCUMENT_BYTES} bytes (it is {})",
                body.text.len()
            ),
        ));
    }
    let limit = limit_for(&dir, target);
    let used = counted(&body.text);
    if used > limit {
        let over = used - limit;
        let setting = if target == "user" {
            "memory.user_char_limit"
        } else {
            "memory.memory_char_limit"
        };
        return Err(bad(
            StatusCode::CONFLICT,
            format!(
                "{name} would hold {used} characters of a {limit}-character budget, {over} over. \
                 Shorten it here, or raise {setting} in this bot's config."
            ),
        ));
    }
    write_atomic(&document_path(&dir, &name), &body.text)?;
    Ok(Json(document_value(&dir, &name, target, label)))
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


#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::header::AUTHORIZATION;
    use std::path::{Path, PathBuf};

    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";

    fn scratch(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-bot-docs-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn state(dir: &FsPath) -> Arc<AppState> {
        let engine_ws = "ws://127.0.0.1:9121/api/ws".to_string();
        let token_file = dir.join("engine.token");
        Arc::new(AppState {
            store: crate::store::Store::open(&dir.join("bridge.db")).expect("store"),
            pairing: crate::pairing::Pairing::new(600.0),
            tickets: crate::auth::Tickets::new(30.0, 300.0),
            limiter: crate::auth::RateLimiter::new(30, 60.0),
            salt: "salt-".repeat(8),
            public_host: "localhost".to_string(),
            engine_ws: engine_ws.clone(),
            engine_token_file: token_file.clone(),
            engine_auth: crate::engine_auth::EngineAuth::Required,
            engine_home: dir.join("engine"),
            home: dir.to_path_buf(),
            attachments_dir: dir.join("attachments"),
            local_token: Arc::new(crate::local_token::LocalToken::from_value(
                LOCAL,
                dir.join("local.token"),
            )),
            local_computers: Default::default(),
            browsers: Default::default(),
            display: crate::display::DisplayHub::spawn(engine_ws, Some(token_file)),
            relay_sockets: Default::default(),
            reactions: crate::reactions::Registry::in_dir(dir),
            audit: Arc::new(crate::audit::AuditLog::in_dir(dir)),
        })
    }

    fn auth() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers
            .insert(AUTHORIZATION, format!("Bearer {LOCAL}").parse().unwrap());
        headers
    }

    /// A profile with a memories directory, as the engine makes one.
    fn bot(dir: &FsPath, profile: &str) -> PathBuf {
        let home = dir.join("engine").join("profiles").join(profile);
        std::fs::create_dir_all(home.join("memories")).unwrap();
        home
    }

    fn detail(fail: &Fail) -> String {
        fail.1 .0["detail"].as_str().unwrap_or_default().to_string()
    }

    #[test]
    fn the_count_is_the_runtime_s_own_count() {
        assert_eq!(counted("hello"), 5);
        // Entries are stripped and rejoined, so padding around a separator is not budget: two one
        // character entries cost 1 + the three-character delimiter + 1.
        assert_eq!(counted("  a  \n§\n  b  "), 5, "`a`, the delimiter, `b`");
        // A lone section sign is text: only the full delimiter splits.
        assert_eq!(counted("a § b"), 5);
        assert_eq!(counted(""), 0);
        assert_eq!(
            counted("\n\n § \n\n"),
            1,
            "an entry that strips to `§` is one character, not three bytes"
        );
    }

    #[test]
    fn a_limit_comes_from_the_bot_s_own_config_or_the_runtime_default() {
        let dir = scratch("limit");
        let home = bot(&dir, "ops");
        assert_eq!(limit_for(&home, "memory"), DEFAULT_MEMORY_LIMIT as usize);
        assert_eq!(limit_for(&home, "user"), DEFAULT_USER_LIMIT as usize);

        std::fs::write(
            home.join("config.yaml"),
            "memory:\n  memory_char_limit: 4000\n  user_char_limit: 900\n",
        )
        .unwrap();
        assert_eq!(limit_for(&home, "memory"), 4000);
        assert_eq!(limit_for(&home, "user"), 900);

        // A config this module cannot parse is not a reason to refuse a save.
        std::fs::write(home.join("config.yaml"), "memory: [unclosed\n").unwrap();
        assert_eq!(limit_for(&home, "memory"), DEFAULT_MEMORY_LIMIT as usize);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn every_memory_route_refuses_a_request_with_no_device() {
        let dir = scratch("auth");
        let st = state(&dir);
        let home = bot(&dir, "ops");
        let path = home.join("memories").join("MEMORY.md");
        std::fs::write(&path, "noted").unwrap();

        let read = memory_get(State(st.clone()), HeaderMap::new(), Path("ops".into())).await;
        assert_eq!(read.unwrap_err().0, StatusCode::UNAUTHORIZED);

        let one = memory_get_one(
            State(st.clone()),
            HeaderMap::new(),
            Path(("ops".to_string(), "MEMORY.md".to_string())),
        )
        .await;
        assert_eq!(one.unwrap_err().0, StatusCode::UNAUTHORIZED);

        let write = memory_put(
            State(st.clone()),
            HeaderMap::new(),
            Path(("ops".to_string(), "MEMORY.md".to_string())),
            Json(MemoryPut { text: "x".into() }),
        )
        .await;
        assert_eq!(write.unwrap_err().0, StatusCode::UNAUTHORIZED);

        // …and the document is untouched by any of that.
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "noted");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_name_off_the_allow_list_is_a_422_that_names_the_two_files() {
        let dir = scratch("names");
        let st = state(&dir);
        bot(&dir, "ops");
        let names = [
            "..%2FMEMORY.md",
            "../MEMORY.md",
            "../../MEMORY.md",
            "MEMORY.md/../USER.md",
            "SOUL.md",
            "memory.md",
            "NOTES.md",
            "",
        ];
        for name in names {
            let fail = memory_get_one(
                State(st.clone()),
                auth(),
                Path(("ops".to_string(), name.to_string())),
            )
            .await
            .expect_err(&format!("read accepted `{name}`"));
            assert_eq!(fail.0, StatusCode::UNPROCESSABLE_ENTITY, "`{name}`");
            let why = detail(&fail);
            assert!(why.contains("MEMORY.md") && why.contains("USER.md"), "{why}");

            let fail = memory_put(
                State(st.clone()),
                auth(),
                Path(("ops".to_string(), name.to_string())),
                Json(MemoryPut {
                    text: "pwned".into(),
                }),
            )
            .await
            .unwrap_err();
            assert_eq!(fail.0, StatusCode::UNPROCESSABLE_ENTITY, "`{name}`");
        }
        // A traversal attempt created nothing anywhere.
        assert!(!dir.join("engine").join("MEMORY.md").exists());
        assert!(!dir.join("MEMORY.md").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_save_over_the_budget_is_refused_before_it_writes() {
        let dir = scratch("budget");
        let st = state(&dir);
        let home = bot(&dir, "ops");
        std::fs::write(
            home.join("config.yaml"),
            "memory:\n  memory_char_limit: 20\n  user_char_limit: 8\n",
        )
        .unwrap();
        let path = home.join("memories").join("MEMORY.md");
        std::fs::write(&path, "kept").unwrap();

        let fail = memory_put(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "MEMORY.md".to_string())),
            Json(MemoryPut {
                text: "x".repeat(25),
            }),
        )
        .await
        .expect_err("25 over a 20 limit");
        assert_eq!(fail.0, StatusCode::CONFLICT);
        let why = detail(&fail);
        assert!(
            why.contains("25") && why.contains("20") && why.contains("5 over"),
            "{why}"
        );
        assert!(why.contains("memory.memory_char_limit"), "{why}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "kept", "a refused save wrote");

        // The user budget is its own number, read from the same config.
        let fail = memory_put(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "USER.md".to_string())),
            Json(MemoryPut {
                text: "123456789".into(),
            }),
        )
        .await
        .expect_err("9 over an 8 limit");
        assert_eq!(fail.0, StatusCode::CONFLICT);
        assert!(detail(&fail).contains("9") && detail(&fail).contains("8"));
        assert!(detail(&fail).contains("memory.user_char_limit"), "{}", detail(&fail));
        assert!(!home.join("memories").join("USER.md").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_document_over_the_byte_cap_is_a_413_with_a_sentence() {
        let dir = scratch("bytes");
        let st = state(&dir);
        let home = bot(&dir, "ops");
        let path = home.join("memories").join("MEMORY.md");
        std::fs::write(&path, "kept").unwrap();

        let fail = memory_put(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "MEMORY.md".to_string())),
            Json(MemoryPut {
                text: "x".repeat(MAX_DOCUMENT_BYTES + 1),
            }),
        )
        .await
        .expect_err("over the byte cap");
        assert_eq!(fail.0, StatusCode::PAYLOAD_TOO_LARGE);
        assert!(detail(&fail).contains("262144"), "{}", detail(&fail));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "kept");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_save_replaces_the_file_by_rename_and_keeps_its_mode() {
        use std::os::unix::fs::MetadataExt;
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("atomic");
        let st = state(&dir);
        let home = bot(&dir, "ops");
        let path = home.join("memories").join("MEMORY.md");
        std::fs::write(&path, "old").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        let before_inode = std::fs::metadata(&path).unwrap().ino();

        let value = memory_put(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "MEMORY.md".to_string())),
            Json(MemoryPut {
                text: "a\n§\nb".into(),
            }),
        )
        .await
        .expect("saved");
        assert_eq!(value.0["chars"], json!(5), "`a`, the delimiter, `b`");
        assert_eq!(value.0["bytes"], json!(6), "`§` is two bytes, so six for five characters");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "a\n§\nb");
        assert_eq!(
            mode_of(&std::fs::metadata(&path).unwrap()),
            0o640,
            "the rewrite changed the file's mode"
        );
        assert_ne!(
            std::fs::metadata(&path).unwrap().ino(),
            before_inode,
            "the document was rewritten in place; a rename replaces the inode"
        );
        // And no temp file was left behind beside it.
        let leftovers: Vec<String> = std::fs::read_dir(home.join("memories"))
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "left behind: {leftovers:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_write_that_cannot_be_published_leaves_the_previous_document_whole() {
        use std::os::unix::fs::PermissionsExt;
        // Not running as root in CI: a read-only directory cannot accept the temp file, so the rename
        // never happens. Under root (this host) the mode is not enforced, so the check would be a lie —
        // skip rather than assert something the kernel ignores.
        if unsafe { libc_geteuid() } == 0 {
            return;
        }
        let dir = scratch("nopartial");
        let home = bot(&dir, "ops");
        let path = home.join("memories").join("MEMORY.md");
        std::fs::write(&path, "the previous memory").unwrap();
        let memories = home.join("memories");
        std::fs::set_permissions(&memories, std::fs::Permissions::from_mode(0o500)).unwrap();

        let attempt = write_atomic(&path, "a replacement");
        std::fs::set_permissions(&memories, std::fs::Permissions::from_mode(0o700))
            .unwrap();

        assert!(attempt.is_err(), "a write into a read-only directory succeeded");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "the previous memory",
            "a failed save damaged the document it was replacing"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn libc_geteuid() -> u32 {
        #[cfg(unix)]
        {
            // `id -u` without a libc dependency: /proc/self/status carries the effective uid.
            std::fs::read_to_string("/proc/self/status")
                .ok()
                .and_then(|status| {
                    status
                        .lines()
                        .find(|line| line.starts_with("Uid:"))
                        .and_then(|line| line.split_whitespace().nth(2).map(str::to_string))
                })
                .and_then(|uid| uid.parse().ok())
                .unwrap_or(1)
        }
        #[cfg(not(unix))]
        {
            1
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_bot_with_no_file_yet_reads_empty_and_is_created_on_first_save() {
        let dir = scratch("empty");
        let st = state(&dir);
        let home = bot(&dir, "ops");

        let value = memory_get_one(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "USER.md".to_string())),
        )
        .await
        .expect("a document with no file is not an error");
        assert_eq!(value.0["present"], json!(false));
        assert_eq!(value.0["text"], json!(""));
        assert_eq!(value.0["chars"], json!(0));
        assert_eq!(value.0["bytes"], json!(0));

        memory_put(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "USER.md".to_string())),
            Json(MemoryPut {
                text: "likes tea".into(),
            }),
        )
        .await
        .expect("the first save creates the document");
        assert_eq!(
            std::fs::read_to_string(home.join("memories").join("USER.md")).unwrap(),
            "likes tea"
        );
        assert_eq!(
            mode_of(&std::fs::metadata(home.join("memories").join("USER.md")).unwrap()),
            0o600,
            "a new memory document is owner-only"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_symlinked_document_is_refused_rather_than_followed() {
        let dir = scratch("symlink");
        let st = state(&dir);
        let home = bot(&dir, "ops");
        let outside = dir.join("outside.md");
        std::fs::write(&outside, "a host file").unwrap();
        std::os::unix::fs::symlink(&outside, home.join("memories").join("MEMORY.md")).unwrap();

        let value = memory_get_one(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "MEMORY.md".to_string())),
        )
        .await
        .expect("a read answers");
        assert_eq!(value.0["text"], json!(""), "a link was followed");
        assert!(value.0["error"].as_str().unwrap_or_default().contains("symlink"));

        let fail = memory_put(
            State(st.clone()),
            auth(),
            Path(("ops".to_string(), "MEMORY.md".to_string())),
            Json(MemoryPut {
                text: "pwned".into(),
            }),
        )
        .await
        .expect_err("a write through a link");
        assert_eq!(fail.0, StatusCode::CONFLICT);
        assert_eq!(std::fs::read_to_string(&outside).unwrap(), "a host file");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn the_list_carries_both_documents_with_their_own_budget() {
        let dir = scratch("list");
        let st = state(&dir);
        let home = bot(&dir, "ops");
        std::fs::write(home.join("config.yaml"), "memory:\n  memory_char_limit: 3000\n").unwrap();
        std::fs::write(home.join("memories").join("MEMORY.md"), "noted").unwrap();

        let value = memory_get(State(st.clone()), auth(), Path("ops".into()))
            .await
            .expect("listed");
        assert_eq!(value.0["memory"]["chars"], json!(5));
        assert_eq!(value.0["memory"]["limit"], json!(3000));
        assert_eq!(value.0["user"]["limit"], json!(1375));
        assert_eq!(value.0["user"]["present"], json!(false));
        assert!(value.0["memory"]["modified_at"].is_string());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_unknown_bot_is_a_404_on_a_write_and_never_creates_one() {
        let dir = scratch("nobot");
        let st = state(&dir);
        let fail = memory_put(
            State(st.clone()),
            auth(),
            Path(("ghost".to_string(), "MEMORY.md".to_string())),
            Json(MemoryPut { text: "hi".into() }),
        )
        .await
        .expect_err("no such bot");
        assert_eq!(fail.0, StatusCode::NOT_FOUND);
        assert!(!dir.join("engine").join("profiles").join("ghost").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
