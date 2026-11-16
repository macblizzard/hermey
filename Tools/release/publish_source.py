#!/usr/bin/env python3
"""Readers for a sideload build: what the app says it is, and safe names for untrusted strings.

This file used to be a second publisher (`publish_source.py` wrote its own `source.json` into the
served directory, with its own version, its own history trimming and its own idea of the filename).
Two writers for one directory is how the served manifest came to sit at `0.1.52` while the newest
artifact beside it was `0.1.482`. Everything that writes release artifacts now lives in
`Tools/release/publish_dist.py`; this module is the library both it and `publish_altstore.py` read
the IPA through, and nothing here touches the filesystem.
"""

from __future__ import annotations

import plistlib
import re
import zipfile
from pathlib import Path


def safe_component(value: object, limit: int = 64) -> str:
    """A filesystem/HTML-safe single component built from an untrusted string.

    The version and build come out of the IPA's Info.plist, which is exactly as trustworthy as
    whatever produced the IPA. `../../etc/x` must not become a path and `<script>` must not become
    markup.
    """
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", str(value))[:limit]
    return cleaned if cleaned and cleaned not in (".", "..") else "0"


def read_ipa(ipa: Path) -> dict:
    """The Info.plist of the app inside `ipa`, or a clean failure."""
    with zipfile.ZipFile(ipa) as archive:
        plist_name = next((name for name in archive.namelist() if name.endswith("Info.plist")), None)
        if plist_name is None:
            raise SystemExit(f"{ipa}: no Info.plist inside")
        info = plistlib.loads(archive.read(plist_name))
    required = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")
    missing = [key for key in required if not info.get(key)]
    if missing:
        raise SystemExit(f"{ipa}: Info.plist is missing {missing}")
    return info


if __name__ == "__main__":
    raise SystemExit(
        "publish_source.py is a library now: publishing happens in Tools/release/publish_dist.py"
    )
