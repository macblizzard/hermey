import AppKit
import HermesAppKit
import HermesKit
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
                .hermeyFocusQuiet()
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
                .hermeyFocusQuiet()

                // The reason behind "something went wrong", one click from the version number
                // people are asked for first. Same viewer as the phone's Settings → View log.
                Button("View log…") { showLog = true }
                    .accessibilityIdentifier("aboutViewLog")
                    .hermeyFocusQuiet()

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
            ClientLogView(title: "Log", header: logHeader,
                          uploader: store.model.clientLogUploader)
            .hermesSheetChrome()
        }
    }

    /// The other half of "which version am I running": the **host** service, which updates on its
    /// own schedule and whose version is not this app's.
    ///
    /// One line, in the order a person asks the question: the version, what it means, and the press
    /// that answers it. The action sits on that same line, right-aligned in a fixed-width slot, so
    /// `Check now` visibly acts on the number beside it instead of floating at the far right of a
    /// heading — and so the row does not move when an update turns `Check now` into `Update`. The
    /// words for each answer are the ones this row has always used; what changed is that each answer
    /// has its own colour, because muted grey for "up to date" and "could not check" alike told the
    /// reader nothing.
    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("HOST SERVICE")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(hostLine)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(hostLineTone)
                    .monospacedDigit()
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("aboutHostVersion")

                Spacer(minLength: 8)

                // Before the button, never in its place: the link is quiet and optional, and the
                // press has to stay in the same spot whether or not a release page exists.
                if let update = store.model.hostUpdate, update.showsNotes, let notes = update.notesURL {
                    Link("What's new", destination: notes)
                        .font(TypeScale.font(TypeScale.micro))
                        .hermeyFocusQuiet()
                }

                hostAction
                    .frame(width: Self.hostActionWidth, alignment: .trailing)
            }

            // Only a press has a second line: installing is the one thing here that reports stages,
            // and the version line above stays the version line throughout it.
            if let state = store.model.hostUpdate?.stateText {
                Text(state)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(store.model.hostUpdate?.isSettled == true ? Tokens.textMuted : Tokens.textDim)
                    .accessibilityIdentifier("aboutHostState")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The width every state of the action occupies. One number, not a per-state size: an update
    /// must not nudge the line it belongs to.
    private static let hostActionWidth: CGFloat = 104

    /// The one control on the line, and the only thing on this page that changes the machine.
    ///
    /// Every branch draws the same class of control — a bordered `.small` button, as the rest of
    /// this pane uses — so the slot reads as one button that changes its word, not as a status line
    /// that sometimes grows a button out of it.
    @ViewBuilder
    private var hostAction: some View {
        if let update = store.model.hostUpdate, update.isBusy {
            // Downloading, verifying, restarting: the stage words are on the line below, and a press
            // here would ask for what is already running.
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("aboutHostBusy")
        } else if store.model.hostCheckRunning {
            // It says so, and refuses a second press — here and in the model.
            Button("Checking…") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .accessibilityIdentifier("aboutHostCheck")
                .hermeyFocusQuiet()
        } else if let update = store.model.hostUpdate, let title = update.buttonTitle {
            Button(title) {
                Task { await self.store.model.beginHostUpdate() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!update.canStartPress)
            .accessibilityIdentifier("aboutHostUpdate")
            .hermeyFocusQuiet()
        } else if let update = store.model.hostUpdate, update.isSettled {
            Button("Dismiss") { self.store.model.dismissHostUpdate() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("aboutHostDismiss")
                .hermeyFocusQuiet()
        } else {
            Button("Check now") {
                Task { await self.store.model.checkHostUpdate(refresh: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.model.hostCheckRunning)
            .accessibilityIdentifier("aboutHostCheck")
            .hermeyFocusQuiet()
        }
    }

    /// The colour the host line carries.
    ///
    /// Three answers, three tones: an available update is the accent because there is something to
    /// press; a host that could not be asked, or that is behind and cannot install it itself, is the
    /// warning because somebody has to look; a host that answered is plain muted text.
    private var hostLineTone: Color {
        guard store.isPaired, let status = store.model.hostStatus else { return Tokens.textMuted }
        // A press that could not be answered is the warning tone even when the last answer was a
        // good one: the number is a fact, but "and I just checked" is not, and saying nothing about
        // that is how a press reads as a no-op.
        if store.model.hostCheckFailure != nil { return Tokens.warning }
        if status.latest == nil { return Tokens.warning }
        // `accentText`, not `accent`: this is a 12 pt line of text, and the accent used as a wash
        // behind a selected row is not always readable as a sentence on the canvas.
        if status.hasNewerRelease { return status.canSelfUpdate ? Tokens.accentText : Tokens.warning }
        return Tokens.textMuted
    }

    /// The host line: the version, and the truth about what it means — on one line, always.
    ///
    /// The version is the host's own `current` from the newest answer that arrived, whatever
    /// `available` says: a feed still behind the running build (0.4.0 published, 0.8.14 running)
    /// reads as "up to date" because that is what it is, and the number on the left is never a
    /// cached or earlier one. A check that could not be answered keeps that number and says why
    /// beside it — "up to date" is only ever said about a host that answered.
    private var hostLine: String {
        guard store.isPaired else { return "not paired" }
        if let status = store.model.hostStatus {
            // A press that could not be answered says so first: the number beside it is a fact, but
            // whether an update is on offer was true of the *last* answer, not of this press.
            if let failure = store.model.hostCheckFailure {
                return "\(status.current) · could not check: \(failure)"
            }
            if status.hasNewerRelease, let latest = status.latest {
                // A published release the host has not offered is news, not a button: say exactly
                // that, so the row never claims an offer the button cannot make.
                if !status.available {
                    return "\(status.current) · \(latest) published; this host has not offered it"
                }
                return status.canSelfUpdate
                    ? "\(status.current) · \(latest) available"
                    : "\(status.current) · \(latest) is out; this host does not update itself"
            }
            if status.latest == nil { return "\(status.current) · could not check" }
            return "\(status.current) · up to date"
        }
        // No answer has ever arrived: the reason a press did nothing is the only thing worth saying.
        if let failure = store.model.hostCheckFailure { return "could not check: \(failure)" }
        return "version unavailable"
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
