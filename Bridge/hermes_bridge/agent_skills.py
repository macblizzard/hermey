"""Ship the Mac skill to every bot on this host.

A bot that cannot see how to reach the owner's Mac will try SSH and fail, so the capability is only
real if the *instructions* are present too. This module puts them there:

1. Materialises the CLI next to the bridge's state (``<state>/bin/local_computer.py``). The installer
   deletes its checkout, so a shipped path under the repo would be gone by the time a bot looked.
2. Renders ``agent_skills/mac-local-computer/SKILL.md`` with that absolute path and this bridge's
   URL baked in — no placeholder ever reaches a bot.
3. Writes it where the bots actually load skills: the shared skills dir Hermes is configured with
   (one copy, every profile, including bots created later), and, when no shared dir is configured or
   the sandbox keeps the Hermes home read-only, into every profile's own skills dir instead.

The file it writes carries ``managed_by: hermey-bridge`` in its frontmatter. That marker is the whole
safety story: a skill of the same name **without** it belongs to the owner, and is never overwritten.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

from .paths import STATE_DIR, atomic_write_bytes, atomic_write_text, profiles_root

LOGGER = logging.getLogger(__name__)

#: The skill's directory name, and the name Hermes shows in its index.
SKILL_NAME = "mac-local-computer"

#: Frontmatter line that marks a file as ours to update. Absence of it means "hands off".
MANAGED_MARKER = "managed_by: hermey-bridge"

_BUNDLE = Path(__file__).resolve().parent / "agent_skills"
TEMPLATE = _BUNDLE / SKILL_NAME / "SKILL.md"
CLI_SOURCE = _BUNDLE / "bin" / "local_computer.py"

_CLI_PLACEHOLDER = "@@CLI@@"
_BRIDGE_PLACEHOLDER = "@@BRIDGE@@"


def bridge_url() -> str:
    """The loopback URL the CLI defaults to, made explicit in the rendered skill."""
    host = os.environ.get("HERMES_BRIDGE_HOST", "").strip() or "127.0.0.1"
    port = os.environ.get("HERMES_BRIDGE_PORT", "").strip() or "8787"
    return f"http://{host}:{port}"


def install_cli(destination: Path | None = None) -> Path:
    """Put the CLI at a stable path and hand that path back.

    ``<state>/bin`` is the one writable, non-temporary directory this process owns (the unit allows
    it by name), so it is the only place a bot on an installed host can rely on.
    """
    target = Path(destination) if destination is not None else STATE_DIR / "bin" / "local_computer.py"
    try:
        source = CLI_SOURCE.read_bytes()
        existing = target.read_bytes() if target.is_file() else None
        if existing != source:
            atomic_write_bytes(target, source)
        target.chmod(0o755)
        return target
    except OSError as exc:
        # A read-only state dir still leaves the running checkout usable (developer hosts).
        checkout = Path(__file__).resolve().parents[2] / "Tools" / "local_computer.py"
        if checkout.is_file():
            LOGGER.warning("local computer CLI: %s; falling back to %s", exc, checkout)
            return checkout
        raise


def render(cli: Path) -> str:
    """The skill text, with this host's paths substituted."""
    template = TEMPLATE.read_text(encoding="utf-8")
    return template.replace(_CLI_PLACEHOLDER, str(cli)).replace(_BRIDGE_PLACEHOLDER, bridge_url())


def install_home() -> Path:
    """The Hermes install home — the directory ``profiles/`` sits in."""
    root = profiles_root()
    return root.parent if root.name == "profiles" else root


def _config_external_dirs(config: Path) -> list[Path]:
    """``skills.external_dirs`` out of the Hermes config, without a YAML dependency.

    Only the one key is read, and a config this parser cannot follow yields no dirs — the caller
    then falls back to the per-profile dirs, which always work.
    """
    if not config.is_file():
        return []
    try:
        lines = config.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []

    dirs: list[Path] = []
    inside_skills = False
    inside_list = False
    for raw in lines:
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line.startswith((" ", "\t")):  # a top-level key ends any block
            inside_skills = stripped.startswith("skills:")
            inside_list = False
            continue
        if not inside_skills:
            continue
        if stripped.startswith("external_dirs:"):
            inline = stripped.split(":", 1)[1].strip()
            if inline.startswith("["):
                for item in inline.strip("[]").split(","):
                    item = item.strip().strip("'\"")
                    if item:
                        dirs.append(Path(item).expanduser())
                inside_list = False
            else:
                inside_list = True
            continue
        if inside_list:
            if stripped.startswith("- "):
                item = stripped[2:].strip().strip("'\"")
                if item:
                    dirs.append(Path(item).expanduser())
            else:
                inside_list = False
    return dirs


def shared_skill_dirs() -> list[Path]:
    """Skill dirs shared by every profile — the preferred single target."""
    explicit = os.environ.get("HERMES_SKILLS_DIR", "").strip()
    if explicit:
        return [Path(explicit).expanduser()]
    return _config_external_dirs(install_home() / "config.yaml")


def fallback_skill_dirs() -> list[Path]:
    """Per-profile skill dirs, plus the default profile's, for hosts with no shared dir."""
    home = install_home()
    dirs = [home / "skills"]
    try:
        for profile in sorted(profiles_root().iterdir()):
            if profile.is_dir():
                dirs.append(profile / "skills")
    except OSError:
        pass
    seen: set[str] = set()
    unique: list[Path] = []
    for path in dirs:
        key = str(path)
        if key not in seen:
            seen.add(key)
            unique.append(path)
    return unique


def write_skill(root: Path, body: str) -> str:
    """Write one copy. Returns ``written`` / ``current`` / ``foreign`` / ``failed: …``.

    ``foreign`` is a real answer, not a failure: the owner has a skill by that name, so their file
    stays exactly as it is and this install leaves it alone.
    """
    path = Path(root) / SKILL_NAME / "SKILL.md"
    try:
        if path.is_file():
            existing = path.read_text(encoding="utf-8", errors="replace")
            if existing == body:
                relax_mode(path)  # an install that predates this may still be 0600
                return "current"
            if MANAGED_MARKER not in existing:
                return "foreign"
            # Ours, but no longer what the template says: either this bridge shipped new
            # instructions, or a bot hand-edited the file. A bot's edit is never silently
            # destroyed — the text it wrote stays beside the file it was edited in.
            previous = path.parent / (path.name + ".previous")
            atomic_write_text(previous, existing)
            relax_mode(previous)
        atomic_write_text(path, body)
        relax_mode(path)
        return "written"
    except OSError as exc:
        return f"failed: {exc.strerror or exc}"


def relax_mode(path: Path) -> None:
    """A skill is read by every agent process on the host, and ``mkstemp`` leaves 0600.

    Not a failure if it cannot be done: the mode is a convenience, the content is the point.
    """
    try:
        path.chmod(0o644)
    except OSError:
        pass


def install() -> dict[str, Any]:
    """Make the skill available to every bot on this host. Never raises for a permission problem.

    Called on every bridge start, so it must be safe to repeat: identical content is left untouched,
    and a changed template is picked up on the next restart (a template update ships with the bridge).
    """
    try:
        cli = install_cli()
    except OSError as exc:
        LOGGER.error("local computer skill not installed: %s", exc)
        return {"installed": [], "attempted": [], "error": str(exc)}
    body = render(cli)

    attempted: list[dict[str, str]] = []
    installed: list[str] = []

    # A configured shared dir serves every profile at once, so it is tried first and alone: writing
    # the same file into 20 profile dirs as well would only give the next reader 20 copies to keep
    # in step.
    for root in shared_skill_dirs():
        outcome = write_skill(root, body)
        attempted.append({"dir": str(root), "outcome": outcome})
        if outcome in {"written", "current"}:
            installed.append(str(root))
            break

    # No shared dir (the stock install), or it is not writable from inside the unit's sandbox.
    if not installed:
        for root in fallback_skill_dirs():
            outcome = write_skill(root, body)
            attempted.append({"dir": str(root), "outcome": outcome})
            if outcome in {"written", "current"}:
                installed.append(str(root))

    if installed:
        LOGGER.info("local computer skill at %s (cli %s)", ", ".join(installed), cli)
    else:
        LOGGER.warning("local computer skill could not be written: %s", attempted)
    return {"installed": installed, "attempted": attempted, "cli": str(cli)}
