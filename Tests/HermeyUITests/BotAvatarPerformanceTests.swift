import XCTest
import HermesKit
@testable import HermeyUI

/// The stunts a busy face performs between its authored acting.
///
/// The maintainer's report of 2026-11-16: *"it now blinks and moves a bit, but it's not enough, I need more
/// movements … more eye movements and some jumps and flips in between every few seconds while
/// working"*. These tests pin the answers he chose — playful, in working plus every busy state — and
/// the two rules that keep the result from looking broken: a stunt is a pure function of the clock,
/// and each one ends where it began.
///
/// They assert on `performance(...)` — the layer this file is about — rather than on the composed
/// frame, because the reference's own acting (the breath, the gaze tracks, the blink) is always
/// moving and would drown a threshold either way.
final class BotAvatarPerformanceTests: XCTestCase {

    private let traits = BotAvatarMotionTraits(phase: 0, eyeLoop: 0)
    private let step = 1.0 / 30.0

    private func performances(_ activity: BotAvatarActivity,
                              seconds: Double = 12,
                              side: Double = 40,
                              traits: BotAvatarMotionTraits? = nil) -> [BotAvatarPerformance] {
        let resolved = traits ?? self.traits
        return stride(from: 0.0, through: seconds, by: step).map {
            BotAvatarMotion.performance(activity: activity, traits: resolved, at: $0, side: side)
        }
    }

    /// How many separate runs of `on` the window contains: one run is one stunt.
    private func runs(_ samples: [BotAvatarPerformance],
                      where on: (BotAvatarPerformance) -> Bool) -> Int {
        var count = 0
        var inside = false
        for sample in samples {
            let active = on(sample)
            if active && !inside { count += 1 }
            inside = active
        }
        return count
    }

    // MARK: - What he asked for

    func testAWorkingFaceLeavesTheGroundAndTurnsOver() {
        let sampled = performances(.working)
        // Twelve seconds is a little over two beats: three jumps and two flips, so four stunt windows
        // is a floor that still fails if either stunt stops firing.
        let stunts = runs(sampled) { !$0.body.isRest }
        let flips = runs(sampled) { abs($0.body.rotate) > 20 }
        XCTAssertGreaterThanOrEqual(stunts, 4, "the face barely performed")
        XCTAssertGreaterThanOrEqual(flips, 2, "the face never turned over")
    }

    func testStuntsComeEveryFewSecondsRatherThanConstantly() {
        // "in between every few seconds": the body performs, then it goes back to the state's own
        // acting. A body that moved continuously would be a spinning thing, not a bot doing a job.
        let sampled = performances(.working, seconds: 20)
        let resting = sampled.filter { $0.body.isRest }.count
        let share = Double(resting) / Double(sampled.count)
        XCTAssertGreaterThan(share, 0.6, "the body never rested between stunts")
        XCTAssertLessThan(share, 0.95, "the body almost never performed")
    }

    func testTheEyesMoveMoreOftenThanTheBodyDoes() {
        // The eyes are the acting and the body is punctuation — the reference's own balance, kept:
        // 14 glances to 5 stunts across twelve seconds.
        let sampled = performances(.working, seconds: 12)
        let glances = runs(sampled) { $0.eyes.offsetX != 0 || $0.eyes.offsetY != 0 }
        let stunts = runs(sampled) { !$0.body.isRest }
        XCTAssertGreaterThan(glances, stunts * 2, "the body out-acted the eyes")
    }

    // MARK: - Which states perform

    func testEveryBusyStatePerforms() {
        for activity in [BotAvatarActivity.working, .thinking, .reading, .writing, .computer] {
            let performed = performances(activity, seconds: 8).contains { !$0.body.isRest }
            XCTAssertTrue(performed, "\(activity.rawValue) never performed")
        }
    }

    func testIdleWaitingAndErrorAreLeftExactlyAsTheReferenceDrawsThem() {
        // Idle is a bot doing nothing, waiting is looking at the person, error is gone quiet: a
        // backflip in any of them is a lie. The performed frame must equal the port's own frame.
        for activity in [BotAvatarActivity.idle, .waiting, .error] {
            XCTAssertTrue(performances(activity, seconds: 14).allSatisfy(\.isEmpty),
                          "\(activity.rawValue) performed")
            for moment in stride(from: 0.0, through: 14.0, by: 1.0) {
                let reference = BotAvatarMotion.frame(activity: activity, traits: traits, at: moment, side: 40)
                let performed = BotAvatarMotion.performedFrame(activity: activity, traits: traits,
                                                               at: moment, side: 40)
                XCTAssertEqual(performed, reference, "\(activity.rawValue) performed at \(moment)s")
            }
        }
    }

    func testReduceMotionAndTheSizeFloorStillCloseTheWholeFace() {
        // The gates live in `allows(...)` and the view falls back to `.rest` when they close, which is
        // what keeps stunts off a device that asked for stillness. This pins the gate, not the fallback.
        XCTAssertFalse(BotAvatarMotion.allows(activity: .working, reduceMotion: true, size: 40))
        XCTAssertFalse(BotAvatarMotion.allows(activity: .working, reduceMotion: false, size: 40, minimumSize: 48))
        XCTAssertTrue(BotAvatarMotion.allows(activity: .working, reduceMotion: false, size: 40))
    }

    // MARK: - The two rules that keep it looking like a face

    /// The distance between two rotations on screen: 360° and 0° are the same pose, so a roll that
    /// ends at a full turn has not teleported back.
    private func angularGap(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    func testNoStuntTeleports() {
        // Nothing may snap: between two drawn frames a thirtieth of a second apart, the pose can only
        // travel as far as a stunt's own fastest segment. A track missing its closing `(1, 0)` shows
        // up here as a jump back to the resting pose.
        let sampled = stride(from: 0.0, through: 20.0, by: step).map {
            BotAvatarMotion.performedFrame(activity: .working, traits: traits, at: $0, side: 16)
        }
        for index in 1..<sampled.count {
            let previous = sampled[index - 1].body
            let current = sampled[index].body
            // A full roll moves ~69° in a frame at its fastest, so 75 is the honest ceiling.
            XCTAssertLessThan(angularGap(current.rotate, previous.rotate), 75,
                              "the rotation snapped \(previous.rotate)° → \(current.rotate)°")
            // A leap at 16 pt travels 0.16 of the face; its fastest frame moves it 0.059.
            XCTAssertLessThan(abs(current.translateY - previous.translateY), 0.08,
                              "the body snapped \(previous.translateY) → \(current.translateY)")
            // A saccade is meant to be quick — 60 ms, two frames — but not instantaneous.
            let previousEyes = sampled[index - 1].eyes
            let currentEyes = sampled[index].eyes
            XCTAssertLessThan(abs(currentEyes.offsetX - previousEyes.offsetX), 0.35,
                              "the gaze snapped \(previousEyes.offsetX) → \(currentEyes.offsetX)")
        }
    }

    func testTheSameInstantAlwaysDrawsTheSameFace() {
        // A pure function of the clock: a timeline may ask out of order, twice, or after a window was
        // occluded, and two faces must agree about what happened at a given instant.
        for moment in [0.0, 3.21, 7.75, 11.02, 19.4] {
            let first = BotAvatarMotion.performedFrame(activity: .working, traits: traits, at: moment, side: 40)
            let second = BotAvatarMotion.performedFrame(activity: .working, traits: traits, at: moment, side: 40)
            XCTAssertEqual(first, second)
        }
    }

    func testTwoBotsDoNotPerformInLockstep() {
        // The phase is the bot's own, so a list of faces never jumps as a chorus.
        let other = BotAvatarMotionTraits(phase: 0.83, eyeLoop: 2)
        let differing = stride(from: 0.0, through: 12.0, by: step).filter { moment in
            let mine = BotAvatarMotion.performance(activity: .working, traits: traits, at: moment, side: 40)
            let theirs = BotAvatarMotion.performance(activity: .working, traits: other, at: moment, side: 40)
            return mine != theirs
        }
        XCTAssertGreaterThan(differing.count, 60, "the two faces performed instant for instant")
    }

    func testASmallFaceTravelsLessInPointsThanABigOne() {
        // The fraction shrinks as the face grows, so the leap is ~3–5 points at every size: a 16 pt
        // icon that leapt the same *fraction* as a 96 pt one would leave its row.
        XCTAssertGreaterThan(BotAvatarMotion.stuntTravel(forSize: 16), BotAvatarMotion.stuntTravel(forSize: 96))
        XCTAssertLessThanOrEqual(16 * BotAvatarMotion.stuntTravel(forSize: 16), 3.0)
        XCTAssertLessThanOrEqual(96 * BotAvatarMotion.stuntTravel(forSize: 96), 5.0)
    }

    func testTheLayersComposeInsteadOfReplacingEachOther() {
        // The breath must survive a stunt: scale multiplies, so a squash on a 1.005 breath keeps the
        // breath. Adding the scales instead would flatten the face mid-jump.
        let reference = BotAvatarMotion.Frame(
            body: BotAvatarPose(translateY: 0.01, rotate: 1, scaleX: 1.005, scaleY: 1.005, brightness: 0.02),
            eyes: BotAvatarEyePose(offsetX: 0.1, offsetY: -0.02, scaleX: 1, scaleY: 0.9)
        )
        let stunt = BotAvatarPerformance(
            body: BotAvatarPose(translateY: -0.05, rotate: 360, scaleX: 0.9, scaleY: 1.1, brightness: 0.05),
            eyes: BotAvatarEyePose(offsetX: 0.05, offsetY: 0.03, scaleX: 1, scaleY: 0.7)
        )
        let merged = stunt.applied(to: reference)
        XCTAssertEqual(merged.body.translateY, 0.01 - 0.05, accuracy: 1e-9)
        XCTAssertEqual(merged.body.rotate, 361, accuracy: 1e-9)
        XCTAssertEqual(merged.body.scaleX, 1.005 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(merged.body.scaleY, 1.005 * 1.1, accuracy: 1e-9)
        XCTAssertEqual(merged.body.brightness, 0.07, accuracy: 1e-9)
        XCTAssertEqual(merged.eyes.offsetX, 0.15, accuracy: 1e-9)
        XCTAssertEqual(merged.eyes.scaleY, 0.9 * 0.7, accuracy: 1e-9)
    }
}
