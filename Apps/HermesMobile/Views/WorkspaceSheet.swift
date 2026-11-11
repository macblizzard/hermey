import SwiftUI
import PDFKit
import HermesKit
import OpenBotUI

/// The bot's workspace, as a place to read rather than a place to manage.
///
/// Two sections, because there are two questions a person actually asks: *what did it make* and
/// *what did I send it*. Everything is one tap from a viewer; nothing here can rename, move or delete,
/// so a stray drag cannot tidy away a document the bot is still working on.
struct WorkspaceSheet: View {
    let bot: Bot
    let client: WorkspaceClient
    @Environment(\.dismiss) private var dismiss

    @State private var listing: WorkspaceListing?
    @State private var failure: String?
    @State private var isLoading = true

    private var written: [WorkspaceFile] {
        (listing?.files ?? []).filter(\.isFromBot)
    }

    private var sent: [WorkspaceFile] {
        (listing?.files ?? []).filter { !$0.isFromBot }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure {
                    ContentUnavailableView {
                        Label("Couldn't read the workspace", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else if (listing?.files ?? []).isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: "folder")
                    } description: {
                        Text("Documents \(bot.displayName) prepares land here, and so does anything you send it.")
                    }
                } else {
                    fileList
                }
            }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh workspace")
                }
            }
        }
        .task { await load() }
    }

    private var fileList: some View {
        List {
            if !written.isEmpty {
                Section("Written by \(bot.displayName)") {
                    ForEach(written) { file in row(file) }
                }
            }
            if !sent.isEmpty {
                Section("You sent") {
                    ForEach(sent) { file in row(file) }
                }
            }
            if listing?.truncated == true {
                Section {
                    Text("Showing the most recent \(listing?.files.count ?? 0) files.")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func row(_ file: WorkspaceFile) -> some View {
        NavigationLink {
            WorkspaceDocumentView(file: file, profile: bot.id, client: client)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.symbolName)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Tokens.accentText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(TypeScale.font(TypeScale.md, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(file.sizeDescription) · \(file.whenText())")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                }
                Spacer(minLength: 0)
                if !file.previewable {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textSecondary)
                        .accessibilityLabel("No preview")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func load() async {
        isLoading = listing == nil
        failure = nil
        do {
            listing = try await client.list(profile: bot.id)
        } catch let error as WorkspaceError {
            failure = error.errorDescription
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}

/// One document. Text is text, a PDF is a PDF, an image is an image, and anything else says so plainly
/// instead of pretending to render it.
struct WorkspaceDocumentView: View {
    let file: WorkspaceFile
    let profile: String
    let client: WorkspaceClient

    @State private var bytes: Data?
    @State private var contentType: String?
    @State private var failure: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't open this", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
            } else if let bytes {
                content(bytes)
            } else {
                ContentUnavailableView("Nothing to show", systemImage: "doc")
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func content(_ data: Data) -> some View {
        if file.isPDF, let document = PDFDocument(data: data) {
            PDFViewer(document: document)
                .ignoresSafeArea(edges: .bottom)
        } else if file.isImage, let image = UIImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            }
        } else if let text = String(data: data, encoding: .utf8), file.isText {
            ScrollView {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            // The honest answer for a `.docx`: it is in the workspace, and this app cannot lay it out.
            ContentUnavailableView {
                Label("No preview for this kind of file", systemImage: "doc")
            } description: {
                Text("\(file.sizeDescription) · open it on the host, or ask \(profile) to convert it to PDF.")
            }
        }
    }

    private func load() async {
        guard file.previewable || file.isText else { isLoading = false; return }
        do {
            let result = try await client.data(profile: profile, file: file)
            bytes = result.bytes
            contentType = result.contentType
        } catch let error as WorkspaceError {
            failure = error.errorDescription
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}

/// PDFKit, wrapped: `PDFView` is a UIKit view and does not scroll correctly unless it is allowed to
/// own its own layout.
private struct PDFViewer: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
