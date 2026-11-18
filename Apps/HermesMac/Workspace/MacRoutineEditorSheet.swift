import SwiftUI
import HermesKit
import HermeyUI

/// The New Routine form, as a Mac panel.
///
/// The phone's form is a `List` of sections because that is how iOS draws a form. On the Mac the same
/// fields are a labelled column with the actions in a header row and Escape to cancel — the shape every
/// other panel in this app already uses (Skills, MCP, Model). The rule the Create button obeys is still
/// `RoutineDraft.problem`, the same sentence the bridge refuses with.
struct MacRoutineEditorSheet: View {
    let botName: String
    let deliveries: [RoutineDelivery]
    let create: (RoutineDraft) async throws -> BotRoutine

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RoutineDraft()
    @State private var skillsText = ""
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Name") {
                        TextField("Morning summary (optional)", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    whenSection
                    promptSection
                    deliverSection
                    advancedSection

                    if let problem = failure ?? draft.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(TypeScale.font(TypeScale.sm))
                            .foregroundStyle(problem == failure ? Tokens.danger : Tokens.textDim)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 620)
        .background(Tokens.canvas)
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(Tokens.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Routine")
                    .font(TypeScale.font(TypeScale.md, weight: .semibold))
                Text("For \(botName)")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("routine.cancel")
            Button("Create Routine") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isCreatable)
                .accessibilityIdentifier("routine.create")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            content()
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("When")
                .font(TypeScale.font(TypeScale.sm, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)

            HStack(spacing: 10) {
                Picker("", selection: $draft.schedule.mode) {
                    ForEach(RoutineScheduleMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                switch draft.schedule.mode {
                case .daily, .weekly, .monthly:
                    if draft.schedule.mode == .weekly {
                        Picker("", selection: $draft.schedule.weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(RoutineSchedule.weekdayName(day)).tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                    if draft.schedule.mode == .monthly {
                        Picker("", selection: $draft.schedule.dayOfMonth) {
                            ForEach(1...28, id: \.self) { day in
                                Text(RoutineSchedule.ordinal(day)).tag(day)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    DatePicker("", selection: clockBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 100)

                case .repeating:
                    Stepper(value: $draft.schedule.repeatCount, in: 1...1440) {
                        Text("Every \(draft.schedule.repeatCount)")
                    }
                    .frame(width: 160)
                    Picker("", selection: $draft.schedule.repeatUnit) {
                        ForEach(RoutineSchedule.RepeatUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                case .once:
                    DatePicker("", selection: $draft.schedule.onceAt,
                               in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()

                case .custom:
                    TextField("0 9 * * * · every 2h · 2026-11-18T09:00:00", text: $draft.schedule.custom)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: TypeScale.sm, design: .monospaced))
                }

                Spacer(minLength: 0)
            }

            Text(draft.schedule.summary)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(Tokens.textSecondary)
        }
    }

    private var promptSection: some View {
        field("What should it do?") {
            TextEditor(text: $draft.prompt)
                .font(TypeScale.font(TypeScale.md))
                .frame(height: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .fill(Tokens.surface))
                .overlay(alignment: .topLeading) {
                    if draft.prompt.isEmpty {
                        Text("Every morning, check the weather and my calendar and send me a short summary of the day…")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textDim)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var deliverSection: some View {
        field("Send to") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: $draft.deliver) {
                    ForEach(deliveries) { delivery in
                        Text(delivery.label).tag(delivery.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)

                Text("Results are always kept in the routine's history too.")
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(Tokens.textDim)
            }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                field("Skills (comma separated)") {
                    TextField("skill-a, skill-b", text: $skillsText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: skillsText) { _, text in
                            draft.skills = text.split(separator: ",").map(String.init)
                        }
                }
                field("Script path on the host") {
                    TextField("~/.hermes/profiles/<bot>/scripts/audit.sh", text: $draft.script)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 8)
        }
        .font(TypeScale.font(TypeScale.sm))
    }

    /// A `Date` bound onto the two integers the schedule keeps, so the cron string is never parsed back.
    private var clockBinding: Binding<Date> {
        Binding(
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
        )
    }

    private func save() async {
        guard draft.isCreatable else { return }
        isSaving = true
        failure = nil
        do {
            _ = try await create(draft)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        isSaving = false
    }
}
