import Foundation
import SwiftUI

#if os(iOS) && canImport(ActivityKit) && canImport(WidgetKit)
import WidgetKit

/// The bot's own face, drawn in the Live Activity by the app's renderer.
///
/// **One implementation, two processes.** `OpenBotAvatarRenderer`, `OpenBotAvatarState`,
/// `OpenBotAvatarModel`, `OpenBotAvatarView` and the geometry under them are compiled into this
/// extension straight out of `Sources/HermeyUI/OpenBotAvatar` (`project.yml`) — the argument
/// `BotStateWord.swift` made one target over, for the same reason. Nothing in this file draws an
/// eye, decides a blink, holds a gaze, paints a material or knows what a phase is: the pose is
/// `OpenBotAvatarState.pose(mood:time:seed:reducedMotion:)` and the drawing is
/// `OpenBotAvatarRenderer.draw`, both the app's own. What is here is the plumbing between a clock and
/// those two calls, and the one thing a card needs that the app's surfaces do not: a face resolved
/// out of the activity's own attributes.
///
/// **Motion — what the platform gives it, and what it does not.** A Live Activity's views are hosted
/// and re-rendered by the system while the card is on the Lock Screen or in the island, so a SwiftUI
/// clock in one advances; that is why this is a `TimelineView(.animation)` rather than a timeline
/// entry. (A Home Screen widget is the opposite: WidgetKit archives its views per entry and draws
/// the archive, so the same view there would be one frozen frame.) The interval is
/// `OpenBotAvatarView.frameInterval` — the app's own 10 Hz, asked for by name rather than restated,
/// because a second cadence in a second process is a second animation. How many of those 10 Hz
/// frames the system actually composites is the system's decision and is not something this file can
/// promise; what it can promise is that no work happens for a frame that is not asked for, and that
/// under Always-On (`isLuminanceReduced`) or on a stale card the clock is paused at the state's
/// stance — the same pose `OpenBotAvatarView` holds under Reduce Motion.
///
/// **Cost.** Per frame: one `pose` (a dozen sines, a hash and no allocation, no clock of its own) and
/// one `Canvas` pass over paths built once. The definition is not decoded per frame — not even per
/// update: `HermeyTurnFaceStore` decodes the attribute once per distinct face and hands back the same
/// `OpenBotAvatarModel` (itself a cache keyed by the definition) on every later call.
struct HermeyTurnFace: View {
    let face: HermeyTurnPreparedFace
    /// What the bot is doing — the eight-state vocabulary, already resolved by `OpenBotAvatarState(turn:)`.
    let state: OpenBotAvatarState
    let size: CGFloat
    /// A stale card (the app could not update it) or an Always-On Lock Screen: hold, do not drift.
    let isStale: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    /// Whether this card is being drawn in a place the system has dimmed to save the battery. The
    /// system stops compositing animations there whatever we ask for, so asking is the battery bug.
    private var still: Bool { isStale || luminanceReduced }

    var body: some View {
        TimelineView(.animation(minimumInterval: OpenBotAvatarView.frameInterval, paused: still)) { context in
            Canvas { canvas, canvasSize in
                OpenBotAvatarRenderer.draw(face.model,
                                           pose: pose(at: context.date),
                                           material: face.material,
                                           backdrop: .themed(dark: colorScheme != .light),
                                           into: &canvas,
                                           size: canvasSize,
                                           color: face.color,
                                           ink: OpenBotAvatarView.ink(for: face.color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The frame's pose, on the shared clock.
    ///
    /// `time` is the reference date — the same quantity, on the same scale, that `OpenBotAvatarView`
    /// feeds the same function — so the card's face is at the point of the wave the roster's face is
    /// at, in the same instant, instead of running a second clock of its own from its own start.
    private func pose(at date: Date) -> OpenBotAvatarPose {
        let time = still ? 0 : date.timeIntervalSinceReferenceDate
        return state.pose(mood: mood, time: time, seed: face.seed, reducedMotion: still)
    }

    /// `done` is the one state the reference celebrates, and every other one is neutral. Written
    /// here rather than through the app's `mood(for:)` bridge because that bridge takes a
    /// `BotAvatarActivity` and lives behind `HermesKit`, which this process does not link.
    private var mood: BotAvatarMood { state == .done ? .happy : .neutral }
}

// MARK: - What a frame needs

/// A face resolved and ready to draw: everything a frame reads, and nothing a frame has to re-read.
///
/// Built once per distinct face by `HermeyTurnFaceStore` and then held: the volume, the silhouette,
/// the ribbon hoop and the seed are all resolved here, so a frame is a pose and a fill.
struct HermeyTurnPreparedFace {
    let model: OpenBotAvatarModel
    let color: Color
    let material: BotAvatarMaterial
    /// The bot's own phase offset, from `BotAvatarHash.shippedHash` — the same hash
    /// `OpenBotAvatarView` seeds with, so two bots move out of step here exactly as they do in the
    /// app, and one bot moves the same way in both places.
    let seed: UInt32
}

/// The card's faces, decoded once each.
///
/// A Live Activity body is re-evaluated on every content update and its face's on every frame, so the
/// work that must not happen there is decoding: the definition JSON arrives on the attributes, is
/// parsed once per distinct face, and every later call — update or frame — is a dictionary lookup
/// under a lock. There are at most a handful of faces in a card's life (one per bot that spoke), and
/// the cache is emptied rather than grown when it reaches its limit.
enum HermeyTurnFaceStore {
    /// The key a stored face is filed under. A card shows one bot and the extension has no bot list;
    /// `BotAvatarLibrary` is keyed by id, so the card's bot is named here rather than the resolution
    /// taking a second path that does not go through the library.
    private static let botID = "live-activity"
    private static let cacheLimit = 8

    private static let lock = NSLock()
    private static var cache: [String: HermeyTurnPreparedFace] = [:]

    /// The face for an activity's attributes, or nil when there is none to draw.
    ///
    /// Nil is the honest answer for the two cases that have no face: a bot that never chose a drawn
    /// avatar, and a definition this build refuses. Both draw the phase's symbol instead
    /// (`HermeyTurnAvatar`), which is the card every bot had before this.
    ///
    /// The document goes through `BotAvatarDocument(json:color:material:)` — the initialiser the app
    /// uses for a host's answer — and then through `BotAvatarLibrary`, so the rules that decide
    /// whether a stored face may be drawn (the contract, the colour, the material) are the app's
    /// rules and not a copy of them.
    static func prepare(_ face: HermeyTurnAttributes.Face?) -> HermeyTurnPreparedFace? {
        guard let face, face.isDrawn, let definition = face.definition else { return nil }
        let key = "\(definition)|\(face.color ?? "")|\(face.material ?? "")"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let document = BotAvatarDocument(json: definition,
                                               color: face.color,
                                               material: face.material) else { return nil }
        let library = BotAvatarLibrary(avatars: [botID: document])
        guard let resolved = library[botID],
              let model = OpenBotAvatarModel.model(for: resolved.definition) else { return nil }
        let prepared = HermeyTurnPreparedFace(
            model: model,
            color: resolved.color.flatMap(OpenBotAvatarColor.color(hex:)) ?? OpenBotAvatarRenderer.defaultColor,
            material: resolved.material,
            seed: BotAvatarHash.shippedHash(resolved.definition.id))

        lock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = prepared
        lock.unlock()
        return prepared
    }
}

// MARK: - The eight words, worn by the card

extension OpenBotAvatarState {
    /// The state this card's face wears, from the word the coordinator sent.
    ///
    /// `ContentState.botState` is already normalised against `BotStateWord`, so the lookup succeeds
    /// for anything this build wrote; the `switch` is the floor for a card written by a *later* build
    /// whose word this one has never seen — the face then wears the phase's state rather than
    /// nothing, and the card still looks like the turn it is showing.
    init(turn: HermeyTurnAttributes.ContentState) {
        if let known = OpenBotAvatarState(rawValue: turn.botState) {
            self = known
            return
        }
        switch turn.phase {
        case .working: self = .working
        case .needsYou: self = .waiting
        case .done: self = .done
        }
    }
}
#endif
