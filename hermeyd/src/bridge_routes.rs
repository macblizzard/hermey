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

/// A face's own entry: the chosen face (`avatar`), and optionally the avatar it draws itself with
/// (`definition`, the open-bot-avatar v1 JSON), that avatar's colour (`color`) and the material it
/// is painted in (`material`: `solid` or `glass`).
///
/// The document predates all three, so every field is optional and a missing one is not a change;
/// an absent `material` is `solid`, which is what every stored face already is. The shapes are
/// decoded by the apps' `BotIconService` / `MacBotIconService` field-for-field.
fn face_entry(doc: &Value, bot: &str) -> Value {
    doc.get("faces")
        .and_then(|faces| faces.get(bot))
        .cloned()
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

pub async fn get_icons(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let doc = st.store.doc_or(DOC_ICONS, json!({"faces": {}, "icons": {}}));
    Ok(Json(doc))
}

/// A bad definition is refused with the validator's own reason, and nothing is written: a partial
/// save here would leave a bot wearing half an avatar.
fn bad_request(reason: String) -> AuthFail {
    (
        StatusCode::BAD_REQUEST,
        Json(json!({ "detail": reason })),
    )
}

pub async fn put_icon(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(bot): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, AuthFail> {
    require_device(&st, &headers)?;
    let mut doc = st.store.doc_or(DOC_ICONS, json!({"faces": {}, "icons": {}}));
    let mut entry = face_entry(&doc, &bot);
    let has = |key: &str| body.get(key).is_some();

    // The chosen face: a string sets it; an absent or null one clears it. That is exactly what the
    // pre-avatar picker has always sent, so an old client keeps its meaning.
    if has("avatar") {
        match body.get("avatar").and_then(|v| v.as_str()) {
            Some(avatar) => entry["avatar"] = json!(avatar),
            None => {
                if let Some(object) = entry.as_object_mut() {
                    object.remove("avatar");
                }
            }
        }
    }

    // The generated avatar: `null` clears it, an object must validate. The material is cleared with
    // it: a material describes how to paint a definition, and one left behind would be a setting
    // for a face that no longer exists.
    if has("definition") {
        match body.get("definition") {
            Some(Value::Null) | None => {
                if let Some(object) = entry.as_object_mut() {
                    object.remove("definition");
                    object.remove("material");
                }
            }
            Some(definition) => match crate::bot_avatar::validate(definition) {
                Ok(spec) => entry["definition"] = spec.to_json(),
                Err(errors) => {
                    // The first reason leads, the rest follow: an editor shows one line and may
                    // expand the list.
                    let lead = errors.first().cloned().unwrap_or_default();
                    let mut detail = format!("invalid avatar definition: {lead}");
                    if errors.len() > 1 {
                        detail.push_str(&format!(" (and {} more)", errors.len() - 1));
                    }
                    return Err(bad_request(detail));
                }
            },
        }
    }

    // The avatar's colour, overridable per bot. `null` falls back to the palette colour.
    if has("color") {
        match body.get("color").and_then(|v| v.as_str()) {
            Some(color) if crate::bot_avatar::is_hex_color(color) => entry["color"] = json!(color),
            Some(color) => {
                return Err(bad_request(format!(
                    "color must be #rgb or #rrggbb, not {color:?}"
                )))
            }
            None => {
                if let Some(object) = entry.as_object_mut() {
                    object.remove("color");
                }
            }
        }
    }

    // The material: `null` falls back to `solid` (the field is simply dropped), and anything that is
    // neither `solid` nor `glass` is refused with the contract's reason and nothing is written.
    if has("material") {
        match body.get("material") {
            Some(Value::Null) | None => {
                if let Some(object) = entry.as_object_mut() {
                    object.remove("material");
                }
            }
            Some(value) => match crate::bot_avatar::parse_material(value) {
                Ok(material) => entry["material"] = json!(material),
                Err(reason) => return Err(bad_request(reason)),
            },
        }
    }

    if let Some(faces) = doc["faces"].as_object_mut() {
        // Nothing left to say about this bot: keep the document clean for the next reader.
        if entry.as_object().map(|o| o.is_empty()).unwrap_or(false) {
            faces.remove(&bot);
        } else {
            faces.insert(bot, entry);
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

#[cfg(test)]
mod tests {
    //! The avatar half of the bot-icon document, through the real handlers.
    //!
    //! These call `get_icons`/`put_icon` themselves — not a copy of their body — so the route's
    //! auth gate, the document merge and the validator's refusal are all exercised together. The
    //! state is a throwaway `bridge.db` (`crate::test_support::state`), and the bearer is the local
    //! token that state installs.

    use super::*;
    use axum::extract::{Path, State};

    const LOCAL: &str = "test-local-token";

    fn auth() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            format!("Bearer {LOCAL}").parse().unwrap(),
        );
        headers
    }

    fn definition() -> Value {
        json!({
            "version": 1,
            "id": "box",
            "name": "Box",
            "body": { "path": "M20 20 H80 V80 H20 Z" },
            "eyes": { "x": 50, "y": 46, "spacing": 15, "scale": 1 },
        })
    }

    async fn put(st: &Arc<AppState>, bot: &str, body: Value) -> Result<Json<Value>, AuthFail> {
        put_icon(State(Arc::clone(st)), auth(), Path(bot.to_string()), Json(body)).await
    }

    async fn get(st: &Arc<AppState>) -> Value {
        get_icons(State(Arc::clone(st)), auth()).await.expect("icons").0
    }

    #[tokio::test]
    async fn a_definition_and_colour_round_trip_through_the_document() {
        let dir = crate::test_support::scratch("bot-avatar-round-trip");
        let st = Arc::new(crate::test_support::state(&dir));

        put(&st, "cody", json!({
            "avatar": "#A97EFE::shape_1",
            "definition": definition(),
            "color": "#A97EFE",
        }))
        .await
        .expect("a valid definition is stored");

        let stored = get(&st).await;
        assert_eq!(stored["faces"]["cody"]["avatar"], json!("#A97EFE::shape_1"));
        assert_eq!(stored["faces"]["cody"]["definition"], definition());
        assert_eq!(stored["faces"]["cody"]["color"], json!("#A97EFE"));

        // A second GET reads the document back from SQLite, which is what a paired device sees.
        let again = get(&st).await;
        assert_eq!(again["faces"]["cody"]["definition"], definition());
    }

    #[tokio::test]
    async fn an_invalid_definition_is_refused_and_nothing_is_written() {
        let dir = crate::test_support::scratch("bot-avatar-refusal");
        let st = Arc::new(crate::test_support::state(&dir));

        let mut bad = definition();
        bad["body"]["path"] = json!("M20 20 H140 V80 H20 Z");
        let (status, body) = put(&st, "cody", json!({ "definition": bad }))
            .await
            .expect_err("a path leaving the box must be refused");
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let detail = body.0["detail"].as_str().unwrap_or_default();
        assert!(detail.contains("invalid avatar definition"), "{detail}");
        assert!(detail.contains("right edge x=140"), "{detail}");

        assert_eq!(get(&st).await["faces"].as_object().map(|f| f.len()), Some(0));
    }

    #[tokio::test]
    async fn a_bad_colour_is_refused() {
        let dir = crate::test_support::scratch("bot-avatar-colour");
        let st = Arc::new(crate::test_support::state(&dir));
        let (status, body) = put(&st, "cody", json!({ "color": "orange" }))
            .await
            .expect_err("a colour that is not hex must be refused");
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(body.0["detail"].as_str().unwrap_or_default().contains("color"));
    }

    #[tokio::test]
    async fn clearing_the_avatar_clears_the_entry_but_the_face_alone_keeps_it() {
        let dir = crate::test_support::scratch("bot-avatar-clear");
        let st = Arc::new(crate::test_support::state(&dir));

        put(&st, "cody", json!({ "avatar": "#A97EFE", "definition": definition() }))
            .await
            .expect("stored");
        // The old picker's own write: it only ever sends `avatar`, and clearing the face must not
        // touch the avatar it does not know about.
        put(&st, "cody", json!({ "avatar": null }))
            .await
            .expect("cleared face");
        assert_eq!(get(&st).await["faces"]["cody"]["definition"], definition());

        put(&st, "cody", json!({ "definition": null }))
            .await
            .expect("cleared avatar");
        assert_eq!(get(&st).await["faces"].as_object().map(|f| f.len()), Some(0));
    }

    #[tokio::test]
    async fn a_material_round_trips_beside_the_definition() {
        let dir = crate::test_support::scratch("bot-avatar-material");
        let st = Arc::new(crate::test_support::state(&dir));

        put(&st, "cody", json!({
            "definition": definition(),
            "color": "#A97EFE",
            "material": "glass",
        }))
        .await
        .expect("glass is a material");

        let stored = get(&st).await;
        assert_eq!(stored["faces"]["cody"]["material"], json!("glass"));
        // …and it is in SQLite, which is what a paired device reads on the next launch.
        assert_eq!(get(&st).await["faces"]["cody"]["material"], json!("glass"));

        // Back to solid: the field is stored, not dropped, because a bot may choose it explicitly.
        put(&st, "cody", json!({ "material": "solid" }))
            .await
            .expect("solid is a material");
        assert_eq!(get(&st).await["faces"]["cody"]["material"], json!("solid"));
    }

    #[tokio::test]
    async fn an_absent_material_is_not_written_and_means_solid() {
        let dir = crate::test_support::scratch("bot-avatar-material-absent");
        let st = Arc::new(crate::test_support::state(&dir));

        put(&st, "cody", json!({ "definition": definition(), "color": "#A97EFE" }))
            .await
            .expect("stored");
        // Absent, not defaulted into the document: nothing already saved is rewritten, and every
        // reader treats a missing field as solid.
        assert!(get(&st).await["faces"]["cody"].get("material").is_none());

        // An explicit null is the same thing: solid, and not a value in the document.
        put(&st, "cody", json!({ "material": null })).await.expect("null clears");
        assert!(get(&st).await["faces"]["cody"].get("material").is_none());
    }

    #[tokio::test]
    async fn an_unknown_material_is_refused_and_nothing_is_written() {
        let dir = crate::test_support::scratch("bot-avatar-material-refusal");
        let st = Arc::new(crate::test_support::state(&dir));

        let (status, body) = put(&st, "cody", json!({
            "definition": definition(),
            "material": "chrome",
        }))
        .await
        .expect_err("chrome is not a material");
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let detail = body.0["detail"].as_str().unwrap_or_default();
        // The sentence names every material the runtime does accept, so an editor can show it as-is.
        assert_eq!(
            detail,
            "material must be \"solid\", \"glass\", \"matte\" or \"metal\", not \"chrome\""
        );
        // The whole write is refused, not just the field: a bot must not keep half a change.
        assert_eq!(get(&st).await["faces"].as_object().map(|f| f.len()), Some(0));
    }

    #[tokio::test]
    async fn every_material_the_app_offers_round_trips_through_the_document() {
        // The table in `BotAvatarMaterial.swift` grows, and this is the host's own check that each
        // row it names is storable — the Python guard compares the two lists, this stores them.
        let dir = crate::test_support::scratch("bot-avatar-materials-round-trip");
        let st = Arc::new(crate::test_support::state(&dir));

        for material in crate::bot_avatar::MATERIALS {
            put(&st, "cody", json!({ "definition": definition(), "material": material }))
                .await
                .unwrap_or_else(|(status, body)| {
                    panic!("{material} is not storable: {status} {}", body.0)
                });
            assert_eq!(get(&st).await["faces"]["cody"]["material"], json!(material));
        }
    }

    #[tokio::test]
    async fn clearing_the_definition_clears_the_material_with_it() {
        let dir = crate::test_support::scratch("bot-avatar-material-clear");
        let st = Arc::new(crate::test_support::state(&dir));

        put(&st, "cody", json!({ "definition": definition(), "material": "glass" }))
            .await
            .expect("stored");
        assert_eq!(get(&st).await["faces"]["cody"]["material"], json!("glass"));

        put(&st, "cody", json!({ "definition": null }))
            .await
            .expect("cleared");
        // A material describes how to paint a definition; with the definition gone it is a setting
        // for a face that does not exist, and the whole entry goes.
        assert_eq!(get(&st).await["faces"].as_object().map(|f| f.len()), Some(0));
    }
}
