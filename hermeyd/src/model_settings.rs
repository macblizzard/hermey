//! A bot's model settings: how hard the model is asked to think, and which model looks at pictures.
//!
//! Both are facts the model catalogue cannot answer — they live in the profile's `config.yaml`
//! (`agent.reasoning_effort` and `auxiliary.vision.*`), so this reads and writes that file. The write
//! is a merge, not a replacement: only the keys this sheet owns may change.

use crate::routes::{require_device, AppState};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

type Fail = (StatusCode, Json<Value>);

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// The engine's own list (`hermes_constants.VALID_REASONING_EFFORTS`), plus `""` for the provider's
/// default. A level the engine adds later still round-trips: the current value is always shown.
const EFFORTS: [&str; 8] = ["", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"];

fn valid_profile(profile: &str) -> bool {
    !profile.is_empty()
        && profile.len() <= 64
        && profile.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn config_path(st: &AppState, profile: &str) -> PathBuf {
    st.engine_home.join("profiles").join(profile).join("config.yaml")
}

fn load(path: &PathBuf) -> serde_yaml::Value {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_yaml::from_str::<serde_yaml::Value>(&s).ok())
        .filter(|v| v.is_mapping())
        .unwrap_or(serde_yaml::Value::Mapping(Default::default()))
}

fn get_str(doc: &serde_yaml::Value, section: &str, key: &str) -> String {
    doc.get(section)
        .and_then(|s| s.get(key))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

/// `auxiliary.vision.<key>` — the shape every shipped config uses and the engine reads
/// (`agent/image_routing.py` → `cfg["auxiliary"]["vision"]["provider"|"model"]`,
/// `agent/auxiliary_client.py` → `_get_auxiliary_task_config("vision")`).
fn nested_char(doc: &serde_yaml::Value, section: &str, block: &str, key: &str) -> String {
    doc.get(section)
        .and_then(|s| s.get(block))
        .and_then(|b| b.get(key))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

/// The vision pair the engine would actually use: the nested object first, then the flat
/// `auxiliary.vision_provider` / `vision_model` an older config (or a pre-fix write of ours) has.
///
/// This is the live bug this module had: it only read the flat pair, which neither shipped config
/// nor the engine writes, so the app's vision row showed `auto` on every bot forever.
fn vision_pair(doc: &serde_yaml::Value) -> (String, String) {
    let mut provider = nested_char(doc, "auxiliary", "vision", "provider");
    let mut model = nested_char(doc, "auxiliary", "vision", "model");
    if provider.is_empty() {
        provider = get_str(doc, "auxiliary", "vision_provider");
    }
    if model.is_empty() {
        model = get_str(doc, "auxiliary", "vision_model");
    }
    (provider, model)
}

fn view(doc: &serde_yaml::Value) -> Value {
    let effort = get_str(doc, "agent", "reasoning_effort");
    let (raw_provider, vision_model) = vision_pair(doc);
    let provider = if raw_provider.is_empty() {
        "auto".to_string()
    } else {
        raw_provider
    };
    json!({
        "effort": effort,
        // Bare strings, in the same order (the leading `""` is "provider default"), because the
        // app's decoder looks each entry up as a `String` and drops anything richer.
        "efforts": EFFORTS.iter().map(|e| json!(e)).collect::<Vec<_>>(),
        // The flat pair stays for older readers; the app reads the nested object.
        "vision_provider": provider,
        "vision_model": vision_model,
        "vision": { "provider": provider, "model": vision_model },
    })
}

pub async fn get_settings(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    let path = config_path(&st, &profile);
    if !path.is_file() {
        return Err(bad(StatusCode::NOT_FOUND, "no such bot"));
    }
    Ok(Json(view(&load(&path))))
}

/// Set the vision pair in the **nested** form the engine reads, preserving every sibling key.
///
/// A replacement would drop `auxiliary.vision.base_url`, `mode`, `timeout`, or
/// `auxiliary.free_only` — settings this sheet does not own but that the engine does read. So the
/// existing maps are cloned, one key is written, and the rest is put back untouched.
fn apply_vision(
    doc: &mut serde_yaml::Value,
    provider: Option<&str>,
    model: Option<&str>,
) {
    let mut auxiliary = doc
        .get("auxiliary")
        .and_then(|v| v.as_mapping().cloned())
        .unwrap_or_default();
    let mut vision = auxiliary
        .get(serde_yaml::Value::from("vision"))
        .and_then(|v| v.as_mapping().cloned())
        .unwrap_or_default();
    if let Some(provider) = provider {
        vision.insert(
            serde_yaml::Value::from("provider"),
            serde_yaml::Value::from(provider.trim()),
        );
    }
    if let Some(model) = model {
        vision.insert(
            serde_yaml::Value::from("model"),
            serde_yaml::Value::from(model.trim()),
        );
    }
    auxiliary.insert(
        serde_yaml::Value::from("vision"),
        serde_yaml::Value::Mapping(vision),
    );
    doc["auxiliary"] = serde_yaml::Value::Mapping(auxiliary);
}

/// Set `agent.reasoning_effort`, preserving the rest of the `agent` block.
fn apply_effort(doc: &mut serde_yaml::Value, effort: &str) {
    let mut agent = doc
        .get("agent")
        .and_then(|v| v.as_mapping().cloned())
        .unwrap_or_default();
    agent.insert(
        serde_yaml::Value::from("reasoning_effort"),
        serde_yaml::Value::from(effort),
    );
    doc["agent"] = serde_yaml::Value::Mapping(agent);
}

/// Render and replace the config atomically: a half-written config would break the bot's next turn.
fn save(path: &std::path::Path, doc: &serde_yaml::Value) -> Result<(), String> {
    let rendered = serde_yaml::to_string(doc)
        .map_err(|e| format!("could not render config: {e}"))?;
    let tmp = path.with_extension("yaml.tmp");
    std::fs::write(&tmp, rendered).map_err(|e| format!("could not write config: {e}"))?;
    std::fs::rename(&tmp, path).map_err(|e| format!("could not save config: {e}"))
}

#[derive(Deserialize)]
pub struct SettingsPut {
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub vision_provider: Option<String>,
    #[serde(default)]
    pub vision_model: Option<String>,
}

pub async fn put_settings(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(profile): Path<String>,
    Json(body): Json<SettingsPut>,
) -> Result<Json<Value>, Fail> {
    require_device(&st, &headers)?;
    if !valid_profile(&profile) {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "invalid bot name"));
    }
    let path = config_path(&st, &profile);
    if !path.is_file() {
        return Err(bad(StatusCode::NOT_FOUND, "no such bot"));
    }
    let mut doc = load(&path);

    if let Some(effort) = body.effort.clone() {
        let effort = effort.trim().to_string();
        if !EFFORTS.contains(&effort.as_str()) {
            return Err(bad(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("unknown effort level: {effort}"),
            ));
        }
        apply_effort(&mut doc, &effort);
    }

    if body.vision_provider.is_some() || body.vision_model.is_some() {
        apply_vision(
            &mut doc,
            body.vision_provider.as_deref(),
            body.vision_model.as_deref(),
        );
    }

    save(&path, &doc).map_err(|e| bad(StatusCode::INTERNAL_SERVER_ERROR, e))?;

    Ok(Json(view(&load(&path))))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn parse(text: &str) -> serde_yaml::Value {
        serde_yaml::from_str(text).expect("yaml")
    }

    fn scratch(tag: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "hermeyd-settings-{tag}-{}-{nanos}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    /// The shipped shape (`/root/.hermes/profiles/cody/config.yaml`): nested provider/model.
    /// Before this fix the row read the flat pair, found nothing, and said "auto" forever.
    #[test]
    fn the_nested_vision_pair_is_what_the_app_shows() {
        let doc = parse(
            "auxiliary:\n  vision:\n    provider: opencode-go\n    model: deepseek-v4.1-flash\n",
        );
        let shown = view(&doc);
        assert_eq!(shown["vision"]["provider"], "opencode-go");
        assert_eq!(shown["vision"]["model"], "deepseek-v4.1-flash");
        assert_eq!(shown["vision_provider"], "opencode-go");
        assert_eq!(shown["vision_model"], "deepseek-v4.1-flash");
    }

    /// An older config (or one this module wrote before the fix) carries only the flat pair; it
    /// must still read, so the row does not go blank on upgrade.
    #[test]
    fn a_flat_only_config_still_reads() {
        let doc = parse("auxiliary:\n  vision_provider: groq\n  vision_model: llama-3.2-11b-vision\n");
        let shown = view(&doc);
        assert_eq!(shown["vision"]["provider"], "groq");
        assert_eq!(shown["vision"]["model"], "llama-3.2-11b-vision");
    }

    /// Both shapes present: the nested one the engine reads wins, even when the flat leftover
    /// disagrees.
    #[test]
    fn nested_beats_flat_when_both_exist() {
        let doc = parse(
            "auxiliary:\n  vision_provider: stale\n  vision_model: stale-model\n  vision:\n    provider: opencode-go\n    model: fresh-model\n",
        );
        let shown = view(&doc);
        assert_eq!(shown["vision"]["provider"], "opencode-go");
        assert_eq!(shown["vision"]["model"], "fresh-model");
    }

    /// The write must land where the engine looks, and must not eat any sibling: `base_url`,
    /// `mode` and `auxiliary.free_only` are settings this sheet does not own.
    #[test]
    fn a_vision_write_is_nested_and_preserves_every_sibling() {
        let mut doc = parse(
            "agent:\n  reasoning_effort: high\n  max_turns: 40\n\
             auxiliary:\n  free_only: true\n  vision:\n    provider: old\n    model: old-model\n    base_url: https://example.invalid/v1\n    mode: text\n\
             skills:\n  external_dirs: [/tmp/skills]\n",
        );
        apply_vision(&mut doc, Some(" opencode-go "), Some("deepseek-v4.1-flash"));

        // Render and re-parse: a round trip through the file is what the engine reads.
        let again = parse(&serde_yaml::to_string(&doc).unwrap());
        assert_eq!(again["auxiliary"]["vision"]["provider"], "opencode-go");
        assert_eq!(again["auxiliary"]["vision"]["model"], "deepseek-v4.1-flash");
        assert_eq!(
            again["auxiliary"]["vision"]["base_url"],
            "https://example.invalid/v1",
            "base_url was lost"
        );
        assert_eq!(again["auxiliary"]["vision"]["mode"], "text", "mode was lost");
        assert_eq!(again["auxiliary"]["free_only"], true, "free_only was lost");
        assert_eq!(again["agent"]["reasoning_effort"], "high");
        assert_eq!(again["agent"]["max_turns"], 40);
        assert_eq!(again["skills"]["external_dirs"][0], "/tmp/skills");
        assert!(again["auxiliary"].get("vision_provider").is_none(), "no new flat key");
    }

    /// One half of the pair alone must not clear the other.
    #[test]
    fn writing_only_the_model_keeps_the_provider() {
        let mut doc = parse("auxiliary:\n  vision:\n    provider: opencode-go\n    model: old\n");
        apply_vision(&mut doc, None, Some("new-model"));
        let again = parse(&serde_yaml::to_string(&doc).unwrap());
        assert_eq!(again["auxiliary"]["vision"]["provider"], "opencode-go");
        assert_eq!(again["auxiliary"]["vision"]["model"], "new-model");
    }

    /// The effort write is a merge too: a second key in `agent` must survive.
    #[test]
    fn an_effort_write_keeps_the_agent_block() {
        let mut doc = parse("agent:\n  reasoning_effort: low\n  max_turns: 12\n");
        apply_effort(&mut doc, "high");
        let again = parse(&serde_yaml::to_string(&doc).unwrap());
        assert_eq!(again["agent"]["reasoning_effort"], "high");
        assert_eq!(again["agent"]["max_turns"], 12);
    }

    /// Full path on a real file: load → mutate → save → load → view. This is the handler's flow
    /// minus the HTTP layer, and it catches a temp-name or rename mistake the pure tests cannot.
    #[test]
    fn a_settings_write_round_trips_through_the_file() {
        let dir = scratch("roundtrip");
        let path = dir.join("config.yaml");
        std::fs::write(
            &path,
            "auxiliary:\n  vision:\n    provider: old\n    model: old-model\n    timeout: 30\n",
        )
        .unwrap();

        let mut doc = load(&path);
        apply_vision(&mut doc, Some("opencode-go"), Some("deepseek-v4.1-flash"));
        save(&path, &doc).expect("save");

        let shown = view(&load(&path));
        assert_eq!(shown["vision"]["provider"], "opencode-go");
        assert_eq!(shown["vision"]["model"], "deepseek-v4.1-flash");
        assert_eq!(load(&path)["auxiliary"]["vision"]["timeout"], 30);
        assert!(!path.with_extension("yaml.tmp").exists(), "temp file left behind");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
