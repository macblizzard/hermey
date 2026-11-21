//! The two `skills.manage` wire shapes, discovered at runtime.
//!
//! The Skills page sends `skills.manage {action:"list", session_id}` so the engine resolves the
//! **bot's own** skills tree. Our build carries two local patches for that
//! (`patches/0001-skills-manage-session-scope.patch`, `0002-skills-search-metadata-field.patch`):
//! `session_id` is an accepted contract field, and `action:"search"` returns rows. A stock Hermes
//! install has neither:
//!
//! * `session_id` is rejected by pydantic as `Extra inputs are not permitted` (code **4000**);
//! * `action:"search"` raises `'SkillMeta' object has no attribute 'describe'` (code **5024**).
//!
//! Neither is something the app should ever see: a stock engine is a supported host, and the
//! Skills page must still render (the launch-profile tree, and an empty search) instead of an
//! error card. So the relay speaks the shape the engine accepted *last time*, and learns it from
//! the engine's own refusal:
//!
//! * **optimistic first contact** — send `session_id`; our engine takes it, so nothing changes on
//!   the host that needs the session scope most;
//! * **one retry** — a 4000 that names `session_id` is answered by re-sending the same request ids
//!   for `session_id` and recording `ProfileOnly` for the life of the process;
//! * **search is best effort** — a 5024 (or the `.describe()` attribute error) becomes an empty,
//!   flagged result; later searches are answered from the relay without a round trip.
//!
//! Everything here is pure state plus one process-global instance, so the relay stays a splice and
//! the decisions are unit-testable without a socket (`relay.rs` wires it).

use serde_json::{Map, Value};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::OnceLock;

/// pydantic's "extra inputs are not permitted" rejection — the engine's contract validator.
pub const ERROR_EXTRA_INPUT: i64 = 4000;
/// The engine handler's own crash code (`'SkillMeta' object has no attribute 'describe'`).
pub const ERROR_HANDLER: i64 = 5024;

/// What the engine's `skills.manage` contract accepts for a session-scoped list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionShape {
    /// Nothing learned yet: send `session_id` (our build) and watch for a refusal.
    Unknown,
    /// The engine took `session_id` — our patched build.
    SessionScoped,
    /// The engine refused `session_id` — a stock build. Omit it from now on.
    ProfileOnly,
}

/// Whether `action:"search"` can produce rows on this engine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SearchSupport {
    Unknown,
    Supported,
    /// The engine's handler raises before it can answer; search is answered locally as empty.
    Unavailable,
}

/// The two read-only actions the relay forwards (`install`/`browse`/`inspect` stay refused by
/// policy — see `relay::skills_manage_allowed`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    List,
    Search,
}

impl Action {
    fn parse(params: &Map<String, Value>) -> Option<Self> {
        match params.get("action") {
            None => Some(Action::List),
            Some(Value::String(action)) if action == "list" => Some(Action::List),
            Some(Value::String(action)) if action == "search" => Some(Action::Search),
            _ => None,
        }
    }
}

/// One in-flight `skills.manage` whose reply may carry a dialect signal.
///
/// `params` is what was actually sent, so a retry is the same request minus `session_id` — the
/// `profile`, `query` and paging arguments must survive it.
#[derive(Clone, Debug, PartialEq)]
pub struct Track {
    pub action: Action,
    /// The forwarded request carried `session_id`.
    pub carried_session: bool,
    /// This request is already the retry; a second refusal is passed to the app.
    pub retried: bool,
    pub params: Map<String, Value>,
}

impl Track {
    /// The same request without `session_id`, marked as the one retry.
    pub fn without_session(&self) -> Self {
        let mut params = self.params.clone();
        params.remove("session_id");
        Self {
            action: self.action,
            carried_session: false,
            retried: true,
            params,
        }
    }
}

/// What the relay should do with one client frame before forwarding it.
#[derive(Debug)]
pub enum Outbound {
    /// Forward `wire`; `track` (when present) must be remembered against the request id.
    Send { wire: Value, track: Option<Track> },
    /// Answer the app from the relay instead of forwarding — search is known to be unusable.
    Answer(Value),
}

/// What an engine refusal means for the request the relay is tracking.
#[derive(Debug, PartialEq)]
pub enum Reaction {
    /// Not a dialect signal (or already retried): let the error reach the app.
    Pass,
    /// Re-send under the same id, without `session_id`.
    Retry { params: Map<String, Value>, track: Track },
    /// The app gets this `result` instead of the engine's error.
    Degrade(Value),
}

/// The result a degraded search answers with. `results` is the key the app decodes, so an empty
/// list renders as "no matches" rather than a failed page; `degraded` says why to anyone reading
/// the wire, and `reason` never carries a Python traceback.
pub fn degraded_search() -> Value {
    serde_json::json!({
        "results": [],
        "degraded": true,
        "reason": "skills search is not available on this engine",
    })
}

/// pydantic's extra-field refusal, and only when it is about `session_id`:
/// an unrelated 4000 must not be mistaken for a dialect signal.
pub fn is_session_refusal(code: Option<i64>, message: &str) -> bool {
    let lower = message.to_lowercase();
    let names_session = lower.contains("session_id");
    match code {
        Some(ERROR_EXTRA_INPUT) => names_session || lower.contains("extra inputs are not permitted"),
        _ => names_session && lower.contains("extra inputs"),
    }
}

/// The stock engine's broken `_skills_search`, by code or by its own message (a handler crash is
/// 5024; the attribute error is what says *which* handler).
pub fn is_search_refusal(code: Option<i64>, message: &str) -> bool {
    let lower = message.to_lowercase();
    code == Some(ERROR_HANDLER)
        || lower.contains("has no attribute 'describe'")
        || lower.contains("has no attribute \"describe\"")
}

/// Process-wide dialect. One engine per host, so one answer per process: a retry learned once is
/// remembered for every later socket instead of costing every app connection a failed round trip.
#[derive(Debug)]
pub struct EngineDialect {
    session: AtomicU8,
    search: AtomicU8,
}

const UNKNOWN: u8 = 0;
const YES: u8 = 1;
const NO: u8 = 2;

impl Default for EngineDialect {
    fn default() -> Self {
        Self::new()
    }
}

impl EngineDialect {
    pub fn new() -> Self {
        Self {
            session: AtomicU8::new(UNKNOWN),
            search: AtomicU8::new(UNKNOWN),
        }
    }

    /// The one the live relay uses. Tests build their own so parallel cases cannot learn from each
    /// other (and a test never poisons the real process's memory).
    pub fn shared() -> std::sync::Arc<EngineDialect> {
        static SHARED: OnceLock<std::sync::Arc<EngineDialect>> = OnceLock::new();
        SHARED
            .get_or_init(|| std::sync::Arc::new(EngineDialect::new()))
            .clone()
    }

    pub fn session(&self) -> SessionShape {
        match self.session.load(Ordering::Relaxed) {
            YES => SessionShape::SessionScoped,
            NO => SessionShape::ProfileOnly,
            _ => SessionShape::Unknown,
        }
    }

    pub fn search(&self) -> SearchSupport {
        match self.search.load(Ordering::Relaxed) {
            YES => SearchSupport::Supported,
            NO => SearchSupport::Unavailable,
            _ => SearchSupport::Unknown,
        }
    }

    /// Record what the engine's answer proved. Called on a successful reply as well: a reply that
    /// is not an error *is* the proof that the shape was accepted.
    pub fn note_accepted(&self, track: &Track) {
        if track.carried_session && self.session() == SessionShape::Unknown {
            self.session.store(YES, Ordering::Relaxed);
        }
        if track.action == Action::Search && self.search() == SearchSupport::Unknown {
            self.search.store(YES, Ordering::Relaxed);
        }
    }

    /// Shape one outbound `skills.manage` frame.
    ///
    /// `params` is the client's object as it stands (after alias adoption). Returns the frame to
    /// forward — with `session_id` removed when this engine is known to refuse it — or the local
    /// answer when search is already known to be unusable.
    pub fn prepare(&self, params: &Map<String, Value>) -> Outbound {
        let Some(action) = Action::parse(params) else {
            // Not a shape this module knows (policy normally refuses it first). Pass it through.
            return Outbound::Send {
                wire: Value::Object(params.clone()),
                track: None,
            };
        };
        if action == Action::Search && self.search() == SearchSupport::Unavailable {
            return Outbound::Answer(degraded_search());
        }

        let mut shaped = params.clone();
        if self.session() == SessionShape::ProfileOnly {
            shaped.remove("session_id");
        }
        let track = Track {
            action,
            carried_session: shaped.contains_key("session_id"),
            retried: false,
            params: shaped.clone(),
        };
        Outbound::Send {
            wire: Value::Object(shaped),
            track: Some(track),
        }
    }

    /// Interpret one error reply for a tracked request.
    pub fn on_error(&self, track: &Track, code: Option<i64>, message: &str) -> Reaction {
        if track.action == Action::Search && self.search() != SearchSupport::Unavailable
            && is_search_refusal(code, message)
        {
            self.search.store(NO, Ordering::Relaxed);
            return Reaction::Degrade(degraded_search());
        }
        if track.carried_session
            && !track.retried
            && self.session() != SessionShape::ProfileOnly
            && is_session_refusal(code, message)
        {
            self.session.store(NO, Ordering::Relaxed);
            let retry = track.without_session();
            return Reaction::Retry {
                params: retry.params.clone(),
                track: retry,
            };
        }
        Reaction::Pass
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn params(value: Value) -> Map<String, Value> {
        value.as_object().expect("object params").clone()
    }

    fn sent(out: Outbound) -> (Value, Track) {
        match out {
            Outbound::Send { wire, track } => (wire, track.expect("a skills.manage is tracked")),
            Outbound::Answer(answer) => panic!("expected a forward, got {answer}"),
        }
    }

    /// Our patched engine: the first list carries `session_id`, the reply is not an error, and the
    /// shape is remembered as accepted — nothing is ever stripped.
    #[test]
    fn a_patched_engine_keeps_receiving_session_id() {
        let dialect = EngineDialect::new();
        let (wire, track) = sent(dialect.prepare(&params(
            json!({"action": "list", "profile": "cody", "session_id": "s-1"}),
        )));
        assert_eq!(wire["session_id"], "s-1", "the first call must stay optimistic");
        assert!(track.carried_session);
        dialect.note_accepted(&track);
        assert_eq!(dialect.session(), SessionShape::SessionScoped);

        let (wire, _) = sent(dialect.prepare(&params(
            json!({"action": "list", "profile": "cody", "session_id": "s-2"}),
        )));
        assert_eq!(wire["session_id"], "s-2", "a verified engine keeps its session scope");
    }

    /// Stock engine: 4000 names `session_id` → one retry with the same id and every other argument
    /// intact → ProfileOnly for the life of the process, so the *next* call never sends it.
    #[test]
    fn a_rejected_session_id_is_retried_once_without_it_and_remembered() {
        let dialect = EngineDialect::new();
        let (_, track) = sent(dialect.prepare(&params(
            json!({"action": "list", "profile": "cody", "session_id": "s-1"}),
        )));
        let reaction = dialect.on_error(
            &track,
            Some(ERROR_EXTRA_INPUT),
            "session_id: Extra inputs are not permitted",
        );
        let (retry_params, retry_track) = match reaction {
            Reaction::Retry { params, track } => (params, track),
            other => panic!("expected a retry, got {other:?}"),
        };
        assert!(!retry_params.contains_key("session_id"));
        assert_eq!(retry_params["profile"], "cody", "the retry keeps its scope");
        assert_eq!(retry_params["action"], "list");
        assert!(retry_track.retried);
        assert_eq!(dialect.session(), SessionShape::ProfileOnly);

        let (wire, next) = sent(dialect.prepare(&params(
            json!({"action": "list", "profile": "cody", "session_id": "s-2"}),
        )));
        assert!(!wire.to_string().contains("session_id"), "remembered: {wire}");
        assert!(!next.carried_session);

        // A second refusal of the same request is the app's to see — one retry, never a loop.
        let again = dialect.on_error(
            &retry_track,
            Some(ERROR_EXTRA_INPUT),
            "session_id: Extra inputs are not permitted",
        );
        assert_eq!(again, Reaction::Pass);
    }

    /// Stock engine: `search` crashes with 5024. The app gets an empty, flagged result now, and
    /// later searches are answered locally (no extra round trip, no error card).
    #[test]
    fn a_stock_engines_broken_search_degrades_to_an_empty_result() {
        let dialect = EngineDialect::new();
        let (_, track) = sent(dialect.prepare(&params(
            json!({"action": "search", "query": "pdf", "session_id": "s-1"}),
        )));
        let degraded = match dialect.on_error(
            &track,
            Some(ERROR_HANDLER),
            "'SkillMeta' object has no attribute 'describe'",
        ) {
            Reaction::Degrade(result) => result,
            other => panic!("expected a degraded result, got {other:?}"),
        };
        assert_eq!(degraded["results"], json!([]));
        assert_eq!(degraded["degraded"], true);
        assert_eq!(dialect.search(), SearchSupport::Unavailable);

        match dialect.prepare(&params(json!({"action": "search", "query": "x"}))) {
            Outbound::Answer(answer) => assert_eq!(answer["results"], json!([])),
            Outbound::Send { .. } => panic!("a search on a broken handler must not be forwarded"),
        }
        // A list is unaffected by the search verdict.
        let (wire, _) = sent(dialect.prepare(&params(
            json!({"action": "list", "profile": "cody"}),
        )));
        assert_eq!(wire["action"], "list");
    }

    /// The two refusals are told apart: an unrelated 4000 (a bad `page`, say) must not strip the
    /// session, and a 5024 on a *list* is a real engine bug the app should see.
    #[test]
    fn only_a_session_refusal_strips_the_session_and_only_a_search_degrades() {
        let dialect = EngineDialect::new();
        let (_, track) = sent(dialect.prepare(&params(
            json!({"action": "list", "session_id": "s-1"}),
        )));
        assert_eq!(
            dialect.on_error(&track, Some(ERROR_EXTRA_INPUT), "page: Input should be a valid integer"),
            Reaction::Pass
        );
        assert_eq!(dialect.session(), SessionShape::Unknown, "no false learning");

        let (_, list_track) = sent(dialect.prepare(&params(
            json!({"action": "list", "session_id": "s-1"}),
        )));
        assert_eq!(
            dialect.on_error(&list_track, Some(ERROR_HANDLER), "handler blew up"),
            Reaction::Pass,
            "a 5024 on a list is a genuine engine error, not a search verdict"
        );
        assert_eq!(dialect.search(), SearchSupport::Unknown);
    }

    #[test]
    fn the_retry_is_the_same_request_without_the_session_only() {
        let track = Track {
            action: Action::List,
            carried_session: true,
            retried: false,
            params: params(json!({
                "action": "list", "profile": "cody", "session_id": "s-1", "page": 2
            })),
        };
        let retry = track.without_session();
        assert_eq!(
            Value::Object(retry.params),
            json!({"action": "list", "profile": "cody", "page": 2})
        );
        assert!(retry.retried);
    }
}
