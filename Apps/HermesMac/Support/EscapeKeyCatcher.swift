import AppKit
import SwiftUI

/// Escape, answered by the shell.
///
/// The panes are not modal, so nothing owned the key: the palette answered Escape (its own
/// `.onExitCommand`) and the sidebar, the bot panel and the computer ignored it. People press Escape
/// at a panel they want gone, and on this app nothing happened.
///
/// A local monitor rather than `.onExitCommand` on the shell, for one reason: `.onExitCommand`
/// belongs to the focused *view*, so a focused text field would either eat Escape or bubble it —
/// meaning the composer's own Escape behaviour would change depending on which panel happened to be
/// open. The monitor is neutral: it looks at the first responder first, and if someone is typing it
/// steps out of the way and lets the field have the key. Otherwise the key closes the topmost thing
/// and never reaches an inner view.
struct EscapeKeyCatcher: NSViewRepresentable {
    /// What to close. Returning `true` means the key was used and is swallowed.
    var onEscape: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onEscape: onEscape) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var onEscape: () -> Bool
        private var monitor: Any?

        init(onEscape: @escaping () -> Bool) {
            self.onEscape = onEscape
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
                    return event
                }
                // A key that types wins over a key that closes: the field editor is an `NSTextView`,
                // and it is the first responder for every text field in the app.
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                // A sheet owns its own Escape: `dismiss` is what a person means there.
                if NSApp.keyWindow?.attachedSheet != nil { return event }
                return self.onEscape() ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}
