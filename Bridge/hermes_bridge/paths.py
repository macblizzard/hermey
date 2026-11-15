"""Where the bridge keeps state on disk.

One answer for every route: the directory the systemd unit allows (`ReadWritePaths=`) and the one
the installer created. Reading it from the environment instead of hardcoding a path is what makes a
sandboxed install work at all — with `ProtectSystem=strict`, writing to an invented `/var/lib/...`
is an instant `EROFS` on the first bot delete.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path


def _state_dir() -> Path:
    explicit = os.environ.get("HERMES_BRIDGE_STATE_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    database = os.environ.get("HERMES_BRIDGE_DB", "").strip()
    if database:
        return Path(database).expanduser().parent
    xdg = os.environ.get("XDG_STATE_HOME", "").strip()
    base = Path(xdg).expanduser() if xdg else Path.home() / ".local" / "state"
    return base / "hermes-bridge"


STATE_DIR = _state_dir()

#: Bots the owner deleted. Kept out of the bot's own home, which is gone by then.
ARCHIVE_DIR = STATE_DIR / "deleted-bots"

#: "This bot is off" is bridge state, not something the agent should be able to edit.
DISABLED_STATE_FILE = STATE_DIR / "disabled-bots.json"

#: Uploaded room pictures.
ROOM_ATTACHMENT_ROOT = STATE_DIR / "room-attachments"


def profiles_root() -> Path:
    """The Hermes profiles this bridge reports on.

    ``HERMES_PROFILES_ROOT`` wins (the installer sets it), then ``HERMES_HOME``/profiles, then the
    conventional home. A bridge running under a different user than the agent still reads the right
    directory instead of silently reporting an empty bot list.

    ``HERMES_HOME`` can be either the install home (``~/.hermes``, so bots are ``profiles/*``) or a
    running profile (``~/.hermes/profiles/assistant``), in which case the bots are its siblings —
    both shapes are honoured here because four modules used to carry their own copy of this rule and
    three of them ignored ``HERMES_PROFILES_ROOT`` entirely.
    """
    explicit = os.environ.get("HERMES_PROFILES_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    home = os.environ.get("HERMES_HOME", "").strip()
    if home:
        base = Path(home).expanduser()
        if base.parent.name == "profiles":
            return base.parent
        return base / "profiles"
    return Path.home() / ".hermes" / "profiles"


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """Write *data* to *path* so a reader sees the old file or the new one, never half of either.

    The temporary file is unique per call: with a fixed name two concurrent writers share one
    scratch file, and the second ``replace`` can publish a mix of both payloads. The rename is the
    publish, and it stays inside the destination directory so it is a same-filesystem move.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".writing")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def atomic_write_text(path: Path, text: str, encoding: str = "utf-8") -> None:
    """``atomic_write_bytes`` for text. See that function for why the temp name is unique."""
    atomic_write_bytes(path, text.encode(encoding))
