import base64
import pytest

from hermes_bridge.attachment_validation import validate_attachment_request, AttachmentError, MAX_ATTACHMENT_BYTES


def data_url(data):
    return 'data:application/octet-stream;base64,' + base64.b64encode(data).decode()


def test_file_bytes_are_validated_and_host_paths_rejected():
    params = {'session_id': 'abc', 'name': 'note.txt', 'data_url': data_url(b'hello')}
    validate_attachment_request('file.attach', params)
    with pytest.raises(AttachmentError):
        validate_attachment_request('file.attach', {**params, 'path': '/etc/passwd'})


def test_image_valid_and_oversized_rejected():
    params = {'session_id': 'abc', 'filename': 'a.png', 'content_base64': base64.b64encode(b'x' * MAX_ATTACHMENT_BYTES).decode()}
    validate_attachment_request('image.attach_bytes', params)
    params['content_base64'] = base64.b64encode(b'x' * (MAX_ATTACHMENT_BYTES + 1)).decode()
    with pytest.raises(AttachmentError):
        validate_attachment_request('image.attach_bytes', params)


@pytest.mark.parametrize('changes', [
    {'name': '../secret'}, {'name': 'a\\b'}, {'data_url': 'http://localhost/'},
    {'data_url': 'data:application/octet-stream;base64,!!!!'}, {'data_url': data_url(b'')},
    {'staged_upload': {'path': '/etc/passwd'}}, {'session_id': ''},
])
def test_rejects_unsafe_or_malformed_fields(changes):
    params = {'session_id': 'abc', 'name': 'note.txt', 'data_url': data_url(b'x')}
    with pytest.raises(AttachmentError):
        validate_attachment_request('file.attach', {**params, **changes})


def test_attachment_ceiling_is_eight_mib():
    assert MAX_ATTACHMENT_BYTES == 8 * 1024 * 1024


@pytest.mark.parametrize('method,field,name_field', [
    ('file.attach', 'data_url', 'name'),
    ('image.attach_bytes', 'content_base64', 'filename'),
])
def test_exactly_eight_mib_is_accepted(method, field, name_field):
    payload = b'x' * (8 * 1024 * 1024)
    encoded = base64.b64encode(payload).decode()
    params = {'session_id': 'abc', name_field: 'big.bin', field: encoded if method == 'image.attach_bytes' else 'data:application/octet-stream;base64,' + encoded}
    validate_attachment_request(method, params)


@pytest.mark.parametrize('method,field,name_field', [
    ('file.attach', 'data_url', 'name'),
    ('image.attach_bytes', 'content_base64', 'filename'),
])
def test_one_byte_over_eight_mib_is_rejected(method, field, name_field):
    payload = b'x' * (8 * 1024 * 1024 + 1)
    encoded = base64.b64encode(payload).decode()
    params = {'session_id': 'abc', name_field: 'big.bin', field: encoded if method == 'image.attach_bytes' else 'data:application/octet-stream;base64,' + encoded}
    with pytest.raises(AttachmentError, match='8 MiB'):
        validate_attachment_request(method, params)


def test_path_methods_are_not_supported():
    with pytest.raises(AttachmentError):
        validate_attachment_request('image.attach', {'session_id': 'abc', 'path': '/etc/passwd'})
