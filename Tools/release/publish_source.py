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
    """The Info.plist of the **app** inside `ipa`, or a clean failure.

    The app's own plist is `Payload/<Name>.app/Info.plist`. A modern app also carries nested
    bundles — a SwiftUI resource bundle (``HermesApps_HermeyUI.bundle``) is one — and each has an
    ``Info.plist`` of its own. Taking the first name that ends in ``Info.plist`` took the *nested*
    one, so the published source advertised ``hermey.HermeyUI.resources`` as the bundle identifier
    instead of ``dev.hermey.app.mobile``. A sideloading app matches an update to the installed app by
    that identifier, so the wrong one is not cosmetic: it is "update" installing a stranger.

    The app plist is identified by ``CFBundlePackageType == APPL``, falling back to the shallowest
    ``Payload/*.app/Info.plist`` path when the key is absent.
    """
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        candidates = [name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist")]
        if not candidates:
            # Not an .app-shaped archive: keep the old behaviour rather than refusing outright.
            candidates = [name for name in names if name.endswith("Info.plist")]
        shallowest = sorted(candidates, key=lambda name: (name.count("/"), len(name)))
        info: dict = {}
        chosen = None
        for name in shallowest:
            try:
                candidate = plistlib.loads(archive.read(name))
            except Exception:
                continue
            if candidate.get("CFBundlePackageType") == "APPL" or chosen is None:
                chosen, info = name, candidate
            if candidate.get("CFBundlePackageType") == "APPL":
                break
        if chosen is None:
            raise SystemExit(f"{ipa}: no readable Info.plist inside")
    required = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")
    missing = [key for key in required if not info.get(key)]
    if missing:
        raise SystemExit(f"{ipa}: {chosen} is missing {missing}")
    return info



if __name__ == "__main__":
    raise SystemExit(
        "publish_source.py is a library now: publishing happens in Tools/release/publish_dist.py"
    )
