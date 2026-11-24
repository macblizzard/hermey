import HermesKit
import SwiftUI

/// A bot's face: one of the eight shipped bodies, the same two bar eyes on every one, and the
/// activity the bot is in drawn as motion.
///
/// ## Adopting it
///
/// Every surface that draws a bot's face uses this view, and every one of them hands over the same
/// three things: the bot's id, what it is doing, and the size it draws at.
///
/// ```swift
/// BotAvatarView(identity: bot.id,
///               color: faces[bot.id]?.raw,          // the stored `#RRGGBB::shape_N`, or nil
///               activity: model.activity(forBot: bot.id),
///               size: metrics.avatar,
///               animates: model.activity(forBot: bot.id) != .idle)
/// ```
///
/// The activity is never derived in a view. `BotActivityTracker` (in `HermesKit`) reduces the
/// gateway's own events to one per bot, and `AppModel.activity(forBot:)` is the single accessor both
/// shells read; a view that re-derived it from `isStreaming` and a tool name would be a second copy
/// of the precedence rules, which is how the roster and the chat header start disagreeing.
///
/// Both compile against `HermeyUI` alone for everything but the activity value, which lives in
/// `HermesKit` — the one vocabulary the wire layer and the design system share.
///
/// **The stored avatar is not an argument.** A bot that has chosen a face draws it on every
/// surface, and the surface does not have to know: `EnvironmentValues.botAvatars` carries the host's
/// map (`BotAvatarLibrary`), injected once at each app's root, and this view resolves
/// `definition ?? environment.botAvatars[identity]`. The `definition:` parameter remains for a
/// preview or an editor drawing a face the host does not have yet.
///
/// **A face changes when a surface adopts this.** The shape and colour derive from the reference's
/// palette (eleven colours) with the reference's hash. A surface that must keep a stored face passes
/// `color:` with the stored value (the reference's `#RRGGBB` or `#RRGGBB::shape_N`) and leaves the id
/// to pick the shape — or passes both, and nothing is derived. That is what `BotFaceChoice` stores.
///
/// One case needs a second line: a stored `data:image/…` value resolves to `isImage == true`, and its
/// picture stays the caller's to draw —
///
/// ```swift
/// let face = BotAvatarIdentity.resolve(identity: bot.id, explicitColor: bot.color)
/// if face.isImage {
///     PhotoAvatar(...)                       // the existing renderer
///         .overlay(face)   // no ring: the face itself is the signal
/// } else {
///     BotAvatarView(identity: bot.id, color: bot.color, activity: activity, size: 32)
/// }
/// ```
///
/// — which is why the face and the picture are drawn by different code.
///
/// ## What it draws
///
/// The body is filled with the bot's palette colour, the eyes are cut out in the page colour unless
/// the body is nearly white or black (`BotAvatarPalette.eyeTone`), and the **state is drawn as
/// motion**: the body breathes (and bobs while writing) while the eyes and lids run that state's
/// authored track — sweeps while reading, dips while writing, a look up while thinking, side
/// glances on the computer — with a scheduled blink. This is the reference's own model
/// (`logoAvatarFrame`), not an approximation of it: its shipped faces are near-still bodies with very
/// active eyes, not spinning rings. Below 24 pt, under Reduce Motion, or when `animates` is false,
/// the face holds still.
///
/// **On top of that acting, a busy face performs** (`BotAvatarPerformance`): a jump and a flip
/// alternating every few seconds, saccades and the odd double take between them, and a squint on its
/// own slower clock. That is a deliberate departure from the reference, asked for on 2026-11-16; the
/// port itself is untouched, which is why the two live in separate functions and only this view
/// composes them.
public struct BotAvatarView: View {
    /// The bot's id. The colour and the shape are both derived from it when nothing is stored.
    public var identity: String
    /// The stored `bots.color` value: `#RRGGBB`, `#RRGGBB::shape_N`, a palette id or name, or a
    /// `data:image/…` URL. `nil` means "derive it from the id".
    public var color: String?
    /// What the bot is doing. See `BotAvatarActivity.from(status:toolNames:composing:thinking:background:)`.
    public var activity: BotAvatarActivity
    /// The avatar's side, in points. Any size; the artwork is vector.
    public var size: CGFloat
    /// Static, as the system's Reduce Motion asks. The environment value also stops the motion.
    public var reduceMotion: Bool
    /// Whether this avatar may move at all, separate from Reduce Motion. A long bot list passes
    /// `false` for its idle rows, which is the difference between one face rebuilding per frame and
    /// twenty.
    public var animates: Bool
    /// The size at which this face starts moving. Defaults to the house floor; a surface where the
    /// face *is* the status (the working row) passes `0` so even a 16 pt icon moves.
    public var animatingFrom: Double
    /// Spoken label, e.g. the bot's name. Without one the avatar is hidden from the accessibility
    /// tree — it is decoration beside a name that is already read out.
    public var label: String?
    /// The colour the eyes are cut out in. Defaults to the page (`Tokens.canvas`).
    public var pageBackground: Color?
    /// The bot's own generated avatar, when it has one (`BotAvatarDocument`). A bot with a definition
    /// draws that instead of the shape-and-palette face — the whole row, header and pet follow this
    /// one branch, so no two surfaces can disagree about which face a bot wears.
    ///
    /// Almost nothing passes this. The stored avatar arrives through the environment
    /// (`EnvironmentValues.botAvatars`, injected once at each app's root), so a call site that knows
    /// only the bot's id still draws the face the bot chose; the parameter exists for a preview or an
    /// editor that is drawing a definition the host does not have yet.
    public var definition: BotAvatarDefinition?
    /// The definition's colour: `#RRGGBB`, or nil for the house colour. Only read beside an explicit
    /// `definition:` — a stored definition brings its own stored colour with it.
    public var avatarColor: String?

    @Environment(\.botAvatars) private var avatarLibrary

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Backgrounded windows keep their faces still: the Mac target had no such gate, so a minimised
    /// conversation went on redrawing 30 times a second behind another app.
    @Environment(\.scenePhase) private var scenePhase
    /// The app's own motion switch (Settings → Appearance). Read here rather than sampled in a
    /// helper so flipping it redraws the faces that are on screen.
    @AppStorage(BotAvatarMotion.defaultsKey) private var appAllowsMotion = true

    public init(identity: String,
                color: String? = nil,
                activity: BotAvatarActivity = .idle,
                size: CGFloat = 36,
                reduceMotion: Bool = false,
                animates: Bool = true,
                animatingFrom: Double = BotAvatarMotion.minimumAnimatingSize,
                label: String? = nil,
                pageBackground: Color? = nil,
                definition: BotAvatarDefinition? = nil,
                avatarColor: String? = nil) {
        self.identity = identity
        self.color = color
        self.activity = activity
        self.size = size
        self.reduceMotion = reduceMotion
        self.animates = animates
        self.animatingFrom = animatingFrom
        self.label = label
        self.pageBackground = pageBackground
        self.definition = definition
        self.avatarColor = avatarColor
    }

    /// The fixed inks for the two bodies that are too pale or too dark for a cut-out. The reference
    /// picks whichever of the page's own two colours contrasts with the body; the app's page colours
    /// are dynamic, so the bars are pinned to the two ends of the same scale instead — which is what
    /// the reference resolves to on a light page, and the right answer on a dark one.
    static let darkEyeInk = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let lightEyeInk = Color.white

    public var body: some View {
        if let face = self.face {
            // The generated avatar draws itself, in its own volume; the shape-and-palette face below
            // is untouched, which is what keeps a bot without one looking exactly as it did.
            OpenBotAvatarView(definition: face.definition,
                              color: face.color,
                              material: face.material,
                              state: OpenBotAvatarState(activity: activity),
                              mood: OpenBotAvatarState.mood(for: activity),
                              size: size,
                              animates: animates,
                              reduceMotion: reduceMotion,
                              animatingFrom: animatingFrom,
                              label: label)
        } else {
            shapeBody
        }
    }

    /// The face this view draws: the definition it was handed (a preview, the editor), else what the
    /// environment says the host stores for this bot.
    ///
    /// One resolution for every surface. Before this, four call sites passed the stored definition
    /// and twelve did not, so a bot's new avatar appeared in its header and its old one in Settings,
    /// in the bot panel and in every list row — the report that started this. A caller's `color:` is
    /// deliberately *not* consulted when the definition came from the host: the stored colour
    /// belongs to the stored body, and a stale `bots.color` must not repaint a newer face.
    private var face: BotAvatarDocument? {
        if let definition {
            return BotAvatarDocument(definition: definition, color: avatarColor)
        }
        return avatarLibrary[identity]
    }

    private var shapeBody: some View {
        let resolved = BotAvatarIdentity.resolve(identity: identity, explicitColor: color)
        let moves = BotAvatarMotion.allows(activity: activity,
                                           reduceMotion: reduceMotion || systemReduceMotion,
                                           animates: animates && appAllowsMotion
                                               && scenePhase == .active,
                                           size: size,
                                           minimumSize: animatingFrom)
        let traits = BotAvatarMotionTraits(identity: resolved.identity)

        // Built once per body evaluation, not once per tick: the shape's arcs were being re-rastered
        // 30 times a second inside the timeline closure (`A8_mark_constmask` in Tinker's sample).
        let facePath = resolved.shape.path(inSide: size)

        // `body` gets result-builder semantics from the protocol; this property does not, so a body
        // with more than one statement needs the return spelled out.
        return TimelineView(.animation(minimumInterval: BotAvatarMotion.frameInterval(for: activity),
                                paused: !moves)) { context in
            content(resolved: resolved, facePath: facePath, traits: traits, moves: moves,
                    date: context.date)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(resolved: resolved))
        .accessibilityHidden(label == nil)
    }

    // MARK: - Layers

    @ViewBuilder
    private func content(resolved: BotAvatarIdentity,
                         facePath: Path,
                         traits: BotAvatarMotionTraits,
                         moves: Bool,
                         date: Date) -> some View {
        let time = date.timeIntervalSinceReferenceDate
        // One frame, evaluated exactly as the reference's `logoAvatarFrame`, with the state's stunts
        // performed over it: the body breathes (and bobs while writing), the eyes and lids follow the
        // state's authored track, a scheduled blink closes them, and — in every busy state — the face
        // also jumps, flips, darts and squints between the acting (`BotAvatarPerformance`, asked for
        // 2026-11-16). Idle, waiting and error keep the reference's own stillness.
        let frame = moves
            ? BotAvatarMotion.performedFrame(activity: activity, traits: traits, at: time, side: Double(size))
            : .rest
        let body = frame.body
        let eyes = frame.eyes

        ZStack {
            if resolved.isImage {
                // A photo avatar is the caller's to draw. An empty face is the honest placeholder
                // for a shape module.
                Color.clear
            } else {
                ZStack {
                    facePath
                        .fill(resolved.color.color)
                        .brightness(body.brightness)
                    eyesLayer(resolved: resolved, pose: eyes)
                }
                .frame(width: size, height: size)
                .scaleEffect(x: body.scaleX, y: body.scaleY)
                .rotationEffect(.degrees(body.rotate))
                .offset(x: body.translateX * size, y: body.translateY * size)
            }
        }
        .frame(width: size, height: size)
    }

    private func eyesLayer(resolved: BotAvatarIdentity, pose: BotAvatarEyePose) -> some View {
        let geometry = BotAvatarGeometry.shipped
        let scale = CGFloat(geometry.scale(forSide: Double(size)))
        let box = geometry.eyes.bounds

        return ZStack(alignment: .topLeading) {
            ForEach(geometry.eyes.bars) { bar in
                RoundedRectangle(cornerRadius: CGFloat(bar.cornerRadius) * scale, style: .continuous)
                    .fill(eyeInk(bodyHex: resolved.color.hex))
                    .frame(width: CGFloat(bar.width) * scale, height: CGFloat(bar.height) * scale)
                    .offset(x: CGFloat(bar.x - geometry.viewBox.minX) * scale,
                            y: CGFloat(bar.y - geometry.viewBox.minY) * scale)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        // The reference transforms the eyes about their own centre; the frame's centre is the view
        // box's (114.5, 114.5), eight units below the eyes' (114.2705, 106.2705). At the sizes this
        // draws, that is under a third of a point, and pinning the anchor to the frame keeps the
        // layer's transforms independent of the body's.
        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .center)
        .offset(x: pose.offsetX * box.width * scale, y: pose.offsetY * box.height * scale)
    }

    private func eyeInk(bodyHex: String) -> Color {
        switch BotAvatarPalette.eyeTone(forBody: bodyHex) {
        case .page: return pageBackground ?? Tokens.canvas
        case .dark: return Self.darkEyeInk
        case .light: return Self.lightEyeInk
        }
    }

    private func accessibilityText(resolved: BotAvatarIdentity) -> String {
        let name = label ?? ""
        let state = activity.accessibilityDescription
        return name.isEmpty ? state : "\(name), \(state)"
    }
}

/// The ring a bot used to wear while it was doing something.
///
/// **Nothing draws this any more.** The reference's shipped faces carry no ring at all — its bots
/// act through eyes and body, one motion per state — and the half-circle turning around a working
/// face was ours, not theirs. The type is kept only because it is public API; deleting it is a
/// separate, deliberate break.
///
/// Public because a photo avatar needs it too: the reference draws the same ring around a picture,
/// and a caller that renders an image itself can lay this over it. The geometry is the reference's —
/// a 48-unit box, radius 22, stroke 3.2, a 45-unit arc and a comet head at the tip — inset four
/// points around the avatar.
public struct BotAvatarRing: View {
    public var size: CGFloat
    public var tint: Color
    /// Whether the ring is drawn at all. The reference fades it over 180 ms, which this matches.
    public var active: Bool
    /// Whether it turns. Its turn is 1.2 s, the reference's `rakazo-avatar-spin`.
    public var spinning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat, tint: Color, active: Bool, spinning: Bool = true) {
        self.size = size
        self.tint = tint
        self.active = active
        self.spinning = spinning
    }

    public var body: some View {
        let ringSide = size + 8
        let unit = ringSide / 48
        let turns = spinning && !reduceMotion
        // A 45-unit arc of a radius-22 circle: 45 / (2π · 22).
        let arc = 45.0 / (2 * Double.pi * 22)

        TimelineView(.animation(minimumInterval: BotAvatarMotion.frameInterval, paused: !turns)) { context in
            let angle = turns ? angle(at: context.date) : 0
            ZStack {
                Circle()
                    .trim(from: 0, to: arc)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: tint.opacity(0.9), location: 0.6),
                                .init(color: tint.opacity(0), location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 3.2 * unit, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    // Inset 2 of the 48 units: the reference's circle is r=22 in a 48-unit box.
                    .padding(2 * unit)

                Circle()
                    .fill(.white)
                    .frame(width: 5.6 * unit, height: 5.6 * unit)
                    .offset(x: 19 * unit)
            }
            .frame(width: ringSide, height: ringSide)
            .rotationEffect(.degrees(angle))
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where in the 1.2 s turn this instant is.
    ///
    /// The cycle is the reference's (`rakazo-avatar-spin`, 1.2 s infinite). Its timing function is
    /// `cubic-bezier(0.4, 0, 0.2, 1)`, which eases *within* every turn; this port turns linearly
    /// instead, because a ring that slows to a stop and starts again once a second reads as a stutter
    /// rather than as work in progress. Same cycle, one deliberate difference in the curve.
    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / BotAvatarMotion.workingRingDuration
        return (turns - turns.rounded(.down)) * 360
    }
}

#if DEBUG
#Preview("Bot avatar · shapes") {
    VStack(spacing: 20) {
        HStack(spacing: 14) {
            ForEach(BotAvatarShape.shipped) { shape in
                BotAvatarView(identity: shape.id, color: "#A97EFE::shape_\(BotAvatarShape.index(of: shape.kind))", size: 44)
            }
        }
        HStack(spacing: 14) {
            ForEach([BotAvatarActivity.idle, .thinking, .reading, .working, .computer, .waiting, .blocked, .done], id: \.self) { activity in
                BotAvatarView(identity: "research", activity: activity, size: 40)
            }
        }
        HStack(spacing: 14) {
            ForEach([16.0, 24.0, 32.0, 56.0, 96.0], id: \.self) { side in
                BotAvatarView(identity: "nightly-build", activity: .working, size: side)
            }
        }
    }
    .padding(24)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
#endif
