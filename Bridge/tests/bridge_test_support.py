"""Constants shared by the bridge tests.

Why this file exists: `conftest.py` is not an importable module name that survives more than one
test directory in a single pytest run. Both this suite and `Tools/qa` have a `conftest.py`, so
`from conftest import X` in a test resolves to whichever one pytest registered last — the combined
run `pytest Bridge/tests Tools/qa` failed with "cannot import name 'TEST_PUBLIC_KEY' from
'conftest'". Shared values therefore live here, under a unique module name, and both conftest and
the tests import from it.
"""

from __future__ import annotations

import base64

#: The token the fake gateway expects upstream. Deliberately distinctive: the audit tests assert it
#: never appears in a log line, a response body or the device database.
GATEWAY_TOKEN = "gateway-token-9f3c2a-do-not-leak"

#: 32 zero bytes, base64. The bridge validates the shape of a pairing public key (Ed25519 = 32
#: bytes) and rejects anything else — a 33-byte value is refused, which is why this is exactly 32.
TEST_PUBLIC_KEY = base64.b64encode(b"\x11" * 32).decode("ascii")
