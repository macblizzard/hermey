"""Voice relay for paired devices: speech-to-text and text-to-speech.

Two POST endpoints, each authenticated by its own fresh single-use ``ws_ticket``
(``Authorization: Bearer``), exactly like :mod:`hermes_bridge.bot_icons`:

* ``POST /v1/voice/transcribe`` ``{mime_type, content_base64}`` -> ``{transcript}``
* ``POST /v1/voice/synthesize`` ``{text}`` -> ``{mime_type, content_base64}``

Security posture:

* The client sends bytes only. There is no URL, path or filename field, and the
  provider base URLs come from this host's configuration — the request cannot
  influence where a connection goes, so there is nothing to SSRF.
* Audio is capped at 10 MiB *decoded* and must be mp3/m4a/wav/ogg; text is capped
  at 4000 characters. Base64 is validated strictly, not merely decoded.
* Provider credentials live only in headers built here. They are never returned,
  never logged, and scrubbed from any provider text that might echo them.
* A provider failure is a 502 with a short fixed sentence — the provider's body
  is not echoed, because it can contain account details and is not ours to show.
"""

from __future__ import annotations

import base64
import binascii
import json
import logging
import os
import re
import secrets
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Dict, Optional, Tuple

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, ConfigDict

from .device_auth import require_device

#: Decoded audio ceiling. The phone records at 32 kbit/s, so 10 MiB is far more
#: than the 60-second capture limit — this is an abuse bound, not a UX bound.
MAX_AUDIO_BYTES = 10 * 1024 * 1024
MAX_TEXT_CHARS = 4000
#: Provider responses larger than this are truncated rather than buffered whole.
MAX_PROVIDER_RESPONSE_BYTES = MAX_AUDIO_BYTES + 64 * 1024
PROVIDER_TIMEOUT_SECONDS = 30.0

#: mime -> filename extension. Anything else is 415; no sniffing of the bytes.
ALLOWED_AUDIO_MIME: Dict[str, str] = {
    'audio/mpeg': 'mp3',
    'audio/mp4': 'mp4',
    'audio/x-m4a': 'm4a',
    'audio/wav': 'wav',
    'audio/x-wav': 'wav',
    'audio/ogg': 'ogg',
}

VOICE_ID = 'EXAVITQu4vr4xnSDxMaL'
TRANSCRIBE_MODEL = 'whisper-large-v3'
TTS_MODEL = 'eleven_multilingual_v2'
GROQ_BASE_URL = 'https://api.groq.com/openai/v1'
ELEVENLABS_BASE_URL = 'https://api.elevenlabs.io/v1'

#: A plain ``Python-urllib/x.y`` UA is refused by the CDN in front of Groq; a
#: custom one is not. Keep this explicit and stable.
USER_AGENT = 'HermesBridge/1.0 (+https://github.com/hermey; voice-relay)'

#: ``(url, body, headers, timeout) -> (status, body, headers)``. Injecting this is
#: how tests prove the wire shape without spending a cent.
HTTPCall = Callable[[str, bytes, Dict[str, str], float], Tuple[int, bytes, Dict[str, str]]]

#: Short, fixed, credential-free messages. A provider's own text is never used.
TRANSCRIBE_FAILED = 'Speech transcription failed at the voice provider.'
SYNTHESIZE_FAILED = 'Speech synthesis failed at the voice provider.'
PROVIDER_UNREACHABLE = 'The voice provider could not be reached.'
NOT_CONFIGURED = 'Voice providers are not configured on this host.'

_VOICE_ID_PATTERN = re.compile(r'^[A-Za-z0-9_-]{1,64}$')

_log = logging.getLogger('hermes_bridge.voice')


class VoiceProviderError(Exception):
    """Provider-side failure, with a message that is safe to return verbatim."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse a 3xx instead of dialling whatever it points at."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _urlopen(url: str, body: bytes, headers: Dict[str, str], timeout: float):
    """Default transport: one blocking POST, bounded read, redirects not followed.

    A redirect is the one way a provider (or something in front of it) could make this
    host talk to an address it was never configured for, so a 3xx becomes an ordinary
    provider failure instead of a second request.
    """
    request = urllib.request.Request(url, data=body, headers=headers, method='POST')
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return response.status, response.read(MAX_PROVIDER_RESPONSE_BYTES), dict(response.headers)
    except urllib.error.HTTPError as exc:  # a real answer, just not a 200 (or a 3xx we refused)
        try:
            payload = exc.read(MAX_PROVIDER_RESPONSE_BYTES)
        except Exception:  # pragma: no cover - body already gone
            payload = b''
        return exc.code, payload, dict(exc.headers or {})
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise VoiceProviderError(PROVIDER_UNREACHABLE) from exc


def _scrub(text: str, *secrets_: Optional[str]) -> str:
    """Remove any configured credential from a string before it leaves this module."""
    cleaned = text
    for secret in secrets_:
        if secret:
            cleaned = cleaned.replace(secret, '[redacted]')
    return cleaned[:200]


@dataclass(frozen=True)
class VoiceBackend:
    """Provider configuration plus the transport. Everything is injectable."""

    groq_api_key: str = ''
    elevenlabs_api_key: str = ''
    groq_base_url: str = GROQ_BASE_URL
    elevenlabs_base_url: str = ELEVENLABS_BASE_URL
    transcribe_model: str = TRANSCRIBE_MODEL
    voice_id: str = VOICE_ID
    tts_model: str = TTS_MODEL
    timeout: float = PROVIDER_TIMEOUT_SECONDS
    user_agent: str = USER_AGENT
    http: HTTPCall = field(default=_urlopen)

    @classmethod
    def from_env(cls) -> 'VoiceBackend':
        """Keys come from the bridge EnvironmentFile; never from the request."""
        return cls(
            groq_api_key=os.environ.get('GROQ_API_KEY', ''),
            elevenlabs_api_key=os.environ.get('ELEVENLABS_API_KEY', ''),
            groq_base_url=os.environ.get('HERMES_VOICE_GROQ_BASE_URL', GROQ_BASE_URL),
            elevenlabs_base_url=os.environ.get('HERMES_VOICE_ELEVENLABS_BASE_URL', ELEVENLABS_BASE_URL),
            user_agent=os.environ.get('HERMES_VOICE_USER_AGENT', USER_AGENT),
            timeout=float(os.environ.get('HERMES_VOICE_TIMEOUT', PROVIDER_TIMEOUT_SECONDS)),
        )

    def __post_init__(self) -> None:
        for name, value in (('groq_base_url', self.groq_base_url),
                            ('elevenlabs_base_url', self.elevenlabs_base_url)):
            if not value.startswith(('https://', 'http://127.0.0.1', 'http://localhost')):
                raise ValueError(f'{name} must be https (loopback http is allowed for tests)')
        if not _VOICE_ID_PATTERN.match(self.voice_id):
            raise ValueError('voice_id must be a short opaque identifier')
        if self.timeout <= 0 or self.timeout > 120:
            raise ValueError('timeout must be between 0 and 120 seconds')

    @property
    def configured(self) -> bool:
        return bool(self.groq_api_key and self.elevenlabs_api_key)

    # -- transcription ---------------------------------------------------

    def transcribe(self, audio: bytes, mime_type: str) -> str:
        if not self.groq_api_key:
            raise VoiceProviderError(NOT_CONFIGURED)
        extension = ALLOWED_AUDIO_MIME[mime_type]
        boundary = '----hermes-' + secrets.token_hex(12)
        body = _multipart_body(boundary, audio, mime_type, extension, self.transcribe_model)
        headers = {
            'Authorization': 'Bearer ' + self.groq_api_key,
            'Content-Type': f'multipart/form-data; boundary={boundary}',
            'Accept': 'application/json',
            'User-Agent': self.user_agent,
        }
        status, payload, _ = self._post(self.groq_base_url.rstrip('/') + '/audio/transcriptions',
                                        body, headers, TRANSCRIBE_FAILED)
        if not 200 <= status < 300:
            raise VoiceProviderError(TRANSCRIBE_FAILED)
        try:
            parsed = json.loads(payload.decode('utf-8'))
        except (UnicodeDecodeError, ValueError):
            raise VoiceProviderError(TRANSCRIBE_FAILED) from None
        text = parsed.get('text') if isinstance(parsed, dict) else None
        if not isinstance(text, str):
            raise VoiceProviderError(TRANSCRIBE_FAILED)
        return text.strip()

    # -- synthesis -------------------------------------------------------

    def synthesize(self, text: str) -> Tuple[str, bytes]:
        if not self.elevenlabs_api_key:
            raise VoiceProviderError(NOT_CONFIGURED)
        url = (self.elevenlabs_base_url.rstrip('/')
               + '/text-to-speech/' + self.voice_id)
        body = json.dumps({'text': text, 'model_id': self.tts_model}).encode('utf-8')
        headers = {
            'xi-api-key': self.elevenlabs_api_key,
            'Content-Type': 'application/json',
            'Accept': 'audio/mpeg',
            'User-Agent': self.user_agent,
        }
        status, payload, response_headers = self._post(url, body, headers, SYNTHESIZE_FAILED)
        if not 200 <= status < 300:
            raise VoiceProviderError(SYNTHESIZE_FAILED)
        if not payload:
            raise VoiceProviderError(SYNTHESIZE_FAILED)
        content_type = ''
        for key, value in response_headers.items():
            if key.lower() == 'content-type':
                content_type = (value or '').split(';')[0].strip().lower()
                break
        # ElevenLabs answers audio/mpeg; a JSON body with a 200 is still a failure.
        if content_type == 'application/json':
            raise VoiceProviderError(SYNTHESIZE_FAILED)
        return 'audio/mpeg', payload

    def _post(self, url: str, body: bytes, headers: Dict[str, str], failure: str):
        try:
            status, payload, response_headers = self.http(url, body, headers, self.timeout)
        except VoiceProviderError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            raise VoiceProviderError(PROVIDER_UNREACHABLE) from None
        except Exception:
            # A transport that raised something unexpected must not become a 500
            # with a traceback; the caller sees a provider failure.
            raise VoiceProviderError(failure) from None
        if not isinstance(status, int):
            raise VoiceProviderError(failure)
        if not 200 <= status < 300:
            # A short, scrubbed, DEBUG-only reason so a 502 can be diagnosed on the
            # host without ever putting a credential in the log. The body itself is
            # never returned to the client.
            reason = _scrub(payload.decode('utf-8', 'replace').replace('\n', ' '),
                            self.groq_api_key, self.elevenlabs_api_key)
            _log.debug('voice provider returned %s: %s', status, reason)
        return status, payload, response_headers


def _multipart_body(boundary: str, audio: bytes, mime_type: str, extension: str,
                    model: str) -> bytes:
    """A minimal, fixed-shape multipart body: one file part, one model part."""
    lines = [
        f'--{boundary}\r\n'.encode(),
        f'Content-Disposition: form-data; name="model"\r\n\r\n{model}\r\n'.encode(),
        f'--{boundary}\r\n'.encode(),
        (f'Content-Disposition: form-data; name="file"; filename="audio.{extension}"\r\n'
         f'Content-Type: {mime_type}\r\n\r\n').encode(),
        audio,
        b'\r\n',
        f'--{boundary}--\r\n'.encode(),
    ]
    return b''.join(lines)


# ---------------------------------------------------------------------- schemas


class TranscribeRequest(BaseModel):
    """Bytes only. ``extra='forbid'`` is what keeps URLs and paths out."""

    model_config = ConfigDict(extra='forbid')

    mime_type: str
    content_base64: str


class TranscribeResponse(BaseModel):
    transcript: str


class SynthesizeRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')

    text: str


class SynthesizeResponse(BaseModel):
    mime_type: str
    content_base64: str


# ----------------------------------------------------------------------- router


def create_voice_router(runtime, backend: Optional[VoiceBackend] = None) -> APIRouter:
    router = APIRouter(prefix='/v1/voice', tags=['voice'])
    voice = backend or VoiceBackend.from_env()

    def authenticate(authorization: Optional[str]) -> str:
        return require_device(runtime, authorization)

    @router.post('/transcribe', response_model=TranscribeResponse)
    def transcribe(body: TranscribeRequest,
                   authorization: Optional[str] = Header(default=None)) -> TranscribeResponse:
        authenticate(authorization)
        audio = _decode_audio(body.mime_type, body.content_base64)
        try:
            transcript = voice.transcribe(audio, _normalized_mime(body.mime_type))
        except VoiceProviderError as exc:
            raise HTTPException(status_code=502, detail=exc.message) from None
        return TranscribeResponse(transcript=transcript)

    @router.post('/synthesize', response_model=SynthesizeResponse)
    def synthesize(body: SynthesizeRequest,
                   authorization: Optional[str] = Header(default=None)) -> SynthesizeResponse:
        authenticate(authorization)
        text = body.text
        if not text.strip():
            raise HTTPException(status_code=422, detail='text must not be blank')
        if len(text) > MAX_TEXT_CHARS:
            raise HTTPException(status_code=413,
                                detail=f'text exceeds {MAX_TEXT_CHARS} characters')
        try:
            mime_type, audio = voice.synthesize(text)
        except VoiceProviderError as exc:
            raise HTTPException(status_code=502, detail=exc.message) from None
        return SynthesizeResponse(mime_type=mime_type,
                                  content_base64=base64.b64encode(audio).decode('ascii'))

    return router


def _normalized_mime(raw: str) -> str:
    return (raw or '').strip().lower()


def _decode_audio(mime_type: str, content_base64: str) -> bytes:
    """Authenticate first, then validate: 415 for the type, 413 for the size."""
    normalized = _normalized_mime(mime_type)
    if normalized not in ALLOWED_AUDIO_MIME:
        raise HTTPException(status_code=415,
                            detail='audio must be mp3, m4a, wav or ogg')
    encoded = (content_base64 or '').strip()
    if not encoded:
        raise HTTPException(status_code=400, detail='audio data is required')
    # Base64 expands 3 bytes to 4; reject on the encoded length before allocating
    # the decode, so an oversized body is cheap to refuse.
    if len(encoded) > ((MAX_AUDIO_BYTES + 2) // 3) * 4 + 4:
        raise HTTPException(status_code=413,
                            detail=f'audio exceeds {MAX_AUDIO_BYTES // (1024 * 1024)} MiB')
    try:
        audio = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise HTTPException(status_code=400, detail='audio is not valid base64') from None
    if not audio:
        raise HTTPException(status_code=400, detail='audio data is required')
    if len(audio) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413,
                            detail=f'audio exceeds {MAX_AUDIO_BYTES // (1024 * 1024)} MiB')
    return audio
