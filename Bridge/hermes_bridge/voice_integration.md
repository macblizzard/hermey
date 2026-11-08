# Voice: integration contract

The router is mounted by `create_app` (`create_voice_router`). Keys are read once from the
bridge `EnvironmentFile` (`GROQ_API_KEY`, `ELEVENLABS_API_KEY`) by `VoiceBackend.from_env()`;
they are never accepted from a request, never returned and never logged.

## Endpoints

Both are `POST`, JSON only, and require a **fresh single-use `ws_ticket`** in
`Authorization: Bearer <ticket>` — mint one per request at `/v1/token`, exactly like
`/v1/bot-icons`. The ticket is consumed by the call; reuse is 401. The `/v1/token`
`access_token` is not accepted.

* `POST /v1/voice/transcribe` body `{"mime_type": "audio/mp4", "content_base64": "..."}` →
  `{"transcript": "..."}`.
  - `mime_type` allowlist: `audio/mpeg`, `audio/mp4`, `audio/x-m4a`, `audio/wav`,
    `audio/x-wav`, `audio/ogg` (exact strings — parameters such as `; charset=…` are not
    accepted). Anything else is 415.
  - `content_base64` is strict base64 of the audio bytes; decoded size ≤ 10 MiB, else 413.
  - Provider: Groq `POST {base}/audio/transcriptions`, `model=whisper-large-v3`, multipart
    `file` + `model`, custom `User-Agent` (a plain urllib UA is refused by the CDN in front
    of Groq; measured, not assumed).
* `POST /v1/voice/synthesize` body `{"text": "..."}` → `{"mime_type": "audio/mpeg",
  "content_base64": "..."}`.
  - `text` must be non-blank (422) and ≤ 4000 characters (413).
  - Provider: ElevenLabs `POST {base}/text-to-speech/EXAVITQu4vr4xnSDxMaL` with
    `model_id=eleven_multilingual_v2`, `Accept: audio/mpeg`.

Unknown fields are rejected (422) on both, so no `url`/`path`/`audio_url` can be smuggled in.
The client never chooses a provider URL; base URLs, models and the voice id are host
configuration (`VoiceBackend`), overridable for tests.

## Errors

| status | meaning |
| --- | --- |
| 401 | missing, invalid, expired, replayed or revoked ticket |
| 413 | decoded audio > 10 MiB, or text > 4000 characters |
| 415 | mime type outside the allowlist |
| 422 | body shape (unknown field, blank text) |
| 502 | provider failure / unreachable / not configured — fixed short sentence |

A 502 detail is a constant sentence such as `Speech transcription failed at the voice
provider.` The provider's own body is discarded; a scrubbed, truncated copy goes to the
`hermes_bridge.voice` logger at DEBUG only, so a 502 can be diagnosed without leaking a key.

## Phone wiring

`Apps/HermesMobile/Networking/VoiceService.swift` is the client (Foundation only). It mints
its own ticket per request through the injected `freshTicket` closure, refuses redirects
(the final URL must match the paired host), and enforces the same limits locally so the user
sees a message instead of an HTTP code. `AppEnvironment.makeVoiceTransport()` builds the
transport from the current pairing; `ConversationScreen` gives each conversation a
`VoiceController`:

* the mic records `audio/mp4` (AAC, 16 kHz mono, ≤ 60 s), stops, transcribes, and **fills
  the draft** — it does not send on its own, so misrecognition can be corrected first;
* the speaker toggle is opt-in per visit, off by default, and speaks only replies that
  arrive while it is on (no history replay, no repeats).

`VoiceTransport.swift`, `VoiceService.swift` and the tests are compiled by the
`HermesVoiceCore` SwiftPM target so they can run without a simulator.

## Measured (2026-11-06, host `hermey` checkout)

Real calls, keys read from `/etc/hermes-bridge/secrets.env` and never printed:

* `synthesize("The quick brown fox jumps over the lazy dog.")` → 200, `audio/mpeg`,
  39,749 bytes, `ID3` header, 0.28 s.
* `transcribe` of those bytes (`audio/mpeg`) → 200, 44 chars, transcript exactly
  `The quick brown fox jumps over the lazy dog.`, 0.32 s.
* Through the mounted endpoints (TestClient, real backend, throwaway device row):
  synthesize → 64,826-byte mp3 → transcribe → exact sentence; reusing that ticket returned
  401; no ticket returned 401.

## Not verified

* Nothing was deployed, restarted or reconfigured, so the running bridge does not serve
  these routes until it is redeployed.
* Swift: no toolchain in this environment. The iOS app, the UI wiring and
  `Tests/HermesVoiceTests` have not been compiled or run here; `swift test` on macOS and the
  iOS simulator build remain to be run in CI.
* Nothing has been exercised on a physical device: microphone permission, audio-session
  switching between `.playAndRecord` and `.playback`, interruption handling, and playback of
  the returned mp3 through `AVAudioPlayer` are all unverified on hardware.
