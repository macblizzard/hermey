import SwiftUI

/// The full Hermes command list, in one sheet, reachable from `/help`.
///
/// The composer's popup only shows six matches while a `/word` is being typed. This is the whole
/// catalogue, searchable, with the same host-only marks and argument hints, so "what commands exist?"
/// has an answer in the app rather than a trip to the docs.
public struct HermesCommandsHelpSheet: View {
    public let onPick: (HermesCommand) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    public init(onPick: @escaping (HermesCommand) -> Void) {
        self.onPick = onPick
    }

    private var commands: [HermesCommand] {
        HermesCommandCatalogue.all.matching(query)
    }

    public var body: some View {
        NavigationStack {
            List {
                if commands.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                        Text("No command matches “\(query)”")
                            .font(TypeScale.font(TypeScale.sm))
                    }
                    .foregroundStyle(Tokens.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    Section("Commands") {
                        ForEach(commands) { command in
                            Button { onPick(command); dismiss() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: command.systemImage)
                                        .frame(width: 20)
                                        .foregroundStyle(Tokens.accentText)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text("/" + command.name)
                                                .font(TypeScale.font(TypeScale.sm, weight: .medium))
                                            if command.isHostCommand {
                                                Text("host")
                                                    .font(TypeScale.font(TypeScale.caption))
                                                    .foregroundStyle(Tokens.textDim)
                                            }
                                        }
                                        Text(command.detail)
                                            .font(TypeScale.font(TypeScale.caption))
                                            .foregroundStyle(Tokens.textMuted)
                                    }
                                    Spacer(minLength: 4)
                                    if let argument = command.argument {
                                        Text(argument)
                                            .font(TypeScale.font(TypeScale.caption))
                                            .foregroundStyle(Tokens.textDim)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a command")
            .navigationTitle("Hermes commands")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
