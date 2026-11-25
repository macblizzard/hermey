//! Editing and deleting a message, on both devices at once.
//!
//! The engine has no message-level edit or delete (`tui_gateway/methods_session.py`), and both apps
//! paint the same thing: `SELECT … FROM messages WHERE session_id=? AND (active=1 OR compacted=1)`.
//! So the host owns the two verbs, and it owns them as a **soft retire** — the row the transcript
//! stops painting, never the bytes:
//!
//! ```text
//! POST /v1/messages/delete    {"bot": "cody", "session": "20261123_101500_ab12cd",
//!                              "message_ids": [41, 42]}
//!   -> 200 {"bot", "session", "retired": 2, "display_count": 104}
//!
//! POST /v1/messages/truncate  {"bot": "cody", "session": "20261123_101500_ab12cd",
//!                              "from_message_id": 41}
//!   -> 200 {"bot", "session", "retired": 6, "display_count": 99}
//!
//!   409 {"error": "turn_running",       "detail": …}  a turn is answering in that conversation
//!   503 {"error": "engine_unavailable", "detail": …}  the engine did not answer; nothing changed
//!   502 {"error": "engine_refused",     "detail": …}  the engine refused the close; nothing changed
//!   404 {"error": "no_such_message",    "detail": …}  no such row in that conversation
//!   422 {"detail": …}                                 bad bot / session / body / ids
//! ```
//!
//! **Why both, and why truncate is what "edit and resend" needs.** Delete retires exactly the rows
//! named. Truncate retires the message the owner wants to rewrite *and everything painted after it*,
//! which is the only honest way to re-ask a turn: leaving the old answer above a new question would
//! show two answers to one ask, and the model would be fed both.
//!
//! **The three steps, in this order.**
//!
//! 1. **Ask the engine whether a turn is running.** `session.active_list` is the engine's own live
//!    registry — the only place that knows, because a live session keeps its own in-memory copy of
//!    the history and would keep serving it. A row whose `session_key` is this conversation and whose
//!    `status` is not `idle` (`working`, `waiting`, `starting`) answers **409** with a sentence:
//!    retiring a row under a running turn is a race the engine always wins, because it flushes its
//!    history when the turn ends. The same row names the **runtime** id, which is what
//!    `session.close` takes — the stored id and the runtime id are two namespaces that look alike and
//!    are not interchangeable (`GatewayEventDecoder.liveSessionIDs` says the same on the app side).
//! 2. **Close it**, so the engine drops its in-memory copy before a single row moves. A resume then
//!    rebuilds from the database — which is what makes both devices converge, and what the app does
//!    the moment this route answers.
//! 3. **Retire the rows in one transaction**: `active=0, compacted=0`. That is not a new convention;
//!    it is exactly what the engine's own rewind and undo write (`hermes_state_mutations.py`, which
//!    contrasts it with compaction's `active=0, compacted=1`). The transcript query stops painting
//!    the row, the bytes stay in the file, and the database's own
//!    `messages_display_visibility_update` trigger keeps `display_order` coherent while it happens.
//!    **No `DELETE` is ever issued from this file**, so the words stay recoverable — the difference
//!    between "delete" as people mean it here and losing a conversation to a mis-tap.
//!
//! **Which rows count as "after".** The transcript is ordered by `COALESCE(display_order, id)` (the
//! `display_order` the database's trigger maintains, backfilled to `id` for a legacy row), and that
//! is the predicate truncate uses — not `id >=`, which would disagree the moment a replayed user row
//! shares a lower display slot. A compressed conversation spreads its transcript over a chain of
//! sessions (`sessions.parent_session_id`, each hop ended `compression`), so the predicate runs
//! across that chain and nowhere else: a `/branch` copy is a different conversation and keeps its
//! own rows.
//!
//! **What the ids can be.** Never a path, never SQL text: `message_ids` is a bounded list of
//! positive integers and `from_message_id` is one. The only string in a body is the bot's name,
//! which is a key (validated to the shape the session pointer accepts) and never a segment of a
//! filesystem path built from the request.
//!
//! **The count.** `display_count` is `COUNT(*)` of the conversation's display set after the retire —
//! the same number a resume reports as `history.total` (`get_resume_display_window`), so the app can
//! say "the conversation now has 99 messages" and be right.
//!
//! **One known narrowness.** The live registry row carries no profile, so two profiles that happen
//! to hold the same stored session id would classify together. The worst case is a spurious close of
//! an *idle* session in the other profile (which reconnects on its own): the rows this route retires
//! are always read from the named bot's own `state.db`, so a wrong match can never move a row of
//! another conversation.

use crate::engine_client::rpc_strict;
use crate::routes::{require_device, AppState};
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::{json, Value};
use std::path::{Path as FsPath, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

type Fail = (StatusCode, Json<Value>);
type Fut<'a, T> = Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;

/// A delete of many rows in one go. Bounded: this is a message menu, not a bulk rewrite, and an
/// unbounded list is an unbounded `IN (…)`.
pub const MAX_MESSAGE_IDS: usize = 200;

/// The session id ceiling `bot_sessions.rs` and `cards.rs` use.
const MAX_SESSION_LEN: usize = 128;

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({ "detail": msg.into() })))
}

fn refused(status: StatusCode, error: &str, msg: impl Into<String>) -> Fail {
    (
        status,
        Json(json!({ "error": error, "detail": msg.into() })),
    )
}

/// A bot is a directory name and a key: `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`, the shape the session
/// pointer and the bot-to-bot route already accept.
fn valid_bot(bot: &str) -> bool {
    let bytes = bot.as_bytes();
    match bytes.first() {
        Some(first) if first.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    bytes.len() <= 64
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}

/// A stored session id: `%Y%m%d_%H%M%S_` + hex, and nothing that could be read as a path.
fn valid_session(session: &str) -> bool {
    let bytes = session.as_bytes();
    match bytes.first() {
        Some(first) if first.is_ascii_alphanumeric() => {}
        _ => return false,
    }
    bytes.len() <= MAX_SESSION_LEN
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

/// What one request asks for.
#[derive(Debug)]
enum Plan {
    /// These rows, and no others.
    Ids(Vec<i64>),
    /// This row and everything painted after it.
    From(i64),
}

struct Request {
    bot: String,
    session: String,
    plan: Plan,
}

/// Strict body parsing: a field this route does not read is malformed, not "close enough".
fn parse(body: &[u8], truncate: bool) -> Result<Request, Fail> {
    let value: Value = serde_json::from_slice(body)
        .map_err(|_| bad(StatusCode::UNPROCESSABLE_ENTITY, "expected a JSON object"))?;
    let object = value
        .as_object()
        .ok_or_else(|| bad(StatusCode::UNPROCESSABLE_ENTITY, "expected a JSON object"))?;
    let allowed: [&str; 3] = if truncate {
        ["bot", "session", "from_message_id"]
    } else {
        ["bot", "session", "message_ids"]
    };
    if let Some(key) = object.keys().find(|key| !allowed.contains(&key.as_str())) {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("unexpected field {key:?}"),
        ));
    }
    let bot = object
        .get("bot")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_string();
    if !valid_bot(&bot) {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "bot must be 1-64 chars of [A-Za-z0-9_.-], starting with a letter or digit",
        ));
    }
    let session = object
        .get("session")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    if !valid_session(&session) {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "session must be 1-128 chars of [A-Za-z0-9_-]",
        ));
    }

    if truncate {
        return match object
            .get("from_message_id")
            .and_then(|v| v.as_i64())
            .filter(|id| *id > 0)
        {
            Some(from_message_id) => Ok(Request {
                bot,
                session,
                plan: Plan::From(from_message_id),
            }),
            None => Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                "from_message_id must be a positive integer",
            )),
        };
    }

    let Some(raw) = object.get("message_ids").and_then(|v| v.as_array()) else {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "message_ids must be a non-empty array of positive integers",
        ));
    };
    if raw.is_empty() || raw.len() > MAX_MESSAGE_IDS {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("message_ids must hold 1-{MAX_MESSAGE_IDS} ids"),
        ));
    }
    let mut ids = Vec::with_capacity(raw.len());
    for entry in raw {
        match entry.as_i64().filter(|id| *id > 0) {
            Some(id) => ids.push(id),
            None => {
                return Err(bad(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "message_ids must be a non-empty array of positive integers",
                ))
            }
        }
    }
    // A repeated id is one row, not two: `retired: 2` must never describe one message.
    ids.sort_unstable();
    ids.dedup();
    Ok(Request {
        bot,
        session,
        plan: Plan::Ids(ids),
    })
}

// ---------------------------------------------------------------------------------------------
// The engine: the one question this route cannot answer by reading the database
// ---------------------------------------------------------------------------------------------

/// What the engine's live registry says about one conversation.
#[derive(Debug, PartialEq)]
pub(crate) enum Live {
    /// Nothing live holds this conversation, so no in-memory copy can outlive the retire.
    NotLive,
    /// Live and idle. The string is the **runtime** id — what `session.close` takes.
    Idle(String),
    /// Live and answering. Any status that is not `idle` — `working`, `waiting` (parked on an
    /// approval), `starting` — means a turn owns the history it will flush when it ends.
    Busy(String),
}

/// Why the engine could not answer at all. A turn that is running is the owner's to wait for; an
/// engine that did not answer is the host's to fix — and neither is a reason to touch a row.
#[derive(Debug, PartialEq)]
pub(crate) enum LiveError {
    Unavailable(String),
}

/// The engine, as this module needs it. A trait so the tests can stand in for a live gateway while
/// still proving the *order* — the fake looks at the rows when it is asked to close.
///
/// `Send + Sync` is not decoration: the axum handler holds this across an `await`, and a `dyn` without
/// it makes the handler's future non-`Send`, which axum refuses to route.
pub(crate) trait Engine: Send + Sync {
    fn live<'a>(&'a self, bot: &'a str, session: &'a str) -> Fut<'a, Result<Live, LiveError>>;
    fn close<'a>(&'a self, runtime_id: &'a str) -> Fut<'a, Result<(), String>>;
}

/// The real engine, over the loopback WS with the per-boot token. One short connection per call,
/// exactly like every other route that asks the engine something (`engine_client`).
pub(crate) struct LiveEngine {
    ws: String,
    token: Option<String>,
}

impl LiveEngine {
    pub(crate) fn new(st: &AppState) -> LiveEngine {
        LiveEngine {
            ws: st.engine_ws.clone(),
            token: st.engine_token(),
        }
    }
}

impl Engine for LiveEngine {
    fn live<'a>(&'a self, bot: &'a str, session: &'a str) -> Fut<'a, Result<Live, LiveError>> {
        Box::pin(async move {
            let _ = bot;
            // `session.active_list` is the engine's own live registry: `id` is the runtime id,
            // `session_key` the stored one, `status` one of idle|working|waiting|starting.
            let result = rpc_strict(
                &self.ws,
                self.token.clone(),
                "session.active_list",
                json!({ "current_session_id": session }),
            )
            .await
            .map_err(|e| LiveError::Unavailable(e.message))?;
            Ok(classify(&result, session))
        })
    }

    fn close<'a>(&'a self, runtime_id: &'a str) -> Fut<'a, Result<(), String>> {
        Box::pin(async move {
            rpc_strict(
                &self.ws,
                self.token.clone(),
                "session.close",
                json!({ "session_id": runtime_id }),
            )
            .await
            .map(|_| ())
            .map_err(|e| e.message)
        })
    }
}

/// The decision, from the `session.active_list` payload. Split out so it is testable without a
/// socket, and so the one rule lives in one place: **any live row that is not `idle` is a turn**.
pub(crate) fn classify(result: &Value, session: &str) -> Live {
    let empty = vec![];
    let rows = result
        .get("sessions")
        .and_then(|s| s.as_array())
        .unwrap_or(&empty);
    for row in rows {
        if row.get("session_key").and_then(|k| k.as_str()) != Some(session) {
            continue;
        }
        let id = row
            .get("id")
            .and_then(|i| i.as_str())
            .unwrap_or_default()
            .to_string();
        let status = row.get("status").and_then(|s| s.as_str()).unwrap_or("");
        if status == "idle" && !id.is_empty() {
            return Live::Idle(id);
        }
        return Live::Busy(if status.is_empty() {
            "unknown".to_string()
        } else {
            status.to_string()
        });
    }
    Live::NotLive
}

/// Steps 1 and 2: may this conversation be touched, and if it is live, drop the engine's copy.
///
/// `Err` is the answer for the caller, already the right status code — 409 for a running turn (the
/// owner waits), 503 for an engine that did not answer, 502 for one that refused the close. In every
/// refusal **no row has been touched**: the database is not opened until this returns `Ok`.
async fn prepare(st: &AppState, bot: &str, session: &str, engine: &dyn Engine) -> Result<(), Fail> {
    let _ = st;
    match engine.live(bot, session).await {
        // Nothing live: no in-memory copy exists, so there is nothing to close. The rows are the
        // only copy, and retiring them is immediately the truth a resume will read.
        Ok(Live::NotLive) => Ok(()),
        Ok(Live::Idle(runtime_id)) => engine.close(&runtime_id).await.map_err(|e| {
            refused(
                StatusCode::BAD_GATEWAY,
                "engine_refused",
                format!(
                    "The engine would not close that conversation before it was changed, so \
                     nothing was changed. ({e})"
                ),
            )
        }),
        Ok(Live::Busy(status)) => Err(refused(
            StatusCode::CONFLICT,
            "turn_running",
            format!(
                "That conversation is still answering ({status}) — wait for the turn to finish, \
                 then try again. Nothing was changed."
            ),
        )),
        Err(LiveError::Unavailable(why)) => Err(refused(
            StatusCode::SERVICE_UNAVAILABLE,
            "engine_unavailable",
            format!(
                "The engine did not answer, so this host cannot confirm the conversation is idle. \
                 Nothing was changed. ({why})"
            ),
        )),
    }
}

// ---------------------------------------------------------------------------------------------
// The rows
// ---------------------------------------------------------------------------------------------

/// `profiles/<bot>/state.db` — the same resolution `previews`, `push` and `bot_message` use.
fn db_path(st: &AppState, bot: &str) -> PathBuf {
    st.engine_home.join("profiles").join(bot).join("state.db")
}

/// Read-write, and **never create**: a bot with no database has no messages to retire, and a route
/// that mints an empty `state.db` would hand the engine a second, empty history for that profile.
fn open_rw(path: &FsPath) -> Option<Connection> {
    if !path.is_file() {
        return None;
    }
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE).ok()?;
    conn.busy_timeout(Duration::from_secs(2)).ok()?;
    Some(conn)
}

fn marks(count: usize) -> String {
    (1..=count)
        .map(|i| format!("?{i}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The conversation's own session and every session it continues through — the compression chain,
/// not any `/branch` copy (a hop only counts when the *parent* ended `compression`).
///
/// A retire is scoped to this set, so a message id from another conversation cannot reach a row this
/// request never named, and a truncate does not silently keep painting a continuation's turns.
fn lineage(conn: &Connection, session: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "WITH RECURSIVE
           anc(id) AS (
             SELECT id FROM sessions WHERE id = ?1
             UNION
             SELECT s.parent_session_id FROM sessions s JOIN anc ON s.id = anc.id
              WHERE s.parent_session_id IS NOT NULL AND s.end_reason = 'compression'
           ),
           chain(id) AS (
             SELECT id FROM sessions WHERE id = ?1
             UNION
             SELECT s.id FROM sessions s
               JOIN chain ON s.parent_session_id = chain.id
               JOIN sessions p ON p.id = s.parent_session_id
              WHERE p.end_reason = 'compression'
           )
         SELECT id FROM anc UNION SELECT id FROM chain",
    )?;
    let rows = stmt.query_map([session], |row| row.get::<_, String>(0))?;
    let mut ids: Vec<String> = rows.filter_map(|row| row.ok()).collect();
    ids.sort();
    ids.dedup();
    if ids.is_empty() {
        // No `sessions` row for this id. The rows are still the only thing we can retire, and a
        // conversation whose session row went missing is exactly when the owner wants the verbs to
        // work — so scope to the id the caller named rather than touching nothing.
        ids.push(session.to_string());
    }
    Ok(ids)
}

/// The display set's size: `COUNT(*)` over the lineage, `(active=1 OR compacted=1)` — precisely what
/// `get_resume_display_window` reports as `history.total`, so the app can quote one number.
fn display_count(conn: &Connection, lineage: &[String]) -> rusqlite::Result<i64> {
    let sql = format!(
        "SELECT COUNT(*) FROM messages WHERE session_id IN ({}) \
         AND (active = 1 OR compacted = 1)",
        marks(lineage.len())
    );
    conn.query_row(&sql, rusqlite::params_from_iter(lineage.iter()), |row| {
        row.get::<_, i64>(0)
    })
}

/// What one retire did.
#[derive(Debug, PartialEq)]
struct Retired {
    /// Rows this call turned invisible. Counted *before* the update, with the same predicate, so an
    /// id that was already retired is not reported as newly gone.
    retired: i64,
    display_count: i64,
}

/// Step 3, in one transaction: `active=0, compacted=0` for the planned rows, then the new count.
///
/// Both plans share one statement shape — only the predicate differs — so there is exactly one place
/// that can ever write a retire, and it is this one. There is no `DELETE` in this function, and
/// `Tests/test_edit_and_delete_messages.py` reads this file to keep it that way.
fn retire(path: &FsPath, session: &str, plan: &Plan) -> Result<Retired, Fail> {
    let Some(mut conn) = open_rw(path) else {
        return Err(refused(
            StatusCode::NOT_FOUND,
            "no_such_message",
            "That bot has no stored conversation.",
        ));
    };
    let unreadable = |e: rusqlite::Error| {
        refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            "unreadable",
            format!("cannot read that conversation: {e}"),
        )
    };
    let lineage = lineage(&conn, session).map_err(unreadable)?;
    let scope = marks(lineage.len());
    let tx = conn.transaction().map_err(unreadable)?;

    // The predicate, and the values it binds: the lineage scope first (every form uses it).
    let mut values: Vec<SqlValue> = lineage
        .iter()
        .map(|id| SqlValue::Text(id.clone()))
        .collect();
    let predicate = match plan {
        Plan::Ids(ids) => {
            let id_marks = (0..ids.len())
                .map(|i| format!("?{}", lineage.len() + 1 + i))
                .collect::<Vec<_>>()
                .join(", ");
            values.extend(ids.iter().map(|id| SqlValue::Integer(*id)));
            format!("session_id IN ({scope}) AND id IN ({id_marks})")
        }
        Plan::From(from) => {
            // The target's own slot, read inside this transaction: `COALESCE(display_order, id)` is
            // the expression the transcript orders by, so "and everything after it" means what the
            // reader sees, including a legacy row whose `display_order` was never backfilled.
            values.push(SqlValue::Integer(*from));
            let slot: Option<i64> = tx
                .query_row(
                    &format!(
                        "SELECT COALESCE(display_order, id) FROM messages \
                         WHERE id = ?{} AND session_id IN ({scope})",
                        lineage.len() + 1
                    ),
                    rusqlite::params_from_iter(values.iter()),
                    |row| row.get(0),
                )
                .optional()
                .map_err(unreadable)?;
            let Some(slot) = slot else {
                return Err(refused(
                    StatusCode::NOT_FOUND,
                    "no_such_message",
                    "No message with that id is in that conversation.",
                ));
            };
            // The id is replaced by the slot it resolved to: the predicate compares slots, not ids.
            *values.last_mut().expect("the id was just pushed") = SqlValue::Integer(slot);
            format!(
                "session_id IN ({scope}) AND COALESCE(display_order, id) >= ?{}",
                lineage.len() + 1
            )
        }
    };

    let visible: i64 = tx
        .query_row(
            &format!(
                "SELECT COUNT(*) FROM messages WHERE {predicate} AND (active = 1 OR compacted = 1)"
            ),
            rusqlite::params_from_iter(values.iter()),
            |row| row.get(0),
        )
        .map_err(unreadable)?;
    if visible == 0 {
        // Nothing visible matched: the id is not in this conversation, or it is already retired.
        // Dropping `tx` rolls back, so a miss cannot leave a half-applied answer behind.
        return Err(refused(
            StatusCode::NOT_FOUND,
            "no_such_message",
            "No message with that id is in that conversation.",
        ));
    }

    tx.execute(
        &format!("UPDATE messages SET active = 0, compacted = 0 WHERE {predicate}"),
        rusqlite::params_from_iter(values.iter()),
    )
    .map_err(unreadable)?;
    let display_count = display_count(&tx, &lineage).map_err(unreadable)?;
    tx.commit().map_err(unreadable)?;
    Ok(Retired {
        retired: visible,
        display_count,
    })
}

// ---------------------------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------------------------

/// One audit line, scalars only: who, which bot, which verb, what happened, how many rows. The
/// session id is a capability for that conversation (`bot_sessions.rs` says the same), so it is not
/// in the line; neither is any message text.
fn audit(device: &str, bot: &str, verb: &str, outcome: &str, retired: Option<i64>) {
    let who: String = device.chars().take(8).collect();
    match retired {
        Some(retired) => eprintln!(
            "audit messages device_id={who} method=POST verb={verb} bot={bot} outcome={outcome} \
             retired={retired}"
        ),
        None => eprintln!(
            "audit messages device_id={who} method=POST verb={verb} bot={bot} outcome={outcome}"
        ),
    }
}

/// The shared body of both routes: parse, ask the engine, retire, answer.
async fn run(
    st: &AppState,
    device: &str,
    body: &[u8],
    truncate: bool,
    engine: &dyn Engine,
) -> Result<Value, Fail> {
    let verb = if truncate { "truncate" } else { "delete" };
    let request = parse(body, truncate).map_err(|fail| {
        audit(device, "-", verb, "rejected", None);
        fail
    })?;

    // 1 and 2, before the database is opened at all: a running turn is refused, and a live session
    // is closed so the engine cannot keep serving its in-memory copy past this retire.
    prepare(st, &request.bot, &request.session, engine)
        .await
        .map_err(|fail| {
            audit(device, &request.bot, verb, "refused", None);
            fail
        })?;

    // 3, in one transaction.
    let retired =
        retire(&db_path(st, &request.bot), &request.session, &request.plan).map_err(|fail| {
            audit(device, &request.bot, verb, "nothing", None);
            fail
        })?;

    audit(device, &request.bot, verb, "retired", Some(retired.retired));
    Ok(json!({
        "bot": request.bot,
        "session": request.session,
        "retired": retired.retired,
        "display_count": retired.display_count,
    }))
}

/// `POST /v1/messages/delete` — retire these messages from the conversation, on every device.
pub async fn post_delete(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let engine = LiveEngine::new(&st);
    run(&st, &device, &body, false, &engine).await.map(Json)
}

/// `POST /v1/messages/truncate` — retire this message and everything painted after it. What "edit and
/// resend" needs: the old ask and its answer go, then the owner's new text is sent as a turn.
pub async fn post_truncate(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let engine = LiveEngine::new(&st);
    run(&st, &device, &body, true, &engine).await.map(Json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{scratch, state};
    use std::sync::Mutex;

    const BOT: &str = "aria";
    const SESSION: &str = "20261120_101500_ab12cd";

    /// What a fake engine was asked, in order — and what the rows looked like at the moment it was
    /// asked to close, which is the ordering proof this route needs.
    #[derive(Default)]
    struct Seen {
        asked: Vec<String>,
        rows_when_closed: Option<Vec<(i64, i64, i64)>>,
    }

    struct Fake {
        live: Result<Live, LiveError>,
        db: PathBuf,
        seen: Mutex<Seen>,
        close_refuses: bool,
    }

    impl Fake {
        fn idle(db: &FsPath) -> Fake {
            Fake {
                live: Ok(Live::Idle("rt-7".to_string())),
                db: db.to_path_buf(),
                seen: Mutex::default(),
                close_refuses: false,
            }
        }
        fn not_live(db: &FsPath) -> Fake {
            Fake {
                live: Ok(Live::NotLive),
                ..Fake::idle(db)
            }
        }
        fn busy(db: &FsPath) -> Fake {
            Fake {
                live: Ok(Live::Busy("working".into())),
                ..Fake::idle(db)
            }
        }
    }

    /// `(id, active, compacted)` for every row of the conversation.
    fn rows(path: &FsPath) -> Vec<(i64, i64, i64)> {
        let conn = Connection::open(path).unwrap();
        let mut stmt = conn
            .prepare("SELECT id, active, compacted FROM messages WHERE session_id = ?1 ORDER BY id")
            .unwrap();
        let out = stmt
            .query_map([SESSION], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();
        out
    }

    impl Engine for Fake {
        fn live<'a>(&'a self, bot: &'a str, session: &'a str) -> Fut<'a, Result<Live, LiveError>> {
            Box::pin(async move {
                self.seen
                    .lock()
                    .unwrap()
                    .asked
                    .push(format!("live:{bot}:{session}"));
                match &self.live {
                    Ok(Live::NotLive) => Ok(Live::NotLive),
                    Ok(Live::Idle(id)) => Ok(Live::Idle(id.clone())),
                    Ok(Live::Busy(why)) => Ok(Live::Busy(why.clone())),
                    Err(LiveError::Unavailable(why)) => Err(LiveError::Unavailable(why.clone())),
                }
            })
        }

        fn close<'a>(&'a self, runtime_id: &'a str) -> Fut<'a, Result<(), String>> {
            Box::pin(async move {
                let mut seen = self.seen.lock().unwrap();
                seen.asked.push(format!("close:{runtime_id}"));
                // The rows as they stood when the close was asked for: a retire that ran first
                // would show up here as an already-inactive row.
                seen.rows_when_closed = Some(rows(&self.db));
                if self.close_refuses {
                    return Err("engine refused: session not found".to_string());
                }
                Ok(())
            })
        }
    }

    /// A profile `state.db` shaped like the engine's, with a session and five rows: two turns of
    /// ask/answer, then a closing note.
    fn seed(tag: &str) -> (PathBuf, PathBuf) {
        let dir = scratch(tag);
        let profile = dir.join("engine").join("profiles").join(BOT);
        std::fs::create_dir_all(&profile).unwrap();
        let db = profile.join("state.db");
        let conn = Connection::open(&db).unwrap();
        conn.execute_batch(
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, end_reason TEXT);
             CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                                    role TEXT NOT NULL, content TEXT, active INTEGER NOT NULL DEFAULT 1,
                                    compacted INTEGER NOT NULL DEFAULT 0, display_order INTEGER);
             INSERT INTO sessions (id) VALUES ('20261120_101500_ab12cd');
             INSERT INTO messages (session_id, role, content, display_order) VALUES
               ('20261120_101500_ab12cd', 'user', 'first ask', 1),
               ('20261120_101500_ab12cd', 'assistant', 'first answer', 2),
               ('20261120_101500_ab12cd', 'user', 'second ask', 3),
               ('20261120_101500_ab12cd', 'assistant', 'second answer', 4),
               ('20261120_101500_ab12cd', 'user', 'a later note', 5);",
        )
        .unwrap();
        (dir, db)
    }

    fn state_on(dir: &FsPath) -> Arc<AppState> {
        Arc::new(AppState {
            engine_home: dir.join("engine"),
            ..state(dir)
        })
    }

    fn delete_body(ids: &[i64]) -> Bytes {
        Bytes::from(json!({ "bot": BOT, "session": SESSION, "message_ids": ids }).to_string())
    }

    fn truncate_body(from: i64) -> Bytes {
        Bytes::from(json!({ "bot": BOT, "session": SESSION, "from_message_id": from }).to_string())
    }

    #[tokio::test]
    async fn a_delete_retires_exactly_the_rows_it_was_given_and_nothing_else() {
        let (dir, db) = seed("delete-rows");
        let st = state_on(&dir);

        let answer = run(
            &st,
            "device-mac",
            &delete_body(&[2, 4]),
            false,
            &Fake::not_live(&db),
        )
        .await
        .expect("retired");
        assert_eq!(answer["retired"], 2);
        assert_eq!(answer["display_count"], 3);
        assert_eq!(
            rows(&db),
            vec![(1, 1, 0), (2, 0, 0), (3, 1, 0), (4, 0, 0), (5, 1, 0)],
            "only the two named rows went invisible, and both are still in the file"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Nothing is ever removed: the row count is the same before and after, which is the difference
    /// between a retire and a hard delete.
    #[tokio::test]
    async fn no_row_is_ever_removed_from_the_file() {
        let (dir, db) = seed("no-delete");
        let st = state_on(&dir);
        let before: i64 = Connection::open(&db)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM messages", [], |r| r.get(0))
            .unwrap();

        run(
            &st,
            "device-mac",
            &truncate_body(1),
            true,
            &Fake::not_live(&db),
        )
        .await
        .expect("retired");

        let after: i64 = Connection::open(&db)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM messages", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            before, after,
            "the bytes stay: a retire is not a hard delete"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_truncate_retires_the_message_and_everything_painted_after_it() {
        let (dir, db) = seed("truncate-rows");
        let st = state_on(&dir);

        let answer = run(
            &st,
            "device-mac",
            &truncate_body(3),
            true,
            &Fake::not_live(&db),
        )
        .await
        .expect("retired");
        assert_eq!(answer["retired"], 3, "the ask, its answer and the note");
        assert_eq!(answer["display_count"], 2);
        assert_eq!(
            rows(&db),
            vec![(1, 1, 0), (2, 1, 0), (3, 0, 0), (4, 0, 0), (5, 0, 0)],
            "everything painted before the target is untouched"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The whole reason there is a check at all: a turn that is still answering owns the history it
    /// will flush, so a retire under it is a race the engine wins.
    #[tokio::test]
    async fn a_running_turn_is_refused_with_409_and_no_row_moves() {
        let (dir, db) = seed("busy");
        let st = state_on(&dir);
        let fake = Fake::busy(&db);

        let (status, payload) = run(&st, "device-mac", &delete_body(&[2]), false, &fake)
            .await
            .expect_err("refused");
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(payload.0["error"], "turn_running");
        assert!(payload.0["detail"]
            .as_str()
            .unwrap()
            .contains("Nothing was changed"));
        assert_eq!(
            rows(&db),
            vec![(1, 1, 0), (2, 1, 0), (3, 1, 0), (4, 1, 0), (5, 1, 0)]
        );
        assert_eq!(
            fake.seen.lock().unwrap().asked,
            vec![format!("live:{BOT}:{SESSION}")],
            "a refusal must not even ask for a close"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The order, proven rather than asserted: when the engine is asked to close, every row is still
    /// exactly as it was written.
    #[tokio::test]
    async fn the_engine_closes_the_session_before_a_single_row_is_touched() {
        let (dir, db) = seed("order");
        let st = state_on(&dir);
        let fake = Fake::idle(&db);

        run(&st, "device-mac", &delete_body(&[2]), false, &fake)
            .await
            .expect("retired");

        {
            let seen = fake.seen.lock().unwrap();
            assert_eq!(
                seen.asked,
                vec![format!("live:{BOT}:{SESSION}"), "close:rt-7".to_string()]
            );
            assert_eq!(
                seen.rows_when_closed.as_ref().unwrap(),
                &vec![(1, 1, 0), (2, 1, 0), (3, 1, 0), (4, 1, 0), (5, 1, 0)],
                "the close came first: every row was still visible when the engine was asked"
            );
        }
        assert_eq!(rows(&db)[1], (2, 0, 0), "and the retire came after");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A close the engine refuses leaves the rows alone: the app must be able to say "nothing
    /// happened" truthfully.
    #[tokio::test]
    async fn a_refused_close_changes_nothing() {
        let (dir, db) = seed("close-refused");
        let st = state_on(&dir);
        let fake = Fake {
            close_refuses: true,
            ..Fake::idle(&db)
        };

        let (status, payload) = run(&st, "device-mac", &delete_body(&[2]), false, &fake)
            .await
            .expect_err("refused");
        assert_eq!(status, StatusCode::BAD_GATEWAY);
        assert_eq!(payload.0["error"], "engine_refused");
        assert_eq!(rows(&db)[1], (2, 1, 0));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_engine_that_does_not_answer_is_a_503_not_a_retire() {
        let (dir, db) = seed("engine-down");
        let st = state_on(&dir);
        let fake = Fake {
            live: Err(LiveError::Unavailable(
                "engine unreachable: connection refused".into(),
            )),
            ..Fake::idle(&db)
        };

        let (status, payload) = run(&st, "device-mac", &truncate_body(2), true, &fake)
            .await
            .expect_err("refused");
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(payload.0["error"], "engine_unavailable");
        assert_eq!(rows(&db)[1], (2, 1, 0));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_message_that_is_not_in_that_conversation_is_a_404() {
        let (dir, db) = seed("missing");
        let st = state_on(&dir);

        let (status, payload) = run(
            &st,
            "device-mac",
            &delete_body(&[999]),
            false,
            &Fake::not_live(&db),
        )
        .await
        .expect_err("missing");
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(payload.0["error"], "no_such_message");
        // …and nothing was retired on the way to finding that out.
        assert_eq!(
            rows(&db),
            vec![(1, 1, 0), (2, 1, 0), (3, 1, 0), (4, 1, 0), (5, 1, 0)]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_body_is_refused_before_anything_is_asked_or_touched() {
        let (dir, db) = seed("bodies");
        let st = state_on(&dir);
        let fake = Fake::not_live(&db);

        let cases: [(&str, String); 8] = [
            ("not json", "nope".to_string()),
            ("empty", "{}".to_string()),
            (
                "bad bot",
                json!({"bot": "../ops", "session": SESSION, "message_ids": [1]}).to_string(),
            ),
            (
                "bad session",
                json!({"bot": BOT, "session": "a b", "message_ids": [1]}).to_string(),
            ),
            (
                "empty ids",
                json!({"bot": BOT, "session": SESSION, "message_ids": []}).to_string(),
            ),
            (
                "zero id",
                json!({"bot": BOT, "session": SESSION, "message_ids": [0]}).to_string(),
            ),
            (
                "extra field",
                json!({"bot": BOT, "session": SESSION, "message_ids": [1], "path": "/etc/passwd"})
                    .to_string(),
            ),
            (
                "truncate without an id",
                json!({"bot": BOT, "session": SESSION}).to_string(),
            ),
        ];
        for (why, body) in cases {
            let truncate = why.starts_with("truncate");
            let (status, _) = run(&st, "device-mac", body.as_bytes(), truncate, &fake)
                .await
                .expect_err(why);
            assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{why}");
        }
        assert!(
            fake.seen.lock().unwrap().asked.is_empty(),
            "a bad body never reaches the engine"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_request_without_a_device_bearer_is_refused() {
        let (dir, _db) = seed("auth");
        let st = state_on(&dir);
        let refused = post_delete(State(Arc::clone(&st)), HeaderMap::new(), delete_body(&[1]))
            .await
            .expect_err("no bearer");
        assert_eq!(refused.0, StatusCode::UNAUTHORIZED);
        let refused = post_truncate(State(Arc::clone(&st)), HeaderMap::new(), truncate_body(1))
            .await
            .expect_err("no bearer");
        assert_eq!(refused.0, StatusCode::UNAUTHORIZED);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A bot with no stored conversation answers 404 rather than minting an empty `state.db`.
    #[tokio::test]
    async fn an_unknown_bot_is_a_404_and_no_database_is_created() {
        let (dir, db) = seed("unknown-bot");
        let st = state_on(&dir);
        let body = Bytes::from(
            json!({"bot": "ghost", "session": SESSION, "message_ids": [1]}).to_string(),
        );
        let (status, payload) = run(&st, "device-mac", &body, false, &Fake::not_live(&db))
            .await
            .expect_err("no conversation");
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(payload.0["error"], "no_such_message");
        assert!(
            !dir.join("engine").join("profiles").join("ghost").exists(),
            "the route must not create a profile database"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The engine's answer, classified. `idle` is clear; anything else is a turn; a session the
    /// registry does not hold is not live at all.
    #[test]
    fn the_live_registry_is_read_by_status_and_stored_id() {
        let working = json!({"sessions": [
            {"id": "rt-1", "session_key": "other", "status": "idle"},
            {"id": "rt-2", "session_key": SESSION, "status": "working"},
        ]});
        assert_eq!(
            classify(&working, SESSION),
            Live::Busy("working".to_string())
        );

        let waiting =
            json!({"sessions": [{"id": "rt-2", "session_key": SESSION, "status": "waiting"}]});
        assert_eq!(
            classify(&waiting, SESSION),
            Live::Busy("waiting".to_string())
        );

        let idle = json!({"sessions": [{"id": "rt-3", "session_key": SESSION, "status": "idle"}]});
        assert_eq!(classify(&idle, SESSION), Live::Idle("rt-3".to_string()));

        assert_eq!(classify(&json!({"sessions": []}), SESSION), Live::NotLive);
        // The stored id is what matches; a runtime id in the request is not the conversation.
        let aliased =
            json!({"sessions": [{"id": "rt-3", "session_key": "stored", "status": "idle"}]});
        assert_eq!(classify(&aliased, "rt-3"), Live::NotLive);
    }
}
