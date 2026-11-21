//! Voice relay for paired devices: speech-to-text and text-to-speech.
//!
//! Two POSTs, each authenticated by its own **fresh single-use `ws_ticket`** in
//! `Authorization: Bearer …`:
//!
//! ```text
//! POST /v1/voice/transcribe  {mime_type, content_base64} -> {transcript}
//! POST /v1/voice/synthesize  {text}                      -> {mime_type, content_base64}
//! ```
//!
//! Deliberate properties, carried over from the production bridge because they are the reason it is
//! safe to expose this at all:
//!
//! * The client sends **bytes only** — no URL, path or filename — and the provider base URLs come from
//!   this host's configuration, so a request cannot steer a connection (nothing to SSRF).
//! * Audio is capped at 10 MiB *decoded* and must be mp3/m4a/wav/ogg; text at 4 000 characters.
//!   Base64 is validated, not merely decoded.
//! * Keys never leave this process: they go into a request header and are never logged, echoed in an
//!   error, or returned.
//!
//! **A custom User-Agent is mandatory.** Groq sits behind Cloudflare, which answers the default
//! `reqwest`/`urllib` fingerprint with `403 Error 1010: Access denied` even when the key is valid —
//! measured, and it looks exactly like a bad key. Set `HERMEY_VOICE_USER_AGENT` to override.
//!
//! Keys live in `$HERMEY_HOME/.env` (`HERMEY_GROQ_API_KEY`, `HERMEY_ELEVENLABS_API_KEY`) — never in the
//! production managed env, which Edition A deliberately cannot read.

use crate::routes::{AppState};
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::Json;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::{Arc, OnceLock};

type Fail = (StatusCode, Json<Value>);

const MAX_AUDIO_BYTES: usize = 10 * 1024 * 1024;
const MAX_TEXT_CHARS: usize = 4_000;
/// Provider replies are capped too: a hostile or broken endpoint must not be able to fill memory.
const MAX_PROVIDER_BYTES: usize = MAX_AUDIO_BYTES + 64 * 1024;

const DEFAULT_VOICE_ID: &str = "EXAVITQu4vr4xnSDxMaL";
const DEFAULT_TTS_MODEL: &str = "eleven_multilingual_v2";
const DEFAULT_TRANSCRIBE_MODEL: &str = "whisper-large-v3";
const DEFAULT_GROQ_BASE: &str = "https://api.groq.com/openai/v1";
const DEFAULT_ELEVEN_BASE: &str = "https://api.elevenlabs.io/v1";
const DEFAULT_USER_AGENT: &str = "hermeyd-voice/1.0";

// Fixed sentences: the provider's own body can contain account details and is not ours to show.
const TRANSCRIBE_FAILED: &str = "the transcription service could not be reached";
const SYNTHESIZE_FAILED: &str = "the speech service could not be reached";
const NOT_CONFIGURED: &str = "voice is not configured on this host";

fn bad(status: StatusCode, msg: impl Into<String>) -> Fail {
    (status, Json(json!({"detail": msg.into()})))
}

/// mime → file extension for the multipart upload; anything else is 415, with no sniffing.
fn extension_for(mime: &str) -> Option<&'static str> {
    match mime {
        "audio/mpeg" => Some("mp3"),
        "audio/mp4" => Some("mp4"),
        "audio/x-m4a" => Some("m4a"),
        "audio/wav" | "audio/x-wav" => Some("wav"),
        "audio/ogg" => Some("ogg"),
        _ => None,
    }
}

struct VoiceConfig {
    groq_key: String,
    eleven_key: String,
    groq_base: String,
    eleven_base: String,
    voice_id: String,
    tts_model: String,
    transcribe_model: String,
    user_agent: String,
    client: reqwest::Client,
}

fn env_or_file(name: &str, env_file: &Path, file_text: &str) -> String {
    if let Ok(v) = std::env::var(name) {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    let _ = env_file;
    for line in file_text.lines() {
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

impl VoiceConfig {
    /// The env file is resolved by `host_env` — `HERMEY_HOME/.env`, then the engine home's, then
    /// its parent — not guessed as `engine_home.parent()`. Boot logs which one won.
    fn load(engine_home: &Path) -> Self {
        let env_file = crate::host_env::select_from_process(engine_home).path;
        let text = std::fs::read_to_string(&env_file).unwrap_or_default();
        let get = |name: &str, default: &str| {
            let v = env_or_file(name, &env_file, &text);
            if v.is_empty() { default.to_string() } else { v }
        };
        let timeout: u64 = get("HERMEY_VOICE_TIMEOUT", "30").parse().unwrap_or(30);
        Self {
            groq_key: get("HERMEY_GROQ_API_KEY", ""),
            eleven_key: get("HERMEY_ELEVENLABS_API_KEY", ""),
            groq_base: get("HERMEY_VOICE_GROQ_BASE_URL", DEFAULT_GROQ_BASE),
            eleven_base: get("HERMEY_VOICE_ELEVENLABS_BASE_URL", DEFAULT_ELEVEN_BASE),
            voice_id: get("HERMEY_VOICE_ID", DEFAULT_VOICE_ID),
            tts_model: get("HERMEY_VOICE_TTS_MODEL", DEFAULT_TTS_MODEL),
            transcribe_model: get("HERMEY_VOICE_TRANSCRIBE_MODEL", DEFAULT_TRANSCRIBE_MODEL),
            user_agent: get("HERMEY_VOICE_USER_AGENT", DEFAULT_USER_AGENT),
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(timeout.clamp(5, 120)))
                .build()
                .unwrap_or_default(),
        }
    }
}

fn config(st: &AppState) -> &'static VoiceConfig {
    static CONFIG: OnceLock<VoiceConfig> = OnceLock::new();
    CONFIG.get_or_init(|| VoiceConfig::load(&st.engine_home))
}

/// The app spends a fresh ticket on every voice request, so this is a one-shot credential — not the
/// long-lived device access token.
fn device_from_ticket(st: &AppState, headers: &HeaderMap) -> Result<String, Fail> {
    let raw = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let ticket = raw
        .strip_prefix("Bearer ")
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .ok_or_else(|| bad(StatusCode::UNAUTHORIZED, "a fresh ticket is required"))?;
    st.tickets
        .consume_ticket(ticket)
        .ok_or_else(|| bad(StatusCode::UNAUTHORIZED, "that ticket is invalid or already used"))
}

#[derive(Deserialize)]
pub struct TranscribeBody {
    pub mime_type: String,
    pub content_base64: String,
}

pub async fn transcribe(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<TranscribeBody>,
) -> Result<Json<Value>, Fail> {
    let _device = device_from_ticket(&st, &headers)?;
    let cfg = config(&st);
    if cfg.groq_key.is_empty() {
        return Err(bad(StatusCode::SERVICE_UNAVAILABLE, NOT_CONFIGURED));
    }
    let extension = extension_for(body.mime_type.trim())
        .ok_or_else(|| bad(StatusCode::UNSUPPORTED_MEDIA_TYPE, "unsupported audio type"))?;

    let audio = STANDARD
        .decode(body.content_base64.trim())
        .map_err(|_| bad(StatusCode::UNPROCESSABLE_ENTITY, "the audio was not valid base64"))?;
    if audio.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "the recording is empty"));
    }
    if audio.len() > MAX_AUDIO_BYTES {
        return Err(bad(StatusCode::PAYLOAD_TOO_LARGE, "that recording is too large"));
    }

    let part = reqwest::multipart::Part::bytes(audio)
        .file_name(format!("audio.{extension}"))
        .mime_str(body.mime_type.trim())
        .map_err(|_| bad(StatusCode::UNSUPPORTED_MEDIA_TYPE, "unsupported audio type"))?;
    let form = reqwest::multipart::Form::new()
        .text("model", cfg.transcribe_model.clone())
        .part("file", part);

    let response = cfg
        .client
        .post(format!("{}/audio/transcriptions", cfg.groq_base.trim_end_matches('/')))
        .header(header::AUTHORIZATION, format!("Bearer {}", cfg.groq_key))
        .header(header::USER_AGENT, &cfg.user_agent)
        .header(header::ACCEPT, "application/json")
        .multipart(form)
        .send()
        .await
        .map_err(|e| {
            eprintln!("voice: transcribe transport error: {e}");
            bad(StatusCode::BAD_GATEWAY, TRANSCRIBE_FAILED)
        })?;

    let status = response.status();
    if !status.is_success() {
        // Status only: the body can carry account details.
        eprintln!("voice: transcribe provider status {status}");
        return Err(bad(StatusCode::BAD_GATEWAY, TRANSCRIBE_FAILED));
    }
    let text = response.text().await.unwrap_or_default();
    let parsed: Value = serde_json::from_str(&text)
        .map_err(|_| bad(StatusCode::BAD_GATEWAY, TRANSCRIBE_FAILED))?;
    let transcript = parsed
        .get("text")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    Ok(Json(json!({ "transcript": transcript })))
}

#[derive(Deserialize)]
pub struct SynthesizeBody {
    pub text: String,
}

pub async fn synthesize(
    State(st): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(body): Json<SynthesizeBody>,
) -> Result<Json<Value>, Fail> {
    let _device = device_from_ticket(&st, &headers)?;
    let cfg = config(&st);
    if cfg.eleven_key.is_empty() {
        return Err(bad(StatusCode::SERVICE_UNAVAILABLE, NOT_CONFIGURED));
    }
    let text = body.text.trim().to_string();
    if text.is_empty() {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "there is nothing to say"));
    }
    if text.chars().count() > MAX_TEXT_CHARS {
        return Err(bad(StatusCode::UNPROCESSABLE_ENTITY, "that text is too long to speak"));
    }

    let response = cfg
        .client
        .post(format!(
            "{}/text-to-speech/{}",
            cfg.eleven_base.trim_end_matches('/'),
            cfg.voice_id
        ))
        .header("xi-api-key", &cfg.eleven_key)
        .header(header::USER_AGENT, &cfg.user_agent)
        .header(header::ACCEPT, "audio/mpeg")
        .json(&json!({ "text": text, "model_id": cfg.tts_model }))
        .send()
        .await
        .map_err(|e| {
            eprintln!("voice: synthesize transport error: {e}");
            bad(StatusCode::BAD_GATEWAY, SYNTHESIZE_FAILED)
        })?;

    let status = response.status();
    if !status.is_success() {
        eprintln!("voice: synthesize provider status {status}");
        return Err(bad(StatusCode::BAD_GATEWAY, SYNTHESIZE_FAILED));
    }
    let bytes: Bytes = response
        .bytes()
        .await
        .map_err(|_| bad(StatusCode::BAD_GATEWAY, SYNTHESIZE_FAILED))?;
    if bytes.is_empty() || bytes.len() > MAX_PROVIDER_BYTES {
        return Err(bad(StatusCode::BAD_GATEWAY, SYNTHESIZE_FAILED));
    }
    Ok(Json(json!({
        "mime_type": "audio/mpeg",
        "content_base64": STANDARD.encode(&bytes),
    })))
}
