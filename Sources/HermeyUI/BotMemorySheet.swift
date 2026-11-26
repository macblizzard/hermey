import SwiftUI
import HermesKit

/// What a bot remembers, in its own two files — and now, edited here.
///
/// This is the one part of a bot's behaviour no screen in either app showed until it existed: the
/// transcript says what it *said*, the soul says what it was *told to be*, and these two documents are
/// what it carries silently into every turn.
///
/// It shipped read-only, on the argument that the agent maintains these files with its own memory tool
/// and a viewer was the wrong place to break its rules. The owner's answer was that the rules were his
/// problem to manage: "edit memory option on bot settings of all bots". So this pane edits — but it
/// keeps the two things that made read-only defensible:
///
/// * **the runtime's budget is shown and enforced.** The count is the memory tool's own accounting
///   (`MemoryBudget.counted`), shown as `4,210 / 6,100 characters`, and a save that would exceed it is
///   refused with the limit and the overage in the sentence — never truncated.
/// * **a save is confirmed once**, and says what will happen: which file, and that the bot reads it on
///   its next turn.
///
/// One view for both shells: the phone opens it from the bot page or the Edit sheet, the Mac from bot
/// settings. A document is opened with `read` rather than from the list's copy, because the agent may
/// have written between the two.
public struct BotMemorySheet: View {
    private let botName: String
    private let access: BotMemoryAccess

    @Environment(\.dismiss) private var dismiss
    @State private var memory: BotMemory?
    @State private var failure: String?
    @State private var isLoading = true
    @State private var pending: BotMemoryDocument?

    public init(botName: String, access: BotMemoryAccess) {
        self.botName = botName
        self.access = access
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading, memory == nil {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure, memory == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "brain")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Tokens.textSecondary)
                        Text("Couldn't read \(botName)'s memory")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textPrimary)
                        Text(failure)
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await reload() } }
                        .hermeyFocusQuiet()
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let memory {
                    documents(memory)
                }
            }
            .navigationTitle("Memory")
            // Cross-platform on purpose: `navigationBarTitleDisplayMode` does not exist on macOS,
            // and this sheet is drawn by both shells.
            .inlineSheetTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                    .hermeyFocusQuiet()
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh memory")
                    .hermeyFocusQuiet()
                }
            }
        }
        .task { await reload() }
        .sheet(item: $pending) { document in
            BotMemoryEditor(
                botName: botName,
                document: document,
                read: access.read,
                save: { name, text in
                    let saved = try await access.save(name, text)
                    // The list behind the editor is now a copy of what it held a moment ago: re-read
                    // it so the row's count and edited time are the file's, not the editor's guess.
                    await reload()
                    return saved
                })
        }
    }

    private func documents(_ memory: BotMemory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Both files are replayed into every turn this bot takes. Edit one and the bot "
                     + "reads the new text on its next turn.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if memory.isEmpty {
                    Label("Nothing remembered yet", systemImage: "brain")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textSecondary)
                }

                row(memory.memory)
                row(memory.user)

                if let failure {
                    Text(failure)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // One quiet line, said once, on both shells: this text is not a private note to the
                // app — the bot reads it every turn and can repeat it in any conversation.
                Text("Anything written here is visible to \(botName) on every turn — secrets do not belong in it.")
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(Tokens.canvas)
    }

    /// One document, as a tappable row: its file name, its count against its budget, and when the
    /// agent last wrote it.
    private func row(_ document: BotMemoryDocument) -> some View {
        Button {
            pending = document
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(document.name)
                        .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                        .monospaced()

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textDim)
                }

                // The size is not decoration: this text is replayed into every turn, so its length
                // against the runtime's budget is the thing that costs context.
                Text(document.budgetText)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(document.chars > document.limit && document.limit > 0
                                     ? Tokens.danger : Tokens.textDim)
                    .monospacedDigit()

                HStack(spacing: 8) {
                    if !document.label.isEmpty {
                        Text(document.label)
                            .font(TypeScale.font(TypeScale.micro))
                            .foregroundStyle(Tokens.textDim)
                    }
                    if let edited = document.editedText {
                        Text("· \(edited)")
                            .font(TypeScale.font(TypeScale.micro))
                            .foregroundStyle(Tokens.textDim)
                    }
                }

                if let error = document.error {
                    Text(error)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !document.present {
                    Text("No file yet — opened empty; the first save creates it.")
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Tokens.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hermeyFocusQuiet()
        .accessibilityIdentifier("memoryRow-\(document.name)")
    }

    private func reload() async {
        if memory == nil { isLoading = true }
        failure = nil
        do {
            memory = try await access.load()
        } catch {
            // A host that cannot be reached is not a bot that remembers nothing: keep whatever list
            // this pane already holds and say why it could not be refreshed.
            failure = MemoryFailure.sentence(error)
        }
        isLoading = false
    }
}
