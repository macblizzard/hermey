import SwiftUI
import HermesKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Settings → View log.
///
/// The app's own memory of what it did and where it failed, in the one place a user can reach it
/// after a screen only told them "something went wrong". It is deliberately plain: a monospaced
/// list, oldest first, with errors marked — because the reader is either scanning for the failure's
/// clock time or copying the whole thing into a message.
///
/// Shared by both apps so the same log reads the same way on a phone and on the Mac (the Mac's
/// Settings window shows it in a sheet from the About tab).
public struct ClientLogView: View {
    private let title: String
    private let header: String

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ClientLogEntry] = []
    @State private var copied = false
    @State private var confirmingClear = false

    /// - Parameters:
    ///   - title: the sheet's title.
    ///   - header: the context line above the log (build, platform, host, connection state).
    public init(title: String = "Log", header: String = "") {
        self.title = title
        self.header = header
    }

    public var body: some View {
        // The one modifier the two platforms spell differently, kept out of the chain: an
        // `.inline` bar title is iOS-only, and `#if` inside a modifier chain is a compile risk
        // that is not worth a title's height.
        #if os(iOS)
        sheetBody.navigationBarTitleDisplayMode(.inline)
        #else
        sheetBody
        #endif
    }

    private var sheetBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !header.isEmpty {
                    Text(header)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Tokens.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Tokens.surface)
                        .textSelection(.enabled)
                    Hairline(color: Tokens.border)
                }

                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(Tokens.textDim)
                        Text("Nothing logged yet")
                            .font(TypeScale.font(TypeScale.lg, weight: .medium))
                            .foregroundStyle(Tokens.textPrimary)
                        Text("The app writes here when it connects, fails, retries or loses a message — so the next problem leaves a trail.")
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                Text(entry.line)
                                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                    .foregroundStyle(tint(entry.level))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(Tokens.canvas)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .font(TypeScale.font(TypeScale.md))
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        copy()
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(entries.isEmpty)

                    ShareLink(item: text()) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(entries.isEmpty)

                    Button {
                        confirmingClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog("Clear this log?", isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("Clear log", role: .destructive) {
                    ClientLog.shared.clear()
                    reload()
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("The entries are deleted from this device. Nothing on the host changes.")
            }
            .task { reload() }
        }
    }

    private func tint(_ level: ClientLogLevel) -> Color {
        switch level {
        case .info: return Tokens.textSecondary
        case .warning: return Tokens.warning
        case .error: return Tokens.danger
        }
    }

    private func text() -> String {
        var out = header.isEmpty ? "" : header + "\n\n"
        out += ClientLog.shared.text()
        return out
    }

    private func reload() {
        entries = ClientLog.shared.snapshot()
    }

    private func copy() {
        ClientLog.shared.flushNow()
        #if os(iOS)
        UIPasteboard.general.string = text()
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(), forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}

#if DEBUG
#Preview("Log") {
    ClientLogView(header: "Hermey 0.1.63 (build 63)\niOS 18.2 · host: casa · direct")
        .preferredColorScheme(.dark)
}
#endif
