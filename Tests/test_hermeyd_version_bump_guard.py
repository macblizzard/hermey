"""The version-bump guard: `hermeyd --version` must never describe two different programs.

On 2026-11-22 the host service was rebuilt with several fixes and kept reporting 0.2.0, so a deployed
binary could not be compared with the repository at all. `Tools/check_hermeyd_version_bump.py` makes
that a CI failure instead of a discovery. These tests drive it through real git repositories, because
the thing under test is a diff between two refs.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "Tools" / "check_hermeyd_version_bump.py"


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


class Repo:
    """A throwaway git repository with a hermeyd-shaped tree."""

    def __init__(self, root: Path) -> None:
        self.root = root
        run(["git", "init", "-q", "-b", "main"], root)
        run(["git", "config", "user.email", "t@example.com"], root)
        run(["git", "config", "user.name", "t"], root)

    def write(self, relpath: str, text: str) -> None:
        path = self.root / relpath
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message: str) -> str:
        run(["git", "add", "-A"], self.root)
        run(["git", "commit", "-q", "-m", message], self.root)
        return run(["git", "rev-parse", "HEAD"], self.root).stdout.strip()

    def manifest(self, version: str) -> None:
        self.write(
            "hermeyd/Cargo.toml",
            textwrap.dedent(
                f"""\
                [package]
                name = "hermeyd"
                version = "{version}"
                edition = "2021"
                """
            ),
        )


class TheGuardRefusesADrift(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))
        self.repo.manifest("0.2.0")
        self.repo.write("hermeyd/src/main.rs", "fn main() {}\n")
        self.repo.write("README.md", "readme\n")
        self.repo.write("CHANGELOG.md", "## [0.1.615] — 2026-11-22\n\n- something\n")
        self.base = self.repo.commit("initial")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def guard(self, base: str, head: str = "HEAD") -> subprocess.CompletedProcess:
        return run([sys.executable, str(SCRIPT), "--base", base, "--head", head], self.repo.root)

    def test_a_source_change_without_a_bump_fails(self) -> None:
        self.repo.write("hermeyd/src/main.rs", "fn main() { println!(\"x\"); }\n")
        self.repo.commit("change the program")
        result = self.guard(self.base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("hermeyd source changed", result.stdout)
        self.assertIn("hermeyd/src/main.rs", result.stdout)
        self.assertIn("Cargo.toml", result.stdout)

    def test_a_release_alone_does_not_need_a_bump(self) -> None:
        # The owner's decision, after living with the stricter rule for one release: a client release
        # does not move the host service's number. `hermeyd` moves only when its own program changes,
        # so the two numbers keep meaning different things.
        self.repo.write("CHANGELOG.md", "## [0.1.617] — 2026-11-23\n\n- a fix\n\n## [0.1.615] — 2026-11-22\n\n- something\n")
        self.repo.commit("changelog for a release")
        result = self.guard(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no hermeyd source change", result.stdout)

    def test_a_release_together_with_a_source_change_still_needs_a_bump(self) -> None:
        # The exemption is for releases that touch nothing in the service — a release that also ships
        # service code is a source change like any other.
        self.repo.write("CHANGELOG.md", "## [0.1.617] — 2026-11-23\n\n- a fix\n\n## [0.1.615] — 2026-11-22\n\n- something\n")
        self.repo.write("hermeyd/src/main.rs", "fn main() { println!(\"z\"); }\n")
        self.repo.commit("release carrying service code")
        self.assertEqual(self.guard(self.base).returncode, 1)

    def test_a_bundled_asset_change_also_needs_a_bump(self) -> None:
        # The bundled agent skills are part of the deployed program: a host can run new behaviour
        # from an asset change alone, so it must move the version too.
        self.repo.write("hermeyd/assets/agent-skills/signin/SKILL.md", "fill through devtools\n")
        self.repo.commit("change a bundled skill")
        self.assertEqual(self.guard(self.base).returncode, 1)

    def test_a_source_change_with_a_bump_passes(self) -> None:
        self.repo.write("hermeyd/src/main.rs", "fn main() { println!(\"y\"); }\n")
        self.repo.manifest("0.2.1")
        self.repo.commit("change the program and the version")
        result = self.guard(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("0.2.0 → 0.2.1", result.stdout)

    def test_a_docs_only_change_needs_no_bump(self) -> None:
        self.repo.write("README.md", "readme, improved\n")
        self.repo.write("docs/HERMEYD.md", "explanation\n")
        self.repo.commit("docs only")
        result = self.guard(self.base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no hermeyd source change", result.stdout)

    def test_a_test_only_change_needs_no_bump(self) -> None:
        self.repo.write("hermeyd/tests/cli.rs", "#[test] fn t() {}\n")
        self.repo.commit("tests only")
        self.assertEqual(self.guard(self.base).returncode, 0)

    def test_a_first_push_has_nothing_to_compare_and_is_not_a_failure(self) -> None:
        # `github.event.before` is all-zeroes on a branch's first push.
        result = self.guard("0" * 40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("skipped", result.stdout)

    def test_an_unreadable_base_is_not_a_verdict(self) -> None:
        result = self.guard("no-such-ref")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class TheRealRepositoryIsWiredToIt(unittest.TestCase):
    """CI must actually run the guard — a script nobody calls enforces nothing."""

    def test_the_hermeyd_job_runs_the_guard(self) -> None:
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("check_hermeyd_version_bump.py", workflow)
        self.assertIn("fetch-depth: 0", workflow)

    def test_the_manifest_carries_a_version(self) -> None:
        manifest = (REPO_ROOT / "hermeyd" / "Cargo.toml").read_text()
        self.assertIn('version = "', manifest)


if __name__ == "__main__":
    unittest.main()
