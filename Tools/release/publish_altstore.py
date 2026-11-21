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
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_stamp  # noqa: E402  (same directory: the visible build line)
import publish_dist  # noqa: E402  (same directory: the one writer of the served directory)
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


#: CHANGELOG.md lives at the repo root, three levels up from `Tools/release/`.
CHANGELOG = Path(__file__).resolve().parent.parent.parent / "CHANGELOG.md"
#: The notes are read in Sparkle's update dialog, not as a document. `[Unreleased]` between releases
#: grows to tens of thousands of characters, and the whole of it made a 60 KB appcast for a dialog
#: with a three-line notes area — scrolled past, never read. Cut at a line boundary instead.
MAX_NOTE_CHARS = 4000


def _clip_notes(body: str) -> str:
    if len(body) <= MAX_NOTE_CHARS:
        return body
    cut = body.rfind("\n", 0, MAX_NOTE_CHARS)
    return body[:cut if cut > 0 else MAX_NOTE_CHARS].rstrip() + "\n…"


def changelog_notes(version: str) -> str:
    """The release notes, out of CHANGELOG.md rather than invented at publish time.

    This must stay **module level** and be called from `main()` — a previous attempt at this fix
    defined it inside `main()`, which left the publisher exit 0 without publishing anything.

    A release with an empty body is what the owner saw for several builds: `gh release create` fell
    back to "Build X (Y)." whenever `--notes` was missing, so nothing said what changed. The same
    string now feeds the release body, the appcast's `<description>` (what Sparkle draws in the
    update dialog), `mac.json` and both `altstore.json`s, so those four cannot disagree again.

    Prefers the section for this version, falls back to `[Unreleased]`, then to nothing at all —
    the caller decides what an empty answer means.
    """
    try:
        text = CHANGELOG.read_text(encoding="utf-8")
    except OSError:
        return ""
    for heading in (f"## [{version}]", "## [Unreleased]"):
        # The brackets make the match exact: `## [0.1.1]` must not answer for `## [0.1.14]`.
        match = re.search(rf"^{re.escape(heading)}", text, re.MULTILINE)
        if not match:
            continue
        # The rest of the heading line is the release date (`## [0.1.13] — 2026-11-09`), not news.
        line_end = text.find("\n", match.end())
        body = text[line_end + 1:] if line_end != -1 else ""
        # A section ends at the next `## ` heading; `###` subsections belong to it.
        end = re.search(r"^## ", body, re.MULTILINE)
        body = (body[:end.start()] if end else body).strip()
        if body:
            return _clip_notes(body)
    return ""


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

    # The Pages copy of the icon, refreshed every publish. It existed on `gh-pages` and was never
    # rewritten, so the source kept advertising an icon the app had stopped using — the manifest's
    # `iconURL` pointed at `main`, which was also frozen until the generator took it over.
    icon = work / "icon-512.png"
    if icon.exists():
        wanted_icon = icon.read_bytes()
        pages_icon, icon_sha = sync_store.contents_bytes(github, repo, "gh-pages", "icon-512.png")
        if wanted_icon != (pages_icon or b""):
            sync_store.put_bytes(github, repo, "gh-pages", "icon-512.png", wanted_icon,
                                 "pages: icon", icon_sha)
            print("  pages    icon-512.png updated")

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


DOWNLOADS_PAGE = """<!doctype html><meta charset="utf-8"><title>Hermey downloads</title>
<style>body{{font:16px/1.6 -apple-system,system-ui,sans-serif;max-width:44rem;margin:4rem auto;
padding:0 1.5rem;color:#111}}a{{color:#0b6bcb}}code{{background:#f2f2f2;padding:.15em .35em;border-radius:4px}}</style>
<h1>Hermey downloads</h1>
<p>This repo exists so the app has a download URL that does not go through GitHub's release CDN,
which stalls mid-transfer on some networks. The site links these files directly.</p>
<ul>
  <li><a href="{name}">Hermey for macOS, {version}</a> &mdash; disk image, unsigned</li>
  <li><a href="{alias}">{alias}</a> &mdash; the same build under the name older links use</li>
</ul>
<p>iPhone builds live with each release:
<a href="https://github.com/{repo}/releases">github.com/{repo}/releases</a>.</p>
<p>First launch on macOS: right-click &rarr; <strong>Open</strong>, or run
<code>xattr -dr com.apple.quarantine /Applications/Hermey.app</code>.</p>
"""


def push_to_downloads_repo(slug: str, dmg: Path, version: str, build: str, repo: str,
                           entry: dict, notes: str, info: dict, *, ios_entry: dict) -> dict:
    """Force-push a fresh single commit carrying the image, so the repo never accumulates blobs.

    This is the only public URL that is not GitHub's release CDN or the tailnet, and `docs/APPS.md`
    points at it — while nothing passed `--downloads-repo`, so it sat at a five-day-old build while
    the flag existed. It is published from the *same* artifact as the tailnet copy, under a versioned
    name, with the stable name written beside it in the same commit: a reader can tell which build
    they downloaded from the filename, and an old link still resolves to that same build.

    `ios_entry` is built from the IPA and passed separately from `entry` on purpose. This function
    publishes *two* kinds of artifact into one directory (the DMG, and the sideload source a phone
    reads), and the phone's manifest must describe the phone's file. The version of this that reused
    the mac-flavoured entry published `altstore.json` naming
    `.../v0.1.515/Hermey-macOS-unsigned.dmg`, so an iOS update check found an update and Safari
    downloaded a disk image. The identifier is checked below rather than trusted.
    """
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("--downloads-repo needs GITHUB_TOKEN in the environment")
    advertised = (ios_entry.get("downloadURL") or "").rsplit("/", 1)[-1]
    if not advertised.lower().endswith(".ipa"):
        raise SystemExit(
            f"--downloads-repo: altstore.json would advertise {advertised!r}, which is not the IPA")
    versioned = f"Hermey-macOS-{safe_component(version)}.dmg"
    owner, name = slug.split("/")
    pages_base = f"https://{owner}.github.io/{name}"
    size, digest = publish_dist.digest_of(dmg)
    dmg_url = f"{pages_base}/{versioned}"
    release_page = f"https://github.com/{repo}/releases/tag/v{safe_component(version)}"
    work = Path(tempfile.mkdtemp(prefix="hermey-downloads-"))
    try:
        run(["git", "init", "-q", "-b", "gh-pages"], cwd=work)
        shutil.copy2(dmg, work / versioned)
        shutil.copy2(dmg, work / publish_dist.STABLE_DMG_ALIAS)
        # The two feeds the apps read. Generated here from the same measured artifact that the
        # tailnet copy is generated from — the Pages channel is the one Mo installs from, so a page
        # that lists a build the apps cannot be told about is the failure this prevents.
        (work / "appcast.xml").write_text(
            publish_dist.appcast_document(entry, dmg_url, size,
                                          publish_dist.sparkle_signature(dmg), notes, release_page),
            encoding="utf-8")
        (work / "mac.json").write_text(
            publish_dist.mac_feed_document(entry, dmg_url, size, digest, notes), encoding="utf-8")
        # The iOS notifier reads `altstore.json` first and only falls back to `mac.json`, and it is
        # told to read it from Pages. Publishing the DMG without this file answered 404 exactly where
        # a phone looks first — and publishing it from the DMG's numbers answered 200 with a disk
        # image, which is worse: the phone offered the update and Safari downloaded a `.dmg`.
        (work / "altstore.json").write_text(
            json.dumps(publish_dist.source_document(
                info, ios_entry,
                publish_dist.Destination(
                    name="pages",
                    base_url=f"https://github.com/{repo}/releases/download/v{version}",
                    tint=publish_dist.TINT_GITHUB,
                    icon_url=f"https://raw.githubusercontent.com/{repo}/main/icon-512.png",
                    header_url=f"https://raw.githubusercontent.com/{repo}/main/icon-512.png",
                    source_url=f"https://github.com/{repo}/releases/latest/download/altstore.json",
                ),
                notes), indent=2) + "\n", encoding="utf-8")
        (work / "index.html").write_text(
            DOWNLOADS_PAGE.format(name=versioned, alias=publish_dist.STABLE_DMG_ALIAS,
                                  version=f"{version} (build {build})", repo=repo),
            encoding="utf-8")
        (work / ".nojekyll").write_text("", encoding="utf-8")
        # Read back before the temporary tree is removed: the verification below runs after the push
        # and must not depend on files that no longer exist.
        feed_bytes = {feed: (work / feed).read_bytes()
                      for feed in (*publish_dist.FEED_NAMES, "altstore.json")}
        run(["git", "add", "-A"], cwd=work)
        run(["git", "-c", "user.name=Hermey release", "-c", "user.email=release@hermey.local",
             "commit", "-q", "-m", f"downloads: {versioned} for {version} ({build})"], cwd=work)
        url = f"https://x-access-token:{token}@github.com/{slug}.git"
        run(["git", "push", "-q", "-f", url, "gh-pages:gh-pages"], cwd=work)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # The commit is what this publish can prove: GitHub's Pages build for the served URL takes tens
    # of seconds to minutes, so the served copy is verified on the API layer here and stated as
    # eventual in the docs, not claimed as wire-verified.
    sync_store.verify_pages_file(slug, versioned, size, sync_store.git_blob_sha(dmg.read_bytes()))
    for feed, payload in feed_bytes.items():
        sync_store.verify_pages_file(slug, feed, len(payload), sync_store.git_blob_sha(payload))
    # ...and then the served URLs themselves, which is what an app actually fetches. Pages lags the
    # commit by tens of seconds to minutes, so this retries rather than passing on a stale 200.
    publish_dist.verify_public_feeds(
        pages_base, version, build, [versioned, publish_dist.STABLE_DMG_ALIAS],
        manifests=("altstore.json",),
        # altstore.json advertises the IPA on the release; only the DMG is hosted here.
        elsewhere=(advertised,),
        attempts=int(os.environ.get("HERMEY_PAGES_ATTEMPTS", "6")),
        interval=float(os.environ.get("HERMEY_PAGES_RETRY_SECONDS", "30")),
    )
    return {
        "versioned": f"https://{slug.split('/')[0]}.github.io/{slug.split('/')[1]}/{versioned}",
        "stable": f"https://{slug.split('/')[0]}.github.io/{slug.split('/')[1]}/"
                  f"{publish_dist.STABLE_DMG_ALIAS}",
        "bytes": size,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", type=Path, required=True)
    # The Mac build is a disk image: it opens as a window with the app beside an Applications
    # shortcut, so installing is a drag rather than unzip-then-move.
    parser.add_argument("--mac-dmg", type=Path)
    # GitHub's release CDN stalls mid-download on some networks. With this, the image is also pushed
    # to a small Pages repo whose URL is a plain 200 with Content-Length and no redirect at all.
    parser.add_argument("--downloads-repo", help="owner/name whose gh-pages branch carries the image")
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
    # The wire check is the point of the mirror path; skipping it is for a host that cannot reach
    # its own origin (a container mid-bringup), and it says so loudly.
    parser.add_argument("--skip-mirror-verify", action="store_true")
    parser.add_argument("--insecure-mirror-verify", action="store_true")
    parser.add_argument("--skip-release-verify", action="store_true")
    args = parser.parse_args()

    info = read_ipa(args.ipa)
    version = str(info["CFBundleShortVersionString"])
    build = str(info["CFBundleVersion"])
    bundle = str(info["CFBundleIdentifier"])
    min_os = str(info.get("MinimumOSVersion") or "17.0")
    data = args.ipa.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    stamp = dt.datetime.fromtimestamp(args.ipa.stat().st_mtime, dt.timezone.utc)

    # **One string, every destination.** `--notes` when it was passed, else the CHANGELOG's section
    # for this version, else the old placeholder — computed once, before anything uses it. The
    # release body, the appcast's `<description>` (Sparkle's update dialog), `mac.json` and both
    # `altstore.json` files each used to read `args.notes` on their own, and since nothing ever
    # passed it the dialog said "Build 0.1.60x (60x)" while the changelog had the text all along.
    notes = (args.notes or changelog_notes(version) or f"Build {version} ({build}).").strip()
    print(f"  notes    {len(notes)} chars, from "
          f"{'--notes' if args.notes else 'CHANGELOG.md'}")

    # The tag names the *app*, not the build: a release whose tag disagrees with the version inside
    # the IPA is a support thread ("v22" beside an app that says 0.1.22"). Builds still differ per
    # run, which is what the sideload source compares.
    tag = f"v{safe_component(version)}"
    icon_url = ICON_URL.format(repo=args.repo)
    asset_name = f"Hermey-{safe_component(version)}-b{safe_component(build)}.ipa"
    download = f"https://github.com/{args.repo}/releases/download/{tag}/{asset_name}"

    if not release_has(args.repo, tag, asset_name):
        staging = Path(tempfile.mkdtemp())
        try:
            shutil.copy2(args.ipa, staging / asset_name)
            files = [str(staging / asset_name)]
            if args.mac_dmg and args.mac_dmg.exists():
                shutil.copy2(args.mac_dmg, staging / args.mac_dmg.name)
                files.append(str(staging / args.mac_dmg.name))
            run(["gh", "release", "create", tag, *files,
                 "-R", args.repo,
                 "--title", f"{SOURCE_NAME} {version} ({build})",
                 "--notes", notes])
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        print(f"  release {tag}: {asset_name}")
    else:
        # Re-running a publish is how an empty release body gets repaired: the same resolved notes
        # are rewritten, so the GitHub page and the appcast cannot say different things about a
        # build. Best-effort on purpose — a body that cannot be edited (a token without permission,
        # a release managed elsewhere) must not abort a publish whose appcast and manifests are
        # still correct.
        try:
            run(["gh", "release", "edit", tag, "-R", args.repo, "--notes", notes])
            print(f"  release {tag} already exists — notes rewritten, assets reused")
        except SystemExit as failure:
            print(f"  release {tag} already exists — body left as it was ({failure})")

    # The asset is one of the two destinations that is not ours; fetch it back. A fresh asset can
    # 404 on the CDN for ~30 s, which is what the retries are for — not for a wrong digest.
    if not args.skip_release_verify:
        publish_dist.verify_url(download, len(data), digest, "release asset", attempts=16)

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
        "localizedDescription": notes,
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
        # The document is not assembled here: `publish_dist.source_document` builds it from one
        # measured entry, and a Destination only rewrites where the bytes live. Two generators was
        # how the GitHub document and the mirror document drifted into disagreeing field by field.
        history: list[dict] = []
        if path.exists():
            try:
                previous = json.loads(path.read_text())
            except json.JSONDecodeError:
                previous = {}
            history = [version_entry
                       for version_entry in ((previous.get("apps") or [{}])[0].get("versions") or [])
                       if (version_entry.get("version"), version_entry.get("buildVersion"))
                       != (version, build)]
        document = publish_dist.source_document(
            info,
            entry,
            publish_dist.Destination(
                name="github",
                base_url=f"https://github.com/{args.repo}/releases/download/{tag}",
                tint=publish_dist.TINT_GITHUB,
                icon_url=icon_url,
                header_url=icon_url,
                source_url=f"https://github.com/{args.repo}/releases/latest/download/altstore.json",
            ),
            notes,
        )
        # Newest first. `altstore.json` is untracked in `main`, so in practice the clone has no
        # manifest and this list is exactly one entry — the history is carried by release assets,
        # which are never deleted, not by a document that is regenerated each time.
        document["apps"][0]["versions"] = [entry, *history][:args.keep]
        path.write_text(json.dumps(document, indent=2) + "\n")

        if args.mirror_to:
            # The served directory has exactly one writer, and it is not this file. `publish_dist`
            # stages each artifact atomically, generates `altstore.json`/`source.json`/`index.html`
            # from the file it just renamed into place, and fetches every advertised URL back over
            # the origin before returning. This used to be three scripts writing here and one
            # hand-maintained manifest, and the served `source.json` sat at 0.1.52 for ~430 builds.
            publish_dist.publish(args.mirror_to, args.mirror_base_url, args.ipa, args.mac_dmg,
                                 notes, verify_wire=not args.skip_mirror_verify,
                                 insecure=args.insecure_mirror_verify)

        icon = Path(__file__).resolve().parent / "app-icon-512.png"
        if icon.exists() and not (work / "icon-512.png").exists():
            shutil.copy2(icon, work / "icon-512.png")

        # `altstore.json` is deliberately *not* staged to `main`: it is generated, it names the
        # mirror host, and it is published where the docs point — the release asset and gh-pages.
        # Committing it here is what the tree's `.gitignore` forbids, and the secret scan refuses it.
        staged: list[str] = []
        if (work / "icon-512.png").exists():
            staged.append("icon-512.png")

        # The README carries the same marked build line as the landing page, stamped from this IPA,
        # so "which build is current?" cannot answer differently in the two places a person looks.
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
        if not staged or not run(["git", "-C", str(work), "status", "--porcelain"]).strip():
            print("  manifest already published — nothing to commit")
        else:
            run(["git", "-C", str(work), "add", *staged])
            run(["git", "-C", str(work), "-c", "user.name=assistant",
                 "-c", "user.email=hermey@users.noreply.github.com",
                 "commit", "-m", f"publish {version} ({build})"])
            run(["git", "-C", str(work), "push", "origin", "HEAD:main"])
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if args.downloads_repo and args.mac_dmg and args.mac_dmg.exists():
        # The phone's entry, built from the IPA's own bytes and never from the disk image: this is
        # what `altstore.json` on Pages advertises, and the whole point is that it cannot drift to
        # the mac artifact.
        ios_entry = {
            "version": version,
            "buildVersion": build,
            "date": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": notes,
            "downloadURL": download,
            "size": len(data),
            "minOSVersion": min_os,
            "sha256": digest,
        }
        # The appcast this writes is the one Sparkle reads: `notes` is what its `<description>` says.
        published = push_to_downloads_repo(args.downloads_repo, args.mac_dmg, version, build,
                                           args.repo, entry, notes, info, ios_entry=ios_entry)

        print(f"\n  mac      {published['versioned']}  ({published['bytes']} bytes)")
        print(f"  mac      {published['stable']}")

    print(f"\n  source   https://github.com/{args.repo}/releases/latest/download/altstore.json")
    print(f"  ipa      {download}  ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
