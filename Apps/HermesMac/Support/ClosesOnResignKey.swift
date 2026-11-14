import AppKit
import SwiftUI

/// Closes the window when the click that took focus away was outside it.
///
/// The Settings window used to sit there until it was clicked shut — and worse, Escape pressed in
/// it closed the sidebar behind it, because nothing in the window answered the key. A settings
/// surface that behaves as though it belongs to the workspace should dismiss like the workspace's
/// other surfaces: Escape, or a click anywhere else (reported 2026-11-14).
///
/// Two things are *not* "outside": a sheet attached to this window (the bot settings that the Bots
/// tab opens) and a panel this app owns that is itself momentary. Both become key windows, so a
/// plain `didResignKey` observer would close the tab's parent out from under its own sheet.
struct ClosesOnResignKey: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ObserverView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ObserverView: NSView {
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                removeObserver()
                return
            }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                let next = NSApp.keyWindow
                // Its own sheet keeps it: the Bots tab's bot settings is a sheet on this window.
                if let next, next.sheetParent === window { return }
                // A menu or a tooltip is not a place to go.
                if let next, next.className.contains("Menu") || next.level == .popUpMenu { return }
                window.performClose(nil)
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeObserver() }
        }

        private func removeObserver() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
