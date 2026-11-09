import SwiftUI
import HermesKit
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The shared computer, as the apps show it.
///
/// One screen serves every bot, so this pane is deliberately **bot-agnostic** in what it claims: it
/// says "Shared computer", carries the bot's name only as "what it is doing this for", and never
/// implies a private desktop. Control is the gateway's lease — while a human holds it, every bot's
/// `computer_use` is refused, which is the point: you are signing in or answering a 2FA prompt on
/// the machine they share.
///
/// The view has three states, and each one is honest about what it can do:
/// * **stopped / not installed** — Start, or the host's own blocker sentence instead of Start;
/// * **watching** — a live picture, pointer/keyboard inert (the host drops input from a viewer
///   without the lease, so the UI hint is not the gate);
/// * **in control** — input enabled, a red-leaning chip, and Hand back as the way out.
public struct BotComputerPane: View {
    private let profile: String
    private let displayName: String
    private let client: BotComputerClient
    private let resources: BotComputerResources?
    private let onClose: (() -> Void)?
    private let onToggleFullScreen: (() -> Void)?
    private let isFullScreen: Bool

    @State private var status: BotComputerStatus?
    @State private var thumbnail: String?
    @State private var ticket: BotComputerTicket?
    @State private var socketURL: URL?
    @State private var viewerID: String?
    @State private var holdsControl = false
    @State private var isLive = false
    /// True once the page reports its socket open. Until then the pane says "Connecting…" instead of
    /// showing the black rectangle that an unconnected canvas is.
    @State private var isConnected = false
    /// Bumped by the keyboard button: the web view focuses noVNC, which is the only way iOS will
    /// raise the keys.
    @State private var keyboardNonce = 0
    /// How many times this sitting has silently retried a dropped stream.
    @State private var reconnectAttempts = 0
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var loop = 0

    public init(profile: String,
                displayName: String,
                client: BotComputerClient,
                resources: BotComputerResources? = BotComputerResources(),
                isFullScreen: Bool = false,
                onToggleFullScreen: (() -> Void)? = nil,
                onClose: (() -> Void)? = nil) {
        self.profile = profile
        self.displayName = displayName
        self.client = client
        self.resources = resources
        self.isFullScreen = isFullScreen
        self.onToggleFullScreen = onToggleFullScreen
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Tokens.frame).frame(height: 1)
            content
            if let errorText {
                errorStrip(errorText)
            }
        }
        .background(Tokens.canvas)
        // While watching, the picture is a live stream, not a still: no polling needed. While it is
        // not open, the thumbnail is refreshed at a human rate — three seconds is the same cadence
        // the Desktop's own Screen pane uses.
        .task(id: loop) {
            await refreshLoop()
        }
        .onDisappear {
            // Closing the pane hands control back. Leaving a stale human lease would lock every bot
            // out of the screen until someone else takes it.
            handBackIfNeeded()
            isLive = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shared computer")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                Text(subtitle)
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isBusy { ProgressView().controlSize(.small) }
            actionButtons
            if let onToggleFullScreen {
                Button {
                    onToggleFullScreen()
                } label: {
                    Image(systemName: isFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help(isFullScreen ? "Leave full screen" : "Full screen")
                .accessibilityLabel(isFullScreen ? "Leave full screen" : "Full screen")
            }
            if let onClose {
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        if let status, !status.installed { return "\(displayName) · not installed on the host" }
        if let status, let blocker = status.blocker, !blocker.isEmpty { return blocker }
        guard let status else { return "asking the host…" }
        if !status.running { return "stopped · \(displayName) will start it on first use" }
        if holdsControl { return "you are in control · every bot is paused" }
        return "\(displayName) has control" + (status.display.map { " · \($0)" } ?? "")
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isLive {
            if holdsControl {
                Button { keyboardNonce += 1 } label: { Image(systemName: "keyboard") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show the keyboard")
                    .accessibilityLabel("Show the keyboard")
            }
            Button(holdsControl ? "Hand back" : "Take over") {
                if holdsControl { handBack() } else { takeOver() }
            }
            .buttonStyle(.borderedProminent)
            .tint(holdsControl ? Tokens.warning : Tokens.accent)
            .controlSize(.small)
        } else if status?.running == true {
            Button("Open screen") { openScreen() }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .controlSize(.small)
        } else if status?.installed == false {
            EmptyView()
        } else {
            Button("Start screen") { startScreen() }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .controlSize(.small)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            Color.black
            if isLive, let socketURL, let resources {
                // One web view per socket. A new ticket means a new page: reusing the old one left a
                // dead viewer drawing nothing but its black background.
                BotComputerWebView(url: socketURL, resources: resources, viewOnly: !holdsControl,
                                   focusKeyboardNonce: keyboardNonce) { event in
                    handle(event)
                }
                .id(socketURL)
                if !isConnected { connectingOverlay }
            } else if let image = thumbnailImage {
                image.resizable().scaledToFit().opacity(0.9)
                watchingOverlay
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "display")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Tokens.textMuted)
                    Text(emptyText)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Connecting to the shared screen…")
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textSecondary)
        }
        .padding(16)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
    }

    private var watchingOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(Tokens.success).frame(width: 6, height: 6)
                Text("live preview · tap Open screen to watch, Take over to type")
                    .font(TypeScale.font(TypeScale.label))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.bottom, 12)
        }
    }

    private var emptyText: String {
        if status == nil { return "asking the host about the screen…" }
        if status?.installed == false { return "This host has no desktop packages installed yet." }
        if let blocker = status?.blocker, !blocker.isEmpty { return blocker }
        return "The screen is stopped. Start it, or let \(displayName) start it on its next use."
    }

    private var thumbnailImage: Image? {
        guard let thumbnail, let comma = thumbnail.firstIndex(of: ","),
              let data = Data(base64Encoded: String(thumbnail[thumbnail.index(after: comma)...]))
        else { return nil }
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }

    private func errorStrip(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.warning)
            Text(text)
                .font(TypeScale.font(TypeScale.label))
                .foregroundStyle(Tokens.textSecondary)
            Spacer(minLength: 0)
            Button { errorText = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Tokens.surface)
    }

    // MARK: - Actions

    private func refreshLoop() async {
        while !Task.isCancelled {
            if !isLive {
                await refreshOnce()
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func refreshOnce() async {
        do {
            let fresh = try await client.status(profile: profile)
            await MainActor.run {
                status = fresh
                if fresh.lease?.isHuman == false { holdsControl = false }
                // The poll is the health signal: if the host answers, whatever the strip said about
                // not reaching it a moment ago is no longer true.
                if !isBusy { errorText = nil }
            }
            if fresh.running, let dataURL = try? await client.thumbnail(profile: profile) {
                await MainActor.run { thumbnail = dataURL }
            } else {
                await MainActor.run { thumbnail = nil }
            }
        } catch {
            await MainActor.run { report(error) }
        }
    }

    private func startScreen() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                let fresh = try await client.start(profile: profile)
                await MainActor.run {
                    status = fresh
                    isBusy = false
                    errorText = nil
                    loop += 1
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    report(error)
                }
            }
        }
    }

    private func openScreen() {
        guard !isBusy else { return }
        isBusy = true
        isConnected = false
        Task {
            do {
                // A fresh viewer identity every time: the gateway binds a viewer id to the socket
                // that minted it, and the socket behind the old one is gone by now.
                let stream = try await client.streamURL(profile: profile, viewerID: nil)
                let primary = try? await client.status(profile: profile)
                await MainActor.run {
                    ticket = stream.ticket
                    viewerID = stream.ticket.viewerID
                    if let primary { status = primary }
                    socketURL = stream.url
                    isLive = true
                    isBusy = false
                }
                // The lease has to name the *new* viewer, or the host drops input from it while the
                // old id still appears to hold control.
                let held = await MainActor.run { holdsControl }
                if held, let id = await MainActor.run(body: { viewerID }) {
                    _ = try? await client.lease(profile: profile, acquire: true, viewerID: id)
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    report(error)
                }
            }
        }
    }

    /// Tear the viewer down and open a fresh one, so a lease change is applied to a socket that
    /// starts in the right mode instead of a page that has to be told about it after the fact.
    private func reopen() async {
        await MainActor.run {
            socketURL = nil
            isLive = false
            isConnected = false
        }
        openScreen()
    }

    private func takeOver() {
        guard let viewerID, !isBusy else { return }
        isBusy = true
        Task {
            do {
                let lease = try await client.lease(profile: profile, acquire: true, viewerID: viewerID)
                let held = lease?.isHuman ?? true
                await MainActor.run {
                    holdsControl = held
                    isBusy = false
                    errorText = nil
                }
                // Input, pointer and keyboard are then right from the first frame of the new socket.
                if held { await reopen() }
            } catch {
                await MainActor.run {
                    isBusy = false
                    report(error)
                }
            }
        }
    }

    private func handBack() {
        guard let viewerID else { holdsControl = false; return }
        Task {
            do {
                _ = try await client.lease(profile: profile, acquire: false, viewerID: viewerID)
                await MainActor.run { holdsControl = false; errorText = nil }
                await reopen()
            } catch {
                await MainActor.run { report(error) }
            }
        }
    }

    private func handBackIfNeeded() {
        guard holdsControl, let viewerID else { return }
        holdsControl = false
        Task { _ = try? await client.lease(profile: profile, acquire: false, viewerID: viewerID) }
    }

    private func handle(_ event: BotComputerEvent) {
        switch event.name {
        case "connected":
            isConnected = true
            reconnectAttempts = 0
            errorText = nil
        case "disconnected":
            // The socket died (host restart, spent ticket, viewer evicted). A silent retry keeps a
            // blip from ending the session; past that, say so rather than leave a black rectangle
            // standing in for a picture that is never coming.
            isLive = false
            isConnected = false
            socketURL = nil
            ticket = nil
            if reconnectAttempts < 2 {
                reconnectAttempts += 1
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                    await reopen()
                }
            } else {
                holdsControl = false
                errorText = "The stream stopped. Open the screen again to reconnect."
                loop += 1
            }
        case "error":
            // The page's own words: a spent ticket, a refused socket and a missing asset all look
            // like a black rectangle otherwise.
            errorText = event.message ?? "The viewer reported an error."
        default:
            break
        }
    }

    /// Put a failure where the user can read it — unless it is only a cancelled request, which is
    /// what a torn-down poll loop produces and never a fault of the host.
    private func report(_ error: Error) {
        guard let text = RequestOutcome.describe(error) else { return }
        errorText = text
    }
}
