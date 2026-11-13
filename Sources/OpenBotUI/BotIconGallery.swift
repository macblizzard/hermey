import SwiftUI

/// Original geometric robot portraits. These are not representations of existing characters.
public enum BotIcon: String, CaseIterable, Identifiable, Codable {
    case ember, nova, cobalt, orbit, moss, dusk, beacon, pixel, rover, prism
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
    public var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.18))
            Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1)
            if icon.variant < 6 {
            VStack(spacing: size * 0.035) {
                if icon.variant % 2 == 0 {
                    Capsule().fill(tint).frame(width: size * 0.09, height: size * 0.12)
                } else {
                    Circle().fill(tint).frame(width: size * 0.10, height: size * 0.10)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .fill(tint.opacity(0.85))
                    VStack(spacing: size * 0.08) {
                        HStack(spacing: size * 0.10) {
                            Circle().fill(Color.black.opacity(0.8))
                            Circle().fill(Color.black.opacity(0.8))
                        }.frame(width: size * 0.28, height: size * 0.09)
                        Capsule().fill(Color.black.opacity(0.7))
                            .frame(width: size * (icon.variant % 3 == 0 ? 0.22 : 0.14), height: size * 0.035)
                    }
                }.frame(width: size * 0.54, height: size * 0.43)
            }
            } else {
                newPortrait
            }
            switch status {
            case .needsYou: NeedsYouFlash(size: size, tint: tint)
            case .working: BotWorkingSparks(size: size, color: tint, isWorking: true)
            case .compacting: CompactingZip(size: size, tint: tint)
            case nil: EmptyView()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(icon.title) robot icon")
    }


    // Each new silhouette is drawn in normalized coordinates so it scales with
    // the same portrait sizes as the original six, without bundled artwork.
    @ViewBuilder private var newPortrait: some View {
        switch icon {
        case .beacon:
            VStack(spacing: size * 0.02) {
                Circle().fill(tint).frame(width: size * 0.12, height: size * 0.12)
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: size * 0.48, height: size * 0.48)
                    .overlay(Circle().fill(.black.opacity(0.8))
                        .frame(width: size * 0.19, height: size * 0.19)
                        .overlay(Circle().fill(.white.opacity(0.8))
                            .frame(width: size * 0.05, height: size * 0.05)))
            }
        case .pixel:
            VStack(spacing: size * 0.03) {
                HStack(spacing: size * 0.22) {
                    Rectangle().frame(width: size * 0.06, height: size * 0.1)
                    Rectangle().frame(width: size * 0.06, height: size * 0.1)
                }.foregroundStyle(tint)
                Rectangle().fill(tint.opacity(0.85))
                    .frame(width: size * 0.56, height: size * 0.39)
                    .overlay(VStack(spacing: size * 0.07) {
                        HStack(spacing: size * 0.12) {
                            Rectangle().frame(width: size * 0.08, height: size * 0.08)
                            Rectangle().frame(width: size * 0.08, height: size * 0.08)
                        }
                        Rectangle().frame(width: size * 0.22, height: size * 0.035)
                    }.foregroundStyle(.black.opacity(0.8)))
            }
        case .rover:
            VStack(spacing: size * 0.025) {
                Capsule().fill(tint).frame(width: size * 0.25, height: size * 0.06)
                HStack(spacing: 0) {
                    Circle().fill(tint).frame(width: size * 0.12, height: size * 0.12)
                    RoundedRectangle(cornerRadius: size * 0.11)
                        .fill(tint.opacity(0.85))
                        .frame(width: size * 0.46, height: size * 0.38)
                        .overlay(Capsule().fill(.black.opacity(0.8))
                            .frame(width: size * 0.34, height: size * 0.13)
                            .overlay(HStack(spacing: size * 0.10) {
                                Circle().fill(.white.opacity(0.8))
                                Circle().fill(.white.opacity(0.8))
                            }.frame(width: size * 0.19, height: size * 0.045)))
                    Circle().fill(tint).frame(width: size * 0.12, height: size * 0.12)
                }
            }
        case .prism:
            VStack(spacing: size * 0.03) {
                Capsule().fill(tint).frame(width: size * 0.06, height: size * 0.10)
                Path { path in
                    path.move(to: CGPoint(x: size * 0.28, y: 0))
                    path.addLine(to: CGPoint(x: size * 0.56, y: size * 0.13))
                    path.addLine(to: CGPoint(x: size * 0.48, y: size * 0.39))
                    path.addLine(to: CGPoint(x: size * 0.08, y: size * 0.39))
                    path.addLine(to: CGPoint(x: 0, y: size * 0.13))
                    path.closeSubpath()
                }.fill(tint.opacity(0.85))
                    .frame(width: size * 0.56, height: size * 0.39)
                    .overlay(VStack(spacing: size * 0.07) {
                        HStack(spacing: size * 0.12) {
                            Capsule().frame(width: size * 0.09, height: size * 0.045)
                            Capsule().frame(width: size * 0.09, height: size * 0.045)
                        }
                        Circle().frame(width: size * 0.06, height: size * 0.06)
                    }.foregroundStyle(.black.opacity(0.8)))
            }
        default:
            EmptyView()
        }
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                          spacing: 10) {
                    ForEach(BotIcon.allCases) { shape in
                        Button {
                            draft.shape = shape
                            commit()
                        } label: {
                            BotIconPortrait(BotFace(shape: shape, color: draft.color), size: 44)
                                .overlay(
                                    Circle()
                                        .strokeBorder(face != nil && draft.shape == shape
                                                      ? Tokens.accent : .clear,
                                                      lineWidth: 2)
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

            Button {
                choose(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                    Text("Use its initials instead")
                }
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(face == nil ? Tokens.textPrimary : Tokens.textMuted)
            }
            .buttonStyle(.plain)
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
