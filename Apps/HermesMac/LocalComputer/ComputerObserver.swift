import AppKit
import CoreGraphics
import Foundation

/// The image and window metadata returned by one `computer.observe` call.
struct ComputerObservation: Codable, Sendable {
    let frameID: String
    let capturedAt: Double
    let width: Int
    let height: Int
    let format: String
    let imageBase64: String
    let activeWindow: ComputerWindow?

    var byteCount: Int { imageBase64.count * 3 / 4 }
}

struct ComputerWindow: Codable, Sendable {
    let title: String
    let owner: String
    let bundleID: String?
    let bounds: [String: Double]
}

/// A still of the display at the requested moment.
///
/// CoreGraphics is used for the pixels: it is synchronous, has no stream/frame-handler lifecycle to
/// leak, and honours Screen Recording permission. ScreenCaptureKit-style window metadata comes from
/// CGWindowList, matched to the frontmost app. The image is downsampled and JPEG-encoded so a bot can
/// actually receive it over the socket without a multi-megabyte transfer.
private final class ComputerObserver {
    static let shared = ComputerObserver()
    private let maxDimension: CGFloat = 1600
    private let compression: CFTimeInterval = 0.7

    func observe() throws -> ComputerObservation {
        guard let raw = CGWindowListCreateImage(.null, [.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID, .bestResolution) else {
            throw ComputerPermissionError.missing(.screenRecording)
        }
        let scaled = downsample(raw)
        guard let bitmap = NSBitmapImageRep(cgImage: scaled),
              let jpeg = bitmap.representation(using: .jpeg,
                                               properties: [.compressionFactor: compression]) else {
            throw ObservationError.encodeFailed
        }
        return ComputerObservation(
            frameID: UUID().uuidString,
            capturedAt: Date().timeIntervalSince1970,
            width: scaled.width,
            height: scaled.height,
            format: "jpeg",
            imageBase64: jpeg.base64EncodedString(),
            activeWindow: Self.activeWindow())
    }

    private func downsample(_ image: CGImage) -> CGImage {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        if scale == 1 { return image }
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: image.bitmapInfo) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func activeWindow() -> ComputerWindow? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let match = list.first { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            return frontmost.map { owner == $0.localizedName || owner == $0.executableURL?.lastPathComponent } ?? false
        } ?? list.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let match else { return nil }
        let bounds = match[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return ComputerWindow(
            title: match[kCGWindowName as String] as? String ?? "",
            owner: match[kCGWindowOwnerName as String] as? String ?? "",
            bundleID: frontmost?.bundleIdentifier,
            bounds: ["x": bounds["X"] as? Double ?? 0,
                     "y": bounds["Y"] as? Double ?? 0,
                     "width": bounds["Width"] as? Double ?? 0,
                     "height": bounds["Height"] as? Double ?? 0])
    }
}

private enum ObservationError: LocalizedError {
    case encodeFailed

    var errorDescription: String? {
        "The screen could not be encoded as JPEG."
    }
}
