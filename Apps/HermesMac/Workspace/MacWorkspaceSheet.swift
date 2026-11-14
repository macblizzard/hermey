import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import HermesKit
import OpenBotUI

/// The bot's workspace on the Mac: the list on the left, the document on the right.
///
/// A sheet rather than a pane, because a document is something you open, read and close — the chat
/// beside it would only be in the way. Same read-only rule as the phone: nothing here renames, moves
/// or deletes, so a drag cannot tidy away a file a bot is still writing.
struct MacWorkspaceSheet: View {
    let bot: Bot
    let client: WorkspaceClient

    @Environment(\.dismiss) private var dismiss
    @State private var listing: WorkspaceListing?
    @State private var selection: WorkspaceFile.ID?
    @State private var failure: String?
    @State private var isLoading = true
    @State private var query = ""

    private var files: [WorkspaceFile] {
        let all = listing?.files ?? []
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var written: [WorkspaceFile] { files.filter(\.isFromBot) }
    private var sent: [WorkspaceFile] { files.filter { !$0.isFromBot } }

    private var selected: WorkspaceFile? {
        guard let selection else { return nil }
        return (listing?.files ?? []).first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure, listing == nil {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Tokens.textSecondary)
                    Text(failure).font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textSecondary)
                    Button("Try again") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    list.frame(minWidth: 240, idealWidth: 280)
                    viewer.frame(minWidth: 380)
                }
            }
        }
        .frame(width: 880, height: 560)
        .background(Tokens.canvas)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Library · \(bot.displayName)")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                Text("What it prepared, and what you sent it")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh the workspace")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var list: some View {
        List(selection: $selection) {
            if !written.isEmpty {
                Section("Written by \(bot.displayName)") {
                    ForEach(written) { file in
                        row(file).tag(file.id)
                    }
                }
            }
            if !sent.isEmpty {
                Section("You sent") {
                    ForEach(sent) { file in
                        row(file).tag(file.id)
                    }
                }
            }
            if files.isEmpty {
                Text(listing?.truncated == true ? "No match in the most recent files." : "Nothing here yet.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ file: WorkspaceFile) -> some View {
        HStack(spacing: 9) {
            Image(systemName: file.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(Tokens.accentText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.sizeDescription) · \(file.whenText())")
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
        .padding(.vertical, 2)
        .help(file.path)
    }

    @ViewBuilder
    private var viewer: some View {
        if let selected {
            MacWorkspaceDocumentView(file: selected, profile: bot.id, client: client)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Tokens.textSecondary)
                Text("Pick a document")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        isLoading = listing == nil
        failure = nil
        do {
            listing = try await client.list(profile: bot.id)
            if selection == nil { selection = listing?.files.first?.id }
        } catch let error as WorkspaceError {
            failure = error.errorDescription
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}

/// One document, rendered as what it is.
struct MacWorkspaceDocumentView: View {
    let file: WorkspaceFile
    let profile: String
    let client: WorkspaceClient

    @State private var bytes: Data?
    @State private var failure: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.name)
                    .font(TypeScale.font(TypeScale.sm, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(file.sizeDescription) · \(file.kind.uppercased())")
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textSecondary)
                // The phone hands the file to the share sheet; a Mac saves a copy, which is the same
                // gesture and the one a desktop actually offers. It fetches for itself, so it works
                // for a kind of file the viewer will not preview.
                Button("Save…") { saveToDisk() }
                    .font(TypeScale.font(TypeScale.sm))
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.accentText)
                    .fixedSize()
                    .help("Save a copy…")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            Divider()
            content
        }
        .task(id: file.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Tokens.textSecondary)
                Text(failure)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let bytes {
            rendered(bytes)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func rendered(_ data: Data) -> some View {
        if file.isPDF, let document = PDFDocument(data: data) {
            MacPDFView(document: document)
        } else if file.isImage, let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(12)
            }
        } else if file.isText, let text = String(data: data, encoding: .utf8) {
            ScrollView {
                Text(text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Tokens.textSecondary)
                Text("No preview for this kind of file")
                    .font(TypeScale.font(TypeScale.md))
                    .foregroundStyle(Tokens.textSecondary)
                Text("\(file.sizeDescription) · open it on the host, or ask \(profile) to convert it.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Write the document wherever the user picks, fetching it first when the viewer never needed
    /// the bytes (a `.zip`, a `.mov` — anything without a preview).
    private func saveToDisk() {
        Task {
            var data = bytes
            if data == nil {
                do { data = try await client.data(profile: profile, file: file).bytes }
                catch { failure = error.localizedDescription; return }
            }
            guard let data else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { failure = "could not write \(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    private func load() async {
        bytes = nil
        failure = nil
        guard file.previewable || file.isText else { isLoading = false; return }
        isLoading = true
        do {
            bytes = try await client.data(profile: profile, file: file).bytes
        } catch let error as WorkspaceError {
            failure = error.errorDescription
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}

/// `PDFView` on macOS, wrapped: it owns its own scrolling and zoom.
private struct MacPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
