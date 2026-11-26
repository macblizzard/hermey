import AppKit
import SwiftUI

/// The one clock the bot list's idle faces float on.
///
/// The roster's rows used to be pictures: every avatar in `SidebarBotList` drew with `animates:
/// false`, because seventeen always-animating `Canvas` faces at the busiest cadence were part of what
/// made the panel feel heavy while scrolling. 0.1.681 gave the *drawn* avatar an idle float, and the
/// owner's report is that he cannot see it in the list — the float lives inside a timeline each row
/// does not run. So the list now runs **one** clock and every visible row reads it:
///
/// * **one timer for the whole list**, not one per row and never a display link — a row that
///   re-reads a published instant costs one body evaluation, and the list's own body (the grouping,
///   the filter, the `LazyVStack`) is not invalidated at all;
/// * **three frames a second** (`cadence`). The idle float's cycle is 1.8 s — five or six samples a
///   cycle — and the whole travel is two and a half percent of the face's side, so at row size the
///   steps are a third of a point: that is a drift, not a twitch. A faster beat here would only buy
///   smoother sub-point motion at twenty times the cost;
/// * **only what is on screen**: a row is counted while it is materialised (`rowAppeared` /
///   `rowDisappeared`), which is what a `LazyVStack` gives us — a row scrolled away is not in the
///   hierarchy and does not count, and it draws `rest` because it is handed no instant;
/// * **nothing at all** while the list is hidden, the panel has no rows, the window is not the one
///   being used, the app is not active, Reduce Motion is on, or the app's own motion switch is off.
///
/// The timer is invalidated rather than left ticking on a flag: "paused" here means there is no
/// timer, so a face that should be still cannot cost a wake-up either. Everything on this type is
/// main-thread: the timer is added to the main run loop, and the window/app notifications are
/// delivered on the main queue.
final class BotListClock: ObservableObject {
    /// How often the list's faces are sampled, in seconds: 3 Hz.
    ///
    /// The one number for the whole feature. The chat header and the pet keep
    /// `BotAvatarMotion.frameInterval(for:)` — a tenth of a second — because one face being looked at
    /// is worth ten frames where a roster of them is not worth thirty. This is the deliberate floor:
    /// slower than that, and the 1.8 s float starts to read as a stutter rather than a drift.
    static let cadence: Double = 1.0 / 3.0

    /// More rows than this on screen and the list keeps every face still.
    ///
    /// A ceiling rather than a measurement: 32 faces at 3 Hz is 96 avatar frames a second, which is
    /// about three busy faces running at once (`BotAvatarMotion.frameInterval`, 30 Hz). Past that the
    /// cost stops being "a slow drift in a list" and becomes a reason to ask why a panel is showing
    /// that many rows — the panel caps itself at about five, and a full-height sidebar shows a
    /// windowful, so this only ever trips on a window taller than any Mac.
    static let maximumDriftingRows = 32

    /// The instant to draw, or nil while the list is resting.
    ///
    /// Published, so a row that reads it re-evaluates when it changes; nothing else in the list reads
    /// it, which is what keeps a tick from touching the grouping or the row layout.
    @Published private(set) var time: Double?

    private var timer: Timer?
    /// The window the list is in, reported by `BotListWindowProbe`. Weak: the clock must not keep a
    /// closed window alive.
    private weak var window: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    /// Materialised rows. Zero is the panel being closed, the list being empty, or the block not
    /// being drawn at all — three different reasons to have no timer.
    private var visibleRows = 0
    /// The person's own answer: Reduce Motion, the app's motion switch, a background scene.
    private var motionAllowed = false
    /// One queued sync at most. Every entry point below can fire several times in one turn (a row
    /// appearing, a window becoming key, Reduce Motion flipping), and each of them is asking the
    /// same question.
    private var syncScheduled = false

    deinit {
        timer?.invalidate()
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }

    // MARK: - What the list tells it

    /// The window the list lives in, from the probe in `SidebarBotList`'s background.
    ///
    /// `NSApp.keyWindow` is deliberately not used: it answers for whichever window of the app is key,
    /// which may be Settings, a sheet or the pets' panel — never the question "is this list's own
    /// window the one being used".
    func attach(window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        observe()
        scheduleSync()
    }

    /// Whether the person has allowed any motion at all: Reduce Motion, the app's own switch, and
    /// whether the app is in the foreground. The list computes it from its own environment values, so
    /// flipping the switch in Settings stops the faces without a relaunch.
    func setMotionAllowed(_ allowed: Bool) {
        guard motionAllowed != allowed else { return }
        motionAllowed = allowed
        scheduleSync()
    }

    /// A row is on screen. Called once per materialisation, from the row's own `onAppear`.
    func rowAppeared() {
        visibleRows += 1
        scheduleSync()
    }

    /// A row left the screen — scrolled away, filtered out, or the panel was closed.
    func rowDisappeared() {
        visibleRows = max(0, visibleRows - 1)
        scheduleSync()
    }

    // MARK: - When it runs

    /// Every gate, in one place. Each clause is a separate way for a list to be still:
    ///
    /// * no rows, or too many: nothing to draw, or more than the ceiling above;
    /// * motion not allowed: Reduce Motion, the app's switch, a background scene;
    /// * the app is not active, or the list's window is not the key one, or the window is off screen
    ///   (another app's window in front of it, another Space, minimised) — `occlusionState` is the
    ///   system's own answer to "is this window actually being looked at", and it is the one the pets
    ///   already use.
    private var allowed: Bool {
        guard motionAllowed else { return false }
        guard visibleRows > 0, visibleRows <= Self.maximumDriftingRows else { return false }
        guard let app = NSApp, app.isActive else { return false }
        guard let window, window.isVisible, window.isKeyWindow,
              window.occlusionState.contains(.visible) else { return false }
        return true
    }

    /// Starts or stops the timer to match `allowed`. Coalesced and deferred by one run-loop turn,
    /// because half of what calls it happens *inside* a SwiftUI update (a window being attached) and
    /// publishing from there is exactly the "modifying state during view update" the framework warns
    /// about.
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.sync()
        }
    }

    private func sync() {
        if allowed { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        // Publish before the first tick, so the face is at the current instant the moment it is
        // allowed to move rather than one frame later.
        time = Date().timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: Self.cadence, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // A fifth of the interval is slack the system may use to coalesce this with other timers:
        // the float is a drift, so ±60 ms is invisible, and the wake-up is what costs.
        timer.tolerance = Self.cadence * 0.2
        // `.common`, not `.default`: scrolling a scroll view runs the run loop in its own mode, and a
        // timer that stops for the length of a scroll would freeze every face mid-float and restart
        // it after. The tick is one Date and one publish; it is not what makes a scroll slow.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        // Nil, not "the last instant": nil is what the rows draw `rest` from, so a list that pauses
        // settles exactly where it started instead of freezing mid-air with a still face.
        if time != nil { time = nil }
    }

    private func tick() {
        // A gate can change without a notification — a window moving behind another is the usual one
        // — so the tick re-answers the question before it publishes. When the answer changed, this is
        // the stop; when it did not, the publish is one Double.
        guard allowed else { stop(); return }
        time = Date().timeIntervalSinceReferenceDate
    }

    // MARK: - What changes the answer

    /// The window's focus is not a published SwiftUI value, so it is heard rather than read: each of
    /// these notifications re-asks `allowed`, and none of them is on a timer of its own.
    private func observe() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
        ]
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleSync()
            }
        }
    }
}

/// Reports the window a SwiftUI view is in, once it is in one.
///
/// The bot list needs its *own* window — for focus, for occlusion — and `NSApp.keyWindow` is not it.
/// This is a measuring view, like `HoverReporter`: it never draws and never takes a click.
struct BotListWindowProbe: NSViewRepresentable {
    var onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        ProbeView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// Not a hit target: the rows in front of it keep every press.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}
