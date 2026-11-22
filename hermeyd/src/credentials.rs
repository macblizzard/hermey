//! Login cards: the bot asks, the owner answers, the bot consumes — once.
//!
//! ```text
//! GET  /v1/credentials/cards              → [{kind,id,site,fields,options,note,asked_by,state,expires_at}]
//! POST /v1/credentials/cards              → create (a bot asks for a credential)
//! GET  /v1/credentials/cards/{id}         → one card, still without its answer
//! POST /v1/credentials/cards/{id}/answer   {values:{field:value}}
//! POST /v1/credentials/cards/{id}/cancel
//! POST /v1/credentials/cards/{id}/consume  → {values} exactly once
//! ```
//!
//! The rules that make this safe to expose:
//!
//! * A card's **answer is never returned while it is pending or answered** — only `consume` yields it,
//!   once, to the caller that the bot side already is. The list endpoint carries no values at all.
//! * Cards expire (default 15 minutes). An expired card cannot be answered or consumed, so a forgotten
//!   prompt does not sit in the database as a live secret forever.
//! * Consuming marks the card `consumed` and keeps no answer, so a replay finds nothing.
//! * Every step writes one audit record — `credentials.requested`/`answered`/`consumed`/`cancelled`
//!   — carrying the site, the kind and the outcome. That is the whole record: the scalar-only
//!   `audit::Event` has no field a value could travel in, so "what was typed" is not filtered out,
//!   it has nowhere to go.
//! * Usable cards are pruned a while after they are spent or expired, so the document cannot grow
//!   without bound. The grace window keeps a just-consumed card readable, which is the difference
//!   between a caller hearing "already used" and "no such card".
//!
//! Storage is the service's own SQLite `documents` table, one JSON document for the whole card set —
//! the volume is a handful of pending prompts, and it needs no schema of its own. The database file is
//! owner-only (0600), the same posture as the engine's credential file: values are stored only between
//! `answer` and `consume`, then dropped.

use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

const DOC_KEY: &str = "credentials:cards";
const DEFAULT_TTL_SECONDS: f64 = 900.0; // 15 minutes
const MAX_TTL_SECONDS: f64 = 86_400.0;
const MAX_PENDING: usize = 32;
const MAX_FIELD_NAME: usize = 64;
/// How long a spent or expired card is kept before it is pruned. Long enough that a caller which
/// lost the reply still hears "already used"/"expired" instead of "no such card".
const SWEEP_GRACE_SECONDS: f64 = 600.0;

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn load(st: &AppState) -> Map<String, Value> {
    st.store
        .doc_or(DOC_KEY, json!({"cards": {}}))
        .get("cards")
        .and_then(|c| c.as_object())
        .cloned()
        .unwrap_or_default()
}

fn save(st: &AppState, cards: Map<String, Value>) {
    st.store.set_doc(DOC_KEY, &json!({ "cards": cards }));
}

fn expired(card: &Value) -> bool {
    card.get("expires_at").and_then(|e| e.as_f64()).unwrap_or(0.0) <= now()
}

/// What the app may see: never `values`.
fn view(card: &Value) -> Value {
    json!({
        "kind": card.get("kind").cloned().unwrap_or_else(|| json!("login")),
        "id": card.get("id"),
        "site": card.get("site"),
        "fields": card.get("fields").cloned().unwrap_or_else(|| json!([])),
        "options": card.get("options").cloned().unwrap_or_else(|| json!([])),
        "note": card.get("note").cloned().unwrap_or_else(|| json!("")),
        // Always a string: the app's decoder has a non-optional `askedBy`, so a null here used to
        // drop the whole card from the list.
        "asked_by": card.get("asked_by").and_then(|v| v.as_str()).unwrap_or(""),
        "state": card.get("state").cloned().unwrap_or_else(|| json!("pending")),
        "expires_at": card.get("expires_at").cloned().unwrap_or(json!(0)),
    })
}

/// Drop cards that stopped mattering a while ago: spent, cancelled, or expired and past the grace
/// window. Called on the way in to `create_card`, so the set is bounded by `MAX_PENDING` plus the
/// recent past rather than by every card this host ever issued.
fn sweep(cards: &mut Map<String, Value>) {
    let cutoff = now() - SWEEP_GRACE_SECONDS;
    cards.retain(|_, card| {
        // The latest thing that happened to the card decides how long it is kept. A pending card
        // only has `expires_at`, so it lives until its expiry plus the grace window.
        let at = card
            .get("consumed_at")
            .or_else(|| card.get("answered_at"))
            .or_else(|| card.get("expires_at"))
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        at > cutoff
    });
}

/// One audit record for a card step. Site and kind only — the value is not passed in, so no later
/// edit can leak it, and `audit::Event` has no field wide enough to hold one anyway.
fn audit(st: &AppState, event: &str, device: &str, card: &Value, outcome: &str) {
    let kind = card.get("kind").and_then(|k| k.as_str()).unwrap_or("login");
    let method = format!("credentials.{kind}");
    let site = card.get("site").and_then(|s| s.as_str()).unwrap_or("");
    let asked_by = card.get("asked_by").and_then(|s| s.as_str()).unwrap_or("");
    let path = format!(
        "/v1/credentials/cards/{}",
        card.get("id").and_then(|v| v.as_str()).unwrap_or("")
    );
    st.audit.emit(
        event,
        crate::audit::Event {
            device: Some(device),
            method: Some(&method),
            path: Some(&path),
            outcome: Some(outcome),
            reason: Some(site),
            profile: Some(asked_by),
            ..crate::audit::Event::default()
        },
    );
}

pub async fn list_cards(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let cards = load(&st);
    let mut out: Vec<Value> = cards
        .values()
        .filter(|c| c.get("state").and_then(|s| s.as_str()) == Some("pending"))
        .filter(|c| !expired(c))
        .map(view)
        .collect();
    // Soonest to expire first: the prompt that needs an answer now is at the top.
    out.sort_by(|a, b| {
        let key = |v: &Value| v.get("expires_at").and_then(|x| x.as_f64()).unwrap_or(0.0);
        key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal)
    });
    // `{"cards": [...]}`, not a bare array: the app casts the root to a dictionary and reads
    // `root["cards"]`, so a bare array decoded as "no cards" no matter how many were pending.
    Ok(Json(json!({ "cards": out })))
}

pub async fn get_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(card_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let cards = load(&st);
    let Some(card) = cards.get(&card_id) else {
        return Err(bad(StatusCode::NOT_FOUND, "no such card"));
    };
    if expired(card) && card.get("state").and_then(|s| s.as_str()) == Some("pending") {
        return Err(bad(StatusCode::GONE, "that request has expired"));
    }
    Ok(Json(view(card)))
}

#[derive(Deserialize)]
pub struct CreateCard {
    #[serde(default)]
    pub kind: Option<String>,
    pub site: String,
    #[serde(default)]
    pub fields: Vec<String>,
    #[serde(default)]
    pub options: Vec<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub asked_by: Option<String>,
    #[serde(default)]
    pub ttl_seconds: Option<f64>,
}

pub async fn create_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<CreateCard>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let site = body.site.trim().to_string();
    if site.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a site is required"));
    }
    let mut fields: Vec<String> = body
        .fields
        .iter()
        .map(|f| f.trim().to_string())
        .filter(|f| !f.is_empty() && f.len() <= MAX_FIELD_NAME)
        .collect();
    if fields.is_empty() {
        fields = vec!["password".to_string()];
    }
    if fields.len() > 8 {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "too many fields for one card"));
    }

    let mut cards = load(&st);
    sweep(&mut cards);
    let pending = cards
        .values()
        .filter(|c| c.get("state").and_then(|s| s.as_str()) == Some("pending") && !expired(c))
        .count();
    if pending >= MAX_PENDING {
        return Err(bad(StatusCode::TOO_MANY_REQUESTS, "too many requests are already waiting"));
    }

    let id = crate::auth::random_token(12);
    let ttl = body.ttl_seconds.unwrap_or(DEFAULT_TTL_SECONDS).clamp(30.0, MAX_TTL_SECONDS);
    let card = json!({
        "id": id,
        "kind": body.kind.unwrap_or_else(|| "login".to_string()),
        "site": site,
        "fields": fields,
        "options": body.options,
        "note": body.note.unwrap_or_default(),
        "asked_by": body.asked_by.unwrap_or_default(),
        "state": "pending",
        "created_at": now(),
        "expires_at": now() + ttl,
    });
    cards.insert(id.clone(), card.clone());
    save(&st, cards);
    audit(&st, "credentials.requested", &device, &card, "open");
    Ok(Json(view(&card)))
}

#[derive(Deserialize)]
pub struct AnswerCard {
    #[serde(default)]
    pub values: Map<String, Value>,
}

pub async fn answer_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(card_id): Path<String>,
    Json(body): Json<AnswerCard>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let mut cards = load(&st);
    let Some(card) = cards.get_mut(&card_id) else {
        return Err(bad(StatusCode::NOT_FOUND, "no such card"));
    };
    match card.get("state").and_then(|s| s.as_str()) {
        Some("pending") => {}
        Some("answered") | Some("consumed") => {
            return Err(bad(StatusCode::CONFLICT, "that request was already answered"))
        }
        _ => return Err(bad(StatusCode::CONFLICT, "that request is no longer open")),
    }
    if expired(card) {
        return Err(bad(StatusCode::GONE, "that request has expired"));
    }

    // Only the fields the card asked for, as strings.
    let wanted: Vec<String> = card
        .get("fields")
        .and_then(|f| f.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    let mut values = Map::new();
    for field in wanted {
        if let Some(value) = body.values.get(&field) {
            let text = value.as_str().map(str::to_string).unwrap_or_else(|| value.to_string());
            if !text.is_empty() {
                values.insert(field, json!(text));
            }
        }
    }
    if values.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "no answers for that request"));
    }

    card["values"] = Value::Object(values);
    card["state"] = json!("answered");
    card["answered_at"] = json!(now());
    // The record is taken from the card as it now stands, and the audit helper reads only the
    // site/kind — `values` is present on it and still goes nowhere.
    let record = card.clone();
    save(&st, cards);
    audit(&st, "credentials.answered", &device, &record, "answered");
    // The answer is acknowledged by state only; it is never echoed back.
    Ok(Json(json!({"id": card_id, "state": "answered"})))
}

pub async fn cancel_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(card_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let mut cards = load(&st);
    let Some(card) = cards.get_mut(&card_id) else {
        return Err(bad(StatusCode::NOT_FOUND, "no such card"));
    };
    card["state"] = json!("cancelled");
    card["values"] = Value::Null;
    let record = card.clone();
    save(&st, cards);
    audit(&st, "credentials.cancelled", &device, &record, "cancelled");
    Ok(Json(json!({"id": card_id, "state": "cancelled"})))
}

pub async fn consume_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(card_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let mut cards = load(&st);
    let Some(card) = cards.get_mut(&card_id) else {
        return Err(bad(StatusCode::NOT_FOUND, "no such card"));
    };
    match card.get("state").and_then(|s| s.as_str()) {
        Some("answered") => {}
        Some("consumed") => return Err(bad(StatusCode::CONFLICT, "that answer was already collected")),
        _ => return Err(bad(StatusCode::CONFLICT, "nothing to collect yet")),
    }
    if expired(card) {
        return Err(bad(StatusCode::GONE, "that request has expired"));
    }
    let values = card.get("values").cloned().unwrap_or_else(|| json!({}));
    // One read, then it is gone: a replay must not be able to collect the secret twice.
    card["state"] = json!("consumed");
    card["values"] = Value::Null;
    card["consumed_at"] = json!(now());
    // Taken after the values are gone, so the record cannot carry them even by accident. The fill
    // happens where the values were handed over (the sign-in skill), so this step honestly says
    // "consumed", not "filled": the host has not touched a page.
    let record = card.clone();
    save(&st, cards);
    audit(&st, "credentials.consumed", &device, &record, "consumed");
    Ok(Json(json!({"id": card_id, "values": values})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::State;
    use axum::http::header::AUTHORIZATION;
    use std::path::{Path, PathBuf};

    /// Same shape as the router's own test principal: `require_device` accepts this bearer and
    /// reports `local_token::LOCAL_PRINCIPAL`, which is what the audit record names as `device`.
    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";
    const SECRET: &str = "hunter2-not-a-real-password";

    fn scratch(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-credentials-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    /// The fields the routes touch. Everything else is the engine/display wiring, which a card
    /// route never reaches; the `display` hub is spawned and simply dials a port nothing serves.
    fn state(dir: &Path) -> Arc<AppState> {
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
            attachments_dir: dir.join("attachments"),
            local_token: Arc::new(crate::local_token::LocalToken::from_value(
                LOCAL,
                dir.join("local.token"),
            )),
            local_computers: Default::default(),
            browsers: Default::default(),
            display: crate::display::DisplayHub::spawn(engine_ws, Some(token_file)),
            relay_sockets: Default::default(),
            audit: Arc::new(crate::audit::AuditLog::in_dir(dir)),
        })
    }

    fn auth() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            format!("Bearer {LOCAL}").parse().unwrap(),
        );
        headers
    }

    fn ask(kind: &str, fields: &[&str]) -> Json<CreateCard> {
        Json(CreateCard {
            kind: Some(kind.to_string()),
            site: "example.test".to_string(),
            fields: fields.iter().map(|f| f.to_string()).collect(),
            options: Vec::new(),
            note: None,
            asked_by: Some("cody".to_string()),
            ttl_seconds: None,
        })
    }

    fn answers(pairs: &[(&str, &str)]) -> Json<AnswerCard> {
        let mut values = Map::new();
        for (field, value) in pairs {
            values.insert(field.to_string(), json!(value));
        }
        Json(AnswerCard { values })
    }

    /// The promise, in one test: every step is in the audit stream, each record names the site and
    /// the kind, and no record — in any state — carries what the owner typed.
    #[tokio::test]
    async fn every_step_is_audited_with_the_site_and_never_the_value() {
        let dir = scratch("audit");
        let st = state(&dir);

        let created = create_card(
            State(Arc::clone(&st)),
            auth(),
            ask("secret", &["password"]),
        )
        .await
        .expect("ask")
        .0;
        let id = created["id"].as_str().expect("id").to_string();
        assert!(
            created.get("values").is_none(),
            "no value exists at ask time, so the card must not carry one: {created}"
        );

        answer_card(
            State(Arc::clone(&st)),
            auth(),
            Path(id.clone()),
            answers(&[("password", SECRET)]),
        )
        .await
        .expect("answer");

        // Readable in every state, and never with the answer in it.
        let seen = get_card(State(Arc::clone(&st)), auth(), Path(id.clone()))
            .await
            .expect("read")
            .0;
        let listed = list_cards(State(Arc::clone(&st)), auth()).await.expect("list").0;
        assert_eq!(seen["state"], "answered");
        assert!(!seen.to_string().contains(SECRET), "the read must not carry the value");
        assert!(!listed.to_string().contains(SECRET), "the list must not carry the value");

        let collected = consume_card(State(Arc::clone(&st)), auth(), Path(id.clone()))
            .await
            .expect("consume")
            .0;
        assert_eq!(collected["values"]["password"], SECRET, "the owner's answer reaches its one caller");

        let requested = st.audit.all("credentials.requested");
        let answered = st.audit.all("credentials.answered");
        let consumed = st.audit.all("credentials.consumed");
        assert_eq!(requested.len(), 1, "one ask, one record");
        assert_eq!(answered.len(), 1);
        assert_eq!(consumed.len(), 1);

        assert_eq!(requested[0]["method"], "credentials.secret");
        assert_eq!(requested[0]["reason"], "example.test");
        assert_eq!(requested[0]["outcome"], "open");
        assert_eq!(requested[0]["path"], format!("/v1/credentials/cards/{id}"));
        // `device` is the 8-character hint `audit::device_hint` keeps, not the whole principal.
        assert_eq!(requested[0]["device"], "local-cl", "the record names who asked");
        assert_eq!(requested[0]["profile"], "cody");
        assert_eq!(consumed[0]["outcome"], "consumed");

        for event in ["credentials.requested", "credentials.answered", "credentials.consumed"] {
            for record in st.audit.all(event) {
                let text = record.to_string();
                assert!(
                    !text.contains(SECRET),
                    "{event} carried the value: {text}"
                );
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Cancel is a step too, and it is the one that must leave nothing behind to fill.
    #[tokio::test]
    async fn cancelling_is_audited_and_keeps_no_answer() {
        let dir = scratch("cancel");
        let st = state(&dir);

        let id = create_card(State(Arc::clone(&st)), auth(), ask("choice", &[]))
            .await
            .expect("ask")
            .0["id"]
            .as_str()
            .expect("id")
            .to_string();
        let cancelled = cancel_card(State(Arc::clone(&st)), auth(), Path(id.clone()))
            .await
            .expect("cancel")
            .0;
        assert_eq!(cancelled["state"], "cancelled");

        // A cancelled card cannot be answered, so no value can arrive after the owner said no.
        let refused = answer_card(
            State(Arc::clone(&st)),
            auth(),
            Path(id.clone()),
            answers(&[("password", SECRET)]),
        )
        .await
        .expect_err("a cancelled card cannot be answered");
        assert_eq!(refused.0, StatusCode::CONFLICT);

        let records = st.audit.all("credentials.cancelled");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0]["outcome"], "cancelled");
        assert_eq!(records[0]["reason"], "example.test");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The document is pruned, but not so eagerly that a caller which lost the reply is told the
    /// card never existed. Spent/expired cards survive the grace window, then go.
    #[test]
    fn a_spent_card_is_pruned_after_the_grace_window_and_not_before() {
        let mut cards = Map::new();
        cards.insert(
            "waiting".to_string(),
            json!({"id": "waiting", "state": "pending", "expires_at": now() + 60.0}),
        );
        cards.insert(
            "just-spent".to_string(),
            json!({"id": "just-spent", "state": "consumed",
                   "expires_at": now() + 60.0, "consumed_at": now() - 5.0}),
        );
        cards.insert(
            "long-gone".to_string(),
            json!({"id": "long-gone", "state": "consumed",
                   "expires_at": now() - 7200.0, "consumed_at": now() - 7200.0}),
        );
        sweep(&mut cards);
        assert!(cards.contains_key("waiting"), "a live card is never swept");
        assert!(cards.contains_key("just-spent"), "a just-spent card still answers \"already used\"");
        assert!(!cards.contains_key("long-gone"), "a card from hours ago must not accumulate");
    }
}
