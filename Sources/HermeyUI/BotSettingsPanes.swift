import HermesKit
import SwiftUI
import UniformTypeIdentifiers

/// The two roster-wide settings the owner asked for on 2026-11-15: the soul a new bot starts from,
/// and a JSON copy of every bot's configuration that can rebuild the roster on a fresh install.

/// The default soul: one text, on the host, with Hermes's own as the fallback.
public struct DefaultSoulPane: View {
    private let builtIn: String?
    private let present: Bool
    private let isBusy: Bool
    private let save: (String) async -> String?
    private let onChange: () async -> Void

    @State private var text: String
    @State private var status: String?
    @State private var working = false

    public init(current: String,
                builtIn: String?,
                present: Bool,
                isBusy: Bool = false,
                save: @escaping (String) async -> String?,
                onChange: @escaping () async -> Void) {
        self.builtIn = builtIn
        self.present = present
        self.isBusy = isBusy
        self.save = save
        self.onChange = onChange
        _text = State(initialValue: current)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What a new bot starts from")
                .font(TypeScale.font(TypeScale.md, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text(present
                 ? "Every bot you create begins with this. Existing bots keep their own soul."
                 : "Nothing set, so a new bot begins with Hermes's default instructions.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(TypeScale.font(TypeScale.md))
                .foregroundStyle(Tokens.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .fill(Tokens.surface))
                .overlay(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .stroke(Tokens.border, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(builtIn.map { "Hermes's default:\n\($0.prefix(160))…" }
                             ?? "Type the instructions a new bot should start with.")
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                Button {
                    Task { await commit(reset: false) }
                } label: {
                    Text("Save")
                        .font(TypeScale.font(TypeScale.md, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(working || isBusy || text.isEmpty)

                Button {
                    Task { await commit(reset: true) }
                } label: {
                    Text("Reset to Hermes's default")
                        .font(TypeScale.font(TypeScale.md))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textMuted)
                .disabled(working || isBusy || !present)

                Spacer(minLength: 0)

                Text("\(text.count)")
                    .font(TypeScale.font(Tokens.rosterMeta))
                    .foregroundStyle(Tokens.textDim)
                    .monospacedDigit()
            }

            if let status {
                Text(status)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func commit(reset: Bool) async {
        working = true
        defer { working = false }
        let outgoing = reset ? "" : text
        if let failure = await save(outgoing) {
            status = failure
            return
        }
        if reset { text = "" }
        status = reset ? "Back to Hermes's default." : "Saved. New bots start from this."
        await onChange()
    }
}

/// A JSON copy of every bot's config — name, description, soul, memory, notes, routines — and the
/// way back in. Deliberately no conversations: this rebuilds a roster, it does not replay history.
public struct BackupPane: View {
    private let botCount: Int
    private let export: () async -> Data?
    private let preview: (Data, BotImportMode) async -> (BackupImportResult?, String?)
    private let apply: (Data, BotImportMode) async -> (BackupImportResult?, String?)

    @State private var exporting = false
    @State private var importing = false
    @State private var document: BackupFile?
    @State private var status: String?
    @State private var writing = false

    @State private var picked: Data?
    @State private var plan: BackupImportResult?
    @State private var mode: BotImportMode = .merge
    @State private var confirming = false

    public init(botCount: Int,
                export: @escaping () async -> Data?,
                preview: @escaping (Data, BotImportMode) async -> (BackupImportResult?, String?),
                apply: @escaping (Data, BotImportMode) async -> (BackupImportResult?, String?)) {
        self.botCount = botCount
        self.export = export
        self.preview = preview
        self.apply = apply
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Back up your bots")
                .font(TypeScale.font(TypeScale.md, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("\(botCount) bot\(botCount == 1 ? "" : "s") — name, description, soul, memory, notes and routines. Conversations are not included: this is for setting up a fresh Hermes install.")
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await startExport() }
                } label: {
                    Text(writing ? "Reading…" : "Export…")
                        .font(TypeScale.font(TypeScale.md, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accent)
                .disabled(writing)

                Button {
                    importing = true
                } label: {
                    Text("Import…")
                        .font(TypeScale.font(TypeScale.md))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textMuted)
                .disabled(writing)

                Spacer(minLength: 0)
            }

            if let status {
                Text(status)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .fileExporter(isPresented: $exporting,
                      document: document,
                      contentType: .json,
                      defaultFilename: "hermey-bots") { result in
            if case .failure(let error) = result {
                status = "Could not write the file: \(error.localizedDescription)"
            } else {
                status = "Saved."
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.json, .zip]) { result in
            Task { await runImport(result) }
        }
        // The plan is shown before anything is written: an import that silently created, replaced or skipped
        // bots is the one thing this screen must never do.
        .confirmationDialog("Import these bots?", isPresented: $confirming, titleVisibility: .visible) {
            ForEach(BotImportMode.allCases) { option in
                Button(option.title) { Task { await applyPicked(option) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(plan.map { "\($0.preview). Pick how to treat bots that already exist here." }
                 ?? "Reading the file…")
        }
    }

    private func startExport() async {
        writing = true
        defer { writing = false }
        guard let data = await export() else {
            status = "The host did not answer with a backup."
            return
        }
        document = BackupFile(data: data)
        exporting = true
    }

    private func runImport(_ result: Result<URL, Error>) async {
        switch result {
        case .failure(let error):
            status = "Could not read that file: \(error.localizedDescription)"
        case .success(let url):
            // A file the owner picked outside the app's container: the access is scoped, and short.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                picked = data
                writing = true
                let (outcome, failure) = await preview(data, mode)
                writing = false
                if let failure {
                    status = failure
                    return
                }
                guard let outcome else {
                    status = "The host did not answer."
                    return
                }
                plan = outcome
                confirming = true
            } catch {
                status = "Could not read that file: \(error.localizedDescription)"
            }
        }
    }

    private func applyPicked(_ chosen: BotImportMode) async {
        guard let file = picked else { return }
        writing = true
        defer { writing = false }
        let (outcome, failure) = await apply(file, chosen)
        if let failure {
            status = failure
            return
        }
        guard let outcome else {
            status = "The host did not answer."
            return
        }
        status = summary(outcome)
    }

    /// What to tell the owner: what was made, what was left alone, and that routines need a restart.
    private func summary(_ outcome: BackupImportResult) -> String {
        var parts: [String] = []
        if !outcome.created.isEmpty {
            parts.append("created \(outcome.created.map(\.profile).joined(separator: ", "))")
        }
        if !outcome.updated.isEmpty {
            parts.append("filled in \(outcome.updated.count) bot\(outcome.updated.count == 1 ? "" : "s")")
        }
        if outcome.skipped.isEmpty == false {
            parts.append("skipped \(outcome.skipped.count)")
        }
        if outcome.icons.isEmpty == false {
            parts.append("restored \(outcome.icons.count) icon\(outcome.icons.count == 1 ? "" : "s")")
        }
        if parts.isEmpty { parts.append("nothing to change — every bot here already has its own copy") }
        if outcome.restartRequired {
            parts.append("restart the host for the restored routines to run")
        }
        let sentence = parts.joined(separator: "; ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }
}

/// A tiny file document wrapper: the export is bytes the app already has.
public struct BackupFile: FileDocument {
    public static var readableContentTypes: [UTType] { [.zip, .json] }
    public var data: Data

    public init(data: Data = Data()) { self.data = data }

    public init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
