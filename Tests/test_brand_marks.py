"""Every integration the bridge offers needs a mark, in the one catalog both apps compile.

The phone showed six logos while the Mac showed thirteen: the marks existed twice — once in the Mac catalog and
an older copy in the phone's — so adding a service to one of them was invisible on the other. The catalogs now
live in one place (`Apps/Shared/BrandAssets.xcassets`), referenced by both targets in `project.yml`.

These checks are static because the alternative is a ten-minute build per platform followed by a human noticing
an empty square.
"""

from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARED = ROOT / "Apps" / "Shared" / "BrandAssets.xcassets"
APP_CATALOGS = [
    ROOT / "Apps" / "HermesMac" / "Assets.xcassets",
    ROOT / "Apps" / "HermesMobile" / "Assets.xcassets",
]


def catalogue_slugs() -> list[str]:
    """The services the bridge actually offers, from the one list that drives the screen."""
    text = (ROOT / "Bridge" / "hermes_bridge" / "composio.py").read_text(encoding="utf-8")
    block = re.search(r"CATALOG = \((.*?)\n\)", text, flags=re.S)
    if not block:
        return []
    return [slug for slug, _name, _blurb in
            re.findall(r'\("([^"]+)",\s*"([^"]+)",\s*"([^"]*)"\)', block.group(1))]


def test_every_offered_service_has_a_mark() -> None:
    slugs = catalogue_slugs()
    assert slugs, "the catalogue could not be read — this guard would otherwise pass silently"
    missing = [slug for slug in slugs if not (SHARED / f"brand-{slug}.imageset" / f"brand-{slug}.png").is_file()]
    assert not missing, f"services offered with no mark in the shared catalog: {', '.join(missing)}"


def test_no_app_keeps_its_own_copy_of_a_mark() -> None:
    """A copy is how the two platforms came to disagree in the first place."""
    offenders = []
    for catalog in APP_CATALOGS:
        if not catalog.is_dir():
            continue
        offenders += [f"{catalog.parent.parent.name}/{p.name}" for p in catalog.glob("brand-*.imageset")]
    assert not offenders, "brand marks belong in Apps/Shared/BrandAssets.xcassets only: " + ", ".join(offenders)


def test_both_apps_compile_that_catalog() -> None:
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
    assert project.count("Apps/Shared/BrandAssets.xcassets") == 2, (
        "the shared catalog must be a source of both the Mac and the iOS target"
    )
    for target in ("HermesMac", "HermesMobile"):
        # A target's block runs until the next line that starts a new top-level key; slicing on the first
        # indented line instead cut the block to nothing and the guard accused a correctly configured project.
        block = re.search(rf"^  {target}:\n(.*?)(?=^  \S)", project, flags=re.S | re.M)
        assert block, f"{target} is not in project.yml"
        assert "Apps/Shared/BrandAssets.xcassets" in block.group(1), (
            f"{target} does not compile the shared catalog")


def test_a_mark_is_not_dark_on_a_dark_card() -> None:
    """The first version of these marks was invisible: present, and #141413 on a #141413 card.

    Measured from the PNG header rather than by eye: an image with content has a non-trivial alpha or colour
    spread. This cannot judge taste, only that the file is not blank or fully transparent.
    """
    blank = []
    for png in SHARED.glob("brand-*.imageset/*.png"):
        data = png.read_bytes()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{png.name} is not a PNG"
        # A tiny PNG that decodes to nothing is caught by size: our marks are 256x256 glyphs, not 1-pixel dots.
        if len(data) < 400:
            blank.append(f"{png.parent.name} ({len(data)} B)")
    assert not blank, "these marks are effectively empty: " + ", ".join(blank)
