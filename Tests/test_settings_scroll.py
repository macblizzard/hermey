"""A settings screen that lays out a list must also scroll.

The Mac's Integrations tab drew a LazyVGrid directly in a VStack, so with twelve services the first and last
rows were clipped by the window edge and there was nothing to scroll — the phone version had a ScrollView all
along, which is why the same screen was fine there.

These are static checks over the view sources: cheap, and they fail at the moment the mistake is made rather
than after a ten-minute app build and a manual look.
"""

from __future__ import annotations

import pathlib
import re

VIEWS = pathlib.Path(__file__).resolve().parent.parent / "Apps" / "HermesMac" / "Views"


def _swift_files() -> list[pathlib.Path]:
    return sorted(VIEWS.rglob("*.swift"))


def _code(text: str) -> str:
    """The file with comments removed.

    The first version of these tests searched raw text, so a comment mentioning "ScrollView" satisfied them and
    removing the actual ScrollView still passed. A guard that a comment can satisfy is not a guard.
    """
    without_blocks = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(line.split("//", 1)[0] for line in without_blocks.splitlines())


def test_every_mac_view_that_lays_out_a_grid_scrolls() -> None:
    offenders = []
    for path in _swift_files():
        text = _code(path.read_text(encoding="utf-8"))
        if "LazyVGrid" not in text and "LazyHGrid" not in text:
            continue
        if "ScrollView" not in text:
            offenders.append(path.name)
    assert not offenders, (
        "these Mac views lay out a grid with no ScrollView, so a long list is clipped instead of scrollable: "
        + ", ".join(offenders)
    )


def test_integrations_tab_scrolls_the_grid_not_the_whole_screen() -> None:
    """The header and the footer stay put; only the cards move."""
    text = _code((VIEWS / "IntegrationsTab.swift").read_text(encoding="utf-8"))
    assert "ScrollView" in text
    grid = text.index("LazyVGrid")
    scroll = text.index("ScrollView")
    assert scroll < grid, "the grid must be inside the scroll view, not beside it"


def test_the_phone_integrations_screen_also_scrolls() -> None:
    phone = pathlib.Path(__file__).resolve().parent.parent / "Apps" / "HermesMobile" / "Views" / "IntegrationsScreen.swift"
    text = _code(phone.read_text(encoding="utf-8"))
    assert "ScrollView" in text and text.index("ScrollView") < text.index("LazyVGrid")


def test_no_view_pins_a_grid_with_a_fixed_height() -> None:
    """A fixed height applied to the grid itself clips it; a fixed-height ScrollView is legitimate.

    The first version of this check flagged any `.frame(height:)` near a ScrollView, which accused the model
    sheet of a bug it does not have — a small list inside a form is exactly what a fixed-height scroll view is
    for. So the rule is narrower: the grid must not be the thing with the fixed height.
    """
    bad = []
    for path in _swift_files():
        text = _code(path.read_text(encoding="utf-8"))
        for match in re.finditer(r"LazyVGrid\(.*?\)\s*\{", text, flags=re.S):
            block = text[match.start(): match.start() + 2500]
            # up to the grid's own closing brace, look for a fixed height on the grid
            depth, end = 0, len(block)
            for index, char in enumerate(block):
                if char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        end = index
                        break
            if re.search(r"\.frame\(height:\s*\d+", block[:end]):
                bad.append(path.name)
    assert not bad, "a fixed height on the grid clips it: " + ", ".join(sorted(set(bad)))
