"""A reply that lands on the bot on screen must be on screen, without touching anything.

Reported (again, and old): the owner asked cody "update?", the bot list's preview moved to the new
message, the open pane still showed the previous answer under `(´･_･`) musing…`, and the reply only
appeared after switching to another bot and back.

The two readers disagree by construction, and this time the disagreement is *not* the cache:

* the list's third line is fed by the sweep, which reads the host over HTTP and needs no session id;
* the transcript is fed by the socket, whose frames of a live turn carry **no** session id — the
  gateway routes them to "the session this connection last attached", and this client keeps that as
  one pair of ids on the actor. Every `session.resume` overwrites them, so a competing attach (an
  event naming a session the window could not place, a prefetch release, a re-read) can hand the
  turn's completion to a session that is not the one on screen.

`message.complete` was then dropped by the "is this the open conversation" guard, and it was the
*only* branch that committed the streamed text and cleared the thinking row: the pane kept the old
answer and the bubble, the host had the reply, and the bot list showed it. The existing recovery
(`scheduleOpenRefresh`) re-read the transcript — which is not enough, because
`refreshTranscript` then adopted the host's rows and left `isStreaming` exactly as it found it, and
because the id it re-read could be the one the host had stopped resolving.

So: a read is the authority on whether a turn is still running. If the host says it is not, the
turn is finished from the host's answer, keeping the words this client already streamed. If the id
on screen no longer resolves, the read follows the conversation the host says the bot owns now.
And a turn with no frame at all for the stall threshold — already detected and logged — is read back
once instead of waiting for a person to leave the chat.
"""

from __future__ import annotations

import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
APPMODEL = REPO_ROOT / "Sources" / "HermesAppKit" / "AppModel.swift"
SCROLL = REPO_ROOT / "Apps" / "HermesMac" / "Conversation" / "TranscriptScroll.swift"
IOS_SCREEN = REPO_ROOT / "Apps" / "HermesMobile" / "Views" / "ConversationScreen.swift"


def member(text: str, signature: str) -> str:
    """The body of one 4-space-indented Swift member, from its signature to its closing brace."""
    start = text.index(signature)
    rest = text[start:]
    return rest[: rest.index("\n    }\n") + len("\n    }\n")]


class AFinishedTurnLandsWithoutAnInteraction(unittest.TestCase):
    def setUp(self) -> None:
        self.text = APPMODEL.read_text(encoding="utf-8")

    def test_a_read_notices_that_the_host_has_stopped_running_the_turn(self) -> None:
        body = member(self.text, "private func refreshTranscript(_ sid: SessionID) async -> Bool")
        # Both facts are read *before* the await: after it, `isStreaming` may already have been
        # changed by another event, and the comparison would ask the wrong question.
        self.assertIn("let streamed = streamedText", body)
        self.assertIn("let wasStreaming = isStreaming", body)
        self.assertLess(body.index("let wasStreaming = isStreaming"),
                        body.index("client.resumeSession(sid"),
                        "the flag has to be captured before the host is asked")
        self.assertIn("if wasStreaming, !resumed.isStreaming {", body)
        self.assertIn("finishTurn(from: resumed, session: sid, streamed: streamed)", body)

    def test_the_finished_turn_commits_what_was_streamed(self) -> None:
        body = member(self.text, "private func finishTurn(from resumed: SessionResume, session: SessionID,")
        # The host's rows, plus the words only this client received: the answer is whatever the two
        # of them say, and the host's copy may not have been persisted yet when it answered.
        self.assertIn("var entries = resumed.entries", body)
        self.assertIn('let text = streamed.isEmpty ? resumed.liveText : streamed', body)
        self.assertIn('TranscriptEntry(id: "recovered-\\(session)-\\(entries.count)"', body)
        self.assertIn("adoptResume(entries, cursor: resumed.earlierCursor", body)
        self.assertIn("remember(session, entries: transcript", body)
        self.assertIn("cacheTranscriptSoon(session)", body)

    def test_the_read_path_replaces_the_retry_that_reported_nothing(self) -> None:
        # `refreshTranscript` used to be `Void`, so the caller could not tell a refused id from an
        # answered one and nothing else was ever asked. It answers now, and the caller acts on it.
        self.assertIn("@discardableResult\n    private func refreshTranscript(_ sid: SessionID) async -> Bool",
                      self.text)
        self.assertIn("guard selectedSessionID == sid else { return false }", self.text)


class TheIndicatorClearsWhenTheTurnEnds(unittest.TestCase):
    def setUp(self) -> None:
        self.body = member(APPMODEL.read_text(encoding="utf-8"),
                           "private func finishTurn(from resumed: SessionResume, session: SessionID,")

    def test_the_host_s_own_verdict_sets_the_flags(self) -> None:
        # `adopt` is the one place that writes `isStreaming` from a resume; finishing the turn must
        # go through it rather than clearing the flag by hand, or the two can disagree again.
        self.assertIn("adopt(resumed, session: session)", self.body)
        self.assertIn("runningSessions.remove(session)", self.body)

    def test_the_bubble_and_the_reasoning_go_with_it(self) -> None:
        adopt_at = self.body.index("adopt(resumed, session: session)")
        streamed_at = self.body.index('setStreamed("")')
        # `adopt` writes the host's live text into the bubble; the clear has to come after it.
        self.assertLess(adopt_at, streamed_at)
        self.assertIn('reasoningText = ""', self.body)
        self.assertIn("liveTools = []", self.body)
        self.assertIn("sealedInterimKeys.removeAll()", self.body)

    def test_the_pane_is_told_to_land_on_the_new_rows(self) -> None:
        # The rows are replaced in place, so the scroll view keeps the offset it had — the reply is
        # painted below the fold. `transcriptReloads` is how the shells land at the newest message.
        self.assertIn("transcriptReloads += 1", self.body)


class ANewerSessionIsAppliedWhileThePaneIsOpen(unittest.TestCase):
    def setUp(self) -> None:
        self.text = APPMODEL.read_text(encoding="utf-8")

    def test_a_failed_re_read_asks_the_host_where_the_conversation_went(self) -> None:
        body = member(self.text, "private func scheduleOpenRefresh()")
        self.assertIn("let read = await self.refreshTranscript(sid)", body)
        self.assertIn("if !read {", body)
        self.assertIn("await self.followMovedConversation(insteadOf: sid)", body)

    def test_the_moved_conversation_is_resolved_the_way_opening_the_bot_resolves_it(self) -> None:
        body = member(self.text, "private func followMovedConversation(insteadOf stale: SessionID) async")
        # Not the id it was holding — that is the one the host just refused — and not a minted one.
        self.assertIn("newestExistingConversation(for: bot), moved != stale", body)
        self.assertIn("try await client.resumeSession(moved, profile: bot)", body)
        # The window may have moved while the host was answering.
        self.assertIn("guard epoch == botEpoch, selectedBotID == bot, selectedSessionID == stale else { return }",
                      body)
        self.assertIn("paintAdoptedConversation(resumed, named: moved, bot: bot, was: stale)", body)

    def test_a_different_durable_id_is_never_drawn_here(self) -> None:
        # The safety property the whole file rests on: the host's answer has to name the conversation
        # the roster offered, or one bot's words end up in another bot's chat.
        body = member(self.text, "private func followMovedConversation(insteadOf stale: SessionID) async")
        self.assertIn("guard resumed.storedSessionID == nil || resumed.storedSessionID == moved else {", body)
        self.assertNotIn("selectedSessionID = moved", body.split("guard resumed.storedSessionID")[0])

    def test_both_ways_a_conversation_moves_end_in_one_place(self) -> None:
        adopted = member(self.text, "private func adoptMovedConversation(_ session: SessionID,")
        followed = member(self.text, "private func followMovedConversation(insteadOf stale: SessionID) async")
        painter = member(self.text, "private func paintAdoptedConversation(_ resumed: SessionResume,")
        self.assertIn("paintAdoptedConversation(resumed, named: session, bot: bot, was: open)", adopted)
        self.assertIn("paintAdoptedConversation(resumed, named: moved, bot: bot, was: stale)", followed)
        # The paint itself: this bot owns the new id, the old rows go, the resume is adopted.
        self.assertIn("transcript = []", painter)
        self.assertIn("resetForMovedConversation()", painter)
        self.assertIn("selectedSessionID = session", painter)
        self.assertIn("sessionBots[session] = bot", painter)
        self.assertIn("adoptResume(resumed.entries", painter)


class AStrandedTurnIsReadBack(unittest.TestCase):
    def setUp(self) -> None:
        self.text = APPMODEL.read_text(encoding="utf-8")

    def test_silence_while_a_turn_runs_earns_one_read(self) -> None:
        body = member(self.text, "func noteWireSilence() async")
        self.assertIn("guard quiet >= Self.silenceThreshold else { return }", body)
        self.assertIn("guard !isCompressing, !sending, !silenceReadBack, let sid = selectedSessionID else { return }",
                      body)
        self.assertIn("silenceReadBack = true", body)
        self.assertIn("let read = await refreshTranscript(sid)", body)
        self.assertIn("await followMovedConversation(insteadOf: sid)", body)

    def test_one_read_per_stall_and_a_new_stall_may_ask_again(self) -> None:
        # A frame clears both flags, so a host that is quiet for an hour is asked once — and a turn
        # that stalls a second time is not silenced by the first stall's answer.
        body = member(self.text, "private func noteWireEvent(_ event: ClientEvent)")
        self.assertIn("silenceReported = false", body)
        self.assertIn("silenceReadBack = false", body)
        self.assertIn("private var silenceReadBack = false", self.text)

    def test_the_read_runs_on_the_sweep_s_clock_not_a_timer_of_its_own(self) -> None:
        sweep = member(self.text, "public func startUnreadSweep()")
        self.assertIn("await self.noteWireSilence()", sweep)
        # One sleep in the sweep, and it is the slow clock that already existed.
        self.assertEqual(sweep.count("Task.sleep"), 1)
        self.assertIn("Task.sleep(for: .seconds(Self.unreadSweepInterval))", sweep)
        self.assertIn("public static let unreadSweepInterval: TimeInterval = 25", self.text)


class ThePaneLandsOnWhatArrived(unittest.TestCase):
    """The Mac-only half of the same report: rows arrived and stayed below the fold."""

    def setUp(self) -> None:
        self.mac = SCROLL.read_text(encoding="utf-8")
        self.ios = IOS_SCREEN.read_text(encoding="utf-8")

    def test_the_mac_has_the_phone_s_handler_for_a_re_read(self) -> None:
        self.assertIn(".onChange(of: model.transcriptReloads)", self.ios)
        body = self.mac.split(".onChange(of: model.transcriptReloads)", 1)[1].split(".onChange(", 1)[0]
        self.assertIn("scrollRequest += 1", body, "the re-read's rows must be landed on")
        self.assertIn("followsBottom = true", body)

    def test_it_is_wired_next_to_the_other_follow_doors(self) -> None:
        body = self.mac.split(".onChange(of: model.isStreaming)", 1)[1].split(".onChange(of: search.query)", 1)[0]
        self.assertIn("model.transcriptReloads", body)
        self.assertIn("model.selectedSessionID", body)


if __name__ == "__main__":
    unittest.main()
