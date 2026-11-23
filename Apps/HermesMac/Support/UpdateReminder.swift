import Foundation
import os

#if canImport(Sparkle)
import Sparkle

/// What Sparkle may say at launch, and what the panel says instead.
///
/// The launch check used to end in Sparkle's own "a new version is available" alert: a *scheduled*
/// check is drawn by the standard user driver, behind the app's windows but a window all the same,
/// and it opened on every cold start after a release. The panel has a place for that answer now — a
/// glyph on the floor bar, immediately left of search — so the driver is told **no** for a scheduled
/// update and the version is reported instead:
/// `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` → `false`. Nothing
/// pops at boot; the panel carries the news until the owner acts on it.
///
/// A check the owner *asks* for is untouched. Sparkle always handles those itself — the method above
/// is not even called for them — so the menu bar's "Check for Updates…", the palette row, Settings →
/// About and the glyph's own press all end in Sparkle's standard download-and-install window.
///
/// Every callback here arrives on the main thread: Sparkle's drivers document it, and
/// `SPUUpdaterDelegate` is main-actor isolated in the versions this package resolves. That makes
/// `MainActor.assumeIsolated` the exact hop rather than a hopeful one, and it keeps the witnesses
/// non-isolated so the file compiles against both the 2.6 floor and the newer resolutions.
final class UpdateReminder: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    /// Where a waiting version — or the end of one — is reported. Assigned once by the app, and the
    /// only thing this class knows about the rest of the program: it never imports the store.
    var onUpdate: (@MainActor (String?) -> Void)?

    /// The one line about updates that has to be readable from outside the app: the version the
    /// floor bar is offering. Read it with
    /// `log show --last 1h --predicate 'subsystem == "dev.hermey.app.mac" and category == "updates"'`.
    private let updateLog = Logger(subsystem: "dev.hermey.app.mac", category: "updates")

    /// Opt in to gentle scheduled reminders. Without this Sparkle keeps drawing its own alert for a
    /// scheduled check, which is the window this class exists to retire.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// **No.** A scheduled check — the launch one, or Sparkle's own daily cycle — finds its answer
    /// here and is not allowed to open anything. The version is handed over on the way out.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool {
        report(update.displayVersionString)
        return false
    }

    /// Called whether the standard driver handles the update or not. A user-initiated check is the
    /// owner pressing something — the glyph included — so Sparkle takes the session and the glyph
    /// retires rather than sitting under a download window claiming to be a button. A scheduled one
    /// is this path's own confirmation, and the version is kept.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        report(state.userInitiated ? nil : update.displayVersionString)
    }

    /// The session ended — installed, dismissed, skipped, cancelled or failed. Whichever it was,
    /// nothing is downloading any more, so the glyph must not claim that it is.
    func standardUserDriverWillFinishUpdateSession() {
        report(nil)
    }

    /// A check that found nothing: the build is current, or the feed moved on. The glyph must not
    /// outlive the release it was offering.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        report(nil)
    }

    /// One place, so the log and the store can never disagree about what is waiting.
    private func report(_ version: String?) {
        if let version {
            updateLog.notice("update waiting: \(version, privacy: .public)")
        }
        guard let deliver = onUpdate else { return }
        MainActor.assumeIsolated { deliver(version) }
    }
}
#endif
