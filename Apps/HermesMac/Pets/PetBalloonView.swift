import AppKit
import Combine
import HermesKit
import HermeyUI
import SwiftUI

/// The balloon's model: one question in flight at a time, and the state the design drew.
///
/// The transitions themselves are `PetBalloonState` (HermesKit, unit-tested); this type owns the
/// task, the log lines the owner reports bugs from, and the mapping from a thrown error to the
/// sentence in the bubble.
///
/// It also owns something the first version got wrong: **the conversation outlives the window**. A
/// dismissal is not a reset — the pet keeps its last answer for as long as the pet is on screen
/// (memory only; nothing is written to disk, because a desktop pet's transcript is not a document),
/// so reopening the balloon shows what was last asked instead of a blank field. The one thing a
/// dismissal *does* throw away is a turn that had not landed yet: nothing answered it, so there is
/// nothing to show. `New` is the explicit reset, and the only one.
@MainActor
final class PetBalloonModel: ObservableObject {
    @Published private(set) var state: PetBalloonState = .idle
    @Published var draft = ""

    let botID: String
    /// Escape, a click away, or the pet going away while the balloon is up.
    var onDismiss: (() -> Void)?
    /// The answer landed — the pet's cue to look pleased with itself.
    var onAnswer: (() -> Void)?

    private let ask: @MainActor (String) async throws -> BotAnswer
    private var task: Task<Void, Never>?
    /// The last exchange that settled — an answer, or a failure. Kept so a dismissal during a turn,
    /// or a reopening, has something to go back to.
    private var kept: PetBalloonState?

    /// Whether there is anything on screen for `New` to clear: an answer, or a failure. The button
    /// is rendered from this and nothing else, so it appears exactly when it would do something.
    var hasExchange: Bool { state.answer != nil || state.failure != nil }

    init(botID: String, ask: @escaping @MainActor (String) async throws -> BotAnswer) {
        self.botID = botID
        self.ask = ask
    }

    /// Each transition, and nothing else: the window re-fits on this, not on every keystroke in the
    /// field (`objectWillChange` would fire for the draft too).
    var stateChanges: AnyPublisher<PetBalloonState, Never> {
        $state.eraseToAnyPublisher()
    }

    func send() {
        guard state.ask(draft), let question = state.question else { return }
        draft = ""
        ClientLog.note("pet \(botID): question sent", category: "pets")
        run(question)
    }

    func retry() {
        guard state.retry(), let question = state.question else { return }
        ClientLog.note("pet \(botID): question retried", category: "pets")
        run(question)
    }

    func dismiss() {
        cancel()
        // A turn that has not landed has nothing to keep; the exchange before it is still this
        // pet's answer, so that is what the next open shows.
        if state.isAsking { state = kept ?? .idle }
        onDismiss?()
    }

    /// New: an empty field ready for a fresh question.
    ///
    /// The explicit reset — it clears what is on screen *and* anything in flight, because a reply
    /// that lands after the owner asked to start over must not paint itself into the new bubble. The
    /// window closes nothing here: the balloon stays up, empty, with the field focused.
    func clear() {
        cancel()
        state.dismiss()
        kept = nil
        draft = ""
        ClientLog.note("pet \(botID): cleared for a new question", category: "pets")
    }

    /// Cancel the turn without telling the controller anything: used when the window itself is
    /// going away, where `dismiss()` would call back into the teardown that is already running.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(_ question: String) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await ask(question)
                guard !Task.isCancelled else { return }
                state.receive(reply: answer.answered ? answer.reply : nil)
                // Settled: this is now the exchange the pet keeps, whatever it says on the screen.
                kept = state
                if let reply = state.answer {
                    ClientLog.note("pet \(botID): answer arrived (\(reply.count) characters)",
                                   category: "pets")
                    onAnswer?()
                } else {
                    ClientLog.note("pet \(botID): delivered, no answer by the timeout", category: "pets")
                }
            } catch is CancellationError {
                // The balloon went away before the answer did; nothing to tell anyone.
            } catch let error as BotAskError {
                guard !Task.isCancelled else { return }
                // The host's own sentence, unchanged, or the fixed line for a dead socket.
                state.fail(error.localizedDescription)
                kept = state
                ClientLog.note("pet \(botID): question failed — \(error.localizedDescription)",
                               category: "pets")
            } catch {
                guard !Task.isCancelled else { return }
                state.fail(PetBalloonState.unreachableText)
                kept = state
                ClientLog.note("pet \(botID): host unreachable — \(error.localizedDescription)",
                               category: "pets")
            }
        }
    }
}

// MARK: - Where the pet is

/// The pet's centre, as a fraction of the balloon's width (`0` is its left edge, `1` its right).
///
/// The bubble now sits above and to the *side* of the icon (`PetCalloutPlacement`), so the pet is
/// almost never under its middle: on the default above-right seat the pet is off the bubble's inner
/// edge entirely. The window writes this on every placement and the tail follows it; the shape clamps
/// it clear of the rounded corners, which is what lands the tail's root on the pet's edge rather than
/// in the bubble's middle. It is the difference between a callout that points at the pet and one that
/// merely hovers near it.
@MainActor
final class PetBalloonAnchor: ObservableObject {
    @Published var petCentre: CGFloat = 0.5
}

// MARK: - The callout's own ink

/// The balloon's palette, pinned rather than read from `Tokens`.
///
/// The bubble is a solid black callout with white ink. The owner ran it both ways: frosted glass
/// first, and now the reverse — **full black, white text**. Black is the one fill a bright wallpaper
/// cannot defeat: a material always samples what is behind it, so `.ultraThinMaterial` over a white
/// desktop is a white panel no matter what tint is laid on top. The fill is therefore the app's own
/// dark canvas at 0.97 — the last 3 % is the only thing that keeps it looking like part of the
/// screen rather than a hole in it — and a bright wallpaper moves it by about one step in
/// luminance (composited over white it lands near #121212).
///
/// `Tokens` is still refused: it follows `ThemeRuntime`, so on the app's light theme `textPrimary`
/// would be near-black text on a black bubble. Every value here is spelled out, so the bubble cannot
/// change colour with the app's theme.
enum PetBalloonInk {
    /// The fill: the app's dark canvas (`ThemeCatalog.ink`'s `#0A0A0A`) at 0.97, so it reads as
    /// solid black over a bright wallpaper and still catches a hint of a dark one.
    static let body = Color(red: 0.043, green: 0.043, blue: 0.047).opacity(0.97)
    /// The ink. Pure white, because the surface is pure black and there is nothing to warm it
    /// against — the old `#141413` parchment ink was for paper.
    static let primary = Color.white
    /// Headers, the retry line and anything that is present but not the thing being read.
    static let secondary = Color.white.opacity(0.72)
    /// The placeholder, the thinking state and the disabled field: still read, never competing.
    static let muted = Color.white.opacity(0.70)
    /// A refusal, on black. The old `#B3392B` was picked for paper and is nearly invisible here, so
    /// it is lifted to a light coral: 8:1 against the fill, still unmistakably a warning.
    static let danger = Color(red: 1.0, green: 0.56, blue: 0.50)          // #FF8F80
    /// The field's caret. A warm accent would be the last of the old palette, so it is white.
    static let accent = Color.white.opacity(0.90)
    /// The field's well and the button chips: a white veil, not a theme surface. On black the
    /// relationship is inverted — a control is *lighter* than its card, not darker.
    static let well = Color.white.opacity(0.08)
    /// The hairline: white at low alpha, faint enough to be a line rather than a border. On a bright
    /// desktop the black fill holds the silhouette; on a black one this does.
    static let edge = Color.white.opacity(0.18)
}

/// The callout's fixed sizes, so the shape and the content agree about how much of the box the tail
/// takes — and about how tall the answer may grow before it scrolls.
enum PetCalloutMetrics {
    /// How far the tail hangs below the card, root to tip. The content's bottom inset is this plus
    /// its padding.
    static let tailHeight: CGFloat = 13
    /// How wide the tail is where it leaves the card's bottom edge.
    static let tailWidth: CGFloat = 26
    /// How round the tip is: the arc's radius, so the point is soft rather than drawn with a pin.
    static let tailTipRadius: CGFloat = 2.4
    /// How far the tail's side curves are pulled in toward the centre, as a fraction of the root's
    /// half-width. The control point sits on the bottom edge, which is what makes the tail leave the
    /// card horizontally instead of in a notch.
    static let tailFlare: CGFloat = 0.62
    /// A speech bubble's corner, not a card's: continuous, and generous enough that the outline
    /// reads as a bubble at a glance.
    static let cornerRadius: CGFloat = 26
    /// The bubble's padding, on all four sides; the answer is laid out at `answerWidth`.
    static let contentInset: CGFloat = 14
    /// The most the answer may draw before it scrolls inside the bubble instead of growing it.
    ///
    /// One number, in points, beside the tail's: a two-line reply never comes near it and the bubble
    /// ends where the text does; a thirty-line reply stops here and scrolls.
    static let answerCap: CGFloat = 240
    /// The width the answer's `Text` lays out at: the balloon's width less the inset on each side.
    static var answerWidth: CGFloat { PetBalloonView.width - contentInset * 2 }

    /// How tall the answer's own `Text` is at `answerWidth` — measured, not estimated.
    ///
    /// The same face at the same hinted size `TypeScale.font` resolves to (the system font at
    /// `TypeScale.pointSize`, so a ⌘+/⌘- step is measured too), laid into the same width with the
    /// same word wrapping. A hidden copy of the `Text` reporting its height through a preference
    /// would be the other way, and it has to be laid out before it can report: the window would size
    /// itself to the uncapped answer for a frame and then snap down to the cap, a visible jump on
    /// every long reply. This runs in the body's own pass, so the branch is decided before the
    /// bubble is first sized.
    static func answerHeight(of answer: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TypeScale.pointSize(Tokens.textSM), weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measured = NSAttributedString(
            string: answer,
            attributes: [.font: font, .paragraphStyle: paragraph])
        let bounds = measured.boundingRect(
            with: NSSize(width: answerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }
}

// MARK: - The silhouette

/// The balloon's outline: a rounded card with a curved tail hanging off its bottom edge.
///
/// One closed path rather than a card with a tail drawn on top of it: the fill is opaque, so two
/// shapes would double the alpha along the overlap and show as a darker band where the tail meets
/// the body. The tail is part of the outline, so there is also no second subpath whose winding could
/// cut a hole in the body. Corners are
/// quad curves — at this radius they are indistinguishable from arcs and there is no angle convention
/// to get wrong.
struct PetBalloonShape: InsettableShape {
    /// The tail's centre, as a fraction of the shape's width. Clamped so the tail never eats a
    /// rounded corner.
    var tailCentre: CGFloat = 0.5
    var tailHeight: CGFloat = PetCalloutMetrics.tailHeight
    var tailWidth: CGFloat = PetCalloutMetrics.tailWidth
    var cornerRadius: CGFloat = PetCalloutMetrics.cornerRadius
    /// The stroke's inset; `strokeBorder` hands it in, the fill leaves it at zero. Named apart from
    /// `inset(by:)` so the property and the protocol's method cannot be mistaken for each other.
    var strokeInset: CGFloat = 0

    func inset(by amount: CGFloat) -> PetBalloonShape {
        var copy = self
        copy.strokeInset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: strokeInset, dy: strokeInset)
        guard box.width > 0, box.height > 0 else { return Path() }

        let radius = max(0, min(cornerRadius - strokeInset, min(box.width, box.height) / 2))
        let tail = max(0, min(tailHeight - strokeInset, box.height - radius * 2))
        // The card's bottom edge; everything below it is the tail.
        let bottom = box.maxY - tail
        let half = max(0, min(tailWidth, box.width - radius * 2)) / 2
        let centre = min(max(box.minX + box.width * tailCentre, box.minX + radius + half),
                         box.maxX - radius - half)
        // The tip is an arc, so it needs a radius smaller than the tail's own half-width.
        let tipRadius = min(PetCalloutMetrics.tailTipRadius, half * 0.4)
        let rootRight = centre + half
        let rootLeft = centre - half

        var path = Path()
        path.move(to: CGPoint(x: box.minX + radius, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - radius, y: box.minY))
        path.addQuadCurve(to: CGPoint(x: box.maxX, y: box.minY + radius),
                          control: CGPoint(x: box.maxX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: box.maxX - radius, y: bottom),
                          control: CGPoint(x: box.maxX, y: bottom))
        // ... along the bottom edge to the tail's root, then the tail itself, which is the reason
        // this is a bubble and not a rounded rectangle. Each side is one quad curve whose control
        // point sits *on* the bottom edge: the curve therefore leaves the card with a horizontal
        // tangent and there is no notch where the tail meets the body. The two sides meet at a small
        // arc rather than a point, so the tip is soft.
        path.addLine(to: CGPoint(x: rootRight, y: bottom))
        path.addQuadCurve(to: CGPoint(x: centre + tipRadius, y: box.maxY - tipRadius),
                          control: CGPoint(x: rootRight - half * PetCalloutMetrics.tailFlare,
                                           y: bottom))
        path.addQuadCurve(to: CGPoint(x: centre - tipRadius, y: box.maxY - tipRadius),
                          control: CGPoint(x: centre, y: box.maxY))
        path.addQuadCurve(to: CGPoint(x: rootLeft, y: bottom),
                          control: CGPoint(x: rootLeft + half * PetCalloutMetrics.tailFlare,
                                           y: bottom))
        path.addLine(to: CGPoint(x: box.minX + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: box.minX, y: bottom - radius),
                          control: CGPoint(x: box.minX, y: bottom))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + radius))
        path.addQuadCurve(to: CGPoint(x: box.minX + radius, y: box.minY),
                          control: CGPoint(x: box.minX, y: box.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - The balloon

/// The balloon: a field, then thinking, then the answer — or the timeout, or the host's refusal.
///
/// Its own window, floating a point above the pet's, so the pet's window stays icon-sized and the
/// bubble is the only ink on screen.
struct PetBalloonView: View {
    @ObservedObject var model: PetBalloonModel
    let botName: String
    @ObservedObject var anchor: PetBalloonAnchor

    @FocusState private var fieldFocused: Bool
    @State private var copied = false

    static let width: CGFloat = 320

    /// The outline, filled and stroked exactly once each: same path, same tail, same fractions.
    private var silhouette: PetBalloonShape {
        PetBalloonShape(tailCentre: anchor.petCentre)
    }

    /// A retryable failure is advice; an unreachable host or a refusal is a warning.
    private var failureInk: Color {
        model.state.canRetry ? PetBalloonInk.secondary : PetBalloonInk.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let failure = model.state.failure {
                Text(failure)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(failureInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let answer = model.state.answer {
                answerBody(answer)
            }

            if model.state.isAsking {
                HStack(spacing: 8) {
                    SpinningRing(color: PetBalloonInk.muted, size: 11, lineWidth: 1.4)
                    Text("Thinking…")
                        .font(TypeScale.font(Tokens.textSM))
                        .foregroundStyle(PetBalloonInk.muted)
                }
                .frame(height: 20)
            }

            field
        }
        .padding(PetCalloutMetrics.contentInset)
        // The tail hangs below the card, so the content's bottom inset is the padding plus the tail:
        // no line of text ever reaches down into the curve.
        .padding(.bottom, PetCalloutMetrics.tailHeight)
        .frame(width: Self.width)
        // One fill, one silhouette: the card and the tail are the same path, so the black cannot
        // seam where the tail leaves the body. No material under the colour — a material samples
        // what is behind the window, and `.ultraThinMaterial` over a bright desktop is a light
        // panel that a near-black veil only greys. A flat fill is the only thing that reads black
        // on a bright wallpaper; 0.97 keeps a hint of the desktop at the rim.
        .background(silhouette.fill(PetBalloonInk.body))
        .overlay(
            // The hairline: a faint white border. It is the whole edge now - there is no second,
            // brighter rim to catch the light, because on black that rim would read as a bevel.
            silhouette.strokeBorder(PetBalloonInk.edge, lineWidth: 1)
        )
        // Dark inside, always. The bubble is black, so the field's insertion point, scroller and
        // selection have to be drawn for a dark surface: in the light appearance the selection
        // highlight is a pale blue that white ink disappears into, which is the one legibility
        // failure a black bubble could still have. The inks above are pinned as well, so a light
        // theme cannot put near-black text on it even if this environment were lost.
        .environment(\.colorScheme, .dark)
        // Escape closes the balloon; the window's monitor catches it even while the field has focus.
        .onExitCommand { model.dismiss() }
        .onAppear { fieldFocused = true }
        .onChange(of: model.state) { _, _ in copied = false }
        .onChange(of: model.state.isAsking) { _, asking in
            // The field is the point of the balloon: hand focus back the moment a turn ends.
            if !asking { fieldFocused = true }
        }
    }

    /// The answer, at one of two sizes, chosen by measurement rather than by counting characters.
    ///
    /// Under the cap it is exactly the self-sizing `Text` it always was: the bubble grows with the
    /// words and ends where the last line does. Over the cap it scrolls, inside a height that is
    /// *written down* — `ScrollView`'s own height is greedy and flexible, and this bubble is sized by
    /// `fittingSize` on the hosting view, so a flexible height measured as (almost) nothing and the
    /// answer was drawn into zero height: present in the model, copyable by Copy, invisible on
    /// screen. The explicit height is what gives `fittingSize` a number to add up and the answer a
    /// box to scroll inside.
    @ViewBuilder
    private func answerBody(_ answer: String) -> some View {
        if PetCalloutMetrics.answerHeight(of: answer) > PetCalloutMetrics.answerCap {
            ScrollView(.vertical, showsIndicators: true) {
                answerText(answer)
            }
            .frame(height: PetCalloutMetrics.answerCap)
            .frame(maxWidth: .infinity)
        } else {
            answerText(answer)
        }
    }

    /// The answer's words — the same in both branches, so a short reply and a long one read the
    /// same way: selectable, left-aligned, the bubble's full width.
    ///
    /// Legibility on black comes from the fill and the appearance, not from anything drawn over the
    /// glyphs: the surface is 0.97 black, so white clears 17:1, and the dark appearance gives the
    /// selection a deep blue highlight that the white ink still reads on (a light-appearance
    /// selection would be pale blue — white on it, and the answer would vanish exactly while the
    /// owner is copying it). The old black text shadow existed to darken a light frost behind the
    /// words; on a black card it would only smear them.
    private func answerText(_ answer: String) -> some View {
        Text(answer)
            .font(TypeScale.font(Tokens.textSM))
            .foregroundStyle(PetBalloonInk.primary)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(botName)
                .font(TypeScale.font(Tokens.textSM, weight: .semibold))
                .foregroundStyle(PetBalloonInk.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Only when there is something to clear: an answer, or a failure. A `New` beside an
            // empty field would be a button that does nothing, and the owner asked for it to appear
            // with the exchange.
            if model.hasExchange {
                CalloutButton("New") { model.clear() }
            }
            if model.state.canRetry {
                CalloutButton("Retry") { model.retry() }
            }
            if let answer = model.state.answer {
                CalloutButton(copied ? "Copied" : "Copy") {
                    copy(answer)
                }
            }
        }
    }

    private var field: some View {
        TextField("Ask \(botName)…",
                  text: $model.draft,
                  prompt: Text("Ask \(botName)…").foregroundColor(PetBalloonInk.muted))
            .textFieldStyle(.plain)
            .font(TypeScale.font(Tokens.textSM))
            .foregroundStyle(PetBalloonInk.primary)
            .tint(PetBalloonInk.accent)
            .focused($fieldFocused)
            .onSubmit { model.send() }
            .disabled(!model.state.acceptsInput)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .fill(PetBalloonInk.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .strokeBorder(PetBalloonInk.edge, lineWidth: 1)
            )
            .accessibilityLabel("Ask \(botName) a question")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

/// The balloon's small buttons, in the balloon's own inks.
///
/// The same labels, the same actions and the same height as the `HermeyButton`s they replace — but
/// `HermeyButton` paints from `Tokens`, which follow the app's theme rather than this window's, so on
/// a light theme it would be a light chip on the black card: the one part of the bubble still dressed
/// for a different surface.
private struct CalloutButton: View {
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(TypeScale.font(Tokens.textSM, weight: .semibold))
                .foregroundStyle(PetBalloonInk.primary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(PetBalloonInk.well)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .strokeBorder(PetBalloonInk.edge, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .hermeyFocusQuiet()
    }
}

// MARK: - The window

/// The balloon's window: clear, floating, and key only because the owner clicked the pet.
final class PetBalloonPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The bubble's own outline is the only ink, so the window's shadow follows its rounded
        // shape and the tail rather than a rectangle.
        hasShadow = true
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Black card inside a light or dark app: without this the field's insertion point, focus
        // ring, selection and scrollers would be drawn by AppKit for the app's appearance, and a
        // light appearance puts pale-blue selection behind white text.
        appearance = NSAppearance(named: .darkAqua)
    }

    /// Typing is the balloon's whole job, and it is only ever asked for by a click on the pet.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Owns the balloon panel, keeps it above its pet, and closes it on Escape or a click elsewhere.
@MainActor
final class PetBalloonWindow {
    static let width = PetBalloonView.width

    let model: PetBalloonModel

    private let panel: PetBalloonPanel
    private let hosting: NSHostingView<PetBalloonView>
    private let anchor: () -> NSRect?
    /// Where the pet is under the bubble, so the tail points at it after the bubble has been nudged
    /// back onto the display.
    private let anchorModel: PetBalloonAnchor
    /// Whether a window is *this* pet's, so a click on the pet that owns the balloon is a dismissal
    /// that the pet's own tap does not immediately undo — while a click on another pet still reaches
    /// it and opens that pet's balloon.
    var isOwnerWindow: ((NSWindow) -> Bool)?
    var onClose: (() -> Void)?

    private var resizeObserver: AnyCancellable?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var isClosed = false

    init(model: PetBalloonModel, botName: String, anchor: @escaping () -> NSRect?) {
        let anchorModel = PetBalloonAnchor()
        self.model = model
        self.anchor = anchor
        self.anchorModel = anchorModel
        self.panel = PetBalloonPanel(width: Self.width)
        self.hosting = NSHostingView(rootView: PetBalloonView(model: model,
                                                              botName: botName,
                                                              anchor: anchorModel))
        self.hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.onEscape = { [weak model] in model?.dismiss() }
        // The bubble grows and shrinks with its state; its bottom edge stays above the icon. Observed
        // on the state, not on the model: a keystroke in the field must not resize the window.
        resizeObserver = model.stateChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.resizeAndPlace() }
            }
    }

    func present() {
        guard !isClosed else { return }
        resizeAndPlace()
        panel.orderFrontRegardless()
        panel.makeKey()
        // A non-activating panel may refuse key while another app is in front. The owner clicked the
        // pet, so taking activation here is the explicit click the design allows.
        if !panel.isKeyWindow { NSApp.activate() }
        installMonitors()
        // Text laid out after the first frame can be a point or two taller than the estimate.
        Task { @MainActor in self.resizeAndPlace() }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // The question goes with the window: a cancelled turn must not paint a bubble nobody opened.
        model.cancel()
        removeMonitors()
        resizeObserver?.cancel()
        resizeObserver = nil
        panel.orderOut(nil)
        panel.close()
        onClose?()
    }

    // MARK: - Geometry

    private func resizeAndPlace() {
        guard !isClosed else { return }
        hosting.layoutSubtreeIfNeeded()
        let height = min(max(hosting.fittingSize.height, 72), 420)
        panel.setContentSize(NSSize(width: Self.width, height: height))
        place()
    }

    private func place() {
        guard let anchorFrame = anchor(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        else { return }
        let visible = screen.visibleFrame
        let petRect = PetRect(x: anchorFrame.minX, y: anchorFrame.minY,
                              width: anchorFrame.width, height: anchorFrame.height)
        let placed = PetCalloutPlacement.place(
            pet: petRect,
            balloon: PetRect(x: 0, y: 0, width: panel.frame.width, height: panel.frame.height),
            in: PetRect(x: visible.minX, y: visible.minY,
                        width: visible.width, height: visible.height))
        panel.setFrameOrigin(NSPoint(x: placed.rect.x, y: placed.rect.y))
        // The tail points at the pet, wherever the bubble ended up: the shape clamps this fraction
        // clear of its own corners, so on a side seat the tail's root lands on the pet's edge.
        let fraction = PetCalloutPlacement.tailFraction(pet: petRect, balloon: placed.rect)
        anchorModel.petCentre = CGFloat(fraction)
    }

    // MARK: - Dismissal

    private func installMonitors() {
        guard eventMonitors.isEmpty, observers.isEmpty else { return }
        // Escape must work with the field focused, where SwiftUI's `onExitCommand` does not see it.
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.model.dismiss()
                return nil
            }
            if event.window !== self.panel {
                self.model.dismiss()
                if let window = event.window, self.isOwnerWindow?(window) == true { return nil }
            }
            return event
        }
        if let local { eventMonitors.append(local) }

        // A click in another app cannot be seen by a local monitor; losing key is the notice.
        let resign = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.dismiss() }
        }
        observers.append(resign)
    }

    private func removeMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
