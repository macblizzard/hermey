//! Login cards: the bot asks, the owner answers, the bot consumes — once.
//!
//! ```text
//! GET  /v1/credentials/cards              → [{kind,id,site,fields,masked,store,submit,options,note,asked_by,state,expires_at}]
//! POST /v1/credentials/cards              → create (a bot asks for a credential; `store` saves it)
//! GET  /v1/credentials/cards/{id}         → one card, still without its answer
//! POST /v1/credentials/cards/{id}/answer   {values:{field:value}}
//! POST /v1/credentials/cards/{id}/cancel
//! POST /v1/credentials/cards/{id}/consume  → {values} once, or {stored:[{field,name}],ok} for `store`
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
//! * **No route serves it: a stored answer goes to the vault.** A card created with `store: true` has its
//!   answer written to the host's secret store (`secrets.rs`, `0600`, beside `bridge.db`) at the moment
//!   the owner submits. The card keeps the **name** it was saved under, never the value, and `consume`
//!   acknowledges `{name, field}` — which is what lets a bot keep using a credential it has never seen.
//!   A card without `store` is unchanged: its answer is handed over once and kept nowhere.
//!
//! Storage is the service's own SQLite `documents` table, one JSON document for the whole card set —
//! the volume is a handful of pending prompts, and it needs no schema of its own. The database file is
//! owner-only (0600), the same posture as the engine's credential file: values are stored only between
//! `answer` and `consume`, then dropped. A `store` card puts nothing of the value in that table at all.

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
/// A hostname in a certificate is 253 bytes and a note is one line the owner reads on a card.
const MAX_SITE_BYTES: usize = 253;
const MAX_NOTE_BYTES: usize = 240;
const MAX_OPTIONS: usize = 8;
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
///
/// `masked` is the host's own answer to "which of these are secrets", so the app never has to guess
/// from a field's name — a field called `api key` is masked because it is not one of the ordinary
/// ones, and a new secret-shaped field needs no app release to be hidden. `submit` is the button's
/// words, also host-decided: a bot cannot label a stored key "fill it in" and have it typed into a page.
fn view(card: &Value) -> Value {
    let fields: Vec<String> = card
        .get("fields")
        .and_then(|f| f.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    let store = card.get("store").and_then(Value::as_bool).unwrap_or(false);
    json!({
        "kind": card.get("kind").cloned().unwrap_or_else(|| json!("login")),
        "id": card.get("id"),
        "site": card.get("site"),
        "fields": fields,
        "masked": crate::secrets::masked_fields(&fields),
        "store": store,
        "submit": if store { "Save to the vault" } else { "Fill it in" },
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
    /// Save the answer in the host's secret store instead of handing it to the caller. This is the
    /// difference between a login (typing a value into a page once) and a credential the bot needs
    /// again tomorrow (an API key): the second one has to have somewhere to live, and it is not the
    /// bot's context.
    #[serde(default)]
    pub store: bool,
    /// The vault item's label. Absent means `<site>/<field>`, minted by the host.
    #[serde(default)]
    pub save_as: Option<String>,
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
    if site.len() > MAX_SITE_BYTES {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "that site is longer than 253 characters"));
    }
    let note = body.note.unwrap_or_default().trim().to_string();
    if note.chars().count() > MAX_NOTE_BYTES {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "the note is longer than one line"));
    }
    if body.options.len() > MAX_OPTIONS {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "too many options for one card"));
    }
    // A `save_as` label has to be a name the store will accept, checked here rather than at answer
    // time: a card that promises "saved as <name>" must not discover the name was impossible after
    // the owner has typed a password into it.
    let save_as = match body.save_as.as_deref().map(str::trim) {
        None | Some("") => None,
        Some(name) if crate::secrets::valid_name(name) => Some(name.to_string()),
        Some(_) => {
            return Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                "a saved name is letters, digits, '.', '_', '-' and one '/', up to 96 characters",
            ))
        }
    };
    if save_as.is_some() && !body.store {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "save_as needs store: true"));
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
    if save_as.is_some() && fields.len() != 1 {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "save_as names one value, so the card asks for one field",
        ));
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
    let asked_by = body.asked_by.unwrap_or_default().trim().to_string();
    if asked_by.len() > 64 || !asked_by.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "asked_by must be a bot's name"));
    }
    let card = json!({
        "id": id,
        "kind": body.kind.unwrap_or_else(|| "login".to_string()),
        "site": site,
        "fields": fields,
        "options": body.options,
        "note": note,
        "asked_by": asked_by,
        "store": body.store,
        "save_as": save_as,
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
    // A value is a line, not an upload. Refused here, before anything is remembered anywhere, and the
    // message says the limit rather than quoting what was typed.
    if values
        .values()
        .any(|v| v.as_str().map(|t| t.len()).unwrap_or(0) > crate::secrets::MAX_VALUE_BYTES)
    {
        return Err(bad(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!("one value is larger than {} bytes", crate::secrets::MAX_VALUE_BYTES),
        ));
    }

    let store = card.get("store").and_then(Value::as_bool).unwrap_or(false);
    if store {
        // Straight into the host's vault, and only the name is kept on the card. A `put` that fails
        // names the reason and the item, never the value, so this error can travel back to the app.
        let site = card.get("site").and_then(|s| s.as_str()).unwrap_or("").to_string();
        let kind = card.get("kind").and_then(|k| k.as_str()).unwrap_or("login").to_string();
        let note = card.get("note").and_then(|n| n.as_str()).unwrap_or("").to_string();
        let save_as = card.get("save_as").and_then(|s| s.as_str()).map(str::to_string);
        let mut stored = Vec::new();
        for (field, value) in values.iter() {
            let name = save_as
                .clone()
                .unwrap_or_else(|| crate::secrets::name_for(&site, field));
            let text = value.as_str().unwrap_or_default();
            crate::secrets::put(&st, &name, text)
                .map_err(|why| bad(StatusCode::UNPROCESSABLE_ENTITY, why))?;
            // The row the owner's Vault pane draws: where it is for, what asked for it, and when —
            // the card's own scalars, never the answer. Written after the value lands, so an index
            // record without a secret cannot appear.
            crate::vault::note_stored(&st, &name, &kind, &site, &note);
            stored.push(json!({ "field": field, "name": name }));
        }
        card["stored"] = json!(stored);
        card["values"] = Value::Null;
    } else {
        card["values"] = Value::Object(values);
    }
    card["state"] = json!("answered");
    card["answered_at"] = json!(now());
    // The record is taken from the card as it now stands, and the audit helper reads only the
    // site/kind — `values` is present on it and still goes nowhere.
    let record = card.clone();
    save(&st, cards);
    if store {
        audit(&st, "credentials.stored", &device, &record, "stored");
    } else {
        audit(&st, "credentials.answered", &device, &record, "answered");
    }
    // The answer is acknowledged by state only; it is never echoed back.
    Ok(Json(json!({ "id": card_id, "state": "answered" })))
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
    // Kept before the state moves on: a stored answer's only trace is the name it went under.
    let stored = card.get("stored").cloned().filter(|s| !s.is_null());
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
    if let Some(stored) = stored {
        // A stored card never carried the value here: it went into the vault when the owner submitted,
        // so all a caller gets is the name it can ask a fill to use.
        return Ok(Json(json!({
            "id": card_id,
            "state": "consumed",
            "ok": true,
            "stored": stored,
        })));
    }
    Ok(Json(json!({ "id": card_id, "values": values })))
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
            store: false,
            save_as: None,
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

    // --- store mode: the answer has somewhere to live that is not the bot ---------------------

    fn ask_store(fields: &[&str], save_as: Option<&str>) -> Json<CreateCard> {
        Json(CreateCard {
            kind: Some("secret".to_string()),
            site: "api.openai.com".to_string(),
            fields: fields.iter().map(|f| f.to_string()).collect(),
            options: Vec::new(),
            note: Some("Reading the model list".to_string()),
            asked_by: Some("cody".to_string()),
            ttl_seconds: None,
            store: true,
            save_as: save_as.map(str::to_string),
        })
    }

    /// The whole point of `store`: the owner's answer lands in the vault, and every answer a caller
    /// can see — the card, the list, consume, the audit — names an item and never carries the value.
    #[tokio::test]
    async fn a_stored_answer_goes_to_the_vault_and_never_comes_back() {
        let dir = scratch("store");
        let st = state(&dir);

        let created = create_card(
            State(Arc::clone(&st)),
            auth(),
            ask_store(&["api key"], None),
        )
        .await
        .expect("ask")
        .0;
        let id = created["id"].as_str().expect("id").to_string();
        assert_eq!(created["store"], true);
        assert_eq!(created["submit"], "Save to the vault");
        assert_eq!(created["masked"][0], "api key", "an api key is a masked field");
        assert!(created.get("values").is_none());

        answer_card(
            State(Arc::clone(&st)),
            auth(),
            Path(id.clone()),
            answers(&[("api key", SECRET)]),
        )
        .await
        .expect("answer");

        // It is in the store, under the name the site and field mint.
        let stored = crate::secrets::get(&st, "api.openai.com/api-key");
        assert_eq!(stored.as_deref(), Some(SECRET), "the value reached the vault");

        // And the owner's Vault pane can see it as a row: the name, where it is for, and what asked
        // for it — with the value nowhere in what the pane is served.
        let vault = crate::vault::list(State(Arc::clone(&st)), auth())
            .await
            .expect("vault list")
            .0;
        assert_eq!(vault["items"][0]["name"], "api.openai.com/api-key");
        assert_eq!(vault["items"][0]["site"], "api.openai.com");
        assert_eq!(vault["items"][0]["note"], "Reading the model list");
        assert_eq!(vault["items"][0]["kind"], "secret");
        assert!(
            !vault.to_string().contains(SECRET),
            "the vault list carried the value: {vault}"
        );

        // In none of the places a caller can read.
        let seen = get_card(State(Arc::clone(&st)), auth(), Path(id.clone()))
            .await
            .expect("read")
            .0;
        let listed = list_cards(State(Arc::clone(&st)), auth()).await.expect("list").0;
        assert!(!seen.to_string().contains(SECRET), "the card carried the value: {seen}");
        assert!(!listed.to_string().contains(SECRET), "the list carried the value");
        let document = st.store.doc_or(DOC_KEY, json!(null)).to_string();
        assert!(
            !document.contains(SECRET),
            "the value reached the card document (bridge.db), which is a store of prompts, not secrets"
        );

        let ack = consume_card(State(Arc::clone(&st)), auth(), Path(id.clone()))
            .await
            .expect("consume")
            .0;
        assert_eq!(ack["ok"], true);
        assert_eq!(ack["stored"][0]["field"], "api key");
        assert_eq!(ack["stored"][0]["name"], "api.openai.com/api-key");
        assert!(
            ack.get("values").is_none(),
            "a stored card hands over no values: {ack}"
        );
        assert!(!ack.to_string().contains(SECRET), "the acknowledgement carried the value: {ack}");

        // The audit says a value was stored, by site and outcome — and cannot say more.
        let records = st.audit.all("credentials.stored");
        assert_eq!(records.len(), 1, "one step, one record");
        assert_eq!(records[0]["outcome"], "stored");
        assert_eq!(records[0]["reason"], "api.openai.com");
        assert!(
            !records[0].to_string().contains(SECRET),
            "an audit record carried the value"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `save_as` is the vault item's label, so the bot can name it back later. It is checked when the
    /// card is *made*, before the owner types anything into it.
    #[tokio::test]
    async fn a_saved_name_is_validated_when_the_card_is_asked_for() {
        let dir = scratch("save-as");
        let st = state(&dir);

        let created = create_card(
            State(Arc::clone(&st)),
            auth(),
            ask_store(&["api key"], Some("openai.main")),
        )
        .await
        .expect("ask")
        .0;
        assert_eq!(created["store"], true);
        let id = created["id"].as_str().unwrap().to_string();
        answer_card(
            State(Arc::clone(&st)),
            auth(),
            Path(id.clone()),
            answers(&[("api key", SECRET)]),
        )
        .await
        .expect("answer");
        let ack = consume_card(State(Arc::clone(&st)), auth(), Path(id))
            .await
            .expect("consume")
            .0;
        assert_eq!(ack["stored"][0]["name"], "openai.main");
        assert_eq!(crate::secrets::get(&st, "openai.main").as_deref(), Some(SECRET));

        // Names that could be a path, an empty one, and one without `store` are all refused.
        for bad_name in ["/etc/passwd", "../x", "a b"] {
            let refused = create_card(
                State(Arc::clone(&st)),
                auth(),
                ask_store(&["api key"], Some(bad_name)),
            )
            .await
            .expect_err(bad_name);
            assert_eq!(refused.0, StatusCode::UNPROCESSABLE_ENTITY, "{bad_name}");
        }
        let mut no_store = ask_store(&["api key"], Some("openai.main"));
        no_store.0.store = false;
        let refused = create_card(State(Arc::clone(&st)), auth(), no_store)
            .await
            .expect_err("save_as without store");
        assert_eq!(refused.0, StatusCode::UNPROCESSABLE_ENTITY);

        let refused = create_card(
            State(Arc::clone(&st)),
            auth(),
            ask_store(&["username", "password"], Some("one.name")),
        )
        .await
        .expect_err("one name cannot hold two fields");
        assert_eq!(refused.0, StatusCode::UNPROCESSABLE_ENTITY);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A value is a line: the ceiling is refused with its own code and the card stays open.
    #[tokio::test]
    async fn an_oversized_value_is_refused_and_nothing_is_stored() {
        let dir = scratch("oversize");
        let st = state(&dir);
        let id = create_card(State(Arc::clone(&st)), auth(), ask_store(&["api key"], None))
            .await
            .expect("ask")
            .0["id"]
            .as_str()
            .unwrap()
            .to_string();

        let huge = "x".repeat(crate::secrets::MAX_VALUE_BYTES + 1);
        let refused = answer_card(
            State(Arc::clone(&st)),
            auth(),
            Path(id.clone()),
            answers(&[("api key", &huge)]),
        )
        .await
        .expect_err("too large");
        assert_eq!(refused.0, StatusCode::PAYLOAD_TOO_LARGE);
        let body = refused.1 .0.to_string();
        assert!(!body.contains("xxxx"), "the refusal quoted the value: {body}");
        assert!(
            crate::secrets::get(&st, "api.openai.com/api-key").is_none(),
            "a refused answer stored nothing"
        );
        let still = get_card(State(Arc::clone(&st)), auth(), Path(id))
            .await
            .expect("read")
            .0;
        assert_eq!(still["state"], "pending", "the owner can answer again");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The card without `store` keeps the contract it shipped with: the value is handed over once,
    /// kept nowhere, and a second consume finds nothing.
    #[tokio::test]
    async fn an_ordinary_card_still_hands_its_value_over_exactly_once() {
        let dir = scratch("once");
        let st = state(&dir);
        let id = create_card(
            State(Arc::clone(&st)),
            auth(),
            ask("secret", &["username", "password"]),
        )
        .await
        .expect("ask")
        .0["id"]
        .as_str()
        .unwrap()
        .to_string();
        answer_card(
            State(Arc::clone(&st)),
            auth(),
            Path(id.clone()),
            answers(&[("username", "mo@example.test"), ("password", SECRET)]),
        )
        .await
        .expect("answer");

        let collected = consume_card(State(Arc::clone(&st)), auth(), Path(id.clone()))
            .await
            .expect("consume")
            .0;
        assert_eq!(collected["values"]["password"], SECRET);
        assert!(collected.get("stored").is_none(), "no store, no handles");
        // Nothing of it went to the vault: that destination is opt-in.
        assert!(crate::secrets::get(&st, "example.test/password").is_none());

        let again = consume_card(State(Arc::clone(&st)), auth(), Path(id))
            .await
            .expect_err("a replay collects nothing");
        assert_eq!(again.0, StatusCode::CONFLICT);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The app is told which fields are secrets, so it never has to recognise a name to mask it.
    #[test]
    fn the_view_names_the_masked_fields_and_the_buttons_words() {
        let card = json!({
            "id": "c1", "kind": "secret", "site": "example.test",
            "fields": ["username", "password", "api key"], "store": true,
            "state": "pending", "expires_at": 1.0,
        });
        let asked = view(&card);
        assert_eq!(asked["masked"], json!(["password", "api key"]));
        assert_eq!(asked["store"], true);
        assert_eq!(asked["submit"], "Save to the vault");
        assert!(!asked["masked"].to_string().contains("username"), "a plain field is not masked");

        let mut filling = card.clone();
        filling["store"] = json!(false);
        assert_eq!(view(&filling)["submit"], "Fill it in");
    }
}