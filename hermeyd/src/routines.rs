//! A bot's schedules ("routines"). The engine owns cron, so this is a translator over `cron.manage`:
//! list / add / pause / resume, one profile at a time.
//!
//! The prompt is deliberately **not** returned: a routine's prompt is the bot's own instructions —
//! long and often private — and a list of *when this bot runs* never needs it.

use crate::engine_client::rpc;
use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

fn valid_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 64
        && profile.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// One engine job → the shape the app's `BotRoutine` decoder expects.
fn routine_row(job: &Value) -> Value {
    let state = job.get("state").and_then(|s| s.as_str()).unwrap_or("");
    let enabled = job.get("enabled").and_then(|e| e.as_bool()).unwrap_or(true);
    let paused = !enabled || state == "paused";
    let completed = state == "completed";
    json!({
        "id": job.get("job_id"),
        "name": job.get("name"),
        "schedule": job.get("schedule"),
        "next_run_at": job.get("next_run_at"),
        "last_run_at": job.get("last_run_at"),
        "last_status": job.get("last_status"),
        "last_error": job.get("last_error").or_else(|| job.get("last_fire_error")),
        "paused": paused,
        "completed": completed,
    })
}

pub async fn list_routines(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    let result = rpc(
        &st.engine_ws,
        st.engine_token(),
        "cron.manage",
        // `include_disabled` matters: without it the engine omits paused jobs, so a routine the owner
        // just paused would disappear from the list instead of showing as "Paused" and staying
        // resumable. Measured behaviour, not a guess.
        json!({"action": "list", "profile": profile, "include_disabled": true}),
    )
    .await
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;

    let empty = vec![];
    let mut rows: Vec<Value> = result
        .get("jobs")
        .and_then(|j| j.as_array())
        .unwrap_or(&empty)
        .iter()
        .map(routine_row)
        .collect();
    // Soonest first, as the sheet says; an unscheduled row sorts last rather than first.
    rows.sort_by(|a, b| {
        let key = |v: &Value| v.get("next_run_at").and_then(|x| x.as_str()).unwrap_or("9999").to_string();
        key(a).cmp(&key(b))
    });
    // The client decodes {"routines": [...]} — BotRoutine.decodeList casts object["routines"], so a
    // bare array made every bot look like it had no schedules while the host held 35.
    Ok(Json(json!({"routines": rows})))
}

#[derive(Deserialize)]
pub struct RoutineCreate {
    #[serde(default)]
    pub name: Option<String>,
    pub schedule: String,
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default)]
    pub repeat: Option<Value>,
    #[serde(default)]
    pub deliver: Option<String>,
    /// The New Routine form's own fields. They are accepted so the draft is not silently dropped;
    /// only a prompt can be scheduled here, so a draft without one is answered 422 below rather
    /// than turned into a job that fires and does nothing.
    #[serde(default)]
    pub skills: Option<Vec<String>>,
    #[serde(default)]
    pub script: Option<String>,
    #[serde(default)]
    pub paused: Option<bool>,
}

pub async fn create_routine(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Json(body): Json<RoutineCreate>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    let schedule = body.schedule.trim().to_string();
    if schedule.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "a schedule is required"));
    }

    // The form allows a prompt, a skill or a script; only the prompt can be scheduled here (cron
    // runs a prompt, it has no skill or script step). Say so plainly instead of creating a job
    // that fires and does nothing.
    let prompt = body.prompt.unwrap_or_default();
    let has_skill = body
        .skills
        .as_ref()
        .map(|s| s.iter().any(|n| !n.trim().is_empty()))
        .unwrap_or(false);
    let has_script = body.script.as_deref().map(|s| !s.trim().is_empty()).unwrap_or(false);
    if prompt.trim().is_empty() && (has_skill || has_script) {
        return Err(bad(
            StatusCode::UNPROCESSABLE_ENTITY,
            "this host can only schedule a prompt: write what the bot should do, and it runs on this schedule",
        ));
    }
    let name = body
        .name
        .map(|n| n.trim().to_string())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| {
            let mut n = schedule.clone();
            n.truncate(48);
            n
        });

    let job_name = name.clone();
    let mut params = json!({
        "action": "add",
        "name": name,
        "schedule": schedule,
        "prompt": prompt,
        "profile": profile,
    });
    if let Some(deliver) = body.deliver {
        params["deliver"] = json!(deliver);
    }
    if let Some(repeat) = body.repeat {
        if let Some(n) = repeat.as_i64() {
            params["repeat"] = json!(n);
        }
    }

    let result = rpc(&st.engine_ws, st.engine_token(), "cron.manage", params)
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;

    if result.get("success").and_then(|s| s.as_bool()) == Some(false) {
        let reason = result
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("the engine refused to create the routine");
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, reason));
    }

    // The engine's add answer carries the job fields; fall back to a list read if it does not.
    let job = result.get("job").cloned().unwrap_or_else(|| result.clone());
    let mut row = routine_row(&job);
    if row.get("id").map(|v| v.is_null()).unwrap_or(true) {
        row["id"] = job.get("job_id").cloned().unwrap_or(Value::Null);
    }
    // "Start paused" is applied after the create, so the row handed back already says Paused and
    // the job cannot fire between the two calls.
    if body.paused.unwrap_or(false) {
        let job_id = row
            .get("id")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| job_name.clone());
        if !job_id.is_empty() {
            let answer = rpc(
                &st.engine_ws,
                st.engine_token(),
                "cron.manage",
                json!({ "action": "pause", "name": job_id, "profile": profile }),
            )
            .await;
            if let Ok(answer) = answer {
                if answer.get("success").and_then(|s| s.as_bool()) != Some(false) {
                    row["paused"] = json!(true);
                }
            }
        }
    }
    // The app's `BotRoutine.decodeOne` reads `object["routine"]`, so a bare row decoded `nil` and a
    // created routine looked like a failed create. The production bridge answers `{"routine": {...}}`
    // for the same reason.
    Ok(Json(json!({ "routine": row })))
}

#[derive(Deserialize)]
pub struct RoutineState {
    pub paused: bool,
}

pub async fn set_routine_state(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((profile, job_id)): Path<(String, String)>,
    Json(body): Json<RoutineState>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) || job_id.is_empty() || job_id.len() > 128 {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid job id"));
    }
    let action = if body.paused { "pause" } else { "resume" };
    let result = rpc(
        &st.engine_ws,
        st.engine_token(),
        "cron.manage",
        json!({"action": action, "name": job_id, "profile": profile}),
    )
    .await
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    if result.get("success").and_then(|s| s.as_bool()) == Some(false) {
        let reason = result.get("error").and_then(|e| e.as_str()).unwrap_or("the engine refused");
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, reason));
    }
    Ok(Json(json!({"id": job_id, "paused": body.paused})))
}

/// `DELETE /v1/bots/{profile}/routines/{job_id}` — remove the schedule from the engine.
///
/// Without this the app could create and pause a routine but never be rid of it: the bridge simply
/// had no route, so the delete answered 404. `cron.manage` calls the engine's remove with the job id
/// in `name` (that gateway reads `params["name"]` for pause/resume/remove alike), and the profile
/// scoping is the same as the list route, so a removal can only reach this bot's cron store.
pub async fn delete_routine(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path((profile, job_id)): Path<(String, String)>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) || job_id.is_empty() || job_id.len() > 128 {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid job id"));
    }
    let result = rpc(
        &st.engine_ws,
        st.engine_token(),
        "cron.manage",
        json!({"action": "remove", "name": job_id, "profile": profile}),
    )
    .await
    .map_err(|e| bad(StatusCode::BAD_GATEWAY, e))?;
    // An engine that refused (unknown id, unreadable store) still answers 200 over the socket with
    // `success: false`; a truthful status matters here because a 200 would let the app drop the row
    // while the job kept firing.
    if result.get("success").and_then(|s| s.as_bool()) == Some(false) {
        let reason = result
            .get("error")
            .and_then(|e| e.as_str())
            .unwrap_or("the engine refused to remove the routine");
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, reason));
    }
    // The app ignores the body on a delete; the id is returned so a caller can confirm which row went.
    Ok(Json(json!({"profile": profile, "id": job_id, "deleted": true})))
}
