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

/// A blink, drawn as two transforms on the same picture.
///
/// The shipped faces are pictures, so there is no lid to lower. What reads as a blink at 96 pt is the
/// body compressing for about a tenth of a second, with the faintest lift in brightness — cheap
/// enough to run beside the idle motion, because it is a `scaleEffect` and a `brightness`: no redraw,
/// no second asset, and nothing per frame that SwiftUI is not already doing.
struct PetBlink: Equatable {
    /// Vertical scale; 1 is open.
    var squash: CGFloat = 1
    /// Added brightness.
    var lift: Double = 0

    static let open = PetBlink()
    /// Ten per cent shorter for 110 ms. Deeper than this reads as a squash rather than an eyelid.
    static let shut = PetBlink(squash: 0.90, lift: 0.06)
    /// Reduce Motion: the same blink at half the depth, and no brightness lift at all.
    static let gentle = PetBlink(squash: 0.97, lift: 0)

    /// One eyelid's travel, one way: 110 ms down, 110 ms back.
    static let duration: Double = 0.11
    /// Between the two blinks of a reaction.
    static let gap: Double = 0.07
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
    /// The blink. Its own state, not part of `PetMotion`: a blink is not a move the pet decides on,
    /// it is what the body does while it sits there.
    @State private var lid = PetBlink.open

    private let side = CGFloat(PetGeometry.iconSide)

    var body: some View {
        BotAvatarStill(identity: pet.botID, color: pet.face, size: side)
            .frame(width: side, height: side)
            // It floats. The shadow is drawn inside the clear window's motion ring, under the icon's
            // own alpha — and it is *not* hit area: clicks are decided by `PetIconMask` in
            // `PetHitTestView`, which knows nothing about anything drawn around the ink.
            .brightness(lid.lift)
            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 6)
            .scaleEffect(motion.scale)
            .rotationEffect(.degrees(motion.rotation))
            .offset(motion.offset)
            // The blink is a vertical squash of the whole body, applied after the move so the two
            // multiply instead of replacing each other.
            .scaleEffect(x: 1, y: lid.squash, anchor: .center)
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
            // Blinking has its own clock, and the same rule: an occluded panel's task ends, so no
            // timer runs for a window nobody can see.
            .task(id: pet.isVisible) { await blinkLoop() }
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
                    // The pet answers the click first — a hop and a double blink committed on this
                    // runloop turn — and the balloon opens on the next line. Nothing waits for the
                    // reaction: the two play over each other, which is what makes the click feel
                    // like the pet noticed rather than like a window that took a moment to appear.
                    beginClickReaction()
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

    // MARK: - Blinking

    /// Blink on this pet's own clock, 3–9 s apart, so two pets on one desk never blink in step.
    ///
    /// Same shape as the idle loop, for the same reason: one task per panel, and it ends with the
    /// panel's visibility, so an occluded pet is not running a timer for a window nobody can see.
    @MainActor
    private func blinkLoop() async {
        while !Task.isCancelled, pet.isVisible {
            try? await Task.sleep(for: .seconds(Double.random(in: 3...9)))
            guard !Task.isCancelled, pet.isVisible else { return }
            await blink(times: 1)
        }
    }

    /// One blink, or the two of a reaction, as a squash and back.
    ///
    /// `easeInOut` on both halves: the body has to be at its shortest for an instant to read as shut,
    /// and a linear return looks like a bounce. Reduce Motion gets the gentler `PetBlink.gentle`
    /// (0.97, no lift) rather than nothing — a desktop that blinks is the point of the feature, and a
    /// square-on transform of two per cent is not what the setting is asking to be spared.
    @MainActor
    private func blink(times: Int) async {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shut = reduceMotion ? PetBlink.gentle : PetBlink.shut
        for pass in 0..<max(1, times) {
            if pass > 0 {
                try? await Task.sleep(for: .seconds(PetBlink.gap))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeInOut(duration: PetBlink.duration)) { lid = shut }
            try? await Task.sleep(for: .seconds(PetBlink.duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: PetBlink.duration)) { lid = .open }
        }
    }

    // MARK: - The click

    /// What the pet does when it is clicked: a small hop, committed on the click's own turn, and a
    /// double blink over the top of it. The caller opens the balloon immediately afterwards, so the
    /// reaction is something the pet is doing *while* the bubble appears.
    ///
    /// Reduce Motion: no hop at all, and one gentle blink instead of two — the balloon still opens at
    /// once, because a click has to have a result.
    @MainActor
    private func beginClickReaction() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            withAnimation(.easeOut(duration: 0.16)) {
                motion = PetMotion(offset: CGSize(width: 0, height: -6), scale: 1.03)
            }
        }
        Task {
            await blink(times: reduceMotion ? 1 : 2)
            guard !reduceMotion, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.28)) { motion = .rest }
        }
    }
}
