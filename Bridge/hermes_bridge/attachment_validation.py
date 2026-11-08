"""Validate the byte-only subset before forwarding attachment RPCs.

Call only after the normal websocket ticket/device authentication and before proxying.
Never allow the upstream path-bearing or staged-upload variants for remote clients.
"""
import base64
import binascii

MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024
_MAX_ATTACHMENT_LABEL = f'{MAX_ATTACHMENT_BYTES // (1024 * 1024)} MiB'
ATTACHMENT_METHODS = frozenset({'file.attach', 'image.attach_bytes'})


class AttachmentError(ValueError):
    pass


def validate_attachment_request(method: str, params: object) -> None:
    if method not in ATTACHMENT_METHODS or not isinstance(params, dict):
        raise AttachmentError('Invalid attachment request')
    allowed = {'session_id', 'filename', 'content_base64'} if method == 'image.attach_bytes' else {'session_id', 'name', 'data_url'}
    if set(params) - allowed:
        raise AttachmentError('Only byte uploads are permitted')
    sid = params.get('session_id')
    name = params.get('filename' if method == 'image.attach_bytes' else 'name')
    if not isinstance(sid, str) or not sid or len(sid) > 128:
        raise AttachmentError('Invalid session')
    if not isinstance(name, str) or not name or len(name.encode('utf-8')) > 255 or name in ('.', '..') or any(c in name for c in ('/', '\\', '\x00', '\n', '\r')):
        raise AttachmentError('Invalid attachment name')
    data = params.get('content_base64' if method == 'image.attach_bytes' else 'data_url')
    if not isinstance(data, str):
        raise AttachmentError('Attachment data is required')
    if method == 'file.attach':
        prefix = 'data:application/octet-stream;base64,'
        if not data.startswith(prefix):
            raise AttachmentError('Invalid attachment data URL')
        data = data[len(prefix):]
    if not data or len(data) > ((MAX_ATTACHMENT_BYTES + 2) // 3) * 4:
        raise AttachmentError(f'Attachment is empty or exceeds {_MAX_ATTACHMENT_LABEL}')
    try:
        decoded = base64.b64decode(data, validate=True)
    except (ValueError, binascii.Error):
        raise AttachmentError('Invalid attachment encoding') from None
    if not decoded or len(decoded) > MAX_ATTACHMENT_BYTES:
        raise AttachmentError(f'Attachment is empty or exceeds {_MAX_ATTACHMENT_LABEL}')
