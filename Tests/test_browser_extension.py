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

    def test_the_reply_is_an_id_and_a_boolean(self) -> None:
        assert "send({ id: message.id, ok })" in SOURCE

    def test_nothing_is_logged(self) -> None:
        assert "console.log" not in SOURCE, "a value could reach a log through a debug print"

    def test_nothing_is_written_to_storage(self) -> None:
        for line in SOURCE.splitlines():
            if "chrome.storage" in line:
                assert "value" not in line.lower(), line

    def test_it_uses_the_native_setter(self) -> None:
        """A plain `el.value =` leaves React-controlled forms empty and looks like a wrong password."""
        assert 'getOwnPropertyDescriptor(proto, "value").set' in SOURCE
