"""B2: looking a conversation up must not move the screen.

The failure: `endlessSession(for:)` selected the bot it was asked about, so a caller that only
wanted the id — a preview, a notification body, a background summary — captured the outgoing
transcript, reset the pane and switched `selectedBotID`. Several of those in flight is the
selection oscillating between bots while the owner reads one conversation.

The app target cannot be executed by this suite (it needs an Xcode build on a Mac), so these are
structure checks over the Swift source: that the two doors exist and stay apart, and that every
call site in `Sources/` and `Apps/` states which door it is using in the code itself.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"
SOURCE = APP.read_text(encoding="utf-8")
CLASSIFIED = ("[B2 navigation]", "[B2 lookup]", "[B2 bootstrap]")


def strip_comments(text: str) -> str:
    """Source with every `//` comment removed, so a doc reference is not mistaken for a call."""
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


def function_body(text: str, signature: str) -> str:
    """The braced body of the function whose declaration contains `signature`."""
    start = text.index(signature)
    open_brace = text.index("{", start)
    depth = 0
    for index in range(open_brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace:index]
    raise AssertionError(f"unbalanced braces after {signature}")


def call_sites(text: str) -> list[tuple[int, str]]:
    """Every `endlessSession(for: …)` call in code (not in a comment), as (line number, call)."""
    code = strip_comments(text)
    sites = []
    for match in re.finditer(r"endlessSession\(for:", code):
        open_paren = code.index("(", match.start())
        depth = 0
        for index in range(open_paren, len(code)):
            if code[index] == "(":
                depth += 1
            elif code[index] == ")":
                depth -= 1
                if depth == 0:
                    sites.append((code.count("\n", 0, match.start()) + 1,
                                  code[open_paren:index + 1]))
                    break
    return sites


class TheDoorsAreApart(unittest.TestCase):
    def test_the_open_takes_an_explicit_select(self) -> None:
        self.assertIn("public func endlessSession(for botID: String, select: Bool = true)",
                      SOURCE)

    def test_a_lookup_returns_before_anything_is_selected(self) -> None:
        body = function_body(SOURCE, "public func endlessSession(for botID: String, select: Bool")
        guard = body.index("guard select else { return await conversationID(for: botID) }")
        # Every side effect of navigation sits *after* the guard, so `select: false` cannot move.
        for effect in ("captureConversation(", "resetForBotSwitch(", "selectedBotID = botID",
                       "restoreConversation(", "isOpeningConversation ="):
            self.assertIn(effect, body)
            self.assertLess(guard, body.index(effect), f"{effect} must not run for a lookup")

    def test_the_lookup_door_touches_no_published_state(self) -> None:
        body = function_body(SOURCE, "public func conversationID(for botID: String) async -> SessionID?")
        for forbidden in ("selectedBotID =", "captureConversation(", "resetForBotSwitch(",
                          "restoreConversation(", "isOpeningConversation", "await select(",
                          "transcript =", "conversationCache["):
            self.assertNotIn(forbidden, body, f"a lookup must not do {forbidden}")

    def test_every_write_to_the_selection_says_which_kind_it_is(self) -> None:
        lines = SOURCE.splitlines()
        writes = [index for index, line in enumerate(lines)
                  if re.search(r"\bselectedBotID = ", line) and not line.lstrip().startswith("//")]
        self.assertTrue(writes)
        for index in writes:
            near = "\n".join(lines[max(0, index - 4):index])
            self.assertTrue(any(marker in near for marker in CLASSIFIED),
                            f"line {index + 1} selects a bot without a B2 classification")


class EveryCallSiteIsClassified(unittest.TestCase):
    def test_production_call_sites_name_their_door_and_carry_a_marker(self) -> None:
        # `Sources/` and `Apps/` only: the test targets open conversations on purpose, dozens of
        # times, and every one of those is navigation by construction.
        files = sorted(list((ROOT / "Sources").rglob("*.swift")) + list((ROOT / "Apps").rglob("*.swift")))
        found = 0
        for path in files:
            text = path.read_text(encoding="utf-8")
            for line, call in call_sites(text):
                found += 1
                self.assertIn("select:", call,
                              f"{path.relative_to(ROOT)}:{line} must say select: true/false")
                nearby = "\n".join(text.splitlines()[max(0, line - 6):line])
                self.assertTrue(any(marker in nearby for marker in CLASSIFIED),
                                f"{path.relative_to(ROOT)}:{line} needs a [B2 …] comment "
                                "classifying it as navigation or lookup")
        self.assertGreaterEqual(found, 5, "the audit found no call sites: the scanner is broken")

    def test_no_background_reader_uses_the_selecting_door(self) -> None:
        # A lookup in production is spelled `conversationID(for:)` or `select: false`. Anything else
        # in a sweep/preview/summary path is the B2 regression, so name the doors that must not
        # appear inside one.
        for path, marker in ((ROOT / "Sources/HermesAppKit/AppModel.swift", "func prefetchConversations("),):
            body = function_body(path.read_text(encoding="utf-8"), marker)
            self.assertNotIn("endlessSession(for:", strip_comments(body),
                             "the background sweep must resolve ids, not open conversations")


if __name__ == "__main__":
    unittest.main()
