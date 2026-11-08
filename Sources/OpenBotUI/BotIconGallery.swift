import SwiftUI

/// Original geometric robot portraits. These are not representations of existing characters.
public enum BotIcon: String, CaseIterable, Identifiable, Codable {
    case ember, nova, cobalt, orbit, moss, dusk, beacon, pixel, rover, prism
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    fileprivate var tint: Color {
        switch self {
        case .ember: return .orange
        case .nova: return .pink
        case .cobalt: return .cyan
        case .orbit: return .purple
        case .moss: return .green
        case .dusk: return .indigo
        case .beacon: return .yellow
        case .pixel: return .mint
        case .rover: return .blue
        case .prism: return .red
        }
    }
    fileprivate var variant: Int { Self.allCases.firstIndex(of: self) ?? 0 }
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
public struct BotIconPortrait: View {
    public let icon: BotIcon
    public var size: CGFloat
    public var isWorking: Bool


    public init(_ icon: BotIcon, size: CGFloat = 56, isWorking: Bool = false) {
        self.icon = icon; self.size = size; self.isWorking = isWorking
    }
    public var body: some View {
        ZStack {
            Circle().fill(icon.tint.opacity(0.18))
            Circle().strokeBorder(icon.tint.opacity(0.6), lineWidth: 1)
            if icon.variant < 6 {
            VStack(spacing: size * 0.035) {
                if icon.variant % 2 == 0 {
                    Capsule().fill(icon.tint).frame(width: size * 0.09, height: size * 0.12)
                } else {
                    Circle().fill(icon.tint).frame(width: size * 0.10, height: size * 0.10)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .fill(icon.tint.opacity(0.85))
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
            BotWorkingSparks(size: size, color: icon.tint, isWorking: isWorking)
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
                Circle().fill(icon.tint).frame(width: size * 0.12, height: size * 0.12)
                Capsule().fill(icon.tint.opacity(0.85))
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
                }.foregroundStyle(icon.tint)
                Rectangle().fill(icon.tint.opacity(0.85))
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
                Capsule().fill(icon.tint).frame(width: size * 0.25, height: size * 0.06)
                HStack(spacing: 0) {
                    Circle().fill(icon.tint).frame(width: size * 0.12, height: size * 0.12)
                    RoundedRectangle(cornerRadius: size * 0.11)
                        .fill(icon.tint.opacity(0.85))
                        .frame(width: size * 0.46, height: size * 0.38)
                        .overlay(Capsule().fill(.black.opacity(0.8))
                            .frame(width: size * 0.34, height: size * 0.13)
                            .overlay(HStack(spacing: size * 0.10) {
                                Circle().fill(.white.opacity(0.8))
                                Circle().fill(.white.opacity(0.8))
                            }.frame(width: size * 0.19, height: size * 0.045)))
                    Circle().fill(icon.tint).frame(width: size * 0.12, height: size * 0.12)
                }
            }
        case .prism:
            VStack(spacing: size * 0.03) {
                Capsule().fill(icon.tint).frame(width: size * 0.06, height: size * 0.10)
                Path { path in
                    path.move(to: CGPoint(x: size * 0.28, y: 0))
                    path.addLine(to: CGPoint(x: size * 0.56, y: size * 0.13))
                    path.addLine(to: CGPoint(x: size * 0.48, y: size * 0.39))
                    path.addLine(to: CGPoint(x: size * 0.08, y: size * 0.39))
                    path.addLine(to: CGPoint(x: 0, y: size * 0.13))
                    path.closeSubpath()
                }.fill(icon.tint.opacity(0.85))
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

/// Selection is controlled by the caller; persistence is deliberately not local.
public struct BotIconGallery: View {
    public let selected: BotIcon?
    public let choose: (BotIcon?) -> Void
    public init(selected: BotIcon?, choose: @escaping (BotIcon?) -> Void) {
        self.selected = selected; self.choose = choose
    }
    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86))], spacing: 18) {
            Button { choose(nil) } label: {
                VStack { Image(systemName: "person.crop.circle").font(.system(size: 48)); Text("Initials") }
                    .frame(maxWidth: .infinity)
            }.accessibilityAddTraits(selected == nil ? .isSelected : [])
            ForEach(BotIcon.allCases) { icon in
                Button { choose(icon) } label: {
                    VStack(spacing: 6) {
                        BotIconPortrait(icon)
                        Text(icon.title).font(.caption)
                        if selected == icon { Image(systemName: "checkmark.circle.fill") }
                    }.frame(maxWidth: .infinity)
                }.accessibilityAddTraits(selected == icon ? .isSelected : [])
            }
        }.buttonStyle(.plain)
    }
}
