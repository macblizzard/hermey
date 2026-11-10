import AppKit
import HermesAppKit
import OpenBotUI
import SwiftUI

/// The app's own identity, in one place.
///
/// The menu's About panel and the Settings tab both read it, so a version number cannot disagree
/// with itself — and both read the *bundle*, not a constant, because CI stamps
/// `CFBundleShortVersionString`/`CFBundleVersion` per run and a literal here would go stale on the
/// first release after it was written.
enum AppVersion {
    static var marketing: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var label: String { "Version \(marketing) · build \(build)" }

    /// The system panel: AppKit draws it, it is the shape the About menu is expected to take, and
    /// the version it shows comes from the same bundle keys as the Settings tab.
    static func showStandardPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Hermey",
            .applicationVersion: marketing,
            .version: "build \(build)",
            .credits: NSAttributedString(string: "Hermey — the Hermes native client for macOS and iPhone."),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings → About.
///
/// It exists because the macOS app ships unsigned from a sideloading source: the Finder's Get Info
/// shows a version, but the app itself had no way to tell the user which build they were running,
/// which is the first question after a fix "did not take".
struct AboutSettingsTab: View {
    @ObservedObject var store: WorkspaceStore

    @State private var copied = false
    /// The log is read in a sheet: the About tab is a page of facts, and a log is a tool that
    /// scrolls.
    @State private var showLog = false

    private var diagnostics: String {
        """
        Hermey \(AppVersion.marketing) (build \(AppVersion.build))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        host: \(store.isPaired ? store.model.hostName : "not paired")
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Hermey")
                    .font(TypeScale.font(Tokens.textLG, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)

                Text(AppVersion.label)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("aboutVersion")
            }
            .padding(.top, 26)
            .padding(.bottom, 18)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy diagnostics") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(diagnostics, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        copied = false
                    }
                }
                .accessibilityIdentifier("aboutCopyDiagnostics")

                // The reason behind "something went wrong", one click from the version number
                // people are asked for first. Same viewer as the phone's Settings → View log.
                Button("View log…") { showLog = true }
                    .accessibilityIdentifier("aboutViewLog")

                Spacer()

                Text("Updates arrive through the same source you installed from.")
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.canvas)
        .sheet(isPresented: $showLog) {
            ClientLogView(title: "Log", header: logHeader)
        }
    }

    /// What the log is *about*: build, OS, host, connection. The same header the phone puts above
    /// the same lines.
    private var logHeader: String {
        let host = store.isPaired ? store.model.hostName : "not paired"
        return "Hermey \(AppVersion.marketing) (build \(AppVersion.build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString) · host: \(host) · \(store.model.connection.label)"
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
