#!/usr/bin/env python3
"""Publish a sideloaded build as an AltStore/FlareStore source.

    python Tools/release/publish_source.py --ipa dist/Hermes-unsigned.ipa \
        --base-url https://hermes.example.ts.net:8444 --out /srv/hermey-dist

The source is the file a sideloading app adds once; after that it lists new versions and installs
them for you. Everything here is read from the *actual* IPA — bundle id, version, build, minimum
OS, size — so the source can never advertise a build that is not the one on disk.

Two conventions that make updates work:
  * `version` is CFBundleShortVersionString and `date` is the IPA's mtime, newest first.
  * previous entries are preserved from the existing source.json, so the app can show history and
    the sideloader can pick the newest one. Each entry's download URL is served from the same
    directory.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import plistlib
import shutil
import zipfile
from pathlib import Path

TINT = "#007CF7"
CATEGORY = "utilities"


#: The file server keeps one IPA (the newest); older entries would advertise a `sha256` for bytes
#: that are no longer on disk, which is worse than offering no history at all.
MAX_VERSIONS = 1


def read_ipa(ipa: Path) -> dict:
    with zipfile.ZipFile(ipa) as z:
        plist_name = next((n for n in z.namelist() if n.endswith("Info.plist")), None)
        if plist_name is None:
            raise SystemExit(f"{ipa}: no Info.plist inside")
        info = plistlib.loads(z.read(plist_name))
    required = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")
    missing = [k for k in required if not info.get(k)]
    if missing:
        raise SystemExit(f"{ipa}: Info.plist is missing {missing}")
    return info


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--mac-zip", type=Path, help="optional macOS build to publish alongside")
    parser.add_argument("--base-url", required=True, help="public origin that serves this directory")
    parser.add_argument("--out", required=True, type=Path, help="directory to write into (served as-is)")
    parser.add_argument("--notes", default="", help="release notes for this version")
    parser.add_argument("--icon", type=Path, help="512x512 PNG (default: keep the one already published)")
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    # One name per build. The history entries carry their own `sha256`, so re-using one filename
    # made every older entry advertise the *newest* build's bytes — a sideloader checking the hash
    # of an older version failed against the only copy on disk.
    version_guess = None
    try:
        version_guess = str(read_ipa(args.ipa)["CFBundleShortVersionString"])
        build_guess = str(read_ipa(args.ipa)["CFBundleVersion"])
        ipa_name = f"Hermey-{version_guess}-b{build_guess}.ipa"
    except Exception:
        ipa_name = args.ipa.name
    shutil.copy2(args.ipa, out / ipa_name)
    if args.mac_zip:
        published = out / args.mac_zip.name
        shutil.copy2(args.mac_zip, published)
        # The old name keeps working: somebody's bookmark, a README, a message thread. One more file
        # on disk is cheaper than a dead download link.
        legacy = out / "Hermes-macOS-unsigned.zip"
        if published.name != legacy.name:
            shutil.copy2(published, legacy)
    if args.icon and args.icon.resolve() != (out / "icon-512.png").resolve():
        shutil.copy2(args.icon, out / "icon-512.png")

    info = read_ipa(args.ipa)
    version = str(info["CFBundleShortVersionString"])
    build = str(info["CFBundleVersion"])
    size = (out / ipa_name).stat().st_size
    digest = hashlib.sha256((out / ipa_name).read_bytes()).hexdigest()
    date = dt.datetime.fromtimestamp(args.ipa.stat().st_mtime, dt.timezone.utc)
    entry = {
        "version": version,
        "buildVersion": build,
        "date": date.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": args.notes or f"Build {build}",
        "downloadURL": f"{base}/{ipa_name}",
        "size": size,
        "minOSVersion": str(info.get("MinimumOSVersion", "17.0")),
        "sha256": digest,
    }

    source_path = out / "source.json"
    existing = {}
    if source_path.exists():
        try:
            existing = json.loads(source_path.read_text())
        except json.JSONDecodeError:
            existing = {}
    app = (existing.get("apps") or [{}])[0]
    versions = [v for v in app.get("versions", []) if v.get("version") != version or v.get("buildVersion") != build]
    versions.insert(0, entry)
    # Keep the history short and meaningful. Every build now carries its own marketing version
    # (0.1.<run>), so a long tail is just noise in a sideloading front end that lists entries by
    # version string.
    versions = versions[:MAX_VERSIONS]

    privacy = {
        "NSCameraUsageDescription": "Scan the pairing code shown by your Hermes host to connect this device.",
        "NSLocalNetworkUsageDescription": "Hermes connects to your own Hermes host over your private network.",
    }
    source = {
        "name": "Hermey",
        "identifier": "dev.hermey.app.source",
        "subtitle": "Your Hermes bots, on your phone",
        "description": (
            "Native client for a self-hosted Hermes Agent. Every bot (Hermes profile) is reachable "
            "through one gateway; approvals, streaming replies and tool output appear in the "
            "conversation. Builds are unsigned and must be re-signed by your sideloading app."
        ),
        "iconURL": f"{base}/icon-512.png",
        "headerURL": f"{base}/app-icon-1024.png",
        "tintColor": TINT,
        "featuredApps": [info["CFBundleIdentifier"]],
        "apps": [
            {
                "name": "Hermey",
                "bundleIdentifier": info["CFBundleIdentifier"],
                "developerName": "the maintainer",
                "subtitle": "Your Hermes bots, on your phone",
                "localizedDescription": (
                    "Chats with every Hermes bot, streaming replies, tool cards, inline approvals "
                    "and per-device pairing."
                ),
                "iconURL": f"{base}/icon-512.png",
                "tintColor": TINT,
                "category": CATEGORY,
                "screenshots": [],
                "versions": versions,
                "appPermissions": {"entitlements": [], "privacy": privacy},
            }
        ],
        "news": [
            {
                "title": f"Hermes {version} ({build})",
                "identifier": f"hermes-{version}-{build}",
                "caption": args.notes or f"Build {build}",
                "date": entry["date"],
                "tintColor": TINT,
            }
        ],
    }
    source_path.write_text(json.dumps(source, indent=2) + "\n")
    (out / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>Hermes builds</title>"
        "<body style='font:15px -apple-system,sans-serif;background:#1a1a1a;color:#dcdcdc;padding:28px'>"
        "<h2 style='margin:0 0 4px'>Hermes builds</h2>"
        f"<p style='color:#979797'>Add <code>{base}/source.json</code> to your sideloading app.</p>"
        "<ul>"
        f"<li><a style='color:#42a0ff' href='source.json'>source.json</a></li>"
        f"<li><a style='color:#42a0ff' href='{ipa_name}'>{ipa_name}</a> ({size // 1024} KB)</li>"
        + (f"<li><a style='color:#42a0ff' href='{args.mac_zip.name}'>{args.mac_zip.name}</a></li>" if args.mac_zip else "")
        + "</ul></body>"
    )

    print(f"published {info['CFBundleIdentifier']} {version} ({build})")
    print(f"  source   {base}/source.json")
    print(f"  download {entry['downloadURL']}  ({size} bytes, sha256 {digest[:12]}…)")
    print(f"  versions kept: {len(versions)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
