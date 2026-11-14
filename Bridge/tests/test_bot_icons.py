from fastapi.testclient import TestClient

from hermes_bridge.app import create_app
from hermes_bridge.bot_icons import LEGACY
from hermes_bridge.config import BridgeConfig


def test_paired_devices_share_icons_and_revoked_or_replayed_tickets_fail(tmp_path):
    config = BridgeConfig(db_path=tmp_path / 'bridge.db')
    app = create_app(config)
    runtime = app.state.bridge
    for device in ('phone', 'mac'):
        runtime.registry.add_device(device_id=device, name=device, platform='test',
                                    public_key='test', refresh_token='secret-' + device)
    with TestClient(app) as client:
        def ticket(device):
            response = client.post('/v1/token', json={'device_id': device, 'refresh_token': 'secret-' + device})
            return response.json()['ws_ticket']
        def headers(device):
            return {'Authorization': 'Bearer ' + ticket(device)}
        assert client.get('/v1/bot-icons').status_code == 401
        reused = headers('phone')
        assert client.put('/v1/bot-icons/research', headers=reused, json={'icon': 'ember'}).status_code == 200
        assert client.get('/v1/bot-icons', headers=reused).status_code == 401
        # Both at once: `faces` is what the current apps read, `icons` is what a device that has
        # not been updated yet reads. Neither may be dropped while both exist.
        assert client.get('/v1/bot-icons', headers=headers('mac')).json() == {
            'faces': {'research': {'shape': 'ember', 'color': 'orange'}},
            'icons': {'research': 'ember'},
        }
        assert client.put('/v1/bot-icons/research', headers=headers('mac'), json={'icon': 'unknown'}).status_code == 422
        revoked = headers('phone')
        runtime.registry.revoke('phone')
        assert client.get('/v1/bot-icons', headers=revoked).status_code == 401
    restarted = create_app(config)
    with TestClient(restarted) as client:
        t = client.post('/v1/token', json={'device_id': 'mac', 'refresh_token': 'secret-mac'}).json()['ws_ticket']
        assert client.get('/v1/bot-icons', headers={'Authorization': 'Bearer ' + t}).json() == {
            'faces': {'research': {'shape': 'ember', 'color': 'orange'}},
            'icons': {'research': 'ember'},
        }


def test_all_gallery_icons_round_trip_and_unknown_is_rejected(tmp_path):
    from pathlib import Path
    import re

    source = (Path(__file__).resolve().parents[2] / 'Sources/OpenBotUI/BotIconGallery.swift').read_text()
    # The enum's `case` lines, comments stripped: the doc comment above the first line moved the
    # old single-regex parse into the colour enum next door.
    block = re.search(r'public enum BotIcon:.*?\n\}', source, re.S).group(0)
    cases = [line for line in block.splitlines() if line.strip().startswith('case ')]
    icons = [name.strip() for line in cases for name in line.strip()[len('case '):].split(',')]
    icons = [name for icon_part in icons for name in [icon_part.strip()] if name]
    assert icons == ['ember', 'nova', 'cobalt', 'orbit', 'moss', 'dusk', 'beacon', 'pixel',
                     'rover', 'prism', 'lump', 'mushroom', 'blob', 'capsule', 'droplet',
                     'scallop'], icons
    app = create_app(BridgeConfig(db_path=tmp_path / 'bridge.db'))
    app.state.bridge.registry.add_device(device_id='paired', name='phone', platform='ios',
                                         public_key='x', refresh_token='secret')
    with TestClient(app) as client:
        def auth():
            ticket = client.post('/v1/token', json={'device_id': 'paired', 'refresh_token': 'secret'}).json()['ws_ticket']
            return {'Authorization': 'Bearer ' + ticket}
        for icon in icons:
            response = client.put('/v1/bot-icons/' + icon, headers=auth(), json={'icon': icon})
            assert response.status_code == 200, (icon, response.text)
        body = client.get('/v1/bot-icons', headers=auth()).json()
        assert body['icons'] == {icon: icon for icon in icons}
        # An icon-only write reads back as that icon's own colour, so no face moves on upgrade.
        assert body['faces'] == {icon: {'shape': icon, 'color': LEGACY[icon]} for icon in icons}
        assert client.put('/v1/bot-icons/a', headers=auth(), json={'icon': 'not-an-icon'}).status_code == 422


def test_a_face_is_a_shape_and_a_colour_and_half_a_pair_is_refused(tmp_path):
    app = create_app(BridgeConfig(db_path=tmp_path / 'bridge.db'))
    app.state.bridge.registry.add_device(device_id='paired', name='phone', platform='ios',
                                         public_key='x', refresh_token='secret')
    with TestClient(app) as client:
        def auth():
            ticket = client.post('/v1/token', json={'device_id': 'paired',
                                                    'refresh_token': 'secret'}).json()['ws_ticket']
            return {'Authorization': 'Bearer ' + ticket}

        # Any of the ten shapes in any of the twelve colours — the point of the pair.
        assert client.put('/v1/bot-icons/beacon', headers=auth(),
                          json={'shape': 'beacon', 'color': 'teal'}).status_code == 200
        assert client.put('/v1/bot-icons/beacon-pink', headers=auth(),
                          json={'shape': 'ember', 'color': 'pink'}).status_code == 200
        faces = client.get('/v1/bot-icons', headers=auth()).json()['faces']
        assert faces['beacon'] == {'shape': 'beacon', 'color': 'teal'}
        assert faces['beacon-pink'] == {'shape': 'ember', 'color': 'pink'}

        # Half a pair would silently clear a choice nobody asked to clear.
        assert client.put('/v1/bot-icons/beacon', headers=auth(),
                          json={'shape': 'prism'}).status_code == 422
        assert client.put('/v1/bot-icons/beacon', headers=auth(),
                          json={'color': 'ruby'}).status_code == 422
        assert client.get('/v1/bot-icons', headers=auth()).json()['faces']['beacon'] == {
            'shape': 'beacon', 'color': 'teal'}

        # Clearing is its own request, and it clears both spellings.
        assert client.put('/v1/bot-icons/beacon', headers=auth(), json={}).status_code == 200
        body = client.get('/v1/bot-icons', headers=auth()).json()
        assert 'beacon' not in body['faces'] and 'beacon' not in body['icons']
