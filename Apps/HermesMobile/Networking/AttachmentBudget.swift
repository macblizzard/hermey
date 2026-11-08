import Foundation

/// How many bytes one attachment may cost, and what to do with the ones that do not fit.
///
/// Foundation-only on purpose: this file is compiled into the app *and* into a plain
/// SwiftPM test target so the arithmetic, the name rules and the downscaling ladder can
/// be pinned on Linux without a simulator.
///
/// The host's own limits are bigger than ours (`_ATTACH_BYTES_MAX_BYTES` is 25 MiB,
/// `_ATTACHMENT_MAX_BYTES` 256 MiB, the bridge's `MAX_ATTACHMENT_BYTES` is now 8 MiB), but
/// every byte we send is base64 inside one JSON-RPC frame on the paired websocket. Two
/// frame ceilings sit on that path and the *smaller* one decides:
///
///  * the gateway's `server.py`, which needs `ws_max_size` above 16 MiB for `file.attach`;
///  * the bridge's `HERMES_BRIDGE_FRAME_CAP` (`Bridge/hermes_bridge/config.py`), whose
///    hard maximum is 8 MiB and whose default is 1 MiB. 8 MiB of payload is ~10.7 MiB of
///    base64, so the bridge cap must be raised to at least `requiredBridgeFrameBytes`
///    (see `attachment_validation.py` / the deployment note) before this limit is usable.
///
/// Raise the client limit only together with both frame caps.
public enum AttachmentBudget {
    /// Decoded (pre-base64) ceiling for a single attachment.
    public static let maximumBytes = 8 * 1024 * 1024
    /// The gateway's websocket frame ceiling for `file.attach`.
    public static let gatewayFrameBytes = 16 * 1024 * 1024
    public static let maximumNameBytes = 255

    /// The smallest `HERMES_BRIDGE_FRAME_CAP` that still carries one maximum-size
    /// attachment as a single base64 frame, with room for the JSON around it.
    public static var requiredBridgeFrameBytes: Int {
        base64EncodedByteCount(for: maximumBytes) + 128 * 1024
    }

    /// Base64 is four bytes per three, rounded up to a whole group.
    public static func base64EncodedByteCount(for decodedBytes: Int) -> Int {
        guard decodedBytes > 0 else { return 0 }
        return ((decodedBytes + 2) / 3) * 4
    }

    public static func fits(_ byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumBytes
    }

    /// True when the base64 form of `decodedBytes` still fits one gateway frame.
    public static func fitsInFrame(_ decodedBytes: Int) -> Bool {
        base64EncodedByteCount(for: decodedBytes) <= gatewayFrameBytes
    }

    public static func validate(byteCount: Int) throws {
        if byteCount <= 0 { throw AttachmentBudgetError.empty }
        guard byteCount <= maximumBytes else {
            throw AttachmentBudgetError.tooLarge(byteCount: byteCount, maximumBytes: maximumBytes)
        }
    }

    /// Whole units for exact divisions ("8 MB"), one decimal otherwise ("1.5 KB").
    public static func humanSize(_ bytes: Int) -> String {
        let megabyte = 1024 * 1024
        let kilobyte = 1024
        if bytes >= megabyte {
            if bytes % megabyte == 0 { return "\(bytes / megabyte) MB" }
            return trimTrailingZero(String(format: "%.1f", Double(bytes) / Double(megabyte))) + " MB"
        }
        if bytes >= kilobyte {
            if bytes % kilobyte == 0 { return "\(bytes / kilobyte) KB" }
            return trimTrailingZero(String(format: "%.1f", Double(bytes) / Double(kilobyte))) + " KB"
        }
        return "\(bytes) bytes"
    }

    private static func trimTrailingZero(_ text: String) -> String {
        guard text.hasSuffix(".0") else { return text }
        return String(text.dropLast(2))
    }
}

public enum AttachmentBudgetError: Error, LocalizedError, Equatable {
    case empty
    case tooLarge(byteCount: Int, maximumBytes: Int)
    case invalidName
    case unsupportedFile
    case unreadableFile

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "That file is empty."
        case .tooLarge(_, let maximumBytes):
            return "That attachment is larger than the \(AttachmentBudget.humanSize(maximumBytes)) limit."
        case .invalidName:
            return "That file name cannot be sent."
        case .unsupportedFile:
            return "That file type cannot be attached."
        case .unreadableFile:
            return "That file could not be opened."
        }
    }
}

/// File names travel into a JSON-RPC parameter and onto the host's disk, so they are
/// reduced to a single safe component here instead of being validated in three places.
public enum AttachmentName {
    /// Returns a sendable name, or `nil` when nothing salvageable is left.
    ///
    /// - Takes the last path component: a provider URL can carry directories.
    /// - Drops control characters and path separators rather than escaping them.
    /// - Collapses whitespace runs, because a name is rendered in a capsule in the composer.
    /// - Caps the UTF-8 length at 255 bytes while keeping the extension, so the host still
    ///   knows what the file is when it looks at the suffix.
    public static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let component: String
        if let lastSlash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            component = String(trimmed[trimmed.index(after: lastSlash)...])
        } else {
            component = trimmed
        }

        var cleaned = String()
        cleaned.reserveCapacity(component.count)
        var lastWasSpace = false
        for scalar in component.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F { continue }        // control characters
            if scalar == "/" || scalar == "\\" { continue }      // path separators
            let isSpace = scalar == " " || scalar == "\t"
            if isSpace {
                if lastWasSpace { continue }
                lastWasSpace = true
                cleaned.unicodeScalars.append(" ")
                continue
            }
            lastWasSpace = false
            cleaned.unicodeScalars.append(scalar)
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return truncate(cleaned, toUTF8Bytes: AttachmentBudget.maximumNameBytes)
    }

    /// Keeps the extension intact when the stem has to lose bytes.
    private static func truncate(_ name: String, toUTF8Bytes maximum: Int) -> String {
        guard name.utf8.count > maximum else { return name }
        let ext = extensionOf(name)
        let extWithDot = ext.isEmpty ? "" : "." + ext
        // A pathological extension cannot eat the whole name.
        let extBytes = extWithDot.utf8.count
        guard extBytes < maximum - 8 else {
            return fallbackPrefix(name, bytes: maximum)
        }
        let stemBudget = maximum - extBytes
        var stem = String()
        for character in name.dropLast(extWithDot.count) {
            if stem.utf8.count + character.utf8.count > stemBudget { break }
            stem.append(character)
        }
        let result = stem + extWithDot
        return result.isEmpty ? fallbackPrefix(name, bytes: maximum) : result
    }

    private static func fallbackPrefix(_ name: String, bytes maximum: Int) -> String {
        var out = String()
        for character in name {
            if out.utf8.count + character.utf8.count > maximum { break }
            out.append(character)
        }
        return out
    }

    private static func extensionOf(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let ext = String(name[name.index(after: dot)...])
        // A "extension" with spaces or another dot is noise, not a type.
        guard !ext.isEmpty, ext.count <= 16,
              ext.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !ext.contains(".") else { return "" }
        return ext
    }
}

/// One rung of the re-encode ladder: shrink to `maxPixelDimension` on the long edge and
/// encode at `quality`. `maxPixelDimension == 0` means "do not resize, only re-encode".
public struct ImageDownscaleStep: Equatable, Sendable {
    public let maxPixelDimension: Int
    public let quality: Double

    public init(maxPixelDimension: Int, quality: Double) {
        self.maxPixelDimension = maxPixelDimension
        self.quality = quality
    }
}

/// The decision half of image downscaling; the encoding half lives in `AttachmentImageEncoder`
/// because it needs UIKit. Keeping the ladder here makes it provable without a device:
/// a photo that already fits is never touched, and everything else walks down from its own
/// long edge through a fixed set of dimensions and qualities.
public enum ImageDownscale {
    /// Native captures are ~4032 px on the long edge. A photo re-encoded below 1024 px is
    /// too soft to be worth sending, so the ladder stops there.
    public static let dimensionLadder = [2048, 1600, 1280, 1024]
    public static let qualityLadder = [0.8, 0.6, 0.4]
    /// Deliberately pessimistic JPEG estimate (bytes per pixel at quality 1.0): it is only
    /// used to skip rungs that cannot possibly fit, so over-guessing costs quality, never a
    /// rejected frame.
    public static let bytesPerPixelAtFullQuality = 0.2
    /// Never hand the encoder more than this many attempts.
    public static let maximumSteps = 8

    public static func estimatedJPEGBytes(maxPixelDimension: Int, quality: Double) -> Int {
        guard maxPixelDimension > 0, quality > 0 else { return 0 }
        let pixels = Double(maxPixelDimension) * Double(maxPixelDimension)
        return Int(pixels * bytesPerPixelAtFullQuality * quality)
    }

    /// Empty means "send the original bytes": it already fits, so no pixel is re-encoded.
    /// Non-empty is an ordered ladder — the first rung whose encoded size fits wins.
    public static func steps(decodedBytes: Int,
                             pixelWidth: Int,
                             pixelHeight: Int,
                             limit: Int = AttachmentBudget.maximumBytes) -> [ImageDownscaleStep] {
        guard limit > 0 else { return [] }
        if decodedBytes > 0, decodedBytes <= limit { return [] }

        let longEdge = max(pixelWidth, pixelHeight)
        guard longEdge > 0 else {
            // Geometry unknown: re-encode at native size and let quality do the work.
            return qualityLadder.map { ImageDownscaleStep(maxPixelDimension: 0, quality: $0) }
        }

        let dimensions = [longEdge] + dimensionLadder.filter { $0 < longEdge }
        var ladder: [ImageDownscaleStep] = []
        for dimension in dimensions {
            for quality in qualityLadder {
                ladder.append(ImageDownscaleStep(maxPixelDimension: dimension, quality: quality))
            }
        }

        // Skip rungs that arithmetic already rules out; keep one last resort if all are out.
        let budget = Int(Double(limit) * 0.9)
        let plausible = ladder.filter {
            $0.maxPixelDimension == 0 || estimatedJPEGBytes(maxPixelDimension: $0.maxPixelDimension,
                                                            quality: $0.quality) <= budget
        }
        if plausible.isEmpty { return [ladder[ladder.count - 1]] }
        return Array(plausible.prefix(maximumSteps))
    }

    public static func needsReencoding(decodedBytes: Int,
                                       pixelWidth: Int,
                                       pixelHeight: Int,
                                       limit: Int = AttachmentBudget.maximumBytes) -> Bool {
        !steps(decodedBytes: decodedBytes, pixelWidth: pixelWidth, pixelHeight: pixelHeight, limit: limit).isEmpty
    }
}
