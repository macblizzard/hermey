//! The provider surface: what the host can run, and which provider+model a bot is pinned to.
//!
//! Everything here is derived from the engine's own `model.options` inventory — never from a key
//! value. A provider row carries no secret and no base URL: the app asks "can this run, and with
//! what", and the host answers from the engine's credential *state*.
//!
//! Sign-in is deliberately absent: keys are added on the host with `hermes auth add|refresh|status`.
//! A client can pick among what is already authenticated, and is told plainly when a provider is
//! known but has no credential (`provider_not_authenticated`) rather than being shown an empty list.

use crate::engine_client::{rpc_strict, EngineError};
use crate::routes::{require_device, AppState};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// A refusal a UI must be able to tell apart. `detail` keeps the production bridge's key, `error`
/// is the stable machine code the app switches on.
fn refuse(status: StatusCode, code: &str, msg: impl Into<String>, mut extra: Value) -> Fail {
    if let Some(obj) = extra.as_object_mut() {
        obj.insert("error".into(), json!(code));
        obj.insert("detail".into(), json!(msg.into()));
    }
    (status, Json(extra))
}

fn engine_token(st: &AppState) -> Option<String> {
    std::fs::read_to_string(&st.engine_token_file).ok().map(|s| s.trim().to_string())
}

fn valid_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 64
        && profile.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

async fn engine_call(st: &AppState, method: &str, params: Value) -> Result<Value, EngineError> {
    rpc_strict(&st.engine_ws, engine_token(st), method, params).await
}

/// The engine's own message, without the transport wrapper. The refusal frame is
/// `{code,message}`; showing a client the whole envelope reads like a host bug.
fn engine_detail(e: &EngineError) -> String {
    if let Some(idx) = e.message.find('{') {
        if let Ok(v) = serde_json::from_str::<Value>(&e.message[idx..]) {
            if let Some(msg) = v.get("message").and_then(|m| m.as_str()) {
                return msg.to_string();
            }
        }
    }
    e.message.clone()
}

async fn describe(st: &AppState, profile: &str) -> Result<Value, EngineError> {
    engine_call(st, "profiles.describe", json!({"name": profile})).await
}

/// The engine's catalogue for one profile (or the launch scope). `include_unconfigured` adds the
/// empty skeletons for providers that are *known* but have no credential — that is what makes an
/// "unknown provider" answer possible instead of treating every unauthenticated one as unknown.
async fn catalogue(st: &AppState, profile: Option<&str>) -> Result<Value, EngineError> {
    let mut params = json!({"include_unconfigured": true});
    if let Some(p) = profile {
        params["profile"] = json!(p);
    }
    engine_call(st, "model.options", params).await
}

fn row_slug(row: &Value) -> String {
    row.get("slug").and_then(|v| v.as_str()).unwrap_or("").to_lowercase()
}

fn row_models(row: &Value) -> Vec<String> {
    row.get("models")
        .and_then(|m| m.as_array())
        .map(|a| a.iter().filter_map(|m| m.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default()
}

/// Engine row → the wire shape. `state` is the one word a UI needs; `usable` is the narrower
/// "selecting this now will not fail on credentials or quota".
fn provider_row(row: &Value, priority: usize, current_provider: &str) -> Value {
    let slug = row.get("slug").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let models = row_models(row);
    let authenticated = row.get("authenticated").and_then(|v| v.as_bool()).unwrap_or(false);
    let limit = row.get("limit").cloned().unwrap_or(Value::Null);
    let account_limited = limit
        .get("scope")
        .and_then(|s| s.as_str())
        .map(|s| s == "account")
        .unwrap_or(false);
    let warning = row.get("warning").and_then(|v| v.as_str()).unwrap_or("").to_string();

    let (state, reason, usable) = if !authenticated {
        (
            "not_authenticated",
            Some(format!(
                "no credential on the host for {slug} — run `hermes auth add {slug}` on the host"
            )),
            false,
        )
    } else if models.is_empty() {
        (
            "no_models",
            Some(format!("{slug} is authenticated but the engine advertises no models")),
            false,
        )
    } else if account_limited {
        let until = limit.get("resets_at").and_then(|v| v.as_str()).unwrap_or("");
        (
            "rate_limited",
            Some(if until.is_empty() {
                format!("{slug}'s credential is rate limited")
            } else {
                format!("{slug}'s credential is rate limited until {until}")
            }),
            false,
        )
    } else if !warning.is_empty() {
        ("warning", Some(warning), true)
    } else if !limit.is_null() {
        ( "model_limited", None, true)
    } else {
        ("ready", None, true)
    };

    json!({
        "slug": slug,
        "name": row.get("name").cloned().unwrap_or(Value::Null),
        "models": models,
        "model_count": models.len(),
        "total_models": row.get("total_models").cloned().unwrap_or(json!(models.len())),
        "authenticated": authenticated,
        "usable": usable,
        "state": state,
        "reason": reason,
        "auth_type": row.get("auth_type").cloned().unwrap_or(Value::Null),
        "source": row.get("source").cloned().unwrap_or(Value::Null),
        "is_current": row.get("is_current").and_then(|v| v.as_bool()).unwrap_or(false),
        "is_default": slug.eq_ignore_ascii_case(current_provider) && !current_provider.is_empty(),
        "is_user_defined": row.get("is_user_defined").and_then(|v| v.as_bool()).unwrap_or(false),
        // The engine returns rows in its canonical/priority order; the index makes that explicit
        // without inventing a ranking of our own.
        "priority": priority,
        "limit": limit,
        "usage": row.get("usage").cloned().unwrap_or(Value::Null),
        "plan_usage": row.get("plan_usage").cloned().unwrap_or(Value::Null),
        "unavailable_models": row.get("unavailable_models").cloned().unwrap_or(Value::Null),
    })
}

/// `GET /v1/providers[?profile=bot]` — every provider the engine knows, with its models and
/// credential state. `default` is the engine's own current provider+model for that scope;
/// `providers[]` keeps the engine's priority order.
pub async fn list_providers(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(q): Query<ProvidersQuery>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    let profile = q.profile.filter(|p| !p.is_empty());
    if let Some(p) = &profile {
        if !valid_profile(p) {
            return Err(refuse(StatusCode::UNPROCESSABLE_ENTITY, "invalid_bot", "invalid bot name", json!({})));
        }
        if let Err(e) = describe(&st, p).await {
            return Err(match e.code {
                Some(4064) => refuse(StatusCode::NOT_FOUND, "unknown_bot", engine_detail(&e), json!({"profile": p})),
                _ => bad(StatusCode::BAD_GATEWAY, e.message),
            });
        }
    }
    let payload = catalogue(&st, profile.as_deref())
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e.message))?;

    let current_provider = payload.get("provider").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let current_model = payload.get("model").and_then(|v| v.as_str()).unwrap_or("").to_string();
    // Launch scope can carry a model pin with no provider (measured: `z-ai/glm-5.3` and an empty
    // provider). The row with `is_current` is then the only provider the engine names; falling back
    // to it keeps `default` useful instead of an empty pair.
    let effective_provider = if current_provider.is_empty() {
        payload
            .get("providers")
            .and_then(|p| p.as_array())
            .and_then(|a| {
                a.iter()
                    .find(|r| r.get("is_current").and_then(|v| v.as_bool()) == Some(true))
                    .map(row_slug)
            })
            .unwrap_or_default()
    } else {
        current_provider.clone()
    };
    let rows: Vec<Value> = payload
        .get("providers")
        .and_then(|p| p.as_array())
        .map(|a| {
            a.iter()
                .enumerate()
                .map(|(i, row)| provider_row(row, i + 1, &effective_provider))
                .collect()
        })
        .unwrap_or_default();

    let ready = rows.iter().filter(|r| r.get("usable").and_then(|u| u.as_bool()) == Some(true)).count();
    let authenticated = rows
        .iter()
        .filter(|r| r.get("authenticated").and_then(|u| u.as_bool()) == Some(true))
        .count();

    Ok(Json(json!({
        "profile": profile,
        "providers": rows,
        "count": rows.len(),
        "authenticated_count": authenticated,
        "usable_count": ready,
        "default": {"provider": effective_provider, "model": current_model},
        "provider": effective_provider,
        "model": current_model,
    })))
}

#[derive(Deserialize)]
pub struct ProvidersQuery {
    #[serde(default)]
    pub profile: Option<String>,
}

/// `GET /v1/bots/{profile}/model` — the bot's pinned provider+model, its credential state, and the
/// models that provider offers. Unknown provider on disk is reported, not hidden: a bot can point
/// at a provider that lost its credential, and the UI must offer a re-auth path instead of lying.
pub async fn get_bot_model(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(refuse(StatusCode::UNPROCESSABLE_ENTITY, "invalid_bot", "invalid bot name", json!({})));
    }
    let described = describe(&st, &profile).await.map_err(|e| match e.code {
        Some(4064) => refuse(StatusCode::NOT_FOUND, "unknown_bot", engine_detail(&e), json!({"profile": profile})),
        _ => bad(StatusCode::BAD_GATEWAY, e.message),
    })?;
    let pinned_provider = described
        .get("model")
        .and_then(|m| m.get("provider"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let pinned_model = described
        .get("model")
        .and_then(|m| m.get("default"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let payload = catalogue(&st, Some(&profile))
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e.message))?;
    let rows = payload.get("providers").and_then(|p| p.as_array()).cloned().unwrap_or_default();
    let current_provider = payload.get("provider").and_then(|v| v.as_str()).unwrap_or("");
    let current = rows
        .iter()
        .find(|r| row_slug(r).eq_ignore_ascii_case(&pinned_provider))
        .map(|r| provider_row(r, 0, current_provider));

    let (provider_known, authenticated, usable, state, reason, models) = match &current {
        Some(row) => (
            true,
            row.get("authenticated").and_then(|v| v.as_bool()).unwrap_or(false),
            row.get("usable").and_then(|v| v.as_bool()).unwrap_or(false),
            row.get("state").and_then(|v| v.as_str()).unwrap_or("unknown").to_string(),
            row.get("reason").cloned().unwrap_or(Value::Null),
            row.get("models").and_then(|m| m.as_array()).cloned().unwrap_or_default(),
        ),
        None => (
            false,
            false,
            false,
            "unknown_provider".to_string(),
            json!(format!("the engine does not offer provider '{pinned_provider}'")),
            vec![],
        ),
    };

    Ok(Json(json!({
        "profile": profile,
        "provider": pinned_provider,
        "model": pinned_model,
        "provider_known": provider_known,
        "authenticated": authenticated,
        "usable": usable,
        "state": state,
        "reason": reason,
        "models": models,
        "model_count": models.len(),
        "providers": rows.iter().enumerate().map(|(i, r)| {
            let row = provider_row(r, i + 1, current_provider);
            json!({
                "slug": row.get("slug"),
                "name": row.get("name"),
                "authenticated": row.get("authenticated"),
                "usable": row.get("usable"),
                "state": row.get("state"),
                "model_count": row.get("model_count"),
                "is_current": row.get("is_current"),
            })
        }).collect::<Vec<_>>(),
        "default": {"provider": pinned_provider, "model": pinned_model},
    })))
}

#[derive(Deserialize)]
pub struct ModelPut {
    /// Optional: a bare `{model}` keeps the bot's current provider (the old single-field shape).
    #[serde(default)]
    pub provider: Option<String>,
    pub model: String,
    /// The engine refuses a "guarded" (expensive/data-policy) model once; the client resends with
    /// this after the user confirms.
    #[serde(default)]
    pub confirm_expensive_model: Option<bool>,
    /// Skip the catalogue membership check — for a model id the provider accepts but the engine's
    /// curated catalogue has not listed.
    #[serde(default)]
    pub force: Option<bool>,
}

/// `PUT|POST /v1/bots/{profile}/model` — pin a bot's provider+model through the engine
/// (`profiles.configure`), then read it back with `profiles.describe`. The read-back is the
/// proof: a 200 from the write is not the same fact as the profile now carrying the pin.
pub async fn put_bot_model(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Json(body): Json<ModelPut>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(refuse(StatusCode::UNPROCESSABLE_ENTITY, "invalid_bot", "invalid bot name", json!({})));
    }
    let model = body.model.trim().to_string();
    if model.is_empty() {
        return Err(refuse(StatusCode::UNPROCESSABLE_ENTITY, "model_required", "model is required", json!({})));
    }

    let described = describe(&st, &profile).await.map_err(|e| match e.code {
        Some(4064) => refuse(StatusCode::NOT_FOUND, "unknown_bot", engine_detail(&e), json!({"profile": profile})),
        _ => bad(StatusCode::BAD_GATEWAY, e.message),
    })?;
    let current_provider = described
        .get("model")
        .and_then(|m| m.get("provider"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let provider = body
        .provider
        .as_deref()
        .map(|p| p.trim().to_lowercase())
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| current_provider.to_lowercase());
    if provider.is_empty() {
        return Err(refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "provider_required",
            "provider is required (this bot has no provider pin to fall back to)",
            json!({}),
        ));
    }

    let payload = catalogue(&st, Some(&profile))
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e.message))?;
    let rows = payload.get("providers").and_then(|p| p.as_array()).cloned().unwrap_or_default();
    let row = rows.iter().find(|r| row_slug(r).eq_ignore_ascii_case(&provider));

    // Four refusals, each one distinguishable in a UI:
    //   unknown_bot               404 — profiles.describe said 4064
    //   unknown_provider          422 — the engine's catalogue does not contain this slug
    //   provider_not_authenticated 409 — known, but no credential on the host
    //   model_not_offered         422 — authenticated, but this provider does not list the model
    let Some(row) = row else {
        let known: Vec<String> = rows.iter().map(row_slug).filter(|s| !s.is_empty()).take(64).collect();
        return Err(refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "unknown_provider",
            format!("unknown provider '{provider}'"),
            json!({"provider": provider, "known_providers": known}),
        ));
    };
    let authenticated = row.get("authenticated").and_then(|v| v.as_bool()).unwrap_or(false);
    if !authenticated {
        return Err(refuse(
            StatusCode::CONFLICT,
            "provider_not_authenticated",
            format!("provider '{provider}' is known but has no credential on the host"),
            json!({
                "provider": provider,
                "hint": format!("run `hermes auth add {provider}` on the host"),
            }),
        ));
    }
    let models = row_models(row);
    if models.is_empty() {
        return Err(refuse(
            StatusCode::CONFLICT,
            "provider_unavailable",
            format!("provider '{provider}' is authenticated but offers no models"),
            json!({"provider": provider}),
        ));
    }
    if body.force != Some(true) && !models.iter().any(|m| m == &model) {
        let needle = model.to_lowercase();
        let suggestions: Vec<String> = models
            .iter()
            .filter(|m| m.to_lowercase().contains(&needle) || needle.contains(&m.to_lowercase()))
            .take(8)
            .cloned()
            .collect();
        return Err(refuse(
            StatusCode::UNPROCESSABLE_ENTITY,
            "model_not_offered",
            format!("provider '{provider}' does not offer model '{model}'"),
            json!({
                "provider": provider,
                "model": model,
                "model_count": models.len(),
                "suggestions": suggestions,
                "force_hint": "resend with \"force\": true to pin a model id outside the engine catalogue",
            }),
        ));
    }

    let mut params = json!({"name": profile, "provider": provider, "model": model});
    if body.confirm_expensive_model == Some(true) {
        params["confirm_expensive_model"] = json!(true);
    }
    let applied = engine_call(&st, "profiles.configure", params)
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e.message))?;

    if applied.get("confirm_required").and_then(|v| v.as_bool()) == Some(true) {
        // Nothing was written; the client shows the engine's own words and resends with the flag.
        return Ok(Json(json!({
            "profile": profile,
            "provider": provider,
            "model": model,
            "applied": false,
            "confirm_required": true,
            "confirm_message": applied.get("confirm_message").cloned().unwrap_or(Value::Null),
        })));
    }

    let after = describe(&st, &profile)
        .await
        .map_err(|e| bad(StatusCode::BAD_GATEWAY, e.message))?;
    let now_provider = after
        .get("model")
        .and_then(|m| m.get("provider"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let now_model = after
        .get("model")
        .and_then(|m| m.get("default"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if !now_provider.eq_ignore_ascii_case(&provider) || now_model != model {
        return Err(refuse(
            StatusCode::BAD_GATEWAY,
            "engine_did_not_apply",
            "the engine accepted the change but the profile still carries a different pin",
            json!({"requested": {"provider": provider, "model": model},
                   "stored": {"provider": now_provider, "model": now_model}}),
        ));
    }

    Ok(Json(json!({
        "profile": profile,
        "provider": now_provider,
        "model": now_model,
        "previous": {"provider": current_provider, "model": described.get("model").and_then(|m| m.get("default")).cloned().unwrap_or(Value::Null)},
        "applied": true,
        "confirm_required": false,
        "authenticated": true,
        "usable": row.get("usable").and_then(|v| v.as_bool()).unwrap_or(true),
    })))
}
