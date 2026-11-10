#!/usr/bin/env python3
"""Keep the AltStore/SideStore source in step with the latest Hermey release.

A stale side-load source is the one failure in this project that makes no noise: the release page
shows the new build, CI is green, and every client keeps installing the old one. This script compares
what is *served* against what the newest release actually contains, repairs the difference, and exits
non-zero when it could not.

It is idempotent: run it after a release, or let the scheduled workflow run it, and a second run
reports "in sync" and changes nothing.

    python3 Tools/release/sync_store.py                 # repair drift
    python3 Tools/release/sync_store.py --check         # report only, exit 1 on drift
    python3 Tools/release/sync_store.py --repo me/fork --at v0.1.9
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_stamp  # noqa: E402  (same directory: the one visible build line)

API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"
JSON_TYPE = "application/json"
MIN_IOS = "17.0"


# --------------------------------------------------------------------------- github plumbing


def resolve_token(explicit: str | None) -> str:
    token = explicit or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token
    try:
        return subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("sync_store: no token — set GH_TOKEN, or run `gh auth login` on this machine")


class GitHub:
    def __init__(self, token: str) -> None:
        self.token = token

    def request(self, url: str, method: str = "GET", body: bytes | None = None,
                content_type: str | None = None, accept: str = "application/vnd.github+json") -> tuple[int, bytes]:
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("Authorization", f"Bearer {self.token}")
        request.add_header("Accept", accept)
        request.add_header("X-GitHub-Api-Version", "2022-11-28")
        if content_type:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def json(self, url: str, method: str = "GET", payload: dict | None = None) -> dict:
        body = json.dumps(payload).encode() if payload is not None else None
        status, raw = self.request(url, method, body, JSON_TYPE if body else None)
        if status >= 300:
            sys.exit(f"sync_store: {method} {url} -> {status}: {raw[:300].decode(errors='replace')}")
        return json.loads(raw or b"{}")


# --------------------------------------------------------------------------- reading the release


def release_for(github: GitHub, repo: str, at: str | None) -> dict:
    return github.json(f"{API}/repos/{repo}/releases/tags/{at}" if at else f"{API}/repos/{repo}/releases/latest")


def asset_named(release: dict, suffix: str) -> dict | None:
    for asset in release.get("assets", []):
        if asset["name"].lower().endswith(suffix):
            return asset
    return None


def asset_bytes(github: GitHub, asset: dict) -> bytes:
    status, raw = github.request(asset["url"], accept="application/octet-stream")
    if status >= 300:
        sys.exit(f"sync_store: could not download {asset['name']} ({status})")
    return raw


def ipa_metadata(ipa: bytes) -> tuple[str, str, str]:
    """``(version, build, bundle id)`` — read from the app inside the archive, never from the filename."""
    with zipfile.ZipFile(io.BytesIO(ipa)) as archive:
        plists = [n for n in archive.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if not plists:
            sys.exit("sync_store: that .ipa has no Payload/*.app/Info.plist")
        info = plistlib.loads(archive.read(plists[0]))
    version = str(info.get("CFBundleShortVersionString") or "")
    build = str(info.get("CFBundleVersion") or "")
    if not version:
        sys.exit("sync_store: the .ipa has no CFBundleShortVersionString")
    return version, build, str(info.get("CFBundleIdentifier") or "")


# --------------------------------------------------------------------------- the manifest itself


def desired_manifest(current: dict | None, repo: str, ipa: dict, ipa_bytes: bytes,
                     version: str, build: str, bundle: str, notes: str) -> dict:
    base = f"https://github.com/{repo}/releases/latest/download"
    digest = hashlib.sha256(ipa_bytes).hexdigest()
    previous = ((current or {}).get("apps") or [{}])[0].get("versions") or [{}]
    previous = previous[0] if previous else {}
    same_build = str(previous.get("buildVersion")) == build and previous.get("version") == version
    entry = {
        "version": version,
        "buildVersion": build,
        "date": previous.get("date") if same_build else (ipa.get("updated_at") or ipa.get("created_at")),
        "localizedDescription": previous.get("localizedDescription") if same_build else notes,
        "downloadURL": f"{base}/{ipa['name']}",
        "size": len(ipa_bytes),
        "minOSVersion": MIN_IOS,
        "sha256": digest,
    }

    if current and current.get("apps"):
        manifest = json.loads(json.dumps(current))  # keep icons, screenshots, permissions as shipped
        app = manifest["apps"][0]
        app["bundleIdentifier"] = app.get("bundleIdentifier") or bundle
    else:
        manifest = {
            "name": "Hermey",
            "identifier": "dev.hermey.app.source",
            "subtitle": "Your Hermes bots, on your phone",
            "description": "Native client for a self-hosted Hermes Agent.",
            "iconURL": f"{base}/icon-512.png",
            "tintColor": "#007CF7",
            "apps": [{
                "name": "Hermey",
                "bundleIdentifier": bundle,
                "developerName": "Hermey",
                "subtitle": "Your Hermes bots, on your phone",
                "localizedDescription": "Chats with every Hermes bot, streaming replies and pairing.",
                "iconURL": f"{base}/icon-512.png",
                "tintColor": "#007CF7",
                "category": "utilities",
                "screenshots": [],
                "versions": [],
            }],
        }
        app = manifest["apps"][0]

    # Newest first, and the entry we just built must be the only one carrying this build.
    versions = [entry] + [v for v in app.get("versions", []) if v.get("buildVersion") != build]
    app["versions"] = versions[:20]

    # A header or icon that 404s makes the source page in AltStore render as a broken tile.
    for key in ("iconURL", "headerURL"):
        if manifest.get(key) and not url_ok(manifest[key]):
            manifest[key] = f"{base}/icon-512.png" if key == "iconURL" else None
        if manifest.get(key) is None:
            manifest.pop(key, None)
    return manifest


def manifest_urls(manifest: dict | None) -> list[tuple[str, str]]:
    """Every URL the source page will load, labelled — a 404 here is an invisible breakage."""
    if not manifest:
        return []
    urls = [(k, manifest[k]) for k in ("iconURL", "headerURL") if manifest.get(k)]
    for app in manifest.get("apps") or []:
        if app.get("iconURL"):
            urls.append(("app iconURL", app["iconURL"]))
        for version in (app.get("versions") or [])[:1]:
            if version.get("downloadURL"):
                urls.append(("downloadURL", version["downloadURL"]))
    return urls


def url_ok(url: str, attempts: int = 4) -> bool:
    """Does this URL actually load, allowing for the CDN's propagation window.

    A freshly uploaded release asset can answer 404 for several seconds, and a HEAD can be refused
    where a GET is not, so neither is trusted on the first try: ask up to `attempts` times, spacing
    the tries out, and fall back to a one-byte ranged GET. Only a URL that stays dark is broken.
    """
    for attempt in range(attempts):
        for method in ("HEAD", "GET"):
            headers = {"Range": "bytes=0-0"} if method == "GET" else {}
            request = urllib.request.Request(url, method=method, headers=headers)
            try:
                with urllib.request.urlopen(request, timeout=45) as response:
                    if response.status in (200, 206):
                        return True
            except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError):
                continue
        if attempt + 1 < attempts:
            time.sleep(3 * (attempt + 1))
    return False


def ensure_icon(github: "GitHub", repo: str, release: dict) -> None:
    """A release without its icon is a source that renders as a broken tile.

    The manifest points every icon at `releases/latest/download/icon-512.png`; if the release does not
    carry that file the whole source is quietly wrong, which is exactly how a hand-cut release broke
    the feed once. Ship the one the repo already tracks, and let the nightly run heal it.
    """
    if asset_named(release, "icon-512.png"):
        return
    path = Path(__file__).with_name("app-icon-512.png")
    if not path.is_file():
        print("warning   no icon-512.png in the release, and none in the repo to upload")
        return
    upload_asset(github, repo, release, "icon-512.png", path.read_bytes(), "image/png")
    print("uploaded  icon-512.png -> release asset")


def served_manifest(github: GitHub, release: dict) -> tuple[dict | None, dict | None]:
    asset = asset_named(release, "altstore.json")
    if not asset:
        return None, None
    try:
        return json.loads(asset_bytes(github, asset)), asset
    except json.JSONDecodeError:
        return None, asset


# --------------------------------------------------------------------------- writing


def upload_asset(github: GitHub, repo: str, release: dict, name: str, payload: bytes, content_type: str) -> None:
    existing = next((a for a in release.get("assets", []) if a["name"] == name), None)
    if existing:
        github.request(f"{API}/repos/{repo}/releases/assets/{existing['id']}", "DELETE")
    status, raw = github.request(
        f"{UPLOADS}/repos/{repo}/releases/{release['id']}/assets?name={name}",
        "POST", payload, content_type,
    )
    if status >= 300:
        sys.exit(f"sync_store: uploading {name} -> {status}: {raw[:300].decode(errors='replace')}")


def update_pages(github: GitHub, repo: str, branch: str, path: str, content: bytes) -> bool:
    url = f"{API}/repos/{repo}/contents/{path}"
    current = github.request(f"{url}?ref={branch}")[0]
    if current == 404:
        return False  # no Pages branch in this fork; the release asset is the source of truth
    document = github.json(f"{url}?ref={branch}")
    if base64.b64decode(document.get("content", "")) == content:
        return False
    github.json(url, "PUT", {
        "message": f"store: {path} for {json.loads(content)['apps'][0]['versions'][0]['version']}",
        "content": base64.b64encode(content).decode(),
        "sha": document["sha"],
        "branch": branch,
    })
    return True


def contents(github: "GitHub", repo: str, branch: str, path: str) -> tuple[str | None, str | None]:
    """``(text, sha)`` for one file on a branch; ``(None, None)`` when it is not there."""
    status, raw = github.request(f"{API}/repos/{repo}/contents/{path}?ref={branch}")
    if status == 404:
        return None, None
    if status >= 300:
        sys.exit(f"sync_store: reading {branch}:{path} -> {status}")
    document = json.loads(raw or b"{}")
    return base64.b64decode(document.get("content", "")).decode(), document.get("sha")


def put_contents(github: "GitHub", repo: str, branch: str, path: str, text: str,
                 message: str, sha: str | None) -> None:
    payload = {"message": message, "content": base64.b64encode(text.encode()).decode(), "branch": branch}
    if sha:
        payload["sha"] = sha
    github.json(f"{API}/repos/{repo}/contents/{path}", "PUT", payload)


def delete_contents(github: "GitHub", repo: str, branch: str, path: str, sha: str, message: str) -> None:
    github.json(f"{API}/repos/{repo}/contents/{path}", "DELETE",
                {"message": message, "sha": sha, "branch": branch})


def dead_pages_files(github: "GitHub", repo: str, branch: str) -> list[tuple[str, str, str]]:
    """Files on the Pages branch that should not be there: build artefacts and the old source.

    A sideloading front end fetches *its* source; a stray `.ipa` on Pages is only ever a download a
    visitor finds instead of the release page, and `source.json` belongs to the older tailnet
    publisher. Returns ``(path, sha, why)``.
    """
    status, raw = github.request(f"{API}/repos/{repo}/contents/?ref={branch}")
    if status == 404:
        return []
    if status >= 300:
        return []
    dead = []
    for row in json.loads(raw or b"[]"):
        name = row.get("name", "")
        if row.get("type") != "file":
            continue
        if name.lower().endswith(".ipa"):
            dead.append((name, row["sha"], "builds live on the release, not on Pages"))
        elif name == "source.json":
            dead.append((name, row["sha"], "the old tailnet publisher's manifest"))
    return dead


# --------------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync the AltStore source with the latest release.")
    parser.add_argument("--repo", default="macblizzard/hermey")
    parser.add_argument("--at", default=None, help="release tag (default: the latest release)")
    parser.add_argument("--check", action="store_true", help="report drift, change nothing, exit 1 on drift")
    parser.add_argument("--pages-branch", default="gh-pages")
    parser.add_argument("--readme-branch", default="main",
                        help="branch whose README carries the visible build line")
    parser.add_argument("--token", default=None)
    parser.add_argument("--notes", default="Native iOS and macOS client for your own Hermes agent.")
    args = parser.parse_args()

    github = GitHub(resolve_token(args.token))
    release = release_for(github, args.repo, args.at)
    ipa_asset = asset_named(release, ".ipa")
    if not ipa_asset:
        sys.exit(f"sync_store: release {release.get('tag_name')} has no .ipa asset")
    ipa = asset_bytes(github, ipa_asset)
    version, build, bundle = ipa_metadata(ipa)
    if not args.check:
        ensure_icon(github, args.repo, release)
    current, current_asset = served_manifest(github, release)
    wanted = desired_manifest(current, args.repo, ipa_asset, ipa, version, build, bundle, args.notes)

    print(f"release   {release['tag_name']}  ipa {ipa_asset['name']}  {version} ({build})  {len(ipa)} bytes")
    served_entry = ((current or {}).get("apps") or [{}])[0].get("versions") or [{}]
    served_entry = served_entry[0] if served_entry else {}
    wanted_entry = wanted["apps"][0]["versions"][0]
    manifest_drift = any(str(served_entry.get(k)) != str(wanted_entry.get(k)) for k in
                         ("version", "buildVersion", "downloadURL", "size", "sha256"))
    broken = [(label, url) for label, url in manifest_urls(current) if not url_ok(url)]
    for label, url in broken:
        print(f"broken    {label} {url}")
    if not manifest_drift and not broken:
        print("manifest  in sync")
    else:
        differ = [k for k in ("version", "buildVersion", "downloadURL", "size", "sha256")
                  if str(served_entry.get(k)) != str(wanted_entry.get(k))]
        if differ:
            print(f"manifest  DRIFT — {', '.join(differ)} differ "
                  f"(served {served_entry.get('version')} ({served_entry.get('buildVersion')}), "
                  f"wanted {version} ({build}))")
        else:
            print("manifest  DRIFT — a referenced URL does not load")

    # The two files a person reads before installing: the landing page and the repo README. Each
    # carries a marked build line, stamped from the IPA this run is about, so neither can sit on a
    # version that no longer exists.
    page_wanted = build_stamp.index_body(version, build, ipa_asset["name"])
    page_text, page_sha = contents(github, args.repo, args.pages_branch, "index.html")
    page_stamped = page_text is not None and build_stamp.current(page_text) is not None
    page_drift = page_stamped and not build_stamp.matches(page_text, page_wanted)
    if page_text is not None:
        print("pages     DRIFT — index.html advertises another build" if page_drift
              else "pages     in sync" if page_stamped
              else "pages     no build markers — left alone")

    readme_wanted = build_stamp.readme_body(version, build)
    readme_text, readme_sha = contents(github, args.repo, args.readme_branch, "README.md")
    readme_stamped = readme_text is not None and build_stamp.current(readme_text) is not None
    readme_drift = readme_stamped and not build_stamp.matches(readme_text, readme_wanted)
    if readme_text is not None:
        print("readme    DRIFT — README.md advertises another build" if readme_drift
              else "readme    in sync" if readme_stamped
              else "readme    no build markers — left alone")

    dead = dead_pages_files(github, args.repo, args.pages_branch)
    for name, _sha, why in dead:
        print(f"stale     gh-pages:{name} — {why}")

    drift = manifest_drift or bool(broken) or page_drift or readme_drift or bool(dead)

    for label, url in manifest_urls(wanted):
        if not url_ok(url):
            print(f"still broken after repair  {label} {url}")

    if args.check:
        return 1 if drift else 0

    if manifest_drift or broken:
        payload = (json.dumps(wanted, indent=2) + "\n").encode()
        upload_asset(github, args.repo, release, "altstore.json", payload, JSON_TYPE)
        print("uploaded  altstore.json -> release asset")
        if update_pages(github, args.repo, args.pages_branch, "altstore.json", payload):
            print("updated   gh-pages altstore.json")

    if page_drift and page_text is not None:
        stamped = build_stamp.replace(page_text, page_wanted)
        if stamped is not None:
            put_contents(github, args.repo, args.pages_branch, "index.html", stamped,
                         f"pages: build {version} ({build})", page_sha)
            print("updated   gh-pages index.html")

    if readme_drift and readme_text is not None:
        stamped = build_stamp.replace(readme_text, readme_wanted)
        if stamped is not None:
            put_contents(github, args.repo, args.readme_branch, "README.md", stamped,
                         f"readme: build {version} ({build})", readme_sha)
            print("updated   README.md")

    for name, sha, _why in dead:
        delete_contents(github, args.repo, args.pages_branch, name, sha,
                        f"pages: drop {name} (builds are release assets)")
        print(f"removed   gh-pages:{name}")

    failures = []
    for label, url in (("release", f"https://github.com/{args.repo}/releases/latest/download/altstore.json"),
                       ("pages", f"https://{args.repo.split('/')[0]}.github.io/{args.repo.split('/')[1]}/altstore.json")):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                served = json.loads(response.read())
            newest = served["apps"][0]["versions"][0]
            ok = newest["version"] == version and str(newest["buildVersion"]) == build
            print(f"{label:<9} {'ok' if ok else 'STALE'}  {newest['version']} ({newest['buildVersion']})")
            if not ok:
                failures.append(label)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            print(f"{label:<9} unreadable — {error}")
            failures.append(label)

    # Freshly uploaded release assets can 404 for a few seconds while the CDN catches up — but only
    # a run that actually uploaded something can be looking at that window. A failure with nothing
    # uploaded is a real one, and waiting ten seconds would only delay the report.
    if failures and (manifest_drift or page_drift or readme_drift):
        import time
        time.sleep(10)
        return main_verify_only(args.repo, version, build)
    return 1 if failures else 0


def main_verify_only(repo: str, version: str, build: str) -> int:
    owner, name = repo.split("/")
    bad = []
    for label, url in (("release", f"https://github.com/{repo}/releases/latest/download/altstore.json"),
                       ("pages", f"https://{owner}.github.io/{name}/altstore.json")):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                newest = json.loads(response.read())["apps"][0]["versions"][0]
            ok = newest["version"] == version and str(newest["buildVersion"]) == build
            print(f"{label:<9} {'ok' if ok else 'STALE'}  "
                  f"{newest['version']} ({newest['buildVersion']})")
            if not ok:
                bad.append(label)
        except Exception as error:  # noqa: BLE001 - report, do not raise, on a retry
            print(f"{label:<9} unreadable — {error}")
            bad.append(label)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
