import AppKit
import HermesAppKit
import HermeyUI
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
    /// The app's updater action, handed down from `HermesMacApp` — the same one the menu item
    /// calls. The version text is where a person goes to ask "am I current", so asking is a press
    /// on the line right under it rather than a trip to the menu bar.
    let checkForUpdates: () -> Void

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

                // The manual check, beside the number it answers for. Sparkle's panel is the only
                // UI: a build that is current gets its "up to date" notice, a newer one its notes
                // and Install, and either can be dismissed without touching the workspace.
                Button("Check for Updates…") {
                    checkForUpdates()
                }
                .controlSize(.small)
                .accessibilityIdentifier("aboutCheckForUpdates")
            }
            .padding(.top, 26)
            .padding(.bottom, 18)

            hostSection
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

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

                Text("Updates are verified and installed in place by Sparkle.")
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
            .hermesSheetChrome()
        }
    }

    /// The other half of "which version am I running": the **host** service, which updates on its
    /// own schedule and whose version is not this app's.
    ///
    /// Same row, same words as the bell's, and the same button: an update is never applied from
    /// here without a press, and the button is the only thing on this page that changes the machine.
    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SectionCaption("HOST SERVICE")
                Spacer(minLength: 0)
                Button("Check now") {
                    Task { await self.store.model.checkHostUpdate(refresh: true) }
                }
                .buttonStyle(.plain)
                .font(TypeScale.font(TypeScale.micro))
                .foregroundStyle(Tokens.textDim)
                .accessibilityIdentifier("aboutHostCheck")
            }

            if let update = store.model.hostUpdate {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(update.versionLine)
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textPrimary)
                            .monospacedDigit()
                            .textSelection(.enabled)
                        if let state = update.stateText {
                            Text(state)
                                .font(TypeScale.font(TypeScale.micro))
                                .foregroundStyle(update.isSettled ? Tokens.textMuted : Tokens.textDim)
                                .accessibilityIdentifier("aboutHostState")
                        }
                    }
                    Spacer(minLength: 8)
                    if let notes = update.notesURL, update.showsNotes {
                        Link("What's new", destination: notes)
                            .font(TypeScale.font(TypeScale.micro))
                    }
                    if update.isBusy {
                        ProgressView().controlSize(.small)
                    } else if let title = update.buttonTitle {
                        Button(title) {
                            Task { await self.store.model.beginHostUpdate() }
                        }
                        .controlSize(.small)
                        .disabled(!update.canStartPress)
                        .accessibilityIdentifier("aboutHostUpdate")
                    } else if update.isSettled {
                        Button("Dismiss") { self.store.model.dismissHostUpdate() }
                            .controlSize(.small)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(hostLine)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.textMuted)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("aboutHostVersion")
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The host line when no row is drawn: the version, and the truth about what it means.
    ///
    /// Four different situations, four different sentences — "up to date" is only said when the host
    /// answered and nothing newer exists. A host that cannot update itself still gets the news it is
    /// behind; it just gets no button here either.
    private var hostLine: String {
        guard store.isPaired else { return "not paired" }
        guard let status = store.model.hostStatus else { return "version unavailable" }
        if let latest = status.latest, status.available {
            return status.canSelfUpdate
                ? "\(status.current) · \(latest) available"
                : "\(status.current) · \(latest) is out; this host does not update itself"
        }
        if status.latest == nil { return "\(status.current) · could not check" }
        return "\(status.current) · up to date"
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
