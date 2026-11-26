import SwiftUI

/// A group chat's members as one portrait: up to three faces, each tucked under the one before it.
///
/// **The plate follows the face that is actually drawn.** Between two overlapping faces there is a
/// plate — a stroke in the page colour — whose job is to separate them, not to decorate them. It was
/// drawn as a `Circle` behind every face, unconditionally, and that only reads as a plate behind the
/// **shape** face, whose body *is* a circle: there the ring sits exactly on the silhouette. A bot
/// with a generated avatar draws its own silhouette instead — ears, a square, a wide body — and a
/// circle behind one is a second, wrong outline with gaps between it and the drawing, which is the
/// circle the owner photographed on 2026-11-24.
///
/// So the plate is asked of the drawn thing: a shape face keeps exactly the ring it has today
/// (1.5 pt, page colour), a drawn avatar gets none at all and is separated by its own outline. The
/// overlap order, the spacing and the crop are untouched — only the plate is conditional.
///
/// ```swift
/// StackedBotFaces(faces: room.members.prefix(3).map {
///                     StackedBotFaces.Face(id: $0.profile, color: icons[$0.profile]?.raw)
///                 },
///                 size: 30,
///                 spacing: -8)
/// ```
public struct StackedBotFaces: View {
    /// One member of the stack: the bot's id, and the stored `bots.color` the host has for it.
    public struct Face: Identifiable, Hashable {
        public let id: String
        public let color: String?

        public init(id: String, color: String? = nil) {
            self.id = id
            self.color = color
        }
    }

    private let faces: [Face]
    private let size: CGFloat
    private let spacing: CGFloat

    /// The same library `BotAvatarView` resolves through, read here to answer one question the face
    /// cannot be asked from the outside: is this bot drawn from a definition, or from a shape?
    @Environment(\.botAvatars) private var avatars

    public init(faces: [Face], size: CGFloat, spacing: CGFloat) {
        self.faces = faces
        self.size = size
        self.spacing = spacing
    }

    public var body: some View {
        HStack(spacing: spacing) {
            ForEach(faces) { face in
                BotAvatarView(identity: face.id,
                              color: face.color,
                              activity: .idle,
                              size: size,
                              animates: false)
                    .overlay { plate(for: face.id) }
            }
        }
        .fixedSize()
    }

    /// The plate behind one face — or nothing, when the face brings its own outline.
    ///
    /// A generated avatar is not a circle, so a circular plate behind it is a second silhouette: the
    /// dark ring with gaps the owner saw around a cat and a square. The shape face is round and keeps
    /// today's ring unchanged.
    @ViewBuilder
    private func plate(for identity: String) -> some View {
        if avatars[identity] == nil {
            Circle()
                .stroke(Tokens.canvas, lineWidth: 1.5)
        }
    }
}
