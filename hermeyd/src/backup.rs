//! Bot backup: `GET /v1/backup` → one JSON document; `POST /v1/backup/restore` → what was created.
//!
//! The document is the same shape the production bridge exports, so a file written on one host
//! restores on the other:
//!
//! ```json
//! {"version":1,"kind":"hermey-bot-backup","exported_at":"…","host":"…",
//!  "bots":[{"profile":"aria","name":…,"description":…,"soul":…,
//!           "memory":{"memory":…,"user":…},"notes":…,"categories":[],"routines":[…]}]}
//! ```
//!
//! Restore is deliberately **additive**: it creates bots this host does not have, fills in files, and
//! never deletes or rewrites a conversation. Memory is only written when the target's file is empty —
//! a restore that clobbered a bot's accumulated memory would be worse than no restore at all.

use crate::engine_client::rpc;
use crate::routes::{require_device, AppState};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

const VERSION: i64 = 1;

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

fn valid_profile(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn profiles_root(st: &AppState) -> PathBuf {
    st.engine_home.join("profiles")
}

fn read_text(dir: &Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap_or_default()
}

/// `name:` / `description:` out of a profile's config.yaml without pulling in a YAML writer.
fn config_fields(dir: &Path) -> (Option<String>, Option<String>) {
    let text = read_text(dir, "config.yaml");
    let doc: serde_yaml::Value = serde_yaml::from_str(&text).unwrap_or(serde_yaml::Value::Null);
    let get = |key: &str| {
        doc.get(key)
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    };
    let profile = doc.get("profile");
    (
        get("name").or_else(|| {
            profile.and_then(|p| p.get("name")).and_then(|v| v.as_str()).map(|s| s.to_string())
        }),
        get("description").or_else(|| {
            profile.and_then(|p| p.get("description")).and_then(|v| v.as_str()).map(|s| s.to_string())
        }),
    )
}

fn engine_token(st: &AppState) -> Option<String> {
    std::fs::read_to_string(&st.engine_token_file).ok().map(|s| s.trim().to_string())
}

async fn routines_for(st: &AppState, profile: &str) -> Vec<Value> {
    let Ok(result) = rpc(
        &st.engine_ws,
        engine_token(st),
        "cron.manage",
        json!({"action": "list", "profile": profile, "include_disabled": true}),
    )
    .await
    else {
        return vec![];
    };
    result
        .get("jobs")
        .and_then(|j| j.as_array())
        .map(|jobs| {
            jobs.iter()
                .map(|j| {
                    json!({
                        "name": j.get("name"),
                        "schedule": j.get("schedule"),
                        "prompt": j.get("prompt"),
                        "paused": j.get("state").and_then(|s| s.as_str()) == Some("paused")
                            || j.get("enabled").and_then(|e| e.as_bool()) == Some(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub async fn export(State(st): State<Arc<AppState>>, headers: HeaderMap) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    Ok(Json(document(&st).await))
}

/// The document itself, without the HTTP wrapper: `/v1/backup.zip` ships exactly this, so the two
/// routes can never drift into two different ideas of what a backup is.
pub(crate) async fn document(st: &AppState) -> Value {
    let root = profiles_root(st);
    let mut bots: Vec<Value> = Vec::new();
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)
        .map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect())
        .unwrap_or_default();
    dirs.sort();

    for dir in dirs {
        let Some(profile) = dir.file_name().and_then(|n| n.to_str()).map(str::to_string) else { continue };
        if !valid_profile(&profile) || profile.starts_with('.') {
            continue;
        }
        let (name, description) = config_fields(&dir);
        bots.push(json!({
            "profile": profile,
            "name": name.unwrap_or_else(|| profile.clone()),
            "description": description,
            "soul": read_text(&dir, "SOUL.md"),
            "memory": {
                "memory": read_text(&dir, "memories/MEMORY.md"),
                "user": read_text(&dir, "memories/USER.md"),
            },
            "notes": read_text(&dir, "NOTES.md"),
            "categories": [],
            "routines": routines_for(st, &profile).await,
        }));
    }

    let host = std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "hermey".to_string());

    json!({
        "version": VERSION,
        "kind": "hermey-bot-backup",
        "exported_at": now_iso(),
        "host": host,
        "bots": bots,
        "categories": [],
    })
}

pub(crate) fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    iso_at(secs)
}

/// Epoch seconds → `YYYY-MM-DDTHH:MM:SSZ`. Shared because the app decodes several timestamps with
/// `.iso8601`: an epoch float there fails the whole document, not just the field.
pub(crate) fn iso_at(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, (rem % 3600) / 60, rem % 60)
}

fn write_if_missing(dir: &Path, relative: &str, text: &str, overwrite: bool) -> bool {
    if text.is_empty() {
        return false;
    }
    let path = dir.join(relative);
    let existing = std::fs::read_to_string(&path).ok();
    match existing.as_deref() {
        // Identical content is not a write: restoring the document you just exported must report
        // "skipped", not rewrite every file and claim it changed something.
        Some(current) if current == text => return false,
        Some(current) if !overwrite && !current.trim().is_empty() => {
            return false; // never clobber accumulated content
        }
        _ => {}
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, text).is_ok()
}

pub async fn restore(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(document): Json<Value>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if document.get("kind").and_then(|k| k.as_str()) != Some("hermey-bot-backup") {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "that is not a Hermey bot backup"));
    }
    let Some(bots) = document.get("bots").and_then(|b| b.as_array()) else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "the document has no bots"));
    };

    let root = profiles_root(&st);
    let mut created: Vec<Value> = Vec::new();
    let mut updated: Vec<Value> = Vec::new();
    let mut skipped: Vec<Value> = Vec::new();
    let mut routines_added = 0usize;

    for bot in bots {
        let profile = bot.get("profile").and_then(|p| p.as_str()).unwrap_or("").to_string();
        if !valid_profile(&profile) {
            skipped.push(json!({"profile": profile, "reason": "not a valid bot name"}));
            continue;
        }
        let dir = root.join(&profile);
        let is_new = !dir.join("config.yaml").exists();

        if is_new {
            if std::fs::create_dir_all(&dir).is_err() {
                skipped.push(json!({"profile": profile, "reason": "could not create the directory"}));
                continue;
            }
            let name = bot.get("name").and_then(|n| n.as_str()).unwrap_or(&profile).to_string();
            let mut cfg = Map::new();
            cfg.insert("name".into(), json!(name));
            if let Some(description) = bot.get("description").and_then(|d| d.as_str()) {
                if !description.trim().is_empty() {
                    cfg.insert("description".into(), json!(description));
                }
            }
            let rendered = serde_yaml::to_string(&Value::Object(cfg)).unwrap_or_default();
            let _ = std::fs::write(dir.join("config.yaml"), rendered);
            write_if_missing(&dir, "SOUL.md", bot.get("soul").and_then(|s| s.as_str()).unwrap_or(""), true);
            created.push(json!({"profile": profile, "by": "backup"}));
        } else {
            let mut wrote: Vec<String> = Vec::new();
            if write_if_missing(&dir, "SOUL.md", bot.get("soul").and_then(|s| s.as_str()).unwrap_or(""), true) {
                wrote.push("SOUL.md".into());
            }
            if write_if_missing(&dir, "NOTES.md", bot.get("notes").and_then(|n| n.as_str()).unwrap_or(""), false) {
                wrote.push("NOTES.md".into());
            }
            let memory = bot.get("memory").cloned().unwrap_or(Value::Null);
            if write_if_missing(&dir, "memories/MEMORY.md",
                                memory.get("memory").and_then(|m| m.as_str()).unwrap_or(""), false) {
                wrote.push("memories/MEMORY.md".into());
            }
            if write_if_missing(&dir, "memories/USER.md",
                                memory.get("user").and_then(|m| m.as_str()).unwrap_or(""), false) {
                wrote.push("memories/USER.md".into());
            }
            if wrote.is_empty() {
                skipped.push(json!({"profile": profile, "reason": "already up to date"}));
            } else {
                updated.push(json!({"profile": profile, "wrote": wrote}));
            }
        }

        // Schedules: additive, and only for bots the document carries them for.
        if let Some(routines) = bot.get("routines").and_then(|r| r.as_array()) {
            for routine in routines {
                let schedule = routine.get("schedule").and_then(|s| s.as_str()).unwrap_or("");
                if schedule.is_empty() {
                    continue;
                }
                let params = json!({
                    "action": "add",
                    "name": routine.get("name").and_then(|n| n.as_str()).unwrap_or(schedule),
                    "schedule": schedule,
                    "prompt": routine.get("prompt").and_then(|p| p.as_str()).unwrap_or(""),
                    "profile": profile,
                });
                if let Ok(result) = rpc(&st.engine_ws, engine_token(&st), "cron.manage", params).await {
                    if result.get("success").and_then(|s| s.as_bool()) != Some(false) {
                        routines_added += 1;
                    }
                }
            }
        }
    }

    Ok(Json(json!({
        "created": created,
        "updated": updated,
        "skipped": skipped,
        "routines_added": routines_added,
        // The engine's scheduler reads routines at boot, so a freshly written job is real after a
        // restart. Saying so is better than implying it is already running.
        "restart_required": routines_added > 0,
    })))
}

// --------------------------------------------------------------------------------------------- //
// POST /v1/backup/import — the file itself (a .zip or a bare .json), not a JSON envelope.        //
//                                                                                                //
// Mirrors bot_backup.py::import_upload + load_backup + load_document + import_backup: mode=merge //
// by default, `dry_run` plans without writing, the import is additive, and the refusals are the  //
// bridge's own: 422 for an empty file or a file that is not a Hermey backup, 413 past 8 MiB.     //
// --------------------------------------------------------------------------------------------- //

/// One file has to stay openable in a text editor (`MAX_BACKUP_BYTES` in bot_backup.py).
const MAX_BACKUP_BYTES: usize = 8 * 1024 * 1024;

/// The import format version this host reads (`BACKUP_VERSION` in bot_backup.py; also served by
/// `/v1/backup/import-prompt`, which is compiled from the same constant the bridge serves).
const IMPORT_VERSION: i64 = 2;

#[derive(Deserialize)]
pub struct ImportQuery {
    /// merge (default) | overwrite | copy — chosen by the owner, never guessed.
    #[serde(default)]
    pub mode: Option<String>,
    /// 0/1; anything but 0 plans the import without writing.
    #[serde(default)]
    pub dry_run: Option<i64>,
}

fn is_backup_version_ok(document: &Value) -> Result<(), Fail> {
    let version = document.get("version");
    let Some(version) = version else { return Ok(()) };
    let Some(version) = version.as_i64() else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "backup version is not a number"));
    };
    if version > IMPORT_VERSION {
        return Err(bad(
            StatusCode::CONFLICT,
            format!("this backup is version {version}; this bridge reads {IMPORT_VERSION}"),
        ));
    }
    Ok(())
}

/// The envelope check every path goes through before a single file is touched. Guessing at another
/// product's export is how a user ends up with a bot that looks imported and is empty.
fn check_envelope(document: Value) -> Result<Value, Fail> {
    if !document.is_object() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a backup is a JSON object"));
    }
    if document.get("kind").and_then(|k| k.as_str()) != Some("hermey-bot-backup") {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "this is not a Hermey bot backup (kind must be 'hermey-bot-backup'); import from another \
             product is not supported yet, and a guess would give you empty bots",
        ));
    }
    is_backup_version_ok(&document)?;
    Ok(document)
}

/// A backup from bytes: a .zip we (or Python) wrote, or the bare .json written before zips existed.
fn load_backup(data: &[u8]) -> Result<(Value, std::collections::HashMap<String, Vec<u8>>), Fail> {
    let mut icons = std::collections::HashMap::new();
    if data.starts_with(b"PK") {
        let entries = crate::parity_gaps::read_zip(data)
            .map_err(|e| bad(StatusCode::UNPROCESSABLE_ENTITY, e))?;
        let mut document_raw: Option<Vec<u8>> = None;
        for (name, bytes) in entries {
            if name == "backup.json" {
                document_raw = Some(bytes);
            } else if let Some(stem) = crate::parity_gaps::icon_key(&name) {
                icons.insert(stem, bytes);
            }
        }
        let Some(raw) = document_raw else {
            return Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                "this zip has no backup.json — it is not a Hermey bot backup",
            ));
        };
        let document: Value = serde_json::from_slice(&raw)
            .map_err(|_| bad(StatusCode::UNPROCESSABLE_ENTITY, "backup.json inside the zip is not JSON"))?;
        Ok((check_envelope(document)?, icons))
    } else {
        let document: Value = serde_json::from_slice(data)
            .map_err(|_| bad(StatusCode::UNPROCESSABLE_ENTITY, "that file is not JSON"))?;
        Ok((check_envelope(document)?, icons))
    }
}

/// Publish one document in a single step: a reader never sees half a soul. Temp file 0600, rename.
fn atomic_write(dir: &Path, relative: &str, text: &str) {
    let path = dir.join(relative);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = dir.join(format!(
        ".{}.{}.tmp",
        crate::auth::random_token(6),
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file")
    ));
    if std::fs::write(&tmp, text).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        if std::fs::rename(&tmp, &path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    } else {
        let _ = std::fs::remove_file(&tmp);
    }
}

/// One document as the agent reads it — but a symlink is refused, not followed: the agent can write
/// inside its own profile, so a link named `SOUL.md` must not hand the import a host file.
fn read_existing(dir: &Path, relative: &str) -> String {
    let path = dir.join(relative);
    let Ok(meta) = std::fs::symlink_metadata(&path) else { return String::new() };
    if meta.file_type().is_symlink() || !meta.is_file() {
        return String::new();
    }
    std::fs::read_to_string(&path).unwrap_or_default()
}

/// A description is one line of prose, never YAML structure: it is interpolated into config.yaml,
/// so a newline must not be able to open new keys.
fn one_line(value: Option<&str>, limit: usize) -> String {
    let text = value.unwrap_or("").split_whitespace().collect::<Vec<_>>().join(" ");
    text.chars().take(limit).collect()
}

/// The (name, schedule) pairs this profile's scheduler already holds — the import's de-duplicate
/// set, standing in for the backup ids the engine does not keep.
async fn known_jobs(st: &AppState, profile: &str) -> std::collections::HashSet<(String, String)> {
    let Ok(result) = rpc(
        &st.engine_ws,
        engine_token(st),
        "cron.manage",
        json!({"action": "list", "profile": profile, "include_disabled": true}),
    )
    .await
    else {
        return Default::default();
    };
    let Some(jobs) = result.get("jobs").and_then(|j| j.as_array()) else {
        return Default::default();
    };
    jobs.iter()
        .map(|job| {
            let schedule = match job.get("schedule") {
                Some(Value::String(s)) => s.clone(),
                Some(other) => serde_json::to_string(other).unwrap_or_default(),
                None => String::new(),
            };
            (
                job.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string(),
                schedule,
            )
        })
        .collect()
}

/// A category by name, created when this host does not have it. Ids are host-local, so a backup's
/// ids mean nothing here — the name is the identity a person recognises.
fn ensure_category(st: &AppState, name: &str) -> String {
    let cleaned: String = name.split_whitespace().collect::<Vec<_>>().join(" ");
    let cleaned: String = cleaned.chars().take(64).collect();
    if cleaned.is_empty() {
        return String::new();
    }
    let mut doc = st
        .store
        .doc_or("bot_categories", json!({"categories": [], "assignments": {}, "order": []}));
    let mut id = String::new();
    if let Some(arr) = doc["categories"].as_array() {
        for category in arr {
            if category.get("name").and_then(|n| n.as_str()).map(|n| n.to_lowercase())
                == Some(cleaned.to_lowercase())
            {
                id = category.get("id").and_then(|i| i.as_str()).unwrap_or("").to_string();
                break;
            }
        }
    }
    if id.is_empty() {
        id = crate::auth::random_token(6);
        if let Some(arr) = doc["categories"].as_array_mut() {
            arr.push(json!({"id": id, "name": cleaned}));
        }
        if let Some(order) = doc["order"].as_array_mut() {
            order.push(json!(id));
        }
    }
    st.store.set_doc("bot_categories", &doc);
    id
}

/// Bring a backup's bots onto this host — `import_backup` in bot_backup.py, minus the parts this
/// stack does differently (routines go through the engine's `cron.manage`, not a jobs.json file).
pub(crate) async fn import_backup(
    st: &AppState,
    document: Value,
    icons: std::collections::HashMap<String, Vec<u8>>,
    mode: &str,
    dry_run: bool,
) -> Result<Value, Fail> {
    if !matches!(mode, "merge" | "overwrite" | "copy") {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, format!("unknown mode '{mode}'")));
    }
    is_backup_version_ok(&document)?;
    let bots = document
        .get("bots")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let Some(bots) = bots.as_array() else {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "bots must be a list"));
    };

    let root = profiles_root(st);
    let mut created: Vec<Value> = Vec::new();
    let mut updated: Vec<Value> = Vec::new();
    let mut skipped: Vec<Value> = Vec::new();
    let mut written_docs: Vec<String> = Vec::new();
    let mut routines_added = 0usize;
    let mut icons_written: Vec<String> = Vec::new();
    let mut restart_required = false;

    // Groups first, so a bot's category id has somewhere to point. Ids are matched by name.
    let mut local_by_id: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    if let Some(categories) = document.get("categories").and_then(|c| c.as_array()) {
        for category in categories {
            if !category.is_object() {
                continue;
            }
            let name = category.get("name").and_then(|n| n.as_str()).unwrap_or("").trim();
            if name.is_empty() {
                continue;
            }
            let local = if dry_run { String::new() } else { ensure_category(st, name) };
            if !local.is_empty() {
                let backup_id = category.get("id").and_then(|i| i.as_str()).unwrap_or("").to_string();
                local_by_id.insert(backup_id, local);
            }
        }
    }

    for entry in bots {
        if !entry.is_object() {
            skipped.push(json!({"profile": null, "reason": "not an object"}));
            continue;
        }
        let wanted = entry.get("profile").and_then(|p| p.as_str()).unwrap_or("").trim().to_string();
        if !valid_profile(&wanted) {
            skipped.push(json!({"profile": wanted, "reason": "invalid profile name"}));
            continue;
        }
        let existing = root.join(&wanted).is_dir();
        let target = if existing && mode == "copy" {
            // Never touch an existing bot: it lands beside it as `name-2`.
            let mut candidate = String::new();
            for index in 2..100 {
                let name = format!("{wanted}-{index}");
                if !root.join(&name).exists() {
                    candidate = name;
                    break;
                }
            }
            if candidate.is_empty() {
                skipped.push(json!({"profile": wanted, "reason": format!("too many copies of {wanted}")}));
                continue;
            }
            candidate
        } else {
            wanted.clone()
        };
        let directory = root.join(&target);
        let creating = !directory.is_dir();

        if !dry_run && creating {
            // Make a bot that is not on this host yet, by writing the directory the engine reads.
            if std::fs::create_dir_all(&directory).is_err() {
                skipped.push(json!({"profile": target, "reason": "could not create: permission denied"}));
                continue;
            }
            let name = entry.get("name").and_then(|n| n.as_str()).unwrap_or(&target);
            let mut cfg = serde_json::Map::new();
            cfg.insert("name".into(), json!(name));
            let description = one_line(entry.get("description").and_then(|d| d.as_str()), 200);
            if !description.is_empty() {
                cfg.insert("description".into(), json!(description));
            }
            let rendered = serde_yaml::to_string(&Value::Object(cfg)).unwrap_or_default();
            atomic_write(&directory, "config.yaml", &rendered);
            let soul = entry.get("soul").and_then(|s| s.as_str()).unwrap_or("");
            if !soul.is_empty() {
                atomic_write(&directory, "SOUL.md", soul);
            }
        }
        if creating {
            let mut row = json!({"profile": target, "by": "files"});
            if target != wanted {
                row["from"] = json!(wanted);
            }
            created.push(row);
        }

        let mut wrote: Vec<String> = Vec::new();
        let memory = entry.get("memory").cloned().unwrap_or(Value::Null);
        let candidates = [
            ("SOUL.md", entry.get("soul").and_then(|s| s.as_str())),
            ("memories/MEMORY.md", memory.get("memory").and_then(|m| m.as_str())),
            ("memories/USER.md", memory.get("user").and_then(|m| m.as_str())),
            ("NOTES.md", entry.get("notes").and_then(|n| n.as_str())),
        ];
        for (relative, text) in candidates {
            let Some(text) = text else { continue };
            if text.trim().is_empty() {
                continue; // an empty string is "unknown", never an instruction to erase
            }
            let here = if creating || dry_run { String::new() } else { read_existing(&directory, relative) };
            if !here.trim().is_empty() && mode != "overwrite" {
                continue;
            }
            if !dry_run {
                atomic_write(&directory, relative, text);
            }
            wrote.push(relative.to_string());
        }
        if !wrote.is_empty() {
            written_docs.extend(wrote.iter().map(|name| format!("{target}/{name}")));
            if !creating {
                updated.push(json!({"profile": target, "wrote": wrote}));
            }
        }

        // Schedules: additive, and only for bots the document carries them for. The bridge writes
        // cron/jobs.json keyed by the backup's own id, so an import twice is not a duplicate; the
        // engine mints its own ids, so the closest safe rule is name + schedule.
        let mut added = 0usize;
        let routines = entry.get("routines").cloned().unwrap_or_else(|| json!([]));
        if let Some(routines) = routines.as_array() {
            if dry_run {
                added = routines.iter().filter(|r| r.is_object()).count();
            } else {
                let known = known_jobs(st, &target).await;
                for routine in routines {
                    let schedule = routine.get("schedule").and_then(|s| s.as_str()).unwrap_or("");
                    if schedule.is_empty() {
                        continue;
                    }
                    let name = routine.get("name").and_then(|n| n.as_str()).unwrap_or(schedule);
                    if known.contains(&(name.to_string(), schedule.to_string())) {
                        continue;
                    }
                    let params = json!({
                        "action": "add",
                        "name": name,
                        "schedule": schedule,
                        "prompt": routine.get("prompt").and_then(|p| p.as_str()).unwrap_or(""),
                        "profile": target,
                    });
                    if let Ok(result) = crate::engine_client::rpc(
                        &st.engine_ws,
                        engine_token(st),
                        "cron.manage",
                        params,
                    )
                    .await
                    {
                        if result.get("success").and_then(|s| s.as_bool()) != Some(false) {
                            added += 1;
                        }
                    }
                }
            }
        }
        if added > 0 {
            routines_added += added;
            restart_required = true;
        }

        let icon = icons.get(&wanted).or_else(|| icons.get(&target)).cloned();
        if let Some(bytes) = icon {
            if !dry_run {
                let dir = crate::parity_gaps::icon_dir(st);
                let path = dir.join(format!("{target}.png"));
                if crate::parity_gaps::write_private_atomic(&dir, &path, &bytes).is_err() {
                    skipped.push(json!({"profile": target, "reason": "icon could not be written"}));
                }
            }
            icons_written.push(target.clone());
        }

        let enabled = entry.get("enabled");
        if enabled.and_then(|e| e.as_bool()) == Some(false) && !dry_run {
            let mut doc = st.store.doc_or("bots_disabled", json!({"disabled": []}));
            if let Some(arr) = doc["disabled"].as_array_mut() {
                if !arr.iter().any(|v| v.as_str() == Some(target.as_str())) {
                    arr.push(json!(target));
                }
            }
            st.store.set_doc("bots_disabled", &doc);
        }

        let wanted_categories: Vec<String> = entry
            .get("categories")
            .and_then(|c| c.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|c| c.as_str())
                    .filter(|c| !c.is_empty())
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        if let Some(first) = wanted_categories.first() {
            if dry_run {
                continue;
            }
            let Some(local) = local_by_id.get(first) else {
                skipped.push(json!({
                    "profile": target,
                    "reason": "the backup names a category it does not carry",
                }));
                continue;
            };
            let mut doc = st
                .store
                .doc_or("bot_categories", json!({"categories": [], "assignments": {}, "order": []}));
            if let Some(map) = doc["assignments"].as_object_mut() {
                map.insert(target.clone(), json!(local));
            }
            st.store.set_doc("bot_categories", &doc);
        }
    }

    Ok(json!({
        "mode": mode,
        "dry_run": dry_run,
        "created": created,
        "updated": updated,
        "skipped": skipped,
        "documents": written_docs,
        "icons": icons_written,
        "routines_added": routines_added,
        "restart_required": restart_required,
        "restored_at": now_iso(),
    }))
}

/// `POST /v1/backup/import` — take a .zip (or the older bare .json) and bring its bots onto this
/// host. The body is the file itself, not a JSON envelope around it: the app hands over exactly
/// what it saved, and a 12 MB zip does not get base64-inflated on the way.
pub async fn import(
    State(st): State<Arc<AppState>>,
    axum::extract::Query(query): axum::extract::Query<ImportQuery>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if body.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "an empty file is not a backup"));
    }
    if body.len() > MAX_BACKUP_BYTES {
        return Err(bad(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!("this file is {} bytes; the limit is {MAX_BACKUP_BYTES}", body.len()),
        ));
    }
    let (document, icons) = load_backup(&body)?;
    let mode = query.mode.as_deref().unwrap_or("merge");
    let dry_run = query.dry_run.unwrap_or(0) != 0;
    Ok(Json(import_backup(&st, document, icons, mode, dry_run).await?))
}
