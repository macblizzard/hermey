"""The extension is a fill target, not a password store.

It is the one component that touches both a secret and a web page, so its guarantees are pinned here
rather than trusted: it talks to the bridge at a known path, it answers with an id and a boolean, and it
never keeps or logs what it was given.
"""

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXT = ROOT / "browser-extension"
SOURCE = (EXT / "background.js").read_text(encoding="utf-8")


class TestTheManifest:
    def test_it_is_a_valid_mv3_manifest(self) -> None:
        manifest = json.loads((EXT / "manifest.json").read_text(encoding="utf-8"))
        assert manifest["manifest_version"] == 3
        assert manifest["background"]["service_worker"] == "background.js"

    def test_it_asks_only_for_what_filling_needs(self) -> None:
        manifest = json.loads((EXT / "manifest.json").read_text(encoding="utf-8"))
        assert set(manifest["permissions"]) <= {"scripting", "tabs", "storage", "alarms"}
        assert "activeTab" not in manifest["permissions"]

    def test_every_file_it_names_exists(self) -> None:
        manifest = json.loads((EXT / "manifest.json").read_text(encoding="utf-8"))
        for relative in (manifest["background"]["service_worker"],
                         manifest["action"]["default_popup"]):
            assert (EXT / relative).is_file(), relative


class TestItCannotKeepASecret:
    def test_it_speaks_to_the_bridge_the_bridge_expects(self) -> None:
        assert "/v1/browser/ws" in SOURCE, "the extension and the bridge must agree on the path"

    def test_the_reply_carries_an_id_and_no_value(self) -> None:
        """The reply names the call and says whether it worked (and, for a probe, the page's shape).

        It must never echo what was filled — that is the line between "the login worked" and "the bot has
        the password".
        """
        assert "send({ id: message.id, ...reply })" in SOURCE
        for line in SOURCE.splitlines():
            if "send({" in line and "value" in line:
                raise AssertionError(f"a reply line mentions a value: {line.strip()}")

    def test_nothing_is_logged(self) -> None:
        assert "console.log" not in SOURCE, "a value could reach a log through a debug print"

    def test_nothing_is_written_to_storage(self) -> None:
        for line in SOURCE.splitlines():
            if "chrome.storage" in line:
                assert "value" not in line.lower(), line

    def test_it_uses_the_native_setter(self) -> None:
        """A plain `el.value =` leaves React-controlled forms empty and looks like a wrong password."""
        assert 'getOwnPropertyDescriptor(proto, "value").set' in SOURCE


class TestSixBoxCodes:
    """Doctolib's Keycloak asks for a 6-digit code as six one-character inputs.

    Filling the whole code into the first box is silently wrong — it looks exactly like a wrong code, and
    the owner retries a code that was never entered. Verified against the live page: 6 boxes, 6 filled.
    """

    def test_it_distributes_digits_across_boxes(self) -> None:
        assert "perBox" in SOURCE, "no distribution path for a multi-box one-time code"
        assert "autocomplete*=one-time-code" in SOURCE

    def test_it_still_fills_a_single_code_field(self) -> None:
        """A page with one code input must keep working: the spread only runs above one box."""
        assert "boxes.length > 1" in SOURCE
