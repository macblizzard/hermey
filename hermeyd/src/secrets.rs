//! The host's secret store: what the owner types into a card, kept where only the host can read it.
//!
//! ```text
//! <state>/secrets.json      0600, one JSON object { "<name>": "<value>" }
//! ```
//!
//! This is the destination a *stored* credential card writes to (`credentials.rs` `store: true`) and
//! the one place `browser.rs` reads when a fill names a secret instead of carrying one. The rules that
//! keep it a store and not a leak:
//!
//! * **No route reads it.** Nothing in the HTTP surface returns a value. Two doors write one — a
//!   `store`-mode credential card's answer (`/v1/credentials/cards/{id}/answer`) and an edit of an item
//!   that already exists (`PATCH /v1/vault/{name}`, `edit` below) — and both go through `save`. The only
//!   reader is a `fill` instruction, whose reply is the extension's own field names and booleans — never
//!   a value.
//! * **A name, not a value, is what leaves here.** A bot learns `<site>/<field>` (an item label) and
//!   can ask for a fill by that name; it never receives the text behind it.
//! * **Owner-only, atomic.** The file is created `0600` (the same posture as `local.token` and
//!   `bridge.db`), written to a temp file in the same directory and renamed, so a reader never sees a
//!   half-written store and a crash cannot truncate every secret at once.
//! * **Nothing is logged.** No function here prints, audits, or formats a value into a message. The
//!   audit records live in `credentials.rs` and are scalar-only by construction.
//! * **A corrupt store is refused, not overwritten.** An unparsable file is an error on write, so the
//!   next card cannot silently replace a vault it could not read.

use crate::routes::AppState;
use serde_json::{Map, Value};
use std::path::PathBuf;

/// What an edit did, so the route above it can give each answer its own code.
///
/// Three cases, and none of them carries a value: an edit that reported *what* it moved would be the
/// read-back this store exists not to have.
#[derive(Debug, PartialEq, Eq)]
pub enum EditOutcome {
    /// The name — and, when one was given, the value — changed, in one write.
    Changed,
    /// Nothing is stored under the old name.
    Missing,
    /// Another secret already holds the new name.
    Taken,
}

/// Longest single value. A password or an API key is a line, not a document; 4 KB is generous for a
/// PEM key and still far below anything that could bloat the store or a card document.
pub const MAX_VALUE_BYTES: usize = 4096;

/// Longest name. `<site>/<field>` is the shape this module mints, and 96 characters holds the longest
/// hostname in a certificate with room to spare.
pub const MAX_NAME_BYTES: usize = 96;

/// Field names the host treats as ordinary, visible text. Everything else is masked in the app —
/// defaulting to masked is what makes a field called "api key" safe without a new list to maintain.
pub const PLAIN_FIELDS: &[&str] = &["username", "user", "email", "site", "host", "account", "login"];

/// Where the store lives: beside `bridge.db` and `local.token`, in the service's state directory.
pub fn path(st: &AppState) -> PathBuf {
    st.home.join("secrets.json")
}

/// `Doctolib.DE` + `one-time code` -> `doctolib.de/one-time-code`.
///
/// The site is the card's own `site` (an origin the owner saw on the card), and the field is whatever
/// the card asked for. Everything outside `[a-z0-9._-]` becomes `-`, so a name is always one printable
/// token: no spaces, no slashes beyond the one separator, nothing that could be read as a path.
pub fn name_for(site: &str, field: &str) -> String {
    fn slug(text: &str) -> String {
        let mut out = String::with_capacity(text.len());
        for ch in text.chars() {
            let lower = ch.to_ascii_lowercase();
            if lower.is_ascii_alphanumeric() || lower == '.' || lower == '_' || lower == '-' {
                out.push(lower);
            } else if !out.ends_with('-') {
                out.push('-');
            }
        }
        out.trim_matches('-').to_string()
    }
    let site = slug(site);
    let field = slug(field);
    let mut name = if site.is_empty() { field } else if field.is_empty() { site } else { format!("{site}/{field}") };
    if name.len() > MAX_NAME_BYTES {
        name.truncate(MAX_NAME_BYTES);
        name = name.trim_end_matches(|c: char| c == '-' || c == '/' || c == '.').to_string();
    }
    name
}

/// Is this a name the store will hold? One separator at most, printable, bounded — the same guard a
/// `save_as` from a bot has to pass before a card can promise the owner it will be saved.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME_BYTES
        && !name.starts_with('/')
        && !name.ends_with('/')
        && !name.contains("//")
        && !name.contains("..")
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' || c == '/')
}

/// True when the app should mask this field. Unknown names are masked: the safe answer is the default.
pub fn is_masked(field: &str) -> bool {
    !PLAIN_FIELDS.contains(&field.trim().to_ascii_lowercase().as_str())
}

/// The fields of a card that the apps must draw as masked inputs.
pub fn masked_fields(fields: &[String]) -> Vec<String> {
    fields.iter().filter(|f| is_masked(f)).cloned().collect()
}

/// The whole store, or an empty map when there is no file yet.
///
/// A file that exists but cannot be parsed is an **error**: reporting it as empty would let the next
/// write replace every secret the owner ever saved.
fn load(st: &AppState) -> Result<Map<String, Value>, String> {
    let file = path(st);
    let text = match std::fs::read_to_string(&file) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(err) => return Err(format!("the secret store is unreadable: {}", err.kind())),
    };
    if text.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Object(map)) => Ok(map),
        _ => Err("the secret store is not readable JSON; nothing was written".to_string()),
    }
}

/// Publish the store in one step: temp file in the same directory, `0600`, then rename.
fn save(st: &AppState, map: &Map<String, Value>) -> Result<(), String> {
    let file = path(st);
    let dir = file.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| PathBuf::from("."));
    if let Err(err) = std::fs::create_dir_all(&dir) {
        return Err(format!("the secret store's directory could not be created: {}", err.kind()));
    }
    let tmp = dir.join(format!(".secrets.{}.tmp", std::process::id()));
    let bytes = Value::Object(map.clone()).to_string();
    if let Err(err) = std::fs::write(&tmp, bytes) {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("the secret store could not be written: {}", err.kind()));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
    }
    if let Err(err) = std::fs::rename(&tmp, &file) {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("the secret store could not be replaced: {}", err.kind()));
    }
    Ok(())
}

/// Store one value under one name, replacing a previous value for the same name.
///
/// The error strings name the reason and the *name*, never the value: they travel back to an app and
/// into an audit-free log, so nothing here may echo what was typed.
pub fn put(st: &AppState, name: &str, value: &str) -> Result<(), String> {
    if !valid_name(name) {
        return Err(format!(
            "a secret name is letters, digits, '.', '_', '-' and one '/', up to {MAX_NAME_BYTES} characters"
        ));
    }
    if value.is_empty() {
        return Err("nothing to store: the value was empty".to_string());
    }
    if value.len() > MAX_VALUE_BYTES {
        return Err(format!("that value is larger than {MAX_VALUE_BYTES} bytes"));
    }
    let mut map = load(st)?;
    map.insert(name.to_string(), Value::String(value.to_string()));
    save(st, &map)
}

/// Change a secret's name, and its value when a new one is given — in one write.
///
/// This is the only function that moves a value from one key to another, and it lives here rather than
/// in `vault.rs` for the same reason `put` does: the route above it can neither see nor echo a value, so
/// the bytes have to be handled by the module that owns them. `None` keeps the value under the old name,
/// which is what a rename alone asks for; `Some` replaces it. Both happen on one map and are published by
/// **one** `save` — the same temp-file-then-rename an add uses — so a rename whose value write fails
/// cannot leave half an item behind, and a crash leaves the old item whole.
///
/// Refusals name the reason and the *name*; nothing here formats, returns or logs a value.
pub fn edit(st: &AppState, from: &str, to: &str, value: Option<&str>) -> Result<EditOutcome, String> {
    if !valid_name(from) || !valid_name(to) {
        return Err(format!(
            "a secret name is letters, digits, '.', '_', '-' and one '/', up to {MAX_NAME_BYTES} characters"
        ));
    }
    if let Some(text) = value {
        if text.is_empty() {
            return Err("nothing to store: the value was empty".to_string());
        }
        if text.len() > MAX_VALUE_BYTES {
            return Err(format!("that value is larger than {MAX_VALUE_BYTES} bytes"));
        }
    }
    let mut map = load(st)?;
    // Taken out of the map first, so the collision test below cannot see the item it is replacing.
    let Some(current) = map.remove(from) else {
        return Ok(EditOutcome::Missing);
    };
    if map.contains_key(to) {
        // Nothing was written: the store on disk never learned about this attempt.
        return Ok(EditOutcome::Taken);
    }
    let next = match value {
        Some(text) => Value::String(text.to_string()),
        None => current,
    };
    map.insert(to.to_string(), next);
    save(st, &map)?;
    Ok(EditOutcome::Changed)
}

/// The value behind a name, for a fill. `None` for a name that was never stored.
pub fn get(st: &AppState, name: &str) -> Option<String> {
    if !valid_name(name) {
        return None;
    }
    load(st).ok()?.get(name)?.as_str().map(str::to_string)
}

/// Whether a name is stored — for an acknowledgement or a test, never for a value.
pub fn has(st: &AppState, name: &str) -> bool {
    get(st, name).is_some()
}

/// Every name in the store, sorted — the only shape of this store a route may serve.
///
/// Names are not secrets: a name is what a bot is allowed to know (it is how a fill is asked for), and
/// it is the whole of what the owner's Vault pane lists. Returning names rather than the map is
/// deliberate: there is no value in the return type, so no caller can print one.
pub fn names(st: &AppState) -> Result<Vec<String>, String> {
    let mut out: Vec<String> = load(st)?.into_iter().map(|(name, _)| name).collect();
    out.sort();
    Ok(out)
}

/// Forget one name. `Ok(true)` removed it, `Ok(false)` means it was never there, and a name the store
/// would not hold is an error — the same three answers the route has to tell apart.
///
/// The value is dropped with the name: the store is rewritten whole from the map minus this key, so
/// the bytes that held it are replaced rather than shadowed.
pub fn remove(st: &AppState, name: &str) -> Result<bool, String> {
    if !valid_name(name) {
        return Err(format!(
            "a secret name is letters, digits, '.', '_', '-' and one '/', up to {MAX_NAME_BYTES} characters"
        ));
    }
    let mut map = load(st)?;
    if map.remove(name).is_none() {
        return Ok(false);
    }
    save(st, &map)?;
    Ok(true)
}

/// When the store as a whole was last written, as Unix seconds.
///
/// Entries carry no date of their own (the file is a name→value map and stays one), so an entry that
/// predates the vault's index — or was written by a path that kept no index — is dated by the file it
/// lives in. That is an approximation and the pane shows it as a date, not a claim about one write.
pub fn modified_at(st: &AppState) -> Option<f64> {
    let meta = std::fs::metadata(path(st)).ok()?;
    let modified = meta.modified().ok()?;
    modified
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs_f64())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::Tickets;
    use crate::pairing::Pairing;
    use crate::routes::AppState;
    use crate::store::Store;
    use std::path::Path;
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";
    const VALUE: &str = "«redacted:sk-…»";

    fn scratch(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-secrets-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn state(dir: &Path) -> Arc<AppState> {
        let engine_ws = "ws://127.0.0.1:9121/api/ws".to_string();
        let token_file = dir.join("engine.token");
        Arc::new(AppState {
            store: Store::open(&dir.join("bridge.db")).expect("store"),
            pairing: Pairing::new(600.0),
            tickets: Tickets::new(30.0, 300.0),
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

    #[test]
    fn a_name_is_one_printable_token() {
        assert_eq!(name_for("Doctolib.DE", "one-time code"), "doctolib.de/one-time-code");
        assert_eq!(name_for("doctolib.de", "password"), "doctolib.de/password");
        assert_eq!(name_for("api.openai.com", "API key"), "api.openai.com/api-key");
        // No scheme, no port colon, no whitespace: an origin is reduced to something a shell and a
        // JSON key can both hold.
        assert_eq!(name_for("https://x.test:8443", "password"), "https-x.test-8443/password");
        assert_eq!(name_for("", "password"), "password");
        let long = name_for(&"a".repeat(300), "password");
        assert!(long.len() <= MAX_NAME_BYTES, "{long}");
        assert!(valid_name(&long), "{long}");
    }

    #[tokio::test]
    async fn the_guards_refuse_what_could_be_a_path_or_a_flood() {
        for name in ["", "/etc/passwd", "a//b", "../x", "a/../b", "a b", "café"] {
            assert!(!valid_name(name), "{name:?} must be refused");
        }
        assert!(valid_name("doctolib.de/password"));
        assert!(!valid_name(&"a".repeat(MAX_NAME_BYTES + 1)));

        let dir = scratch("guards");
        let st = state(&dir);
        assert!(put(&st, "a/../b", VALUE).is_err());
        assert!(put(&st, "ok/name", "").is_err(), "an empty value is not stored");
        let huge = "x".repeat(MAX_VALUE_BYTES + 1);
        let err = put(&st, "ok/name", &huge).unwrap_err();
        assert!(!err.contains("xxxx"), "the refusal must not quote the value: {err}");
        assert!(!has(&st, "ok/name"), "nothing was stored by a refused write");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The file the owner's secret lands in is owner-only, and it is not a temp file that stays.
    #[cfg(unix)]
    #[tokio::test]
    async fn the_store_is_owner_only_and_written_in_one_step() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("mode");
        let st = state(&dir);
        put(&st, "doctolib.de/password", VALUE).expect("stored");

        let file = path(&st);
        assert!(file.is_file());
        let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the store must be owner-only, was {mode:o}");
        // The temp file is renamed away, never left beside the store.
        let leftovers: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.starts_with(".secrets."))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");

        // A second write keeps the first: this is a store, not a slot.
        put(&st, "api.openai.com/api-key", "sk-second").expect("stored");
        assert_eq!(get(&st, "doctolib.de/password").as_deref(), Some(VALUE));
        assert_eq!(get(&st, "api.openai.com/api-key").as_deref(), Some("sk-second"));
        // …and replacing one leaves the other alone.
        put(&st, "doctolib.de/password", "new-value").expect("replaced");
        assert_eq!(get(&st, "doctolib.de/password").as_deref(), Some("new-value"));
        assert_eq!(get(&st, "api.openai.com/api-key").as_deref(), Some("sk-second"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A corrupt store is refused rather than silently emptied, so the next card cannot destroy a
    /// vault it could not read.
    #[tokio::test]
    async fn a_corrupt_store_refuses_a_write_instead_of_replacing_it() {
        let dir = scratch("corrupt");
        let st = state(&dir);
        put(&st, "doctolib.de/password", VALUE).expect("stored");
        std::fs::write(path(&st), "{not json").unwrap();

        let err = put(&st, "api.openai.com/api-key", "sk-second").unwrap_err();
        assert!(!err.contains(VALUE), "the refusal must not quote anything: {err}");
        assert!(err.contains("not readable JSON"), "{err}");
        // The corrupt bytes are still there: nothing was overwritten.
        assert_eq!(std::fs::read_to_string(path(&st)).unwrap(), "{not json");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The store's own edit: one map, one write, and an outcome that says which case happened without
    /// ever naming a value.
    #[cfg(unix)]
    #[tokio::test]
    async fn an_edit_moves_the_name_and_the_value_in_one_write() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("edit");
        let st = state(&dir);
        put(&st, "doctolib.de/password", VALUE).expect("stored");

        assert_eq!(
            edit(&st, "doctolib.de/password", "doctolib.de/login", Some("new-value")),
            Ok(EditOutcome::Changed)
        );
        assert_eq!(get(&st, "doctolib.de/login").as_deref(), Some("new-value"));
        assert!(!has(&st, "doctolib.de/password"), "the old name kept its value");

        // `None` is a rename that leaves the value alone — the same request an edit sheet with a blank
        // field makes.
        assert_eq!(
            edit(&st, "doctolib.de/login", "doctolib.de/primary", None),
            Ok(EditOutcome::Changed)
        );
        assert_eq!(get(&st, "doctolib.de/primary").as_deref(), Some("new-value"));

        // A name another secret holds is refused, and nothing is written for it.
        put(&st, "api.openai.com/api-key", "sk-second").expect("stored");
        assert_eq!(
            edit(&st, "doctolib.de/primary", "api.openai.com/api-key", Some("third")),
            Ok(EditOutcome::Taken)
        );
        assert_eq!(get(&st, "doctolib.de/primary").as_deref(), Some("new-value"));
        assert_eq!(get(&st, "api.openai.com/api-key").as_deref(), Some("sk-second"));

        // Nobody saved that: Missing, and no item appeared.
        assert_eq!(
            edit(&st, "no.such/name", "somewhere.else", Some("x")),
            Ok(EditOutcome::Missing)
        );
        assert!(!has(&st, "somewhere.else"));

        // An empty replacement is the create rule, not a wipe: refused, and the value stays.
        assert!(edit(&st, "doctolib.de/primary", "doctolib.de/primary", Some("")).is_err());
        assert_eq!(get(&st, "doctolib.de/primary").as_deref(), Some("new-value"));

        // An edit lands in the same file an add does: owner-only, and no temp file left beside it.
        let mode = std::fs::metadata(path(&st)).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "an edit must not loosen the store, was {mode:o}");
        let leftovers: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.starts_with(".secrets."))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_masked_field_is_the_default_and_the_plain_ones_are_named() {
        for field in ["password", "api key", "one-time code", "token", "PIN", "secret"] {
            assert!(is_masked(field), "{field} must be masked");
        }
        for field in ["username", "Email", "site", "host"] {
            assert!(!is_masked(field), "{field} is ordinary text");
        }
        let fields = vec!["username".to_string(), "password".to_string(), "api key".to_string()];
        assert_eq!(masked_fields(&fields), vec!["password".to_string(), "api key".to_string()]);
    }

    #[tokio::test]
    async fn a_value_never_appears_in_any_answer() {
        let dir = scratch("echo");
        let st = state(&dir);
        put(&st, "doctolib.de/password", VALUE).expect("stored");
        // What a caller can see: the name, and whether it exists.
        assert!(has(&st, "doctolib.de/password"));
        assert!(!has(&st, "doctolib.de/nope"));
        // The store's own file is the one place the value lives.
        let on_disk = std::fs::read_to_string(path(&st)).unwrap();
        assert!(on_disk.contains(VALUE), "the value is in the store, and only there");
        let _ = std::fs::remove_dir_all(&dir);
    }
}