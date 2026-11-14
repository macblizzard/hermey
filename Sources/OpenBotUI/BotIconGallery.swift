import SwiftUI

/// Original geometric robot portraits. These are not representations of existing characters.
public enum BotIcon: String, CaseIterable, Identifiable, Codable {
    /// The ten original ids, kept by name so every stored face still reads.
    case ember, nova, cobalt, orbit, moss, dusk, beacon, pixel, rover, prism
    /// The rest of the set: silhouettes that never had an id because the old drawings could not
    /// have been them — a mushroom is not a robot, and that is the point.
    case lump, mushroom, blob, capsule, droplet, scallop

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    fileprivate var variant: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// The twelve swatches a bot can wear.
///
/// The ten portraits used to be ten drawings with a colour baked into each one, which is why a bot
/// could not have "the beacon shape in blue". Shape and colour are separate now: any of the ten
/// silhouettes, in any of these twelve. `BotFace.legacy` keeps every existing bot's exact face.
public enum BotColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case orange, amber, lime, mint, teal, cyan, blue, indigo, purple, pink, ruby, slate

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    public var swatch: Color {
        switch self {
        case .orange: return Color(red: 0.96, green: 0.60, blue: 0.24)
        case .amber:  return Color(red: 0.94, green: 0.78, blue: 0.30)
        case .lime:   return Color(red: 0.66, green: 0.86, blue: 0.32)
        case .mint:   return Color(red: 0.33, green: 0.86, blue: 0.65)
        case .teal:   return Color(red: 0.22, green: 0.79, blue: 0.80)
        case .cyan:   return Color(red: 0.29, green: 0.72, blue: 0.95)
        case .blue:   return Color(red: 0.34, green: 0.55, blue: 0.98)
        case .indigo: return Color(red: 0.49, green: 0.44, blue: 0.95)
        case .purple: return Color(red: 0.67, green: 0.44, blue: 0.96)
        case .pink:   return Color(red: 0.95, green: 0.44, blue: 0.72)
        case .ruby:   return Color(red: 0.94, green: 0.34, blue: 0.40)
        case .slate:  return Color(red: 0.56, green: 0.61, blue: 0.69)
        }
    }

    /// Deterministic, like `BotFace.default(for:)`: a bot has a face before the host answers.
    public static func `default`(for botID: String) -> BotColor {
        allCases[Int(Self.hash(botID) % UInt64(allCases.count))]
    }

    private static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0x811C_9DC5
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 16_777_619
        }
        return hash
    }
}

/// A silhouette and a swatch: everything a portrait is drawn from.
public struct BotFace: Hashable, Codable, Sendable {
    public var shape: BotIcon
    public var color: BotColor

    public init(shape: BotIcon, color: BotColor) {
        self.shape = shape
        self.color = color
    }

    /// The face each of the ten original portraits wore before shape and colour were separate, so
    /// no bot's face changes when it is first read back from a host that only stored an icon id.
    public static func legacy(_ shape: BotIcon) -> BotFace {
        let color: BotColor
        switch shape {
        case .ember:  color = .orange
        case .nova:   color = .pink
        case .cobalt: color = .cyan
        case .orbit:  color = .purple
        case .moss:   color = .lime
        case .dusk:   color = .indigo
        case .beacon: color = .amber
        case .pixel:  color = .mint
        case .rover:  color = .blue
        case .prism:  color = .ruby
        case .lump:     color = .slate
        case .mushroom: color = .teal
        case .blob:     color = .indigo
        case .capsule:  color = .blue
        case .droplet:  color = .cyan
        case .scallop:  color = .pink
        }
        return BotFace(shape: shape, color: color)
    }

    /// A face for a bot that has never been given one: shape and colour both from its id, so the
    /// first second of a launch looks finished instead of a list of initials.
    public static func `default`(for botID: String) -> BotFace {
        BotFace(shape: .default(for: botID), color: .default(for: botID))
    }
}

/// What the picker holds and what the host stores: a face, or the bot's own initials.
public struct BotFaceChoice: Hashable, Codable, Sendable {
    public var shape: BotIcon
    public var color: BotColor

    public init(_ face: BotFace) {
        self.shape = face.shape
        self.color = face.color
    }

    public var face: BotFace { BotFace(shape: shape, color: color) }
}

extension BotIcon {
    /// The portrait a bot wears until someone gives it one of its own.
    ///
    /// Deterministic from the bot's id, so a bot keeps the same face across launches, across
    /// devices, and before the host has even answered — which is what makes the first second of a
    /// launch look finished instead of a list of initials.
    public static func `default`(for botID: String) -> BotIcon {
        var hash: UInt64 = 0x811C_9DC5
        for byte in botID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 16_777_619
        }
        return allCases[Int(hash % UInt64(allCases.count))]
    }
}

/// Scalable vector artwork, shared by the macOS and iOS shells.
/// What a bot is doing, said on its face instead of in a chip beside its name.
///
/// A chip is a label you have to read; a bot that sparks, flashes or zips is a thing you notice
/// while looking at something else. The three states are the three the header used to spell out.
public enum PortraitStatus: String, Sendable, Hashable {
    /// It is asking for you — the exclamation flashes.
    case needsYou
    /// A turn is in flight — the antenna sparks and the spark travels.
    case working
    /// The transcript is being compacted — a zip runs down the face and closes.
    case compacting
}

public struct BotIconPortrait: View {
    public let icon: BotIcon
    /// The swatch this shape is drawn in. Taken from the face when a caller has one.
    public var color: Color
    public var size: CGFloat
    public var isWorking: Bool
    /// `isWorking` is kept because a dozen call sites pass it; `status` is the whole story, and a
    /// caller that knows which state it is should pass that instead.
    public var status: PortraitStatus?

    /// The way every caller should construct a portrait: shape and colour together.
    ///
    /// `isWorking` is here as well as on the legacy init, and with the same label order, because a
    /// call site written against the old signature must still resolve to the *face* overload.
    public init(_ face: BotFace, size: CGFloat = 56, isWorking: Bool = false,
                status: PortraitStatus? = nil) {
        self.icon = face.shape
        self.color = face.color.swatch
        self.size = size
        self.isWorking = isWorking || status == .working
        self.status = status ?? (isWorking ? .working : nil)
    }

    /// The legacy door: a bare shape, in the colour that shape used to be drawn in.
    public init(_ icon: BotIcon, size: CGFloat = 56, isWorking: Bool = false,
                status: PortraitStatus? = nil) {
        self.icon = icon
        self.color = BotFace.legacy(icon).color.swatch
        self.size = size
        self.isWorking = isWorking
        self.status = status ?? (isWorking ? .working : nil)
    }

    /// The swatch. `tint` is gone: a shape no longer carries a colour of its own.
    private var tint: Color { color }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Motion is a courtesy, not the point: below 18 pt the face is a legend for a row, and a small
    /// thing that moves is a small thing that catches the eye for no reason. The app's own switch
    /// (Settings → Appearance) answers first; without one, the system's Reduce Motion does.
    private var motionIsOn: Bool { BotFaceMotion.allows(reduceMotion: reduceMotion, size: size) }

    public var body: some View {
        ZStack {
            // One solid silhouette and two eyes. No ring, no body, no antenna: the shape is the
            // bot, and the state badge below has a clean mass to sit on instead of a drawing it
            // has to compete with.
            BotSilhouette(icon)
                .fill(tint)

            // Tier one: light from above, shadow below, an inner rim. Inside the silhouette, so the
            // outline that makes a shape recognisable never changes (#100).
            BotFaceLight(icon: icon, size: size)

            // The blink is read from the clock, not from a `@State` flag: a timeline over just the
            // eyes cannot be cancelled by a re-render, cannot be dropped for being written from the
            // wrong actor, and costs ten rebuilds a second of two rounded rectangles.
            TimelineView(.animation(minimumInterval: 0.1, paused: !motionIsOn || scenePhase != .active)) { context in
                BotEyes(size: size,
                        tilt: icon.eyeTilt,
                        blink: blink(at: context.date),
                        squint: isWorking ? 1 : 0)
            }

            switch status {
            case .needsYou: NeedsYouFlash(size: size, tint: tint)
            case .working: BotWorkingSparks(size: size, color: tint, isWorking: true)
            case .compacting: CompactingZip(size: size, tint: tint)
            case nil: EmptyView()
            }
        }
        .frame(width: size, height: size)
        // Tier two: a slow breath, and a blink every few seconds. Both are implicit animations over
        // two `@State` flags rather than a `TimelineView`, deliberately: a timeline rebuilds the view
        // tree every frame, and this face is drawn once per roster row (see #99).
        // The breath, system-driven: `phaseAnimator` runs the cycle on the render server, with no
        // state of ours to write and nothing to cancel. A single phase means "still".
        .phaseAnimator(motionIsOn ? [0.0, 1.0] : [0.0], trigger: motionIsOn) { content, phase in
            content.scaleEffect(1.0 + 0.025 * phase)
        } animation: { _ in .easeInOut(duration: 1.8) }
        // Squinting is a state change, not a loop, so it animates once on its own.
        .animation(.easeOut(duration: 0.22), value: isWorking)
        .accessibilityLabel("\(icon.title) bot face")
    }
}


/// The blink, as a function of the clock.
///
/// Each face keeps its own period — derived from the icon's own name, so equal faces match and a
/// roster of eight does not blink in unison, which reads as a rendering glitch rather than as faces.
/// The shut is about a tenth of a second: enough to see, short enough not to look like a wink.
private extension BotIconPortrait {
    func blink(at date: Date) -> Double {
        guard motionIsOn else { return 0 }
        let seed = Double(abs(icon.title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 7)) * 0.31
        let period = 3.4 + seed
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        // The last 0.14 s of every period is the blink.
        return phase > period - 0.14 ? 1 : 0
    }
}

/// Shared working indicator that leaves the underlying portrait unchanged.
public struct BotWorkingSparks: View {
    public var size: CGFloat
    public var color: Color
    public var isWorking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat, color: Color, isWorking: Bool) {
        self.size = size; self.color = color; self.isWorking = isWorking
    }

    public var body: some View {
        ZStack {
            if isWorking {
                if reduceMotion {
                    antennaSparks(opacity: 0.65)
                } else {
                    TimelineView(.animation(minimumInterval: 0.12)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                        antennaSparks(opacity: 0.45 + 0.4 * (0.5 + 0.5 * sin(phase * 5)))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Small angular arcs frame the antenna without obscuring the face.
    private func antennaSparks(opacity: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.12, y: size * 0.04))
            path.addLine(to: CGPoint(x: size * 0.06, y: size * 0.08))
            path.addLine(to: CGPoint(x: size * 0.11, y: size * 0.10))
            path.addLine(to: CGPoint(x: size * 0.05, y: size * 0.15))
            path.move(to: CGPoint(x: size * 0.38, y: size * 0.04))
            path.addLine(to: CGPoint(x: size * 0.44, y: size * 0.08))
            path.addLine(to: CGPoint(x: size * 0.39, y: size * 0.10))
            path.addLine(to: CGPoint(x: size * 0.45, y: size * 0.15))
        }
        .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: max(1, size * 0.025), lineCap: .round, lineJoin: .round))
        .frame(width: size * 0.5, height: size * 0.2)
        .offset(y: -size * 0.23)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// A flashing exclamation in the corner of the face: the one state that is a request.
///
/// It pulses rather than spins, and it is drawn, not a font glyph, so it keeps its weight at 14 pt
/// in a roster row and at 34 pt in the header pill.
public struct NeedsYouFlash: View {
    public var size: CGFloat
    public var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat, tint: Color) {
        self.size = size; self.tint = tint
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = reduceMotion ? 1.0 : 0.55 + 0.45 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4.2))
            badge(opacity: phase, scale: reduceMotion ? 1 : 0.94 + 0.1 * phase)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func badge(opacity: Double, scale: Double) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.85))
            Circle().strokeBorder(tint.opacity(0.9), lineWidth: max(1, size * 0.02))
            VStack(spacing: size * 0.035) {
                Capsule().fill(tint)
                    .frame(width: size * 0.055, height: size * 0.135)
                Circle().fill(tint)
                    .frame(width: size * 0.055, height: size * 0.055)
            }
        }
        .frame(width: size * 0.40, height: size * 0.40)
        .scaleEffect(scale)
        .opacity(opacity)
        .offset(x: size * 0.30, y: size * 0.28)
    }
}

/// A zip closing down the face: two combs of teeth meeting, and the pull travelling with them.
///
/// At 14 pt the teeth are texture rather than detail — what reads is the seam closing and
/// reopening, which is exactly what compaction is.
public struct CompactingZip: View {
    public var size: CGFloat
    public var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closed = false

    public init(size: CGFloat, tint: Color) {
        self.size = size; self.tint = tint
    }

    public var body: some View {
        ZStack {
            // A dark scrim, so the zip is legible over any silhouette underneath it.
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .frame(width: size * 0.46, height: size * 0.44)

            teeth(goingDown: true).offset(y: closed ? size * 0.055 : -size * 0.055)
            teeth(goingDown: false).offset(y: closed ? -size * 0.055 : size * 0.055)

            Capsule()
                .fill(tint)
                .frame(width: size * 0.075, height: size * 0.10)
                .offset(y: closed ? size * 0.20 : -size * 0.20)
        }
        .onAppear {
            guard !reduceMotion else { closed = true; return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                closed = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func teeth(goingDown: Bool) -> some View {
        HStack(spacing: size * 0.035) {
            ForEach(0..<3, id: \.self) { _ in
                Triangle(pointingDown: goingDown)
                    .fill(tint.opacity(0.85))
                    .frame(width: size * 0.085, height: size * 0.07)
            }
        }
    }
}

/// One tooth. A `Path` rather than a glyph so three of them at 3 pt wide stay crisp.
struct Triangle: Shape {
    var pointingDown: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointingDown {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

/// Shape × colour, the way Rakazo draws it: one big portrait, then the silhouettes, then the
/// swatches.
///
/// Selection is controlled by the caller — persistence is never local. The two grids are separate
/// because the choices are separate: a person who likes the beacon's antenna should not have to give
/// up the colour it is drawn in to keep it.
public struct BotFacePicker: View {
    public let face: BotFace?
    public let choose: (BotFace?) -> Void

    /// The face being composed. Seeded from the bot's current one, so opening the picker and
    /// changing only the colour keeps the shape that was already there.
    @State private var draft: BotFace

    public init(face: BotFace?, choose: @escaping (BotFace?) -> Void) {
        self.face = face
        self.choose = choose
        _draft = State(initialValue: face ?? BotFace(shape: .ember, color: .cyan))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            preview

            grid(title: "Shape") {
                // Eight across: sixteen silhouettes make two clean rows, and the grid is read as
                // one set rather than a list that wrapped.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
                          spacing: 8) {
                    ForEach(BotIcon.allCases) { shape in
                        Button {
                            draft.shape = shape
                            commit()
                        } label: {
                            // The shape draws itself, so the selection ring is a rounded square
                            // around the tile instead of a circle around the shape — a ring tight
                            // to a mushroom and a ring tight to a capsule cannot both read right.
                            BotIconPortrait(BotFace(shape: shape, color: draft.color), size: 34)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(draft.shape == shape ? Tokens.controlActive : .clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(draft.shape == shape ? Tokens.accent : .clear,
                                                      lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(shape.title) shape")
                        .accessibilityAddTraits(draft.shape == shape ? .isSelected : [])
                    }
                }
            }

            grid(title: "Colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
                          spacing: 8) {
                    ForEach(BotColor.allCases) { swatch in
                        Button {
                            draft.color = swatch
                            commit()
                        } label: {
                            Circle()
                                .fill(swatch.swatch)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(draft.color == swatch
                                                          ? Tokens.textPrimary : .clear,
                                                          lineWidth: 2)
                                )
                                .overlay(
                                    Circle().strokeBorder(Tokens.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(swatch.title) colour")
                        .accessibilityAddTraits(draft.color == swatch ? .isSelected : [])
                    }
                }
            }

        }
    }

    /// The face being built, at a size where the drawing is actually legible.
    private var preview: some View {
        HStack(spacing: 14) {
            BotIconPortrait(draft, size: 76)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(draft.shape.title) · \(draft.color.title)")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text("Any shape, any colour — the bot list, the chat header and your own message bubbles all take it.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
    }

    private func grid<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TypeScale.font(TypeScale.sm, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            content()
        }
    }

    private func commit() {
        choose(draft)
    }
}
