import SwiftUI
import HermesKit

/// The three screens the owner asked for, written once for both apps.
///
/// Each takes closures rather than an `AppModel`: the phone and the Mac own their own model
/// instances and their own navigation, and a sheet that reached into a singleton would be the one
/// thing in this project the two apps could not share. The closures are `async throws` so a failure
/// on the host — a refused name, an unreachable bridge — lands in the sheet instead of vanishing.

// MARK: - Add a bot

/// Name, description, and a face.
///
/// The name is the profile name, which is also a directory name and a shell alias on the host, so
/// it is normalised here rather than rejected later by the host: lowercase, dashes, no spaces.
public struct AddBotSheet: View {
    private let onCreate: (String, String, BotFace?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var face: BotFace?
    @State private var busy = false
    @State private var failure: String?

    public init(onCreate: @escaping (String, String, BotFace?) async throws -> Void) {
        self.onCreate = onCreate
    }

    /// `Ada Lovelace!` → `ada-lovelace`. What the host accepts, decided before the round trip.
    private var normalised: String {
        let lowered = name.lowercased()
        let dashes = lowered.replacingOccurrences(of: " ", with: "-")
        let allowed = dashes.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String(allowed.prefix(64))
    }

    private var canCreate: Bool {
        guard let first = normalised.first else { return false }
        guard first.isLetter || first.isNumber else { return false }
        return normalised.count >= 2
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name", hint: normalised.isEmpty ? "lowercase, dashes, no spaces"
                                                          : "becomes \(normalised)") {
                        TextField("ops", text: $name)
                            .noAutoCapitalisation()
                            .autocorrectionDisabled()
                            .font(.system(size: TypeScale.md, design: .monospaced))
                    }

                    field("Description", hint: "the line under its name in the bot list") {
                        TextField("Chief of staff, runs the ops board", text: $description)
                            .lineLimit(2)
                    }

                    // Shape × colour, at the top, because the face is the first thing a person
                    // recognises in the list afterwards. No SOUL.md here: who the bot *is* is a
                    // long-form thing that belongs in the bot's own settings, next to its name and
                    // description, not in the way of creating it.
                    BotFacePicker(face: face) { face = $0 }

                    if let failure {
                        Text(failure)
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            .background(Tokens.canvas)
            .navigationTitle("Add bot")
            .inlineSheetTitle()
            .sheetSizing()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(!canCreate)
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, hint: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(TypeScale.font(TypeScale.sm, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                if let hint {
                    Text(hint)
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                }
            }
            content()
                .padding(10)
                .background(Tokens.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func create() async {
        busy = true
        failure = nil
        do {
            try await onCreate(normalised,
                               description.trimmingCharacters(in: .whitespacesAndNewlines),
                               face)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}

// MARK: - Manage bots

/// Hide, disable, or delete a bot.
///
/// The three verbs are deliberately different sizes: hiding is a local tap and instantly undone;
/// disabling pauses the bot's schedules on the host and is undone by the same switch; deleting is
/// final and asks for the bot's name typed back, because the host's delete cannot be undone from
/// the app.
public struct ManageBotsSheet: View {
    private let bots: [Bot]
    private let hidden: (String) -> Bool
    private let disabled: Set<String>
    private let onToggleHidden: (String) -> Void
    private let onToggleEnabled: (String, Bool) async throws -> Void
    private let onDelete: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirming: Bot?
    @State private var typedName = ""
    @State private var busy: String?
    @State private var failure: String?

    public init(bots: [Bot],
                hidden: @escaping (String) -> Bool,
                disabled: Set<String>,
                onToggleHidden: @escaping (String) -> Void,
                onToggleEnabled: @escaping (String, Bool) async throws -> Void,
                onDelete: @escaping (String) async throws -> Void) {
        self.bots = bots
        self.hidden = hidden
        self.disabled = disabled
        self.onToggleHidden = onToggleHidden
        self.onToggleEnabled = onToggleEnabled
        self.onDelete = onDelete
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(bots) { bot in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(bot.displayName)
                                .font(TypeScale.font(TypeScale.md, weight: .medium))
                                .foregroundStyle(Tokens.textPrimary)
                            if disabled.contains(bot.id) {
                                Text("OFF")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Tokens.warning.opacity(0.16))
                                    .foregroundStyle(Tokens.warning)
                                    .clipShape(Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                        if let described = bot.description, !described.isEmpty {
                            Text(described)
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textDim)
                                .lineLimit(2)
                        }
                        HStack(spacing: 14) {
                            Toggle(isOn: Binding(
                                get: { !hidden(bot.id) },
                                set: { _ in onToggleHidden(bot.id) }
                            )) {
                                Text("Visible").font(TypeScale.font(TypeScale.caption))
                            }
                            .labelsHidden()
                            Text(hidden(bot.id) ? "Hidden" : "Visible")
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textMuted)

                            Toggle(isOn: Binding(
                                get: { !disabled.contains(bot.id) },
                                set: { wanted in
                                    Task {
                                        busy = bot.id
                                        failure = nil
                                        do { try await onToggleEnabled(bot.id, wanted) }
                                        catch { failure = error.localizedDescription }
                                        busy = nil
                                    }
                                }
                            )) {
                                Text("Active").font(TypeScale.font(TypeScale.caption))
                            }
                            .labelsHidden()
                            Text(disabled.contains(bot.id) ? "Off" : "Active")
                                .font(TypeScale.font(TypeScale.caption))
                                .foregroundStyle(Tokens.textMuted)
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                typedName = ""
                                confirming = bot
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .font(TypeScale.font(TypeScale.caption))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.danger)
                        }
                        .disabled(busy == bot.id)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .background(Tokens.canvas)
            .navigationTitle("Manage bots")
            .inlineSheetTitle()
            .sheetSizing()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let failure {
                    Text(failure)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Tokens.surface)
                }
            }
            .alert("Delete \(confirming?.displayName ?? "this bot")?",
                   isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                TextField("type \(confirming?.id ?? "")", text: $typedName)
                Button("Cancel", role: .cancel) { confirming = nil }
                Button("Delete", role: .destructive) {
                    guard let bot = confirming else { return }
                    Task {
                        busy = bot.id
                        do {
                            try await onDelete(bot.id)
                            confirming = nil
                        } catch {
                            failure = error.localizedDescription
                        }
                        busy = nil
                    }
                }
                .disabled(typedName != (confirming?.id ?? ""))
            } message: {
                Text("The profile is removed from the host. A copy is kept on the server for a week.")
            }
        }
    }
}

// MARK: - SOUL.md

/// The bot's real `SOUL.md`, loaded from the host and written back to it.
///
/// A running conversation keeps the prompt it started with, so saving is not the same as the bot
/// behaving differently mid-thread. The footnote says that instead of letting the owner wonder.
public struct SoulEditorSheet: View {
    private let botName: String
    private let load: () async throws -> String
    private let save: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?

    public init(botName: String,
                load: @escaping () async throws -> String,
                save: @escaping (String) async throws -> Void) {
        self.botName = botName
        self.load = load
        self.save = save
    }

    private var dirty: Bool { text != original }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: TypeScale.sm, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(Tokens.canvas)
                    Text("Saved to the host. A conversation already open keeps the soul it started with until it is reset.")
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.surface)
                }
                if let failure {
                    Text(failure)
                        .font(TypeScale.font(TypeScale.caption))
                        .foregroundStyle(Tokens.danger)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("SOUL.md · \(botName)")
            .sheetSizing(minWidth: 560, minHeight: 520)
            .inlineSheetTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await commit() } }.disabled(!dirty || loading)
                    }
                }
            }
            .task {
                do {
                    let loaded = try await load()
                    text = loaded
                    original = loaded
                } catch {
                    failure = error.localizedDescription
                }
                loading = false
            }
        }
    }

    private func commit() async {
        saving = true
        failure = nil
        do {
            try await save(text)
            original = text
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        saving = false
    }
}
