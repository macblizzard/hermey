"""Voice relay: fresh-ticket auth, strict payload limits, and provider redaction.

The provider transport is injected, so nothing here reaches Groq or ElevenLabs (or
spends a cent). The live probes are recorded separately in ``docs/VOICE.md``.
"""
from __future__ import annotations

import base64
import json
import logging

import pytest
from fastapi.testclient import TestClient

from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig
from hermes_bridge.voice import (
    MAX_AUDIO_BYTES,
    MAX_TEXT_CHARS,
    VoiceBackend,
    VoiceProviderError,
    _urlopen,
)

SECRET_GROQ = 'gsk-secret-groq-do-not-leak'
SECRET_ELEVEN = 'eleven-canary-not-a-key'


class FakeHTTP:
    """Records every provider call and replies from a scripted queue."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls = []

    def __call__(self, url, body, headers, timeout):
        self.calls.append({'url': url, 'body': body, 'headers': dict(headers), 'timeout': timeout})
        if not self.replies:
            raise AssertionError('unexpected provider call')
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def _backend(http, **overrides):
    fields = dict(
        groq_api_key=SECRET_GROQ,
        elevenlabs_api_key=SECRET_ELEVEN,
        http=http,
    )
    fields.update(overrides)
    return VoiceBackend(**fields)


@pytest.fixture
def harness(tmp_path):
    http = FakeHTTP()
    app = create_app(BridgeConfig(db_path=tmp_path / 'bridge.db'), voice_backend=_backend(http))
    app.state.bridge.registry.add_device(device_id='phone', name='phone', platform='ios',
                                         public_key='test', refresh_token='refresh-phone')
    with TestClient(app) as client:
        def auth():
            response = client.post('/v1/token', json={'device_id': 'phone',
                                                      'refresh_token': 'refresh-phone'})
            assert response.status_code == 200
            return {'Authorization': 'Bearer ' + response.json()['ws_ticket']}

        yield client, http, auth


def _audio(boundary_note=b'x' * 64):
    return base64.b64encode(boundary_note).decode('ascii')


# --------------------------------------------------------------------------- auth


def test_requires_a_fresh_single_use_ticket(harness):
    client, http, auth = harness
    body = {'mime_type': 'audio/mp4', 'content_base64': _audio()}

    assert client.post('/v1/voice/transcribe', json=body).status_code == 401
    assert client.post('/v1/voice/transcribe', json=body,
                       headers={'Authorization': 'Bearer nope'}).status_code == 401

    # The access token from /v1/token is random and unverifiable: it is not a ticket.
    token = client.post('/v1/token', json={'device_id': 'phone', 'refresh_token': 'refresh-phone'}).json()
    assert client.post('/v1/voice/transcribe', json=body,
                       headers={'Authorization': 'Bearer ' + token['access_token']}).status_code == 401

    headers = auth()
    http.replies.append((200, b'ID3ok', {'content-type': 'audio/mpeg'}))
    assert client.post('/v1/voice/synthesize', json={'text': 'hello'}, headers=headers).status_code == 200
    assert client.post('/v1/voice/synthesize', json={'text': 'hello'}, headers=headers).status_code == 401
    assert len(http.calls) == 1

    # Revoking the device invalidates a ticket minted before the revoke.
    revoked = auth()
    client.app.state.bridge.registry.revoke('phone')
    assert client.post('/v1/voice/transcribe', json=body, headers=revoked).status_code == 401


def test_second_request_needs_its_own_ticket(harness):
    client, http, auth = harness
    http.replies.append((200, b'{"text":"one"}', {'content-type': 'application/json'}))
    first = auth()
    assert client.post('/v1/voice/transcribe',
                       json={'mime_type': 'audio/mpeg', 'content_base64': _audio()},
                       headers=first).json() == {'transcript': 'one'}
    assert client.post('/v1/voice/transcribe',
                       json={'mime_type': 'audio/mpeg', 'content_base64': _audio()},
                       headers=first).status_code == 401
    assert len(http.calls) == 1


# ---------------------------------------------------------------------- transcribe


def test_transcribe_calls_groq_with_multipart_and_returns_transcript(harness):
    client, http, auth = harness
    http.replies.append((200, b'{"text":"  hello from the phone  "}', {'content-type': 'application/json'}))
    response = client.post('/v1/voice/transcribe',
                           json={'mime_type': 'audio/mp4', 'content_base64': _audio(b'audio-bytes')},
                           headers=auth())
    assert response.status_code == 200
    assert response.json() == {'transcript': 'hello from the phone'}
    assert SECRET_GROQ not in response.text and SECRET_ELEVEN not in response.text

    call = http.calls[0]
    assert call['url'] == 'https://api.groq.com/openai/v1/audio/transcriptions'
    assert call['headers']['Authorization'] == 'Bearer ' + SECRET_GROQ
    # Plain urllib's UA was rejected by Cloudflare; the probe proved a custom UA works.
    assert call['headers']['User-Agent'] and 'python-urllib' not in call['headers']['User-Agent'].lower()
    assert b'name="model"' in call['body'] and b'whisper-large-v3' in call['body']
    assert b'filename="audio.mp4"' in call['body']
    assert b'audio/mp4' in call['body']
    assert b'audio-bytes' in call['body']


@pytest.mark.parametrize('mime, extension', [
    ('audio/mpeg', 'audio.mp3'),
    ('audio/mp4', 'audio.mp4'),
    ('audio/x-m4a', 'audio.m4a'),
    ('audio/wav', 'audio.wav'),
    ('audio/ogg', 'audio.ogg'),
])
def test_audio_allowlist_accepts_the_four_container_families(harness, mime, extension):
    client, http, auth = harness
    http.replies.append((200, b'{"text":"ok"}', {}))
    response = client.post('/v1/voice/transcribe',
                           json={'mime_type': mime, 'content_base64': _audio()},
                           headers=auth())
    assert response.status_code == 200
    assert f'filename="{extension}"'.encode() in http.calls[0]['body']


@pytest.mark.parametrize('mime', ['audio/flac', 'video/mp4', 'text/plain', '', 'audio/mpeg; charset=utf-8'])
def test_audio_type_is_rejected_with_415(harness, mime):
    client, http, auth = harness
    response = client.post('/v1/voice/transcribe',
                           json={'mime_type': mime, 'content_base64': _audio()},
                           headers=auth())
    assert response.status_code == 415
    assert http.calls == []


def test_audio_over_ten_mebibytes_is_413(harness):
    client, http, auth = harness
    too_big = base64.b64encode(b'\0' * (MAX_AUDIO_BYTES + 1)).decode('ascii')
    response = client.post('/v1/voice/transcribe',
                           json={'mime_type': 'audio/mpeg', 'content_base64': too_big},
                           headers=auth())
    assert response.status_code == 413
    assert http.calls == []


def test_exactly_ten_mebibytes_is_accepted(harness):
    client, http, auth = harness
    http.replies.append((200, b'{"text":"big"}', {}))
    at_limit = base64.b64encode(b'\0' * MAX_AUDIO_BYTES).decode('ascii')
    response = client.post('/v1/voice/transcribe',
                           json={'mime_type': 'audio/mpeg', 'content_base64': at_limit},
                           headers=auth())
    assert response.status_code == 200
    assert response.json() == {'transcript': 'big'}


@pytest.mark.parametrize('payload', [
    {'mime_type': 'audio/mpeg', 'content_base64': 'not base64!!'},
    {'mime_type': 'audio/mpeg', 'content_base64': 'data:audio/mpeg;base64,AAAA'},  # data URLs are not accepted
    {'mime_type': 'audio/mpeg', 'content_base64': ''},
    {'mime_type': 'audio/mpeg', 'content_base64': '/etc/passwd'},
])
def test_undecodable_or_url_shaped_content_is_refused(harness, payload):
    client, http, auth = harness
    response = client.post('/v1/voice/transcribe', json=payload, headers=auth())
    assert response.status_code in (400, 422)
    assert http.calls == []


def test_extra_fields_are_forbidden_so_no_path_or_url_can_be_smuggled(harness):
    client, http, auth = harness
    base = {'mime_type': 'audio/mpeg', 'content_base64': _audio()}
    for extra in ({'url': 'http://169.254.169.254/latest/meta-data'},
                  {'path': '/etc/passwd'},
                  {'audio_url': 'https://evil.example/x.mp3'}):
        response = client.post('/v1/voice/transcribe', json={**base, **extra}, headers=auth())
        assert response.status_code == 422
    assert http.calls == []


# ---------------------------------------------------------------------- synthesize


def test_synthesize_calls_elevenlabs_and_returns_mp3(harness):
    client, http, auth = harness
    audio = b'ID3\x03\x00\x00\x00fake-mp3-bytes'
    http.replies.append((200, audio, {'content-type': 'audio/mpeg'}))
    response = client.post('/v1/voice/synthesize', json={'text': 'Hello there.'}, headers=auth())
    assert response.status_code == 200
    payload = response.json()
    assert payload['mime_type'] == 'audio/mpeg'
    assert base64.b64decode(payload['content_base64']) == audio
    assert SECRET_ELEVEN not in response.text and SECRET_GROQ not in response.text

    call = http.calls[0]
    assert call['url'] == 'https://api.elevenlabs.io/v1/text-to-speech/EXAVITQu4vr4xnSDxMaL'
    assert call['headers']['xi-api-key'] == SECRET_ELEVEN
    assert call['headers']['Accept'] == 'audio/mpeg'
    assert json.loads(call['body']) == {'text': 'Hello there.', 'model_id': 'eleven_multilingual_v2'}


def test_synthesize_rejects_overlong_and_empty_text(harness):
    client, http, auth = harness
    too_long = 'a' * (MAX_TEXT_CHARS + 1)
    assert client.post('/v1/voice/synthesize', json={'text': too_long}, headers=auth()).status_code == 413
    assert client.post('/v1/voice/synthesize', json={'text': ''}, headers=auth()).status_code == 422
    assert client.post('/v1/voice/synthesize', json={'text': '   '}, headers=auth()).status_code == 422
    assert client.post('/v1/voice/synthesize', json={'text': 'x', 'voice': 'other'}).status_code == 422
    assert http.calls == []


def test_synthesize_accepts_text_at_the_limit(harness):
    client, http, auth = harness
    http.replies.append((200, b'ID3audio', {'content-type': 'audio/mpeg'}))
    response = client.post('/v1/voice/synthesize', json={'text': 'a' * MAX_TEXT_CHARS}, headers=auth())
    assert response.status_code == 200


# ------------------------------------------------------------------------ failures


def test_provider_http_error_is_502_and_never_echoes_the_key(harness, caplog):
    client, http, auth = harness
    leaky = json.dumps({'error': {'message': f'invalid api key {SECRET_GROQ}', 'code': 401}}).encode()
    http.replies.append((401, leaky, {'content-type': 'application/json'}))
    with caplog.at_level(logging.DEBUG):
        response = client.post('/v1/voice/transcribe',
                               json={'mime_type': 'audio/mpeg', 'content_base64': _audio()},
                               headers=auth())
    assert response.status_code == 502
    detail = response.json()['detail']
    assert SECRET_GROQ not in response.text and SECRET_ELEVEN not in response.text
    assert 'invalid api key' not in detail.lower()
    assert len(detail) <= 120
    assert all(SECRET_GROQ not in record.getMessage() for record in caplog.records)


def test_tts_provider_failure_is_502_with_a_short_message(harness):
    client, http, auth = harness
    http.replies.append((500, b'<html>upstream exploded</html>', {'content-type': 'text/html'}))
    response = client.post('/v1/voice/synthesize', json={'text': 'Hello.'}, headers=auth())
    assert response.status_code == 502
    assert 'exploded' not in response.text
    assert SECRET_ELEVEN not in response.text


def test_unreachable_provider_is_502(harness):
    client, http, auth = harness
    http.replies.append(OSError('connection reset'))
    response = client.post('/v1/voice/transcribe',
                           json={'mime_type': 'audio/mpeg', 'content_base64': _audio()},
                           headers=auth())
    assert response.status_code == 502
    assert 'connection reset' not in response.text


def test_garbage_provider_body_is_502(harness):
    client, http, auth = harness
    http.replies.append((200, b'not json at all', {'content-type': 'text/html'}))
    response = client.post('/v1/voice/transcribe',
                           json={'mime_type': 'audio/mpeg', 'content_base64': _audio()},
                           headers=auth())
    assert response.status_code == 502


def test_empty_audio_response_is_502(harness):
    client, http, auth = harness
    http.replies.append((200, b'', {'content-type': 'audio/mpeg'}))
    assert client.post('/v1/voice/synthesize', json={'text': 'Hello.'}, headers=auth()).status_code == 502


# ------------------------------------------------------------- injection / config


def test_base_urls_models_and_voice_are_injectable(harness):
    http = FakeHTTP((200, b'{"text":"custom"}', {}),
                    (200, b'ID3custom', {'content-type': 'audio/mpeg'}))
    app = create_app(BridgeConfig(db_path=harness[0].app.state.bridge.config.db_path),
                     voice_backend=_backend(http,
                                            groq_base_url='http://127.0.0.1:9/mock/v1',
                                            elevenlabs_base_url='http://127.0.0.1:9/mock/v1',
                                            transcribe_model='whisper-test',
                                            voice_id='testvoice',
                                            tts_model='test-tts-model'))
    app.state.bridge.registry.add_device(device_id='d', name='d', platform='ios',
                                         public_key='test', refresh_token='r')
    with TestClient(app) as client:
        token = client.post('/v1/token', json={'device_id': 'd', 'refresh_token': 'r'}).json()['ws_ticket']
        headers = {'Authorization': 'Bearer ' + token}
        assert client.post('/v1/voice/transcribe',
                           json={'mime_type': 'audio/ogg', 'content_base64': _audio()},
                           headers=headers).status_code == 200
        token = client.post('/v1/token', json={'device_id': 'd', 'refresh_token': 'r'}).json()['ws_ticket']
        assert client.post('/v1/voice/synthesize', json={'text': 'hi'},
                           headers={'Authorization': 'Bearer ' + token}).status_code == 200
    assert http.calls[0]['url'] == 'http://127.0.0.1:9/mock/v1/audio/transcriptions'
    assert b'whisper-test' in http.calls[0]['body']
    assert http.calls[1]['url'] == 'http://127.0.0.1:9/mock/v1/text-to-speech/testvoice'
    assert json.loads(http.calls[1]['body'])['model_id'] == 'test-tts-model'


def test_unconfigured_keys_fail_closed_without_calling_anything(tmp_path):
    http = FakeHTTP()
    app = create_app(BridgeConfig(db_path=tmp_path / 'bridge.db'),
                     voice_backend=_backend(http, groq_api_key='', elevenlabs_api_key=''))
    app.state.bridge.registry.add_device(device_id='d', name='d', platform='ios',
                                         public_key='test', refresh_token='r')
    with TestClient(app) as client:
        token = client.post('/v1/token', json={'device_id': 'd', 'refresh_token': 'r'}).json()['ws_ticket']
        headers = {'Authorization': 'Bearer ' + token}
        response = client.post('/v1/voice/transcribe',
                               json={'mime_type': 'audio/mpeg', 'content_base64': _audio()},
                               headers=headers)
        assert response.status_code == 502
        assert 'not configured' in response.json()['detail'].lower()
    assert http.calls == []


def test_provider_error_type_is_not_a_500():
    """The router maps VoiceProviderError; anything else would be a 500 and a stack trace."""
    assert issubclass(VoiceProviderError, Exception)


def test_default_transport_refuses_redirects_without_following_them():
    """A 3xx must not become a request to an address this host never configured."""
    import http.server
    import threading

    hits = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            hits.append(self.path)
            if self.path == '/first':
                self.send_response(302)
                self.send_header('Location', '/second')
                self.end_headers()
            else:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'followed')

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        status, payload, _ = _urlopen(f'http://127.0.0.1:{server.server_port}/first', b'', {}, 5)
    finally:
        server.shutdown()
        server.server_close()
    assert status == 302
    assert payload != b'followed'
    assert hits == ['/first']
