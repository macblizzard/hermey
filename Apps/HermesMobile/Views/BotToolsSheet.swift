import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// What a bot may reach for: its skills, and its MCP servers.
///
/// One sheet for both because the question is the same — *what does this bot have* — and the answer
/// differs only in what a row is called. A toggle is not cosmetic: it rewrites the bot's own config on
/// the host, so a switch here survives a relaunch, applies to the next turn, and applies to this bot
/// alone. The sheet says that much rather than leaving it to be discovered.
struct BotToolsSheet: View {
    enum Kind {
        case skills
        case mcp

        var title: String {
            switch self {
            case .skills: return "Skills"
            case .mcp: return "MCP servers"
            }
        }

        var symbol: String {
            switch self {
            case .skills: return "book.closed"
            case .mcp: return "puzzlepiece.extension"
            }
        }

        /// What "off" means. Never "hidden and still callable" — it is off.
        var explanation: String {
            switch self {
            case .skills:
                return "Skills are the instructions this bot can follow. Turning one off removes it from the bot's own index, so it cannot be reached by name either. Other bots keep theirs."
            case .mcp:
                return "MCP servers give this bot tools from outside Hermes. Turning one off stops it being started for this bot; the tools it provided disappear on the next turn."
            }
        }
    }

    let bot: Bot
    let kind: Kind
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var description: ProfileDescription?
    @State private var failure: String?
    @State private var busy: Set<String> = []
    @State private var isLoading = true

    private var skills: [ProfileSkill] { description?.skills ?? [] }
    private var servers: [ProfileMCPServer] { description?.mcpServers ?? [] }

    private var isEmpty: Bool {
        kind == .skills ? skills.isEmpty : servers.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure, description == nil {
                    ContentUnavailableView {
                        Label("Couldn't read this bot's \(kind.title.lowercased())", systemImage: kind.symbol)
                    } description: {
                        Text(failure)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else if isEmpty {
                    ContentUnavailableView {
                        Label("Nothing installed", systemImage: kind.symbol)
                    } description: {
                        Text(kind == .skills
                             ? "\(bot.displayName) has no skills of its own yet."
                             : "\(bot.displayName) has no MCP servers configured.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle(kind.title)
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
                    .accessibilityLabel("Refresh \(kind.title)")
                }
            }
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            Section {
                Text(kind.explanation)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if kind == .skills {
                    ForEach(skills) { skill in
                        toggle(title: skill.title,
                               detail: skill.name,
                               isOn: skill.enabled,
                               busy: busy.contains(skill.name)) { wanted in
                            await setSkill(skill, enabled: wanted)
                        }
                    }
                } else {
                    ForEach(servers) { server in
                        toggle(title: server.name,
                               detail: server.transport,
                               isOn: server.enabled,
                               busy: busy.contains(server.name)) { wanted in
                            await setServer(server, enabled: wanted)
                        }
                    }
                }
            } footer: {
                Text(kind == .skills
                     ? "\(skills.filter(\.enabled).count) of \(skills.count) on for this bot."
                     : "\(servers.filter(\.enabled).count) of \(servers.count) on for this bot.")
                    .font(TypeScale.font(TypeScale.sm))
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func toggle(title: String, detail: String, isOn: Bool, busy: Bool,
                        toggle action: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { wanted in
            Task { await action(wanted) }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                Text(detail)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
        }
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
    }

    private func setSkill(_ skill: ProfileSkill, enabled: Bool) async {
        guard let current = description else { return }
        // Optimistic: the switch moves now, and moves back if the host refuses.
        var next = current
        if let index = next.skills.firstIndex(where: { $0.name == skill.name }) {
            next.skills[index].enabled = enabled
        }
        description = next
        busy.insert(skill.name)
        failure = nil
        do {
            try await model.setSkill(skill.name, enabled: enabled, for: bot.id, using: current)
        } catch {
            description = current
            failure = error.localizedDescription
        }
        busy.remove(skill.name)
    }

    private func setServer(_ server: ProfileMCPServer, enabled: Bool) async {
        guard let current = description else { return }
        var next = current
        if let index = next.mcpServers.firstIndex(where: { $0.name == server.name }) {
            next.mcpServers[index].enabled = enabled
        }
        description = next
        busy.insert(server.name)
        failure = nil
        do {
            try await model.setMCPServer(server.name, enabled: enabled, for: bot.id, using: current)
        } catch {
            description = current
            failure = error.localizedDescription
        }
        busy.remove(server.name)
    }

    private func load() async {
        isLoading = description == nil
        failure = nil
        do {
            description = try await model.describeBot(bot.id)
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}
