"""One publisher, atomic staging, and a publish that proves itself over the wire.

Each of these pins a failure that shipped: a served `source.json` at 0.1.52 while the directory held
0.1.482, a 10 MB disk image downloadable mid-copy, and a Mac install that ran the previous build
because its one-and-only filename had not been rewritten.
"""

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE = ROOT / "Tools" / "release"
DIST = (RELEASE / "publish_dist.py").read_text(encoding="utf-8")
ALTSTORE = (RELEASE / "publish_altstore.py").read_text(encoding="utf-8")
SOURCE = (RELEASE / "publish_source.py").read_text(encoding="utf-8")
SERVE = (RELEASE / "serve_dist.py").read_text(encoding="utf-8")


class OneWriter(unittest.TestCase):
    def test_the_served_directory_has_exactly_one_writer(self) -> None:
        # `publish_altstore.py` publishes to GitHub; the mirror half is a single call into
        # `publish_dist`. Any copy of an artifact or a manifest written here again is drift waiting
        # to happen.
        self.assertIn("import publish_dist", ALTSTORE)
        self.assertIn("publish_dist.publish(", ALTSTORE)
        # Everything the mirror half does, and nothing else: the GitHub-release staging below it may
        # copy artifacts freely, the served directory may not be written here at all.
        block = ALTSTORE.split("if args.mirror_to:", 1)[1].split("icon = Path(__file__)", 1)[0]
        self.assertIn("publish_dist.publish(", block)
        for forbidden in ("copy2", "copyfile", "write_text", ".replace(", "open("):
            self.assertNotIn(forbidden, block, f"the mirror block must not touch files: {forbidden}")

    def test_the_second_publisher_is_gone(self) -> None:
        self.assertFalse((RELEASE / "publish_latest.sh").exists())
        self.assertNotIn("def main()", SOURCE, "publish_source is a library now")
        self.assertIn("publish_source.py is a library now", SOURCE)

    def test_both_manifests_are_generated_from_the_staged_file(self) -> None:
        # size and sha256 are measured on the bytes that were just renamed into place, not read
        # from the arguments and not hand-edited.
        self.assertIn("size, sha = digest_of(staged_ipa)", DIST)
        self.assertIn('"size": size', DIST)
        self.assertIn('"sha256": sha', DIST)
        self.assertIn('for manifest in MANIFEST_NAMES:', DIST)
        self.assertIn('MANIFEST_NAMES = ("altstore.json", "source.json")', DIST)
        self.assertIn('write_atomic(directory / "index.html"', DIST)


class AtomicStaging(unittest.TestCase):
    def test_artifacts_are_renamed_into_place(self) -> None:
        self.assertIn('incoming = directory / f".incoming-{os.getpid()}-{name}"', DIST)
        self.assertIn("os.replace(incoming, target)", DIST)
        self.assertIn("os.fsync", DIST)

    def test_manifests_are_renamed_into_place(self) -> None:
        self.assertIn('incoming = path.with_name(f".incoming-{os.getpid()}-{path.name}")', DIST)
        self.assertIn("os.replace(incoming, path)", DIST)

    def test_nothing_is_written_directly_to_its_published_name(self) -> None:
        # `write_text` straight onto `source.json` is the shape that leaves a half-written manifest
        # for a sideloader to parse.
        body = DIST.split("def stage(", 1)[1]
        self.assertNotIn('target.write_', body)
        self.assertNotIn('(directory / "source.json").write_text', DIST)


class VerifiedOverTheWire(unittest.TestCase):
    def test_every_advertised_url_is_fetched_back(self) -> None:
        self.assertIn("def verify(", DIST)
        self.assertIn("for name in names:", DIST)
        self.assertIn("fetch(f\"{base}/{name}?{stamp}\"", DIST)

    def test_the_check_compares_bytes_not_just_status(self) -> None:
        self.assertIn("served {len(body)} bytes, on disk {expected_size}", DIST)
        self.assertIn("served bytes differ from the file on disk", DIST)

    def test_the_manifests_must_name_the_build_that_was_just_published(self) -> None:
        self.assertIn('if str(newest.get("buildVersion")) != build', DIST)
        self.assertIn("which this publish did not stage", DIST)

    def test_a_mismatch_fails_the_publish(self) -> None:
        self.assertIn('raise SystemExit("publish verification failed:', DIST)
        self.assertIn("def verify(", DIST)
        self.assertIn("attempts: int = 6", DIST, "the origin is a TLS front end; retry the check")

    def test_the_publish_verifies_by_default(self) -> None:
        self.assertIn("verify_wire: bool = True", DIST)
        self.assertIn("if verify_wire:", DIST)


class VersionedDiskImage(unittest.TestCase):
    def test_the_dmg_filename_carries_the_version(self) -> None:
        self.assertIn('dmg_name = f"Hermey-macOS-{version}.dmg"', DIST)

    def test_the_stable_name_survives_as_an_alias_of_the_same_build(self) -> None:
        self.assertIn('STABLE_DMG_ALIAS = "Hermey-macOS-unsigned.dmg"', DIST)
        self.assertIn("stage(dmg, directory, STABLE_DMG_ALIAS)", DIST)

    def test_the_landing_page_lists_the_versioned_name_first(self) -> None:
        page = DIST.split("def landing_page(", 1)[1].split("def publish(", 1)[0]
        self.assertIn("html.escape(dmg_name)", page)
        self.assertIn("same build, stable name", page)


class OneDirectory(unittest.TestCase):
    def test_the_server_default_is_the_served_directory(self) -> None:
        # `/srv/hermey-dist` was a second copy nobody served; it is not referenced anywhere now.
        self.assertIn('default="/srv/hermes-apps-dist"', SERVE)
        self.assertNotIn("/srv/hermey-dist", SERVE)

    def test_the_release_tools_name_only_the_served_directory(self) -> None:
        for path in RELEASE.glob("*.py"):
            self.assertNotIn("/srv/hermey-dist", path.read_text(encoding="utf-8"),
                             f"{path.name} still names the retired directory")
        shell = (RELEASE / "publish_github.sh").read_text(encoding="utf-8")
        self.assertNotIn("/srv/hermey-dist", shell)


if __name__ == "__main__":
    unittest.main()
