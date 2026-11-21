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
    require_device(&st, &headers)?;
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
    require_device(&st, &headers)?;
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
    save(&st, cards);
    // The answer is acknowledged by state only; it is never echoed back.
    Ok(Json(json!({"id": card_id, "state": "answered"})))
}

pub async fn cancel_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(card_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let mut cards = load(&st);
    let Some(card) = cards.get_mut(&card_id) else {
        return Err(bad(StatusCode::NOT_FOUND, "no such card"));
    };
    card["state"] = json!("cancelled");
    card["values"] = Value::Null;
    save(&st, cards);
    Ok(Json(json!({"id": card_id, "state": "cancelled"})))
}

pub async fn consume_card(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(card_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
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
    save(&st, cards);
    Ok(Json(json!({"id": card_id, "values": values})))
}
