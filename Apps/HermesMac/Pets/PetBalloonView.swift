import AppKit
import Combine
import HermesKit
import HermeyUI
import SwiftUI

/// The pet's chat: the thread, the turn in flight, and the one rule that ends a conversation.
///
/// This used to be a single question and a single answer, and a dismissal threw the answer away.
/// The owner's ask replaced that with a small persistent chat: the balloon shows the last few turns,
/// the owner types into it, a click away hides it without losing anything, and a bot message that
/// arrives while it is closed opens it again.
///
/// Three things follow from that and are stated here rather than in the view:
///
/// * **a dismissal is not a cancellation.** The window goes; the turn keeps running, because the
///   answer it produces is what reopens the balloon. Only `New` and the pet going away cancel;
/// * **the thread is the pet's, and it is on disk** (`PetConversationStore`, keyed by bot id), so a
///   relaunch opens the same chat instead of a blank field;
/// * **twenty messages, then `New`.** The cap is `PetConversation.maxMessages`; the field is
///   disabled by `acceptsInput` and the reason is `fullText`, so a full chat cannot be typed into.
///
/// Nothing here logs message text: counts and outcomes only, because a pet's questions are the
/// owner's words.
@MainActor
final class PetBalloonModel: ObservableObject {
    /// The turn in flight. `failed` carries the sentence under the thread: the host's own refusal,
    /// the timeout, or the unreachable line.
    enum Phase: Equatable {
        case idle
        case asking
        case failed(String)
    }

    /// What a full conversation says, beside the greyed field.
    static let fullText = "This chat is full — start a new one."

    @Published private(set) var conversation: PetConversation
    @Published private(set) var phase: Phase = .idle
    @Published var draft = ""

    let botID: String
    /// Escape, a click away, or the pet going away while the balloon is up.
    var onDismiss: (() -> Void)?
    /// A bot message landed. The controller decides whether that means reopening the balloon — the
    /// model does not know whether its window is on screen, and must not try to.
    var onBotMessage: (() -> Void)?

    private let ask: @MainActor (String) async throws -> BotAnswer
    private let store: PetConversationStore
    private var task: Task<Void, Never>?

    init(botID: String,
         store: PetConversationStore? = nil,
         ask: @escaping @MainActor (String) async throws -> BotAnswer) {
        self.botID = botID
        let store = store ?? PetConversationStore(botID: botID)
        self.store = store
        self.conversation = store.load()
        self.ask = ask
    }

    // MARK: - What the view asks

    var isAsking: Bool { phase == .asking }

    /// Whether the composer takes input: no turn in flight, and room for a question **and** its
    /// answer. At the cap this is false and the field draws greyed with `fullText` beside it.
    var acceptsInput: Bool { !isAsking && !conversation.isFull }

    var isFull: Bool { conversation.isFull }

    /// Whether `New` would clear anything. The button is rendered from this and nothing else.
    var canClear: Bool { !conversation.isEmpty }

    /// The sentence under the thread, when the last turn failed.
    var notice: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Retry re-sends the owner's last message, so it is only offered when there is one.
    var canRetry: Bool {
        if case .failed = phase { return conversation.lastOwnerMessage != nil }
        return false
    }

    /// Everything that changes the balloon's height: a message, a turn's state, or the composer
    /// growing a line. A plain keystroke that stays on the same line does not resize the window.
    var layoutChanges: AnyPublisher<Void, Never> {
        Publishers.Merge3(
            $conversation.map { _ in () }.eraseToAnyPublisher(),
            $phase.map { _ in () }.eraseToAnyPublisher(),
            $draft.map { PetCalloutMetrics.composerHeight(for: $0) }
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher()
        )
        .eraseToAnyPublisher()
    }

    // MARK: - Sending

    func send() {
        guard acceptsInput else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard conversation.append(PetMessage(role: .owner, text: question)) else { return }
        draft = ""
        store.save(conversation)
        run(question)
    }

    func retry() {
        guard canRetry, !isAsking, let question = conversation.lastOwnerMessage?.text else { return }
        ClientLog.note("pet \(botID): question retried", category: "pets")
        run(question)
    }

    /// Shift+Return: a newline in the draft rather than a send.
    ///
    /// The key is handled by the window's monitor, which sees it before the text view does; this is
    /// the model half of that, so the rule ("Return sends, Shift+Return breaks the line") is not
    /// spread across a monitor and a view.
    func insertNewline() {
        guard acceptsInput else { return }
        draft += "\n"
    }

    /// Hide the balloon. **Not** a reset and not a cancellation: the thread stays, and a turn in
    /// flight keeps running so its answer can reopen the balloon.
    func dismiss() {
        onDismiss?()
    }

    /// New: a clean conversation, and nothing in flight to paint into it.
    ///
    /// The only thing that empties a thread. The file goes with it, so a relaunch does not bring the
    /// old chat back.
    func clear() {
        cancel()
        conversation.reset()
        phase = .idle
        draft = ""
        store.clear()
        ClientLog.note("pet \(botID): conversation cleared", category: "pets")
    }

    /// Stop the turn without telling the controller anything: used when the pet itself is going
    /// away, where `dismiss()` would call back into the teardown that is already running.
    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - The turn

    private func run(_ question: String) {
        task?.cancel()
        phase = .asking
        ClientLog.note("pet \(botID): question sent", category: "pets")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await ask(question)
                guard !Task.isCancelled else { return }
                guard answer.answered, let reply = answer.reply else {
                    phase = .failed(PetBalloonState.unansweredText)
                    ClientLog.note("pet \(botID): delivered, no answer by the timeout",
                                   category: "pets")
                    return
                }
                conversation.append(PetMessage(role: .bot, text: reply))
                phase = .idle
                store.save(conversation)
                // Characters, never words: the owner's questions are not ours to write down.
                ClientLog.note("pet \(botID): answer arrived (\(reply.count) characters)",
                               category: "pets")
                onBotMessage?()
            } catch is CancellationError {
                // The pet went away before the answer did; nothing to tell anyone.
            } catch let error as BotAskError {
                guard !Task.isCancelled else { return }
                // The host's own sentence, unchanged, or the fixed line for a dead socket.
                phase = .failed(error.localizedDescription)
                ClientLog.note("pet \(botID): question failed — \(error.localizedDescription)",
                               category: "pets")
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(PetBalloonState.unreachableText)
                ClientLog.note("pet \(botID): host unreachable — \(error.localizedDescription)",
                               category: "pets")
            }
        }
    }
}

// MARK: - Where the pet is

/// The pet's centre, as a fraction of the balloon's width (`0` is its left edge, `1` its right).
///
/// The bubble sits above and to the *side* of the icon (`PetCalloutPlacement`), so the pet is
/// almost never under its middle: on the default above-right seat the pet is off the bubble's inner
/// edge entirely. The window writes this on every placement and the tail follows it; the shape clamps
/// it clear of the rounded corners, which is what lands the tail's root on the pet's edge rather than
/// in the bubble's middle.
@MainActor
final class PetBalloonAnchor: ObservableObject {
    @Published var petCentre: CGFloat = 0.5
}

// MARK: - The callout's own ink

/// The balloon's palette, pinned rather than read from `Tokens`.
///
/// The bubble is a solid black callout with white ink. Black is the one fill a bright wallpaper
/// cannot defeat: a material always samples what is behind it, so `.ultraThinMaterial` over a white
/// desktop is a white panel no matter what tint is laid on top. The fill is therefore the app's own
/// dark canvas at 0.97 — the last 3 % is the only thing that keeps it looking like part of the
/// screen rather than a hole in it.
///
/// `Tokens` is still refused for ink: it follows `ThemeRuntime`, so on the app's light theme
/// `textPrimary` would be near-black text on a black bubble. Every value here is spelled out, so the
/// bubble cannot change colour with the app's theme.
enum PetBalloonInk {
    /// The fill: the app's dark canvas (`ThemeCatalog.ink`'s `#0A0A0A`) at 0.97.
    static let body = Color(red: 0.043, green: 0.043, blue: 0.047).opacity(0.97)
    /// The ink. Pure white, because the surface is pure black.
    static let primary = Color.white
    /// Headers, the retry line and anything present but not the thing being read.
    static let secondary = Color.white.opacity(0.72)
    /// The placeholder, the thinking state and the disabled field: still read, never competing.
    static let muted = Color.white.opacity(0.70)
    /// A refusal, on black. Lifted to a light coral: 8:1 against the fill, still a warning.
    static let danger = Color(red: 1.0, green: 0.56, blue: 0.50)          // #FF8F80
    /// The field's caret. White, because a warm accent would be the last of the old palette.
    static let accent = Color.white.opacity(0.90)
    /// The field's well and the bot's bubbles: a white veil, not a theme surface. On black the
    /// relationship is inverted — a control is *lighter* than its card, not darker.
    static let well = Color.white.opacity(0.08)
    /// The owner's own lines: a little brighter than the bot's, so the two sides read apart at a
    /// glance without a second hue on a monochrome card.
    static let ownerBubble = Color.white.opacity(0.16)
    /// The hairline: white at low alpha, faint enough to be a line rather than a border.
    static let edge = Color.white.opacity(0.18)
}

/// The callout's fixed sizes, so the shape and the content agree about how much of the box the tail
/// takes — and about how tall the transcript and the composer may grow before they scroll or clip.
enum PetCalloutMetrics {
    /// How far the tail hangs below the card, root to tip. The content's bottom inset is this plus
    /// its padding.
    static let tailHeight: CGFloat = 13
    /// How wide the tail is where it leaves the card's bottom edge.
    static let tailWidth: CGFloat = 26
    /// How round the tip is: the arc's radius, so the point is soft rather than drawn with a pin.
    static let tailTipRadius: CGFloat = 2.4
    /// How far the tail's side curves are pulled in toward the centre, as a fraction of the root's
    /// half-width.
    static let tailFlare: CGFloat = 0.62
    /// A speech bubble's corner, not a card's: continuous, and generous enough to read as a bubble.
    static let cornerRadius: CGFloat = 26
    /// The bubble's padding, on all four sides; the content is laid out at `answerWidth`.
    static let contentInset: CGFloat = 14
    /// How tall the transcript may grow before it scrolls inside the bubble.
    ///
    /// One number, in points, beside the tail's: two short turns never come near it and the bubble
    /// ends where the thread does; a long chat stops here and scrolls, with the newest line at the
    /// bottom. Written down rather than left flexible because the bubble is sized by `fittingSize`,
    /// and a flexible height measures as nothing — the bug that once hid a long answer entirely.
    static let transcriptCap: CGFloat = 240
    /// The gap between two bubbles.
    static let bubbleSpacing: CGFloat = 6
    /// A bubble's own inset, horizontal and vertical.
    static let bubbleInset: CGFloat = 9
    /// The composer's ceiling, in points, before it stops growing and scrolls its own text.
    static let composerCap: CGFloat = 66

    /// The width the content lays out at: the balloon's width less the inset on each side.
    static var answerWidth: CGFloat { PetBalloonView.width - contentInset * 2 }

    /// The width a bubble's words lay out at. A bubble stops short of the column so the two sides
    /// are visibly two sides — yours on the right, the bot's on the left.
    static var bubbleTextWidth: CGFloat { answerWidth * 0.82 - bubbleInset * 2 }

    /// One bubble's height at `bubbleTextWidth`, measured rather than guessed.
    static func bubbleHeight(of text: String) -> CGFloat {
        measure(text, width: bubbleTextWidth) + bubbleInset * 2
    }

    /// The transcript's height: every clamped bubble plus the gaps, capped.
    static func transcriptHeight(of messages: [PetMessage]) -> CGFloat {
        guard !messages.isEmpty else { return 0 }
        let total = messages.reduce(CGFloat(0)) { partial, message in
            partial + bubbleHeight(of: PetBrevity.clamp(message.text)) + bubbleSpacing
        } - bubbleSpacing
        return min(ceil(total), transcriptCap)
    }

    /// The composer's height at the draft's own line count, measured, between one line and the cap.
    static func composerHeight(for draft: String) -> CGFloat {
        let text = draft.isEmpty ? "A" : draft
        return min(max(measure(text, width: answerWidth - 22) + 12, 28), composerCap)
    }

    /// `Text`'s own height for a string, in the face and size `TypeScale.font` resolves to, laid
    /// into the same width with the same word wrapping. A hidden copy reporting through a
    /// preference would have to be laid out before it could report, which shows as a jump on the
    /// first frame; this runs inside the body's own pass, so the height is decided before the window
    /// is sized.
    private static func measure(_ text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TypeScale.pointSize(Tokens.textSM), weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measured = NSAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: paragraph])
        let bounds = measured.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }
}

// MARK: - The silhouette

/// The balloon's outline: a rounded card with a curved tail hanging off its bottom edge.
///
/// One closed path rather than a card with a tail drawn on top of it: the fill is opaque, so two
/// shapes would double the alpha along the overlap and show as a darker band where the tail meets
/// the body. Corners are quad curves — at this radius they are indistinguishable from arcs.
struct PetBalloonShape: InsettableShape {
    /// The tail's centre, as a fraction of the shape's width. Clamped so the tail never eats a
    /// rounded corner.
    var tailCentre: CGFloat = 0.5
    var tailHeight: CGFloat = PetCalloutMetrics.tailHeight
    var tailWidth: CGFloat = PetCalloutMetrics.tailWidth
    var cornerRadius: CGFloat = PetCalloutMetrics.cornerRadius
    /// The stroke's inset; `strokeBorder` hands it in, the fill leaves it at zero.
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
        // ... along the bottom edge to the tail's root, then the tail itself. Each side is one quad
        // curve whose control point sits *on* the bottom edge, so the curve leaves the card with a
        // horizontal tangent and there is no notch where the tail meets the body. The two sides meet
        // at a small arc rather than a point, so the tip is soft.
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

/// The balloon: a small chat. The last few turns, the turn in flight, the composer, and — when the
/// thread has filled — the sentence that says `New` is the way forward.
///
/// Its own window, floating a point above the pet's, so the pet's window stays icon-sized and the
/// bubble is the only ink on screen. It grows upward from a fixed bottom edge (`PetCalloutPlacement`),
/// which is what lets a conversation grow without moving the thing it is talking about.
struct PetBalloonView: View {
    @ObservedObject var model: PetBalloonModel
    let botName: String
    @ObservedObject var anchor: PetBalloonAnchor
    /// Whether the first frame takes the keyboard. A balloon the owner clicked does; one that
    /// opened itself for a bot's message does not — typing into the middle of his work would be the
    /// rudest thing a desk toy could do.
    let autoFocus: Bool

    @FocusState private var fieldFocused: Bool
    @State private var copied = false

    static let width: CGFloat = 320

    /// The outline, filled and stroked exactly once each: same path, same tail, same fractions.
    private var silhouette: PetBalloonShape {
        PetBalloonShape(tailCentre: anchor.petCentre)
    }

    /// A retryable failure is advice; an unreachable host or a refusal is a warning.
    private var failureInk: Color {
        model.canRetry ? PetBalloonInk.secondary : PetBalloonInk.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !model.conversation.isEmpty {
                transcript
            }

            if let notice = model.notice {
                Text(notice)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(failureInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isAsking {
                HStack(spacing: 8) {
                    SpinningRing(color: PetBalloonInk.muted, size: 11, lineWidth: 1.4)
                    Text("Thinking…")
                        .font(TypeScale.font(Tokens.textSM))
                        .foregroundStyle(PetBalloonInk.muted)
                }
                .frame(height: 20)
            }

            if model.isFull {
                Text(PetBalloonModel.fullText)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(PetBalloonInk.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            composer
        }
        .padding(PetCalloutMetrics.contentInset)
        // The tail hangs below the card, so the content's bottom inset is the padding plus the tail:
        // no line of text ever reaches down into the curve.
        .padding(.bottom, PetCalloutMetrics.tailHeight)
        .frame(width: Self.width)
        // One fill, one silhouette: the card and the tail are the same path, so the black cannot
        // seam where the tail leaves the body.
        .background(silhouette.fill(PetBalloonInk.body))
        .overlay(silhouette.strokeBorder(PetBalloonInk.edge, lineWidth: 1))
        // Dark inside, always: the field's insertion point, scroller and selection are drawn for a
        // dark surface, and on black the inks are pinned so a light theme cannot repaint them.
        .environment(\.colorScheme, .dark)
        // Escape closes the balloon; the window's monitor catches it even while the field has focus.
        .onExitCommand { model.dismiss() }
        .onAppear {
            // A click on the pet is a request to type; a reply arriving is not.
            if autoFocus { fieldFocused = true }
        }
        .onChange(of: model.phase) { _, phase in
            guard autoFocus else { return }
            // The field is the point of the balloon: hand focus back the moment a turn ends.
            if phase != .asking { fieldFocused = true }
        }
        .onChange(of: model.conversation.count) { _, _ in copied = false }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(botName)
                .font(TypeScale.font(Tokens.textSM, weight: .semibold))
                .foregroundStyle(PetBalloonInk.primary)
                .lineLimit(1)

            // Where the cap stands, in the smallest type on the card: eighteen of twenty is the
            // difference between "the field is broken" and "this chat is nearly full".
            Text("\(model.conversation.count)/\(PetConversation.maxMessages)")
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(PetBalloonInk.muted)
                .accessibilityLabel("\(model.conversation.count) of "
                                    + "\(PetConversation.maxMessages) messages")

            Spacer(minLength: 8)

            // Only when there is something to clear: the owner asked for `New` to appear with the
            // exchange, and a button on an empty field is a button that does nothing.
            if model.canClear {
                CalloutButton("New") { model.clear() }
            }
            if model.canRetry {
                CalloutButton("Retry") { model.retry() }
            }
            if let answer = model.conversation.lastBotMessage?.text {
                CalloutButton(copied ? "Copied" : "Copy") {
                    copy(answer)
                }
            }
        }
    }

    // MARK: - The thread

    /// The last turns, newest at the bottom, scrolled inside a height that is *written down*.
    ///
    /// `ScrollView`'s own height is greedy and flexible, and this bubble is sized by `fittingSize`
    /// on the hosting view, so a flexible height measured as (almost) nothing and the thread was
    /// drawn into zero height: present in the model, invisible on screen. `transcriptHeight` is what
    /// gives `fittingSize` a number to add up and the thread a box to scroll inside.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: PetCalloutMetrics.bubbleSpacing) {
                    ForEach(model.conversation.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: PetCalloutMetrics.transcriptHeight(of: model.conversation.messages))
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: model.conversation.count) { _, _ in scrollToEnd(proxy) }
        }
    }

    /// One turn. Yours on the right in a brighter veil, the bot's on the left in the card's own
    /// well; the words are clamped to a pet's length (`PetBrevity`) and the whole answer is on
    /// hover, and in Copy.
    private func bubble(_ message: PetMessage) -> some View {
        let mine = message.role == .owner
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 24) }
            Text(PetBrevity.clamp(message.text))
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(PetBalloonInk.primary)
                .textSelection(.enabled)
                .lineLimit(PetBrevity.lineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PetCalloutMetrics.bubbleInset)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(mine ? PetBalloonInk.ownerBubble : PetBalloonInk.well)
                )
                // The clamp is a display rule, not a deletion: the full answer is under the pointer
                // and in Copy.
                .help(message.text)
                .accessibilityLabel(mine ? "You said: \(message.text)"
                                         : "\(botName) said: \(message.text)")
            if !mine { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = model.conversation.messages.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    // MARK: - The composer

    /// Return sends, Shift+Return breaks the line, and the field grows to three lines before it
    /// scrolls. Both keys are handled by the window's monitor (it sees them before the text view),
    /// so the composer only has to be a text view bound to the draft.
    private var composer: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.draft)
                .font(TypeScale.font(Tokens.textSM))
                .foregroundStyle(PetBalloonInk.primary)
                .tint(PetBalloonInk.accent)
                .scrollContentBackground(.hidden)
                .focused($fieldFocused)
                .hermeyFocusQuiet()
                .disabled(!model.acceptsInput)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(height: PetCalloutMetrics.composerHeight(for: model.draft))

            if model.draft.isEmpty {
                Text("Message \(botName)…")
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(PetBalloonInk.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(PetBalloonInk.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(PetBalloonInk.edge, lineWidth: 1)
        )
        // Greyed when it takes nothing: at the cap, or while a turn is in flight.
        .opacity(model.acceptsInput ? 1 : 0.45)
        .accessibilityLabel("Message \(botName)")
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
/// a light theme it would be a light chip on the black card.
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

/// The balloon's window: clear, floating, and key only when the owner clicked the pet.
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
        // ring, selection and scrollers would be drawn by AppKit for the app's appearance.
        appearance = NSAppearance(named: .darkAqua)
    }

    /// Typing is the balloon's job, and it is only ever asked for by a click on the pet.
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
    /// Whether this appearance takes the keyboard: true for a click on the pet, false for a balloon
    /// that opened itself because the bot wrote something.
    private let autoFocus: Bool
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
    /// `NSWorkspace` posts on its own centre, so its token cannot be removed with the others.
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isClosed = false

    init(model: PetBalloonModel, botName: String, anchor: @escaping () -> NSRect?,
         autoFocus: Bool) {
        let anchorModel = PetBalloonAnchor()
        self.model = model
        self.anchor = anchor
        self.autoFocus = autoFocus
        self.anchorModel = anchorModel
        self.panel = PetBalloonPanel(width: Self.width)
        self.hosting = NSHostingView(rootView: PetBalloonView(model: model,
                                                              botName: botName,
                                                              anchor: anchorModel,
                                                              autoFocus: autoFocus))
        self.hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.onEscape = { [weak model] in model?.dismiss() }
        // The bubble grows and shrinks with its content; its bottom edge stays above the icon.
        // Observed on the conversation, the phase and the composer's height — not on every
        // keystroke, because a keystroke that stays on one line must not resize the window.
        resizeObserver = model.layoutChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.resizeAndPlace() }
            }
    }

    func present(focus: Bool? = nil) {
        guard !isClosed else { return }
        resizeAndPlace()
        panel.orderFrontRegardless()
        // A balloon that opened itself comes forward without becoming key: the owner keeps typing
        // where he was, and this card is something he can read and then click.
        if focus ?? autoFocus {
            panel.makeKey()
            // A non-activating panel may refuse key while another app is in front. The owner
            // clicked the pet, so taking activation here is the explicit click the design allows.
            if !panel.isKeyWindow { NSApp.activate() }
        }
        installMonitors()
        // Text laid out after the first frame can be a point or two taller than the estimate.
        Task { @MainActor in self.resizeAndPlace() }
    }

    /// Close the window. The turn is **not** cancelled by default: a reply that lands while the
    /// balloon is away is what reopens it. The pet going away passes `cancellingTurn: true`.
    func close(cancellingTurn: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        if cancellingTurn { model.cancel() }
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
        let height = min(max(hosting.fittingSize.height, 72), 460)
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

    // MARK: - Keys and dismissal

    private func installMonitors() {
        guard eventMonitors.isEmpty, observers.isEmpty else { return }
        // Escape must work with the field focused, where SwiftUI's `onExitCommand` does not see it;
        // Return and Shift+Return are the composer's two keys, and a local monitor is the one place
        // that sees them before the text view turns them into newlines.
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.model.dismiss()
                    return nil
                }
                if self.panel.isKeyWindow, self.panel.firstResponder is NSTextView,
                   event.keyCode == 36 || event.keyCode == 76 {
                    if event.modifierFlags.contains(.shift) {
                        self.model.insertNewline()
                    } else {
                        self.model.send()
                    }
                    return nil
                }
                return event
            }
            if event.window !== self.panel {
                self.model.dismiss()
                if let window = event.window, self.isOwnerWindow?(window) == true { return nil }
            }
            return event
        }
        if let local { eventMonitors.append(local) }

        // A click in another app cannot be seen by a local monitor; losing key is the notice for a
        // balloon that took the keyboard, and the app going inactive is the notice for one that did
        // not (a balloon that opened itself never became key in the first place).
        let resign = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.dismiss() }
        }
        observers.append(resign)
        let inactive = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.dismiss() }
        }
        observers.append(inactive)

        // A balloon that opened itself never became key, so there is no "lost key" to notice: the
        // owner switching to another app is the click away, and it closes the bubble too.
        let switched = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let front = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard front?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.model.dismiss() }
        }
        workspaceObservers.append(switched)
    }

    private func removeMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }
}
