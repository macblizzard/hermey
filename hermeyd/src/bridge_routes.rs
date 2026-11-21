//! Bridge-owned collections: categories, bot icons, defaults, disabled bots, approvals, push.
//!
//! These are exactly the things the *host service* owns and the engine does not: they are UI state,
//! not agent state, so they live in our SQLite documents and survive an engine swap. Shapes match the
//! Swift decoders field-for-field (checked against `BotCategories.swift`, `BotDefaults.swift`,
//! `ApprovalSettings.swift`, `BotIconPicker.swift`).

use crate::auth::random_token;
use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde_json::{json, Value};
use std::sync::Arc;

type AuthFail = (StatusCode, Json<Value>);

const DOC_CATEGORIES: &str = "bot_categories";
const DOC_DEFAULTS: &str = "bot_defaults";
const DOC_ICONS: &str = "bot_icons";
const DOC_DISABLED: &str = "bots_disabled";
const DOC_APPROVALS: &str = "approvals";

fn categories_doc(st: &AppState) -> Value {
    st.store
        .doc_or(DOC_CATEGORIES, json!({"categories": [], "assignments": {}, "order": []}))
}

fn defaults_doc(st: &AppState) -> Value {
    st.store.doc_or(
        DOC_DEFAULTS,
        json!({"soul": {"text": "", "chars": 0, "present": false}, "built_in": null}),
    )
}

// ---- categories -------------------------------------------------------------------

pub async fn get_categories(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    Ok(Json(categories_doc(&st)))
}

/// Create a category (`{"name": "Work"}`) or replace the whole document when `categories` is sent.
pub async fn post_categories(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = categories_doc(&st);
    if let Some(cats) = body.get("categories") {
        doc["categories"] = cats.clone();
    } else if let Some(name) = body.get("name").and_then(|v| v.as_str()) {
        let id = random_token(6);
        if let Some(arr) = doc["categories"].as_array_mut() {
            arr.push(json!({"id": id, "name": name}));
        }
        if let Some(order) = doc["order"].as_array_mut() {
            order.push(json!(id));
        }
    }
    for key in ["assignments", "order"] {
        if let Some(v) = body.get(key) {
            doc[key] = v.clone();
        }
    }
    st.store.set_doc(DOC_CATEGORIES, &doc);
    Ok(Json(doc))
}

/// Rename (`{"name": …}`) or reassign (`{"profile": …, "category": …|null}`) one category.
pub async fn patch_category(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(category): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = categories_doc(&st);
    if let Some(name) = body.get("name").and_then(|v| v.as_str()) {
        if let Some(arr) = doc["categories"].as_array_mut() {
            for c in arr.iter_mut() {
                if c.get("id").and_then(|v| v.as_str()) == Some(category.as_str()) {
                    c["name"] = json!(name);
                }
            }
        }
    }
    if let Some(profile) = body.get("profile").and_then(|v| v.as_str()) {
        let target = body.get("category").and_then(|v| v.as_str()).unwrap_or("");
        let map = doc["assignments"].as_object_mut();
        if let Some(map) = map {
            if target.is_empty() {
                map.remove(profile);
            } else {
                map.insert(profile.to_string(), json!(target));
            }
        }
    }
    st.store.set_doc(DOC_CATEGORIES, &doc);
    Ok(Json(doc))
}

pub async fn delete_category(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(category): Path<String>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = categories_doc(&st);
    if let Some(arr) = doc["categories"].as_array_mut() {
        arr.retain(|c| c.get("id").and_then(|v| v.as_str()) != Some(category.as_str()));
    }
    if let Some(order) = doc["order"].as_array_mut() {
        order.retain(|v| v.as_str() != Some(category.as_str()));
    }
    if let Some(map) = doc["assignments"].as_object_mut() {
        map.retain(|_, v| v.as_str() != Some(category.as_str()));
    }
    st.store.set_doc(DOC_CATEGORIES, &doc);
    Ok(Json(doc))
}

pub async fn put_category_order(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = categories_doc(&st);
    // The client sends `{"ids":[…]}`; older variants used `{"order":…}`. Accept both rather than
    // making the arrangement silently not stick.
    if let Some(order) = body.get("ids").or_else(|| body.get("order")) {
        doc["order"] = order.clone();
    }
    st.store.set_doc(DOC_CATEGORIES, &doc);
    Ok(Json(doc))
}

/// `PUT /v1/bots/{profile}/category` — `{"category_id": "…"|null}`; null means Uncategorized.
/// Answers with the whole document so one call redraws the list.
pub async fn put_bot_category(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = categories_doc(&st);
    let category = body
        .get("category_id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if let Some(map) = doc["assignments"].as_object_mut() {
        if category.is_empty() {
            map.remove(&profile);
        } else {
            map.insert(profile, json!(category));
        }
    }
    st.store.set_doc(DOC_CATEGORIES, &doc);
    Ok(Json(doc))
}

// ---- bot defaults -----------------------------------------------------------------

pub async fn get_defaults(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    Ok(Json(defaults_doc(&st)))
}

pub async fn put_defaults_soul(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = defaults_doc(&st);
    let text = body.get("text").and_then(|v| v.as_str()).unwrap_or("");
    doc["soul"] = json!({
        "text": text,
        "chars": text.chars().count(),
        "present": !text.trim().is_empty(),
        // ISO-8601, not epoch seconds: the app decodes this with `.iso8601`, and a float fails the
        // whole document rather than just the field.
        "updated_at": crate::backup::now_iso(),
    });
    st.store.set_doc(DOC_DEFAULTS, &doc);
    Ok(Json(doc))
}

// ---- bot icons --------------------------------------------------------------------

pub async fn get_icons(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let doc = st.store.doc_or(DOC_ICONS, json!({"faces": {}, "icons": {}}));
    Ok(Json(doc))
}

pub async fn put_icon(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(bot): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = st.store.doc_or(DOC_ICONS, json!({"faces": {}, "icons": {}}));
    match body.get("avatar").and_then(|v| v.as_str()) {
        Some(avatar) => {
            if let Some(faces) = doc["faces"].as_object_mut() {
                faces.insert(bot, json!({"avatar": avatar}));
            }
        }
        None => {
            if let Some(faces) = doc["faces"].as_object_mut() {
                faces.remove(&bot);
            }
        }
    }
    st.store.set_doc(DOC_ICONS, &doc);
    Ok(Json(doc))
}

// ---- disabled bots ----------------------------------------------------------------

pub async fn get_disabled(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    Ok(Json(st.store.doc_or(DOC_DISABLED, json!({"disabled": []}))))
}

/// A deleted bot must not keep a disabled marker that a later bot with the same name inherits —
/// the purge route clears it here, beside the document the toggle writes.
pub(crate) fn forget_disabled(st: &AppState, profile: &str) {
    let mut doc = st.store.doc_or(DOC_DISABLED, json!({"disabled": []}));
    if let Some(arr) = doc["disabled"].as_array_mut() {
        arr.retain(|v| v.as_str() != Some(profile));
    }
    st.store.set_doc(DOC_DISABLED, &doc);
}

/// Turn a bot off (`{"enabled": false}`) or back on. Cosmetic for now: pausing the engine's cron jobs
/// is the production behaviour and lands with the routines routes.
pub async fn post_bot_state(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let enabled = body.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
    let mut doc = st.store.doc_or(DOC_DISABLED, json!({"disabled": []}));
    if let Some(arr) = doc["disabled"].as_array_mut() {
        arr.retain(|v| v.as_str() != Some(profile.as_str()));
        if !enabled {
            arr.push(json!(profile));
        }
    }
    st.store.set_doc(DOC_DISABLED, &doc);
    Ok(Json(json!({"profile": profile, "enabled": enabled})))
}

// ---- approvals --------------------------------------------------------------------

pub async fn get_approvals(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    Ok(Json(st.store.doc_or(
        DOC_APPROVALS,
        json!({"mode": null, "profiles": {}, "unset": [], "updated": [], "failed": {}}),
    )))
}

pub async fn put_approvals(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = st.store.doc_or(
        DOC_APPROVALS,
        json!({"mode": null, "profiles": {}, "unset": [], "updated": [], "failed": {}}),
    );
    if let Some(mode) = body.get("mode") {
        doc["mode"] = mode.clone();
    }
    doc["updated"] = json!([]);
    doc["failed"] = json!({});
    st.store.set_doc(DOC_APPROVALS, &doc);
    Ok(Json(doc))
}

// ---- rooms / push / previews ------------------------------------------------------

/// Rooms are hosted by the engine (`groups.*`); the empty list keeps the sidebar honest until the
/// relay side of rooms lands.
pub async fn get_rooms(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    Ok(Json(json!([])))
}

// Previews and push are not documents and are not answered here: `previews.rs` reads each
// profile's state.db (read-only) for the bot list's last line, and `push.rs` owns the Bark relay.
// This module used to carry stubs for both; two answers for one route is how a list ends up empty
// while the database is full.
