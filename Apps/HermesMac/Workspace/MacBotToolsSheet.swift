import SwiftUI
import HermesKit
import HermesAppKit
import OpenBotUI

/// What a bot may reach for, on the Mac: its skills, or its MCP servers.
///
/// The same contract as the phone's sheet — one row per entry, a switch that writes the bot's own
/// config on the host, optimistic and reverted with the host's reason if it refuses — laid out as a
/// Mac panel: a single list, the explanation at the top, a count at the bottom.
struct MacBotToolsSheet: View {
    enum Kind {
        case skills
        case mcp

        var title: String { self == .skills ? "Skills" : "MCP servers" }
        var symbol: String { self == .skills ? "book.closed" : "puzzlepiece.extension" }

        var explanation: String {
            switch self {
            case .skills:
                return "Skills are the instructions this bot can follow. Turning one off removes it from this bot's own index, so it cannot be reached by name either. Other bots keep theirs."
            case .mcp:
                return "MCP servers give this bot tools from outside Hermes. Turning one off stops it being started for this bot; the tools it provided disappear on the next turn."
            }
        }
    }

    let bot: Bot
    let kind: Kind
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var described: ProfileDescription?
    @State private var failure: String?
    @State private var busy: Set<String> = []
    @State private var isLoading = true
    @State private var query = ""

    private var filteredSkills: [ProfileSkill] {
        let all = described?.skills ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filteredServers: [ProfileMCPServer] {
        let all = described?.mcpServers ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var enabledCount: Int {
        kind == .skills
            ? (described?.skills.filter(\.enabled).count ?? 0)
            : (described?.mcpServers.filter(\.enabled).count ?? 0)
    }

    private var totalCount: Int {
        kind == .skills ? (described?.skills.count ?? 0) : (described?.mcpServers.count ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure, described == nil {
                VStack(spacing: 12) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Tokens.textSecondary)
                    Text(failure)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                    Button("Try again") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(width: 560, height: 520)
        .background(Tokens.canvas)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(kind.title) · \(bot.displayName)")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                Text("\(enabledCount) of \(totalCount) on for this bot")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reload from the host")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var list: some View {
        VStack(spacing: 0) {
            Text(kind.explanation)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if kind == .skills {
                        ForEach(filteredSkills) { skill in
                            row(title: skill.title, detail: skill.name, isOn: skill.enabled,
                                busy: busy.contains(skill.name)) { wanted in
                                await setSkill(skill, enabled: wanted)
                            }
                        }
                    } else {
                        ForEach(filteredServers) { server in
                            row(title: server.name, detail: server.transport, isOn: server.enabled,
                                busy: busy.contains(server.name)) { wanted in
                                await setServer(server, enabled: wanted)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(title: String, detail: String, isOn: Bool, busy: Bool,
                     action: @escaping (Bool) async -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                Text(detail)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: { wanted in
                Task { await action(wanted) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
            .help(isOn ? "On for \(bot.displayName) — click to turn off" : "Off — click to turn on")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func setSkill(_ skill: ProfileSkill, enabled: Bool) async {
        guard let current = described else { return }
        var next = current
        if let index = next.skills.firstIndex(where: { $0.name == skill.name }) {
            next.skills[index].enabled = enabled
        }
        described = next
        busy.insert(skill.name)
        failure = nil
        do {
            try await model.setSkill(skill.name, enabled: enabled, for: bot.id, using: current)
        } catch {
            described = current
            failure = error.localizedDescription
        }
        busy.remove(skill.name)
    }

    private func setServer(_ server: ProfileMCPServer, enabled: Bool) async {
        guard let current = described else { return }
        var next = current
        if let index = next.mcpServers.firstIndex(where: { $0.name == server.name }) {
            next.mcpServers[index].enabled = enabled
        }
        described = next
        busy.insert(server.name)
        failure = nil
        do {
            try await model.setMCPServer(server.name, enabled: enabled, for: bot.id, using: current)
        } catch {
            described = current
            failure = error.localizedDescription
        }
        busy.remove(server.name)
    }

    private func load() async {
        isLoading = described == nil
        failure = nil
        do {
            var current = try await model.describeBot(bot.id)
            if kind == .skills {
                // `profiles.describe` only knows the bot's own folder; the hub's list is the real index.
                let available = Set(try await model.availableSkills(bot.id))
                var merged = current.skills
                let known = Set(merged.map(\.name))
                merged.append(contentsOf: available.subtracting(known).sorted()
                    .map { ProfileSkill(name: $0, enabled: true) })
                current.skills = merged
                    .map { ProfileSkill(name: $0.name, enabled: available.contains($0.name)) }
                    .sorted { $0.name < $1.name }
            }
            described = current
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}
