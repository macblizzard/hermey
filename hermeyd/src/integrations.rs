//! Integrations: connect the owner's Google accounts to this host through Composio.
//!
//! The app taps Connect, this service asks Composio for a **hosted** sign-in link, and the browser
//! opens Composio's own page — sign-in, consent and "you're connected" all happen there. The project
//! key never leaves this host and never reaches the app, the same rule as the login cards.
//!
//! Composio's model, which is what makes one key serve many people: an **auth config** is a per-toolkit
//! blueprint (Composio manages the OAuth app), and a **connected account** is one owner's grant,
//! addressed by `user_id`.
//!
//! ```text
//! GET  /v1/integrations                     -> {configured, user, services[]}
//! POST /v1/integrations/{slug}/connect       {alias?} -> {url}
//! GET  /v1/integrations/{slug}/tools        -> {tools:[{slug,name}]}
//! POST /v1/integrations/{slug}/alias         {alias, account_id?}
//! POST /v1/integrations/{slug}/disconnect    {account_id?}
//! POST /v1/integrations/run                  {tool_slug, arguments, account_id?}
//! GET  /v1/integrations/{slug}/key-fields    -> {slug, fields:[{name,label,required,secret}]}
//! POST /v1/integrations/{slug}/key-connect   {values} -> {ok, account_id, status}
//! ```
//!
//! `connected` is derived from the account list rather than trusted from Composio, and **every** active
//! account is returned: showing only the first made a second Gmail invisible and made Disconnect revoke
//! whichever it happened to find.
//!
//! The key lives in `$HERMEY_HOME/.env` (`HERMEY_COMPOSIO_API_KEY`) — never the production managed env.

use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::path::Path as FsPath;
use std::sync::{Arc, OnceLock};

type Fail = (StatusCode, Json<Value>);

const API: &str = "https://backend.composio.dev/api/v3.1";
const TIMEOUT_SECS: u64 = 20;
const DEFAULT_USER: &str = "hermey-owner";
const USER_AGENT: &str = "hermeyd/1.0";

/// What the Integrations screen offers, in the order the app shows them.
///
/// The last two are the key-based pair: their only Composio scheme is an API key, so they are the
/// rows `key_based` is true for and the ones `key-fields`/`key-connect` serve below.
const CATALOG: [(&str, &str, &str); 8] = [
    ("gmail", "Gmail", "Read, search and send mail"),
    ("googlecalendar", "Google Calendar", "See and change your calendar"),
    ("googledrive", "Google Drive", "Find and open files"),
    ("googledocs", "Google Docs", "Read and write documents"),
    ("googlesheets", "Google Sheets", "Read and edit spreadsheets"),
    ("googlemaps", "Google Maps", "Places, directions and distance"),
    ("cloudflare", "Cloudflare", "DNS, cache and Workers"),
    ("vercel", "Vercel", "Deployments, domains and projects"),
];

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

struct Composio {
    key: String,
    user: String,
    client: reqwest::Client,
}

fn env_or_file(name: &str, text: &str) -> String {
    if let Ok(v) = std::env::var(name) {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            if k.trim() == name {
                return v.trim().trim_matches('"').trim_matches('\'').to_string();
            }
        }
    }
    String::new()
}

fn composio(st: &AppState) -> &'static Composio {
    static CLIENT: OnceLock<Composio> = OnceLock::new();
    CLIENT.get_or_init(|| {
        // `host_env` owns the location: `HERMEY_HOME/.env` first, then the engine home's own, then
        // its parent. A missing file is an empty text, which `env_or_file` already models.
        let env_text = crate::host_env::read_text(&st.engine_home);
        let user = env_or_file("HERMEY_COMPOSIO_USER_ID", &env_text);
        Composio {
            key: env_or_file("HERMEY_COMPOSIO_API_KEY", &env_text),
            user: if user.is_empty() { DEFAULT_USER.to_string() } else { user },
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(TIMEOUT_SECS))
                .build()
                .unwrap_or_default(),
        }
    })
}

impl Composio {
    fn configured(&self) -> bool {
        !self.key.is_empty()
    }

    async fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, String> {
        if !self.configured() {
            return Err("no Composio key on this host".to_string());
        }
        let url = format!("{API}{path}");
        let mut request = self
            .client
            .request(
                reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| "bad method".to_string())?,
                &url,
            )
            .header("x-api-key", &self.key)
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            .header(reqwest::header::ACCEPT, "application/json");
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|e| format!("Composio unreachable: {e}"))?;
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        if !status.is_success() {
            // The body can echo the request back; report the status only.
            return Err(format!("Composio refused the request ({})", status.as_u16()));
        }
        serde_json::from_str(&text).map_err(|_| "Composio returned something that is not JSON".to_string())
    }

    /// Items out of either shape Composio uses: `{items:[…]}` or a bare list.
    async fn items(&self, path: &str) -> Result<Vec<Value>, String> {
        let reply = self.call("GET", path, None).await?;
        let items = match &reply {
            Value::Object(map) => map.get("items").cloned().unwrap_or_else(|| json!([])),
            Value::Array(_) => reply.clone(),
            _ => json!([]),
        };
        Ok(items.as_array().cloned().unwrap_or_default())
    }

    /// Active accounts, or the reason they could not be read.
    ///
    /// This used to answer `[]` on any failure, which made a Composio that was unreachable or had
    /// refused the key look exactly like an owner who had connected nothing — and every caller
    /// downstream ("nothing is connected for that service") repeated that guess as fact.
    async fn accounts(&self, slug: Option<&str>) -> Result<Vec<Value>, String> {
        let mut path = format!("/connected_accounts?user_id={}", urlencoding::encode(&self.user));
        if let Some(slug) = slug {
            path.push_str(&format!("&toolkit_slug={}", urlencoding::encode(slug)));
        }
        let rows = self.items(&path).await?;
        Ok(rows
            .into_iter()
            .filter(|row| {
                // More than one account per toolkit is normal once a second Gmail exists.
                row.get("status").and_then(|s| s.as_str()).map(|s| s.eq_ignore_ascii_case("active")).unwrap_or(false)
            })
            .filter(|row| match slug {
                None => true,
                Some(slug) => toolkit_of(row) == slug,
            })
            .collect())
    }

    async fn auth_config_id(&self, slug: &str) -> Option<String> {
        let path = format!("/auth_configs?toolkit_slug={}", urlencoding::encode(slug));
        let rows = self.items(&path).await.ok()?;
        for row in rows {
            if toolkit_of(&row) != slug {
                continue;
            }
            match row.get("status").and_then(|s| s.as_str()) {
                None | Some("ENABLED") | Some("enabled") => {}
                _ => continue,
            }
            if let Some(id) = row.get("id").or_else(|| row.get("nanoid")).and_then(|v| v.as_str()) {
                return Some(id.to_string());
            }
        }
        None
    }

    /// The toolkit's blueprint, created with Composio-managed auth when the project has none: asking a
    /// self-hoster to build an OAuth app per service first is the friction this feature removes.
    async fn ensure_auth_config(&self, slug: &str) -> Result<String, String> {
        if let Some(existing) = self.auth_config_id(slug).await {
            return Ok(existing);
        }
        let reply = self.call("POST", "/auth_configs", Some(json!({"toolkit": {"slug": slug}}))).await?;
        let id = reply
            .get("auth_config")
            .and_then(|c| c.get("id"))
            .or_else(|| reply.get("id"))
            .and_then(|v| v.as_str())
            .map(str::to_string);
        id.ok_or_else(|| format!("Composio would not create an auth config for {slug}"))
    }

    async fn connect_link(&self, slug: &str, alias: Option<&str>) -> Result<String, String> {
        let config = self.ensure_auth_config(slug).await?;
        // `allow_multiple` is what makes a second Gmail possible: without it Composio refuses the
        // second connection for the same user and auth config.
        let mut body = json!({"auth_config_id": config, "user_id": self.user, "allow_multiple": true});
        if let Some(alias) = alias {
            body["alias"] = json!(alias);
        }
        let reply = self.call("POST", "/connected_accounts/link", Some(body)).await?;
        reply
            .get("redirect_url")
            .and_then(|u| u.as_str())
            .map(str::to_string)
            .ok_or_else(|| "Composio did not return a link".to_string())
    }

    /// The API_KEY blueprint for a toolkit, created once with no credentials of ours in it.
    ///
    /// `use_custom_auth` is the only type Composio accepts here; without it the request is refused
    /// with "no managed credentials for this toolkit". The key itself is **not** part of the
    /// blueprint — it belongs to the connected account, one per owner.
    async fn key_auth_config(&self, slug: &str) -> Result<String, String> {
        let path = format!("/auth_configs?toolkit_slug={}", urlencoding::encode(slug));
        // A lookup that fails here is not fatal: the POST below may still succeed, and that is the
        // difference between "this project has no key config yet" and "Composio is unreachable".
        if let Ok(rows) = self.items(&path).await {
            for row in rows {
                let scheme = row
                    .get("auth_scheme")
                    .or_else(|| row.get("authScheme"))
                    .and_then(|s| s.as_str())
                    .unwrap_or("")
                    .to_ascii_uppercase();
                if scheme == "API_KEY" {
                    if let Some(id) = row.get("id").and_then(|v| v.as_str()) {
                        return Ok(id.to_string());
                    }
                }
            }
        }
        let reply = self
            .call(
                "POST",
                "/auth_configs",
                Some(json!({
                    "toolkit": {"slug": slug},
                    "auth_config": {
                        "type": "use_custom_auth",
                        "authScheme": "API_KEY",
                        "name": format!("hermey-{slug}"),
                        "credentials": {},
                    },
                })),
            )
            .await?;
        let created = reply.get("auth_config").unwrap_or(&reply);
        created
            .get("id")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| format!("Composio would not create a key auth config for {slug}"))
    }

    /// What the owner has to supply, as Composio defines it — never guessed here.
    ///
    /// Cloudflare wants a Global API Key *and* the account email; Vercel wants a token and an
    /// optional team id. Hard-coding that list would rot the first time a toolkit changes it.
    async fn key_fields(&self, slug: &str) -> Result<Vec<Value>, String> {
        let config = self.key_auth_config(slug).await?;
        let path = format!("/auth_configs/{}", urlencoding::encode(&config));
        let reply = self.call("GET", &path, None).await?;
        let body = reply.get("auth_config").unwrap_or(&reply);
        let fields = body
            .get("expected_input_fields")
            .and_then(|f| f.as_array())
            .map(|rows| {
                rows.iter()
                    .filter_map(|field| {
                        let name = field.get("name").and_then(|n| n.as_str()).unwrap_or("").trim();
                        if name.is_empty() {
                            return None;
                        }
                        let label = field
                            .get("displayName")
                            .and_then(|l| l.as_str())
                            .map(str::to_string)
                            .unwrap_or_else(|| name.to_string());
                        Some(json!({
                            "name": name,
                            "label": label,
                            "required": field.get("required").and_then(|r| r.as_bool()).unwrap_or(false),
                            "secret": field.get("is_secret").and_then(|s| s.as_bool()).unwrap_or(false),
                        }))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(fields)
    }

    /// Store a key with Composio as this owner's connection.
    ///
    /// The values go to Composio and nowhere else: they are not returned by the route, not written
    /// to the state directory and not put in a log line. Callers get an account id and a status,
    /// which is all the app needs to draw a connected card.
    async fn connect_with_key(
        &self,
        slug: &str,
        values: &Map<String, Value>,
    ) -> Result<(String, String), String> {
        let config = self.key_auth_config(slug).await?;
        let reply = self
            .call(
                "POST",
                "/connected_accounts",
                Some(json!({
                    "auth_config": {"id": config},
                    "user_id": self.user,
                    "connection": {"state": {"authScheme": "API_KEY", "val": values}},
                })),
            )
            .await?;
        let id = reply
            .get("id")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| format!("Composio did not create a connection for {slug}"))?;
        let status = reply.get("status").and_then(|s| s.as_str()).unwrap_or("").to_string();
        Ok((id, status))
    }
}

fn toolkit_of(row: &Value) -> String {
    let nested = row.get("toolkit").and_then(|t| t.get("slug")).and_then(|s| s.as_str());
    let flat = row.get("toolkit_slug").and_then(|s| s.as_str());
    nested.or(flat).unwrap_or("").trim().to_lowercase()
}

fn account_label(row: &Value, index: usize) -> String {
    for key in ["alias", "alias_name", "email", "account_email"] {
        if let Some(value) = row.get(key).and_then(|v| v.as_str()) {
            if !value.trim().is_empty() {
                return value.trim().to_string();
            }
        }
    }
    format!("account {}", index + 1)
}

fn account_id(row: &Value) -> Option<String> {
    row.get("id").or_else(|| row.get("nanoid")).and_then(|v| v.as_str()).map(str::to_string)
}

fn valid_slug(slug: &str) -> bool {
    CATALOG.iter().any(|(s, _, _)| *s == slug)
}

pub async fn list(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let api = composio(&st);
    Ok(Json(services(api.accounts(None).await, api.configured(), &api.user)))
}

/// The Integrations screen's payload, from one account read — or from the reason there was none.
///
/// `available` means "this host could ask", so a Composio that is unreachable or refusing the key
/// renders as unavailable with the cause in `error`, not as eight services the owner has simply not
/// connected. Everything else about the shape is unchanged, because the apps already decode it.
fn services(rows: Result<Vec<Value>, String>, configured: bool, user: &str) -> Value {
    let (all, error) = match rows {
        Ok(rows) => (rows, None),
        Err(reason) => (Vec::new(), Some(reason)),
    };
    let available = configured && error.is_none();
    let mut services = Vec::new();
    for (slug, name, blurb) in CATALOG {
        let rows: Vec<&Value> = all.iter().filter(|r| toolkit_of(r) == slug).collect();
        let accounts: Vec<Value> = rows
            .iter()
            .enumerate()
            .map(|(i, row)| json!({"id": account_id(row), "label": account_label(row, i)}))
            .collect();
        services.push(json!({
            "slug": slug,
            "name": name,
            "blurb": blurb,
            "connected": !accounts.is_empty(),
            "account_id": rows.first().and_then(|r| account_id(r)),
            "available": available,
            // The app draws the key form only for services it is told are key-based; without this
            // flag every row looked OAuth-only and Cloudflare/Vercel opened the browser flow.
            "key_based": key_based(slug),
            "accounts": accounts,
        }));
    }
    let mut body = json!({
        "configured": configured,
        "user": user,
        "services": services,
    });
    if let Some(error) = error {
        body["error"] = json!(error);
    }
    body
}

#[derive(Deserialize)]
pub struct ConnectBody {
    #[serde(default)]
    pub alias: Option<String>,
}

pub async fn connect(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(slug): Path<String>,
    body: Option<Json<ConnectBody>>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_slug(&slug) {
        return Err(bad(StatusCode::NOT_FOUND, "unknown integration"));
    }
    let alias = body
        .and_then(|Json(b)| b.alias)
        .map(|a| a.trim().chars().take(40).collect::<String>())
        .filter(|a| !a.is_empty());
    match composio(&st).connect_link(&slug, alias.as_deref()).await {
        Ok(url) => Ok(Json(json!({"url": url}))),
        Err(e) => Err(bad(StatusCode::CONFLICT, e)),
    }
}

pub async fn tools(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(slug): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_slug(&slug) {
        return Err(bad(StatusCode::NOT_FOUND, "unknown integration"));
    }
    let path = format!("/tools?toolkit_slug={}&limit=50", urlencoding::encode(&slug));
    match composio(&st).items(&path).await {
        Ok(rows) => {
            let tools: Vec<Value> = rows
                .iter()
                .filter_map(|t| {
                    let slug = t.get("slug").and_then(|s| s.as_str())?;
                    Some(json!({"slug": slug, "name": t.get("name").and_then(|n| n.as_str()).unwrap_or("")}))
                })
                .collect();
            Ok(Json(json!({ "tools": tools })))
        }
        Err(e) => Err(bad(StatusCode::CONFLICT, e)),
    }
}

#[derive(Deserialize)]
pub struct AliasBody {
    pub alias: String,
    #[serde(default)]
    pub account_id: Option<String>,
}

pub async fn set_alias(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(slug): Path<String>,
    Json(body): Json<AliasBody>,
) -> Result<StatusCode, Fail> {
    require_device(&st, &headers)?;
    if !valid_slug(&slug) {
        return Err(bad(StatusCode::NOT_FOUND, "unknown integration"));
    }
    let api = composio(&st);
    let id = match body.account_id.filter(|i| !i.trim().is_empty()) {
        Some(id) => id,
        None => {
            // A lookup that failed is not "nothing connected": say which one it was.
            let rows = api
                .accounts(Some(&slug))
                .await
                .map_err(|e| bad(StatusCode::CONFLICT, e))?;
            rows.first()
                .and_then(account_id)
                .ok_or_else(|| bad(StatusCode::CONFLICT, "nothing is connected for that service"))?
        }
    };
    let alias = body.alias.trim().chars().take(40).collect::<String>();
    if alias.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "an alias is required"));
    }
    let path = format!("/connected_accounts/{}", urlencoding::encode(&id));
    api.call("PATCH", &path, Some(json!({"alias": alias})))
        .await
        .map_err(|e| bad(StatusCode::CONFLICT, e))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct DisconnectBody {
    #[serde(default)]
    pub account_id: Option<String>,
}

pub async fn disconnect(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(slug): Path<String>,
    body: Option<Json<DisconnectBody>>,
) -> Result<StatusCode, Fail> {
    require_device(&st, &headers)?;
    if !valid_slug(&slug) {
        return Err(bad(StatusCode::NOT_FOUND, "unknown integration"));
    }
    let api = composio(&st);
    let requested = body.and_then(|Json(b)| b.account_id).filter(|i| !i.trim().is_empty());
    let id = match requested {
        Some(id) => id,
        None => {
            let rows = api
                .accounts(Some(&slug))
                .await
                .map_err(|e| bad(StatusCode::CONFLICT, e))?;
            rows.first()
                .and_then(account_id)
                .ok_or_else(|| bad(StatusCode::CONFLICT, "nothing is connected for that service"))?
        }
    };
    let path = format!("/connected_accounts/{}", urlencoding::encode(&id));
    api.call("DELETE", &path, None)
        .await
        .map_err(|e| bad(StatusCode::CONFLICT, e))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct RunBody {
    pub tool_slug: String,
    #[serde(default)]
    pub arguments: Option<Map<String, Value>>,
    #[serde(default)]
    pub account_id: Option<String>,
}

pub async fn run(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<RunBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if body.tool_slug.trim().is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a tool is required"));
    }
    let path = format!("/tools/execute/{}", urlencoding::encode(body.tool_slug.trim()));
    let mut payload = json!({
        "user_id": composio(&st).user,
        "arguments": body.arguments.unwrap_or_default(),
    });
    if let Some(account) = body.account_id {
        payload["connected_account_id"] = json!(account);
    }
    composio(&st)
        .call("POST", &path, Some(payload))
        .await
        .map(Json)
        .map_err(|e| bad(StatusCode::CONFLICT, e))
}

/// Kept for callers that resolve the key file path themselves (the bridge uses /etc/hermey).
#[allow(dead_code)]
fn key_file() -> &'static FsPath {
    FsPath::new("/etc/hermey/composio.key")
}

// ---------------------------------------------------------------------------------------------
// Key-based integrations: the services whose connection is a pasted key, not a redirect.
// ---------------------------------------------------------------------------------------------

/// Composio calls these API_KEY schemes: the owner pastes a key (and whatever secondary field the
/// toolkit wants) and there is no browser step at all. Cloudflare and Vercel are the two the bridge
/// offers this way — a toolkit whose only scheme is OAuth is not in this list, and asking for its
/// fields is a 400 rather than an empty list that would draw an empty form.
const KEY_TOOLKITS: [&str; 2] = ["cloudflare", "vercel"];

fn key_based(slug: &str) -> bool {
    KEY_TOOLKITS.contains(&slug)
}

/// `GET /v1/integrations/{slug}/key-fields` — the inputs this service needs, straight from
/// Composio's auth config. Never guessed here: a hard-coded field list rots the first time a
/// toolkit adds one.
pub async fn key_fields(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(slug): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !key_based(&slug) {
        return Err(bad(StatusCode::BAD_REQUEST, format!("{slug} is not connected with a key")));
    }
    match composio(&st).key_fields(&slug).await {
        Ok(fields) => Ok(Json(json!({"slug": slug, "fields": fields}))),
        // Composio refused, is unreachable, or this host has no project key: the app cannot draw the
        // form for a reason that is not the app's fault, and 503 says exactly that.
        Err(e) => Err(bad(StatusCode::SERVICE_UNAVAILABLE, e)),
    }
}

#[derive(Deserialize)]
pub struct KeyConnectBody {
    /// The pasted values, keyed by field name. Never echoed, logged or stored on this host.
    #[serde(default)]
    pub values: Option<Map<String, Value>>,
}

/// `POST /v1/integrations/{slug}/key-connect` — store the owner's key as their connection.
///
/// The values arrive over the device's own authenticated link, go straight to Composio, and are not
/// echoed back, logged or persisted — the same rule as a login card. Only an account id and a status
/// come out.
pub async fn key_connect(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(slug): Path<String>,
    body: Option<Json<KeyConnectBody>>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !key_based(&slug) {
        return Err(bad(StatusCode::BAD_REQUEST, format!("{slug} is not connected with a key")));
    }

    let mut values: Map<String, Value> = Map::new();
    for (key, value) in body.and_then(|Json(body)| body.values).unwrap_or_default() {
        let text = match value {
            Value::String(text) => text,
            Value::Null => String::new(),
            other => other.to_string(),
        };
        // A field the owner left blank is not a field: sending "" to Composio stores an empty
        // credential and the connected card would lie.
        if text.trim().is_empty() {
            continue;
        }
        values.insert(key, json!(text));
    }
    if values.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "values are required"));
    }

    // No values in this line, ever — the slug and the outcome are the whole diagnosis.
    match composio(&st).connect_with_key(&slug, &values).await {
        Ok((account_id, status)) => {
            eprintln!("integrations: key-connect {slug} -> connected");
            Ok(Json(json!({"ok": true, "account_id": account_id, "status": status})))
        }
        Err(e) => {
            eprintln!("integrations: key-connect {slug} -> refused");
            Err(bad(StatusCode::BAD_GATEWAY, e))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn service<'a>(body: &'a Value, slug: &str) -> &'a Value {
        body["services"]
            .as_array()
            .expect("services")
            .iter()
            .find(|s| s["slug"] == slug)
            .unwrap_or_else(|| panic!("{slug} is missing from the catalog"))
    }

    /// The bug this closes: a Composio that could not be reached answered with an empty account
    /// list, so the screen said "nothing connected" and the phone's error said "could not reach the
    /// host" — two descriptions of a fault neither of them named.
    #[test]
    fn an_unreachable_composio_is_named_not_rendered_as_nothing_connected() {
        let body = services(
            Err("Composio unreachable: connection refused".to_string()),
            true,
            "hermey-owner",
        );
        assert_eq!(body["error"], "Composio unreachable: connection refused");
        assert_eq!(body["configured"], true, "the key is still on this host");
        for row in body["services"].as_array().expect("services") {
            assert_eq!(row["available"], false, "{} still claims Composio answered", row["slug"]);
            assert_eq!(row["connected"], false);
        }
        assert_eq!(
            body["services"].as_array().expect("services").len(),
            CATALOG.len(),
            "every row is still drawn, so the screen keeps its shape"
        );
    }

    #[test]
    fn a_working_read_marks_every_service_available() {
        let body = services(Ok(Vec::new()), true, "hermey-owner");
        assert!(body.get("error").is_none(), "a successful read has nothing to report");
        for row in body["services"].as_array().expect("services") {
            assert_eq!(row["available"], true);
            assert_eq!(row["connected"], false, "nobody has connected anything yet");
        }
    }

    #[test]
    fn an_active_account_connects_only_its_own_service() {
        let rows = vec![json!({
            "id": "acc-1",
            "status": "ACTIVE",
            "alias": "work",
            "toolkit": {"slug": "gmail"},
        })];
        let body = services(Ok(rows), true, "hermey-owner");
        assert_eq!(service(&body, "gmail")["connected"], true);
        assert_eq!(service(&body, "gmail")["account_id"], "acc-1");
        assert_eq!(service(&body, "gmail")["accounts"][0]["label"], "work");
        assert_eq!(
            service(&body, "googlecalendar")["connected"],
            false,
            "one Gmail must not light up the calendar"
        );
    }

    #[test]
    fn a_keyless_host_says_so_once() {
        let body = services(Err("no Composio key on this host".to_string()), false, "hermey-owner");
        assert_eq!(body["configured"], false);
        assert_eq!(body["error"], "no Composio key on this host");
        assert_eq!(service(&body, "gmail")["available"], false);
    }
}
