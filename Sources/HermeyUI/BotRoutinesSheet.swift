import SwiftUI
import HermesKit

/// What a bot does on its own: its routines, and a switch beside each one.
///
/// This is the phone's page and the Mac's sheet, one view, because the question is identical in both
/// shells — *what does this bot run without me, and is it still running* — and a feature that exists
/// on one platform only reads as a bug on the other.
///
/// Two rules the rows keep:
///
/// - The list is read from the host every time the sheet opens. A cached routine could say "every
///   day at 3am" about a job that was paused on the desktop last week, and the switch would then be
///   drawn in the wrong position — the one thing a switch must never be.
/// - A switch that fails puts itself back. `paused` is host state, so the row is flipped locally to
///   answer the finger immediately, then re-read from the host on failure rather than left showing a
///   change the scheduler never accepted.
public struct BotRoutinesSheet: View {
    private let botName: String
    private let load: () async throws -> [BotRoutine]
    private let setPaused: (String, Bool) async throws -> Void
    /// Creates one from the New Routine form. Nil closes the + button, for a shell that can read
    /// routines but cannot write them (a preview, or an older host).
    private let create: ((RoutineDraft) async throws -> BotRoutine)?
    /// The form's "Send to" choices, supplied by the shell that knows the roster.
    private let deliveries: [RoutineDelivery]

    @Environment(\.dismiss) private var dismiss
    @State private var routines: [BotRoutine] = []
    @State private var isLoading = true
    @State private var failure: String?
    @State private var busyJobID: String?
    @State private var showNewRoutine = false

    public init(botName: String,
                load: @escaping () async throws -> [BotRoutine],
                setPaused: @escaping (String, Bool) async throws -> Void,
                create: ((RoutineDraft) async throws -> BotRoutine)? = nil,
                deliveries: [RoutineDelivery] = [.local, .defaultBotChat]) {
        self.botName = botName
        self.load = load
        self.setPaused = setPaused
        self.create = create
        self.deliveries = deliveries
    }

    public var body: some View {
        NavigationStack {
            List {
                // What a routine is, once, in the sheet's own words: the switch below is a real
                // change to the host's scheduler, not a display filter.
                Section {
                    Text("Routines are the jobs this bot runs on a schedule, on the host itself. "
                         + "A pause here survives a relaunch and applies to every device.")
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                }

                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading \(botName)'s routines…")
                                .font(TypeScale.font(TypeScale.sm))
                                .foregroundStyle(Tokens.textDim)
                        }
                    }
                } else if routines.isEmpty, failure == nil {
                    Section {
                        Label("No routines", systemImage: "clock.arrow.circlepath")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textSecondary)
                        Text("\(botName) has nothing scheduled. Tap + to add one, or ask it in chat.")
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(Tokens.textDim)
                    }
                } else {
                    Section {
                        ForEach(routines) { routine in
                            row(routine)
                        }
                    } footer: {
                        if let failure {
                            Text(failure)
                                .font(TypeScale.font(TypeScale.sm))
                                .foregroundStyle(Tokens.danger)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(Tokens.canvas)
            .navigationTitle("Routines")
            .inlineSheetTitle()
            .sheetSizing()
            .toolbar {
                // The + sits beside the title, before Done — and both live in ONE toolbar item, as an
                // HStack. A `ToolbarItemGroup` whose first member is conditional is not portable: on
                // macOS the group collapsed to the member that existed, so the + replaced Done and the
                // sheet had no way out (reported 2026-11-16, force-quit required). One item, two
                // buttons, no placement left to the platform.
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        if let create {
                            Button {
                                showNewRoutine = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("Add routine")
                            .accessibilityIdentifier("routines.add")
                            .hermeyFocusQuiet()
                        }
                        // Done is unconditional: this sheet is reached from a drawer row on the phone and
                        // from a panel on the Mac, and neither has another way back.
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("routines.done")
                            .hermeyFocusQuiet()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh routines")
                    .hermeyFocusQuiet()
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showNewRoutine) {
            if let create {
                RoutineEditorSheet(botName: botName, deliveries: deliveries) { draft in
                    let made = try await create(draft)
                    // Re-read rather than append: the row the scheduler will actually fire carries a
                    // `next_run_at` only the host knows, and guessing at it puts a wrong time on
                    // screen that the next refresh then has to correct.
                    await reload()
                    return made
                }
                .hermesSheetChrome()
            }
        }
    }

    private func row(_ routine: BotRoutine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(routine.name)
                    .font(TypeScale.font(TypeScale.md, weight: .medium))
                    .foregroundStyle(Tokens.textPrimary)
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

                Spacer(minLength: 8)

                if routine.canToggle {
                    if busyJobID == routine.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { !routine.paused },
                            set: { wanted in
                                Task { await toggle(routine, paused: !wanted) }
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(routine.paused
                                            ? "Resume \(routine.name)"
                                            : "Pause \(routine.name)")
                        .hermeyFocusQuiet()
                    }
                }
            }

            Text(routine.schedule)
                .font(TypeScale.font(TypeScale.caption))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(routine.timingText())
                if let lastRun = routine.lastRunText() {
                    Text("·")
                    Text(lastRun)
                }
            }
            .font(TypeScale.font(TypeScale.micro))
            .foregroundStyle(routine.lastStatus?.lowercased().hasPrefix("fail") == true
                             || routine.lastStatus?.lowercased() == "error"
                             ? Tokens.danger : Tokens.textDim)
            .lineLimit(2)
        }
        .padding(.vertical, 4)
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

    /// Flip the row first — a switch that lags its own finger reads as broken — then let the host's
    /// answer stand, or re-read it when the host refused.
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
