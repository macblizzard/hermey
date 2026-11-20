import AppKit
import SwiftUI

/// The window's own full-screen mode, driven by the computer pane's flag.
///
/// The pane has always had a "full screen" verb, but it only ever grew *inside* the window: the
/// sidebar, the transcript and the window's chrome stayed exactly where they were, so a 1440x900
/// desktop still shared the screen with a conversation. This puts the window itself into full screen
/// — the green button's own behaviour — while the flag is up, and takes it back out when the flag
/// goes down. It also reports the reverse: leaving full screen the system's way (green button, ⌃⌘F,
/// a display change) has to put the pane back in its panel, or the flag and the window disagree and
/// the next click on the button does nothing.
struct WindowFullScreenDriver: NSViewRepresentable {
    let isFullScreen: Bool
    /// Full screen ended without this driver asking for it: the shell puts the pane back.
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> NSView {
        let view = HostView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onExit = onExit
        context.coordinator.desired = isFullScreen
        context.coordinator.apply()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// A zero-size view whose only job is to find its window.
    private final class HostView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    final class Coordinator {
        var desired = false
        var onExit: () -> Void
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        /// Set while a toggle is in flight. Full screen animates, and a second `toggleFullScreen`
        /// during that animation can leave the window wherever the caller did not ask for.
        private var pending = false

        init(onExit: @escaping () -> Void) { self.onExit = onExit }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            guard window !== self.window else {
                apply()
                return
            }
            self.window = window
            detach()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                object: window, queue: .main) { [weak self] _ in
                self?.pending = false
            })
            observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.pending = false
                // Only a departure this driver did not ask for is news: the flag said full screen,
                // the window says otherwise, and the pane has to come back into its panel.
                if self.desired {
                    self.desired = false
                    self.onExit()
                }
            })
            apply()
        }

        func apply() {
            guard let window else { return }
            let active = window.styleMask.contains(.fullScreen)
            guard desired != active, !pending else { return }
            pending = true
            window.toggleFullScreen(nil)
            // A window that refuses (nothing resizable, a sheet in the way) sends no notification at
            // all — without this the button would stay inert for the rest of the session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.pending = false
            }
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        deinit { detach() }
    }
}
