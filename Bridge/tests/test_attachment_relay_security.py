import asyncio
import json
from test_proxy import open_ws, recv_frame


def test_byte_only_and_extra_methods_cannot_bypass(bridge_factory, fake_gateway):
    bridge = bridge_factory(extra_client_methods=frozenset({'image.attach', 'pdf.attach', 'clipboard.paste'}))
    async def run():
        async with open_ws(bridge.ws_url(bridge.pair()['ticket'])) as ws:
            await recv_frame(ws)
            requests = [
                ('file.attach', {'session_id':'s', 'name':'a', 'data_url':'data:application/octet-stream;base64,eA==', 'path':'/etc/passwd'}),
                ('image.attach', {'session_id':'s', 'path':'/etc/passwd'}),
                ('pdf.attach', {'session_id':'s', 'path':'/etc/passwd'}),
                ('clipboard.paste', {'session_id':'s'}),
                ('file.attach', {'session_id':'s', 'name':'a', 'data_url':'data:application/octet-stream;base64,eA=='}),
            ]
            for i, (method, params) in enumerate(requests):
                await ws.send(json.dumps({'jsonrpc':'2.0','id':100+i,'method':method,'params':params}))
                response = await recv_frame(ws)
                if i < 4:
                    assert 'error' in response
                else:
                    assert response['id'] == 104  # fake gateway does not implement attachment
    asyncio.run(run())
    assert fake_gateway.wait_for(lambda f:f.get('id') == 104)
    assert not any(f.get('id') in (100,101,102,103) for f in fake_gateway.received)


def test_attachment_upstream_error_does_not_leak(bridge, fake_gateway):
    fake_gateway.auto_respond = False
    async def run():
        async with open_ws(bridge.ws_url(bridge.pair()['ticket'])) as ws:
            await recv_frame(ws)
            await ws.send(json.dumps({'jsonrpc':'2.0','id':201,'method':'file.attach','params':{'session_id':'s','name':'a','data_url':'data:application/octet-stream;base64,eA=='}}))
            fake_gateway.wait_for(lambda f:f.get('id') == 201)
            fake_gateway.push({'jsonrpc':'2.0','id':201,'error':{'code':5028,'message':'secret /host/private'}})
            response = await recv_frame(ws)
            assert 'secret' not in json.dumps(response)
            assert '/host/private' not in json.dumps(response)
    asyncio.run(run())
