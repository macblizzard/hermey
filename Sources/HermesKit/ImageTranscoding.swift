import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an iPhone photo into something the host will actually accept.
///
/// `tui_gateway`'s `image.attach_bytes` keeps a list of extensions and answers
/// `unsupported image extension: .heic` for anything outside it. A camera roll is HEIC by default, so
/// the picker's own output was rejected every time — the failure happened after the user chose a
/// picture, which reads as "attaching is broken" rather than "that format is not supported".
///
/// The conversion belongs on this side: ImageIO is present on both platforms, the picture keeps its
/// resolution, and the host needs no change. Anything that is not HEIC/HEIF — or that ImageIO cannot
/// decode — is returned untouched, so a caller never loses an attachment to a failed transcode.
public enum ImageTranscoding {
    /// Extensions the host refuses, and the only ones worth decoding and re-encoding.
    public static let convertibleExtensions: Set<String> = ["heic", "heif"]

    /// A JPEG's extension, which is also what the host's allow-list expects.
    public static let jpegExtension = "jpg"

    /// 0.85 keeps a 12-megapixel photo well inside the 8 MB attachment budget while staying visually
    /// indistinguishable from the original on a phone screen.
    public static let jpegQuality: CGFloat = 0.85

    public struct Result: Equatable {
        public let name: String
        public let data: Data
        /// True when the bytes were re-encoded, so a caller can say so if it wants.
        public let converted: Bool

        public init(name: String, data: Data, converted: Bool) {
            self.name = name
            self.data = data
            self.converted = converted
        }
    }

    /// `name`/`data` unchanged unless the extension is one the host rejects, in which case the picture
    /// is decoded and written back out as JPEG under a `.jpg` name.
    public static func jpegIfNeeded(name: String, data: Data) -> Result {
        let ext = (name as NSString).pathExtension.lowercased()
        guard convertibleExtensions.contains(ext), !data.isEmpty else {
            return Result(name: name, data: data, converted: false)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0
        else {
            // Undecodable: hand it back as it came, so the send path reports the host's own reason
            // instead of a made-up one here.
            return Result(name: name, data: data, converted: false)
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return Result(name: name, data: data, converted: false)
        }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return Result(name: name, data: data, converted: false)
        }

        let base = (name as NSString).deletingPathExtension
        let renamed = base.isEmpty ? "photo.\(jpegExtension)" : "\(base).\(jpegExtension)"
        return Result(name: renamed, data: output as Data, converted: true)
    }
}
