import AppKit
import HermeyUI
import ServiceManagement
import SwiftUI

/// The login item, as the settings row sees it.
///
/// `SMAppService.mainApp` is macOS 13+ and this app targets 14, so there is no older API to carry.
/// Two states are why this is more than a boolean: registration can land in "needs approval" when the
/// owner switched the item off in System Settings, and it can fail outright on a build macOS will not
/// accept. A toggle that silently snaps back is worse than one that explains itself, so the row always
/// shows the status the system reports rather than the wish the click expressed.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var status: LaunchAtLoginStatus = .off

    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        // The owner can change this in System Settings while Hermey is running, so the row's idea of
        // the truth is re-read whenever the app comes back to the front.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        )
    }

    func refresh() {
        status = Self.map(SMAppService.mainApp.status)
    }

    /// Ask for the change, then re-read what the system actually did.
    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // The row keeps describing reality; the log keeps the reason.
            NSLog("Hermey: login item %@ failed: %@",
                  on ? "registration" : "removal", error.localizedDescription)
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func map(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled: return .on
        case .notRegistered: return .off
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
}
