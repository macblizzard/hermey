"""Put the sign-in extension on disk for the browser the bot desktop launches.

The extension is the only door into a browser that needs no launch flags, so it cannot be an optional
extra a host has to be told to install. It ships inside this package and is written on every bridge
start, the same way the bundled skills are — a fresh install has it, and an upgrade replaces it.

One fixed directory, readable by whatever user the browser drops to. Not derived from a profile: this
host runs the browser as another user through a wrapper whose profile is not the agent's, and a path
computed from one profile pointed at a directory the other user could not read — the extension then
silently never loaded.
"""

from __future__ import annotations

import logging
import os
import shutil
from pathlib import Path

LOGGER = logging.getLogger(__name__)

#: The extension's name on disk and in the browser.
EXTENSION_NAME = "hermey-signin"

#: Everything the extension is made of. Listed so a missing file is an error, not a silent half-install.
EXTENSION_FILES = ("manifest.json", "background.js", "popup.html", "popup.js")

#: Beside the bridge's own state, which is the one directory the service unit lets it write
#: (``ReadWritePaths=/var/lib/hermey`` with ``ProtectSystem=strict``). /opt was the first choice and was
#: read-only in practice, so the install silently landed in the fallback while the launcher looked at
#: /opt — the two have to agree, and the one that can be written is the honest answer.
DEFAULT_HOME = "/opt/hermes-extension"


def source_dir() -> Path:
    """The copy that ships inside this package."""
    return Path(__file__).resolve().parent / "browser_extension"


def home() -> Path:
    """Where extensions are installed. ``HERMES_EXTENSION_HOME`` overrides it for tests and odd hosts."""
    override = os.environ.get("HERMES_EXTENSION_HOME")
    if override:
        return Path(override)
    return Path(DEFAULT_HOME)


def target_dir() -> Path:
    return home() / EXTENSION_NAME


def install(destination: Path | None = None) -> Path:
    """Write the extension where the browser looks. Returns the path that ended up usable.

    Falls back to the bridge's own state directory when the system path is not writable (a host that
    runs the bridge as a normal user), because an extension in an odd place still beats none — the
    launcher is told the path by :func:`extension_dir`.
    """
    source = source_dir()
    missing = [name for name in EXTENSION_FILES if not (source / name).is_file()]
    if missing:
        raise FileNotFoundError(f"extension is incomplete, missing: {', '.join(missing)}")

    for candidate in (Path(destination) if destination else target_dir(), _fallback_dir()):
        try:
            candidate.mkdir(parents=True, exist_ok=True)
            for name in EXTENSION_FILES:
                wanted = (source / name).read_bytes()
                current = candidate / name
                if not current.is_file() or current.read_bytes() != wanted:
                    current.write_bytes(wanted)
                current.chmod(0o644)
            _relax(candidate)
            return candidate
        except OSError as exc:  # noqa: PERF203 - try the next location
            LOGGER.warning("sign-in extension: cannot write %s: %s", candidate, exc)
    raise OSError("no writable location for the sign-in extension")


def _fallback_dir() -> Path:
    from .agent_skills import STATE_DIR

    return Path(STATE_DIR) / "extension" / EXTENSION_NAME


def _relax(directory: Path) -> None:
    """Make it readable by the browser's user, wherever that browser runs from.

    Best effort: a mode change that fails only matters on hosts where the browser is another user, and
    those hosts are root-run where it does not fail.
    """
    for path in (directory.parent, directory, *directory.glob("*")):
        try:
            mode = path.stat().st_mode & 0o777
            path.chmod(mode | (0o755 if path.is_dir() else 0o444))
        except OSError:
            pass


def extension_dir() -> str:
    """The directory the launcher passes to the browser. Installs first if nothing is there yet."""
    if not (target_dir() / "manifest.json").is_file():
        return str(install())
    return str(target_dir())


def status() -> dict:
    """What an operator (and the app) can check: is the door actually on disk and current?"""
    source, target = source_dir(), target_dir()
    present = (target / "manifest.json").is_file()
    current = present and all(
        (target / name).is_file() and (target / name).read_bytes() == (source / name).read_bytes()
        for name in EXTENSION_FILES
    )
    return {"path": str(target), "present": present, "up_to_date": current,
            "files": list(EXTENSION_FILES)}


#: Browsers that honour --load-extension. Stable Chrome 137+ accepts the flag and loads nothing, with
#: no error anywhere — the worst kind of failure, so the check below is a loud warning rather than a
#: silent default.
def describe_browser(executable: str | None) -> dict:
    """What the bot desktop will actually run, and whether it can carry the extension.

    ``loads_extensions`` is deliberately conservative: unknown or missing answers are ``None`` (we do
    not know), never ``True``.
    """
    if not executable:
        return {"executable": None, "version": None, "loads_extensions": None,
                "note": "no browser resolved; the bot desktop cannot open one"}
    version = None
    try:
        import subprocess

        out = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=10)
        version = (out.stdout or out.stderr).strip() or None
    except Exception:  # noqa: BLE001 - a version we cannot read is not a failure to report as one
        pass
    lowered = (version or "").lower()
    if "chrome for testing" in lowered or "chromium" in lowered:
        loads = True
    elif "google chrome" in lowered:
        major = 0
        for token in (version or "").split():
            head = token.split(".")[0]
            if head.isdigit():
                major = int(head)
                break
        loads = major < 137 if major else None
    else:
        loads = None
    note = ""
    if loads is False:
        note = ("this Chrome ignores --load-extension, so a login card can be asked for but never filled; "
                "point the bot desktop at a Chromium or Chrome for Testing build")
        LOGGER.warning("sign-in extension: %s", note)
    return {"executable": executable, "version": version, "loads_extensions": loads, "note": note}
