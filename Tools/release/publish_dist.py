#!/usr/bin/env python3
"""The one writer of the served release directory.

Everything that ends up on `https://<host>:8444/` comes through this module: the artifacts, the
manifests that advertise them, the landing page, and the check that each of those is actually
downloadable over the wire afterwards. `publish_altstore.py` (GitHub release + Pages + mirror) calls
in here for the mirror half, and this module's CLI does the same publish on its own for a repair or a
rebuild from artifacts already on disk:

    python3 Tools/release/publish_dist.py --ipa build/Hermey-0.1.484-b484.ipa \\
        --dmg build/Hermey-macOS-unsigned.dmg --directory /srv/hermes-apps-dist \\
        --base-url https://hermes.corvus-vibes.ts.net:8444 --notes "..."

Why it is built this way, each rule paid for by a real failure:

* **Manifests are generated from the artifact just staged**, by re-reading the *published* file's
  size and sha256 — never from the arguments, never hand-edited. `source.json` on the host once sat
  at `0.1.52` for ~430 builds because a second script wrote it and nothing compared it with the
  newest file in the directory.
* **Nothing is written in place.** A 10 MB disk image copied over a live `SimpleHTTPRequestHandler`
  is downloadable mid-copy: a truncated file with a 200 and a Content-Length that lies. Each artifact
  goes to `.incoming-<pid>-<name>` in the same directory, is fsynced, then `os.replace`d — one
  atomic rename on the same filesystem.
* **Published means verified.** After staging, every URL the manifests advertise is fetched over the
  real origin, and its length and sha256 are compared with the bytes on disk; then the manifests are
  re-fetched and their newest build is compared with the build just staged. Any mismatch is a
  non-zero exit with the reason, because a publish that cannot say what it published is not one.
* **The DMG filename is versioned** (`Hermey-macOS-0.1.484.dmg`). The IPA always was; the disk image
  was one name forever, which is how a fresh Mac install ran a build from hours earlier. The stable
  name survives as a byte-identical alias written in the same publish, for links already in the wild.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import shutil
import ssl
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from publish_source import read_ipa, safe_component  # noqa: E402  (same directory)

TINT = "#007CF7"
SOURCE_NAME = "Hermey"
SOURCE_ID = "dev.hermey.app.source"
#: Links already in a message thread, a bookmark or an old release note. Written every publish, so it
#: can never be a different build from the versioned name beside it.
STABLE_DMG_ALIAS = "Hermey-macOS-unsigned.dmg"
MANIFEST_NAMES = ("altstore.json", "source.json")


def stage(source: Path, directory: Path, name: str) -> Path:
    """Copy `source` into `directory/name` atomically: no reader ever sees a partial file."""
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / name
    incoming = directory / f".incoming-{os.getpid()}-{name}"
    try:
        shutil.copyfile(source, incoming)
        shutil.copystat(source, incoming)
        with open(incoming, "rb") as handle:
            os.fsync(handle.fileno())
        os.replace(incoming, target)
    finally:
        if incoming.exists():
            incoming.unlink()
    return target


def write_atomic(path: Path, text: str) -> None:
    """Same discipline for a manifest: a half-written source is a sideloader reading garbage."""
    incoming = path.with_name(f".incoming-{os.getpid()}-{path.name}")
    try:
        incoming.write_text(text, encoding="utf-8")
        with open(incoming, "rb") as handle:
            os.fsync(handle.fileno())
        os.replace(incoming, path)
    finally:
        if incoming.exists():
            incoming.unlink()


def digest_of(path: Path) -> tuple[int, str]:
    """Size and sha256 of the bytes that are actually on disk."""
    hasher = hashlib.sha256()
    size = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
            size += len(chunk)
    return size, hasher.hexdigest()


def fetch(url: str, timeout: float = 60, insecure: bool = False) -> bytes:
    context = ssl._create_unverified_context() if insecure else None  # noqa: S323 (opt-in only)
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        if response.status != 200:
            raise RuntimeError(f"{url} answered {response.status}")
        return response.read()


def verify(directory: Path, base_url: str, names: list[str], version: str, build: str,
           attempts: int = 6, insecure: bool = False) -> None:
    """Prove what was published: every advertised URL, then the manifests that advertise them.

    Retried because the origin is a TLS front end over a loopback file server, and a rename landing
    while a request is in flight can surface the previous file once; a publish that only *usually*
    verifies is the behaviour this whole module exists to replace.
    """
    base = base_url.rstrip("/")
    problems: list[str] = []
    for attempt in range(1, attempts + 1):
        problems = []
        stamp = f"cb={int(time.time())}{attempt}"
        for name in names:
            expected_size, expected_sha = digest_of(directory / name)
            try:
                body = fetch(f"{base}/{name}?{stamp}", insecure=insecure)
            except Exception as error:  # noqa: BLE001 (the reason is the report)
                problems.append(f"{name}: {error}")
                continue
            if len(body) != expected_size:
                problems.append(f"{name}: served {len(body)} bytes, on disk {expected_size}")
            elif hashlib.sha256(body).hexdigest() != expected_sha:
                problems.append(f"{name}: served bytes differ from the file on disk")
        for manifest in MANIFEST_NAMES:
            try:
                document = json.loads(fetch(f"{base}/{manifest}?{stamp}", insecure=insecure))
            except Exception as error:  # noqa: BLE001
                problems.append(f"{manifest}: {error}")
                continue
            newest = ((document.get("apps") or [{}])[0].get("versions") or [{}])[0]
            if str(newest.get("buildVersion")) != build or str(newest.get("version")) != version:
                problems.append(f"{manifest}: advertises {newest.get('version')} "
                                f"({newest.get('buildVersion')}), published {version} ({build})")
            advertised = (newest.get("downloadURL") or "").rsplit("/", 1)[-1]
            if advertised not in names:
                problems.append(f"{manifest}: downloadURL names {advertised!r}, "
                                f"which this publish did not stage")
        if not problems:
            print(f"  verified {len(names)} artifacts + {len(MANIFEST_NAMES)} manifests over the wire")
            return
        if attempt < attempts:
            time.sleep(1.5)
    raise SystemExit("publish verification failed:\n  " + "\n  ".join(problems))


def source_document(info: dict, entry: dict, base_url: str, notes: str) -> dict:
    """One document, generated from the staged artifact: version, build, size and sha256 all come
    from the entry, which was measured on the file that was just renamed into place."""
    base = base_url.rstrip("/")
    version = entry["version"]
    build = entry["buildVersion"]
    bundle = str(info["CFBundleIdentifier"])
    return {
        "name": SOURCE_NAME,
        "identifier": SOURCE_ID,
        "subtitle": "Your Hermes bots, on your phone",
        "description": (
            "Native client for a self-hosted Hermes Agent. Every bot (Hermes profile) is reachable "
            "through one gateway; approvals, streaming replies and tool output appear in the "
            "conversation. Builds are unsigned and must be re-signed by your sideloading app."
        ),
        "iconURL": f"{base}/icon-512.png",
        "headerURL": f"{base}/app-icon-1024.png",
        "tintColor": TINT,
        "featuredApps": [bundle],
        "apps": [{
            "name": SOURCE_NAME,
            "bundleIdentifier": bundle,
            "developerName": "Hermey",
            "subtitle": "Your Hermes bots, on your phone",
            "localizedDescription": (
                "Chats with every Hermes bot, streaming replies, tool cards, inline approvals and "
                "per-device pairing."
            ),
            "iconURL": f"{base}/icon-512.png",
            "tintColor": TINT,
            "category": "utilities",
            "screenshots": [],
            # One entry, deliberately: the directory keeps only the newest IPA, so a longer history
            # would advertise sha256s for bytes that are no longer on disk.
            "versions": [entry],
            "appPermissions": {"entitlements": [], "privacy": {
                "NSCameraUsageDescription": "Scan the pairing code shown by your Hermes host to connect this device.",
                "NSLocalNetworkUsageDescription": "Hermes connects to your own Hermes host over your private network.",
            }},
        }],
        "news": [{
            "title": f"Hermes {version} ({build})",
            "identifier": f"hermes-{version}-{build}",
            "caption": notes or f"Build {build}",
            "date": entry["date"],
            "tintColor": TINT,
        }],
    }


def landing_page(base_url: str, version: str, build: str, ipa_name: str, ipa_size: int,
                 dmg_name: str | None, dmg_size: int | None) -> str:
    base = base_url.rstrip("/")
    items = [f"<li><a href='source.json'>source.json</a> — add this in your sideloading app</li>",
             f"<li><a href='{html.escape(ipa_name)}'>{html.escape(ipa_name)}</a> ({ipa_size // 1024} KB)</li>"]
    if dmg_name:
        items.append(f"<li><a href='{html.escape(dmg_name)}'>{html.escape(dmg_name)}</a>"
                     f" ({(dmg_size or 0) // 1024} KB)</li>")
        items.append(f"<li><a href='{html.escape(STABLE_DMG_ALIAS)}'>{html.escape(STABLE_DMG_ALIAS)}</a>"
                     " — same build, stable name</li>")
    return (
        "<!doctype html><meta charset=utf-8><title>Hermey builds</title>"
        "<body style='font:15px -apple-system,sans-serif;background:#1a1a1a;color:#dcdcdc;padding:28px'>"
        f"<h2 style='margin:0 0 4px'>Hermey {html.escape(version)} ({html.escape(build)})</h2>"
        f"<p style='color:#979797'>Add <code>{base}/source.json</code> to your sideloading app.</p>"
        f"<ul>{''.join(items)}</ul></body>"
    )


def publish(directory: Path, base_url: str, ipa: Path, dmg: Path | None, notes: str,
            verify_wire: bool = True, insecure: bool = False,
            keep_dmg_alias: bool = True) -> dict:
    """Stage the artifacts, generate both manifests from them, then prove it over the wire."""
    info = read_ipa(ipa)
    version = safe_component(info["CFBundleShortVersionString"])
    build = safe_component(info["CFBundleVersion"])

    ipa_name = f"Hermey-{version}-b{build}.ipa"
    staged_ipa = stage(ipa, directory, ipa_name)
    names = [ipa_name]
    size, sha = digest_of(staged_ipa)
    stamp = dt.datetime.fromtimestamp(staged_ipa.stat().st_mtime, dt.timezone.utc)
    print(f"  staged  {ipa_name}  ({size} bytes, sha256 {sha[:12]}…)")

    dmg_name: str | None = None
    dmg_size: int | None = None
    if dmg and dmg.is_file():
        dmg_name = f"Hermey-macOS-{version}.dmg"
        staged_dmg = stage(dmg, directory, dmg_name)
        dmg_size, _ = digest_of(staged_dmg)
        names.append(dmg_name)
        print(f"  staged  {dmg_name}  ({dmg_size} bytes)")
        if keep_dmg_alias:
            stage(dmg, directory, STABLE_DMG_ALIAS)
            names.append(STABLE_DMG_ALIAS)

    entry = {
        "version": version,
        "buildVersion": build,
        "date": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": notes or f"Build {build}.",
        "downloadURL": f"{base_url.rstrip('/')}/{ipa_name}",
        "size": size,
        "minOSVersion": str(info.get("MinimumOSVersion") or "17.0"),
        "sha256": sha,
    }
    document = source_document(info, entry, base_url, notes)
    payload = json.dumps(document, indent=2) + "\n"
    for manifest in MANIFEST_NAMES:
        write_atomic(directory / manifest, payload)
    write_atomic(directory / "index.html",
                 landing_page(base_url, version, build, ipa_name, size, dmg_name, dmg_size))
    print("  wrote   " + ", ".join([*MANIFEST_NAMES, "index.html"]))

    if verify_wire:
        verify(directory, base_url, names, version, build, insecure=insecure)
    else:
        print("  skipped wire verification (--no-verify)")
    return document


def latest_artifacts(directory: Path) -> tuple[Path, Path | None]:
    """Newest IPA and DMG already in the directory, for a manifest repair that rebuilds nothing."""
    ipas = sorted(directory.glob("Hermey-*.ipa"),
                  key=lambda p: p.stat().st_mtime)
    if not ipas:
        raise SystemExit(f"no Hermey-*.ipa in {directory}")
    dmgs = sorted(directory.glob("Hermey-macOS-*.dmg"), key=lambda p: p.stat().st_mtime)
    return ipas[-1], (dmgs[-1] if dmgs else None)


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--from-disk", action="store_true",
                        help="publish the newest artifacts already in --directory (a manifest repair)")
    parser.add_argument("--directory", type=Path, default=Path("/srv/hermes-apps-dist"))
    parser.add_argument("--base-url", default="https://hermes.corvus-vibes.ts.net:8444")
    parser.add_argument("--notes", default="")
    parser.add_argument("--no-verify", action="store_true")
    parser.add_argument("--insecure", action="store_true",
                        help="skip TLS verification for the wire check (self-signed origins only)")
    args = parser.parse_args()

    if args.from_disk:
        ipa, dmg = latest_artifacts(args.directory)
        print(f"  using   {ipa.name} + {dmg.name if dmg else 'no dmg'}")
    else:
        if not args.ipa:
            parser.error("--ipa is required unless --from-disk")
        ipa, dmg = args.ipa, args.dmg

    document = publish(args.directory, args.base_url, ipa, dmg, args.notes,
                       verify_wire=not args.no_verify, insecure=args.insecure)
    newest = document["apps"][0]["versions"][0]
    print()
    print(f"  published {newest['version']} ({newest['buildVersion']}) to {args.base_url.rstrip('/')}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
