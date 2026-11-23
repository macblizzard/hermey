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
        state.dismiss()
        onDismiss?()
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
                ClientLog.note("pet \(botID): question failed — \(error.localizedDescription)",
                               category: "pets")
            } catch {
                guard !Task.isCancelled else { return }
                state.fail(PetBalloonState.unreachableText)
                ClientLog.note("pet \(botID): host unreachable — \(error.localizedDescription)",
                               category: "pets")
            }
        }
    }
}

/// The balloon: a field, then thinking, then the answer — or the timeout, or the host's refusal.
///
/// Its own window, floating a point above the pet's, so the pet's window stays icon-sized and the
/// bubble is the only opaque thing on screen.
struct PetBalloonView: View {
    @ObservedObject var model: PetBalloonModel
    let botName: String

    @FocusState private var fieldFocused: Bool
    @State private var copied = false

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let failure = model.state.failure {
                Text(failure)
                    .font(TypeScale.font(Tokens.textSM))
                    .foregroundStyle(model.state.canRetry ? Tokens.textSecondary : Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let answer = model.state.answer {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(answer)
                        .font(TypeScale.font(Tokens.textSM))
                        .foregroundStyle(Tokens.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }

            if model.state.isAsking {
                HStack(spacing: 8) {
                    SpinningRing(color: Tokens.textMuted, size: 11, lineWidth: 1.4)
                    Text("Thinking…")
                        .font(TypeScale.font(Tokens.textSM))
                        .foregroundStyle(Tokens.textMuted)
                }
                .frame(height: 20)
            }

            field
        }
        .padding(14)
        .frame(width: Self.width)
        // Translucent on purpose: the balloon sits over whatever the desktop happens to be — a photo,
        // a dark editor, a bright page — and a solid sheet looks pasted on. The material blurs what is
        // behind it, the theme colour tints it just enough to keep the text readable, and the stroke
        // stays the only hard edge.
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                        .fill(Tokens.sheet.opacity(0.72))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
        // Escape closes the balloon; the window's monitor catches it even while the field has focus.
        .onExitCommand { model.dismiss() }
        .onAppear { fieldFocused = true }
        .onChange(of: model.state) { _, _ in copied = false }
        .onChange(of: model.state.isAsking) { _, asking in
            // The field is the point of the balloon: hand focus back the moment a turn ends.
            if !asking { fieldFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(botName)
                .font(TypeScale.font(Tokens.textSM, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.state.canRetry {
                HermeyButton("Retry", kind: .secondary, size: .small) { model.retry() }
            }
            if let answer = model.state.answer {
                HermeyButton(copied ? "Copied" : "Copy", kind: .secondary, size: .small) {
                    copy(answer)
                }
            }
        }
    }

    private var field: some View {
        TextField("Ask \(botName)…",
                  text: $model.draft,
                  prompt: Text("Ask \(botName)…").foregroundColor(Tokens.textPlaceholder))
            .textFieldStyle(.plain)
            .font(TypeScale.font(Tokens.textSM))
            .foregroundStyle(Tokens.textPrimary)
            .tint(Tokens.accent)
            .focused($fieldFocused)
            .onSubmit { model.send() }
            .disabled(!model.state.acceptsInput)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .fill(Tokens.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                    .strokeBorder(Tokens.borderStrong, lineWidth: 1)
            )
            .accessibilityLabel("Ask \(botName) a question")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}

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
        // The bubble is opaque inside a clear window, so the shadow follows its rounded shape.
        hasShadow = true
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
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
        self.model = model
        self.anchor = anchor
        self.panel = PetBalloonPanel(width: Self.width)
        self.hosting = NSHostingView(rootView: PetBalloonView(model: model, botName: botName))
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
        let pet = PetPlacement(x: anchorFrame.minX, y: anchorFrame.minY, screenID: "")
        let rect = PetGeometry.above(
            pet,
            side: anchorFrame.height,
            balloon: PetRect(x: 0, y: 0, width: panel.frame.width, height: panel.frame.height),
            in: PetRect(x: visible.minX, y: visible.minY,
                        width: visible.width, height: visible.height))
        panel.setFrameOrigin(NSPoint(x: rect.x, y: rect.y))
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
