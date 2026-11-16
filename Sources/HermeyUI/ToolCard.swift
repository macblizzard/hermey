import Foundation
import SwiftUI

/// A tool call in the transcript: what ran, how long it took, and what it printed.
///
/// The header is the whole interaction — it toggles the body and it is the only
/// accessible element when collapsed. Long output starts collapsed (over 12 lines, per
/// the spec) because a tool that prints a thousand lines must not push the answer off the
/// screen. The 12-line rule lives in one place, `shouldStartExpanded`, so a screen cannot
/// decide differently.
public struct ToolCard: View {
    public enum Status: Equatable {
        case running
        case done
        case failed

        var word: String {
            switch self {
            case .running: return "running"
            case .done: return "done"
            case .failed: return "failed"
            }
        }

        var tint: Color {
            switch self {
            case .running: return Tokens.accent
            case .done: return Tokens.success
            case .failed: return Tokens.danger
            }
        }

        var soft: Color {
            switch self {
            case .running: return Tokens.accentSoft
            case .done: return Tokens.successSoft
            case .failed: return Tokens.dangerSoft
            }
        }
    }

    private let name: String
    private let summary: String?
    private let status: Status
    private let output: String?
    private let durationMS: Int?
    private let exitCode: Int?
    private let stdoutLines: Int?
    private let workingDirectory: String?

    @State private var expanded: Bool

    public init(name: String,
                summary: String? = nil,
                status: Status = .running,
                output: String? = nil,
                durationMS: Int? = nil,
                exitCode: Int? = nil,
                stdoutLines: Int? = nil,
                workingDirectory: String? = nil,
                startsExpanded: Bool? = nil) {
        self.name = name
        self.summary = summary
        self.status = status
        self.output = output
        self.durationMS = durationMS
        self.exitCode = exitCode
        self.stdoutLines = stdoutLines
        self.workingDirectory = workingDirectory
        _expanded = State(initialValue: startsExpanded ?? ToolCard.shouldStartExpanded(output))
    }

    /// Collapsed when there is nothing to read or more than a screenful to read.
    public static func shouldStartExpanded(_ output: String?) -> Bool {
        guard let output, !output.isEmpty else { return false }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines <= 12
    }

    /// The expanded body, made readable.
    ///
    /// A `terminal` call arrives as JSON — `{"command": "…", "timeout": 180}` — and rendering that
    /// verbatim buries the one thing the reader wants under escaped quotes, doubled backslashes and
    /// a payload field nobody reads. The command is extracted and shown as the shell line it was
    /// typed as. Every other tool keeps its arguments as they arrived: a `patch` call's paths and
    /// hunks read fine as JSON.
    public static func readableCall(name: String, raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        guard ["terminal", "bash", "shell"].contains(name.lowercased()) else { return raw }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return raw }
        return command
    }

    /// `toolComplete(ok:)` maps straight onto the card's three states.
    public static func status(ok: Bool) -> Status {
        ok ? .done : .failed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if expanded {
                Hairline()
                outputBody
                    .transition(.opacity)
            }
        }
        .cardSurface()
        .animation(Motion.toolCard, value: expanded)
    }

    // MARK: Header

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                statusGlyph

                Text(name)
                    .font(Tokens.mono)
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(Tokens.mono)
                        .foregroundStyle(Tokens.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let durationText {
                    Text(durationText)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.textDim)
                        .fixedSize()
                }

                DisclosureGlyph(expanded: expanded)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(expanded ? "Collapse tool output" : "Expand tool output")
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch status {
        case .running:
            SpinningRing(color: Tokens.accent, size: 11, lineWidth: 1.5)
                .frame(width: 14, height: 14)
        case .done, .failed:
            ZStack {
                Circle().fill(status.soft)
                Image(systemName: status == .done ? "checkmark" : "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(status.tint)
            }
            .frame(width: 14, height: 14)
        }
    }

    // MARK: Body

    private var outputBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolBodyView(text: outputText,
                         font: Tokens.mono,
                         color: Tokens.textSecondary,
                         gutterColor: Tokens.textMuted)
                .foregroundStyle(output == nil || output?.isEmpty == true ? Tokens.textDim : Tokens.textSecondary)
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                        .fill(Tokens.sheetInset)
                )
                .padding(.horizontal, 10)
                .padding(.top, 10)

            if hasFooter {
                footer
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            } else {
                Color.clear.frame(height: 2)
            }
        }
    }

    private var outputText: String {
        guard let output, !output.isEmpty else {
            return status == .running ? "Waiting for output…" : "No output."
        }
        // A stored JSON result becomes the text inside it; a call whose arguments were all there
        // was becomes the command; anything else is shown as it arrived.
        if let body = ToolPayload.info(raw: output)?.body, !body.isEmpty { return body }
        return Self.readableCall(name: name, raw: output)
    }

    /// Footer facts: whatever the caller measured, plus what the payload itself admits to (an exit
    /// status, a line count) — a card that showed neither said nothing about a command that failed.
    private var resolvedExitCode: Int? { exitCode ?? ToolPayload.info(raw: output)?.exitCode }
    private var resolvedStdoutLines: Int? { stdoutLines ?? ToolPayload.info(raw: output)?.lineCount }

    private var hasFooter: Bool {
        resolvedExitCode != nil || resolvedStdoutLines != nil || (workingDirectory?.isEmpty == false)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let exitCode = resolvedExitCode {
                Text("exit \(exitCode)")
                    .foregroundStyle(exitCode == 0 ? Tokens.textDim : Tokens.danger)
                if resolvedStdoutLines != nil || workingDirectory?.isEmpty == false {
                    separator
                }
            }

            if let stdoutLines = resolvedStdoutLines {
                Text(stdoutLines == 1 ? "1 line" : "\(stdoutLines) lines")
                    .foregroundStyle(Tokens.textDim)
                if workingDirectory?.isEmpty == false {
                    separator
                }
            }

            if let workingDirectory, !workingDirectory.isEmpty {
                Text(workingDirectory)
                    .foregroundStyle(Tokens.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private var separator: some View {
        Text("·").foregroundStyle(Tokens.textDim)
    }

    // MARK: Values

    private var durationText: String? {
        guard let durationMS else { return nil }
        if durationMS < 1_000 { return "\(max(0, durationMS)) ms" }
        let seconds = Double(durationMS) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        let rest = whole % 60
        return rest == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(rest)s"
    }

    private var accessibilityText: String {
        var parts = ["Tool", name, status.word]
        if let durationText { parts.append(durationText) }
        return parts.joined(separator: ", ")
    }

    private func toggle() {
        withAnimation(Motion.toolCard) { expanded.toggle() }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Tool card · running") {
    ToolCard(name: "bash",
             summary: "pytest -q tests/",
             status: .running,
             output: "collected 214 items\n.....\n",
             durationMS: 820)
        .frame(width: 520)
        .padding(20)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Tool card · done, collapsed") {
    ToolCard(name: "read_file",
             summary: "Sources/HermesKit/GatewayClient.swift",
             status: .done,
             output: (1...40).map { "line \($0): ok" }.joined(separator: "\n"),
             durationMS: 12_400,
             exitCode: 0,
             stdoutLines: 40,
             workingDirectory: "~/jobs/hermey")
        .frame(width: 520)
        .padding(20)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Tool card · failed") {
    ToolCard(name: "bash",
             summary: "swift build",
             status: .failed,
             output: "error: no such module 'HermesKit'\n",
             durationMS: 3_100,
             exitCode: 1,
             stdoutLines: 1,
             workingDirectory: "~/jobs/hermey",
             startsExpanded: true)
        .frame(width: 520)
        .padding(20)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
#endif
