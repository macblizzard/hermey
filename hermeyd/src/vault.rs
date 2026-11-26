//! The vault's face to the owner: what the Vault pane lists, and the two things it can do to an item.
//!
//! ```text
//! GET    /v1/vault            -> 200 {"items": [{name, kind, addedAt, site?, note?}]}
//! PATCH  /v1/vault/{*name}    -> 200 {"name": "<name after>", "renamed": bool, "replaced": bool}
//!                            -> 404 {"detail": "no secret by that name"}
//!                            -> 409 {"detail": "another secret already has that name"} | store failure
//!                            -> 422 {"detail": "a secret name is letters, digits, …"} | nothing to change
//!                            -> 413 {"detail": "that value is larger than 4096 bytes"}
//! DELETE /v1/vault/{*name}    -> 200 {"deleted": "<name>"}
//!                            -> 404 {"detail": "no secret by that name"}
//!                            -> 422 {"detail": "a secret name is letters, digits, …"}
//!                            -> 409 {"detail": "the secret store …"}
//! ```
//!
//! **A value has nowhere to travel.** The store itself is `secrets.rs`: a name→value map, `0600`, with
//! no route that reads it. This module serves the *names* only, and it never calls `secrets::get` — none
//! of the routes here can see a value, so none can return, format or log one. `VaultItem` below has no
//! field for a value, which is the cheapest proof of that: the type a response is built from could not
//! carry one even if a later edit wanted it to.
//!
//! **A value goes in two ways, and both are the store's own write.** A new item appears when the owner
//! answers a credential card made with `store: true` (`credentials.rs`) — the same path a bot's request
//! takes, and the only way an item is *created*. An item that already exists can have its value
//! *replaced* by `PATCH /v1/vault/{name}`, which hands the text straight to `secrets::edit` and gets
//! nothing back but the name it now has. Neither route accepts a name it would not store, and neither
//! answers with anything that was typed: an edit is write-only in the literal sense, because there is no
//! shape in this module a value could be read out of.
//!
//! **Metadata is an index, not a second store.** `secrets.json` stays what it was — names and values —
//! because changing its shape would mean migrating every secret the owner has saved. The labels a row
//! shows beside a name (`site`, `note`, `kind`, `addedAt`) live in the host's document store under
//! `vault:index`, keyed by name, and hold no value. An entry with no index record — one saved before
//! this pane existed — is still listed, dated by the store file's own timestamp.
//!
//! **Deleting is the store's own removal**, not a tombstone: `secrets::remove` rewrites the map without
//! the name, so the value stops existing rather than being hidden.

use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

/// Where the pane's labels live. A document, not a file: it is a handful of short strings and it
/// belongs with the rest of the host's small state.
const INDEX_KEY: &str = "vault:index";

/// One row of the vault, as both apps decode it (`Sources/HermesKit/VaultItems.swift`).
///
/// There is deliberately no `value` member. A field that does not exist is a field a serialiser cannot
/// write, so "the list never contains a secret" is a property of the type rather than of a filter
/// somebody has to remember to keep.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VaultItem<'a> {
    name: &'a str,
    kind: &'a str,
    added_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    site: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<&'a str>,
}

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({ "detail": msg.into() })))
}

/// The name pattern's own sentence, used by both routes so a refusal reads the same everywhere.
fn name_rule() -> String {
    format!(
        "a secret name is letters, digits, '.', '_', '-' and one '/', up to {} characters",
        crate::secrets::MAX_NAME_BYTES
    )
}

fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn load_index(st: &AppState) -> Map<String, Value> {
    st.store
        .doc_or(INDEX_KEY, json!({ "items": {} }))
        .get("items")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

fn save_index(st: &AppState, items: Map<String, Value>) {
    st.store.set_doc(INDEX_KEY, &json!({ "items": items }));
}

/// Remember where a stored credential came from, so its row can say "for api.openai.com".
///
/// Called by `credentials.rs` at the moment the answer reaches the vault. It records the card's own
/// `site`/`note`/`kind` and the time — scalars the owner could already read on the card — and nothing
/// that was typed into it. A name keeps only its most recent card, which is the same rule the store
/// itself follows: a second save under one name replaces the first.
pub fn note_stored(st: &AppState, name: &str, kind: &str, site: &str, note: &str) {
    if !crate::secrets::valid_name(name) {
        return;
    }
    let mut items = load_index(st);
    let mut record = Map::new();
    record.insert("kind".into(), json!(kind));
    record.insert("added_at".into(), json!(now()));
    if !site.is_empty() {
        record.insert("site".into(), json!(site));
    }
    if !note.is_empty() {
        record.insert("note".into(), json!(note));
    }
    items.insert(name.to_string(), Value::Object(record));
    save_index(st, items);
}

/// Drop a name's labels with the name, so a later secret saved under the same name cannot inherit the
/// old row's site or date.
fn forget(st: &AppState, name: &str) {
    let mut items = load_index(st);
    if items.remove(name).is_some() {
        save_index(st, items);
    }
}

/// Carry a renamed item's labels over to its new name, so the row keeps saying where it is for.
///
/// The **secret** is one write (`secrets::edit`); this is the decoration that follows it, in the host's
/// own document store. Moving the record rather than copying it matters both ways: the new name keeps
/// its site and its added date, and the old name does not leave labels behind for whatever secret is
/// saved under it next. A record that cannot be moved leaves the item listed and dated by the store —
/// the same degraded row an entry from before this index existed gets — so a lost label is never a lost
/// secret.
fn move_labels(st: &AppState, from: &str, to: &str) {
    if from == to {
        return;
    }
    let mut items = load_index(st);
    if let Some(record) = items.remove(from) {
        items.insert(to.to_string(), record);
        save_index(st, items);
    }
}

/// `GET /v1/vault` — the names the owner has saved, newest first.
pub async fn list(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    // An unreadable store is an error and not an empty list: an empty vault and a broken one must
    // never look the same in the pane, or the owner sees "you have saved nothing" when the truth is
    // "the file could not be read".
    let names = crate::secrets::names(&st).map_err(|why| bad(StatusCode::CONFLICT, why))?;
    let index = load_index(&st);
    let fallback = crate::secrets::modified_at(&st).unwrap_or_else(now);

    let mut items: Vec<VaultItem> = names
        .iter()
        .map(|name| {
            let record = index.get(name);
            let text = |key: &str| record.and_then(|r| r.get(key)).and_then(Value::as_str);
            VaultItem {
                name,
                kind: text("kind").unwrap_or("secret"),
                added_at: record
                    .and_then(|r| r.get("added_at"))
                    .and_then(Value::as_f64)
                    .unwrap_or(fallback),
                site: text("site"),
                note: text("note"),
            }
        })
        .collect();

    // Newest first, then by name: a stable order that does not depend on the file's key order, so the
    // row the owner just added is at the top on both devices.
    items.sort_by(|a, b| {
        b.added_at
            .partial_cmp(&a.added_at)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.name.cmp(b.name))
    });
    Ok(Json(json!({ "items": items })))
}

/// `DELETE /v1/vault/{name}` — forget one secret, by name.
///
/// The name may contain one `/` (`doctolib.de/password`), so the route is a wildcard and the client
/// percent-encodes the separator. Three answers, three codes: the name is not one the store would hold
/// (422), the store does not have it (404 — the app surfaces this rather than redrawing as if the
/// delete worked), or it is gone (200).
pub async fn delete_item(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(name): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !crate::secrets::valid_name(&name) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, name_rule()));
    }
    match crate::secrets::remove(&st, &name) {
        Ok(true) => {
            forget(&st, &name);
            Ok(Json(json!({ "deleted": name })))
        }
        Ok(false) => Err(bad(StatusCode::NOT_FOUND, "no secret by that name")),
        Err(why) => Err(bad(StatusCode::CONFLICT, why)),
    }
}

/// What an edit carries: the name to move to, and — only when the owner typed one — a new value.
///
/// Both are optional, and absent means "leave it alone". This type is the request's shape, never a
/// response's: nothing in this file serialises it, and `value` has no counterpart on `VaultItem`, so a
/// value that arrives here has exactly one way back out — into the store.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditRequest {
    /// The item's new name. Absent, or the name it already has, is a rename that renames nothing.
    #[serde(default)]
    rename: Option<String>,
    /// The replacement value. Absent, empty, or `null` keeps the stored one — a sheet that leaves the
    /// field blank is asking to change the name only, which is why blank is not a refusal here.
    #[serde(default)]
    value: Option<String>,
}

/// `PATCH /v1/vault/{name}` — rename an item and, when a value is given, replace it. Write-only.
///
/// One request carries both halves and one `secrets::edit` writes both, so a rename cannot land without
/// the value it came with, or the other way round. The answer says which half happened — the name it now
/// has, and two booleans — and never anything that was typed: the value is handed to the store and the
/// handler that received it returns before it could be formatted anywhere.
///
/// Codes, and why each one exists: the name in the path or the rename target is not a name the store
/// would hold (422 — checked *before* any lookup, so a path can never be read as one), nothing changed
/// (422 — a silent success would tell the pane an edit happened), no secret under the old name (404),
/// another secret already holds the new name (409 — refusing is what stops one item from swallowing
/// another), a value over the limit (413), the store itself unreadable (409).
pub async fn edit_item(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(name): Path<String>,
    Json(body): Json<EditRequest>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !crate::secrets::valid_name(&name) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, name_rule()));
    }
    // A rename to the name it already has is the same item; treated as no rename at all, so the store
    // is not asked to move a key onto itself.
    let rename_to = match body.rename.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        None => name.clone(),
        Some(next) if !crate::secrets::valid_name(next) => {
            return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, name_rule()))
        }
        Some(next) => next.to_string(),
    };
    // A blank value is "keep the current one", not "store nothing": the sheet starts empty on purpose,
    // and it is the only reading under which a rename-only edit is expressible.
    let value = body.value.filter(|v| !v.is_empty());
    if let Some(text) = value.as_deref() {
        if text.len() > crate::secrets::MAX_VALUE_BYTES {
            return Err(bad(
                StatusCode::PAYLOAD_TOO_LARGE,
                format!("that value is larger than {} bytes", crate::secrets::MAX_VALUE_BYTES),
            ));
        }
    }
    if rename_to == name && value.is_none() {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "nothing to change: that is already the name, and no value was given",
        ));
    }

    // The value goes to the store and comes back as an outcome. There is no branch below in which the
    // text is a local variable this function could print, and the reply is built from the *names*.
    match crate::secrets::edit(&st, &name, &rename_to, value.as_deref()) {
        Ok(crate::secrets::EditOutcome::Changed) => {
            move_labels(&st, &name, &rename_to);
            Ok(Json(json!({
                "name": rename_to,
                "renamed": rename_to != name,
                "replaced": value.is_some(),
            })))
        }
        Ok(crate::secrets::EditOutcome::Missing) => {
            Err(bad(StatusCode::NOT_FOUND, "no secret by that name"))
        }
        Ok(crate::secrets::EditOutcome::Taken) => Err(bad(
            StatusCode::CONFLICT,
            "another secret already has that name",
        )),
        Err(why) => Err(bad(StatusCode::CONFLICT, why)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::header::AUTHORIZATION;
    use std::path::{Path, PathBuf};

    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";
    const SECRET: &str = "test-secret-value";

    fn scratch(tag: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-vault-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

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
        headers
            .insert(AUTHORIZATION, format!("Bearer {LOCAL}").parse().unwrap());
        headers
    }

    async fn items(st: &Arc<AppState>) -> Value {
        list(State(Arc::clone(st)), auth()).await.expect("list").0
    }

    /// The promise, asserted on the serialised body: the names are there, and the values are not —
    /// nowhere in the JSON, and not as a key either.
    #[tokio::test]
    async fn the_list_serves_names_and_never_a_value() {
        let dir = scratch("names");
        let st = state(&dir);
        crate::secrets::put(&st, "api.openai.com/api-key", SECRET).expect("stored");
        crate::secrets::put(&st, "doctolib.de/password", "hunter2-another").expect("stored");

        let body = items(&st).await;
        let text = body.to_string();
        assert!(!text.contains(SECRET), "the list carried a value: {text}");
        assert!(!text.contains("hunter2-another"), "the list carried a value: {text}");

        let rows = body["items"].as_array().expect("items");
        assert_eq!(rows.len(), 2);
        let names: Vec<&str> = rows.iter().filter_map(|r| r["name"].as_str()).collect();
        assert!(names.contains(&"api.openai.com/api-key"), "{names:?}");
        assert!(names.contains(&"doctolib.de/password"), "{names:?}");

        // Every key of every row is one the shape allows — a `value` key would fail here even if its
        // content were empty, which is the check that would have caught a well-meant "just the length".
        let allowed = ["name", "kind", "addedAt", "site", "note"];
        for row in rows {
            for key in row.as_object().expect("row").keys() {
                assert!(allowed.contains(&key.as_str()), "unexpected key {key:?} in {row}");
            }
            assert!(row["addedAt"].as_f64().unwrap_or(0.0) > 0.0, "a row is dated: {row}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An empty vault is an honest empty list — the pane tells that apart from a failure by the
    /// status, not by the count.
    #[tokio::test]
    async fn an_empty_vault_is_an_empty_list() {
        let dir = scratch("empty");
        let st = state(&dir);
        let body = items(&st).await;
        assert_eq!(body["items"].as_array().map(Vec::len), Some(0), "{body}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Delete is by name, refuses a name the store would not hold, and answers 404 for one it does not
    /// have instead of pretending it did something.
    #[tokio::test]
    async fn delete_removes_the_name_and_tells_the_three_cases_apart() {
        let dir = scratch("delete");
        let st = state(&dir);
        crate::secrets::put(&st, "api.openai.com/api-key", SECRET).expect("stored");
        crate::secrets::put(&st, "doctolib.de/password", "hunter2-another").expect("stored");
        note_stored(&st, "api.openai.com/api-key", "secret", "api.openai.com", "Reading models");

        let gone = delete_item(
            State(Arc::clone(&st)),
            auth(),
            Path("api.openai.com/api-key".to_string()),
        )
        .await
        .expect("deleted")
        .0;
        assert_eq!(gone["deleted"], "api.openai.com/api-key");
        assert!(!crate::secrets::has(&st, "api.openai.com/api-key"), "the value is gone with the name");
        assert!(crate::secrets::has(&st, "doctolib.de/password"), "the other entry is untouched");

        let body = items(&st).await;
        assert_eq!(body["items"].as_array().unwrap().len(), 1, "{body}");
        assert_eq!(body["items"][0]["name"], "doctolib.de/password");
        // The label went with the name: a secret saved under it again starts clean.
        assert!(load_index(&st).get("api.openai.com/api-key").is_none());

        // The same name twice: the second is a 404, not a silent success.
        let missing = delete_item(
            State(Arc::clone(&st)),
            auth(),
            Path("api.openai.com/api-key".to_string()),
        )
        .await
        .expect_err("already gone");
        assert_eq!(missing.0, StatusCode::NOT_FOUND);

        // A name the store would never hold is refused before anything is looked up.
        for bad_name in ["/etc/passwd", "../x", "a b", "a//b", ""] {
            let refused = delete_item(
                State(Arc::clone(&st)),
                auth(),
                Path(bad_name.to_string()),
            )
            .await
            .expect_err(bad_name);
            assert_eq!(refused.0, StatusCode::UNPROCESSABLE_ENTITY, "{bad_name:?}");
        }
        assert!(crate::secrets::has(&st, "doctolib.de/password"), "a refused delete removed nothing");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Both routes are the owner's: a caller without the device's bearer gets nothing.
    #[tokio::test]
    async fn both_routes_need_a_device_token() {
        let dir = scratch("auth");
        let st = state(&dir);
        crate::secrets::put(&st, "api.openai.com/api-key", SECRET).expect("stored");
        assert_eq!(
            list(State(Arc::clone(&st)), HeaderMap::new()).await.expect_err("no token").0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            delete_item(State(Arc::clone(&st)), HeaderMap::new(), Path("api.openai.com/api-key".to_string()))
                .await
                .expect_err("no token")
                .0,
            StatusCode::UNAUTHORIZED
        );
        assert!(crate::secrets::has(&st, "api.openai.com/api-key"), "an unauthorised delete removed nothing");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The labels come from the card that stored the answer, and a name saved before the index existed
    /// is still listed — dated by the store, and without inventing a site.
    #[tokio::test]
    async fn a_row_says_where_it_is_for_and_an_old_entry_is_still_listed() {
        let dir = scratch("meta");
        let st = state(&dir);
        crate::secrets::put(&st, "api.openai.com/api-key", SECRET).expect("stored");
        note_stored(&st, "api.openai.com/api-key", "secret", "api.openai.com", "Reading the model list");
        crate::secrets::put(&st, "legacy.name", "old-value").expect("stored");

        let body = items(&st).await;
        let rows = body["items"].as_array().unwrap();
        assert_eq!(rows.len(), 2, "{body}");
        let saved = rows.iter().find(|r| r["name"] == "api.openai.com/api-key").expect("row");
        assert_eq!(saved["site"], "api.openai.com");
        assert_eq!(saved["note"], "Reading the model list");
        assert_eq!(saved["kind"], "secret");
        let legacy = rows.iter().find(|r| r["name"] == "legacy.name").expect("row");
        assert!(legacy.get("site").is_none(), "an unlabelled entry invents no site: {legacy}");
        assert!(legacy["addedAt"].as_f64().unwrap() > 0.0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A corrupt store is a refusal, not an empty vault — the one confusion the pane must never make.
    #[tokio::test]
    async fn an_unreadable_store_is_an_error_and_not_an_empty_list() {
        let dir = scratch("corrupt");
        let st = state(&dir);
        crate::secrets::put(&st, "api.openai.com/api-key", SECRET).expect("stored");
        std::fs::write(crate::secrets::path(&st), "{not json").unwrap();

        let refused = list(State(Arc::clone(&st)), auth()).await.expect_err("readable?");
        assert_eq!(refused.0, StatusCode::CONFLICT);
        assert!(!refused.1 .0.to_string().contains(SECRET), "a refusal quotes nothing");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The wire, over a real socket and the real router: a name with a `/` in it survives the path,
    /// and the bytes that come back are the shape the apps decode — with no value in them.
    ///
    /// Called directly, the handlers would pass even if the wildcard route were wrong, so this mounts
    /// `/v1/vault` and `/v1/vault/{*name}` exactly as `main.rs` does and speaks HTTP to it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_wire_shape_holds_over_http_for_a_name_with_a_slash() {
        let dir = scratch("wire");
        let st = state(&dir);
        crate::secrets::put(&st, "doctolib.de/password", SECRET).expect("stored");
        note_stored(&st, "doctolib.de/password", "login", "doctolib.de", "The booking site");

        let app = axum::Router::new()
            .route("/v1/vault", axum::routing::get(list))
            .route("/v1/vault/{*name}", axum::routing::delete(delete_item))
            .with_state(Arc::clone(&st));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = reqwest::Client::new();
        let bearer = format!("Bearer {LOCAL}");

        let listed = client
            .get(format!("http://{addr}/v1/vault"))
            .header("Authorization", &bearer)
            .send()
            .await
            .expect("GET");
        assert_eq!(listed.status(), reqwest::StatusCode::OK);
        let body = listed.text().await.expect("body");
        assert!(!body.contains(SECRET), "the wire carried a value: {body}");
        assert!(body.contains("doctolib.de/password"), "the name is on the wire: {body}");
        assert!(body.contains("The booking site"), "the label is on the wire: {body}");

        // The separator is percent-encoded by the apps (`URLPath.componentAllowed` excludes `/`), and
        // the wildcard decodes it back to the name the store holds.
        let deleted = client
            .delete(format!("http://{addr}/v1/vault/doctolib.de%2Fpassword"))
            .header("Authorization", &bearer)
            .send()
            .await
            .expect("DELETE");
        assert_eq!(deleted.status(), reqwest::StatusCode::OK, "a name with '/' must route");
        assert!(!crate::secrets::has(&st, "doctolib.de/password"));

        // …and the same name again is the 404 the pane surfaces rather than hiding.
        let again = client
            .delete(format!("http://{addr}/v1/vault/doctolib.de%2Fpassword"))
            .header("Authorization", &bearer)
            .send()
            .await
            .expect("DELETE");
        assert_eq!(again.status(), reqwest::StatusCode::NOT_FOUND);

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }

    // --- editing: a rename and a replacement, write-only ------------------------------------------

    /// The edit's whole job: one request renames the item **and** replaces its value, and the answer
    /// names the item where it now is without carrying a byte of what was typed.
    #[tokio::test]
    async fn an_edit_renames_and_replaces_the_value_in_one_write() {
        let dir = scratch("edit");
        let st = state(&dir);
        crate::secrets::put(&st, "doctolib.de/password", SECRET).expect("stored");
        note_stored(&st, "doctolib.de/password", "login", "doctolib.de", "The booking site");

        let answer = edit_item(
            State(Arc::clone(&st)),
            auth(),
            Path("doctolib.de/password".to_string()),
            Json(EditRequest {
                rename: Some("doctolib.de/login".to_string()),
                value: Some("a-brand-new-value".to_string()),
            }),
        )
        .await
        .expect("edited")
        .0;

        assert_eq!(answer["name"], "doctolib.de/login");
        assert_eq!(answer["renamed"], true);
        assert_eq!(answer["replaced"], true);
        // The promise, asserted on the bytes that go back: neither the old value nor the new one.
        let text = answer.to_string();
        assert!(!text.contains(SECRET), "the answer carried the old value: {text}");
        assert!(!text.contains("a-brand-new-value"), "the answer carried the new value: {text}");
        // …and the reply has no key a value could hide in.
        let keys: Vec<&String> = answer.as_object().expect("object").keys().collect();
        for key in keys {
            assert!(["name", "renamed", "replaced"].contains(&key.as_str()), "unexpected key {key:?}");
        }

        // Moved, not copied: one item, under the new name, holding the new value.
        assert!(!crate::secrets::has(&st, "doctolib.de/password"));
        assert_eq!(
            crate::secrets::get(&st, "doctolib.de/login").as_deref(),
            Some("a-brand-new-value")
        );
        // …and the labels went with it, so the row still says where it is for.
        let listed = items(&st).await;
        assert_eq!(listed["items"].as_array().map(Vec::len), Some(1), "{listed}");
        assert_eq!(listed["items"][0]["name"], "doctolib.de/login");
        assert_eq!(listed["items"][0]["site"], "doctolib.de");
        assert_eq!(listed["items"][0]["note"], "The booking site");
        assert!(
            load_index(&st).get("doctolib.de/password").is_none(),
            "the old name kept labels a later secret would inherit"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A rename with no value keeps the stored one — including the blank string the sheet sends when the
    /// field was left alone, which is why blank is "keep" here and a refusal on a create.
    #[tokio::test]
    async fn an_edit_with_no_value_keeps_the_stored_one() {
        let dir = scratch("edit-keep");
        let st = state(&dir);
        crate::secrets::put(&st, "api.openai.com/api-key", SECRET).expect("stored");

        let renamed = edit_item(
            State(Arc::clone(&st)),
            auth(),
            Path("api.openai.com/api-key".to_string()),
            Json(EditRequest { rename: Some("openai.main".to_string()), value: None }),
        )
        .await
        .expect("renamed")
        .0;
        assert_eq!(renamed["name"], "openai.main");
        assert_eq!(renamed["renamed"], true);
        assert_eq!(renamed["replaced"], false);
        assert_eq!(crate::secrets::get(&st, "openai.main").as_deref(), Some(SECRET));

        // A blank value is the same request: the sheet starts empty, so an empty string must not be
        // read as "store nothing" (which the store would refuse) nor as "wipe it".
        let again = edit_item(
            State(Arc::clone(&st)),
            auth(),
            Path("openai.main".to_string()),
            Json(EditRequest { rename: Some("openai.primary".to_string()), value: Some(String::new()) }),
        )
        .await
        .expect("renamed again")
        .0;
        assert_eq!(again["replaced"], false);
        assert_eq!(crate::secrets::get(&st, "openai.primary").as_deref(), Some(SECRET));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Every refusal, and the store untouched after each one: a taken name, a name that could be a
    /// path, a name nobody saved, and a request that asks for no change at all.
    #[tokio::test]
    async fn an_edit_refuses_a_taken_name_a_bad_name_a_missing_item_and_an_empty_change() {
        let dir = scratch("edit-refuse");
        let st = state(&dir);
        crate::secrets::put(&st, "api.openai.com/api-key", SECRET).expect("stored");
        crate::secrets::put(&st, "doctolib.de/password", "hunter2-another").expect("stored");

        // Renaming onto a name another secret holds is a 409 — and it must not be a 200 that swallowed
        // one item, so both values are still exactly what they were.
        let taken = edit_item(
            State(Arc::clone(&st)),
            auth(),
            Path("api.openai.com/api-key".to_string()),
            Json(EditRequest {
                rename: Some("doctolib.de/password".to_string()),
                value: Some("would-have-replaced".to_string()),
            }),
        )
        .await
        .expect_err("a taken name");
        assert_eq!(taken.0, StatusCode::CONFLICT);
        assert_eq!(crate::secrets::get(&st, "api.openai.com/api-key").as_deref(), Some(SECRET));
        assert_eq!(
            crate::secrets::get(&st, "doctolib.de/password").as_deref(),
            Some("hunter2-another")
        );

        // A name the store would never hold, on either side of the move, is refused before a lookup.
        for (from, to) in [
            ("/etc/passwd", None),
            ("../x", None),
            ("api.openai.com/api-key", Some("/etc/shadow")),
            ("api.openai.com/api-key", Some("a//b")),
        ] {
            let refused = edit_item(
                State(Arc::clone(&st)),
                auth(),
                Path(from.to_string()),
                Json(EditRequest {
                    rename: to.map(str::to_string),
                    value: Some("some-value".to_string()),
                }),
            )
            .await
            .expect_err(from);
            assert_eq!(refused.0, StatusCode::UNPROCESSABLE_ENTITY, "{from:?} -> {to:?}");
        }

        // A secret nobody saved: 404, not a create under the new name.
        let missing = edit_item(
            State(Arc::clone(&st)),
            auth(),
            Path("no.such/name".to_string()),
            Json(EditRequest { rename: None, value: Some("some-value".to_string()) }),
        )
        .await
        .expect_err("missing");
        assert_eq!(missing.0, StatusCode::NOT_FOUND);
        assert!(!crate::secrets::has(&st, "no.such/name"), "a 404 created something");

        // Same name, no value: nothing to do is a refusal, not a quiet success.
        let nothing = edit_item(
            State(Arc::clone(&st)),
            auth(),
            Path("api.openai.com/api-key".to_string()),
            Json(EditRequest { rename: Some("api.openai.com/api-key".to_string()), value: None }),
        )
        .await
        .expect_err("nothing to change");
        assert_eq!(nothing.0, StatusCode::UNPROCESSABLE_ENTITY);

        // Every refusal left both items exactly where they were.
        assert_eq!(
            items(&st).await["items"].as_array().map(Vec::len),
            Some(2),
            "a refused edit changed the list"
        );
        assert_eq!(crate::secrets::get(&st, "api.openai.com/api-key").as_deref(), Some(SECRET));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The write is one write: when it cannot land, neither half of the edit survives.
    ///
    /// `save` publishes by renaming a temp file over the store. Occupying that temp path with a
    /// directory makes the write fail even for root, and the assertion is that the item is still there
    /// under its **old** name with its **old** value — a rename that went through without its value, or
    /// the reverse, is exactly what one `save` rules out.
    #[tokio::test]
    async fn a_failed_write_leaves_the_whole_item_where_it_was() {
        let dir = scratch("edit-atomic");
        let st = state(&dir);
        crate::secrets::put(&st, "doctolib.de/password", SECRET).expect("stored");
        let blocker = dir.join(format!(".secrets.{}.tmp", std::process::id()));
        std::fs::create_dir_all(&blocker).expect("blocker");

        let refused = edit_item(
            State(Arc::clone(&st)),
            auth(),
            Path("doctolib.de/password".to_string()),
            Json(EditRequest {
                rename: Some("doctolib.de/login".to_string()),
                value: Some("a-brand-new-value".to_string()),
            }),
        )
        .await
        .expect_err("the store could not be written");
        assert_eq!(refused.0, StatusCode::CONFLICT);
        // The refusal quotes neither value.
        let text = refused.1 .0.to_string();
        assert!(!text.contains(SECRET), "{text}");
        assert!(!text.contains("a-brand-new-value"), "{text}");

        assert!(crate::secrets::has(&st, "doctolib.de/password"), "the rename survived a failed write");
        assert!(!crate::secrets::has(&st, "doctolib.de/login"), "half an edit landed");
        assert_eq!(
            crate::secrets::get(&st, "doctolib.de/password").as_deref(),
            Some(SECRET),
            "the value must be the old one, not a half-written new one"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The edit is the owner's: no device token, no rename — and nothing written.
    #[tokio::test]
    async fn an_edit_needs_the_device_token_and_writes_nothing_without_one() {
        let dir = scratch("edit-auth");
        let st = state(&dir);
        crate::secrets::put(&st, "doctolib.de/password", SECRET).expect("stored");

        let refused = edit_item(
            State(Arc::clone(&st)),
            HeaderMap::new(),
            Path("doctolib.de/password".to_string()),
            Json(EditRequest {
                rename: Some("doctolib.de/login".to_string()),
                value: Some("a-brand-new-value".to_string()),
            }),
        )
        .await
        .expect_err("no token");
        assert_eq!(refused.0, StatusCode::UNAUTHORIZED);
        assert!(crate::secrets::has(&st, "doctolib.de/password"));
        assert!(!crate::secrets::has(&st, "doctolib.de/login"));
        assert_eq!(crate::secrets::get(&st, "doctolib.de/password").as_deref(), Some(SECRET));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The wire: a PATCH on the wildcard path with a `/` in the name, the body it carries, and the
    /// answer — which has the new name in it and no value anywhere.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_edit_wire_answers_with_a_name_and_never_a_value() {
        let dir = scratch("edit-wire");
        let st = state(&dir);
        crate::secrets::put(&st, "doctolib.de/password", SECRET).expect("stored");
        note_stored(&st, "doctolib.de/password", "login", "doctolib.de", "The booking site");

        let app = axum::Router::new()
            .route("/v1/vault", axum::routing::get(list))
            .route(
                "/v1/vault/{*name}",
                axum::routing::delete(delete_item).patch(edit_item),
            )
            .with_state(Arc::clone(&st));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = reqwest::Client::new();
        let bearer = format!("Bearer {LOCAL}");

        let edited = client
            .patch(format!("http://{addr}/v1/vault/doctolib.de%2Fpassword"))
            .header("Authorization", &bearer)
            .json(&json!({ "rename": "doctolib.de/login", "value": "a-brand-new-value" }))
            .send()
            .await
            .expect("PATCH");
        assert_eq!(edited.status(), reqwest::StatusCode::OK, "a PATCH on the wildcard must route");
        let body = edited.text().await.expect("body");
        assert!(body.contains("doctolib.de/login"), "the answer names the item: {body}");
        assert!(!body.contains(SECRET), "the wire carried a value: {body}");
        assert!(!body.contains("a-brand-new-value"), "the wire carried the new value: {body}");
        assert_eq!(crate::secrets::get(&st, "doctolib.de/login").as_deref(), Some("a-brand-new-value"));

        // The list still shows one item, under the new name, and still with no value in it.
        let listed = client
            .get(format!("http://{addr}/v1/vault"))
            .header("Authorization", &bearer)
            .send()
            .await
            .expect("GET")
            .text()
            .await
            .expect("body");
        assert!(!listed.contains("a-brand-new-value"), "{listed}");
        assert!(listed.contains("doctolib.de/login"), "{listed}");

        // The old name is gone: an edit moves the item rather than copying it.
        let gone = client
            .patch(format!("http://{addr}/v1/vault/doctolib.de%2Fpassword"))
            .header("Authorization", &bearer)
            .json(&json!({ "value": "another" }))
            .send()
            .await
            .expect("PATCH");
        assert_eq!(gone.status(), reqwest::StatusCode::NOT_FOUND);

        server.abort();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
