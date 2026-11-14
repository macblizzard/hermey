import SwiftUI
import HermesKit

/// What a bot remembers, in its own two files.
///
/// This is the one part of a bot's behaviour no screen in either app showed until now: the transcript
/// says what it *said*, the soul says what it was *told to be*, and these two documents are what it
/// carries silently into every turn. Read-only by design — the agent maintains them with its own
/// memory tool, whose append-vs-replace rules the app does not model, and a text view in a viewer is
/// the wrong place to break them.
///
/// One view for both shells: the phone opens it from the bot page or the Edit sheet, the Mac from bot
/// settings.
public struct BotMemorySheet: View {
    private let botName: String
    private let load: () async throws -> BotMemory

    @Environment(\.dismiss) private var dismiss
    @State private var memory: BotMemory?
    @State private var failure: String?
    @State private var isLoading = true

    public init(botName: String, load: @escaping () async throws -> BotMemory) {
        self.botName = botName
        self.load = load
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
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh memory")
                }
            }
        }
        .task { await reload() }
    }

    private func documents(_ memory: BotMemory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Both files are injected into every turn this bot takes. They are the agent's own "
                     + "notes — written by its memory tool, not by this app.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if memory.isEmpty {
                    Label("Nothing remembered yet", systemImage: "brain")
                        .font(TypeScale.font(TypeScale.md))
                        .foregroundStyle(Tokens.textSecondary)
                }

                document(memory.memory)
                document(memory.user)

                if let failure {
                    Text(failure)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.danger)
                }
            }
            .padding(16)
        }
        .background(Tokens.canvas)
    }

    @ViewBuilder
    private func document(_ document: BotMemoryDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(document.name)
                    .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .monospaced()
                Spacer(minLength: 8)
                // The size is not decoration: this text is replayed into every turn, so its length is
                // the thing that costs context.
                if document.present {
                    Text(document.sizeText)
                        .font(TypeScale.font(TypeScale.micro))
                        .foregroundStyle(Tokens.textDim)
                        .monospacedDigit()
                }
            }

            if !document.label.isEmpty {
                Text(document.label)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textDim)
            }

            if let error = document.error {
                Text(error)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(document.present ? "The file is empty." : "No file yet — this bot has not saved "
                     + "anything here.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            } else {
                Text(document.text)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Tokens.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func reload() async {
        if memory == nil { isLoading = true }
        failure = nil
        do {
            memory = try await load()
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}
