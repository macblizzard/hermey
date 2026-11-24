import Combine
import Foundation
import HermesKit
import SwiftUI

/// What a file row is doing right now.
///
/// The three live states are the whole point of the row: a file the host has not written yet is
/// *not* an error, and saying "could not open" about a document a bot announced a second ago would
/// be a lie the person has to argue with. `notReady` is the quiet fourth state.
public enum AttachmentFileStatus: Equatable, Sendable {
    case ready
    case loading
    case notReady
    case failed(String)

    /// The state a thrown fetch deserves. A 404 is `notReady`; everything else carries its words.
    public static func forError(_ error: Error) -> AttachmentFileStatus {
        if let fetch = error as? AttachmentFetchError, fetch.isNotReady { return .notReady }
        return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}

/// One file in a conversation, drawn as a row rather than a blob.
///
/// A picture is its own thumbnail; a document cannot be. So a PDF, a Word file, a spreadsheet — and
/// any bot-made file — is a row: the type's SF Symbol, the file's own name, its size when known, and
/// a press that opens it. The row owns the look only: what "open" means (Quick Look on the Mac, the
/// share sheet on the phone) belongs to the app that shows it.
public struct AttachmentFileRow: View {
    public let name: String
    public let kind: AttachmentKind
    /// Bytes, when the sender or the host told us. `nil` shows the type's own word instead of a
    /// made-up size.
    public let size: Int?
    public let status: AttachmentFileStatus
    /// The whole row is the target: a press opens the file (or tries again).
    public let onOpen: () -> Void
    /// The explicit retry the `notReady` state offers.
    public let onRetry: () -> Void

    @State private var isHovered = false

    public init(name: String,
                kind: AttachmentKind,
                size: Int? = nil,
                status: AttachmentFileStatus = .ready,
                onOpen: @escaping () -> Void,
                onRetry: (() -> Void)? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.status = status
        self.onOpen = onOpen
        self.onRetry = onRetry ?? onOpen
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(status == .notReady ? Tokens.textMuted : Tokens.accentText)
                .frame(width: 30, height: 30)
                .background(Tokens.control, in: RoundedRectangle(cornerRadius: Tokens.radiusSmall,
                                                                  style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(TypeScale.font(Tokens.textSM, weight: .medium))
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(TypeScale.font(TypeScale.caption))
                    .foregroundStyle(Tokens.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            trailing
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .fill(Tokens.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusControl, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .help("Open \(name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attached file \(name)")
        .accessibilityValue(Text(detail))
        .accessibilityHint(status == .notReady ? "The file is not on the host yet. Retry." : "Opens the file")
        .accessibilityAddTraits(.isButton)
    }

    /// The second line: the size when it is known, otherwise the type's word, and — when the host
    /// has not written the file yet — that fact, in the same quiet register.
    private var detail: String {
        if status == .notReady { return "Not there yet — tap to retry" }
        if case let .failed(reason) = status { return reason }
        if let size, size > 0 {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return kind.displayName
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
        case .notReady:
            Button(action: onRetry) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Retry")
                        .font(TypeScale.font(TypeScale.caption, weight: .semibold))
                }
                .foregroundStyle(Tokens.accentText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Tokens.control, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry opening \(name)")
            .hermeyFocusQuiet()
        case .failed, .ready:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isHovered ? Tokens.textSecondary : Tokens.textMuted)
        }
    }
}

/// Opens files for every row of one transcript.
///
/// Held by the transcript rather than by a row: a row inside a `LazyVStack` is torn down the moment
/// it scrolls out, and its "loading" or "not ready" state would go with it. One coordinator also
/// means one file is fetched once, no matter how many rows name it.
@MainActor
public final class AttachmentOpenCoordinator: ObservableObject {
    @Published public private(set) var states: [AttachmentLocation: AttachmentFileStatus] = [:]

    /// The fetch: a cached or downloaded local file for a location. The app supplies it, because the
    /// model that owns the bearer belongs to the app.
    public var loader: (@MainActor (AttachmentLocation) async throws -> URL)?

    /// What to do with the file once it is here: Quick Look on the Mac, the share sheet on iOS.
    public var present: (@MainActor (URL) -> Void)?

    public init() {}

    public func status(for location: AttachmentLocation) -> AttachmentFileStatus {
        states[location] ?? .ready
    }

    /// Fetch (or reuse) the file and hand it to the platform viewer.
    ///
    /// A second press while a fetch is in the air is ignored: two Quick Look windows for one file
    /// is not what a double click means.
    public func open(_ location: AttachmentLocation) {
        guard states[location] != .loading else { return }
        states[location] = .loading
        Task { [weak self] in
            guard let self else { return }
            guard let loader = self.loader else {
                self.states[location] = .failed(AttachmentFetchError.notConfigured.localizedDescription)
                return
            }
            do {
                let url = try await loader(location)
                self.states[location] = .ready
                self.present?(url)
            } catch {
                self.states[location] = AttachmentFileStatus.forError(error)
            }
        }
    }
}
