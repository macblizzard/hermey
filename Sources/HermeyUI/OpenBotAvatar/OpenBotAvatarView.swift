import Foundation
// Conditional, and the only conditional import in this file: `init(activity:)` below maps the app's
// vocabulary onto these eight states, and that mapping needs `HermesKit`. Everything else here —
// the view, the document, the ink — is drawing, and the iOS Live Activity compiles this same file into
// its own module (`project.yml`) so the card can hold the face without linking the networking stack.
#if canImport(HermesKit)
import HermesKit
#endif
import SwiftUI

/// A bot's generated avatar, drawn natively: the definition's outline given the volume upstream
/// infers for it, the eyes on its surface, and the bot's current state as the pose.
///
/// ```swift
/// OpenBotAvatarView(definition: stored.definition,
///                   color: stored.color,
///                   material: stored.material,
///                   state: .init(activity: model.activity(forBot: bot.id)),
///                   size: 32)
/// ```
///
/// `state` takes one of the eight names (`.thinking`) or a definition of the host's own
/// (`AvatarStateDefinition`) — upstream 0.5.0's point, that a host can add a state without a new case
/// in an enum we ship. A change of state or mood eases in over `OpenBotAvatarEasing.changeMilliseconds`
/// from the pose that was on screen, and the eyes morph from one shape to the next while it does.
///
/// It is a sibling of `BotAvatarView`, not a replacement: a bot with no generated avatar keeps the
/// shape-and-palette face it has today, and one with a definition draws this instead. That is the
/// rule every surface follows (`BotAvatarView` takes both and picks), so a list row cannot end up
/// disagreeing with the chat header about which face a bot wears.
///
/// **Motion.** Sampled at 10 Hz — the same cadence the pets animate at — through a `Canvas`, from a
/// pose that is a pure function of time. Under Reduce Motion, below `animatingFrom`, in a background
/// window, or when `animates` is false, it holds the rest pose and costs nothing. The drawing itself
/// never allocates geometry: the body's cross-sections, the ribbon hoops' reach and the outline are
/// built once per definition and cached (`OpenBotAvatarModel`), and a frame only transforms them.
///
/// That is the face's *breathing*. Where the app shows a bot beside its name, `BotAvatarView` also
/// performs the shared face's motion over it (the hop, the flip, the darts) and hands the eye pose
/// down through `eyeOverride:` — so this view is never asked for a second motion language.
public struct OpenBotAvatarView: View {
    public var definition: BotAvatarDefinition
    /// The stored `#RRGGBB`, or nil for the house colour.
    public var color: String?
    /// The stored `material`: a flat solid or the reference's glass. It reaches here from the
    /// avatar library with the definition, so no surface chooses it per call site.
    public var material: BotAvatarMaterial
    /// What the bot is doing: one of the eight names, or a definition of the host's own.
    public var state: OpenBotAvatarStateChoice
    /// How it feels; `happy` draws the eyes as arcs.
    public var mood: BotAvatarMood
    public var size: CGFloat
    /// Where the face is drawn. nil follows the environment's `colorScheme`, which is right for
    /// every themed surface; the pet passes `.pet` because it floats over a wallpaper and its rim
    /// must never depend on a page colour it cannot see.
    public var backdrop: OpenBotAvatarBackdrop?
    /// Whether this avatar may move at all (a long list passes false for its idle rows).
    public var animates: Bool
    public var reduceMotion: Bool
    /// The size below which the face holds still. The pets' floor, so a 16 pt row icon is static.
    public var animatingFrom: Double
    /// Spoken label. Without one the avatar is decoration beside a name already read out.
    public var label: String?
    /// Eyes decided elsewhere, for the shared face's blink-and-dart schedule. Nil — the default, and
    /// every caller that draws this view directly — keeps the avatar's own idle blinking.
    public var eyeOverride: OpenBotAvatarEyeOverride?

    /// What this surface keeps between frames: when the state began, and what a change is easing in
    /// from. A plain object, stepped once per frame — no published state, so a frame cannot invalidate
    /// the view it is drawing.
    @State private var animator = OpenBotAvatarStateAnimator()

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// A person who has asked for less transparency gets the calm painted glass: no refraction at
    /// all, and the same three legible layers a list row draws. Read here, decided in
    /// `BotAvatarGlassRoute.decide`, so no surface chooses for itself.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    public init(definition: BotAvatarDefinition,
                color: String? = nil,
                material: BotAvatarMaterial = .solid,
                state: OpenBotAvatarStateChoice = .idle,
                mood: BotAvatarMood = .neutral,
                size: CGFloat = 36,
                backdrop: OpenBotAvatarBackdrop? = nil,
                animates: Bool = true,
                reduceMotion: Bool = false,
                animatingFrom: Double = 24,
                label: String? = nil,
                eyeOverride: OpenBotAvatarEyeOverride? = nil) {
        self.definition = definition
        self.color = color
        self.material = material
        self.state = state
        self.mood = mood
        self.size = size
        self.backdrop = backdrop
        self.animates = animates
        self.reduceMotion = reduceMotion
        self.animatingFrom = animatingFrom
        self.label = label
        self.eyeOverride = eyeOverride
    }

    /// The frame interval: 10 Hz, the pets' cadence. Calm is the point — a 60 Hz avatar in a list of
    /// twenty bots is a battery decision, not a look.
    public static let frameInterval = 0.1

    public var body: some View {
        let still = reduceMotion || systemReduceMotion
        let moves = animates && !still && Double(size) >= animatingFrom && scenePhase == .active
        let resolvedColor = color.flatMap(OpenBotAvatarColor.color(hex:)) ?? OpenBotAvatarRenderer.defaultColor
        let seed = BotAvatarHash.shippedHash(definition.id)
        let surface = backdrop ?? .themed(dark: colorScheme != .light)
        // **The decision**, once, from the surface: what draws this bot's glass — the Metal body or
        // the painted material. Nothing below asks again; `frame` follows it and the renderer follows
        // the pass it is given.
        let route = BotAvatarGlassRoute.decide(material: material, side: Double(size),
                                               reduceTransparency: reduceTransparency)

        return Group {
            if let model = OpenBotAvatarModel.model(for: definition) {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !moves)) { context in
                    let time = moves ? context.date.timeIntervalSinceReferenceDate : 0
                    // One step per frame: how long this state has been showing, and what to ease in
                    // from. A still frame asks for the same step and eases nothing.
                    let step = animator.step(state: state, mood: mood, at: context.date,
                                             reducedMotion: !moves)
                    let pose = state.pose(mood: mood, time: time, seed: seed, reducedMotion: !moves,
                                          eyeOverride: eyeOverride, stateAge: step.stateAge,
                                          blend: step.blend)
                    frame(model: model, pose: pose, route: route, surface: surface,
                          color: resolvedColor, still: !moves, time: time)
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

    /// One frame, in the number of passes the route needs.
    ///
    /// `.canvas` is the drawing this view has always made: one pass, all of it. `.metal` is the same
    /// frame split into three — the ribbons that pass behind the body, the body alone, and everything
    /// over it — because the shader draws the body and must not touch an eye, a ribbon or a mark. The
    /// body's pass is a `MetalKit` view over the body's own box: the shader paints it from the
    /// silhouette the `Canvas` route fills, and the other two are the renderer's own drawing,
    /// unchanged.
    ///
    /// The three passes are the shader path's whole cost: two `Canvas` draws and one Metal draw per
    /// avatar, and only on an app surface that is drawing a glass body at 24 pt or more. A body under
    /// a mark, a still frame and a reduced-transparency surface all take `.canvas`, which is one.
    @ViewBuilder
    private func frame(model: OpenBotAvatarModel,
                       pose: OpenBotAvatarPose,
                       route: BotAvatarGlassRoute,
                       surface: OpenBotAvatarBackdrop,
                       color: Color,
                       still: Bool,
                       time: Double) -> some View {
        switch route {
        case .canvas:
            Canvas { context, canvasSize in
                OpenBotAvatarRenderer.draw(model,
                                           pose: pose,
                                           material: material,
                                           backdrop: surface,
                                           into: &context,
                                           size: canvasSize,
                                           color: color,
                                           ink: Self.ink(for: color),
                                           still: still,
                                           time: time)
            }
        case .metal:
            // The layer's own size: the frame fills this view's bounds, so the shader's `position`
            // space is exactly it — the numbers below are in the same points the drawing is in.
            let layerSize = CGSize(width: size, height: size)
            let face = OpenBotAvatarRenderer.bodyTransform(model, pose: pose, size: layerSize)
            let glass = BotAvatarGlassSurface.make(model: model, pose: pose, size: layerSize,
                                                   face: face, color: color, backdrop: surface,
                                                   material: material)
            ZStack {
                Canvas { context, canvasSize in
                    OpenBotAvatarRenderer.draw(model, pose: pose, material: material,
                                               backdrop: surface, into: &context, size: canvasSize,
                                               color: color, ink: Self.ink(for: color),
                                               still: still, time: time, pass: .behind)
                }
                // The body: the reference's lit, refracting surface, drawn by the runtime shader over
                // the same silhouette the `Canvas` route fills.
                BotAvatarGlassView(surface: glass, path: model.silhouette.applying(face))
                Canvas { context, canvasSize in
                    OpenBotAvatarRenderer.draw(model, pose: pose, material: material,
                                               backdrop: surface, into: &context, size: canvasSize,
                                               color: color, ink: Self.ink(for: color),
                                               still: still, time: time, pass: .over)
                }
            }
        }
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

#if canImport(HermesKit)
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

public extension OpenBotAvatarStateChoice {
    /// The same mapping for the type a surface passes as `state`, so a call site that read
    /// `.init(activity:)` when the parameter was the enum still reads the same way.
    init(activity: BotAvatarActivity) {
        self = .named(OpenBotAvatarState(activity: activity))
    }
}
#endif

// MARK: - What is stored

/// One bot's generated avatar, as the host stores it: the definition, the colour it is drawn in,
/// and the material it is made of.
///
/// `BotAvatarDocument` is the Swift shape of the `faces[bot]` entry's three avatar fields. The
/// chosen face (`avatar`) stays in `BotFaceChoice` and travels beside it, unchanged.
///
/// ```json
/// { "definition": { … }, "color": "#A97EFE", "material": "glass" }
/// ```
///
/// `material` is absent or null on every document written before it existed, and that means
/// `solid` — so nothing already saved changes and there is no migration. A value that is none of
/// `solid`, `glass`, `matte` or `metal` is refused by `BotAvatarMaterial(validating:)`, the same rule
/// (and the same sentence) the host applies when it answers 400.
public struct BotAvatarDocument: Hashable, Sendable, Codable {
    public var definition: BotAvatarDefinition
    /// `#RRGGBB`, or nil to draw the house colour.
    public var color: String?
    /// One of `BotAvatarMaterial`'s values. Absent means `solid`.
    public var material: BotAvatarMaterial

    public init(definition: BotAvatarDefinition,
                color: String? = nil,
                material: BotAvatarMaterial = .solid) {
        self.definition = definition
        self.color = color
        self.material = material
    }

    /// Read the document a host answered with, where `definition` is the JSON itself and `material`
    /// the stored string. nil when either cannot be read: a definition this build does not accept,
    /// or a material it cannot paint. The host refuses to store an unknown one, so the second case
    /// is a document from a newer host — drawn as the shape face rather than guessed at.
    public init?(json definitionJSON: String, color: String?, material: String? = nil) {
        guard let data = definitionJSON.data(using: .utf8),
              let definition = try? JSONDecoder().decode(BotAvatarDefinition.self, from: data) else {
            return nil
        }
        guard let validated = try? BotAvatarMaterial(validating: material) else { return nil }
        self.definition = definition
        self.color = color
        self.material = validated
    }

    /// The JSON text stored on the host, ready to paste into an editor.
    public func definitionJSON() -> String {
        (try? definition.jsonText()) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case definition
        case color
        case material
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        definition = try container.decode(BotAvatarDefinition.self, forKey: .definition)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        // Absent or null is solid; anything else goes through the same validator as the host's.
        material = try container.decodeIfPresent(BotAvatarMaterial.self, forKey: .material)
            ?? .fallback
    }
}
