import SwiftUI
import HermesKit

/// The New Routine form: what a bot should do on its own, and when.
///
/// The shape follows the official app's form, because the fields are the host's own nouns: a name, a
/// schedule, "what should it do?", where the result goes, and — behind Advanced — the two other
/// things a routine can carry instead of a prompt (a skill, a script). The rule the button obeys is
/// `RoutineDraft.problem`, which is the same sentence the bridge refuses with, so the form and the
/// server cannot disagree about what is missing.
///
/// Nothing here talks to the host: the sheet collects a draft and hands it back, and the caller that
/// opened it owns the request. That keeps this view previewable and keeps the failure message next to
/// the list that has to show it.
public struct RoutineEditorSheet: View {
    private let botName: String
    /// Where the result can go: Nowhere, the default bot chat, and one entry per bot. Passed in rather
    /// than read from a model, so the form stays previewable and cannot show a target that does not exist.
    private let deliveries: [RoutineDelivery]
    private let create: (RoutineDraft) async throws -> BotRoutine

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RoutineDraft()
    @State private var skillsText = ""
    @State private var isSaving = false
    @State private var failure: String?

    public init(botName: String,
                deliveries: [RoutineDelivery] = [.local, .defaultBotChat],
                create: @escaping (RoutineDraft) async throws -> BotRoutine) {
        self.botName = botName
        self.deliveries = deliveries
        self.create = create
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Morning summary (optional)", text: $draft.name)
                        .font(TypeScale.font(TypeScale.md))
                        .literalTextEntry()
                        .accessibilityIdentifier("routine.name")
                }

                Section {
                    scheduleControls
                    Text(draft.schedule.summary)
                        .font(TypeScale.font(TypeScale.sm))
                        .foregroundStyle(Tokens.textSecondary)
                        .accessibilityIdentifier("routine.summary")
                } header: {
                    Text("When")
                } footer: {
                    Text("Times are this phone's clock; the host resolves them in the profile's timezone.")
                        .font(TypeScale.font(TypeScale.sm))
                }

                Section("What should it do?") {
                    // A prompt is long-form text, so it gets a real box rather than a one-line field.
                    // The placeholder is drawn over it because `TextEditor` has none of its own.
                    ZStack(alignment: .topLeading) {
                        if draft.prompt.isEmpty {
                            Text("Every morning, check the weather and my calendar and send me a short summary of the day…")
                                .font(TypeScale.font(TypeScale.md))
                                .foregroundStyle(Tokens.textDim)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $draft.prompt)
                            .font(TypeScale.font(TypeScale.md))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .accessibilityIdentifier("routine.prompt")
                    }
                }

                Section {
                    Picker("Send to", selection: $draft.deliver) {
                        ForEach(deliveries) { delivery in
                            Text(delivery.label).tag(delivery.value)
                        }
                    }
                    .font(TypeScale.font(TypeScale.md))
                    .accessibilityIdentifier("routine.deliver")
                    .hermeyFocusQuiet()
                } footer: {
                    Text("Results are always kept in the routine's history too.")
                        .font(TypeScale.font(TypeScale.sm))
                }

                Section("Advanced") {
                    TextField("Skills, comma separated", text: $skillsText)
                        .font(TypeScale.font(TypeScale.sm))
                        .literalTextEntry()
                        .onChange(of: skillsText) { _, text in
                            draft.skills = text.split(separator: ",").map(String.init)
                        }
                        .accessibilityIdentifier("routine.skills")

                    TextField("Script path on the host", text: $draft.script)
                        .font(TypeScale.font(TypeScale.sm))
                        .literalTextEntry()
                        .accessibilityIdentifier("routine.script")
                }

                if let problem = failure ?? draft.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(problem == failure ? Tokens.danger : Tokens.textDim)
                            .accessibilityIdentifier("routine.problem")
                    }
                }
            }
            .navigationTitle("New Routine")
            .inlineSheetTitle()
            .background(Tokens.canvas)
            // A Mac sheet sizes itself to its content and a `List` has no intrinsic height, so without
            // this the "New Routine" modal opened blank — the rows were all there, drawn into a sheet
            // with no room. `sheetSizing` is the one place in this module that floor is set.
            .sheetSizing(minWidth: 520, minHeight: 560)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                    .hermeyFocusQuiet()
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create Routine") { Task { await save() } }
                            .disabled(!draft.isCreatable)
                            .accessibilityIdentifier("routine.create")
                            .hermeyFocusQuiet()
                    }
                }
            }
        }
    }

    // MARK: - When

    @ViewBuilder
    private var scheduleControls: some View {
        Picker("Repeat", selection: $draft.schedule.mode) {
            ForEach(RoutineScheduleMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("routine.mode")
        .hermeyFocusQuiet()

        switch draft.schedule.mode {
        case .daily, .weekly, .monthly:
            if draft.schedule.mode == .weekly {
                Picker("Day", selection: $draft.schedule.weekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(RoutineSchedule.weekdayName(day)).tag(day)
                    }
                }
                .hermeyFocusQuiet()
            }
            if draft.schedule.mode == .monthly {
                Picker("Day", selection: $draft.schedule.dayOfMonth) {
                    ForEach(1...28, id: \.self) { day in
                        Text(RoutineSchedule.ordinal(day)).tag(day)
                    }
                }
                .hermeyFocusQuiet()
            }
            timePicker

        case .repeating:
            Stepper(value: $draft.schedule.repeatCount, in: 1...1440) {
                Text("Every \(draft.schedule.repeatCount) \(draft.schedule.repeatUnit.label.lowercased())")
                    .font(TypeScale.font(TypeScale.md))
            }
            .hermeyFocusQuiet()
            Picker("Unit", selection: $draft.schedule.repeatUnit) {
                ForEach(RoutineSchedule.RepeatUnit.allCases) { unit in
                    Text(unit.label).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .hermeyFocusQuiet()

        case .once:
            DatePicker("Time", selection: $draft.schedule.onceAt,
                       in: Date()..., displayedComponents: [.date, .hourAndMinute])

        case .custom:
            TextField("0 9 * * * · every 2h · 2026-11-18T09:00:00", text: $draft.schedule.custom)
                .font(.system(size: TypeScale.sm, design: .monospaced))
                .literalTextEntry()
                .accessibilityIdentifier("routine.custom")
        }
    }

    /// One clock control shared by daily, weekly and monthly: a `Date` bound onto the two integers the
    /// schedule actually keeps, so the cron string never has to be parsed back into a time.
    private var timePicker: some View {
        DatePicker("Time", selection: Binding(
            get: {
                var components = DateComponents()
                components.hour = draft.schedule.hour
                components.minute = draft.schedule.minute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.schedule.hour = parts.hour ?? 9
                draft.schedule.minute = parts.minute ?? 0
            }
        ), displayedComponents: .hourAndMinute)
        .accessibilityIdentifier("routine.time")
    }

    // MARK: - Saving

    private func save() async {
        guard draft.isCreatable else { return }
        isSaving = true
        failure = nil
        do {
            _ = try await create(draft)
            dismiss()
        } catch {
            // The host's refusal replaces the form's own hint: it knows which field it disliked
            // (an unparseable schedule, an unknown timezone) and this view does not.
            failure = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Platform spellings

private extension View {
    /// Routine text is host data — a skill name, a script path, a cron expression — so it gets no
    /// autocapitalisation and no autocorrection. Both spellings are iOS-only, and a `#if` inside a
    /// modifier chain is the compile risk this file otherwise avoids; one helper, two platforms.
    @ViewBuilder
    func literalTextEntry() -> some View {
        #if os(iOS)
        self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

