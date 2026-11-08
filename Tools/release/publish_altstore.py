#!/usr/bin/env python3
"""Publish an unsigned iOS build to a public GitHub-hosted sideload source.

Why GitHub instead of the tailnet file server: a sideloading front end fetches its source over the
public internet and caches it aggressively. A tailnet-only URL can only be reached with Tailscale up,
and the front end kept serving a list it had already fetched. GitHub gives a public HTTPS URL with
real CDN semantics, and release assets give the IPA a stable, permanent address.

Layout mirrors a standard AltStore source:

  <repo>/altstore.json                                    <- add this URL in the installer
  <repo>/releases/download/v<build>/Hermey-<version>-b<build>.ipa   <- the build itself

`date` is the IPA's mtime (UTC), `version`/`buildVersion` come from the IPA's Info.plist, and the new
entry is prepended so the newest build is always first. Old entries are trimmed, but their release
assets are left alone: an installed device may still be pointing at one.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from publish_source import read_ipa  # noqa: E402  (same directory, shared IPA reader)

SOURCE_NAME = "Hermey"
SOURCE_ID = "dev.hermey.app.source"
ICON_URL = "https://raw.githubusercontent.com/{repo}/main/icon-512.png"


def safe_component(value: object, limit: int = 64) -> str:
    """A path component built from the IPA's own version strings, which are untrusted input."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", str(value))[:limit]
    return cleaned if cleaned and cleaned not in (".", "..") else "0"


def run(cmd: list[str], **kwargs) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(cmd[:3])} failed:\n{result.stderr.strip()}")
    return result.stdout


def release_has(repo: str, tag: str, asset: str) -> bool:
    """Whether `tag` exists *and* carries `asset`.

    The tag alone was not enough: a release created without the IPA (an interrupted publish, a
    hand-made tag) was treated as done, and the source then pointed at a 404.
    """
    result = subprocess.run(["gh", "release", "view", tag, "-R", repo, "--json", "assets"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return False
    try:
        assets = json.loads(result.stdout or "{}").get("assets") or []
    except json.JSONDecodeError:
        return False
    return any(item.get("name") == asset for item in assets)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--mac-zip", type=Path)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--notes", default="")
    parser.add_argument("--keep", type=int, default=5)
    # A copy on the host's own file server, which answers `Cache-Control: no-store`. GitHub's raw
    # CDN keeps a fetched source for minutes and an installer keeps it longer; a URL that is never
    # reused cannot show a version that was replaced three releases ago.
    parser.add_argument("--mirror-to", type=Path)
    # The mirror's own source points its downloads at the mirror. GitHub's release CDN has answered
    # 504 for these .ipa assets while serving the .zip from the same release, so the host that holds
    # the file is the host that serves it.
    parser.add_argument("--mirror-base-url", default="https://hermes.example.ts.net:8444")
    args = parser.parse_args()

    info = read_ipa(args.ipa)
    version = str(info["CFBundleShortVersionString"])
    build = str(info["CFBundleVersion"])
    bundle = str(info["CFBundleIdentifier"])
    min_os = str(info.get("MinimumOSVersion") or "17.0")
    data = args.ipa.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    stamp = dt.datetime.fromtimestamp(args.ipa.stat().st_mtime, dt.timezone.utc)

    tag = f"v{build}"
    asset_name = f"Hermey-{safe_component(version)}-b{safe_component(build)}.ipa"
    download = f"https://github.com/{args.repo}/releases/download/{tag}/{asset_name}"

    if not release_has(args.repo, tag, asset_name):
        staging = Path(tempfile.mkdtemp())
        try:
            shutil.copy2(args.ipa, staging / asset_name)
            files = [str(staging / asset_name)]
            if args.mac_zip and args.mac_zip.exists():
                shutil.copy2(args.mac_zip, staging / args.mac_zip.name)
                files.append(str(staging / args.mac_zip.name))
            run(["gh", "release", "create", tag, *files,
                 "-R", args.repo,
                 "--title", f"{SOURCE_NAME} {version} ({build})",
                 "--notes", args.notes or f"Build {version} ({build})."])
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        print(f"  release {tag}: {asset_name}")
    else:
        print(f"  release {tag} already exists — reusing it")

    entry = {
        "version": version,
        "buildVersion": build,
        "date": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": args.notes or f"Build {version} ({build}).",
        "downloadURL": download,
        "size": len(data),
        "minOSVersion": min_os,
        "sha256": digest,
    }

    work = Path(tempfile.mkdtemp())
    try:
        run(["git", "clone", "--depth", "1", f"https://github.com/{args.repo}.git", str(work)])
        path = work / "altstore.json"
        source = json.loads(path.read_text()) if path.exists() else {}
        app = (source.get("apps") or [{}])[0]
        versions = [v for v in app.get("versions", [])
                    if not (v.get("version") == version and v.get("buildVersion") == build)]
        versions.insert(0, entry)
        app.update({
            "name": SOURCE_NAME,
            "bundleIdentifier": bundle,
            "developerName": "Hermey",
            "subtitle": "Hermes Agent client",
            "localizedDescription": "Native client for a self-hosted Hermes Agent gateway.",
            "iconURL": ICON_URL,
            "tintColor": "#007CF7",
            "category": "utilities",
            "screenshots": [],
            "versions": versions[:args.keep],
            "appPermissions": {"entitlements": [], "privacy": {
                "NSCameraUsageDescription": "Scan the pairing code shown by your Hermes host to connect this device."}},
        })
        source.update({
            "name": "Hermey",
            "identifier": SOURCE_ID,
            "sourceURL": f"https://raw.githubusercontent.com/{args.repo}/main/altstore.json",
            "schemaVersion": source.get("schemaVersion", 1),
            "subtitle": "Hermes Agent",
            "description": "Unsigned builds of the Hermes native client, published automatically from CI.",
            "iconURL": ICON_URL,
            "headerURL": ICON_URL,
            "tintColor": "#007CF7",
            "featuredApps": [bundle],
            "apps": [app],
            "news": source.get("news", []),
        })
        path.write_text(json.dumps(source, indent=2) + "\n")
        if args.mirror_to:
            args.mirror_to.mkdir(parents=True, exist_ok=True)
            # Copy the assets ourselves, before rewriting the URLs: the rewrite only points at files
            # the mirror already holds, and relying on a separate publish step to have put them
            # there is how v153 shipped a "mirrored" source whose downloads still went to GitHub.
            # The mirror's filenames are the *published* ones, not the artifact names CI hands us
            # (`Hermes-unsigned.ipa` vs `Hermey-<version>-b<build>.ipa`); matching on the artifact
            # name silently left the new build out of the mirror and the rewrite skipped it.
            if args.ipa and Path(args.ipa).is_file():
                shutil.copy2(args.ipa, args.mirror_to / asset_name)
            if args.mac_zip and Path(args.mac_zip).is_file():
                shutil.copy2(args.mac_zip, args.mirror_to / Path(args.mac_zip).name)
                shutil.copy2(args.mac_zip, args.mirror_to / "Hermey-macOS-unsigned.zip")
            mirrored = json.loads(path.read_text())
            for entry in mirrored.get("apps", []):
                for published in entry.get("versions", []):
                    url = published.get("downloadURL", "")
                    name = url.rsplit("/", 1)[-1]
                    # Only rewrite to a file the mirror actually holds; a name it never received
                    # must keep the URL that works rather than point at a 404.
                    if name and (args.mirror_to / name).is_file():
                        published["downloadURL"] = f"{args.mirror_base_url.rstrip('/')}/{name}"
            (args.mirror_to / "altstore.json").write_text(json.dumps(mirrored, indent=2) + "\n")

        icon = Path(__file__).resolve().parent / "app-icon-512.png"
        if icon.exists() and not (work / "icon-512.png").exists():
            shutil.copy2(icon, work / "icon-512.png")

        staged = ["altstore.json"]
        if (work / "icon-512.png").exists():
            staged.append("icon-512.png")
        run(["git", "-C", str(work), "add", *staged])
        run(["git", "-C", str(work), "-c", "user.name=assistant",
             "-c", "user.email=hermey@users.noreply.github.com",
             "commit", "-m", f"publish {version} ({build})"])
        run(["git", "-C", str(work), "push", "origin", "HEAD:main"])
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(f"\n  source   https://raw.githubusercontent.com/{args.repo}/main/altstore.json")
    print(f"  ipa      {download}  ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
