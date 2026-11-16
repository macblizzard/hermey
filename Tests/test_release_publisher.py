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

class TwoDestinationsOneDocument(unittest.TestCase):
    """The GitHub documents and the served documents come from one generator, by adapter."""

    def test_the_github_document_is_not_assembled_by_hand(self) -> None:
        self.assertIn("publish_dist.source_document(", ALTSTORE)
        self.assertIn("publish_dist.Destination(", ALTSTORE)
        # The old shape: a dict literal built inline from `app.update({...})`.
        self.assertNotIn('app.update({"', ALTSTORE)
        self.assertIn('base_url=f"https://github.com/{args.repo}/releases/download/{tag}"', ALTSTORE)

    def test_only_the_destination_differs(self) -> None:
        dist = DIST
        for field in ('name: str', 'base_url: str', 'tint: str', 'icon_url: str | None',
                      'header_url: str | None', 'source_url: str | None'):
            self.assertIn(field, dist.split("class Destination", 1)[1].split("def ", 1)[0])

    def test_the_mirror_document_does_not_advertise_a_github_source_url(self) -> None:
        # A mirror manifest that names the release asset tells a sideloader to leave the mirror.
        self.assertIn('if destination.source_url:', DIST)
        self.assertIn('document["sourceURL"] = destination.source_url', DIST)


class TheDocumentedMacLinkIsPublished(unittest.TestCase):
    def test_the_publish_passes_the_downloads_repo(self) -> None:
        shell = (RELEASE / "publish_github.sh").read_text(encoding="utf-8")
        self.assertIn("DOWNLOADS_REPO", shell)
        self.assertIn('DOWNLOAD_ARGS=(--downloads-repo "$DOWNLOADS_REPO")', shell)
        self.assertIn('${DOWNLOAD_ARGS[@]+"${DOWNLOAD_ARGS[@]}"}', shell)

    def test_the_downloads_repo_gets_a_versioned_name_andthe_alias(self) -> None:
        self.assertIn('versioned = f"Hermey-macOS-{safe_component(version)}.dmg"', ALTSTORE)
        self.assertIn("shutil.copy2(dmg, work / publish_dist.STABLE_DMG_ALIAS)", ALTSTORE)

    def test_the_commit_is_verified_even_though_pages_lags(self) -> None:
        self.assertIn("sync_store.verify_pages_file(slug, versioned, size,", ALTSTORE)
        self.assertIn("sync_store.git_blob_sha(dmg.read_bytes())", ALTSTORE,
                      "a >1 MB file cannot be read back through the contents API: compare the blob SHA")
        store = (RELEASE / "sync_store.py").read_text(encoding="utf-8")
        self.assertIn("def verify_pages_file(", store)
        self.assertIn("def git_blob_sha(", store)
        self.assertIn("GitHub builds and publishes a Pages site", store)

    def test_the_docs_state_the_pages_lag_instead_of_implying_match(self) -> None:
        docs = (ROOT / "docs" / "APPS.md").read_text(encoding="utf-8")
        self.assertIn("Pages is a mirror of the release, and the release itself is always current", docs)


class TheReleaseAssetIsVerified(unittest.TestCase):
    def test_the_uploaded_asset_is_fetched_back(self) -> None:
        self.assertIn('publish_dist.verify_url(download, len(data), digest, "release asset"', ALTSTORE)
        self.assertIn("attempts=16", ALTSTORE, "a fresh asset 404s on the CDN for ~30 s")

    def test_the_skip_is_explicit_and_named(self) -> None:
        self.assertIn('"--skip-release-verify"', ALTSTORE)

def _plist(payload: dict) -> bytes:
    import plistlib
    return plistlib.dumps(payload)


class TheSideloadSourceDescribesThePhoneNotTheMac(unittest.TestCase):
    """`altstore.json` on the Pages mirror named the DMG, so an iOS update downloaded a disk image.

    The mirror publishes two artifacts into one directory: the disk image and the sideload source a
    phone reads. Reusing the mac-flavoured entry for the phone's manifest is the defect; the IPA's
    own numbers now build that entry, and a non-IPA identifier is refused.
    """

    def test_the_downloads_repo_writes_the_ipa_entry(self) -> None:
        block = ALTSTORE.split("def push_to_downloads_repo(", 1)[1].split("def main(", 1)[0]
        self.assertIn("ios_entry: dict", block)
        self.assertIn("source_document(\n                info, ios_entry,", block)
        self.assertNotIn("source_document(\n                info, entry,", block)

    def test_a_non_ipa_identifier_is_refused(self) -> None:
        block = ALTSTORE.split("def push_to_downloads_repo(", 1)[1].split("def main(", 1)[0]
        self.assertIn('advertised.lower().endswith(".ipa")', block)
        self.assertIn("which is not the IPA", block)

    def test_the_ios_entry_is_built_from_the_ipa_bytes(self) -> None:
        tail = ALTSTORE.split("if args.downloads_repo and", 1)[1]
        self.assertIn('"downloadURL": download,', tail)
        self.assertIn('"size": len(data),', tail)
        self.assertIn('"sha256": digest,', tail)
        self.assertNotIn("dmg_size", tail.split("published = push_to_downloads_repo", 1)[0])


class TheSourceNamesTheAppBundleNotANestedOne(unittest.TestCase):
    """The published source advertised `hermey.HermeyUI.resources` — a nested resource bundle.

    A sideloading app matches an update to the installed app by bundle identifier, so the wrong one
    is not cosmetic: "update" installs a stranger. The first `Info.plist` in the zip was the nested
    bundle's, because it sorts inside the .app.
    """

    def _fake_ipa(self) -> pathlib.Path:
        import tempfile, zipfile
        directory = pathlib.Path(tempfile.mkdtemp())
        ipa = directory / "Hermey-test.ipa"
        nested = {
            "CFBundleIdentifier": "hermey.HermeyUI.resources",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "BNDL",
        }
        app = {
            "CFBundleIdentifier": "dev.hermey.app.mobile",
            "CFBundleShortVersionString": "0.1.516",
            "CFBundleVersion": "516",
            "CFBundlePackageType": "APPL",
        }
        with zipfile.ZipFile(ipa, "w") as archive:
            # The nested bundle first, in the order a real archive carries it.
            archive.writestr("Payload/Hermey.app/HermesApps_HermeyUI.bundle/Info.plist", _plist(nested))
            archive.writestr("Payload/Hermey.app/Info.plist", _plist(app))
        return ipa

    def test_the_app_plist_wins(self) -> None:
        import sys
        sys.path.insert(0, str(RELEASE))
        import publish_source
        info = publish_source.read_ipa(self._fake_ipa())
        self.assertEqual(info["CFBundleIdentifier"], "dev.hermey.app.mobile")
        self.assertEqual(info["CFBundleVersion"], "516")

    def test_the_app_plist_is_identified_by_package_type(self) -> None:
        self.assertIn('candidate.get("CFBundlePackageType") == "APPL"', SOURCE)
