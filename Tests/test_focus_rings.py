"""One focus language: the accent ring is off every control, in one spelling.

The owner's report (2026-11-24): "i still see that swiftUI focus on many buttons throughout the
app showing the blue border around the buttons. could u find all of them and fix them?"

macOS draws that border — the focus effect, in the accent blue — around any focusable control
that holds keyboard focus, and puts it on the first focusable control in a window before the
pointer has moved. `Sources/HermeyUI/FocusQuiet.swift` names the decision
(`.hermeyFocusQuiet()`), and these tests hold the sweep to it. They read the Swift sources as
text: what is being checked is an arrangement, which a Linux test cannot compile.

Four rules:

* the modifier is defined once, in one file, and is the only spelling of it in the tree;
* every `Button`/`Toggle`/`Picker`/`Menu`/`Link`/`ShareLink`/`Stepper`/`Slider` construction in
  `Apps` and `Sources/HermeyUI` carries it — except the system menus (a `Menu`'s items,
  `.contextMenu`, and `Commands`), which never wore the ring;
* the two places where keyboard focus *is* the affordance — the sidebar's bot rows and the
  composer's model pill — still take focus and draw the app's own fill, not the ring;
* a control styled `.plain` is not a second, unfixed family: it carries the modifier too.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWEEP = [ROOT / "Apps", ROOT / "Sources" / "HermeyUI"]

CONVENTION = ROOT / "Sources" / "HermeyUI" / "FocusQuiet.swift"
MODIFIER = ".hermeyFocusQuiet()"

CONSTRUCTORS = ("Button", "Picker", "ColorPicker", "Toggle", "Menu", "Link",
                "NavigationLink", "ShareLink", "Stepper", "Slider")

#: Builders whose content is an `NSMenu`. The system draws those items and never rings them, and
#: a view modifier does not even compile inside `Commands`.
SYSTEM_MENU_CONTEXTS = {"Commands", "menu", "contextMenu"}

PAIRS = {"(": ")", "[": "]", "{": "}"}


# ------------------------------------------------------------------ reading Swift as text

def swift_files() -> list[Path]:
    return sorted(p for base in SWEEP for p in base.rglob("*.swift")
                  if "/.build/" not in str(p))


def masked(text: str) -> str:
    """The same text with comments and string bodies blanked, so brace counting is honest."""
    buf = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                buf[k] = " "
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if buf[k] != "\n":
                    buf[k] = " "
            i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            for k in range(i, j):
                if buf[k] != "\n":
                    buf[k] = " "
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            for k in range(i, min(j + 1, n)):
                if buf[k] != "\n":
                    buf[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(buf)


def group_end(clean: str, i: int) -> int:
    """Index just past the bracketed group that opens at `i`."""
    depth = 0
    while i < len(clean):
        c = clean[i]
        if c in PAIRS:
            depth += 1
        elif c in PAIRS.values():
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise AssertionError("unbalanced group")


CLAUSE_LABELS = ("label", "role", "message", "actions", "content", "isOn", "selection",
                 "value", "systemImage", "title")


def chain_span(clean: str, start: int) -> tuple[int, int]:
    """`(body_end, chain_end)` for the construction that begins at `start`.

    `body_end` is the end of the control's own body; `chain_end` the end of the modifiers that
    hang off it. SwiftUI spells a control as `Button { } label: { } .style(...).other(...)`, so
    the walk takes groups, `label:`-style clauses, then dotted modifiers.
    """
    i = start
    while i < len(clean) and clean[i] not in "({":
        i += 1
    groups = 0
    while i < len(clean):
        while i < len(clean) and clean[i] in " \n\t":
            i += 1
        if i < len(clean) and clean[i] in "([{":
            i = group_end(clean, i)
            groups += 1
            continue
        m = re.match(r"(%s)\s*:" % "|".join(CLAUSE_LABELS), clean[i:])
        if m:
            i += m.end()
            while i < len(clean) and clean[i] in " \n\t":
                i += 1
            if i < len(clean) and clean[i] in "([{":
                i = group_end(clean, i)
                continue
        break
    if groups == 0:
        raise AssertionError("construction at %d has no body" % start)
    body_end = i
    while True:
        j = i
        while j < len(clean) and clean[j] in " \n\t":
            j += 1
        if j >= len(clean) or clean[j] != ".":
            break
        m = re.match(r"\.([A-Za-z_]\w*)", clean[j:])
        if not m:
            break
        k = j + m.end()
        while k < len(clean) and clean[k] in " \n\t":
            k += 1
        while k < len(clean) and clean[k] in "([{":
            k = group_end(clean, k)
            while k < len(clean) and clean[k] in " \n\t":
                k += 1
        i = k
    return body_end, i


def enclosing(clean: str) -> dict[int, tuple[str, ...]]:
    """Char index -> the builders around it, by name."""
    opens: list[tuple[int, str | None]] = []
    out: dict[int, tuple[str, ...]] = {}
    for i, ch in enumerate(clean):
        if ch == "{":
            prefix = re.sub(r"\s+", " ", clean[max(0, i - 160):i]).rstrip()
            opens.append((i, builder_name(prefix)))
        elif ch == "}":
            if opens:
                opens.pop()
        if opens:
            out[i] = tuple(n for _, n in opens if n)
    return out


def builder_name(prefix: str) -> str | None:
    if not prefix:
        return None
    if prefix.endswith(".commands"):
        return "Commands"
    if prefix.endswith(".contextMenu"):
        return "contextMenu"
    if re.search(r"(?<![\w.])Menu\s*$", prefix):
        return "menu"
    m = re.search(r"([A-Za-z_][\w.]*)\s*(\([^()]*\))?\s*$", prefix)
    return m.group(1) if m else None


def controls(path: Path):
    """`(line, name, chain_text, contexts)` for every focusable construction in one file."""
    text = path.read_text(encoding="utf-8")
    clean = masked(text)
    ctx = enclosing(clean)
    for m in re.finditer(r"(?<![\w.])(%s)(?![\w])" % "|".join(CONSTRUCTORS), clean):
        tail = clean[m.end():m.end() + 60].lstrip()
        if not (tail.startswith("{") or tail.startswith("(")):
            continue
        try:
            _, end = chain_span(clean, m.start())
        except AssertionError:
            continue
        yield (text.count("\n", 0, m.start()) + 1, m.group(1), text[m.start():end],
               ctx.get(m.start(), ()))


def is_system_menu(contexts: tuple[str, ...]) -> bool:
    return any(c in SYSTEM_MENU_CONTEXTS for c in contexts)


# ------------------------------------------------------------------ the rules

class TheConventionExistsOnce(unittest.TestCase):
    """One spelling, one file: `.hermeyFocusQuiet()`."""

    def test_the_modifier_is_defined_in_one_file(self) -> None:
        definitions = [p for p in swift_files()
                       if re.search(r"func\s+hermeyFocusQuiet\s*\(", p.read_text(encoding="utf-8"))]
        self.assertEqual([p.relative_to(ROOT).as_posix() for p in definitions],
                         ["Sources/HermeyUI/FocusQuiet.swift"])

    def test_it_is_exactly_the_system_modifier(self) -> None:
        body = CONVENTION.read_text(encoding="utf-8")
        self.assertIn("func hermeyFocusQuiet() -> some View {", body)
        self.assertIn("focusEffectDisabled()", body)

    def test_nothing_else_spells_the_system_modifier(self) -> None:
        # A bare `.focusEffectDisabled()` anywhere else is a second way to say this, and the next
        # person would not know which one to copy.
        offenders = []
        for path in swift_files():
            if path == CONVENTION:
                continue
            text = masked(path.read_text(encoding="utf-8"))
            if ".focusEffectDisabled(" in text:
                offenders.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(offenders, [])

    def test_the_doc_says_why(self) -> None:
        body = CONVENTION.read_text(encoding="utf-8")
        # The reason the ring is wrong here, not just the instruction to remove it.
        self.assertIn("accent blue", body)
        self.assertIn("tab stop", body)


class EveryControlWearsIt(unittest.TestCase):
    """The sweep: not the ones that were easy."""

    def test_every_construction_is_covered(self) -> None:
        missing = []
        covered = 0
        for path in swift_files():
            for line, name, chain, contexts in controls(path):
                if is_system_menu(contexts):
                    continue
                if MODIFIER in chain:
                    covered += 1
                else:
                    missing.append(f"{path.relative_to(ROOT)}:{line} {name}")
        self.assertEqual(missing, [], "controls without %s:\n  %s" % (MODIFIER, "\n  ".join(missing[:40])))
        # The list this replaced was 170 buttons; the sweep is much wider than that, and a rule
        # that quietly stopped finding them would still pass the check above.
        self.assertGreaterEqual(covered, 380, f"only {covered} controls carry the modifier")

    def test_the_whole_tree_is_scanned(self) -> None:
        files = swift_files()
        self.assertGreater(len(files), 150)
        self.assertTrue(any("HermesMobile" in p.as_posix() for p in files))
        self.assertTrue(any("HermesMac" in p.as_posix() for p in files))
        self.assertTrue(any("Sources/HermeyUI" in p.as_posix() for p in files))

    def test_each_control_kind_appears(self) -> None:
        # If the scanner stopped recognising a kind, the coverage test would pass by finding
        # nothing to check. These are the kinds the app actually uses, and they must be seen.
        kinds: dict[str, int] = {}
        for path in swift_files():
            for _, name, chain, contexts in controls(path):
                if is_system_menu(contexts):
                    continue
                kinds[name] = kinds.get(name, 0) + 1
        for kind in ("Button", "Toggle", "Picker", "Menu", "Link", "ShareLink"):
            self.assertGreater(kinds.get(kind, 0), 0, f"no {kind} construction was found")

    def test_the_system_menus_are_left_alone(self) -> None:
        # The opposite failure: stamping a view modifier into a `Commands` builder or an NSMenu
        # item. Those never wore the ring, and the modifier would not compile in `Commands`.
        offenders = []
        for path in swift_files():
            for line, name, chain, contexts in controls(path):
                if is_system_menu(contexts) and MODIFIER in chain:
                    offenders.append(f"{path.relative_to(ROOT)}:{line} {name}")
        self.assertEqual(offenders, [], "system menu items were modified:\n  " + "\n  ".join(offenders))

    def test_no_plain_control_is_a_second_family(self) -> None:
        # `.buttonStyle(.plain)` removed the chrome; it never removed the ring. A plain control
        # without the convention is exactly the one the owner photographed.
        missing = []
        for path in swift_files():
            for line, name, chain, contexts in controls(path):
                if is_system_menu(contexts):
                    continue
                if ".buttonStyle(.plain)" in chain and MODIFIER not in chain:
                    missing.append(f"{path.relative_to(ROOT)}:{line} {name}")
        self.assertEqual(missing, [], "plain controls without the convention:\n  " + "\n  ".join(missing))


class KeyboardStopsKeepTheirOwnAffordance(unittest.TestCase):
    """Hiding the ring must not mean "cannot tab"."""

    def setUp(self) -> None:
        self.rows = (ROOT / "Apps" / "HermesMac" / "Sidebar" / "SidebarBotList.swift").read_text(encoding="utf-8")
        self.pill = (ROOT / "Sources" / "HermeyUI" / "ComposerModelPill.swift").read_text(encoding="utf-8")

    def test_the_bot_row_still_takes_focus(self) -> None:
        self.assertIn(".focused($focusedRow, equals: bot.id)", self.rows)
        # `focusable(false)` would have been the cheap way to make the ring go away, and it takes
        # the row out of the tab order — the row is a keyboard stop, so it is not used.
        self.assertNotIn(".focusable(false)", self.rows)
        self.assertIn(MODIFIER, self.rows)

    def test_the_bot_row_draws_its_own_focus(self) -> None:
        # The ring is replaced by the row's existing "live" state: the hover fill and its hairline,
        # on the focus the row already tracks. The ⋯ it used to reveal is gone (2026-11-25), so the
        # row's own focus is the only focus state left on it.
        self.assertIn("let holdsKeyboardFocus = focusedRow == bot.id", self.rows)
        self.assertIn("isHovered || holdsKeyboardFocus ? Tokens.controlHover", self.rows)
        self.assertIn("(isHovered || holdsKeyboardFocus) && !isSelected ? 1 : 0", self.rows)
        # And not the accent: a focused row is not a selected one.
        focus_lines = [l for l in self.rows.splitlines() if "holdsKeyboardFocus ?" in l]
        self.assertTrue(focus_lines)
        for line in focus_lines:
            self.assertNotIn("accent", line)

    def test_the_composer_pill_still_takes_focus(self) -> None:
        self.assertIn("@FocusState private var isFocused: Bool", self.pill)
        self.assertIn(".focused($isFocused)", self.pill)
        self.assertIn(MODIFIER, self.pill)
        self.assertNotIn(".focusable(false)", self.pill)

    def test_the_composer_pill_draws_its_own_focus(self) -> None:
        # The pill's one fill carries it — the same step the pointer gets, and no rim (a rim inside
        # the field would read as a text field inside the field).
        fill = [l for l in self.pill.splitlines() if "Capsule().fill(" in l]
        self.assertEqual(len(fill), 1)
        self.assertIn("isEnabled && (isHovered || isFocused) ? Tokens.controlHover", fill[0])
        # The accent is the ring's colour; the pill's focus state is the chrome's own fill.
        self.assertNotIn("accent", fill)


if __name__ == "__main__":
    unittest.main()
