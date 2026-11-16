import SwiftUI
import HermesKit

/// What a run of tool calls says about itself.
///
/// The wording lives here rather than in each app so the Mac and the phone cannot disagree about
/// whether a run is "Running 12 commands…" or "Ran 12 commands", and so the plural is decided once.
public enum ToolRunSummary {
    public static func title(count: Int, isRunning: Bool, failures: Int = 0) -> String {
        var line: String
        if isRunning {
            line = count == 1 ? "Running a command…" : "Running \(count) commands…"
        } else {
            line = count == 1 ? "Ran 1 command" : "Ran \(count) commands"
        }
        if failures > 0 {
            line += " · \(failures) failed"
        }
        return line
    }

    /// A call whose result reported a non-zero exit or an error. Read from the result only: the
    /// arguments of a `bash` call are not a failure just because they mention one.
    public static func failures(in run: ToolRun) -> Int {
        run.entries.filter { ToolPayload.failed(raw: $0.tool?.content) }.count
    }
}

/// One line for a run of tool calls, with the cards behind a disclosure.
///
/// A turn can make thirty calls, and thirty cards push the answer off the screen. The run is one
/// quiet row — how many, whether it is still going, how many failed — and opening it shows the
/// calls, each of which is still its own card with its own disclosure. The row keeps its state
/// while the run grows, because the run's id is its first call.
public struct ToolRunGroup<Row: View>: View {
    private let run: ToolRun
    private let row: (TranscriptEntry) -> Row

    @State private var expanded = false
    @State private var hovering = false

    public init(run: ToolRun, @ViewBuilder row: @escaping (TranscriptEntry) -> Row) {
        self.run = run
        self.row = row
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(run.entries) { entry in
                        row(entry)
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var header: some View {
        let failures = ToolRunSummary.failures(in: run)
        let title = ToolRunSummary.title(count: run.count, isRunning: run.isRunning,
                                        failures: failures)
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(Tokens.textDim)
                Text(title)
                    .font(TypeScale.font(TypeScale.sm))
                    .foregroundStyle(failures > 0 ? Tokens.warning : Tokens.textSecondary)
                    .lineLimit(1)
                if run.isRunning {
                    // A dot rather than a spinner: the run is one line among many, and a spinner
                    // per turn draws the eye to the least important thing on screen.
                    Circle()
                        .fill(Tokens.accent)
                        .frame(width: 5, height: 5)
                        .opacity(0.9)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous)
                    .fill(Tokens.surface.opacity(hovering || expanded ? 0.85 : 0.5))
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(expanded ? "Hides the calls" : "Shows the calls")
        .accessibilityAddTraits(.isButton)
    }
}
