//! Bounded transcript pages: keep a long conversation openable on a phone.
//!
//! `session.resume` answers with the WHOLE conversation in one JSON-RPC frame. One measured bot chat
//! is 1450 rows / 3.4 MB, and `URLSessionWebSocketTask` refuses to deliver a message that size: the
//! app reports "Message too long" (EMSGSIZE), the conversation never opens, and every reconnect
//! re-requests the same oversized frame. The engine's own resume guard counts *messages*, not bytes,
//! so a long-but-legal session slips through it.
//!
//! So the relay pages the transcript it already forwards:
//!
//! * the resume result keeps only its newest page (`plan_newest`) and gains
//!   `history: {total, shown, cursor}`, where `cursor` is the row offset of the page's oldest
//!   message (null once the page is the whole conversation);
//! * the app asks for older rows with `session.history {session_id, profile, cursor, limit}`, which
//!   the relay answers from the copy it kept of THAT connection's resume (`HistoryCache`) — the
//!   engine's own projection, so a page is the same rows, in the same order, as the resume was;
//! * the copy dies with the socket. A reconnect re-resumes and re-fills it, so nothing here is
//!   persisted, shared between devices, or logged with content.
//!
//! Why not forward `session.history` to the engine: the engine answers it from the live session's
//! MODEL history (measured: 157 rows for the same session, because compacted rows are dropped),
//! while the resume returns the display lineage (1450 rows). Serving older pages from it would
//! silently skip the history the user is scrolling.
//!
//! Everything in this module is pure and socket-free; `relay.rs` owns the two socket loops and the
//! per-connection state. Frame-shape assumptions the relay makes (and therefore this module):
//!
//! * one JSON document per WebSocket text frame, possibly with a trailing `\n`. A frame that does
//!   not parse, or does not look like the shape named below, is forwarded byte-for-byte untouched;
//! * JSON-RPC responses carry `id` and no `method`; requests/notifications carry `method`;
//! * ids are numbers or strings, and `1` is a different id from `"1"` (`RpcId`).

use serde_json::{json, Map, Value};
use std::collections::{HashMap, VecDeque};

/// Rows per page. A page is also capped by bytes, so this is a ceiling, not a target: 200 plain chat
/// rows is ~150 KB, while 200 tool rows can be megabytes.
pub const PAGE_MESSAGES: usize = 200;

/// Bytes per page. Comfortably under what iOS accepts (3.4 MB measurably fails) and still several
/// screens of conversation.
pub const PAGE_BYTES: usize = 512 * 1024;

/// Total bytes of relayed transcripts one connection may keep for paging. One long conversation is
/// a few megabytes; four live sockets per device stay well inside this.
pub const CACHE_BYTES: usize = 64 * 1024 * 1024;

/// Any frame above this size that the relay is not otherwise rewriting is trimmed. iOS refuses a
/// 3.4 MB WebSocket message outright, so a monster event must not be able to wedge the socket.
pub const MAX_RELAY_BYTES: usize = 2 * 1024 * 1024;

/// `session.history` for a session this connection never resumed (or whose copy was evicted). The
/// app reopens the conversation, which re-resumes and re-fills the cache.
pub const ERROR_HISTORY_UNAVAILABLE: i64 = -32001;

/// How many `session.resume` requests one connection may have in flight before the oldest id is
/// forgotten. A resume's reply only needs tracking until it arrives; this only bounds a client that
/// asks forever without reading.
pub const MAX_TRACKED_RESUMES: usize = 64;

struct CountingWriter(usize);

impl std::io::Write for CountingWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0 += buf.len();
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// UTF-8 size of one message as it will travel in the frame: compact JSON, non-ASCII kept literal
/// (the client's NDJSON parser reads UTF-8, and the blueprint measures the same way).
pub fn encoded_size(value: &Value) -> usize {
    let mut counter = CountingWriter(0);
    // Serializing a `Value` cannot fail. An undercount would only make a page a hair larger.
    let _ = serde_json::to_writer(&mut counter, value);
    counter.0
}

/// `(page, cursor)` for the newest rows that fit — always at least one row.
///
/// `cursor` is the index of the page's first row in `messages`, or `None` when the page is the whole
/// transcript (so the client can tell "nothing older" from "one row, offset 0").
pub fn plan_newest(
    messages: &[Value],
    max_messages: usize,
    max_bytes: usize,
) -> (&[Value], Option<i64>) {
    let total = messages.len();
    if total == 0 {
        return (&[], None);
    }
    let mut kept = 0usize;
    let mut used = 0usize;
    for message in messages.iter().rev() {
        let size = encoded_size(message);
        // The newest row always ships, however large: an empty resume would look like a lost
        // conversation, which is the bug this whole module exists to prevent.
        if kept > 0 && (kept >= max_messages || used.saturating_add(size) > max_bytes) {
            break;
        }
        used = used.saturating_add(size);
        kept += 1;
    }
    let start = total - kept;
    (&messages[start..], offset(start))
}

/// `(page, next_cursor)` for rows older than `cursor`, newest-of-those last.
///
/// The page is contiguous and ends exactly where the caller's oldest row starts, so prepending it
/// cannot leave a gap. `next_cursor` is `None` when the page reaches the start of the conversation.
pub fn plan_before(
    messages: &[Value],
    cursor: i64,
    limit: usize,
    max_bytes: usize,
) -> (&[Value], Option<i64>) {
    let total = messages.len();
    let end = clamp_cursor(cursor, total);
    if end == 0 {
        return (&[], None);
    }
    if limit == 0 {
        return (&[], offset(end));
    }
    let mut start = end;
    let mut used = 0usize;
    while start > 0 && (end - start) < limit {
        let size = encoded_size(&messages[start - 1]);
        // At least one row per page, for the same reason `plan_newest` always keeps one.
        if start < end && used.saturating_add(size) > max_bytes {
            break;
        }
        start -= 1;
        used = used.saturating_add(size);
    }
    (&messages[start..end], offset(start))
}

fn clamp_cursor(cursor: i64, total: usize) -> usize {
    if cursor <= 0 {
        return 0;
    }
    ((cursor as u64).min(total as u64)) as usize
}

fn offset(index: usize) -> Option<i64> {
    if index == 0 {
        None
    } else {
        Some(index as i64)
    }
}

/// The `(session_id, profile)` a resume is cached under and a page request is looked up by.
///
/// A missing or non-string field is `""` — the same normalisation the blueprint uses, so the two
/// sides of a paging round trip always agree on the key.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct HistoryKey {
    pub session_id: String,
    pub profile: String,
}

impl HistoryKey {
    /// Used by the paging tests (and by any caller that already has the two strings).
    #[allow(dead_code)]
    pub fn new(session_id: &str, profile: &str) -> Self {
        Self {
            session_id: session_id.to_string(),
            profile: profile.to_string(),
        }
    }

    pub fn from_params(params: Option<&Value>) -> Self {
        match params.and_then(Value::as_object) {
            Some(map) => Self::from_map(map),
            None => Self::default(),
        }
    }

    pub fn from_map(map: &Map<String, Value>) -> Self {
        let text = |name: &str| {
            map.get(name)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        };
        Self {
            session_id: text("session_id"),
            profile: text("profile"),
        }
    }
}

/// A JSON-RPC id, preserving its type: `1` and `"1"` are different ids.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum RpcId {
    Int(i64),
    UInt(u64),
    Str(String),
}

impl RpcId {
    pub fn parse(value: &Value) -> Option<RpcId> {
        if let Some(n) = value.as_i64() {
            return Some(RpcId::Int(n));
        }
        if let Some(n) = value.as_u64() {
            return Some(RpcId::UInt(n));
        }
        value.as_str().map(|s| RpcId::Str(s.to_string()))
    }
}

/// Resume request ids this connection is still waiting on, with the key to cache the reply under.
///
/// Bounded and FIFO-evicted: a reply whose id was already forgotten is simply forwarded un-paged
/// (and, if it is huge, trimmed by the safety net), so the failure mode is a transcript that pages
/// less well, never a wrong page.
#[derive(Debug)]
pub struct ResumeRequests {
    max: usize,
    order: VecDeque<RpcId>,
    keys: HashMap<RpcId, HistoryKey>,
}

impl Default for ResumeRequests {
    fn default() -> Self {
        Self::new(MAX_TRACKED_RESUMES)
    }
}

impl ResumeRequests {
    pub fn new(max: usize) -> Self {
        Self {
            max: max.max(1),
            order: VecDeque::new(),
            keys: HashMap::new(),
        }
    }

    /// Asserted by the paging tests; the relay only asks `is_empty`.
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// Remember the `(session_id, profile)` a resume asked about, so its reply can be paged.
    pub fn note(&mut self, id: &Value, params: Option<&Value>) {
        let Some(id) = RpcId::parse(id) else {
            return;
        };
        self.keys.remove(&id);
        self.order.retain(|known| *known != id);
        self.order.push_back(id.clone());
        self.keys.insert(id, HistoryKey::from_params(params));
        while self.order.len() > self.max {
            if let Some(oldest) = self.order.pop_front() {
                self.keys.remove(&oldest);
            }
        }
    }

    /// Forget `id` and return the key its reply should be cached under.
    pub fn take(&mut self, id: &Value) -> Option<HistoryKey> {
        let id = RpcId::parse(id)?;
        let key = self.keys.remove(&id)?;
        self.order.retain(|known| *known != id);
        Some(key)
    }

    /// Forget every outstanding resume. Used when the engine connection dies: those ids belong to
    /// a socket that no longer exists, so a reply carrying one of them on the new socket would be
    /// paged against a resume that never happened.
    pub fn clear(&mut self) {
        self.order.clear();
        self.keys.clear();
    }
}

#[derive(Debug)]
struct CachedTranscript {
    rows: Vec<Value>,
    bytes: usize,
}

/// One older page: the rows, the offset its first row sits at, and the conversation's row count.
#[derive(Clone, Debug, PartialEq)]
pub struct HistoryPage {
    pub rows: Vec<Value>,
    pub cursor: Option<i64>,
    pub total: usize,
}

/// The transcripts this connection relayed, bounded and least-recently-used.
///
/// Keyed by `(session_id, profile)` — the id and bot the *client* resumed with — so a paging request
/// from the app finds the copy of the resume it was handed, and two bots that happen to share a
/// session id cannot read each other's rows.
#[derive(Debug)]
pub struct HistoryCache {
    max_bytes: usize,
    total: usize,
    order: VecDeque<HistoryKey>,
    rows: HashMap<HistoryKey, CachedTranscript>,
}

impl HistoryCache {
    pub fn new(max_bytes: usize) -> Self {
        Self {
            max_bytes,
            total: 0,
            order: VecDeque::new(),
            rows: HashMap::new(),
        }
    }

    /// Introspection used by the paging tests; the relay only needs `remember` and `page`.
    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    #[allow(dead_code)]
    pub fn total_bytes(&self) -> usize {
        self.total
    }

    #[allow(dead_code)]
    pub fn contains(&self, key: &HistoryKey) -> bool {
        self.rows.contains_key(key)
    }

    /// Keep `rows` for `key`, dropping the least recently used entries if over budget.
    pub fn remember(&mut self, key: HistoryKey, rows: Vec<Value>) {
        let bytes: usize = rows.iter().map(encoded_size).sum();
        self.forget(&key);
        self.order.push_back(key.clone());
        self.rows.insert(key, CachedTranscript { rows, bytes });
        self.total = self.total.saturating_add(bytes);
        // A single transcript larger than the whole budget is still worth caching: without it every
        // "load earlier" would need a fresh resume, which is the round trip this avoids. It is
        // admitted alone and the next `remember` evicts it.
        while self.total > self.max_bytes && self.order.len() > 1 {
            if let Some(oldest) = self.order.pop_front() {
                self.drop_entry(&oldest);
            }
        }
    }

    pub fn forget(&mut self, key: &HistoryKey) {
        if self.rows.contains_key(key) {
            self.drop_entry(key);
            self.order.retain(|known| known != key);
        }
    }

    fn drop_entry(&mut self, key: &HistoryKey) {
        if let Some(cached) = self.rows.remove(key) {
            self.total = self.total.saturating_sub(cached.bytes);
        }
    }

    /// The rows cached for `key`, touching the entry's LRU position. `None` when this connection
    /// never resumed it.
    #[allow(dead_code)]
    pub fn get(&mut self, key: &HistoryKey) -> Option<&[Value]> {
        if !self.rows.contains_key(key) {
            return None;
        }
        self.touch(key);
        self.rows.get(key).map(|cached| cached.rows.as_slice())
    }

    fn touch(&mut self, key: &HistoryKey) {
        self.order.retain(|known| known != key);
        self.order.push_back(key.clone());
    }

    /// Plan one older page for `key` — the cache's whole reason to exist.
    pub fn page(
        &mut self,
        key: &HistoryKey,
        cursor: i64,
        limit: usize,
        max_bytes: usize,
    ) -> Option<HistoryPage> {
        if !self.rows.contains_key(key) {
            return None;
        }
        self.touch(key);
        let cached = self.rows.get(key)?;
        let (page, next) = plan_before(&cached.rows, cursor, limit, max_bytes);
        Some(HistoryPage {
            rows: page.to_vec(),
            cursor: next,
            total: cached.rows.len(),
        })
    }
}

/// A client request to page one older slice of the transcript it already resumed.
#[derive(Clone, Debug, PartialEq)]
pub struct HistoryRequest {
    /// The `id` to echo back, kept as a `Value` so its type survives the round trip.
    pub id: Value,
    pub key: HistoryKey,
    pub cursor: i64,
    pub limit: usize,
}

/// `Some` only for a `session.history` that carries a numeric `cursor`.
///
/// A cursorless `session.history` is the app's older `history(limit:)` call and belongs to the
/// engine, so it must be forwarded unchanged.
pub fn history_request(frame: &Value) -> Option<HistoryRequest> {
    let object = frame.as_object()?;
    if object.get("method").and_then(Value::as_str) != Some("session.history") {
        return None;
    }
    let id = object.get("id")?;
    RpcId::parse(id)?;
    let params = object.get("params")?.as_object()?;
    // A bool is not a cursor: serde_json already keeps `true` out of `as_i64`, but reject floats and
    // strings too — the blueprint's `_is_cursor` is exactly "an int, not a bool".
    let cursor = params.get("cursor")?.as_i64()?;
    let limit = params
        .get("limit")
        .and_then(|v| v.as_u64())
        .and_then(|n| usize::try_from(n).ok())
        .filter(|n| *n > 0)
        .unwrap_or(PAGE_MESSAGES);
    Some(HistoryRequest {
        id: id.clone(),
        key: HistoryKey::from_map(params),
        cursor,
        limit,
    })
}

/// The JSON-RPC reply for one older page.
pub fn history_reply(id: &Value, page: &[Value], next_cursor: Option<i64>, total: usize) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "messages": page,
            "count": page.len(),
            "cursor": next_cursor,
            "total": total,
        }
    })
}

pub fn history_error(id: &Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}

/// Replace a `session.resume` reply's transcript with its newest page, and hand back the full array
/// so the caller can cache it.
///
/// `Err(frame)` means "this was not a resume reply I can page" and the frame must be forwarded
/// untouched — no `result.messages`, an empty transcript, a notification, an error reply.
pub fn page_resume_response(
    mut frame: Value,
    max_messages: usize,
    max_bytes: usize,
) -> Result<(Value, Vec<Value>), Value> {
    if frame.get("method").is_some() || frame.get("id").is_none() {
        return Err(frame);
    }
    if frame.get("result").and_then(Value::as_object).is_none() {
        return Err(frame);
    }
    let taken = match frame
        .get_mut("result")
        .and_then(|result| result.get_mut("messages"))
    {
        Some(slot) => std::mem::replace(slot, Value::Null),
        None => return Err(frame),
    };
    let rows = match taken {
        Value::Array(rows) => rows,
        other => {
            frame["result"]["messages"] = other;
            return Err(frame);
        }
    };
    if rows.is_empty() {
        frame["result"]["messages"] = Value::Array(rows);
        return Err(frame);
    }

    let (page, cursor) = plan_newest(&rows, max_messages, max_bytes);
    let shown = page.len();
    let total = rows.len();
    let page: Vec<Value> = page.to_vec();
    frame["result"]["messages"] = Value::Array(page);
    if let Some(result) = frame.get_mut("result").and_then(Value::as_object_mut) {
        result.insert(
            "history".to_string(),
            json!({ "total": total, "shown": shown, "cursor": cursor }),
        );
    }
    Ok((frame, rows))
}

/// What the safety net did, for a log line that carries no transcript content.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrimReport {
    pub bytes_before: usize,
    pub bytes_after: usize,
    /// Dotted path of the string field that was cut, e.g. `result.messages[12].content`.
    pub field: String,
    pub dropped: usize,
}

#[derive(Clone, Debug)]
enum Segment {
    Key(String),
    Index(usize),
}

/// Trim the largest string field of an oversized frame so it can still be delivered, and flag it.
///
/// `None` means the frame is already within budget, or its bulk is not string data (nothing safe to
/// cut) — the caller must then forward the original frame. When a string *is* cut, the frame gains a
/// top-level `_hermeyd_trimmed: {bytes_before, field}` so the client can tell the content is short.
pub fn trim_oversize(mut frame: Value, max_bytes: usize) -> Option<(Value, TrimReport)> {
    let bytes_before = encoded_size(&frame);
    if bytes_before <= max_bytes {
        return None;
    }
    if let Some(object) = frame.as_object_mut() {
        object.insert(
            "_hermeyd_trimmed".to_string(),
            json!({ "bytes_before": bytes_before }),
        );
    }

    let mut field = String::new();
    let mut dropped = 0usize;
    let mut size = encoded_size(&frame);
    // One huge tool result is the real case and needs one pass; the loop is for a frame whose bulk
    // is spread over several large strings. Bounded so a hostile frame cannot spin the relay.
    for _ in 0..64 {
        if size <= max_bytes {
            break;
        }
        let (path, length) = largest_string(&frame)?;
        // Shorter than this and cutting cannot pay for the marker, let alone the flag.
        if length < 1024 {
            return None;
        }
        let excess = size - max_bytes;
        let marker = "…[hermeyd trimmed]";
        let keep = length.saturating_sub(excess + marker.len() + 32);
        let slot = value_at_path_mut(&mut frame, &path)?;
        let text = match slot {
            Value::String(text) => text,
            _ => return None,
        };
        let cut = floor_char_boundary(text, keep);
        dropped += text.len() - cut;
        text.truncate(cut);
        text.push_str(marker);
        if field.is_empty() {
            field = path_label(&path);
        }
        size = encoded_size(&frame);
    }

    // The flag is filled in last so its own bytes are part of the budget it has to fit inside.
    if let Some(object) = frame.as_object_mut() {
        object.insert(
            "_hermeyd_trimmed".to_string(),
            json!({ "bytes_before": bytes_before, "field": field.clone() }),
        );
    }
    size = encoded_size(&frame);
    if size > max_bytes {
        // The field name made the flag a few bytes longer; take that out of the same string.
        if let Some((path, length)) = largest_string(&frame) {
            if length >= 1024 {
                let excess = size - max_bytes;
                let marker = "…[hermeyd trimmed]";
                let keep = length.saturating_sub(excess + marker.len() + 64);
                if let Some(Value::String(text)) = value_at_path_mut(&mut frame, &path) {
                    let cut = floor_char_boundary(text, keep);
                    dropped += text.len() - cut;
                    text.truncate(cut);
                    text.push_str(marker);
                    size = encoded_size(&frame);
                }
            }
        }
    }

    if size >= bytes_before {
        return None;
    }
    Some((
        frame,
        TrimReport {
            bytes_before,
            bytes_after: size,
            field,
            dropped,
        },
    ))
}

fn largest_string(value: &Value) -> Option<(Vec<Segment>, usize)> {
    fn walk(value: &Value, path: &mut Vec<Segment>, best: &mut Option<(Vec<Segment>, usize)>) {
        match value {
            Value::String(text) => {
                if best.as_ref().is_none_or(|(_, size)| text.len() > *size) {
                    *best = Some((path.clone(), text.len()));
                }
            }
            Value::Array(items) => {
                for (index, item) in items.iter().enumerate() {
                    path.push(Segment::Index(index));
                    walk(item, path, best);
                    path.pop();
                }
            }
            Value::Object(map) => {
                for (key, item) in map {
                    path.push(Segment::Key(key.clone()));
                    walk(item, path, best);
                    path.pop();
                }
            }
            _ => {}
        }
    }

    let mut best = None;
    walk(value, &mut Vec::new(), &mut best);
    best
}

fn value_at_path_mut<'a>(value: &'a mut Value, path: &[Segment]) -> Option<&'a mut Value> {
    let mut current = value;
    for segment in path {
        current = match segment {
            Segment::Key(key) => current.get_mut(key.as_str())?,
            Segment::Index(index) => current.get_mut(*index)?,
        };
    }
    Some(current)
}

fn path_label(path: &[Segment]) -> String {
    let mut label = String::new();
    for segment in path {
        match segment {
            Segment::Key(key) => {
                if !label.is_empty() {
                    label.push('.');
                }
                label.push_str(key);
            }
            Segment::Index(index) => {
                label.push('[');
                label.push_str(&index.to_string());
                label.push(']');
            }
        }
    }
    if label.is_empty() {
        label.push_str("<root>");
    }
    label
}

/// Largest char boundary at or below `index`, so cutting a UTF-8 string can never panic.
fn floor_char_boundary(text: &str, index: usize) -> usize {
    let mut cut = index.min(text.len());
    while cut > 0 && !text.is_char_boundary(cut) {
        cut -= 1;
    }
    cut
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(index: usize, payload: usize) -> Value {
        json!({
            "id": format!("m{index:04}"),
            "role": if index % 2 == 0 { "user" } else { "assistant" },
            "content": "x".repeat(payload),
        })
    }

    fn rows(count: usize, payload: usize) -> Vec<Value> {
        (0..count).map(|i| row(i, payload)).collect()
    }

    fn page_bytes(page: &[Value]) -> usize {
        page.iter().map(encoded_size).sum()
    }

    fn compact(value: &Value) -> String {
        serde_json::to_string(value).expect("value serialises")
    }

    // -- planning, newest page -------------------------------------------------------------

    #[test]
    fn encoded_size_is_compact_json_utf8_bytes() {
        assert_eq!(encoded_size(&json!({"a": 1})), 7);
        assert_eq!(encoded_size(&json!("é")), 2 + "é".len());
    }

    #[test]
    fn plan_newest_keeps_the_message_cap() {
        let transcript = rows(450, 8);
        let (page, cursor) = plan_newest(&transcript, 200, PAGE_BYTES);
        assert_eq!(page.len(), 200);
        assert_eq!(cursor, Some(250));
        assert_eq!(page, &transcript[250..]);
    }

    #[test]
    fn plan_newest_stops_on_the_byte_budget_before_the_message_cap() {
        let transcript = rows(10, 400);
        let budget = 1000;
        let (page, cursor) = plan_newest(&transcript, 200, budget);
        assert_eq!(page.len(), 2, "only two ~440-byte rows fit in 1000 bytes");
        assert!(page_bytes(page) <= budget);
        assert_eq!(cursor, Some(8));
        assert_eq!(page, &transcript[8..]);
    }

    #[test]
    fn plan_newest_always_ships_one_row_even_over_the_byte_budget() {
        let transcript = rows(3, 5000);
        let (page, cursor) = plan_newest(&transcript, 200, 64);
        assert_eq!(page.len(), 1, "an empty resume looks like a lost conversation");
        assert_eq!(cursor, Some(2));
        assert_eq!(page[0], transcript[2]);
    }

    #[test]
    fn plan_newest_of_a_whole_conversation_has_no_cursor() {
        let transcript = rows(5, 8);
        let (page, cursor) = plan_newest(&transcript, 200, PAGE_BYTES);
        assert_eq!(page, &transcript[..]);
        assert_eq!(cursor, None, "the whole transcript is not a page boundary");
    }

    #[test]
    fn plan_newest_of_an_empty_transcript_is_empty() {
        let (page, cursor) = plan_newest(&[], 200, PAGE_BYTES);
        assert!(page.is_empty());
        assert_eq!(cursor, None);
    }

    // -- planning, older pages -------------------------------------------------------------

    #[test]
    fn plan_before_walks_back_contiguously() {
        let transcript = rows(400, 8);
        let (page, next) = plan_before(&transcript, 300, 50, PAGE_BYTES);
        assert_eq!(page, &transcript[250..300]);
        assert_eq!(next, Some(250));
    }

    #[test]
    fn plan_before_reaching_the_start_returns_no_cursor() {
        let transcript = rows(400, 8);
        let (page, next) = plan_before(&transcript, 40, 50, PAGE_BYTES);
        assert_eq!(page, &transcript[0..40]);
        assert_eq!(next, None, "the page reaches the start of the conversation");
    }

    #[test]
    fn plan_before_clamps_a_cursor_past_the_end() {
        let transcript = rows(400, 8);
        let (page, next) = plan_before(&transcript, 99_999, 10, PAGE_BYTES);
        assert_eq!(page, &transcript[390..]);
        assert_eq!(next, Some(390));
    }

    #[test]
    fn plan_before_at_zero_returns_nothing() {
        let transcript = rows(10, 8);
        let (page, next) = plan_before(&transcript, 0, 10, PAGE_BYTES);
        assert!(page.is_empty());
        assert_eq!(next, None);
        let (page, next) = plan_before(&transcript, -5, 10, PAGE_BYTES);
        assert!(page.is_empty());
        assert_eq!(next, None);
    }

    #[test]
    fn plan_before_with_a_zero_limit_moves_nothing() {
        let transcript = rows(10, 8);
        let (page, next) = plan_before(&transcript, 4, 0, PAGE_BYTES);
        assert!(page.is_empty());
        assert_eq!(next, Some(4), "the cursor must not move when no rows were read");
    }

    #[test]
    fn plan_before_honours_the_byte_budget_but_keeps_one_row() {
        let transcript = rows(10, 400);
        let (page, next) = plan_before(&transcript, 10, 200, 1000);
        assert_eq!(page.len(), 2);
        assert!(page_bytes(page) <= 1000);
        assert_eq!(next, Some(8));

        let (page, next) = plan_before(&transcript, 10, 200, 1);
        assert_eq!(page.len(), 1, "at least one row per page");
        assert_eq!(next, Some(9));
    }

    // -- the real bug ----------------------------------------------------------------------

    #[test]
    fn three_point_four_megabyte_transcript_pages_under_the_byte_budget() {
        let transcript = rows(1450, 2400);
        let total_bytes = page_bytes(&transcript);
        assert!(
            total_bytes > 3 * 1024 * 1024,
            "synthetic transcript is only {total_bytes} bytes"
        );

        let (newest, cursor) = plan_newest(&transcript, PAGE_MESSAGES, PAGE_BYTES);
        let cursor = cursor.expect("1450 rows over 512 KiB must page");
        assert!(newest.len() <= PAGE_MESSAGES);
        assert!(page_bytes(newest) <= PAGE_BYTES);
        assert_eq!(newest, &transcript[cursor as usize..]);

        // Walk every page down to the start, exactly the way the client prepends them: contiguous,
        // no repeats, no gaps, every page under budget, and the whole transcript reconstructs.
        let mut assembled: Vec<Value> = newest.to_vec();
        let mut at = Some(cursor);
        let mut pages = 1;
        while let Some(c) = at {
            let (page, next) = plan_before(&transcript, c, 150, PAGE_BYTES);
            assert!(!page.is_empty(), "a page with rows left must not be empty");
            assert!(page_bytes(page) <= PAGE_BYTES);
            let start = next.unwrap_or(0) as usize;
            assert_eq!(page, &transcript[start..c as usize], "page is not contiguous");
            assembled.splice(0..0, page.iter().cloned());
            at = next;
            pages += 1;
            assert!(pages < 100, "paging never reached the start");
        }
        assert!(pages > 1);
        assert_eq!(assembled, transcript, "paging lost or duplicated rows");
    }

    // -- cache -----------------------------------------------------------------------------

    #[test]
    fn cache_returns_the_rows_it_was_given() {
        let key = HistoryKey::new("s1", "bot");
        let transcript = rows(5, 8);
        let mut cache = HistoryCache::new(CACHE_BYTES);
        cache.remember(key.clone(), transcript.clone());
        assert_eq!(cache.get(&key), Some(transcript.as_slice()));
        assert_eq!(cache.len(), 1);
        assert!(cache.total_bytes() > 0);
    }

    #[test]
    fn cache_isolates_sessions_and_profiles() {
        let mut cache = HistoryCache::new(CACHE_BYTES);
        let a = HistoryKey::new("s1", "bot-a");
        let b = HistoryKey::new("s1", "bot-b");
        let c = HistoryKey::new("s2", "bot-a");
        cache.remember(a.clone(), rows(3, 8));
        cache.remember(b.clone(), rows(4, 8));
        cache.remember(c.clone(), rows(5, 8));
        assert_eq!(cache.get(&a).map(<[Value]>::len), Some(3));
        assert_eq!(cache.get(&b).map(<[Value]>::len), Some(4));
        assert_eq!(cache.get(&c).map(<[Value]>::len), Some(5));
        assert_eq!(cache.len(), 3);
    }

    #[test]
    fn caches_are_per_connection() {
        let key = HistoryKey::new("s1", "bot");
        let mut first = HistoryCache::new(CACHE_BYTES);
        let mut second = HistoryCache::new(CACHE_BYTES);
        first.remember(key.clone(), rows(2, 8));
        assert!(first.contains(&key));
        assert!(!second.contains(&key), "a second socket starts empty");
        assert!(second.page(&key, 2, 10, PAGE_BYTES).is_none());
    }

    #[test]
    fn cache_evicts_the_least_recently_used_transcript() {
        let mut cache = HistoryCache::new(1000);
        let a = HistoryKey::new("a", "p");
        let b = HistoryKey::new("b", "p");
        let c = HistoryKey::new("c", "p");
        cache.remember(a.clone(), vec![row(0, 300)]);
        cache.remember(b.clone(), vec![row(1, 300)]);
        assert!(cache.get(&a).is_some(), "touch a so b becomes the LRU entry");
        cache.remember(c.clone(), vec![row(2, 300)]);
        assert!(cache.contains(&a));
        assert!(!cache.contains(&b), "the untouched entry is the one evicted");
        assert!(cache.contains(&c));
        assert!(cache.total_bytes() <= 1000);
    }

    #[test]
    fn cache_replacing_a_key_does_not_double_count() {
        let mut cache = HistoryCache::new(CACHE_BYTES);
        let key = HistoryKey::new("s1", "bot");
        cache.remember(key.clone(), rows(2, 8));
        let once = cache.total_bytes();
        cache.remember(key.clone(), rows(2, 8));
        assert_eq!(cache.len(), 1);
        assert_eq!(cache.total_bytes(), once);
    }

    #[test]
    fn cache_forget_releases_budget() {
        let mut cache = HistoryCache::new(CACHE_BYTES);
        let key = HistoryKey::new("s1", "bot");
        cache.remember(key.clone(), rows(2, 80));
        assert!(cache.total_bytes() > 0);
        cache.forget(&key);
        assert_eq!(cache.total_bytes(), 0);
        assert!(cache.is_empty());
        assert!(cache.get(&key).is_none());
    }

    #[test]
    fn cache_keeps_one_transcript_larger_than_its_whole_budget() {
        let mut cache = HistoryCache::new(128);
        let big = HistoryKey::new("big", "p");
        let small = HistoryKey::new("small", "p");
        cache.remember(big.clone(), rows(4, 200));
        assert!(
            cache.contains(&big),
            "an oversized resume must still be pageable"
        );
        cache.remember(small.clone(), rows(1, 8));
        assert!(cache.contains(&small));
        assert!(!cache.contains(&big), "the oversized entry is evicted next");
        assert!(cache.total_bytes() <= 128);
    }

    #[test]
    fn cache_page_ends_where_the_callers_oldest_row_begins() {
        let mut cache = HistoryCache::new(CACHE_BYTES);
        let key = HistoryKey::new("s1", "bot");
        let transcript = rows(400, 8);
        cache.remember(key.clone(), transcript.clone());
        let page = cache
            .page(&key, 200, 50, PAGE_BYTES)
            .expect("the transcript is cached");
        assert_eq!(page.rows, transcript[150..200]);
        assert_eq!(page.cursor, Some(150));
        assert_eq!(page.total, 400);

        let page = cache.page(&key, 120, 500, PAGE_BYTES).expect("cached");
        assert_eq!(page.rows, transcript[0..120]);
        assert_eq!(page.cursor, None);
        assert!(cache.page(&HistoryKey::new("other", "bot"), 1, 1, PAGE_BYTES).is_none());
    }

    // -- frame surgery ---------------------------------------------------------------------

    #[test]
    fn resume_reply_is_replaced_by_its_newest_page_and_gains_history() {
        let transcript = rows(400, 200);
        let frame = json!({
            "jsonrpc": "2.0",
            "id": 7,
            "result": {
                "session_id": "runtime-1",
                "messages": transcript,
                "inflight": Value::Null,
            },
        });
        let (paged, cached) =
            page_resume_response(frame, PAGE_MESSAGES, PAGE_BYTES).expect("a 400-row resume pages");
        assert_eq!(cached, transcript);

        let result = paged["result"].as_object().expect("result stays an object");
        let messages = result["messages"].as_array().expect("messages stays an array");
        assert_eq!(messages.len(), PAGE_MESSAGES);
        assert_eq!(result["history"]["total"], json!(400));
        assert_eq!(result["history"]["shown"], json!(PAGE_MESSAGES));
        assert_eq!(result["history"]["cursor"], json!(200));
        assert_eq!(result["session_id"], json!("runtime-1"), "other fields survive");
        assert_eq!(result["inflight"], Value::Null);
        assert_eq!(messages.last(), cached.last());
    }

    #[test]
    fn a_short_resume_reply_ships_whole_with_a_null_cursor() {
        let transcript = rows(3, 8);
        let frame = json!({"jsonrpc": "2.0", "id": 1, "result": {"messages": transcript}});
        let (paged, cached) = page_resume_response(frame, PAGE_MESSAGES, PAGE_BYTES).unwrap();
        assert_eq!(paged["result"]["messages"], json!(transcript));
        assert_eq!(paged["result"]["history"]["cursor"], Value::Null);
        assert_eq!(paged["result"]["history"]["shown"], json!(3));
        assert_eq!(cached, transcript);
    }

    #[test]
    fn replies_without_messages_are_left_alone() {
        for frame in [
            json!({"jsonrpc": "2.0", "id": 1, "result": {"ok": true}}),
            json!({"jsonrpc": "2.0", "id": 1, "result": {"messages": []}}),
            json!({"jsonrpc": "2.0", "id": 1, "result": {"messages": "nope"}}),
            json!({"jsonrpc": "2.0", "id": 1, "error": {"code": 1, "message": "no"}}),
            json!({"jsonrpc": "2.0", "method": "event", "params": {}}),
        ] {
            let original = compact(&frame);
            let Err(returned) =
                page_resume_response(frame, PAGE_MESSAGES, PAGE_BYTES)
            else {
                panic!("frame should not have been paged: {original}");
            };
            assert_eq!(compact(&returned), original, "the frame must be unchanged");
        }
    }

    #[test]
    fn history_request_needs_a_numeric_cursor() {
        let paged = json!({
            "jsonrpc": "2.0", "id": 2, "method": "session.history",
            "params": {"session_id": "s1", "profile": "bot", "cursor": 40, "limit": 50},
        });
        let request = history_request(&paged).expect("a numeric cursor is a page request");
        assert_eq!(request.cursor, 40);
        assert_eq!(request.limit, 50);
        assert_eq!(request.key, HistoryKey::new("s1", "bot"));
        assert_eq!(request.id, json!(2));

        // The app's older `history(limit:)` call carries no cursor and belongs to the engine.
        for cursorless in [
            json!({"jsonrpc": "2.0", "id": 3, "method": "session.history",
                   "params": {"session_id": "s1"}}),
            json!({"jsonrpc": "2.0", "id": 3, "method": "session.history",
                   "params": {"session_id": "s1", "cursor": "40"}}),
            json!({"jsonrpc": "2.0", "id": 3, "method": "session.history",
                   "params": {"session_id": "s1", "cursor": true}}),
            json!({"jsonrpc": "2.0", "id": 3, "method": "session.history",
                   "params": {"session_id": "s1", "cursor": 1.5}}),
            json!({"jsonrpc": "2.0", "id": 3, "method": "session.history"}),
            json!({"jsonrpc": "2.0", "id": 3, "method": "session.resume",
                   "params": {"session_id": "s1", "cursor": 40}}),
        ] {
            assert!(history_request(&cursorless).is_none(), "{cursorless}");
        }
    }

    #[test]
    fn history_request_defaults_a_missing_or_silly_limit() {
        let frame = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.history",
            "params": {"session_id": "s1", "cursor": 10},
        });
        assert_eq!(history_request(&frame).unwrap().limit, PAGE_MESSAGES);
        let frame = json!({
            "jsonrpc": "2.0", "id": 1, "method": "session.history",
            "params": {"session_id": "s1", "cursor": 10, "limit": 0},
        });
        assert_eq!(history_request(&frame).unwrap().limit, PAGE_MESSAGES);
    }

    #[test]
    fn history_reply_echoes_the_id_type_and_carries_the_next_cursor() {
        let page = rows(2, 8);
        let reply = history_reply(&json!(5), &page, Some(20), 40);
        assert_eq!(reply["id"], json!(5));
        assert_eq!(reply["result"]["messages"], json!(page));
        assert_eq!(reply["result"]["count"], json!(2));
        assert_eq!(reply["result"]["cursor"], json!(20));
        assert_eq!(reply["result"]["total"], json!(40));

        let reply = history_reply(&json!("abc"), &page, None, 2);
        assert_eq!(reply["id"], json!("abc"), "a string id stays a string");
        assert_eq!(reply["result"]["cursor"], Value::Null);
    }

    #[test]
    fn history_error_has_the_jsonrpc_error_shape() {
        let error = history_error(&json!(9), ERROR_HISTORY_UNAVAILABLE, "history page unavailable");
        assert_eq!(error["id"], json!(9));
        assert_eq!(error["error"]["code"], json!(-32001));
        assert!(error.get("result").is_none());
    }

    #[test]
    fn resume_requests_are_keyed_by_id_type() {
        let mut pending = ResumeRequests::new(8);
        pending.note(&json!(1), Some(&json!({"session_id": "int", "profile": "p"})));
        pending.note(&json!("1"), Some(&json!({"session_id": "str", "profile": "p"})));
        assert_eq!(pending.len(), 2, "1 and \"1\" are different JSON-RPC ids");
        assert_eq!(
            pending.take(&json!("1")),
            Some(HistoryKey::new("str", "p"))
        );
        assert_eq!(pending.take(&json!(1)), Some(HistoryKey::new("int", "p")));
        assert!(pending.is_empty());
    }

    #[test]
    fn resume_requests_forget_the_oldest_when_full() {
        let mut pending = ResumeRequests::new(2);
        for id in 1..=3 {
            pending.note(&json!(id), Some(&json!({"session_id": format!("s{id}")})));
        }
        assert_eq!(pending.len(), 2);
        assert!(pending.take(&json!(1)).is_none(), "oldest id was forgotten");
        assert!(pending.take(&json!(2)).is_some());
        assert!(pending.take(&json!(3)).is_some());
    }

    #[test]
    fn resume_requests_fall_back_to_empty_strings_for_odd_params() {
        let mut pending = ResumeRequests::new(4);
        pending.note(&json!(3), None);
        assert_eq!(pending.take(&json!(3)), Some(HistoryKey::default()));
    }

    // -- the safety net --------------------------------------------------------------------

    #[test]
    fn trim_leaves_a_frame_within_budget_alone() {
        let frame = json!({"jsonrpc": "2.0", "id": 1, "result": {"content": "small"}});
        assert!(trim_oversize(frame, MAX_RELAY_BYTES).is_none());
    }

    #[test]
    fn trim_cuts_the_largest_string_and_flags_the_frame() {
        let frame = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "messages": [{"role": "tool", "content": "a".repeat(3 * 1024 * 1024)}],
                "keep": "this is small",
            },
        });
        let (trimmed, report) = trim_oversize(frame, MAX_RELAY_BYTES).expect("3 MiB must trim");
        assert!(encoded_size(&trimmed) <= MAX_RELAY_BYTES);
        assert!(report.bytes_before > MAX_RELAY_BYTES);
        assert!(report.dropped > 0);
        assert_eq!(report.field, "result.messages[0].content");
        assert_eq!(trimmed["result"]["keep"], json!("this is small"));
        let content = trimmed["result"]["messages"][0]["content"]
            .as_str()
            .expect("content stays a string");
        assert!(content.ends_with("…[hermeyd trimmed]"));
        assert!(content.starts_with('a'), "the head of the content is kept");
        assert_eq!(
            trimmed["_hermeyd_trimmed"]["bytes_before"],
            json!(report.bytes_before)
        );
        assert_eq!(trimmed["_hermeyd_trimmed"]["field"], json!(report.field));
    }

    #[test]
    fn trim_never_splits_a_utf8_codepoint() {
        let frame = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": {"content": "é".repeat(1024 * 1024)},
        });
        let (trimmed, _) = trim_oversize(frame, MAX_RELAY_BYTES).expect("must trim");
        assert!(encoded_size(&trimmed) <= MAX_RELAY_BYTES);
        // `as_str` on a `Value` is UTF-8 by construction; just prove a round trip still parses.
        let text = trimmed["result"]["content"].as_str().unwrap();
        assert!(text.ends_with("…[hermeyd trimmed]"));
    }

    #[test]
    fn trim_gives_up_when_the_bulk_is_not_string_data() {
        let numbers: Vec<Value> = (0..400_000).map(|n| json!(n)).collect();
        let frame = json!({"jsonrpc": "2.0", "id": 1, "result": {"rows": numbers}});
        assert!(encoded_size(&frame) > MAX_RELAY_BYTES);
        assert!(
            trim_oversize(frame, MAX_RELAY_BYTES).is_none(),
            "there is no string field to cut, so the frame is forwarded untouched"
        );
    }
}
