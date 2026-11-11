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
import build_stamp  # noqa: E402  (same directory: the visible build line)
import sync_store  # noqa: E402  (same directory: the Pages/manifest plumbing)
from publish_source import read_ipa  # noqa: E402  (same directory, shared IPA reader)

SOURCE_NAME = "Hermey"
SOURCE_ID = "dev.hermey.app.source"
ICON_URL = "https://raw.githubusercontent.com/{repo}/main/icon-512.png"  # .format(repo=…); never emit the braces


def safe_component(value: object, limit: int = 64) -> str:
    """A path component built from the IPA's own version strings, which are untrusted input."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", str(value))[:limit]
    return cleaned if cleaned and cleaned not in (".", "..") else "0"


def run(cmd: list[str], **kwargs) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(cmd[:3])} failed:\n{result.stderr.strip()}")
    return result.stdout


def publish_pages(repo: str, tag: str, work: Path, version: str, build: str, ipa_name: str) -> None:
    """Write everything the release advertises *before* `main` is pushed.

    The `Published pages and README match the release` job runs the second the publish commit
    lands, and it compares the newest release with the Pages landing page — so a publish that left
    the landing page (or the release's own `altstore.json` asset) for a later repair turned that job
    red on every release. Ordering is the fix: release asset, Pages, then the commit.
    """
    manifest = (work / "altstore.json").read_bytes()
    run(["gh", "release", "upload", tag, str(work / "altstore.json"), "-R", repo, "--clobber"])
    print("  manifest altstore.json -> release asset")

    github = sync_store.GitHub(sync_store.resolve_token(None))
    if sync_store.update_pages(github, repo, "gh-pages", "altstore.json", manifest):
        print("  pages    altstore.json updated")

    text, sha = sync_store.contents(github, repo, "gh-pages", "index.html")
    if text is None:
        return
    wanted = build_stamp.index_body(version, build, ipa_name)
    if not build_stamp.matches(text, wanted):
        stamped = build_stamp.replace(text, wanted)
        if stamped is not None:
            sync_store.put_contents(github, repo, "gh-pages", "index.html", stamped,
                                    f"pages: build {version} ({build})", sha)
            print("  pages    index.html stamped")


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
    # The disk image is the friendly download; the zip is kept for anything that expands archives.
    # Either can be published alone.
    parser.add_argument("--mac-dmg", type=Path)
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

    # The tag names the *app*, not the build: a release whose tag disagrees with the version inside
    # the IPA is a support thread ("v22" beside an app that says 0.1.22"). Builds still differ per
    # run, which is what the sideload source compares.
    tag = f"v{version}"
    icon_url = ICON_URL.format(repo=args.repo)
    asset_name = f"Hermey-{safe_component(version)}-b{safe_component(build)}.ipa"
    download = f"https://github.com/{args.repo}/releases/download/{tag}/{asset_name}"

    if not release_has(args.repo, tag, asset_name):
        staging = Path(tempfile.mkdtemp())
        try:
            shutil.copy2(args.ipa, staging / asset_name)
            files = [str(staging / asset_name)]
            for extra in (args.mac_zip, args.mac_dmg):
                if extra and extra.exists():
                    shutil.copy2(extra, staging / extra.name)
                    files.append(str(staging / extra.name))
            run(["gh", "release", "create", tag, *files,
                 "-R", args.repo,
                 "--title", f"{SOURCE_NAME} {version} ({build})",
                 "--notes", args.notes or f"Build {version} ({build})."])
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        print(f"  release {tag}: {asset_name}")
    else:
        print(f"  release {tag} already exists — reusing it")

    # The one-line installer in every doc is `releases/latest/download/install.sh`, so the script has
    # to be an asset of the release — it was not, and that URL answered 404 while the release page
    # looked complete (the same way a missing icon did). `gh release upload` keeps the file's name.
    installer = Path(__file__).resolve().parent.parent.parent / "setup" / "install.sh"
    if installer.is_file():
        run(["gh", "release", "upload", tag, str(installer), "-R", args.repo, "--clobber"])

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
            "iconURL": icon_url,
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
            "iconURL": icon_url,
            "headerURL": icon_url,
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
            if args.mac_dmg and Path(args.mac_dmg).is_file():
                shutil.copy2(args.mac_dmg, args.mirror_to / Path(args.mac_dmg).name)
                shutil.copy2(args.mac_dmg, args.mirror_to / "Hermey-macOS-unsigned.dmg")
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

        # The README carries the same marked build line as the landing page, stamped from this IPA
        # and committed *with* the manifest, so "which build is current?" cannot answer differently
        # in the two places a person looks.
        readme_path = work / "README.md"
        if readme_path.is_file():
            original = readme_path.read_text()
            stamped = build_stamp.replace(original, build_stamp.readme_body(version, build))
            if stamped is not None and stamped != original:
                readme_path.write_text(stamped)
                staged.append("README.md")

        # The release asset and the landing page are written before `main` moves: see `publish_pages`.
        publish_pages(args.repo, tag, work, version, build, asset_name)

        # Nothing to write is not a failure: re-running a publish to repair the mirror or the release
        # assets leaves the manifest byte-identical, and `git commit` then exits 1.
        if not run(["git", "-C", str(work), "status", "--porcelain"]).strip():
            print("  manifest already published — nothing to commit")
        else:
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
