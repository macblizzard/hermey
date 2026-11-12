"""The `hermey` command the installer writes, exercised as the shell it is.

`Tests/test_*.py` usually assert strings in the source, but the CLI is a generated *shell script*:
its bugs are exit codes and branches, which no grep can see. So this expands the heredoc the way
`setup/install.sh` does, puts fake `systemctl`/`curl`/`journalctl` on PATH, and runs the real arms.

The regression behind it: `hermey status` ended its arm with `[ -n "$HOST_DNS" ] && echo …`, so on a
`--no-serve` install (no tailnet name) the failed test became the script's exit status — `hermey status`
answered 1 with a healthy bridge, while the installer's own pass condition is that it exits 0.
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "setup" / "install.sh"

# The installer's own defaults, so a change there shows up here as a failing expectation.
BRIDGE_PORT = "8787"
HTTPS_PORT = "8443"
UNIT = "hermey-bridge"
CONF = "/etc/hermey/bridge.env"
PREFIX = "/opt/hermey"
REPO = "macblizzard/hermey"


def generated_cli(tail_host: str) -> str:
    """The `hermey` script exactly as install.sh would write it for a host named (or not named)."""
    body = INSTALLER.read_text(encoding="utf-8")
    start = body.index('cat > "$BINDIR/hermey" <<EOF')
    start = body.index("\n", start) + 1
    end = body.index("\nEOF\n", start)
    script = body[start:end]
    # install-time expansion of the unquoted heredoc's bare variables…
    for token, value in (
        ("$BRIDGE_PORT", BRIDGE_PORT),
        ("$HTTPS_PORT", HTTPS_PORT),
        ("$BR_UNIT", UNIT),
        ("$CONF", CONF),
        ("$PREFIX", PREFIX),
        ("$REPO", REPO),
        ("${TAIL_HOST:-}", tail_host),
    ):
        script = script.replace(token, value)
    # …and the escapes, which bash turns back into $ ` \ for the running script. Only those four
    # backslash pairs are special inside an unquoted heredoc; everything else is literal.
    script = re.sub(r"\\([$`\\])", lambda m: m.group(1), script)
    script = re.sub(r"\\\n", "", script)
    assert "\\$" not in script, "an escaped variable survived the expansion"
    assert not re.search(r"<[A-Za-z_]", script), "a heredoc token was left unexpanded"
    return script


def fake_bin(directory: Path, https_ok: bool, public_host: str) -> None:
    """Stand-ins that answer the way a healthy host does, and can be told to fail one check.

    ``public_host`` is what the bridge reports from `/v1/pair/start`: the installer writes
    `HERMES_BRIDGE_PUBLIC_HOST` from the tailnet name, and without one the bridge falls back to the
    request's `Host` header, which carries the loopback address *and* the bridge port.
    """
    scripts = {
        "systemctl": f"""#!/usr/bin/env bash
case "$*" in
  *is-active*) echo active;;
  *Environment*) echo "HERMES_BRIDGE_GATEWAY_URL=ws://127.0.0.1:9120";;
  *status*) echo "● {UNIT}.service - Hermey bridge";;
esac
exit 0
""",
        "journalctl": "#!/usr/bin/env bash\necho 'log line'\nexit 0\n",
        "tailscale": '#!/usr/bin/env bash\necho \'{"BackendState": "Running"}\'\n',
        "curl": f"""#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *pair/start*) echo '{{"code": "12345678", "host": "{public_host}"}}'; exit 0;;
    https://*)
      if [ "{'1' if https_ok else '0'}" = 1 ]; then echo '{{"status":"ok"}}'; exit 0; fi
      exit 22;;
    *v1/health*) echo '{{"status":"ok"}}'; exit 0;;
  esac
done
exit 0
""",
    }
    for name, text in scripts.items():
        path = directory / name
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)


class TheInstallerWritesAWorkingCommand(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def run_cli(self, tail_host: str, *args: str, https_ok: bool = True) -> subprocess.CompletedProcess:
        cli = self.tmp / "hermey"
        cli.write_text(generated_cli(tail_host), encoding="utf-8")
        cli.chmod(0o755)
        bins = self.tmp / "bin"
        bins.mkdir(exist_ok=True)
        fake_bin(bins, https_ok, tail_host or f"127.0.0.1:{BRIDGE_PORT}")
        env = {k: v for k, v in os.environ.items()
               if k not in {"HERMEY_PORT", "HERMEY_HTTPS_PORT"}}
        env["PATH"] = f"{bins}{os.pathsep}{env.get('PATH', '')}"
        return subprocess.run(["bash", str(cli), *args], capture_output=True, text=True,
                              env=env, timeout=60)

    # ---------------------------------------------------------------- status (the exit-code bug)
    def test_status_exits_zero_with_a_tailnet_host(self) -> None:
        done = self.run_cli("host.tailnet.ts.net", "status")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn(f"tailnet:  https://host.tailnet.ts.net:{HTTPS_PORT}", done.stdout)

    def test_status_exits_zero_with_no_tailnet_host(self) -> None:
        """The --no-serve shape: printing no tailnet line must not become a non-zero exit."""
        done = self.run_cli("", "status")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("bridge:   healthy", done.stdout)
        self.assertNotIn("tailnet:", done.stdout)

    # ---------------------------------------------------------------- doctor
    def test_doctor_reports_https_ok(self) -> None:
        done = self.run_cli("host.tailnet.ts.net", "doctor")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("https:     ok", done.stdout)

    def test_doctor_says_https_failed_instead_of_going_quiet(self) -> None:
        done = self.run_cli("host.tailnet.ts.net", "doctor", https_ok=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("https:     FAIL", done.stdout,
                      "a check that fails must print, or the certificate is nobody's suspect")

    # ---------------------------------------------------------------- pair
    def test_pair_prints_the_link_with_one_port(self) -> None:
        done = self.run_cli("host.tailnet.ts.net", "pair")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn(f"hermes://pair?host=https://host.tailnet.ts.net:{HTTPS_PORT}&code=12345678",
                      done.stdout)
        self.assertNotIn(f":{BRIDGE_PORT}:", done.stdout,
                         "the Host header carries the bridge port; the link wants the outside one")

    def test_pair_with_only_loopback_prints_the_code_alone(self) -> None:
        """127.0.0.1 from the phone is the phone, so there is no link worth printing."""
        done = self.run_cli("127.0.0.1", "pair")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("code: 12345678", done.stdout)
        self.assertNotIn("hermes://", done.stdout)

    def test_an_unknown_verb_is_a_usage_error(self) -> None:
        done = self.run_cli("host.tailnet.ts.net", "nonsense")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("usage: hermey", done.stderr + done.stdout)


if __name__ == "__main__":
    unittest.main()
