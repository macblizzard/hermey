import AppKit
import HermesKit
import HermeyUI
import SwiftUI

/// The one piece of state a pet's window reads beside its own motion: the face the store knows for
/// this bot (it can change while the pet is on screen), and whether the panel is visible at all.
@MainActor
final class PetModel: ObservableObject {
    let botID: String
    let botName: String
    @Published var face: String?
    /// False while the panel is occluded (another Space, Mission Control, a full-screen app):
    /// the idle loop sleeps instead of animating a window nobody can see.
    @Published var isVisible = true
    /// Bumped when a question is answered, so the pet does its small "done" hop. A counter rather
    /// than a flag, because every answer deserves one — including two in a row.
    @Published var celebrations = 0

    /// The answer landed: hop, unless Reduce Motion says otherwise (checked by the view).
    func celebrate() {
        celebrations += 1
    }

    init(botID: String, botName: String, face: String?) {
        self.botID = botID
        self.botName = botName
        self.face = face
    }
}

/// The icon's alpha, in the icon's own top-left coordinates.
///
/// This is the answer to "where is the pet, as opposed to where is its window": the shipped bodies
/// are blobs, wedges and hexes, and the corners of their 96 pt box are empty. A photo face is read
/// from its own pixels, so a transparent PNG is honoured the same way a drawn body is.
struct PetIconMask {
    private let test: (CGPoint) -> Bool

    init(identity: String, face: String?, side: CGFloat) {
        let resolved = BotAvatarIdentity.resolve(identity: identity, explicitColor: face)
        if resolved.isImage,
           let data = Self.imageData(face),
           let bitmap = NSBitmapImageRep(data: data) {
            let scale = CGFloat(bitmap.pixelsWide) / max(side, 1)
            let height = bitmap.pixelsHigh
            self.test = { point in
                let x = Int(point.x * scale)
                let y = Int(point.y * scale)
                guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < height else { return false }
                return (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02
            }
        } else {
            // The body is the only opaque ink (the eyes sit inside it), so the path *is* the alpha.
            let path = resolved.shape.path(inSide: side)
            self.test = { path.contains($0) }
        }
    }

    func hasInk(at point: CGPoint) -> Bool { test(point) }

    /// A stored `data:image/...;base64,...` value, decoded — the photo faces `BotAvatarStill`
    /// leaves to the caller.
    private static func imageData(_ raw: String?) -> Data? {
        guard let raw, let comma = raw.firstIndex(of: ","), raw[..<comma].contains("base64") else {
            return nil
        }
        return Data(base64Encoded: String(raw[raw.index(after: comma)...]))
    }
}

/// Transform-only idle motion: the icon never changes art, so a bot with its own face needs no
/// second animation asset.
struct PetMotion: Equatable {
    var offset: CGSize = .zero
    var rotation: Double = 0
    var scale: CGFloat = 1

    static let rest = PetMotion()
}

/// The four things a pet does when left alone. Chosen at random every 8–30 s.
enum PetMove: CaseIterable {
    case bob
    case tilt
    case hop
    case wander

    /// One move, drawn from a bag that favours the quiet ones. Under Reduce Motion only `bob`
    /// survives (a point and a half), because a hop is the loudest thing a desktop can do.
    static func random(reduceMotion: Bool) -> PetMove {
        guard !reduceMotion else { return .bob }
        return [.bob, .bob, .tilt, .tilt, .hop, .wander].randomElement() ?? .bob
    }
}

/// The pet: the bot's own face at 96 pt, its idle motion, its drag, its menu, and its click.
struct PetView: View {
    @ObservedObject var pet: PetModel
    let onOpen: () -> Void
    /// A cumulative drag translation, and whether the finger has lifted (which is when the position
    /// is worth saving).
    let onDrag: (CGSize, Bool) -> Void
    let onClose: () -> Void

    @State private var motion = PetMotion.rest
    @State private var isDragging = false

    private let side = CGFloat(PetGeometry.iconSide)

    var body: some View {
        BotAvatarStill(identity: pet.botID, color: pet.face, size: side)
            .frame(width: side, height: side)
            .scaleEffect(motion.scale)
            .rotationEffect(.degrees(motion.rotation))
            .offset(motion.offset)
            // The gesture is the window's whole surface; the panel's mask decides what reaches it.
            .contentShape(Circle())
            .gesture(dragGesture)
            .contextMenu {
                Button("Close pet", role: .destructive) { onClose() }
            }
            .help("\(pet.botName) — click to ask something")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pet.botName), a desktop pet")
            .accessibilityHint("Click to ask this bot a question")
            .accessibilityAddTraits(.isButton)
            // A new id per visibility change restarts the loop when the panel comes back, instead
            // of leaving a cancelled task behind.
            .task(id: pet.isVisible) { await idleLoop() }
            // An answer is worth a hop — the one move the pet makes on someone else's cue.
            .onChange(of: pet.celebrations) { _, _ in
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                Task { await play(.hop) }
            }
    }

    // MARK: - Interaction

    /// `minimumDistance: 0` so a plain click and a drag are told apart by the distance moved, not by
    /// which recogniser won: a click opens the balloon, and anything past two points is a drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging,
                   abs(value.translation.width) + abs(value.translation.height) > 2 {
                    isDragging = true
                }
                if isDragging { onDrag(value.translation, false) }
            }
            .onEnded { value in
                if isDragging {
                    onDrag(value.translation, true)
                } else {
                    onOpen()
                }
                isDragging = false
            }
    }

    // MARK: - Idle motion

    /// Sleep for a random interval, do one move, repeat — for as long as the pet is on screen.
    ///
    /// Each pet has its own loop (one task per panel), so a stuck pet cannot freeze the others, and
    /// an occluded panel's task ends rather than animating an invisible window.
    @MainActor
    private func idleLoop() async {
        while !Task.isCancelled, pet.isVisible {
            let wait = Double.random(in: 8...30)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, pet.isVisible else { return }
            await play(PetMove.random(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        }
    }

    @MainActor
    private func play(_ move: PetMove) async {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target: PetMotion
        switch move {
        case .bob:
            target = PetMotion(offset: CGSize(width: 0, height: reduceMotion ? -1.5 : -3))
        case .tilt:
            target = PetMotion(rotation: 5)
        case .hop:
            target = PetMotion(offset: CGSize(width: 0, height: -9), scale: 1.04)
        case .wander:
            let dx = CGFloat.random(in: -8...8)
            let dy = CGFloat.random(in: -5...5)
            target = PetMotion(offset: CGSize(width: dx, height: dy))
        }

        withAnimation(.easeInOut(duration: reduceMotion ? 0.6 : 0.28)) { motion = target }
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.7 : 0.32))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.42)) { motion = .rest }
    }
}
