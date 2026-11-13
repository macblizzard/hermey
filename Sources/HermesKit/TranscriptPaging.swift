import Foundation

/// Keeping the pages a reader walked back to when a resume replaces the transcript.
///
/// A resume only ever carries the *newest* page — the bridge pages it, because one multi-megabyte
/// frame is a message iOS refuses to deliver. So replacing the transcript wholesale throws away
/// every earlier page the reader had loaded, and the next reconnect puts them back at the fold with
/// nothing above it: "load earlier" then looks like it does nothing at all, because the page it
/// fetched was wiped seconds later.
public enum TranscriptPaging {
    /// The incoming page, with whatever older rows the app already held spliced in front of it.
    ///
    /// The join is the incoming page's first row: everything the app holds *before* that row is
    /// older history and is kept; everything from that row on is replaced by the host's own copy,
    /// so a row can never appear twice and an edited row can never stay stale. When the two pages
    /// do not overlap at all, the incoming page wins — that is a different conversation, or the
    /// same one resumed after a rewind.
    ///
    /// - Returns: the merged rows, and the cursor for the oldest row on screen. Keeping older rows
    ///   keeps the old cursor, because it names the offset of *those* rows, not of the new page.
    public static func merge(keeping old: [TranscriptEntry],
                             incoming: [TranscriptEntry],
                             incomingCursor: Int?,
                             oldCursor: Int?) -> (entries: [TranscriptEntry], cursor: Int?) {
        guard !old.isEmpty, let first = incoming.first else { return (incoming, incomingCursor) }
        guard let join = old.firstIndex(where: { $0.id == first.id }) else {
            return (incoming, incomingCursor)
        }
        guard join > 0 else { return (incoming, incomingCursor) }
        return (Array(old[0..<join]) + incoming, oldCursor)
    }
}
