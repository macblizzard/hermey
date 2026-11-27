import HermesKit
import SwiftUI

/// The agent's task checklist, pinned above the composer.
///
/// It lives here and not in the transcript on purpose: a long turn scrolls its own rows off the
/// top of the screen, and the one thing the owner asked to *always* see is how much of the job is
/// left. The phone and the desktop draw the same view; the shells only decide the inset.
///
/// Nothing is invented. The board is passed in whole, and the view draws nothing when there is no
/// board — a session without a `todo_list` has no strip, not an empty one.
public struct TaskChecklistView: View {

    public let board: TodoBoard

    /// What the person did, if anything. Nil means "follow the board": open while the agent says
    /// it is working, folded when it is not.
    @State private var overrideExpanded: Bool?

    public init(board: TodoBoard) {
        self.board = board
    }

    private var isExpanded: Bool { overrideExpanded ?? board.isActive }

    /// `Tasks 3/12`, and `· done` once nothing is left to run.
    private var title: String {
        var text = "Tasks \(board.counts.done)/\(board.counts.total)"
        if board.isComplete { text += " · done" }
        return text
    }

    public var body: some View {
        // A finished board leaves no trace: the strip exists to show what is left to run, and
        // once nothing is left it is only clutter above the composer. (`isComplete` is false
        // while anything is still pending or running, so this can't hide live work.)
        if board.isComplete {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                header
                if isExpanded {
                    Hairline(color: Tokens.border)
                    taskList
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Tokens.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Tokens.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(Motion.toolCard) {
                overrideExpanded = !isExpanded
            }
        } label: {
            HStack(spacing: 7) {
                if board.isActive {
                    PulsingDot()
                } else if board.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textSecondary)
                } else {
                    Image(systemName: "checklist")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textMuted)
                }

                Text(title)
                    .font(TypeScale.font(TypeScale.label, weight: .medium))
                    .foregroundStyle(board.isComplete ? Tokens.textSecondary : Tokens.textPrimary)
                    .monospacedDigit()

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hermeyFocusQuiet()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(isExpanded ? "Collapse the task list" : "Expand the task list")
    }

    private var accessibilityTitle: String {
        var text = "\(board.counts.done) of \(board.counts.total) tasks done"
        if board.counts.inProgress > 0 {
            text += ", \(board.counts.inProgress) in progress"
        }
        return text
    }

    // MARK: Rows

    /// Eight rows is the ceiling; past that the list scrolls in place rather than eating the
    /// conversation. The cap is on the drawn rows, so a collapsed strip is always one line.
    private static let visibleRowLimit = 8
    private static let rowHeight: CGFloat = 22

    private var taskList: some View {
        let rows = board.rows
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    taskRow(row)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
        }
        // Cap to the rows actually drawn — never `.infinity`. A ScrollView given no height ceiling
        // takes every point the pane offers, which is how an expanded strip swallowed the whole
        // phone screen for a two-row board.
        .frame(maxHeight: CGFloat(min(rows.count, Self.visibleRowLimit)) * Self.rowHeight + 10)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func taskRow(_ row: TodoBoard.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            TaskStatusGlyph(status: row.item.status)
                .frame(width: 12, height: 12)

            Text(row.item.content)
                .font(TypeScale.font(TypeScale.sm))
                .foregroundStyle(colour(for: row.item.status))
                .strikethrough(row.item.status == .cancelled, color: Tokens.textDim)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.rowHeight)
        // A subtask sits under its parent, one step in per level.
        .padding(.leading, CGFloat(row.depth) * 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.item.content), \(statusWord(row.item.status))")
    }

    private func colour(for status: TodoBoard.Status) -> Color {
        switch status {
        case .completed: return Tokens.textSecondary
        case .inProgress: return Tokens.textPrimary
        case .pending: return Tokens.textMuted
        case .cancelled: return Tokens.textDim
        }
    }

    private func statusWord(_ status: TodoBoard.Status) -> String {
        switch status {
        case .completed: return "completed"
        case .inProgress: return "in progress"
        case .pending: return "pending"
        case .cancelled: return "cancelled"
        }
    }
}

/// The four states, the way Codex/Claude draw them: a tick for done, a live dot for the item being
/// worked on, a hollow ring for what waits, and a struck-through line for what was dropped.
struct TaskStatusGlyph: View {
    let status: TodoBoard.Status

    var body: some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
        case .inProgress:
            PulsingDot()
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Tokens.textMuted)
        case .cancelled:
            Image(systemName: "circle")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Tokens.textDim)
        }
    }
}

/// The accent dot of an item that is being worked on — filled at rest, breathing while it runs.
struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(Tokens.accent)
            .frame(width: 7, height: 7)
            .scaleEffect(breathing && !reduceMotion ? 1.5 : 1)
            .opacity(breathing && !reduceMotion ? 0.55 : 1)
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: breathing)
            .onAppear {
                guard !reduceMotion else { return }
                breathing = true
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#if DEBUG
private struct TaskChecklistPreview: View {
    private func board(_ statuses: [TodoBoard.Status]) -> TodoBoard {
        TodoBoard(items: statuses.enumerated().map { index, status in
            TodoBoard.Item(id: "\(index)",
                           content: "Item \(index + 1) — a long task that runs past the edge of the strip",
                           status: status)
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            TaskChecklistView(board: board([.completed, .inProgress, .pending, .cancelled]))
            TaskChecklistView(board: board([.completed, .completed]))
            Spacer()
        }
        .padding()
        .frame(width: 420, height: 360, alignment: .top)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
    }
}

#Preview("Task checklist") {
    TaskChecklistPreview()
}
#endif
