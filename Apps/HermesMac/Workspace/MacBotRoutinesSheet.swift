import SwiftUI
import HermesKit
import HermeyUI

/// A bot's schedule, on the Mac: the same panel language as Skills and MCP.
///
/// The phone's sheet and this one answer the same question, but they are not the same window. The Mac's
/// menu items open fixed-size panels with a header row — icon, "Title · bot", a subtitle, the actions on
/// the right — and a plain `NavigationStack` around a `List` is the iOS idiom wearing a Mac window: no
/// header, different spacing, no Escape. Asked for on 2026-11-16 ("it doesnt match the other windows
/// like mcp or skills … and the routines window modal doesnt close with ESC").
///
/// Escape is `onExitCommand` rather than a keyboard shortcut on a button: it belongs to the window, not
/// to one control, so it works while a text field or the list has focus.
struct MacBotRoutinesSheet: View {
    let bot: Bot
    let load: () async throws -> [BotRoutine]
    let setPaused: (String, Bool) async throws -> Void
    let create: (RoutineDraft) async throws -> BotRoutine
    let deliveries: [RoutineDelivery]

    @Environment(\.dismiss) private var dismiss
    @State private var routines: [BotRoutine] = []
    @State private var isLoading = true
    @State private var failure: String?
    @State private var busyJobID: String?
    @State private var showNewRoutine = false

    private var runningCount: Int { routines.filter { !$0.paused && !$0.completed }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if routines.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(width: 560, height: 520)
        .background(Tokens.canvas)
        .onExitCommand { dismiss() }
        .task { await reload() }
        .sheet(isPresented: $showNewRoutine) {
            MacRoutineEditorSheet(botName: bot.displayName, deliveries: deliveries) { draft in
                let made = try await create(draft)
                // Re-read rather than append: `next_run_at` is the scheduler's answer.
                await reload()
                return made
            }
            .hermesSheetChrome()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Routines · \(bot.displayName)")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                Text(runningCount == 1 ? "1 running on the host" : "\(runningCount) running on the host")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            Button {
                showNewRoutine = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Add a routine")
            .accessibilityIdentifier("routines.add")
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reload from the host")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("routines.done")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Tokens.textSecondary)
            Text("\(bot.displayName) has nothing scheduled.")
                .font(TypeScale.font(TypeScale.md))
            Button("Add a routine") { showNewRoutine = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            Text("Routines are the jobs this bot runs on a schedule, on the host itself. A pause here "
                 + "survives a relaunch and applies to every device.")
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
                    ForEach(routines) { routine in
                        row(routine)
                    }
                }
            }
        }
    }

    private func row(_ routine: BotRoutine) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(routine.name)
                        .font(TypeScale.font(TypeScale.md, weight: .medium))
                        .lineLimit(1)
                    if routine.completed {
                        Text("FINISHED")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Tokens.textDim.opacity(0.16))
                            .foregroundStyle(Tokens.textDim)
                            .clipShape(Capsule())
                    }
                }
                Text(routine.schedule)
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                Text(routine.timingText())
                    .font(TypeScale.font(TypeScale.micro))
                    .foregroundStyle(routine.lastStatus?.lowercased().hasPrefix("fail") == true
                                     || routine.lastStatus?.lowercased() == "error"
                                     ? Tokens.danger : Tokens.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if routine.canToggle {
                if busyJobID == routine.id {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { !routine.paused },
                                             set: { wanted in
                                                 Task { await toggle(routine, paused: !wanted) }
                                             }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help(routine.paused ? "Paused — click to put back on its schedule"
                                         : "Running — click to pause")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func reload() async {
        if routines.isEmpty { isLoading = true }
        failure = nil
        do {
            routines = try await load()
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }

    private func toggle(_ routine: BotRoutine, paused: Bool) async {
        guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        busyJobID = routine.id
        failure = nil
        routines[index] = BotRoutine(id: routine.id, name: routine.name, schedule: routine.schedule,
                                     nextRunAt: routine.nextRunAt, lastRunAt: routine.lastRunAt,
                                     lastStatus: routine.lastStatus, lastError: routine.lastError,
                                     paused: paused, completed: routine.completed)
        do {
            try await setPaused(routine.id, paused)
        } catch {
            failure = error.localizedDescription
            await reload()
        }
        busyJobID = nil
    }
}
