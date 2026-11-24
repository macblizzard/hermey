import XCTest
import HermesKit
@testable import HermeyUI

/// The eyes are the acting: each activity gets its own authored track, and every track blinks.
///
/// The reference's shipped shapes carry still eyes; its animated avatar is where the eye acting
/// lives (`logo-avatar-motion.ts`: `blink`, `idleX/Y`, `readingX/Y`, `readingLid`, `writingY`).
/// These tests pin the behaviour that was missing — eyes that move per state and visibly.
final class BotAvatarEyeMotionTests: XCTestCase {

    private let traits = BotAvatarMotionTraits(phase: 0, eyeLoop: 0)

    private func samples(_ activity: BotAvatarActivity,
                         seconds: Double = 5,
                         step: Double = 1.0 / 30.0) -> [BotAvatarEyePose] {
        stride(from: 0.0, through: seconds, by: step).map {
            BotAvatarMotion.eyePose(activity: activity, traits: traits, at: $0)
        }
    }

    func testReadingSweepsAcrossTheEyes() {
        // The base posture is eyeX = -10 (looking left, as the reference's reading state does) and
        // `readingX` adds up to +20 on top, so the gaze travels from -10 to +10 units — 1/6 of the
        // eye box either side of centre. What matters is that it *travels*, and comes back.
        let poses = samples(.reading, seconds: 10)
        let widest = poses.map(\.offsetX).max() ?? 0
        let narrowest = poses.map(\.offsetX).min() ?? 0
        XCTAssertGreaterThan(widest, 0.15, "reading should look right, like a line of text")
        XCTAssertLessThan(narrowest, -0.1, "…and return to the left, rather than parking right")
        XCTAssertGreaterThan(widest - narrowest, 0.25, "the sweep has to be visible, not a twitch")
    }

    func testIdleMovesLessThanReading() {
        let idle = samples(.idle, seconds: 10).map { abs($0.offsetX) }.max() ?? 0
        let reading = samples(.reading, seconds: 10).map { abs($0.offsetX) }.max() ?? 0
        XCTAssertLessThan(idle, reading / 2, "an idle glance is not a scan")
    }

    func testEveryBusyStateBlinks() {
        // Not `waiting`: the reference's "needs attention" states hold a lid instead of blinking
        // (`logoAvatarNeedsAttention`), which the next test pins.
        for activity in [BotAvatarActivity.working, .reading, .computer, .idle, .thinking] {
            let closed = samples(activity, seconds: 6).map(\.scaleY).min() ?? 1
            XCTAssertLessThan(closed, 0.3, "\(activity.rawValue) never closed its eyes")
        }
    }

    func testTheBlockedStateIsStill() {
        // The reference gives a failure a half-closed lid (0.68) and no tracks: it reads as
        // "gone quiet", and a blinking one reads as alive. Every sample is the same pose.
        let poses = samples(.blocked, seconds: 4)
        let first = poses.first
        XCTAssertTrue(poses.allSatisfy { $0 == first }, "blocked must not animate")
        XCTAssertEqual(first?.scaleY ?? 0, 0.68, accuracy: 0.001)
    }

    func testReadingHoldsItsLidsHalfClosed() {
        // `readingLid` is 0.76, so most frames sit under a full eye without being a blink.
        let lid = samples(.reading, seconds: 10).map(\.scaleY).filter { $0 > 0.4 }.max() ?? 1
        XCTAssertLessThan(lid, 0.85, "reading squints")
    }

    func testStatesLookDifferentFromOneAnother() {
        let reading = BotAvatarMotion.eyePose(activity: .reading, traits: traits, at: 1.2)
        let thinking = BotAvatarMotion.eyePose(activity: .thinking, traits: traits, at: 1.2)
        let computer = BotAvatarMotion.eyePose(activity: .computer, traits: traits, at: 1.2)
        XCTAssertNotEqual(reading, thinking)
        XCTAssertNotEqual(thinking, computer)
        XCTAssertNotEqual(reading, computer)
    }

    func testTheWaitingStateHoldsItsLidInsteadOfBlinking() {
        // `logoAvatarNeedsAttention`: a face waiting on a person keeps its eyes open at 0.9 rather
        // than closing them — that stillness is what makes "it needs you" read.
        let lidded = samples(.waiting, seconds: 8).map(\.scaleY)
        XCTAssertTrue(lidded.allSatisfy { $0 >= 0.85 }, "waiting must not blink")
        XCTAssertEqual(lidded.first ?? 0, 0.9, accuracy: 0.01)
    }

    func testWorkingIsNotJustABlink() {
        // The reference's working state only breathes and blinks, and on a small face that read as a
        // dead icon with a twitch — so working now pans across its work.
        let poses = samples(.working, seconds: 6)
        let travel = (poses.map(\.offsetX).max() ?? 0) - (poses.map(\.offsetX).min() ?? 0)
        XCTAssertGreaterThan(travel, 0.05, "a working face should move its eyes, not only its lids")
    }

    func testSmallFacesExaggerate() {
        // A 20-unit gaze is ~6 pt on a 120 pt face and ~1 pt on a 32 pt row: the same track has to be
        // amplified where the face is small, or only the blink is visible.
        let traits = BotAvatarMotionTraits(phase: 0, eyeLoop: 0)
        let at32 = BotAvatarMotion.frame(activity: .reading, traits: traits, at: 2.0, side: 32)
        let at160 = BotAvatarMotion.frame(activity: .reading, traits: traits, at: 2.0, side: 160)
        XCTAssertGreaterThan(abs(at32.eyes.offsetX), abs(at160.eyes.offsetX))
        XCTAssertEqual(BotAvatarMotion.emphasis(forSize: 160), 1, accuracy: 0.001)
        XCTAssertGreaterThan(BotAvatarMotion.emphasis(forSize: 16), 1)
    }

    func testTwoBotsDoNotMoveInLockstep() {
        // Their bodies breathe out of phase (`traits.phase`); the eyes are identical until a blink
        // is due, so breathing is the honest thing to compare at an arbitrary instant.
        let a = BotAvatarMotionTraits(phase: 0, eyeLoop: 0)
        let b = BotAvatarMotionTraits(phase: 0.37, eyeLoop: 2)
        let bodyA = BotAvatarMotion.frame(activity: .working, traits: a, at: 2.0).body
        let bodyB = BotAvatarMotion.frame(activity: .working, traits: b, at: 2.0).body
        XCTAssertNotEqual(bodyA, bodyB)
    }
}
