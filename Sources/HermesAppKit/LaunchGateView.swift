#if canImport(SwiftUI) && canImport(Combine)
import HermesKit
import SwiftUI

/// The launch gate: the app's own UI with the launch screen laid over it, until the app is usable.
///
/// One decision, drawn once, for both shells. The gate owns a `LaunchReadiness` — the state machine
/// that answers "is the app usable yet?" — and nothing else decides whether the launch screen is
/// visible. It is not a sheet, not a `ProgressView`, and not a route: whatever the shell draws is
/// behind it from the first frame, so the fade uncovers a screen that has already painted rather
/// than one that starts loading when the splash leaves.
///
/// ```swift
/// // Apps/HermesMobile/HermesMobileApp.swift
/// LaunchGateView(model: app.model, isPaired: { app.isPaired }) {
///     BootScreen()
/// } content: {
///     RootView()
/// }
/// ```
///
/// ## Why it polls
///
/// The deadline is the one signal the app cannot publish: nothing changes in `AppModel` when a host
/// simply never answers, so a purely event-driven gate would sit on the splash forever — the exact
/// trap the deadline exists to prevent. The gate re-evaluates on a 30 Hz beat *only while it is
/// waiting*, and only writes when the phase actually changes, so a waiting launch costs a handful of
/// boolean reads and no redraws. Once the phase is terminal the loop ends and the gate never reads
/// the model again.
///
/// ## What it hands off to
///
/// `ready` fades the launch screen out over `fadeOut` seconds — the reference's own 180 ms layer
/// fade (`BootScreen.fadeOutDuration`; pass that constant, the two defaults are pinned equal by a
/// test in `Tests/test_boot_screen.py`). `failed` does the same, minus the readiness: the person gets
/// the app's connect/pair UI, which is where the words, the retry and the pair sheet already live.
/// Neither path can bring the splash back.
@MainActor
public struct LaunchGateView<Boot: View, Content: View>: View {

    @ObservedObject private var model: AppModel
    /// Read on every evaluation rather than passed as a value: pairing can be restored or dropped
    /// while the gate is still waiting.
    private let isPaired: () -> Bool
    private let fadeOut: TimeInterval
    private let boot: Boot
    private let content: Content
    /// Called once, after the launch screen has finished fading out.
    ///
    /// The shells hang work that must not happen over the splash on this — the iOS update card is
    /// the first: its check runs during boot and its answer is held until here. Optional, so a
    /// preview or a test host that does not care does not have to pass anything.
    private let onContentRevealed: (() -> Void)?

    @State private var readiness: LaunchReadiness

    /// Thirty evaluations a second, the same beat the app's faces move at.
    private static var tick: UInt64 { 1_000_000_000 / 30 }

    public init(model: AppModel,
                isPaired: @escaping () -> Bool,
                deadline: TimeInterval = LaunchReadiness.defaultDeadline,
                fadeOut: TimeInterval = 0.18,
                onContentRevealed: (() -> Void)? = nil,
                @ViewBuilder boot: () -> Boot,
                @ViewBuilder content: () -> Content) {
        self.model = model
        self.isPaired = isPaired
        self.fadeOut = max(fadeOut, 0)
        self.onContentRevealed = onContentRevealed
        self.boot = boot()
        self.content = content()
        _readiness = State(initialValue: LaunchReadiness(deadline: deadline))
    }

    public var body: some View {
        ZStack {
            // Behind the launch screen from the first frame: the roster's rows are built while the
            // socket is still being dialled, so the fade uncovers a list rather than an empty box.
            content
                // While the splash is up it is what the app *is*: VoiceOver should not walk the
                // half-filled list underneath it.
                .accessibilityHidden(readiness.showsBootScreen)

            // Always in the hierarchy and fully transparent once the gate opens: a static drawing
            // costs nothing to keep, and presence-removal would need a second state variable to
            // outlive the fade — a second answer to "is the launch screen up?", which is exactly
            // what this view exists to avoid.
            boot
                .opacity(readiness.showsBootScreen ? 1 : 0)
                .animation(.easeInOut(duration: fadeOut), value: readiness.showsBootScreen)
                .allowsHitTesting(false)
                .accessibilityHidden(!readiness.showsBootScreen)
                .zIndex(1)
        }
        .task { await watch() }
    }

    // MARK: - The loop

    private func watch() async {
        readiness.begin(at: Self.now)
        evaluate()
        while !Task.isCancelled, !readiness.isTerminal {
            try? await Task.sleep(nanoseconds: Self.tick)
            evaluate()
        }
        guard !Task.isCancelled else { return }
        // After the fade, not when it starts: the shell is only really on show once the launch
        // screen has stopped drawing over it.
        if fadeOut > 0 {
            try? await Task.sleep(nanoseconds: UInt64(fadeOut * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        onContentRevealed?()
    }

    /// One evaluation. The machine is advanced on a copy so an unchanged phase costs no redraw —
    /// writing `@State` invalidates the subtree whether the value changed or not.
    private func evaluate() {
        var next = readiness
        next.advance(model.launchSignals(isPaired: isPaired()), at: Self.now)
        guard next != readiness else { return }
        readiness = next
    }

    /// Monotonic, and unaffected by the wall clock moving under the app: `systemUptime` is what an
    /// elapsed-time deadline wants, where `Date` can jump backwards at an NTP correction.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public extension AppModel {
    /// The answers `LaunchReadiness` asks for, taken from state this model already publishes.
    ///
    /// `rosterAnswered` and `sessionsAnswered` are the two facts that are not otherwise readable:
    /// `bots.isEmpty` cannot tell "the host says it has no bots" from "nobody has asked yet", and the
    /// difference is a launch screen that leaves or one that waits out its deadline.
    func launchSignals(isPaired: Bool) -> LaunchReadiness.Signals {
        LaunchReadiness.Signals(isPaired: isPaired,
                                isConnected: connection.isLive,
                                connectionFailed: connection.isFailed,
                                rosterAnswered: rosterAnswered,
                                sessionsAnswered: sessionsAnswered)
    }
}
#endif
