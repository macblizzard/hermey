import HermesKit
import SwiftUI

/// The exchanges between two bots, opened from the attribution line on a message one bot sent the
/// other (asked for 2026-11-15).
///
/// There is no separate "pair transcript" on the host — each side lives in that bot's own
/// conversation, and the message between them is a user row in the recipient's. What the bridge does
/// keep is the *record* of each exchange (`GET /v1/bot-transfers?between=a,b`), and that is what this
/// sheet draws: both directions, oldest first, with each sender's face.
public struct BotPairSheet: View {
    private let current: String
    private let peer: String
    private let faces: [String: BotFace]
    private let displayName: (String) -> String
    private let load: () async -> [BotTransfer]

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [BotTransfer] = []
    @State private var loading = true
    @State private var failure: String?

    public init(current: String,
                peer: String,
                faces: [String: BotFace] = [:],
                displayName: @escaping (String) -> String = { $0.capitalized },
                load: @escaping () async -> [BotTransfer]) {
        self.current = current
        self.peer = peer
        self.faces = faces
        self.displayName = displayName
        self.load = load
    }

    public var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 10) {
                        SpinningRing(color: Tokens.textMuted, size: 14, lineWidth: 1.5)
                        Text("Reading the exchange…")
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Tokens.textDim)
                        Text(failure)
                            .font(TypeScale.font(TypeScale.md))
                            .foregroundStyle(Tokens.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 22))
                            .foregroundStyle(Tokens.textDim)
                        Text("Nothing between these two yet")
                            .font(TypeScale.font(TypeScale.md, weight: .medium))
                            .foregroundStyle(Tokens.textPrimary)
                        Text("Messages one bot sends the other are recorded here from now on.")
                            .font(TypeScale.font(TypeScale.caption))
                            .foregroundStyle(Tokens.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries) { entry in
                        row(entry)
                            .listRowBackground(Tokens.canvas)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Tokens.canvas)
            .navigationTitle("\(displayName(current)) ⇄ \(displayName(peer))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .font(TypeScale.font(TypeScale.md))
                }
            }
            .task {
                entries = await load()
                loading = false
            }
        }
        .preferredColorScheme(.dark)
    }

    /// One turn of the exchange: whose turn it was, the words, and when.
    private func row(_ entry: BotTransfer) -> some View {
        let sender = entry.fromProfile ?? current
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                BotIconPortrait(faces[sender] ?? BotFace.default(for: sender),
                                size: Geometry.rosterAvatarCompact)
                Text(displayName(sender))
                    .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.textDim)
                Text(displayName(entry.toProfile))
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(RelativeTime.stamp(entry.at))
                    .font(TypeScale.font(Tokens.rosterMeta))
                    .foregroundStyle(Tokens.textDim)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Text(entry.text)
                .font(TypeScale.font(TypeScale.chatBody))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
