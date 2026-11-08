from fastapi.testclient import TestClient

from hermes_bridge.app import create_app
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
        assert client.get('/v1/bot-icons', headers=headers('mac')).json() == {'icons': {'research': 'ember'}}
        assert client.put('/v1/bot-icons/research', headers=headers('mac'), json={'icon': 'unknown'}).status_code == 422
        revoked = headers('phone')
        runtime.registry.revoke('phone')
        assert client.get('/v1/bot-icons', headers=revoked).status_code == 401
    restarted = create_app(config)
    with TestClient(restarted) as client:
        t = client.post('/v1/token', json={'device_id': 'mac', 'refresh_token': 'secret-mac'}).json()['ws_ticket']
        assert client.get('/v1/bot-icons', headers={'Authorization': 'Bearer ' + t}).json() == {'icons': {'research': 'ember'}}


def test_all_gallery_icons_round_trip_and_unknown_is_rejected(tmp_path):
    from pathlib import Path
    import re

    source = (Path(__file__).resolve().parents[2] / 'Sources/OpenBotUI/BotIconGallery.swift').read_text()
    cases = re.search(r'public enum BotIcon:.*?\{\s*case ([^\n]+)', source, re.S).group(1)
    icons = [part.strip() for part in cases.split(',')]
    assert icons == ['ember', 'nova', 'cobalt', 'orbit', 'moss', 'dusk',
                     'beacon', 'pixel', 'rover', 'prism']
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
        assert client.get('/v1/bot-icons', headers=auth()).json() == {'icons': {icon: icon for icon in icons}}
        assert client.put('/v1/bot-icons/a', headers=auth(), json={'icon': 'not-an-icon'}).status_code == 422
