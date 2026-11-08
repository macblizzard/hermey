"""Public-key handling for pairing.

The app registers an Ed25519 public key when it claims a pairing code. Validating
it here (32 raw bytes, standard or URL-safe base64, padding optional) catches a
client that sends a placeholder or a private key by mistake, and gives the
registry one canonical form to store.
"""

from __future__ import annotations

import base64
import binascii
import re

_B64URL = re.compile(r"^[A-Za-z0-9_-]+={0,2}$")
_B64STD = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")

ED25519_PUBLIC_KEY_BYTES = 32


class InvalidPublicKey(ValueError):
    pass


def normalize_public_key(raw: str) -> str:
    """Return canonical unpadded base64url of a 32-byte Ed25519 public key."""
    if not isinstance(raw, str):
        raise InvalidPublicKey("public key must be a string")
    value = raw.strip()
    if not value or len(value) > 512:
        raise InvalidPublicKey("public key has an invalid length")

    if _B64URL.fullmatch(value):
        normalized = value.replace("-", "+").replace("_", "/")
    elif _B64STD.fullmatch(value):
        normalized = value
    else:
        raise InvalidPublicKey("public key is not base64")

    padded = normalized + "=" * (-len(normalized) % 4)
    try:
        data = base64.b64decode(padded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise InvalidPublicKey("public key is not valid base64") from exc
    if len(data) != ED25519_PUBLIC_KEY_BYTES:
        raise InvalidPublicKey("Ed25519 public keys are 32 bytes")
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")
