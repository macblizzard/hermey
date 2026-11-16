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
        // Two full horizontal sweeps per cycle with the reference's 20/60 amplitude, so the gaze
        // must both reach far right and come back to the left.
        let poses = samples(.reading, seconds: 10)
        let widest = poses.map(\.offsetX).max() ?? 0
        let narrowest = poses.map(\.offsetX).min() ?? 0
        XCTAssertGreaterThan(widest, 0.3, "reading should look right, like a line of text")
        XCTAssertLessThan(narrowest, 0.02, "…and return, rather than parking at the right edge")
    }

    func testIdleMovesLessThanReading() {
        let idle = samples(.idle, seconds: 10).map { abs($0.offsetX) }.max() ?? 0
        let reading = samples(.reading, seconds: 10).map { abs($0.offsetX) }.max() ?? 0
        XCTAssertLessThan(idle, reading / 2, "an idle glance is not a scan")
    }

    func testEveryBusyStateBlinks() {
        for activity in [BotAvatarActivity.working, .reading, .writing, .computer, .idle, .thinking, .waiting] {
            let closed = samples(activity, seconds: 6).map(\.scaleY).min() ?? 1
            XCTAssertLessThan(closed, 0.3, "\(activity.rawValue) never closed its eyes")
        }
    }

    func testTheErrorStateIsStill() {
        // The reference gives error a half-closed lid (0.68) and no tracks: a failure reads as
        // "gone quiet", and a blinking one reads as alive. Every sample is the same pose.
        let poses = samples(.error, seconds: 4)
        let first = poses.first
        XCTAssertTrue(poses.allSatisfy { $0 == first }, "error must not animate")
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

    func testTwoBotsDoNotBlinkInLockstep() {
        let a = BotAvatarMotionTraits(phase: 0, eyeLoop: 0)
        let b = BotAvatarMotionTraits(phase: 0.37, eyeLoop: 2)
        let poseA = BotAvatarMotion.eyePose(activity: .working, traits: a, at: 2.0)
        let poseB = BotAvatarMotion.eyePose(activity: .working, traits: b, at: 2.0)
        XCTAssertNotEqual(poseA, poseB)
    }
}
