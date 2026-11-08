from fastapi.testclient import TestClient
from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig


def test_access_token_is_not_a_ticket_and_null_removes_only_selected_bot(tmp_path):
    app = create_app(BridgeConfig(db_path=tmp_path / 'bridge.db'))
    app.state.bridge.registry.add_device(device_id='paired', name='phone', platform='ios', public_key='x', refresh_token='secret')
    with TestClient(app) as client:
        def token():
            return client.post('/v1/token', json={'device_id': 'paired', 'refresh_token': 'secret'}).json()
        def auth():
            return {'Authorization': 'Bearer ' + token()['ws_ticket']}
        assert client.put('/v1/bot-icons/a', json={'icon':'ember'}, headers={'Authorization': 'Bearer ' + token()['access_token']}).status_code == 401
        assert client.put('/v1/bot-icons/a', json={'icon':'ember'}, headers=auth()).status_code == 200
        assert client.put('/v1/bot-icons/b', json={'icon':'nova'}, headers=auth()).status_code == 200
        assert client.put('/v1/bot-icons/a', json={'icon':None}, headers=auth()).json()['icon'] is None
        assert client.get('/v1/bot-icons', headers=auth()).json() == {'icons': {'b': 'nova'}}
