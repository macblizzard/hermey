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


def test_every_shipped_face_round_trips_and_nonsense_is_rejected(tmp_path):
    """The eight bodies in the eleven palette colours, as one stored string.

    The values are read out of the design system's own sources rather than retyped here: a host that
    accepted a face the app cannot draw would answer with a picture nobody can render, and one that
    refused a face the app writes would lose a user's choice.
    """
    from pathlib import Path
    import re

    ui = Path(__file__).resolve().parents[2] / 'Sources/HermeyUI'
    shapes = re.search(r'case (hex, wedge, squircle, tablet, pebble, blob, teardrop, cloud)',
                       (ui / 'BotAvatarShape.swift').read_text()).group(1).split(', ')
    palette_source = (ui / 'BotAvatarPalette.swift').read_text()
    # Only the list: the reset/fallback entry repeats a hex below it.
    palette_block = palette_source[palette_source.index('colors: [BotAvatarColorDef] = ['):]
    palette = re.findall(r'hex: "(#[0-9A-F]{6})"', palette_block.split('\n    ]', 1)[0])
    assert len(shapes) == 8, shapes
    assert len(palette) == 11, palette

    app = create_app(BridgeConfig(db_path=tmp_path / 'bridge.db'))
    app.state.bridge.registry.add_device(device_id='paired', name='phone', platform='ios',
                                         public_key='x', refresh_token='secret')
    with TestClient(app) as client:
        def auth():
            ticket = client.post('/v1/token', json={'device_id': 'paired', 'refresh_token': 'secret'}).json()['ws_ticket']
            return {'Authorization': 'Bearer ' + ticket}

        for index, shape in enumerate(shapes):
            for colour in palette:
                bot = f'{shape}-{colour.lstrip("#").lower()}'
                avatar = f'{colour}::shape_{index}'
                response = client.put('/v1/bot-icons/' + bot, headers=auth(), json={'avatar': avatar})
                assert response.status_code == 200, (bot, response.text)
                assert response.json()['face'] == {'avatar': avatar}

        body = client.get('/v1/bot-icons', headers=auth()).json()
        assert len(body['faces']) == len(shapes) * len(palette)
        for index, shape in enumerate(shapes):
            for colour in palette:
                bot = f'{shape}-{colour.lstrip("#").lower()}'
                avatar = f'{colour}::shape_{index}'
                # The stored string is the answer; `shape`/`color` are the pair an older device
                # still reads, and it must not fail its decode over a row it does not know.
                assert body['faces'][bot] == {'avatar': avatar,
                                              'shape': f'shape_{index}',
                                              'color': colour}

        # A colour with no body at all is legal: the body then comes from the bot's id.
        assert client.put('/v1/bot-icons/colour-only', headers=auth(),
                          json={'avatar': '#FF781C'}).status_code == 200
        assert client.get('/v1/bot-icons', headers=auth()).json()['faces']['colour-only'] == {
            'avatar': '#FF781C', 'shape': '', 'color': '#FF781C'}

        # Anything else is refused rather than stored as a value nothing can draw.
        for avatar in ('FF781C', '#FF781C::shape_', 'data:image/png;base64,AA', '#GGGGGG'):
            assert client.put('/v1/bot-icons/colour-only', headers=auth(),
                              json={'avatar': avatar}).status_code == 422, avatar
        # A half pair is still a malformed request, not a silent clear.
        assert client.put('/v1/bot-icons/colour-only', headers=auth(),
                          json={'shape': 'ember'}).status_code == 422


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
