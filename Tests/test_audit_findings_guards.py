"""Guards for the 2026-11-27 OSS-audit findings (`docs/SECURITY_TASKS.md`).

Four things were fixed, and each one is a rule that has to survive the next edit:

* a tag name reached a release shell script as script text (`.github/workflows/hermeyd-release.yml`);
* a plaintext WebSocket was possible to a host that is not this machine (`PairingAddress.swift`);
* `ssl._create_unverified_context` was one kwarg away from any caller (`publish_dist.py`);
* and the audit's own false positives were re-triaged by hand every run, so the allowlists are files
  in the tree now, each with its reason.

These are source assertions, like the rest of `Tests/`: they cannot prove the Swift behaves, only
that the guard is still where a reviewer would look for it. `LoopbackHostTests.swift` is the one that
executes the predicate.
"""

from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"


def read(*parts: str) -> str:
    return (ROOT.joinpath(*parts)).read_text()


class WorkflowScripts(unittest.TestCase):
    """No event or input context is spliced into a `run:` script: it arrives through `env:`."""

    #: `matrix` is written in the workflow file itself, so it is not attacker-chosen. Everything
    #: else in `${{ }}` comes from the event, a dispatch form or a previous step's output.
    FORBIDDEN = ("github.", "inputs.", "steps.", "env.", "secrets.")

    def test_no_interpolation_reaches_a_shell_script(self) -> None:
        import yaml  # noqa: PLC0415 (only this test needs it)

        offenders: list[str] = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            document = yaml.safe_load(path.read_text())
            for job_name, job in (document.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    script = step.get("run")
                    if not isinstance(script, str):
                        continue
                    for context in self.FORBIDDEN:
                        if "${{ " + context in script:
                            offenders.append(f"{path.name}:{job_name}:{step.get('name', '?')} -> {context}")
        self.assertEqual(offenders, [], "an event value is script text; pass it through env: and quote it")

    def test_the_release_tag_arrives_as_a_variable_and_is_quoted(self) -> None:
        release = read(".github", "workflows", "hermeyd-release.yml")
        # Named once as data, never inside the script.
        self.assertIn("INPUT_TAG: ${{ inputs.tag }}", release)
        self.assertIn("REF_NAME: ${{ github.ref_name }}", release)
        self.assertNotIn('tag="${{', release)
        self.assertIn('tag="$REF_NAME"', release)
        self.assertIn('"$TAG"', release)
        # An event with no tag name must stop the job rather than run it with an empty tag.
        self.assertIn('test -n "$tag"', release)


class PlaintextSockets(unittest.TestCase):
    """`ws` only ever to this machine; anything else is upgraded, and the rewrite is one way."""

    def setUp(self) -> None:
        self.pairing = read("Apps", "HermesMac", "Pairing", "PairingAddress.swift")

    def test_parse_upgrades_a_remote_plaintext_url(self) -> None:
        body = self.pairing.split("static func parse(", 1)[1]
        self.assertIn('if scheme == "ws", !LoopbackHost.isLoopback(host) {', body)
        self.assertIn('components.scheme = "wss"', body)
        # Upgraded, not refused: the URL the person typed is kept, minus the cleartext.
        self.assertNotIn('throw PairingError.unsupportedScheme("ws")', body)

    def test_every_socket_builder_goes_through_the_one_upgrade(self) -> None:
        # webSocketURL, localComputerSocketURL and apiOrigin — the three that dial or mint.
        self.assertEqual(self.pairing.count("URLComponents(string: securedBaseURL())"), 3)

    def test_there_is_no_fallback_to_the_url_as_typed(self) -> None:
        # `?? text` was the silent downgrade: after an upgrade, `text` is still the plaintext URL.
        self.assertNotIn("?? text", self.pairing)

    def test_the_predicate_has_one_definition(self) -> None:
        self.assertTrue((ROOT / "Sources" / "HermesKit" / "LoopbackHost.swift").is_file())
        # The list it replaced, which got `[::1]` wrong because URLComponents returns `::1`.
        self.assertNotIn('["127.0.0.1", "localhost", "[::1]"]', self.pairing)
        self.assertIn("LoopbackHost.isLoopback(host)", self.pairing)

    def test_the_apps_do_not_derive_a_plaintext_socket_for_a_remote_host(self) -> None:
        bridge = read("Apps", "HermesMobile", "Networking", "BridgeService.swift")
        display = read("Sources", "HermesKit", "BotComputer.swift")
        for source, name in ((bridge, "BridgeService"), (display, "BotComputer")):
            self.assertIn("LoopbackHost.isLoopback(components.host)", source, name)
            self.assertIn('plaintext ? "ws" : "wss"', source, name)


class InsecureTLS(unittest.TestCase):
    """`--insecure` is the only route, it is loud, and it is never a fallback."""

    def setUp(self) -> None:
        self.source = read("Tools", "release", "publish_dist.py")
        sys.path.insert(0, str(ROOT / "Tools" / "release"))
        import publish_dist  # noqa: PLC0415

        self.module = publish_dist
        publish_dist._insecure_warned = False

    def test_the_context_is_built_in_one_place(self) -> None:
        self.assertEqual(self.source.count("ssl._create_unverified_context("), 1)
        self.assertIn("def unverified_context()", self.source)
        # The flag, and only the flag, decides.
        self.assertIn("insecure=args.insecure", self.source)
        self.assertIn("if insecure is True", self.source)

    def test_verification_stays_on_unless_the_flag_is_exactly_true(self) -> None:
        seen: list[object] = []

        class Response:
            status = 200

            def __enter__(self) -> "Response":
                return self

            def __exit__(self, *_: object) -> bool:
                return False

            def read(self) -> bytes:
                return b"body"

        def fake_urlopen(request, timeout=None, context=None):  # noqa: ANN001
            seen.append(context)
            return Response()

        with mock.patch.object(self.module.urllib.request, "urlopen", fake_urlopen):
            self.module.fetch("https://example.test/artifact")
            self.assertIsNone(seen[-1])
            # Truthy is not the flag: a stray string must not open the hole.
            with contextlib.redirect_stderr(io.StringIO()):
                self.module.fetch("https://example.test/artifact", insecure="yes")
            self.assertIsNone(seen[-1])
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.module.fetch("https://example.test/artifact", insecure=True)
            self.assertIsNotNone(seen[-1], "the flag did not reach the opener")
            self.assertIn("--insecure", stderr.getvalue())
            # One line per run, on stderr, not one per request.
            again = io.StringIO()
            with contextlib.redirect_stderr(again):
                self.module.fetch("https://example.test/artifact", insecure=True)
            self.assertEqual(again.getvalue(), "")

    def test_only_http_urls_are_fetched(self) -> None:
        with self.assertRaises(RuntimeError):
            self.module.fetch("file:///etc/passwd")

    def test_the_flag_is_announced_before_the_first_request(self) -> None:
        # `main` warns as soon as the flag is parsed, so the line sits above the publish's output.
        body = self.source.split("def main(", 1)[1]
        self.assertIn("if args.insecure:", body)
        self.assertIn("_warn_insecure_once()", body)


class Allowlists(unittest.TestCase):
    """Each false positive is a file in the tree with its reason, not a re-triage every run."""

    def test_gitleaks_allowlists_by_value_so_a_real_secret_still_fires(self) -> None:
        config = read(".gitleaks.toml")
        self.assertIn("useDefault = true", config)
        self.assertEqual(config.count("[[allowlists]]"), 2)
        # By path *and* value: the files themselves stay in scope.
        self.assertEqual(config.count('regexTarget = "line"'), 2)
        self.assertIn("SUPublicEDKey", config)
        self.assertIn("a2ui\\.surfaces\\.disabled", config)

    def test_the_two_allowlisted_values_are_still_the_ones_in_the_tree(self) -> None:
        # A stale entry is worse than none: it allowlists a line that no longer exists while a new
        # one goes untriaged.
        self.assertIn("SUPublicEDKey: ezxgxj3MqbAIuclhB15SoXkIuZzYTkUtKlSB9SeCEGk=", read("project.yml"))
        self.assertIn('disabledKey = "a2ui.surfaces.disabled"',
                      read("Sources", "HermesA2UI", "A2UISurfaceSettings.swift"))

    def test_osv_ignores_the_unmaintained_advisory_with_a_reason_and_a_date(self) -> None:
        config = read("osv-scanner.toml")
        self.assertIn('id = "RUSTSEC-2024-0449"', config)
        # `ignoreUntil` is the deprecated spelling; osv-scanner 2.7 wants `effectiveUntil`.
        self.assertIn("effectiveUntil = 20", config)
        self.assertIn("unmaintained", config)

    def test_bandit_excludes_paths_and_disables_no_rule(self) -> None:
        config = read(".bandit")
        self.assertIn("[bandit]", config)
        self.assertIn("exclude = ", config)
        self.assertIn("*/Tests/*", config)
        self.assertIn("*/hermeyd/assets/agent-skills/*", config)
        # `skips` would switch a check off for every file, which is what the path list avoids.
        self.assertNotIn("skips", config)
        self.assertNotIn("exclude_dirs", config)  # the ini key is `exclude`; the other is ignored

    def test_the_sha1_and_eval_sites_carry_their_reason(self) -> None:
        sync = read("Tools", "release", "sync_store.py")
        self.assertIn("usedforsecurity=False", sync)
        self.assertIn("nosemgrep: python.lang.security.insecure-hash-algorithms", sync)
        live = read("Tests", "test_live_activity.py")
        self.assertIn("nosemgrep: python.lang.security.audit.eval-detected", live)


if __name__ == "__main__":
    unittest.main()
