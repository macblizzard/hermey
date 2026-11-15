"""A banner's picture: the app renders the face, the host keeps the bytes, the relay shows them.

Three things are worth pinning here:

* the image is only accepted as a PNG (a text file served as `image/png` is worse than no image);
* an unchanged face costs a request and no write, because both sides carry the hash;
* the GET is unauthenticated — the relay app fetches it and holds no credential — so it must be
  impossible to read anything but the face of a named bot.
"""
from __future__ import annotations

import base64

import httpx
import pytest

from hermes_bridge import push_icons

#: A 1×1 PNG. Small enough to inline, real enough to pass the magic-byte check.
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
)


@pytest.fixture(autouse=True)
def icon_dir(tmp_path, monkeypatch):
    """Keep renders out of the real `/var/lib/hermey/push-icons`."""
    monkeypatch.setattr(push_icons, "ICON_DIR", tmp_path / "icons")
    return tmp_path / "icons"


@pytest.fixture
def device(bridge):
    paired = bridge.pair()

    def call(method, path, body=None, auth=True):
        headers = {}
        if auth:
            headers["Authorization"] = f"Bearer {bridge.mint_ticket(paired['device_id'])}"
        return httpx.request(method, f"{bridge.base_url}{path}", json=body, headers=headers,
                             timeout=10)

    return call


def _upload(device, profile="cody", sha=None):
    return device("PUT", f"/v1/push/icon/{profile}",
                  {"png": base64.b64encode(PNG).decode(), "sha256": sha})


class TestWhereTheBytesLive:
    def test_the_directory_is_one_the_unit_may_write(self):
        # `ReadWritePaths=/var/lib/hermey /root/.hermes/profiles`: anywhere else and every upload is
        # EROFS on the deployed host while the tests happily write into tmp_path.
        # Read from the module's source, not the attribute: the fixture above patches ICON_DIR.
        from pathlib import Path

        source = Path(push_icons.__file__).read_text(encoding="utf-8")
        assert 'ICON_DIR = Path("/var/lib/hermey/' in source


class TestUpload:
    def test_a_face_is_stored_and_served(self, device, icon_dir):
        response = _upload(device)

        assert response.status_code == 200, response.text
        assert response.json()["changed"] is True
        assert (icon_dir / "cody.png").read_bytes() == PNG

        fetched = device("GET", "/v1/push/icon/cody.png", auth=False)
        assert fetched.status_code == 200
        assert fetched.headers["content-type"] == "image/png"
        assert fetched.content == PNG

    def test_the_same_face_is_not_written_twice(self, device):
        first = _upload(device).json()
        again = _upload(device, sha=first["sha256"])

        assert again.status_code == 200
        assert again.json()["changed"] is False

    def test_a_different_face_replaces_it(self, device, icon_dir):
        _upload(device)
        other = PNG + b"\0"  # different bytes, and the hash the client sent does not match
        response = device("PUT", "/v1/push/icon/cody",
                          {"png": base64.b64encode(other).decode(), "sha256": "not-the-hash"})

        assert response.json()["changed"] is True
        assert (icon_dir / "cody.png").read_bytes() == other

    @pytest.mark.parametrize("body", [
        {"png": "not-base64!!"},
        {"png": base64.b64encode(b"hello, not a png").decode()},
        {"png": ""},
    ])
    def test_only_a_png_is_accepted(self, device, body):
        assert device("PUT", "/v1/push/icon/cody", body).status_code == 422

    def test_an_oversized_image_is_refused(self, device):
        big = PNG + b"\0" * (push_icons.MAX_BYTES + 1)
        response = device("PUT", "/v1/push/icon/cody",
                          {"png": base64.b64encode(big).decode()})

        assert response.status_code == 413

    def test_a_profile_name_cannot_escape_the_directory(self, device):
        assert _upload(device, profile="..%2fetc").status_code in (404, 422)

    def test_upload_needs_a_device(self, device, icon_dir):
        response = device("PUT", "/v1/push/icon/cody",
                          {"png": base64.b64encode(PNG).decode()}, auth=False)

        assert response.status_code == 401
        assert not icon_dir.exists() or not any(icon_dir.iterdir())


class TestFetch:
    def test_an_unknown_bot_has_no_face(self, device):
        assert device("GET", "/v1/push/icon/nobody.png", auth=False).status_code == 404

    def test_the_url_the_host_hands_the_relay_points_at_that_route(self, device, monkeypatch):
        from hermes_bridge import push

        _upload(device, profile="aria")
        monkeypatch.setattr(push, "ICON_BASE", "https://host:8444/icons")

        assert push.icon_url("aria") == "https://host:8444/icons/aria.png"
        # No render yet means no image, not a URL that 404s inside a notification.
        assert push.icon_url("unrendered") == ""
