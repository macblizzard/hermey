#if os(iOS)
import SwiftUI
import UIKit

/// The whole share sheet, drawn with system colours and no design-system dependency.
///
/// An extension is a second, much smaller binary embedded in the app; pulling `HermeyUI` and its
/// catalogs in for one 430 pt card would double its launch cost for a screen shown for three
/// seconds. What it must do is look native, because iOS puts its chrome around ours.
struct ShareRootView: View {
    @ObservedObject var composer: ShareComposer
    var items: [NSExtensionItem]
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                preview
                if let error = composer.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                destinations
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .navigationTitle("Send to Hermey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if composer.isSending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task { await composer.send() }
                        }
                        .disabled(!composer.canSend)
                    }
                }
            }
            .task { await composer.prepare(items: items) }
        }
    }

    // MARK: - What is being shared

    private var preview: some View {
        HStack(alignment: .top, spacing: 12) {
            if !composer.draft.images.isEmpty {
                thumbnails
            }
            VStack(alignment: .leading, spacing: 4) {
                if composer.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading…").foregroundStyle(.secondary)
                    }
                } else {
                    if let text = composer.draft.text, !text.isEmpty {
                        Text(text)
                            .font(.callout)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let link = composer.draft.urlString, let host = URL(string: link)?.host {
                        // The scheme and path are noise in a 430 pt sheet; the host is the identity.
                        Label(host, systemImage: "link")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if composer.draft.text == nil && composer.draft.urlString == nil {
                        if let file = composer.draft.files.first {
                            Label(file.originalName ?? "File", systemImage: "doc")
                                .font(.callout)
                                .lineLimit(2)
                            Text(ShareImportIssue.size(file.byteCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Attachment")
                                .font(.callout)
                        }
                    }
                    if !composer.draft.isEmpty, let issues = composer.draft.issueSummary {
                        // One line per refused item, naming it and why — the importer's sentence,
                        // never a count of items the sheet could not identify. When nothing at all
                        // was carried the same sentence is already the red line above; this is for
                        // the partial case, so a share of three files cannot hide a fourth.
                        Text(issues)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thumbnails: some View {
        HStack(spacing: 6) {
            ForEach(composer.draft.images.prefix(2)) { image in
                if let picture = thumbnail(for: image) {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel("Image to share")
                }
            }
            if composer.draft.images.count > 2 {
                Text("+\(composer.draft.images.count - 2)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Read back from the container, not from a provider: the bytes were copied there before this
    /// view was drawn, which is also the only reason they survive the sheet closing.
    private func thumbnail(for attachment: ShareAttachment) -> UIImage? {
        guard let url = composer.storage.url(for: attachment, payloadID: composer.payloadID) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Where it goes

    private var destinations: some View {
        Group {
            if let notice = composer.notice {
                VStack(alignment: .leading, spacing: 10) {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Send stays disabled while there is no destination — a share has to go
                    // somewhere real. Reload re-reads the snapshot, so a person who opened the app
                    // (or fixed the signing) mid-share does not have to pick the item again.
                    Button {
                        composer.reloadBots()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Reads the bot list Hermey left for this sheet again.")
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(composer.bots) { bot in
                            if bot.id != composer.bots.first?.id { Divider() }
                            row(for: bot)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(for bot: ShareBot) -> some View {
        Button {
            composer.selectedBotID = bot.id
        } label: {
            HStack(spacing: 12) {
                Text(bot.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if composer.selectedBotID == bot.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.displayName)
        .accessibilityAddTraits(composer.selectedBotID == bot.id ? [.isSelected] : [])
    }
}
#endif
