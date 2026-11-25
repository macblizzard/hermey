//! The vault's read and delete face: what the owner's Vault pane lists, and nothing more.
//!
//! ```text
//! GET    /v1/vault            -> 200 {"items": [{name, kind, addedAt, site?, note?}]}
//! DELETE /v1/vault/{*name}    -> 200 {"deleted": "<name>"}
//!                            -> 404 {"detail": "no secret by that name"}
//!                            -> 422 {"detail": "a secret name is letters, digits, …"}
//!                            -> 409 {"detail": "the secret store …"}
//! ```
//!
//! **A value has nowhere to travel.** The store itself is `secrets.rs`: a name→value map, `0600`, with
//! no route that reads it. This module serves the *names* only, and it never calls `secrets::get` — the
//! two routes here cannot see a value, so they cannot return, format or log one. `VaultItem` below has
//! no field for a value, which is the cheapest proof of that: the type a response is built from could
//! not carry one even if a later edit wanted it to.
//!
//! **Adding has one door.** Nothing here writes a value. An item appears when the owner answers a
//! credential card made with `store: true` (`credentials.rs`), which is the same path a bot's
//! request takes; a Vault pane's "add" is that card, seen from the other side. A second write route
//! would be a second way into the store, and the point of the vault is that there is exactly one.
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
use serde::Serialize;
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::header::AUTHORIZATION;
    use std::path::{Path, PathBuf};

    const LOCAL: &str = "local-cli-token-0123456789abcdef0123456789abcdef";
    const SECRET: &str = "sk-live-5f3a9d-not-a-real-key";

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
}
