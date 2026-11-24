import Foundation
import HermesKit
import SwiftUI

/// A bot's generated avatar, drawn natively: the definition's outline given the volume upstream
/// infers for it, the eyes on its surface, and the bot's current state as the pose.
///
/// ```swift
/// OpenBotAvatarView(definition: stored.definition,
///                   color: stored.color,
///                   state: .init(activity: model.activity(forBot: bot.id)),
///                   size: 32)
/// ```
///
/// It is a sibling of `BotAvatarView`, not a replacement: a bot with no generated avatar keeps the
/// shape-and-palette face it has today, and one with a definition draws this instead. That is the
/// rule every surface follows (`BotAvatarView` takes both and picks), so a list row cannot end up
/// disagreeing with the chat header about which face a bot wears.
///
/// **Motion.** Sampled at 10 Hz — the same cadence the pets animate at — through a `Canvas`, from a
/// pose that is a pure function of time. Under Reduce Motion, below `animatingFrom`, in a background
/// window, or when `animates` is false, it holds the rest pose and costs nothing. The drawing itself
/// never allocates geometry: the body's cross-sections and the marks are built once per definition
/// and cached (`OpenBotAvatarModel`), and a frame only transforms them.
public struct OpenBotAvatarView: View {
    public var definition: BotAvatarDefinition
    /// The stored `#RRGGBB`, or nil for the house colour.
    public var color: String?
    /// What the bot is doing.
    public var state: OpenBotAvatarState
    /// How it feels; `happy` draws the eyes as arcs.
    public var mood: BotAvatarMood
    public var size: CGFloat
    /// Whether this avatar may move at all (a long list passes false for its idle rows).
    public var animates: Bool
    public var reduceMotion: Bool
    /// The size below which the face holds still. The pets' floor, so a 16 pt row icon is static.
    public var animatingFrom: Double
    /// Spoken label. Without one the avatar is decoration beside a name already read out.
    public var label: String?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    public init(definition: BotAvatarDefinition,
                color: String? = nil,
                state: OpenBotAvatarState = .idle,
                mood: BotAvatarMood = .neutral,
                size: CGFloat = 36,
                animates: Bool = true,
                reduceMotion: Bool = false,
                animatingFrom: Double = 24,
                label: String? = nil) {
        self.definition = definition
        self.color = color
        self.state = state
        self.mood = mood
        self.size = size
        self.animates = animates
        self.reduceMotion = reduceMotion
        self.animatingFrom = animatingFrom
        self.label = label
    }

    /// The frame interval: 10 Hz, the pets' cadence. Calm is the point — a 60 Hz avatar in a list of
    /// twenty bots is a battery decision, not a look.
    public static let frameInterval = 0.1

    public var body: some View {
        let still = reduceMotion || systemReduceMotion
        let moves = animates && !still && Double(size) >= animatingFrom && scenePhase == .active
        let resolvedColor = color.flatMap(OpenBotAvatarColor.color(hex:)) ?? OpenBotAvatarRenderer.defaultColor
        let seed = BotAvatarHash.shippedHash(definition.id)

        Group {
            if let model = OpenBotAvatarModel.model(for: definition) {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !moves)) { context in
                    let time = moves ? context.date.timeIntervalSinceReferenceDate : 0
                    let pose = state.pose(mood: mood, time: time, seed: seed, reducedMotion: !moves)
                    Canvas { context, canvasSize in
                        OpenBotAvatarRenderer.draw(model,
                                                   pose: pose,
                                                   into: &context,
                                                   size: canvasSize,
                                                   color: resolvedColor,
                                                   ink: Self.ink(for: resolvedColor))
                    }
                }
            } else {
                // A definition the contract refuses draws nothing rather than something wrong. Every
                // caller validates before storing; this is the last line, not the first.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? definition.name)
        .accessibilityHidden(label == nil)
    }

    /// The eye ink: near-black on every body except the very dark ones, where it would disappear.
    static func ink(for color: Color) -> Color {
        #if canImport(UIKit)
        let resolved = UIColor(color)
        #else
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        #endif
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance < 0.18 ? Color(white: 0.92) : OpenBotAvatarRenderer.defaultInk
    }
}

// MARK: - The app's vocabulary, mapped

public extension OpenBotAvatarState {
    /// The avatar pose for an activity the app already tracks.
    ///
    /// The mapping goes through `rawValue` rather than a `switch` over cases on purpose: the state
    /// vocabulary lives in `HermesKit` and is owned by the activity tracker, and a face that fails to
    /// compile because a case was renamed is a merge conflict in a drawing. `writing` reads as
    /// `reading` (both are a bot bent over text) and `error` as `blocked`, which is what the reference
    /// calls the same pose.
    init(activity: BotAvatarActivity) {
        switch activity.rawValue {
        case "thinking": self = .thinking
        case "reading", "writing": self = .reading
        case "working": self = .working
        case "computer": self = .computer
        case "waiting": self = .waiting
        case "blocked", "error": self = .blocked
        case "done": self = .done
        default: self = .idle
        }
    }

    /// The mood for an activity. Bots are neutral while they work; the arcs are for `done`, which is
    /// the one state the reference celebrates.
    static func mood(for activity: BotAvatarActivity) -> BotAvatarMood {
        activity.rawValue == "done" ? .happy : .neutral
    }
}

// MARK: - What is stored

/// One bot's generated avatar, as the host stores it: the definition plus the colour it is drawn in.
///
/// `BotAvatarDocument` is the Swift shape of the `faces[bot]` entry's two avatar fields. The chosen
/// face (`avatar`) stays in `BotFaceChoice` and travels beside it, unchanged.
public struct BotAvatarDocument: Hashable, Sendable, Codable {
    public var definition: BotAvatarDefinition
    /// `#RRGGBB`, or nil to draw the house colour.
    public var color: String?

    public init(definition: BotAvatarDefinition, color: String? = nil) {
        self.definition = definition
        self.color = color
    }

    /// Read the document a host answered with, where `definition` is the JSON itself.
    public init?(json definitionJSON: String, color: String?) {
        guard let data = definitionJSON.data(using: .utf8),
              let definition = try? JSONDecoder().decode(BotAvatarDefinition.self, from: data) else {
            return nil
        }
        self.definition = definition
        self.color = color
    }

    /// The JSON text stored on the host, ready to paste into an editor.
    public func definitionJSON() -> String {
        (try? definition.jsonText()) ?? ""
    }
}
