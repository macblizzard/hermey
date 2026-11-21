//! Rooms (group chats). The engine hosts them: `groups.create/list/log/send/rename/disband` own the
//! log and route to members, so this module is a translator — exactly the production bridge's job.
//!
//! Shapes mirror `Bridge/hermes_bridge/rooms.py` field-for-field, because the app's decoders were
//! written against that.

use crate::auth::random_token;
use crate::engine_client::rpc;
use crate::routes::{require_device, AppState};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);
const MIN_MEMBERS: usize = 2;
const MAX_MEMBERS: usize = 6;

#[derive(Deserialize)]
pub struct LogQuery {
    pub since_seq: Option<i64>,
}

#[derive(Deserialize)]
pub struct CreateBody {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub members: Vec<MemberIn>,
}

#[derive(Deserialize)]
pub struct MemberIn {
    pub profile: String,
}

#[derive(Deserialize)]
pub struct SendBody {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub event_id: Option<String>,
}

#[derive(Deserialize)]
pub struct RenameBody {
    #[serde(default)]
    pub name: String,
}

fn engine_token(st: &AppState) -> Option<String> {
    std::fs::read_to_string(&st.engine_token_file).ok().map(|s| s.trim().to_string())
}

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// `_actor_label` in the bridge: the transcript shows a handle without its leading '@'.
fn actor_label(actor: &Value) -> Option<String> {
    let kind = actor.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    if kind == "user" {
        return None;
    }
    actor
        .get("display_name")
        .and_then(|v| v.as_str())
        .or_else(|| actor.get("profile").and_then(|v| v.as_str()))
        .or_else(|| actor.get("handle").and_then(|v| v.as_str()))
        .map(|s| s.trim_start_matches('@').to_string())
}

fn slug(name: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in name.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
            last_dash = false;
        } else if !last_dash && !out.is_empty() {
            out.push('-');
            last_dash = true;
        }
        if out.len() >= 40 {
            break;
        }
    }
    let trimmed = out.trim_matches('-').to_string();
    if trimmed.is_empty() { "room".to_string() } else { trimmed }
}

/// Last speaker/text/at, read from the room's own log (a turn marker bumps the room without anybody
/// speaking, so `updated_at` cannot answer this).
async fn last_spoken(st: &AppState, room: &Value) -> Value {
    let room_id = match room.get("room_id").and_then(|v| v.as_str()) {
        Some(id) if !id.is_empty() => id.to_string(),
        _ => return json!({}),
    };
    let latest = room.get("latest_seq").and_then(|v| v.as_i64()).unwrap_or(0);
    if latest == 0 {
        return json!({});
    }
    let params = json!({"room_id": room_id, "since_seq": (latest - 8).max(0), "limit": 20});
    let result = match rpc(&st.engine_ws, engine_token(st), "groups.log", params).await {
        Ok(v) => v,
        Err(_) => return json!({}),
    };
    let last = result
        .get("events")
        .and_then(|e| e.as_array())
        .and_then(|events| {
            events
                .iter()
                .filter(|e| {
                    let kind = e.get("kind").and_then(|k| k.as_str()).unwrap_or("");
                    let text = e
                        .get("payload")
                        .and_then(|p| p.get("text"))
                        .and_then(|t| t.as_str())
                        .unwrap_or("");
                    (kind == "message.user" || kind == "message.member") && !text.trim().is_empty()
                })
                .next_back()
        });
    match last {
        Some(event) => {
            let actor = event.get("actor").cloned().unwrap_or(json!({}));
            json!({
                "last_speaker": actor_label(&actor),
                "last_from_owner": actor.get("kind").and_then(|k| k.as_str()) == Some("user"),
                "last_text": event.get("payload").and_then(|p| p.get("text")).and_then(|t| t.as_str()).unwrap_or(""),
                "last_at": event.get("created_at"),
            })
        }
        None => json!({}),
    }
}

fn room_row(room: &Value) -> Value {
    let members: Vec<Value> = room
        .get("members")
        .and_then(|m| m.as_array())
        .map(|arr| {
            arr.iter()
                .map(|m| {
                    let profile = m.get("profile").and_then(|v| v.as_str()).unwrap_or("");
                    json!({
                        "profile": profile,
                        "handle": m.get("handle").and_then(|v| v.as_str()).unwrap_or(profile),
                        "display_name": m.get("display_name").and_then(|v| v.as_str()).unwrap_or(profile),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    json!({
        "room_id": room.get("room_id"),
        "name": room.get("name").and_then(|v| v.as_str()).or_else(|| room.get("room_id").and_then(|v| v.as_str())),
        "members": members,
        "updated_at": room.get("updated_at"),
        "latest_seq": room.get("latest_seq"),
        "disbanded_at": room.get("disbanded_at"),
    })
}

pub async fn list_rooms(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let result = rpc(&st.engine_ws, engine_token(&st), "groups.list", json!({"limit": 50}))
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    let empty = vec![];
    let rooms = result.get("rooms").and_then(|r| r.as_array()).unwrap_or(&empty);
    let mut out = Vec::with_capacity(rooms.len());
    for room in rooms {
        let mut row = room_row(room);
        if let (Some(row_obj), Value::Object(extra)) = (row.as_object_mut(), last_spoken(&st, room).await) {
            for (k, v) in extra {
                row_obj.insert(k, v);
            }
        }
        out.push(row);
    }
    Ok(Json(json!({"rooms": out})))
}

pub async fn create_room(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<CreateBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if body.members.len() < MIN_MEMBERS || body.members.len() > MAX_MEMBERS {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("a group chat has {MIN_MEMBERS}-{MAX_MEMBERS} bots"),
        ));
    }
    let name = if body.name.trim().is_empty() { "Group chat".to_string() } else { body.name.trim().to_string() };
    if name.chars().count() > 80 {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "name is too long"));
    }
    let mut seen = std::collections::HashSet::new();
    let mut members = Vec::new();
    for m in &body.members {
        if !seen.insert(m.profile.clone()) {
            return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a bot is in the list twice"));
        }
        // `member_id` is required by the engine (code 5111 without it); the bridge uses the profile
        // name as the member id, and the handle without a leading '@'.
        members.push(json!({
            "member_id": m.profile,
            "profile": m.profile,
            "handle": m.profile,
            "display_name": m.profile,
        }));
    }

    // Room id is derived from the name and made unique: `groups.create` is idempotent on room_id, so
    // a collision would silently reopen the older room.
    let suffix: String = random_token(6)
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(8)
        .collect::<String>()
        .to_lowercase();
    let room_id = format!("{}-{}", slug(&name), if suffix.is_empty() { "id".to_string() } else { suffix });
    let result = rpc(
        &st.engine_ws,
        engine_token(&st),
        "groups.create",
        json!({"room_id": room_id, "name": name, "members": members}),
    )
    .await
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;

    let room = result.get("room").cloned().unwrap_or(json!({}));
    Ok(Json(json!({"room": {
        "room_id": room.get("room_id").and_then(|v| v.as_str()).unwrap_or(&room_id),
        "name": room.get("name").and_then(|v| v.as_str()).unwrap_or(&name),
        "members": members,
    }})))
}

pub async fn room_log(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(room_id): Path<String>,
    Query(q): Query<LogQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let mut params = json!({"room_id": room_id, "limit": 200});
    if let Some(since) = q.since_seq {
        params["since_seq"] = json!(since);
    }
    let result = rpc(&st.engine_ws, engine_token(&st), "groups.log", params)
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    let latest = result
        .get("latest_seq")
        .or_else(|| result.get("cursor"))
        .and_then(|v| v.as_i64())
        .unwrap_or(0);
    let events = result.get("events").cloned().unwrap_or(json!([]));
    // One log row reduced to what a chat window draws. `turn.*` and `room.*` rows are the driver's
    // bookkeeping — a transcript showing "ops turn cancelled" would read like something Ops said.
    let views: Vec<Value> = events
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|event| {
                    let kind = event.get("kind").and_then(|k| k.as_str()).unwrap_or("");
                    if kind.starts_with("turn.") || kind.starts_with("room.") {
                        return None;
                    }
                    let payload = event.get("payload").cloned().unwrap_or(json!({}));
                    let actor = event.get("actor").cloned().unwrap_or(json!({}));
                    let label = actor
                        .get("display_name")
                        .and_then(|v| v.as_str())
                        .or_else(|| actor.get("profile").and_then(|v| v.as_str()))
                        .or_else(|| actor.get("handle").and_then(|v| v.as_str()))
                        .map(|s| s.trim_start_matches('@').to_string())
                        .or_else(|| actor_label(&actor));
                    Some(json!({
                        "seq": event.get("seq"),
                        "event_id": event.get("event_id"),
                        "kind": kind,
                        "actor": {
                            "kind": actor.get("kind"),
                            "id": actor.get("id"),
                            "profile": actor.get("profile"),
                            "label": label,
                        },
                        "text": payload.get("text").and_then(|t| t.as_str()).unwrap_or(""),
                        "in_reply_to": payload.get("discussion_event_id"),
                        "at": event.get("created_at"),
                    }))
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Json(json!({"events": views, "latest_seq": latest})))
}

pub async fn send_room(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(room_id): Path<String>,
    Json(body): Json<SendBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let text = body.text.trim().to_string();
    if text.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "text is required"));
    }
    let event_id = body
        .event_id
        .filter(|e| !e.trim().is_empty())
        .unwrap_or_else(|| format!("app-{}", random_token(8)));
    let result = rpc(
        &st.engine_ws,
        engine_token(&st),
        "groups.send",
        json!({"room_id": room_id, "event_id": event_id, "payload": {"thread_id": "main", "text": text}}),
    )
    .await
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(json!({
        "event": result.get("event").cloned().unwrap_or(json!({})),
        "event_id": result.get("client_event_id").and_then(|v| v.as_str()).unwrap_or(&event_id),
        "at": crate::pairing::now(),
    })))
}

pub async fn rename_room(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(room_id): Path<String>,
    Json(body): Json<RenameBody>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let name = body.name.trim().to_string();
    if name.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a name is required"));
    }
    if name.chars().count() > 80 {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "name is too long"));
    }
    // `groups.rename` writes an event, and the gateway requires an event_id for it.
    rpc(
        &st.engine_ws,
        engine_token(&st),
        "groups.rename",
        json!({"room_id": room_id, "name": name, "event_id": format!("rename-{}", random_token(8))}),
    )
    .await
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(json!({"room_id": room_id, "name": name})))
}

pub async fn disband_room(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(room_id): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    rpc(
        &st.engine_ws,
        engine_token(&st),
        "groups.disband",
        json!({"room_id": room_id, "event_id": format!("disband-{}", random_token(8))}),
    )
    .await
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    Ok(Json(json!({"room_id": room_id, "disbanded": true})))
}
