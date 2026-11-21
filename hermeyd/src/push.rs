//! Banners that arrive while the app is shut: a **Bark** relay, because APNs is not ours to use.
//!
//! A sideloaded app is signed by someone else's team, so this host holds no APNs key and cannot
//! notify a phone directly. The delivery goes through Bark — an App Store client plus a server the
//! owner runs — which already holds such a key. Registering a device stores the URL the Bark app
//! shows (`http://host:port/<KEY>`); POSTing a small JSON body to it makes a real banner appear.
//!
//! Shapes mirror production (`hermes_bridge/push.py`) so both hosts behave the same:
//!
//!   POST /v1/push/register  {"url": "http://…/KEY"}    this device's relay, split server/key
//!   POST /v1/push/presence  {"bot": "<profile>"|null}  what this device is looking at
//!   POST /v1/push/test                                 one banner, now, with the true verdict
//!
//! ## Where delivery is hooked, and why not the relay
//!
//! Production reads each bot's conversation on a timer. This service does the same: a background
//! watcher ([`spawn_watcher`]) opens each profile's `state.db` read-only every [`WATCH_SECONDS`] —
//! the same query the bot list's previews use — and announces what is new.
//!
//! The WS relay (`relay.rs`) was the other candidate and it is the wrong hook. It only exists while
//! a device holds a socket, which is exactly when a banner is pointless; and an engine event names
//! a *session* (`session_id`), not the profile that owns it, so the relay could not say which bot
//! spoke without a guess. The watcher names the profile by construction, runs when no app is open,
//! and touches nothing but a read-only SQLite handle.
//!
//! ## The guard
//!
//! `push_watch.last_at` is the newest message already considered for a bot. It does three jobs: a
//! restart does not re-announce yesterday, an older message never fires after a newer one, and a
//! chatty bot is throttled to at most one banner per [`MIN_PUSH_SECONDS`] — the skipped message is
//! consumed (the mark moves) rather than queued, so a stale banner can never arrive late.

use crate::routes::{require_device, AppState};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

/// How often the host looks for new replies. Ten seconds is the point where a banner still feels
/// like a reaction; a tick with nothing new writes nothing.
pub const WATCH_SECONDS: f64 = 10.0;

/// At most one banner per bot per this many seconds of *message time*. A bot that writes five
/// things in a row is one thing happening, not five.
pub const MIN_PUSH_SECONDS: f64 = 30.0;

/// How long a device's "I am reading this bot" claim is believed. The app clears it when it goes to
/// the background, but a phone that sleeps mid-chat cannot send anything — and a stale claim would
/// silence that bot forever.
const PRESENCE_SECONDS: f64 = 120.0;

/// A banner body is a notification, not a message.
const MAX_BODY_CHARS: usize = 140;
const MAX_TITLE_CHARS: usize = 120;

/// Bark accepts a whole notification as JSON; a URL bigger than this is a mistake, not a note.
const MAX_URL_CHARS: usize = 512;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, detail: impl Into<String>) -> Fail {
    (status, Json(json!({ "detail": detail.into() })))
}

// ---- the relay address ---------------------------------------------------------------

/// `http://host:port/KEY` → (`http://host:port`, `KEY`). Anything else is refused.
///
/// Parsed rather than split on the last slash: `rpartition` accepts `http://host/` as server
/// `http:/` and key `host`, which makes a typo look like a working registration. The key is the
/// *first* path segment, because Bark's own "copy URL" button can hand back the prefilled example
/// (`/KEY/title/body`) and taking the last one there registered `body` as the key.
pub fn split_bark_url(raw: &str) -> Result<(String, String), String> {
    let url = raw.trim();
    if url.is_empty() || url.len() > MAX_URL_CHARS {
        return Err("a Bark URL is required".to_string());
    }
    let (scheme, rest) = match url.split_once("://") {
        Some((scheme, rest)) => (scheme.to_ascii_lowercase(), rest),
        None => return Err("a Bark URL starts with http:// or https://".to_string()),
    };
    if scheme != "http" && scheme != "https" {
        return Err("a Bark URL starts with http:// or https://".to_string());
    }
    let (netloc, path) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, ""),
    };
    if netloc.is_empty() || netloc.contains(' ') || netloc.contains('@') {
        return Err("a Bark URL needs a server, e.g. http://host:8080/AbCdEf".to_string());
    }
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    let Some(key) = segments.first() else {
        return Err("a Bark URL ends in the device key, e.g. http://host:8080/AbCdEf".to_string());
    };
    if key.is_empty()
        || key.len() > 128
        || !key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("a Bark URL ends in the device key, e.g. http://host:8080/AbCdEf".to_string());
    }
    Ok((format!("{scheme}://{netloc}"), (*key).to_string()))
}

/// The endpoint without its scheme, for a log line: the key is never part of this, and neither is
/// anything a reader could POST with.
fn endpoint_host(endpoint: &str) -> String {
    endpoint.split_once("://").map(|(_, rest)| rest).unwrap_or(endpoint).to_string()
}

// ---- the relay client ----------------------------------------------------------------

fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            // A registered endpoint is a URL a device typed; it does not get to forward this host.
            // Following a 30x would replay the POST — body included — into whatever it names.
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(8))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new())
    })
}

/// `icon` must be a URL the *phone* can fetch; empty means "no image", not a broken one.
#[allow(clippy::too_many_arguments)]
async fn send(
    endpoint: &str,
    key: &str,
    title: &str,
    body: &str,
    group: &str,
    url: &str,
    icon: &str,
) -> Result<(), String> {
    let mut payload = json!({
        "title": clip(title, MAX_TITLE_CHARS),
        "body": clip(body, MAX_BODY_CHARS),
        // A bot's reply is the reason the phone is buzzing; a Focus mode may still hold it back.
        "level": "timeSensitive",
    });
    if !group.is_empty() {
        payload["group"] = json!(group);
    }
    if !url.is_empty() {
        payload["url"] = json!(url);
    }
    if !icon.is_empty() {
        payload["icon"] = json!(icon);
    }

    let target = format!("{}/{}", endpoint.trim_end_matches('/'), key);
    let response = client()
        .post(target)
        .header("content-type", "application/json")
        .body(payload.to_string())
        .send()
        .await
        // Never carry the request URL into a message: it ends in the key. Classify instead.
        .map_err(|e| {
            if e.is_timeout() {
                "the relay timed out".to_string()
            } else if e.is_connect() {
                "could not reach the relay".to_string()
            } else {
                "the relay request failed".to_string()
            }
        })?;
    if response.status().is_success() {
        Ok(())
    } else {
        Err(format!("the relay refused the banner (HTTP {})", response.status().as_u16()))
    }
}

// ---- routes --------------------------------------------------------------------------

/// `POST /v1/push/register` — `{"url": "http://host:port/KEY"}`.
///
/// The app sends the whole URL the Bark client shows and a person can paste; the split happens
/// here. Replacing an existing target for the same device is an update, not a second row.
pub async fn register(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let raw = body.get("url").and_then(|v| v.as_str()).unwrap_or("");
    let (endpoint, key) = split_bark_url(raw).map_err(|d| bad(StatusCode::UNPROCESSABLE_ENTITY, d))?;
    st.store.set_push_target(&device, "bark", &endpoint, &key);
    eprintln!(
        "push/register: device {} provider=bark endpoint={} key_len={}",
        short(&device),
        endpoint_host(&endpoint),
        key.len()
    );
    Ok(Json(json!({
        "ok": true,
        "device": device,
        "provider": "bark",
        "endpoint": endpoint,
    })))
}

/// `POST /v1/push/presence` — `{"bot": "<profile>"|null}`. Stamped, not just stored.
pub async fn presence(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let bot = body
        .get("bot")
        .and_then(|v| v.as_str())
        .filter(|name| crate::parity_gaps::valid_profile(name))
        .map(|name| name.to_string());
    st.store.set_push_presence(&device, bot.as_deref());
    Ok(Json(json!({ "ok": true, "device": device, "bot": bot })))
}

/// `POST /v1/push/test` — one banner to the calling device's relay, and what really happened.
///
/// No target is a 404 (the app has nothing to test); a relay that refuses is a 200 with
/// `delivered:false` and a reason, because "the relay said no" is an answer the app can show.
pub async fn test(State(st): State<Arc<AppState>>, headers: HeaderMap) -> Result<Json<Value>, Fail> {
    let device = require_device(&st, &headers)?;
    let target = st
        .store
        .push_target(&device)
        .ok_or_else(|| bad(StatusCode::NOT_FOUND, "no relay registered for this device"))?;

    match send(
        &target.endpoint,
        &target.key,
        "Hermey",
        "Notifications are working.",
        "hermey",
        "hermey://bot",
        "",
    )
    .await
    {
        Ok(()) => {
            eprintln!("push/test: device {} delivered to host {}", short(&device), endpoint_host(&target.endpoint));
            Ok(Json(json!({ "ok": true, "delivered": true })))
        }
        Err(reason) => {
            eprintln!("push/test: device {} NOT delivered: {reason}", short(&device));
            Ok(Json(json!({ "ok": true, "delivered": false, "reason": reason })))
        }
    }
}

// ---- delivery on activity --------------------------------------------------------------

/// One banner for one bot's newest message, if the guards allow it.
///
/// `at` is the message's own timestamp; `st.watch.last_at` is the previous one. Order of the guards
/// matters: a repeated or older message costs nothing, a throttled one is consumed silently, a
/// reply to the owner's own prompt is not news, and only then is a request made.
pub async fn announce(st: &AppState, profile: &str, text: &str, at: f64) {
    if let Some(previous) = st.store.push_watch(profile) {
        if at <= previous {
            return;
        }
        if at - previous < MIN_PUSH_SECONDS {
            // Still move the mark: the message is *considered*, so it cannot surface as a late
            // banner once the interval has passed.
            st.store.set_push_watch(profile, at);
            eprintln!("push: {profile} throttled ({}s since the last banner)", (at - previous) as i64);
            return;
        }
    }

    // A reply to something the owner just asked is not news — they are watching for it.
    if let Some((_at, source)) = st.store.push_prompt(profile) {
        if source == "human" {
            st.store.set_push_watch(profile, at);
            return;
        }
    }

    let targets = st.store.push_targets();
    if targets.is_empty() {
        st.store.set_push_watch(profile, at);
        return;
    }

    let body = plain(text);
    if body.is_empty() {
        st.store.set_push_watch(profile, at);
        return;
    }
    let icon = icon_url(st, profile);
    let title = capitalize(profile);
    let url = format!("hermey://bot/{profile}");
    let now = crate::pairing::now();

    let mut delivered = 0usize;
    let mut considered = 0usize;
    for target in &targets {
        // The bot this device is reading is not news to it — while that claim is fresh.
        if target.preset_bot.as_deref() == Some(profile)
            && now - target.updated_at < PRESENCE_SECONDS
        {
            continue;
        }
        considered += 1;
        match send(&target.endpoint, &target.key, &title, &body, profile, &url, &icon).await {
            Ok(()) => delivered += 1,
            Err(reason) => eprintln!(
                "push: {profile} relay {} for device {} refused: {reason}",
                target.provider,
                short(&target.device_id)
            ),
        }
    }
    st.store.set_push_watch(profile, at);
    eprintln!("push: {profile} delivered={delivered}/{considered}");
}

/// The bot's own face, when the host has a public name and the app uploaded one. Empty means no
/// image: a registered relay fetches the picture itself, so a host with no public base has nothing
/// it could hand over.
fn icon_url(st: &AppState, profile: &str) -> String {
    let base = match std::env::var("HERMEY_PUSH_ICON_BASE") {
        Ok(value) if !value.trim().is_empty() => value.trim().trim_end_matches('/').to_string(),
        _ => {
            let host = st.public_host.trim().trim_end_matches('/');
            if host.is_empty() || host == "localhost" {
                return String::new();
            }
            format!("https://{host}/v1/push/icon")
        }
    };
    let path = crate::parity_gaps::icon_dir(st).join(format!("{profile}.png"));
    if path.is_file() {
        format!("{base}/{profile}.png")
    } else {
        String::new()
    }
}

// ---- the watcher ------------------------------------------------------------------------

/// Start the reply watcher. One pass records what already exists, so an install with a year of
/// history does not fire a hundred banners on the first tick.
pub fn spawn_watcher(st: Arc<AppState>) {
    tokio::spawn(async move {
        let mut primed = false;
        let mut ticker = tokio::time::interval(Duration::from_secs_f64(WATCH_SECONDS));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            // `None` means no relay is registered: stay unprimed, so the first pass that has a
            // target records watermarks instead of announcing a year of history.
            if sweep(&st, primed).await.is_some() {
                primed = true;
            }
        }
    });
}

/// One pass. `None` means "no relay registered yet, stay unprimed" — the first pass with targets
/// records the watermarks instead of announcing them.
async fn sweep(st: &AppState, primed: bool) -> Option<()> {
    if st.store.push_targets().is_empty() {
        return None;
    }
    for profile in profile_dirs(st) {
        let db = st
            .engine_home
            .join("profiles")
            .join(&profile)
            .join("state.db");
        if !db.is_file() {
            continue;
        }
        let Some((text, at)) = newest_reply(&db, st.store.get_bot_session(&profile)) else {
            continue;
        };
        if !primed {
            st.store.set_push_watch(&profile, at);
            continue;
        }
        announce(st, &profile, &text, at).await;
    }
    Some(())
}

fn profile_dirs(st: &AppState) -> Vec<String> {
    let root = st.engine_home.join("profiles");
    let mut names: Vec<String> = std::fs::read_dir(&root)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.path().is_dir())
                .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|name| crate::parity_gaps::valid_profile(name))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// The newest assistant message of the conversation the app opens: the shared pointer when there
/// is one, else the newest reply in the profile. Read-only, bounded, best-effort — a locked or
/// missing database loses this bot's banner and nothing else.
fn newest_reply(db: &std::path::Path, pointer: Option<String>) -> Option<(String, f64)> {
    let conn = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    let _ = conn.busy_timeout(Duration::from_millis(400));
    let query = |session: Option<&str>| -> Option<(String, f64)> {
        let sql = if session.is_some() {
            "SELECT content, timestamp FROM messages WHERE session_id = ?1 AND role = 'assistant' \
             AND content IS NOT NULL AND length(trim(content)) > 0 \
             AND upper(trim(content)) NOT IN ('[SILENT]', 'NO_REPLY') \
             ORDER BY timestamp DESC, id DESC LIMIT 1"
        } else {
            "SELECT content, timestamp FROM messages WHERE role = 'assistant' \
             AND content IS NOT NULL AND length(trim(content)) > 0 \
             AND upper(trim(content)) NOT IN ('[SILENT]', 'NO_REPLY') \
             ORDER BY timestamp DESC, id DESC LIMIT 1"
        };
        let mut stmt = conn.prepare(sql).ok()?;
        let mut rows = match session {
            Some(id) => stmt.query([id]).ok()?,
            None => stmt.query([]).ok()?,
        };
        let row = rows.next().ok().flatten()?;
        let content: String = row.get(0).ok()?;
        let at: f64 = row.get(1).ok()?;
        Some((content, at))
    };
    if pointer.is_some() {
        if let Some(found) = query(pointer.as_deref()) {
            return Some(found);
        }
    }
    query(None)
}

// ---- text -----------------------------------------------------------------------------

fn clip(text: &str, limit: usize) -> String {
    let clipped: String = text.chars().take(limit).collect();
    clipped
}

/// The first line of a reply, without the markdown that would show up as literal stars.
fn plain(raw: &str) -> String {
    for raw_line in raw.lines() {
        let mut line: &str = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let stripped = strip_marks(line);
        line = stripped.as_str();
        line = line.trim_start_matches(['#', '>', '-', '*', '+']).trim();
        if !line.is_empty() {
            return clip(line, MAX_BODY_CHARS);
        }
    }
    String::new()
}

/// Drop the markdown that would show up literally in a one-line banner.
fn strip_marks(line: &str) -> String {
    let mut out = line.to_string();
    for mark in ["**", "__", "`"] {
        while let Some(at) = out.find(mark) {
            out.replace_range(at..at + mark.len(), "");
        }
    }
    out
}

fn capitalize(profile: &str) -> String {
    let mut chars = profile.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// A device id in a log line: enough to correlate, not the whole identifier.
fn short(value: &str) -> String {
    if value.len() > 8 {
        format!("{}…", &value[..8])
    } else {
        value.to_string()
    }
}

// ---- tests ----------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bark_urls_split_into_server_and_key() {
        assert_eq!(
            split_bark_url("http://100.86.19.1:8081/AbCdEf123").unwrap(),
            ("http://100.86.19.1:8081".to_string(), "AbCdEf123".to_string())
        );
        assert_eq!(
            split_bark_url("https://bark.example.com/K-1_x").unwrap(),
            ("https://bark.example.com".to_string(), "K-1_x".to_string())
        );
        // The prefilled example Bark's copy button can return: the key is the FIRST segment.
        assert_eq!(
            split_bark_url("http://h:8080/KEY/title/body").unwrap().1,
            "KEY".to_string()
        );
    }

    #[test]
    fn a_typo_is_refused_rather_than_half_registered() {
        assert!(split_bark_url("").is_err());
        assert!(split_bark_url("http://host/").is_err());
        assert!(split_bark_url("http://host").is_err());
        assert!(split_bark_url("ftp://host/KEY").is_err());
        assert!(split_bark_url("host:8080/KEY").is_err());
        assert!(split_bark_url(&format!("http://h/{}", "k".repeat(200))).is_err());
    }

    #[test]
    fn the_first_line_is_plain_text() {
        assert_eq!(plain("## **Done**\nrest"), "Done");
        assert_eq!(plain("\n\n  `code` and text  \nmore"), "code and text");
        assert_eq!(plain("   "), "");
        assert_eq!(plain(&"x".repeat(400)).chars().count(), MAX_BODY_CHARS);
    }
}
