//! Bot-to-bot hand-offs: `GET /v1/bot-transfers?between=a,b&limit=` → `{between:[a,b], entries:[…]}`,
//! oldest first.
//!
//! The records are written by the bridge's Python side
//! (`Bridge/hermes_bridge/bot_transfers.py`): one JSON object per line, appended, *beside the bridge's
//! SQLite file* and named `bot-transfers.jsonl`:
//!
//! ```text
//! {"from_profile": null, "from_label": "cody", "to_profile": "jason",
//!  "session_id": "d8cff42a", "text": "…", "at": 1794769942.7180102}
//! ```
//!
//! That is not where this service keeps its own state. It reads `$HERMEY_HOME/bridge.db` while the
//! bridge read `HERMES_BRIDGE_DB` — on a host that ran the bridge first those are different
//! directories (`/var/lib/hermey` vs `var/hermeyd`), and the old reader looked for `transfers.jsonl`
//! under `engine_home.parent()`, which matched neither name nor place. The page was empty on a host
//! with 41 real exchanges in it.
//!
//! So the reader now searches every layout that has been seen in the field (the bridge's state dir,
//! this service's home, the engine home, the user's `~/.hermey`, `/var/lib/hermey`), under both the
//! Python filename and the old Rust one, and reads the newest non-empty match. A zero-byte file — a
//! producer that has just created it — never hides a populated one. Which file was chosen is logged
//! once (and again if it changes), so an empty page can be told from an empty file.
//!
//! `record` writes the same line the Python writer wrote, byte for byte: Python's `json.dumps`
//! defaults (`", "` and `": "` separators, `ensure_ascii=False`, insertion order) and the same key
//! order — `from_profile`, `from_label`, `to_profile`, `session_id`, `text`, `at`. `session_id` is
//! the conversation the hand-off landed in, and may be `null`; the reader keeps `null` and absent
//! alike. The file is appended to, one line per record, and rotated to `.1` past 4 MiB exactly as
//! `bot_transfers.py:52-58` did.
//!
//! Rows are returned exactly as written, with missing fields defaulted rather than dropped: `text`
//! and `to_profile` become `""`, `from_label` becomes `"assistant"` (what the app itself defaults
//! to), `at` becomes `0.0`, and unknown fields (`session_id`, and anything a later writer adds) ride
//! along untouched. Field names agree with the Python writer's, with one asymmetry worth stating:
//! the writer only fills `from_profile` when its caller supplied one, and older rows carry the
//! sender's name in `from_label` with `from_profile: null`. Matching therefore falls back to
//! `from_label` when `from_profile` is absent; matching on `from_profile` alone is why the modal
//! stayed empty even once the right file was being read.

use crate::routes::{require_device, AppState};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

type Fail = (StatusCode, Json<Value>);
const DEFAULT_LIMIT: usize = 100;
const MAX_LIMIT: usize = 500;

/// What the Python writer calls the file (`Bridge/hermes_bridge/bot_transfers.py`, `_path`).
const BRIDGE_FILENAME: &str = "bot-transfers.jsonl";
/// What this module used to read, and wrote from `record`. Kept so a host that already has one is
/// not abandoned; a file that was never written is simply not found.
const LEGACY_FILENAME: &str = "transfers.jsonl";
/// The app's own default (`BotTransfer.decodeList`), repeated here so a row without a label still
/// draws with the same attribution.
const DEFAULT_FROM_LABEL: &str = "assistant";
/// `bot_transfers.py:41` — past this the file is rotated to `.1` on the next write.
const MAX_BYTES: u64 = 4 * 1024 * 1024;
/// `text[:2000]` in `bot_transfers.py:70` — code points, not bytes.
const MAX_TEXT_CHARS: usize = 2000;

/// Every directory the records file has plausibly lived in, best-known first.
///
/// `attachments_dir` is built by `main` as `$HERMEY_HOME/attachments`, and `$HERMEY_HOME/bridge.db`
/// is this service's own state dir — the same layout the bridge used when it fell back to
/// `~/.hermey`. The bridge-specific variables come from hosts that point the bridge at a shared
/// state directory (this one uses `HERMES_BRIDGE_DB=/var/lib/hermey/bridge.db`), which is exactly
/// the file with history in it.
fn candidate_dirs(st: &AppState) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    let mut push = |p: PathBuf| {
        if !p.as_os_str().is_empty() && !dirs.iter().any(|d| d == &p) {
            dirs.push(p);
        }
    };
    // The bridge wrote beside its own database. Both spellings of "where that database is" are read
    // because the bridge and this service were configured separately.
    if let Some(db) = std::env::var_os("HERMES_BRIDGE_DB") {
        if let Some(parent) = PathBuf::from(&db).parent() {
            push(parent.to_path_buf());
        }
    }
    if let Some(dir) = std::env::var_os("HERMES_BRIDGE_STATE_DIR") {
        push(PathBuf::from(dir));
    }
    if let Some(attachments) = st.attachments_dir.parent() {
        push(attachments.to_path_buf());
    }
    if let Some(dir) = std::env::var_os("HERMEY_HOME") {
        push(PathBuf::from(dir));
    }
    // The engine home and its parent: the old reader's guess, still worth a look on a development
    // box where `var/hermey` holds both.
    if let Some(parent) = st.engine_home.parent() {
        push(parent.to_path_buf());
    }
    push(st.engine_home.clone());
    if let Some(home) = std::env::var_os("HOME") {
        push(PathBuf::from(home).join(".hermey"));
    }
    // The Debian service install's state directory (`StateDirectory=hermey`): what this host
    // actually ran the bridge under.
    push(PathBuf::from("/var/lib/hermey"));
    dirs
}

fn candidate_files(dirs: &[PathBuf]) -> Vec<PathBuf> {
    let mut files = Vec::with_capacity(dirs.len() * 2);
    for dir in dirs {
        for name in [BRIDGE_FILENAME, LEGACY_FILENAME] {
            let candidate = dir.join(name);
            if !files.contains(&candidate) {
                files.push(candidate);
            }
        }
    }
    files
}

/// The file to read: newest by mtime among the candidates that exist, but a populated file beats an
/// empty one. `None` when no candidate exists — that is a fresh host, not an error.
fn newest_existing(files: &[PathBuf]) -> Option<PathBuf> {
    let mut best: Option<(PathBuf, bool, std::time::SystemTime)> = None;
    for file in files {
        let Ok(meta) = std::fs::metadata(file) else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let non_empty = meta.len() > 0;
        let mtime = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
        let better = match &best {
            None => true,
            Some((_, best_non_empty, best_mtime)) => {
                (non_empty, mtime) > (*best_non_empty, *best_mtime)
            }
        };
        if better {
            best = Some((file.clone(), non_empty, mtime));
        }
    }
    best.map(|(path, _, _)| path)
}

/// Resolve the file and say which one was used — once, and again only if the answer changes.
/// Without this line an empty page and a missing file look identical in the logs, which is how the
/// wrong path survived.
fn transfers_file(st: &AppState) -> Option<PathBuf> {
    static LAST_LOGGED: Mutex<Option<String>> = Mutex::new(None);
    let files = candidate_files(&candidate_dirs(st));
    let chosen = newest_existing(&files);
    let message = match &chosen {
        Some(path) => format!("transfers: reading {}", path.display()),
        None => {
            let looked: Vec<String> = files.iter().map(|p| p.display().to_string()).collect();
            format!(
                "transfers: no records file yet; looked at {}",
                looked.join(", ")
            )
        }
    };
    if let Ok(mut last) = LAST_LOGGED.lock() {
        if last.as_deref() != Some(message.as_str()) {
            eprintln!("{message}");
            *last = Some(message);
        }
    }
    chosen
}

/// Where `record` appends: the file already in use, else the bridge's filename in this service's own
/// home (never the old `transfers.jsonl`, so nothing new is written where nothing reads).
fn write_path(st: &AppState) -> PathBuf {
    let files = candidate_files(&candidate_dirs(st));
    if let Some(existing) = newest_existing(&files) {
        return existing;
    }
    st.attachments_dir
        .parent()
        .map(|home| home.join(BRIDGE_FILENAME))
        .unwrap_or_else(|| PathBuf::from(BRIDGE_FILENAME))
}

#[derive(Deserialize)]
pub struct TransfersQuery {
    /// `a,b` — the two profiles whose exchanges are wanted.
    pub between: String,
    pub limit: Option<usize>,
}

/// Bring one written row to the shape the app decodes, in place: unknown fields survive, missing
/// ones are defaulted, and `at` is always a number. `None` for a line that is not an object — a
/// string or an array is not a record, and keeping it would only make the app drop it later.
fn normalise(value: Value) -> Option<Value> {
    let mut row = match value {
        Value::Object(map) => map,
        _ => return None,
    };
    let text_of = |row: &serde_json::Map<String, Value>, key: &str| -> Option<String> {
        row.get(key).and_then(Value::as_str).map(str::to_string)
    };
    let from_profile = text_of(&row, "from_profile").filter(|s| !s.is_empty());
    let from_label = text_of(&row, "from_label")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_FROM_LABEL.to_string());
    let to_profile = text_of(&row, "to_profile").unwrap_or_default();
    let text = text_of(&row, "text").unwrap_or_default();
    // The Python writer always emits a float; a string is accepted anyway (a hand-edited or
    // third-party line), and an absent or unparseable stamp sorts first rather than losing the row.
    let at = match row.get("at") {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => s.trim().parse::<f64>().unwrap_or(0.0),
        _ => 0.0,
    };
    row.insert(
        "from_profile".to_string(),
        from_profile.map(Value::String).unwrap_or(Value::Null),
    );
    row.insert("from_label".to_string(), Value::String(from_label));
    row.insert("to_profile".to_string(), Value::String(to_profile));
    row.insert("text".to_string(), Value::String(text));
    row.insert("at".to_string(), json!(at));
    Some(Value::Object(row))
}

/// Who spoke and who heard. The writer leaves `from_profile` null unless its caller named one, and
/// those rows carry the sender in `from_label`; treating the label as the sender only when the
/// profile is absent keeps a real profile authoritative while still finding the older rows.
fn participants(entry: &Value) -> (String, String) {
    let field = |key: &str| {
        entry
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let from_profile = field("from_profile");
    let from = if from_profile.is_empty() {
        field("from_label")
    } else {
        from_profile
    };
    (from, field("to_profile"))
}

/// The pair's rows, oldest first, newest `limit` of them. Pure over the file's text so the parser can
/// be tested without a service or a real home directory.
fn collect(text: &str, first: &str, second: &str, limit: usize) -> Vec<Value> {
    let mut entries: Vec<Value> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // A malformed or half-written line (an interrupted append) costs that line, not the file.
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(entry) = normalise(value) else {
            continue;
        };
        let (from, to) = participants(&entry);
        // Either direction, and only for this pair.
        if (from == first && to == second) || (from == second && to == first) {
            entries.push(entry);
        }
    }
    // Stable, so rows with the same stamp keep the order they were written in.
    entries.sort_by(|a, b| {
        let key = |v: &Value| v.get("at").and_then(Value::as_f64).unwrap_or(0.0);
        key(a)
            .partial_cmp(&key(b))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    // The newest `limit`, still oldest-first — the page reads as a conversation.
    let start = entries.len().saturating_sub(limit);
    entries.split_off(start)
}

fn read_file(path: &Path) -> String {
    // Missing, unreadable and empty are the same answer here: no rows. The modal says "nothing
    // recorded", which is true of each, and a fresh host must not 500.
    std::fs::read_to_string(path).unwrap_or_default()
}

pub async fn list_transfers(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<TransfersQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let parts: Vec<&str> = q
        .between
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();
    if parts.len() != 2 {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"detail": "between must name two bots: a,b"})),
        ));
    }
    let (first, second) = (parts[0].to_string(), parts[1].to_string());
    let limit = q.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);

    let text = transfers_file(&st)
        .map(|path| read_file(&path))
        .unwrap_or_default();
    let entries = collect(&text, &first, &second, limit);
    // `between` is what the bridge answers with, so a client that reads either host sees one shape.
    Ok(Json(
        json!({ "between": [first, second], "entries": entries }),
    ))
}

/// One line, in the Python writer's exact shape (`bot_transfers.py:65-72`).
///
/// Hand-built rather than `json!` + `to_string`: `serde_json`'s map is ordered, not insertion
/// ordered, so `json!` would reorder the keys. Field order is part of the format here — existing
/// rows and the app's reader both expect Python's.
fn line_for(
    from_profile: Option<&str>,
    from_label: &str,
    to_profile: &str,
    session_id: Option<&str>,
    text: &str,
    at: f64,
) -> String {
    let text: String = text.chars().take(MAX_TEXT_CHARS).collect();
    let quoted = |value: &str| serde_json::to_string(value).unwrap_or_else(|_| "\"\"".to_string());
    let optional = |value: Option<&str>| value.map(quoted).unwrap_or_else(|| "null".to_string());
    let at = serde_json::to_string(&at).unwrap_or_else(|_| "0.0".to_string());
    format!(
        "{{\"from_profile\": {}, \"from_label\": {}, \"to_profile\": {}, \"session_id\": {}, \"text\": {}, \"at\": {}}}",
        optional(from_profile),
        quoted(from_label),
        quoted(to_profile),
        optional(session_id),
        quoted(&text),
        at
    )
}

/// Append one line, rotating past [`MAX_BYTES`] first (`bot_transfers.py:52-79`). A rotation that
/// fails is not a reason to drop the record, so it is best effort.
fn append(path: &Path, line: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if std::fs::metadata(path).map(|meta| meta.len() > MAX_BYTES).unwrap_or(false) {
        let _ = std::fs::rename(path, path.with_extension("jsonl.1"));
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "{line}")
}

/// Append one hand-off. Public so the path that eventually produces these writes the same file and
/// format the bridge used, instead of inventing a second one.
///
/// `session_id` is the conversation the message landed in — the runtime id the engine answered
/// with — and is written as `null` when the caller has none. Python's writer took the same field
/// (`bot_message.py:121-126`).
pub fn record(
    st: &AppState,
    from_profile: Option<&str>,
    from_label: &str,
    to_profile: &str,
    session_id: Option<&str>,
    text: &str,
    at: f64,
) -> std::io::Result<()> {
    append(
        &write_path(st),
        &line_for(from_profile, from_label, to_profile, session_id, text, at),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// One real line from the live bridge's file, with `from_profile` null exactly as written.
    const PYTHON_LINE_OLD: &str = r#"{"from_profile": null, "from_label": "cody", "to_profile": "jason", "session_id": "d8cff42a", "text": "Heads up: your session-sync work was sitting uncommitted", "at": 1794769942.7180102}"#;
    const PYTHON_LINE_MIDDLE: &str = r#"{"from_profile": "jason", "from_label": "assistant", "to_profile": "cody", "session_id": "aa11", "text": "acked", "at": 1794769950.5}"#;
    const PYTHON_LINE_NEW: &str = r#"{"from_profile": null, "from_label": "cody", "to_profile": "jason", "session_id": "bb22", "text": "and the patch files are named in that note", "at": 1794769960.25}"#;

    fn fixture(name: &str, lines: &[&str]) -> (PathBuf, PathBuf) {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-transfers-{}-{}-{}",
            std::process::id(),
            name,
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let file = dir.join(BRIDGE_FILENAME);
        std::fs::write(&file, lines.join("\n") + "\n").expect("fixture");
        (dir, file)
    }

    #[test]
    fn python_shaped_rows_come_back_oldest_first() {
        let text = [PYTHON_LINE_NEW, PYTHON_LINE_OLD, PYTHON_LINE_MIDDLE].join("\n");
        let rows = collect(&text, "cody", "jason", DEFAULT_LIMIT);
        let ats: Vec<f64> = rows.iter().map(|r| r["at"].as_f64().unwrap()).collect();
        assert_eq!(ats, vec![1794769942.7180102, 1794769950.5, 1794769960.25]);
        assert_eq!(rows[0]["from_label"], "cody");
        assert_eq!(rows[0]["to_profile"], "jason");
        assert!(rows[0]["from_profile"].is_null());
        assert_eq!(rows[1]["from_profile"], "jason");
        assert_eq!(
            rows[2]["text"],
            "and the patch files are named in that note"
        );
    }

    #[test]
    fn a_row_named_only_by_its_label_still_matches_the_pair() {
        // The live file's rows all look like this: from_profile null, sender in from_label. Matching
        // on from_profile alone is what left the modal empty.
        let rows = collect(PYTHON_LINE_OLD, "cody", "jason", DEFAULT_LIMIT);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["from_label"], "cody");
    }

    #[test]
    fn either_direction_matches_and_other_pairs_do_not() {
        let text = [PYTHON_LINE_OLD, PYTHON_LINE_MIDDLE, PYTHON_LINE_NEW].join("\n");
        assert_eq!(collect(&text, "cody", "jason", DEFAULT_LIMIT).len(), 3);
        assert_eq!(collect(&text, "jason", "cody", DEFAULT_LIMIT).len(), 3);
        assert!(collect(&text, "cody", "tinker", DEFAULT_LIMIT).is_empty());
        assert!(collect(&text, "jason", "tinker", DEFAULT_LIMIT).is_empty());
    }

    #[test]
    fn the_limit_keeps_the_newest_rows_in_written_order() {
        let text = [PYTHON_LINE_OLD, PYTHON_LINE_MIDDLE, PYTHON_LINE_NEW].join("\n");
        let rows = collect(&text, "cody", "jason", 2);
        let texts: Vec<&str> = rows.iter().map(|r| r["text"].as_str().unwrap()).collect();
        assert_eq!(
            texts,
            vec!["acked", "and the patch files are named in that note"]
        );
    }

    #[test]
    fn unknown_extra_fields_survive_and_missing_ones_are_defaulted() {
        let line = r#"{"to_profile": "ops", "at": "1794769942.5", "kind": "cron", "nested": {"n": 1}, "session_id": "dd33"}"#;
        let rows = collect(line, "assistant", "ops", DEFAULT_LIMIT);
        assert_eq!(rows.len(), 1, "a row without text must still come back");
        let row = &rows[0];
        assert_eq!(row["from_label"], "assistant");
        assert_eq!(row["text"], "");
        assert_eq!(row["at"], 1794769942.5, "a numeric string is accepted");
        assert_eq!(row["kind"], "cron");
        assert_eq!(row["nested"]["n"], 1);
        assert_eq!(row["session_id"], "dd33");
        assert!(row["from_profile"].is_null());
    }

    #[test]
    fn a_malformed_line_is_skipped_and_the_rest_are_kept() {
        let text = [
            PYTHON_LINE_OLD,
            r#"{"from_profile": null, "to_profile": "jas"#, // interrupted append
            "not json at all",
            "[1, 2, 3]", // valid JSON, not a record
            PYTHON_LINE_NEW,
        ]
        .join("\n");
        let rows = collect(&text, "cody", "jason", DEFAULT_LIMIT);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["session_id"], "d8cff42a");
        assert_eq!(rows[1]["session_id"], "bb22");
    }

    #[test]
    fn a_missing_file_is_empty_not_an_error() {
        let dir =
            std::env::temp_dir().join(format!("hermeyd-transfers-missing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join(BRIDGE_FILENAME);
        assert!(!path.exists());
        let text = read_file(&path);
        assert!(text.is_empty());
        assert!(collect(&text, "cody", "jason", DEFAULT_LIMIT).is_empty());
        assert_eq!(newest_existing(&[path]), None);
    }

    #[test]
    fn the_bridge_filename_beside_the_database_is_found() {
        let (dir, file) = fixture("bridge-name", &[PYTHON_LINE_OLD, PYTHON_LINE_NEW]);
        let found = newest_existing(&candidate_files(&[dir.clone()]));
        assert_eq!(found, Some(file.clone()));
        let rows = collect(&read_file(&file), "cody", "jason", DEFAULT_LIMIT);
        assert_eq!(rows.len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_newer_file_wins_when_both_names_exist() {
        let (dir, bridge_file) = fixture("newest-wins", &[PYTHON_LINE_OLD]);
        let legacy = dir.join(LEGACY_FILENAME);
        std::fs::write(&legacy, [PYTHON_LINE_NEW, ""].join("\n")).expect("legacy");
        // Same-second mtimes are possible; make the order explicit instead of racy.
        let now = std::time::SystemTime::now();
        std::fs::File::options()
            .write(true)
            .open(&bridge_file)
            .unwrap()
            .set_modified(now - std::time::Duration::from_secs(60))
            .unwrap();
        std::fs::File::options()
            .write(true)
            .open(&legacy)
            .unwrap()
            .set_modified(now)
            .unwrap();
        let files = candidate_files(&[dir.clone()]);
        assert_eq!(newest_existing(&files), Some(legacy));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_newer_file_does_not_hide_a_populated_one() {
        let (dir, bridge_file) = fixture("empty-newer", &[PYTHON_LINE_OLD]);
        let legacy = dir.join(LEGACY_FILENAME);
        std::fs::write(&legacy, "").expect("empty legacy");
        let now = std::time::SystemTime::now();
        std::fs::File::options()
            .write(true)
            .open(&bridge_file)
            .unwrap()
            .set_modified(now - std::time::Duration::from_secs(60))
            .unwrap();
        std::fs::File::options()
            .write(true)
            .open(&legacy)
            .unwrap()
            .set_modified(now)
            .unwrap();
        let files = candidate_files(&[dir.clone()]);
        assert_eq!(newest_existing(&files), Some(bridge_file));
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- the writer -------------------------------------------------------------------------

    /// One written hand-off, through the same `line_for` + `append` production uses.
    fn write_one(path: &Path, session_id: Option<&str>, text: &str, at: f64) -> String {
        let line = line_for(Some("jason"), "assistant", "cody", session_id, text, at);
        append(path, &line).expect("append");
        line
    }

    #[test]
    fn a_written_row_round_trips_with_its_session_id() {
        let dir = scratch_dir("roundtrip");
        let path = dir.join(BRIDGE_FILENAME);
        write_one(&path, Some("20261121_101010_aa11"), "acked", 1794769950.5);

        let text = read_file(&path);
        assert_eq!(text.lines().count(), 1, "one record, one line");
        let record: Value = serde_json::from_str(text.trim()).expect("valid JSON");
        assert_eq!(record["session_id"], "20261121_101010_aa11");

        let rows = collect(&text, "cody", "jason", DEFAULT_LIMIT);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["session_id"], "20261121_101010_aa11");
        assert_eq!(rows[0]["text"], "acked");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_row_with_no_session_id_still_parses() {
        let dir = scratch_dir("null-session");
        let path = dir.join(BRIDGE_FILENAME);
        let line = write_one(&path, None, "no conversation named", 1794769950.5);
        assert!(line.contains("\"session_id\": null"), "{line}");
        let rows = collect(&read_file(&path), "cody", "jason", DEFAULT_LIMIT);
        assert_eq!(rows.len(), 1);
        assert!(rows[0]["session_id"].is_null());
    }

    /// Byte compatibility is the whole point: a host that ran the Python writer and one that runs
    /// this writer must produce the same line for the same exchange, so either can read the other.
    #[test]
    fn the_written_line_matches_the_python_writer_byte_for_byte() {
        assert_eq!(
            line_for(Some("jason"), "assistant", "cody", Some("aa11"), "acked", 1794769950.5),
            PYTHON_LINE_MIDDLE
        );
        assert_eq!(
            line_for(None, "cody", "jason", Some("d8cff42a"),
                     "Heads up: your session-sync work was sitting uncommitted", 1794769942.7180102),
            PYTHON_LINE_OLD
        );
    }

    #[test]
    fn the_file_stays_append_only_and_one_line_per_record() {
        let dir = scratch_dir("append-only");
        let path = dir.join(BRIDGE_FILENAME);
        let first = write_one(&path, Some("aa11"), "one", 1794769942.5);
        let after_first = read_file(&path);
        write_one(&path, Some("bb22"), "two", 1794769950.5);
        write_one(&path, None, "three", 1794769960.5);
        let all = read_file(&path);
        assert!(
            all.starts_with(&after_first),
            "an append may not rewrite what was already there"
        );
        assert!(all.starts_with(&first));
        assert_eq!(all.lines().count(), 3);
        assert!(all.ends_with('\n'), "every record ends its line");
        assert_eq!(collect(&all, "cody", "jason", DEFAULT_LIMIT).len(), 3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_oversize_file_is_rotated_to_one_previous() {
        let dir = scratch_dir("rotate");
        let path = dir.join(BRIDGE_FILENAME);
        // Just over the cap, then one more record: the *next* write rotates, as in Python.
        std::fs::write(&path, "x".repeat((MAX_BYTES + 1) as usize)).expect("bulk");
        write_one(&path, Some("aa11"), "after rotation", 1794769950.5);
        let rotated = dir.join("bot-transfers.jsonl.1");
        assert!(rotated.is_file(), "the old file is kept as .1");
        assert_eq!(
            std::fs::metadata(&rotated).unwrap().len(),
            MAX_BYTES + 1
        );
        let current = read_file(&path);
        assert_eq!(current.lines().count(), 1, "and the new file starts clean");
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn scratch_dir(tag: &str) -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-transfers-writer-{}-{}-{}",
            std::process::id(),
            tag,
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch");
        dir
    }
}
