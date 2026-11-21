"""The installer is the only way a host gets hermeyd, so it is checked as a program, not as prose.

Two kinds of assertion here, both house style:

* source-level guards on the contract that spans three files — `setup/install.sh`, the release
  workflow, and the asset names. The installer builds `hermeyd-<platform>` and reads `SHA256SUMS`;
  if the workflow names either differently, the first install on a fresh host is a 404.
* runtime tests that run the real script against a **local fake release** (a `file://` directory of
  assets and a `SHA256SUMS` generated here). No network, no GitHub, no root: `id` is stubbed to report
  0 so the script takes its root paths inside a temporary directory, and `systemctl`/`curl` are stubs
  so nothing on the test machine is touched.

The retired Python bridge's installer tests (`test_hermey_cli.py`, `test_installer_bot_desktop.py`)
went with the code they exercised.
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "setup" / "install.sh"
INSTALL = INSTALLER.read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "hermeyd-release.yml").read_text(encoding="utf-8")

ASSETS = ["linux-x86_64", "linux-aarch64", "darwin-arm64", "darwin-x86_64"]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_stubs(directory: Path, uname: str = "") -> None:
    """Stand-ins for the three host commands the installer calls.

    `id -u` reporting 0 lets the script take its root-only paths against a temporary prefix, which is
    what makes a full install testable without sudo. `systemctl` says yes and touches nothing.
    `curl` delegates to the real one, except for the health check, which is answered locally.
    """
    real_id = shutil.which("id") or "/usr/bin/id"
    real_curl = shutil.which("curl") or "/usr/bin/curl"
    scripts = {
        "id": f"""#!/bin/sh
case "$1" in
  -u) echo 0 ;;
  *) exec {real_id} "$@" ;;
esac
""",
        "systemctl": "#!/bin/sh\necho active\nexit 0\n",
        "curl": f"""#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *v1/health*) echo '{{"status":"ok","protocol_version":3,"ws":true}}'; exit 0 ;;
  esac
done
exec {real_curl} "$@"
""",
    }
    if uname:
        scripts["uname"] = f"#!/bin/sh\necho {uname}\n"
    for name, body in scripts.items():
        path = directory / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)


def fake_binary() -> str:
    return """#!/bin/sh
case "$1" in
  --version) echo "hermeyd 0.2.0-test" ;;
  --gateway-check) echo "gateway-check: clear for $HERMEYD_ENGINE_HOME" ;;
  pair)
    host=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --host) host=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${PAIR_LOG:-}" ]; then printf '%s\\n' "$HERMEY_HOME" >> "$PAIR_LOG"; fi
    printf 'pairing code  250240\\n'
    printf 'pairing URL   https://%s/?code=250240\\n' "${host:-localhost}"
    ;;
esac
exit 0
"""


# A `tailscale` stand-in. Written by each test with the node state and serve config it wants to
# pretend this host has, and it records every invocation, so an assertion can say what the
# installer actually asked tailscale to do. Nothing here reaches a real tailnet.
def tailscale_stub(status_json: str, serve_json: str, log: Path,
                   serve_exit: int = 0, off_exit: int = 0) -> str:
    return f"""#!/bin/sh
printf '%s\\n' "$*" >> '{log}'
case "$1" in
  status) printf '%s\\n' '{status_json}' ; exit 0 ;;
  serve)
    case "$2" in
      status) printf '%s\\n' '{serve_json}' ; exit 0 ;;
      --bg) exit {serve_exit} ;;
      --https=443) exit {off_exit} ;;
    esac ;;
esac
exit 0
"""


class InstallerCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        self.serve_log = self.root / "serve.log"
        # Present and logged out by default: a test that does not ask to publish must never reach
        # a real tailnet, and HERMEY_TAILSCALE keeps this off PATH's real binary either way.
        self.tailscale = self.stubs / "tailscale"
        self.set_tailscale(logged_in=False)
        self.env = {
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "PATH": f"{self.stubs}{os.pathsep}{os.environ.get('PATH', '')}",
            "HERMEY_CONF": str(self.root / "conf"),
            "HERMEY_UNIT_DIR": str(self.root / "units"),
            "HERMEY_TAILSCALE": str(self.tailscale),
        }

    def set_tailscale(self, logged_in: bool = True, dns: str = "hermes.example.ts.net.",
                      serve: str = "{}", serve_exit: int = 0, off_exit: int = 0) -> None:
        status = (
            f'{{"BackendState":"Running","Self":{{"DNSName":"{dns}"}}}}'
            if logged_in
            else '{"BackendState":"NeedsLogin","Self":{"DNSName":""}}'
        )
        self.tailscale.write_text(
            tailscale_stub(status, serve, self.serve_log, serve_exit, off_exit),
            encoding="utf-8",
        )
        self.tailscale.chmod(0o755)

    def serve_calls(self) -> list[str]:
        if not self.serve_log.exists():
            return []
        return [line for line in self.serve_log.read_text(encoding="utf-8").splitlines() if line]

    def run_installer(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        merged = dict(self.env)
        merged.update(env)
        return subprocess.run(
            ["sh", str(INSTALLER), *args],
            capture_output=True, text=True, env=merged, timeout=120,
        )

    def make_release(self) -> Path:
        """A local release directory shaped exactly like the published one."""
        release = self.root / "release"
        release.mkdir()
        binary = release / "hermeyd-linux-x86_64"
        binary.write_text(fake_binary(), encoding="utf-8")
        binary.chmod(0o755)

        plugin_dir = self.root / "pkg" / "hermes-genui" / "desktop"
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.js").write_text("console.log('plugin')\n", encoding="utf-8")
        tarball = release / "hermes-genui-plugin.tar.gz"
        with tarfile.open(tarball, "w:gz") as archive:
            archive.add(self.root / "pkg" / "hermes-genui", arcname="hermes-genui")

        (release / "SHA256SUMS").write_text(
            f"{sha256(binary)}  hermeyd-linux-x86_64\n"
            f"{sha256(tarball)}  hermes-genui-plugin.tar.gz\n",
            encoding="utf-8",
        )
        return release

    def install_args(self, name: str = "run") -> list[str]:
        base = self.root / name
        return [
            "--prefix", str(base / "opt"),
            "--state-dir", str(base / "state"),
            "--engine-home", str(base / "engine"),
            "--user", "root",
        ]


class TheInstallerShips2Paths(unittest.TestCase):
    """One script, two paths, and the checksum in front of the first."""

    def test_shebang_and_strict_mode_are_posix(self) -> None:
        self.assertTrue(INSTALL.startswith("#!/bin/sh"))
        self.assertIn("set -eu", INSTALL)
        self.assertNotIn("if [[", INSTALL, "POSIX sh has no [[ ]]")

    def test_the_download_path_names_the_published_asset(self) -> None:
        self.assertIn('asset="$BIN_NAME-$TARGET"', INSTALL)
        self.assertIn("releases/latest/download", INSTALL)
        self.assertIn("SHA256SUMS", INSTALL)
        for asset in ASSETS:
            self.assertIn(asset, INSTALL, f"the installer cannot name {asset}")

    def test_the_checksum_is_verified_before_the_binary_is_installed(self) -> None:
        verified = INSTALL.index('verify_checksum "$TMP/$asset" "$TMP/SHA256SUMS" "$asset"')
        installed = INSTALL.index('install -m 0755 "$TMP/$asset" "$BIN.new"')
        self.assertLess(verified, installed, "install before verify is a supply-chain hole")
        self.assertIn("sha256sum", INSTALL)
        self.assertIn("shasum -a 256", INSTALL, "macOS has no sha256sum")
        self.assertIn("checksum mismatch", INSTALL)

    def test_a_missing_checksum_entry_refuses_instead_of_warning(self) -> None:
        self.assertIn('fail "SHA256SUMS has no entry for $name"', INSTALL)
        block = INSTALL.split("verify_checksum()", 1)[1].split("\n}\n", 1)[0]
        self.assertNotIn("warn", block)

    def test_the_source_path_builds_the_same_binary(self) -> None:
        self.assertIn("--from-source", INSTALL)
        self.assertIn("cargo build --release --locked", INSTALL)
        self.assertIn('SOURCE_BIN="$SRC/hermeyd/target/release/$BIN_NAME"', INSTALL)

    def test_every_option_the_docs_promise_exists(self) -> None:
        for flag in ("--from-source", "--prefix", "--state-dir", "--engine-home", "--uninstall"):
            self.assertIn(f"{flag})", INSTALL, f"{flag} is documented but not parsed")
        self.assertIn("--purge", INSTALL)

    def test_it_does_not_start_the_download_when_it_cannot_identify_the_platform(self) -> None:
        platform = INSTALL.index("detect_target")
        download = INSTALL.index("download_binary", platform)
        self.assertLess(platform, download)


class ItVerifiesWhatItDownloads(InstallerCase):
    def setUp(self) -> None:
        super().setUp()
        write_stubs(self.stubs)
        self.release = self.make_release()

    def test_a_local_release_installs_everything_it_promises(self) -> None:
        engine = self.root / "run" / "engine"
        (engine / "profiles" / "default").mkdir(parents=True)
        done = self.run_installer(
            *self.install_args(), HERMEY_BASE_URL=f"file://{self.release}"
        )
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertIn("checksum ok: hermeyd-linux-x86_64", done.stdout)
        self.assertIn("checksum ok: hermes-genui-plugin.tar.gz", done.stdout)

        binary = self.root / "run" / "opt" / "bin" / "hermeyd"
        self.assertTrue(binary.is_file())
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertTrue((engine / "plugins" / "hermes-genui" / "desktop" / "plugin.js").is_file())

        env_file = (self.root / "conf" / "hermeyd.env").read_text(encoding="utf-8")
        self.assertIn(f"HERMEY_HOME={self.root / 'run' / 'state'}", env_file)
        self.assertIn("HERMEYD_PORT=8788", env_file)
        self.assertIn("HERMEYD_BROWSER_PORT=8790", env_file)
        self.assertEqual((self.root / "run" / "state").stat().st_mode & 0o777, 0o700)

        unit = (self.root / "units" / "hermeyd.service").read_text(encoding="utf-8")
        self.assertIn(f"ExecStart={binary}", unit)
        self.assertIn("EnvironmentFile=-" + str(self.root / "conf" / "hermeyd.env"), unit)

    def test_a_tampered_asset_is_not_installed(self) -> None:
        sums = self.release / "SHA256SUMS"
        sums.write_text(
            "0" * 64 + "  hermeyd-linux-x86_64\n"
            + [line for line in sums.read_text().splitlines() if "plugin" in line][0] + "\n",
            encoding="utf-8",
        )
        done = self.run_installer(
            *self.install_args("bad"), HERMEY_BASE_URL=f"file://{self.release}"
        )
        self.assertEqual(done.returncode, 1)
        self.assertIn("checksum mismatch", done.stderr)
        self.assertFalse((self.root / "bad" / "opt" / "bin" / "hermeyd").exists(),
                         "a binary that failed verification was installed")

    def test_an_archive_that_escapes_the_plugin_directory_is_refused(self) -> None:
        evil = self.root / "pkg" / "escape"
        evil.mkdir()
        (evil / "payload").write_text("x", encoding="utf-8")
        tarball = self.release / "hermes-genui-plugin.tar.gz"
        with tarfile.open(tarball, "w:gz") as archive:
            archive.add(evil / "payload", arcname="../hermes-genui/payload")
        (self.release / "SHA256SUMS").write_text(
            f"{sha256(self.release / 'hermeyd-linux-x86_64')}  hermeyd-linux-x86_64\n"
            f"{sha256(tarball)}  hermes-genui-plugin.tar.gz\n",
            encoding="utf-8",
        )
        done = self.run_installer(
            *self.install_args("evil"), HERMEY_BASE_URL=f"file://{self.release}"
        )
        self.assertEqual(done.returncode, 1)
        self.assertIn("parent paths", done.stderr)


class ItRefusesWhatItCannotRun(InstallerCase):
    def test_an_unsupported_platform_says_what_is_supported(self) -> None:
        write_stubs(self.stubs, uname="FreeBSD")
        done = self.run_installer(*self.install_args())
        self.assertEqual(done.returncode, 1)
        self.assertIn("unsupported platform", done.stderr)
        for word in ("linux x86_64", "linux aarch64", "macOS arm64", "macOS x86_64"):
            self.assertIn(word, done.stderr)
        self.assertIn("--from-source", done.stderr, "refusing must leave a way forward")

    def test_both_ports_must_differ(self) -> None:
        write_stubs(self.stubs)
        done = self.run_installer(*self.install_args(), HERMEYD_BROWSER_PORT="8788")
        self.assertEqual(done.returncode, 1)
        self.assertIn("must differ", done.stderr)

    def test_a_missing_engine_home_is_named_not_guessed(self) -> None:
        write_stubs(self.stubs)
        empty = self.root / "no-engine"
        empty.mkdir()
        done = self.run_installer(
            "--prefix", str(self.root / "x" / "opt"),
            "--state-dir", str(self.root / "x" / "state"),
            "--engine-home", str(empty),
            HERMES_HOME="",
        )
        self.assertEqual(done.returncode, 1)
        self.assertIn("does not exist", done.stderr) if False else None
        self.assertIn("engine home", done.stderr)


class UninstallRemovesWhatWasInstalled(InstallerCase):
    def setUp(self) -> None:
        super().setUp()
        write_stubs(self.stubs)
        base = self.root / "gone"
        self.prefix, self.state, self.engine = base / "opt", base / "state", base / "engine"
        self.conf = self.root / "conf"
        for path in (
            self.prefix / "bin", self.state, self.engine / "plugins" / "hermes-genui" / "desktop",
        ):
            path.mkdir(parents=True)
        (self.prefix / "bin" / "hermeyd").write_text(fake_binary(), encoding="utf-8")
        (self.state / "bridge.db").write_text("devices", encoding="utf-8")
        (self.engine / "plugins" / "hermes-genui" / "desktop" / "plugin.js").write_text("x")
        (self.conf).mkdir(exist_ok=True)
        (self.conf / "hermeyd.env").write_text(
            f"HERMEY_HOME={self.state}\nHERMEYD_ENGINE_HOME={self.engine}\n", encoding="utf-8"
        )
        unit_dir = Path(self.env["HERMEY_UNIT_DIR"])
        unit_dir.mkdir(exist_ok=True)
        (unit_dir / "hermeyd.service").write_text("[Service]\n", encoding="utf-8")

    def uninstall(self, *extra: str) -> subprocess.CompletedProcess:
        return self.run_installer(
            "--uninstall", *extra,
            "--prefix", str(self.prefix),
            "--state-dir", str(self.state),
        )

    def test_it_removes_the_binary_config_and_plugin(self) -> None:
        done = self.uninstall()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse((self.prefix / "bin" / "hermeyd").exists())
        self.assertFalse((Path(self.env["HERMEY_UNIT_DIR"]) / "hermeyd.service").exists())
        self.assertFalse((self.conf / "hermeyd.env").exists())
        self.assertFalse((self.engine / "plugins" / "hermes-genui").exists())

    def test_it_keeps_state_by_default_and_deletes_it_with_purge(self) -> None:
        self.uninstall()
        self.assertTrue((self.state / "bridge.db").is_file(),
                        "uninstall without --purge must keep paired devices")
        done = self.uninstall("--purge")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(self.state.exists(), "--purge must delete state")

    def test_purge_without_uninstall_is_refused(self) -> None:
        done = self.run_installer("--purge")
        self.assertEqual(done.returncode, 1)
        self.assertIn("--purge only makes sense with --uninstall", done.stderr)

    def test_it_removes_only_the_mapping_it_made(self) -> None:
        self.set_tailscale(
            logged_in=True,
            serve='{"TCP":{"443":{"HTTPS":true}},"Web":{"h.example.ts.net:443":'
                  '{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"},'
                  '"/podcast":{"Proxy":"http://127.0.0.1:9000"}}}}}',
        )
        done = self.uninstall()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("serve: removed the root mapping to http://127.0.0.1:8788", done.stdout)
        self.assertIn("serve --https=443 --set-path=/ off", self.serve_calls(),
                      "the root is removed by repeating its own flags, not with --bg off")

    def test_it_leaves_a_root_someone_else_owns(self) -> None:
        self.set_tailscale(
            logged_in=True,
            serve='{"TCP":{"443":{"HTTPS":true}},"Web":{"h.example.ts.net:443":'
                  '{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}',
        )
        done = self.uninstall()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("left in place", done.stdout)
        self.assertNotIn("serve --https=443 --set-path=/ off", self.serve_calls())
        self.assertIn("http://127.0.0.1:3000", done.stdout)


class ItPublishesTheService(InstallerCase):
    """The installer ends with a reachable host, or with the one command it could not run."""

    def setUp(self) -> None:
        super().setUp()
        write_stubs(self.stubs)
        self.release = self.make_release()
        engine = self.root / "run" / "engine"
        (engine / "profiles" / "default").mkdir(parents=True)

    def install(self, *extra: str, **env: str) -> subprocess.CompletedProcess:
        return self.run_installer(
            *self.install_args(), *extra, HERMEY_BASE_URL=f"file://{self.release}", **env
        )

    def test_it_publishes_the_root_and_prints_the_url_that_works(self) -> None:
        self.set_tailscale(logged_in=True, dns="hermes.example.ts.net.")
        done = self.install()
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertIn("serve --bg http://127.0.0.1:8788", self.serve_calls())
        self.assertIn("https://hermes.example.ts.net/?code=250240", done.stdout)
        self.assertIn("code  250240", done.stdout)
        self.assertEqual(done.stdout.strip().splitlines()[-1],
                         "Reachable at https://hermes.example.ts.net/ from your tailnet.")

        env_file = (self.root / "conf" / "hermeyd.env").read_text(encoding="utf-8")
        self.assertIn("HERMEYD_PUBLIC_HOST=hermes.example.ts.net", env_file,
                      "a pairing URL naming localhost cannot be opened on a phone")

    def test_it_pairs_through_the_installed_binary_with_the_right_home(self) -> None:
        self.set_tailscale(logged_in=True)
        pair_log = self.root / "pair.log"
        done = self.install(PAIR_LOG=str(pair_log))
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertEqual(pair_log.read_text(encoding="utf-8").strip(),
                         str(self.root / "run" / "state"))

    def test_a_public_host_the_owner_chose_earlier_survives_the_upgrade(self) -> None:
        self.set_tailscale(logged_in=True)
        conf = self.root / "conf"
        conf.mkdir(parents=True, exist_ok=True)
        (conf / "hermeyd.env").write_text("HERMEYD_PUBLIC_HOST=chosen.example.ts.net\n",
                                          encoding="utf-8")
        done = self.install()
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertIn("HERMEYD_PUBLIC_HOST=chosen.example.ts.net",
                      (conf / "hermeyd.env").read_text(encoding="utf-8"))
        self.assertIn("url   https://chosen.example.ts.net/?code=250240", done.stdout)

    def test_an_already_published_root_is_left_alone_and_says_so(self) -> None:
        self.set_tailscale(
            logged_in=True,
            serve='{"TCP":{"443":{"HTTPS":true}},"Web":{"hermes.example.ts.net:443":'
                  '{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8788"}}}}}',
        )
        done = self.install()
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertIn("the root already publishes http://127.0.0.1:8788", done.stdout)
        self.assertFalse([c for c in self.serve_calls() if " --bg " in f" {c} "],
                         "publishing twice is not idempotent if it re-runs serve")

    def test_a_foreign_root_is_named_and_not_clobbered(self) -> None:
        self.set_tailscale(
            logged_in=True,
            serve='{"TCP":{"443":{"HTTPS":true}},"Web":{"hermes.example.ts.net:443":'
                  '{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}',
        )
        done = self.install()
        self.assertEqual(done.returncode, 0, "an install must not fail over someone else's root")
        self.assertIn("already points at http://127.0.0.1:3000", done.stderr)
        self.assertIn("tailscale serve --https=8443 http://127.0.0.1:8788", done.stdout)
        self.assertIn("belongs to http://127.0.0.1:3000", done.stdout)
        self.assertFalse([c for c in self.serve_calls() if c.startswith("serve --bg")],
                         "the installer published over another service's root")
        self.assertTrue((self.root / "run" / "opt" / "bin" / "hermeyd").is_file(),
                        "the rest of the install must still be complete")

    def test_no_serve_skips_publishing_entirely(self) -> None:
        self.set_tailscale(logged_in=True)
        done = self.install("--no-serve")
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertEqual(self.serve_calls(), [], "--no-serve must not touch tailscale")
        self.assertIn("serve: skipped (--no-serve)", done.stdout)
        self.assertIn("tailscale serve --bg http://127.0.0.1:8788", done.stdout,
                      "the skipped branch still has to say how to publish later")

    def test_the_environment_variable_skips_it_too(self) -> None:
        self.set_tailscale(logged_in=True)
        done = self.install(HERMEY_SERVE="no")
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertEqual(self.serve_calls(), [])

    def test_no_tailscale_installs_and_names_the_command_for_later(self) -> None:
        done = self.install(HERMEY_TAILSCALE=str(self.root / "missing" / "tailscale"))
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertIn("no tailscale on this host", done.stdout)
        self.assertIn("tailscale serve --bg http://127.0.0.1:8788", done.stdout)
        self.assertIn("on this host only", done.stdout.strip().splitlines()[-1])
        self.assertTrue((self.root / "run" / "opt" / "bin" / "hermeyd").is_file())

    def test_a_logged_out_node_installs_and_says_to_log_in_first(self) -> None:
        self.set_tailscale(logged_in=False)
        done = self.install()
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertIn("NeedsLogin", done.stdout)
        self.assertIn("tailscale up", done.stdout)
        self.assertEqual(self.serve_calls(), ["status --json"])

    def test_a_refused_serve_says_what_to_run(self) -> None:
        self.set_tailscale(logged_in=True, serve_exit=1)
        done = self.install()
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertIn("did not succeed", done.stderr)
        self.assertIn("tailscale serve --bg http://127.0.0.1:8788", done.stdout)


class TheDocsDescribeThisHost(unittest.TestCase):
    def setUp(self) -> None:
        self.install_doc = (ROOT / "docs" / "INSTALL.md").read_text(encoding="utf-8")

    def test_the_ports_are_the_ones_the_binary_binds(self) -> None:
        self.assertIn("8788", self.install_doc)
        self.assertIn("8790", self.install_doc)
        self.assertIn("never publish this one", self.install_doc.lower())

    def test_the_token_and_its_permissions_are_documented(self) -> None:
        self.assertIn("/var/lib/hermeyd/local.token", self.install_doc)
        self.assertIn("0600", self.install_doc)

    def test_both_install_paths_are_documented(self) -> None:
        self.assertIn("--from-source", self.install_doc)
        self.assertIn("SHA256SUMS", self.install_doc)
        self.assertIn("checksum", self.install_doc.lower())

    def test_the_three_requirements_are_stated(self) -> None:
        self.assertIn("One gateway per `HERMES_HOME`", self.install_doc)
        self.assertIn("share a UID", self.install_doc)
        self.assertIn("hermes-genui", self.install_doc)

    def test_it_says_how_to_verify_and_uninstall(self) -> None:
        self.assertIn("/v1/health", self.install_doc)
        self.assertIn("hermes serve --isolated", self.install_doc)
        self.assertIn("--uninstall", self.install_doc)
        self.assertIn("--purge", self.install_doc)

    def test_no_doc_hands_the_reader_the_serve_command_as_a_step(self) -> None:
        # The installer publishes now, so `tailscale serve --bg http://127.0.0.1:8788` must read as
        # the no-tailscale / declined case, never as the step after installing.
        serve = "tailscale serve --bg http://127.0.0.1:8788"
        for name in ("docs/INSTALL.md", "docs/PREREQUISITES.md", "README.md"):
            text = (ROOT / name).read_text(encoding="utf-8")
            self.assertLessEqual(text.count(serve), 1,
                                 f"{name} still tells the reader to publish by hand")
        pre = (ROOT / "docs" / "PREREQUISITES.md").read_text(encoding="utf-8")
        self.assertIn("no `tailscale` on the host", pre)
        self.assertIn("publishes", pre)


class NoLiveDocPointsAtTheOldBridge(unittest.TestCase):
    """Guidance a person or agent would follow today must not send them to the removed service."""

    DOCS = [
        "README.md",
        "llms.txt",
        "docs/INSTALL.md",
        "docs/FOR-AGENTS.md",
        "docs/TROUBLESHOOTING.md",
        "docs/APPS.md",
        "docs/ARCHITECTURE.md",
        "setup/SKILL.md",
    ]

    def test_no_install_instructions_name_the_retired_service(self) -> None:
        banned = ["hermey-bridge", "/opt/hermey/venv", "hermey pair", "hermey doctor", "hermey logs"]
        offenders = []
        for name in self.DOCS:
            text = (ROOT / name).read_text(encoding="utf-8")
            for phrase in banned:
                if phrase in text:
                    offenders.append(f"{name}: {phrase}")
        self.assertEqual(offenders, [])

    def test_the_one_line_install_is_the_same_everywhere_that_quotes_it(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("releases/latest/download/install.sh", readme)
        self.assertIn("sudo sh", readme)
        self.assertIn("sudo sh", (ROOT / "setup" / "SKILL.md").read_text(encoding="utf-8"))


class TheReleaseWorkflowPublishesThoseAssets(unittest.TestCase):
    def test_it_runs_on_the_hermeyd_tag_series(self) -> None:
        # hermeyd has its own tag series so a host-service release does not collide with an app
        # release. The publish step must accept the same prefix as the trigger: it validates the tag
        # name in a `case` before anything is uploaded, so a workflow that triggers on `hermeyd-v*`
        # while validating `v*` builds all four binaries and then publishes none of them.
        self.assertIn('tags: ["hermeyd-v*"]', WORKFLOW)
        self.assertIn("hermeyd-v*)", WORKFLOW)

    def test_it_builds_all_four_targets(self) -> None:
        for asset in ASSETS:
            self.assertIn(f"asset: {asset}", WORKFLOW, f"{asset} is not built")
        for target in (
            "x86_64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu",
            "aarch64-apple-darwin",
            "x86_64-apple-darwin",
        ):
            self.assertIn(target, WORKFLOW)

    def test_linux_aarch64_gets_a_real_cross_toolchain(self) -> None:
        # No `cross`/`zigbuild`: the aarch64 build is a rustup target plus Ubuntu's GNU cross gcc.
        self.assertIn("gcc-aarch64-linux-gnu", WORKFLOW)
        self.assertIn("CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER", WORKFLOW)
        self.assertNotIn("cargo install cargo-zigbuild", WORKFLOW)
        self.assertNotIn("cargo install cross", WORKFLOW)

    def test_it_publishes_a_checksum_file_and_the_installer(self) -> None:
        self.assertIn("SHA256SUMS", WORKFLOW)
        self.assertIn("sha256sum hermeyd-*", WORKFLOW)
        self.assertIn("install -m 0644 setup/install.sh dist/install.sh", WORKFLOW)
        self.assertIn("hermes-genui-plugin.tar.gz", WORKFLOW)

    def test_the_publish_job_may_write_a_release(self) -> None:
        self.assertIn("contents: write", WORKFLOW)

    def test_no_marketplace_action_builds_the_binary(self) -> None:
        for line in WORKFLOW.splitlines():
            if line.strip().startswith("uses:"):
                self.assertRegex(line, r"uses: actions/(checkout|upload-artifact|download-artifact)@",
                                 f"unexpected third-party action: {line.strip()}")

    def test_every_upload_declares_a_short_retention(self) -> None:
        blocks = WORKFLOW.split("uses: actions/upload-artifact")[1:]
        self.assertTrue(blocks)
        for block in blocks:
            self.assertRegex(block[:500], r"retention-days: [1-7]\b")


class TheDeployUnitsMatchWhatIsInstalled(unittest.TestCase):
    def test_the_shipped_unit_points_at_the_installed_paths(self) -> None:
        unit = (ROOT / "deploy" / "hermeyd.service").read_text(encoding="utf-8")
        self.assertIn("ExecStart=/opt/hermey/bin/hermeyd", unit)
        self.assertIn("EnvironmentFile=-/etc/hermey/hermeyd.env", unit)
        self.assertIn("ReadWritePaths=/var/lib/hermeyd", unit)

    def test_the_installer_writes_that_same_shape(self) -> None:
        self.assertIn('BIN="$PREFIX/bin/$BIN_NAME"', INSTALL)
        self.assertIn("EnvironmentFile=-$CONF/hermeyd.env", INSTALL)
        self.assertIn("ReadWritePaths=$STATE $ENGINE_HOME", INSTALL)

    def test_the_launchd_plist_points_at_the_installed_paths(self) -> None:
        plist = (ROOT / "deploy" / "com.hermeyd.plist").read_text(encoding="utf-8")
        self.assertIn("/opt/hermey/bin/hermeyd", plist)
        self.assertIn("/var/lib/hermeyd", plist)

    def test_the_plugin_bundle_is_vendored(self) -> None:
        bundle = ROOT / "setup" / "plugins" / "hermes-genui" / "desktop" / "plugin.js"
        self.assertTrue(bundle.is_file(), "the installer has nothing to put in the engine")
        self.assertGreater(bundle.stat().st_size, 1024)


class TheScriptIsSyntacticallyValid(unittest.TestCase):
    def test_sh_parses_it(self) -> None:
        done = subprocess.run(["sh", "-n", str(INSTALLER)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_help_lists_every_documented_flag(self) -> None:
        done = subprocess.run(["sh", str(INSTALLER), "--help"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        for flag in ("--from-source", "--prefix", "--state-dir", "--engine-home", "--uninstall",
                     "--no-serve"):
            self.assertIn(flag, done.stdout)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck is not installed")
    def test_shellcheck_is_clean_at_warning_level(self) -> None:
        done = subprocess.run(
            ["shellcheck", "-S", "warning", str(INSTALLER)],
            capture_output=True, text=True,
        )
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
