import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftUI

/// macOS gates each local-computer capability behind a different TCC permission. There is no single
/// "computer use" grant, so the settings panel has to show four honest states and open the *right*
/// System Settings pane for each one.
enum ComputerPermission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .inputMonitoring: return "Input Monitoring"
        case .automation: return "Automation"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: return "Needed to click, type and read the screen's controls."
        case .screenRecording: return "Needed for computer.observe screenshots."
        case .inputMonitoring: return "Needed to notice when you take the mouse or keyboard back."
        case .automation: return "Needed to drive apps with AppleScript; granted per app on first use."
        }
    }

    /// The deep link into System Settings › Privacy & Security. These are Apple's documented
    /// `x-apple.systempreferences` pane identifiers, not a guess at the UI layout.
    var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        case .automation: pane = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Granted / missing / not testable without asking an app. `nil` is shown as "On first use", never as
/// a failure — Automation is per-app and cannot be queried globally.
struct ComputerPermissionState {
    let granted: Bool?
    let note: String?

    var label: String {
        switch (granted, note) {
        case (.some(true), _): return "Granted"
        case (.some(false), _): return "Needs access"
        case (.none, "On first use"): return "On first use"
        default: return "Not checked"
        }
    }
}

@MainActor
final class ComputerPermissions: ObservableObject {
    @Published private(set) var states: [ComputerPermission: ComputerPermissionState] = [:]

    init() {
        refreshSafe()
        states[.screenRecording] = ComputerPermissionState(granted: nil, note: nil)
        states[.inputMonitoring] = ComputerPermissionState(granted: nil, note: nil)
        states[.automation] = ComputerPermissionState(granted: nil, note: "On first use")
    }

    /// Only the non-prompting check. `AXIsProcessTrusted()` does not show a TCC dialog; the
    /// ScreenCaptureKit and event-tap probes do, so they must wait for an explicit button press.
    func refreshSafe() {
        states[.accessibility] = ComputerPermissionState(
            granted: AXIsProcessTrusted(), note: nil)
    }

    /// Called only from a button in the settings panel. Never from `init`, `onAppear` or scene-phase
    /// changes — macOS treats a probe as a permission request and the owner decides when that happens.
    func check(_ permission: ComputerPermission) {
        switch permission {
        case .accessibility:
            refreshSafe()
        case .screenRecording:
            states[.screenRecording] = ComputerPermissionState(granted: nil, note: "Checking…")
            Task { await checkScreenRecording() }
        case .inputMonitoring:
            states[.inputMonitoring] = ComputerPermissionState(
                granted: Self.inputMonitoringAllowed(), note: nil)
        case .automation:
            testAutomation()
        }
    }

    /// Accessibility is the one grant with a public system prompt API. Use it before falling back to
    /// the Settings pane; the other three must be switched on by the user in System Settings.
    func request(_ permission: ComputerPermission) {
        if permission == .accessibility {
            // In modern Swift the AX prompt key arrives as Unmanaged<CFString>; unwrap it before
            // building the CFDictionary or the compiler rejects it as a non-Hashable dictionary key.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            let prompted = AXIsProcessTrustedWithOptions(options)
            states[.accessibility] = ComputerPermissionState(granted: prompted, note: nil)
            if prompted { return }
        }
        openSettings(permission)
    }

    func openSettings(_ permission: ComputerPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// Send a harmless AppleEvent to System Events. macOS shows the Automation prompt if it has not
    /// been granted; error -1743 means the user refused, which the UI reports plainly.
    func testAutomation() {
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application \"System Events\" to get name")
        _ = script?.executeAndReturnError(&error)
        let granted = error == nil
        let code = (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        states[.automation] = ComputerPermissionState(
            granted: granted,
            note: granted ? nil : "System Events refused the AppleEvent (error \(code ?? -1)).")
    }

    private func checkScreenRecording() async {
        let granted: Bool
        if #available(macOS 12.3, *) {
            granted = await withCheckedContinuation { continuation in
                SCShareableContent.getWithCompletionHandler { content, error in
                    continuation.resume(returning: error == nil && content != nil)
                }
            }
        } else {
            granted = true
        }
        states[.screenRecording] = ComputerPermissionState(
            granted: granted,
            note: granted ? nil : "Hermey is not in the list; add it and relaunch the app.")
    }

    /// A listen-only event tap is the closest thing to a public Input Monitoring probe. If macOS
    /// refuses the tap, the permission is missing.
    private static func inputMonitoringAllowed() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: { _, _, _, _ in nil },
                                          userInfo: nil) else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }
}

/// A command that needs a permission must say which one, rather than failing with an opaque macOS
/// error deep in a framework.
enum ComputerPermissionError: LocalizedError {
    case missing(ComputerPermission)

    var errorDescription: String? {
        switch self {
        case .missing(let permission):
            return "\(permission.title) access is off. Enable it in Settings → Computer, then open \(permission.title) in System Settings."
        }
    }
}
