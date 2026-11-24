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
    /// The bot's own generated avatar, when it has one. The pet draws this instead of the picture,
    /// keeping every bit of its own behaviour — drag, blink, badge, balloon.
    @Published var avatar: BotAvatarDocument?
    /// What the bot is doing, which is the pose the avatar draws.
    @Published var state: OpenBotAvatarState = .idle
    /// False while the panel is occluded (another Space, Mission Control, a full-screen app):
    /// the idle loop sleeps instead of animating a window nobody can see.
    @Published var isVisible = true
    /// Bumped when a question is answered, so the pet does its small "done" hop. A counter rather
    /// than a flag, because every answer deserves one — including two in a row.
    @Published var celebrations = 0
    /// Bumped when the pet itself is clicked. The click is an AppKit event on the panel (so the drag
    /// can move the window with no layout pass); this counter is how that event reaches the view's
    /// own state without the panel knowing anything about SwiftUI.
    @Published var taps = 0
    /// How many of this bot's turns are waiting: `AppModel`'s own count, shown. Zero means no badge
    /// at all, which is the same thing the app's list means by zero.
    @Published private(set) var unread = 0
    /// Bumped when the badge appeared while the owner could not see the window: one hop, the move a
    /// pet already makes for an answer. A counter for the same reason `celebrations` is one — two
    /// replies in a row are two hops, not one.
    @Published private(set) var notices = 0

    /// The answer landed: hop, unless Reduce Motion says otherwise (checked by the view).
    func celebrate() {
        celebrations += 1
    }

    /// The pet was clicked: blink, look, and hop.
    func tap() {
        taps += 1
    }

    /// Take the bot's unread count, and hop once if it grew while the window was away.
    ///
    /// The decision is made by the caller (the controller knows the window; this model does not),
    /// so the two facts are passed together and the count is never applied without one. Returns
    /// true only for the case that hops, which is what the controller logs.
    @discardableResult
    func setUnread(_ count: Int, hopWhenAway: Bool) -> Bool {
        let grew = count > unread
        unread = count
        guard grew, hopWhenAway else { return false }
        notices += 1
        return true
    }

    init(botID: String, botName: String, face: String?, avatar: BotAvatarDocument? = nil) {
        self.botID = botID
        self.botName = botName
        self.face = face
        self.avatar = avatar
    }
}

/// The icon's alpha, in the icon's own top-left coordinates.
///
/// This is the answer to "where is the pet, as opposed to where is its window": the shipped bodies
/// are blobs, wedges and hexes, and the corners of their 96 pt box are empty. A photo face is read
/// from its own pixels, so a transparent PNG is honoured the same way a drawn body is.
struct PetIconMask {
    private let test: (CGPoint) -> Bool
    /// The icon's side, kept so a caller can place something on the icon's own box: the badge's
    /// geometry is in this space, and the hit test has to ask the same question the drawing did.
    let side: CGFloat

    init(identity: String, face: String?, avatar: BotAvatarDocument? = nil, side: CGFloat) {
        self.side = side
        let resolved = BotAvatarIdentity.resolve(identity: identity, explicitColor: face)
        if let avatar, let polygons = try? avatar.definition.polygons(), !polygons.isEmpty {
            // A definition's filled outline is its alpha: the same question the path asks for a
            // drawn shape, asked in the avatar's own 0..100 space.
            let scale = 100 / side
            self.test = { point in
                let p = OpenBotAvatarGeometry.Point(Double(point.x) * Double(scale),
                                                    Double(point.y) * Double(scale))
                return OpenBotAvatarGeometry.contains(polygons, p)
            }
        } else if resolved.isImage,
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

/// The eyes, as fractions of the icon's own side.
///
/// The shipped faces are pictures, so there is no lid to lower: the eyes are drawn *over* the face.
/// Two rounded dark shapes at the upper-middle of the icon — where a cartoon face keeps its eyes —
/// rather than one bar across it, so the pair reads as a face rather than as the picture shrinking.
/// Two jobs, one pair of shapes:
///
/// * **open**, each is a small pupil, and the pair drifts a few points left and right between
///   blinks — which is what makes a still picture look like it is looking around;
/// * **shut**, each thickens into a lid and darkens to `opacity`, over the squashed body, for the
///   length of the blink. That is the difference between blinking and shrinking.
enum PetEyes {
    /// Each eye's width; two of them plus `gap` are the owner's ~55 % of the icon.
    static let width: CGFloat = 0.26
    /// Between the two.
    static let gap: CGFloat = 0.04
    /// How tall one eye is open: a pupil, not a bar.
    static let openHeight: CGFloat = 0.08
    /// How tall it is at the bottom of a blink: enough to cover the shipped face's own eye bars,
    /// which sit at about 37–57 % of the icon's height, so the face reads as closed.
    static let shutHeight: CGFloat = 0.22
    /// Where the band starts, as a fraction of the icon's height from its top (the owner's ~30 %):
    /// the top of the shipped eyes, so a blink closes over them rather than above them.
    static let band: CGFloat = 0.32
    /// How dark the eyes are open, and at the bottom of a blink (the owner's ~0.55).
    static let resting: Double = 0.35
    static let opacity: Double = 0.55
    /// How far the pupils drift from centre, as a fraction of the icon's width: ±3.4 pt at 96 pt.
    static let drift: CGFloat = 0.035
    /// The drift's own clock: a slow look left or right every two to five seconds.
    static let driftCycle: ClosedRange<Double> = 2...5
    /// How long one drift takes.
    static let driftDuration: Double = 0.7
}

/// A blink, drawn as a transform and an overlay on the same picture.
///
/// What reads as a blink at 96 pt is two things at once: the body compressing to four fifths of its
/// height (a visible squash — 0.90 was too shallow to notice), and the pupils thickening into a lid
/// band. The squash alone looks like the picture shrinking; the lids alone float. Together they
/// close.
struct PetBlink: Equatable {
    /// Vertical scale; 1 is open.
    var squash: CGFloat = 1
    /// Added brightness.
    var lift: Double = 0
    /// How shut the eyes are: 0 open, 1 closed. Drives the lids' thickness and their opacity, so
    /// there is one number for "closed" rather than two that can disagree.
    var lid: Double = 0

    static let open = PetBlink()
    /// Four fifths of the height for the length of a blink, with the lids over the eyes.
    static let shut = PetBlink(squash: 0.74, lift: 0.02, lid: 1)
    /// Reduce Motion: shallower, and the lids half as far. A blink is a desktop's smallest bit of
    /// life, so it is gentled rather than removed.
    static let gentle = PetBlink(squash: 0.94, lift: 0, lid: 0.55)

    /// One eyelid's travel, one way: 140 ms down, 140 ms back.
    static let duration: Double = 0.14
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

/// The pet: the bot's own face at 96 pt, its idle motion, its blink, its menu, and its click.
///
/// Dragging and clicking are the panel's (`DesktopPetPanel.sendEvent`): a drag has to move the window
/// on the event's own turn, and a SwiftUI gesture cannot do that without a state update and a layout
/// pass per frame. The view still reacts to the click — `pet.taps` is how the panel's AppKit event
/// reaches this state.
struct PetView: View {
    @ObservedObject var pet: PetModel
    let onClose: () -> Void

    @State private var motion = PetMotion.rest
    /// The blink. Its own state, not part of `PetMotion`: a blink is not a move the pet decides on,
    /// it is what the body does while it sits there.
    @State private var lid = PetBlink.open
    /// Where the pupils are looking: −1 hard left, 0 centre, 1 hard right.
    @State private var gaze: CGFloat = 0

    private let side = CGFloat(PetGeometry.iconSide)

    var body: some View {
        Group {
            if let avatar = pet.avatar {
                // The generated avatar, in the state the bot is in. Its own blinking still runs; the
                // pet's squash and lid overlay are the pet's behaviour and stay on top, as they do
                // for a picture.
                OpenBotAvatarView(definition: avatar.definition,
                                  color: avatar.color,
                                  state: pet.state,
                                  size: side,
                                  animates: pet.isVisible,
                                  label: "\(pet.botName), a desktop pet")
            } else {
                BotAvatarStill(identity: pet.botID, color: pet.face, size: side)
            }
        }
            .frame(width: side, height: side)
            // The unread badge sits on the icon's own box, inside the transforms below: a hop
            // carries it, and the hit test is told the same box (`PetBadge.rect`) so the dot is
            // part of the pet rather than a picture of one.
            .overlay(alignment: .topTrailing) {
                if pet.unread > 0 {
                    PetUnreadBadge(count: pet.unread)
                }
            }
            // It floats. The shadow is drawn inside the clear window's motion ring, under the icon's
            // own alpha — and it is *not* hit area: clicks are decided by `PetIconMask` plus the
            // badge box in `PetHitTestView`, which knows nothing about anything drawn outside both.
            .brightness(lid.lift)
            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 6)
            // No drawn eyes. The shipped faces already have their own — a cloud with two vertical bars
            // — and a second pair drawn over them read as a doubled, T-shaped face (owner, 0.1.631).
            // The looking-around is the *whole icon* drifting a few points instead, which the art
            // carries without anything being drawn on it.
            .scaleEffect(motion.scale)
            .rotationEffect(.degrees(motion.rotation))
            // A slow sideways drift is what makes the face look around: ±3 pt of the whole picture
            // reads as the eyes moving, with nothing drawn over the art.
            .offset(x: gaze * side * PetEyes.drift, y: motion.offset.height)
            // The blink is a vertical squash of the whole body, applied after the move so the two
            // multiply instead of replacing each other.
            .scaleEffect(x: 1, y: lid.squash, anchor: .center)
            .help("\(pet.botName) — click to ask something")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pet.botName), a desktop pet")
            .accessibilityHint("Click to ask this bot a question")
            .accessibilityValue(pet.unread > 0 ? "\(pet.unread) waiting" : "")
            .accessibilityAddTraits(.isButton)
            // The pet takes a drag with the pointer; the menu is the one thing SwiftUI still owns.
            .contextMenu {
                Button("Close pet", role: .destructive) { onClose() }
            }
            // A new id per visibility change restarts the loop when the panel comes back, instead
            // of leaving a cancelled task behind.
            .task(id: pet.isVisible) { await idleLoop() }
            // Blinking has its own clock, and the same rule: an occluded panel's task ends, so no
            // timer runs for a window nobody can see.
            .task(id: pet.isVisible) { await blinkLoop() }
            // The eyes look around on a third clock, slower than the blink and independent of it.
            .task(id: pet.isVisible) { await gazeLoop() }
            // An answer is worth a hop — the one move the pet makes on someone else's cue.
            .onChange(of: pet.celebrations) { _, _ in
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                Task { await play(.hop) }
            }
            // A reply that landed while the window was minimised or hidden: the same hop the pet
            // already makes for an answer, because the same thing happened. It is the only reaction
            // the badge gets — the balloon waits for the click, and nothing pops by itself.
            .onChange(of: pet.notices) { _, _ in
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                Task { await play(.hop) }
            }
            // The click: the panel's AppKit event, as a counter. The balloon opens from the same
            // click, so the reaction plays *while* the bubble appears.
            .onChange(of: pet.taps) { _, _ in beginClickReaction() }
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

    /// One blink, or a run of them: the squash and the lids together, and back.
    ///
    /// `easeInOut` on both halves: the body has to be at its shortest for an instant to read as shut,
    /// and a linear return looks like a bounce. Reduce Motion gets the gentler `PetBlink.gentle`
    /// (0.94, a fainter band) rather than nothing — a desktop that blinks is the point of the
    /// feature, and a square-on transform of two per cent is not what the setting is asking to spare.
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
            try? await Task.sleep(for: .seconds(PetBlink.duration))
        }
    }

    // MARK: - Looking around

    /// Look somewhere new every two to five seconds, for as long as the pet is on screen.
    ///
    /// Under Reduce Motion the eyes stop: a face drifting on its own is exactly the kind of motion
    /// that setting asks not to be given, and the band is still there for the blink.
    @MainActor
    private func gazeLoop() async {
        while !Task.isCancelled, pet.isVisible {
            try? await Task.sleep(for: .seconds(Double.random(in: PetEyes.driftCycle)))
            guard !Task.isCancelled, pet.isVisible else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { continue }
            look(CGFloat.random(in: -1...1))
        }
    }

    @MainActor
    private func look(_ direction: CGFloat) {
        withAnimation(.easeInOut(duration: PetEyes.driftDuration)) {
            gaze = min(max(direction, -1), 1)
        }
    }

    // MARK: - The click

    /// What the pet does when it is clicked: a blink, a look to one side, then a small hop.
    ///
    /// The balloon opens from the same click, on the same runloop turn, so the reaction is something
    /// the pet is doing *while* the bubble appears rather than a delay in front of it. Reduce Motion:
    /// no hop and no look, just the gentle blink.
    @MainActor
    private func beginClickReaction() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task {
            await blink(times: 1)
            guard !Task.isCancelled else { return }
            guard !reduceMotion else { return }
            look(CGFloat.random(in: -1...1))
            withAnimation(.easeOut(duration: 0.16)) {
                motion = PetMotion(offset: CGSize(width: 0, height: -6), scale: 1.03)
            }
            try? await Task.sleep(for: .seconds(0.16))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.28)) { motion = .rest }
        }
    }
}
