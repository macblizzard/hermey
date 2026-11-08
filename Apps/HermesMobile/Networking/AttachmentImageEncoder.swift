import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Turns whatever the user picked into bytes the host will accept.
///
/// A modern iPhone photo is 3–6 MB as HEIC and 8–15 MB as JPEG, so a raw hand-off fails the
/// budget almost every time. Everything goes through `ImageDownscale.steps` instead: an image
/// that already fits is sent untouched, anything else is decoded once, resized down the
/// ladder and re-encoded as JPEG until it fits.
enum AttachmentImageEncoder {

    /// Images picked out of Files or the photo library: downsampled from the file itself, so a
    /// 48 MP capture is never fully decoded into memory.
    static func payload(from url: URL, limit: Int = AttachmentBudget.maximumBytes) throws -> AttachmentPayload {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                     [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AttachmentBudgetError.unsupportedFile
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let steps = ImageDownscale.steps(decodedBytes: fileBytes,
                                         pixelWidth: width, pixelHeight: height, limit: limit)

        // Already under the limit: keep the original bytes, so the host gets the full-quality
        // image instead of a re-encode that only loses.
        if steps.isEmpty, fileBytes > 0 {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else { throw AttachmentBudgetError.empty }
            let name = AttachmentName.sanitized(url.lastPathComponent) ?? "attachment"
            return AttachmentPayload(name: name, data: data, isImage: true)
        }

        for step in steps {
            guard let data = jpegData(from: source, step: step) else { continue }
            if data.isEmpty { throw AttachmentBudgetError.empty }
            if data.count <= limit {
                return AttachmentPayload(name: jpegName(basedOn: url.lastPathComponent),
                                         data: data, isImage: true)
            }
        }
        throw AttachmentBudgetError.tooLarge(byteCount: max(fileBytes, limit + 1), maximumBytes: limit)
    }

    /// Camera captures: a `UIImage` has no byte count of its own, so the ladder is entered with
    /// an estimate and verified against the real encoded size.
    static func payload(from image: UIImage,
                        baseName: String = "Photo",
                        limit: Int = AttachmentBudget.maximumBytes) throws -> AttachmentPayload {
        let pixelWidth = Int((image.size.width * image.scale).rounded())
        let pixelHeight = Int((image.size.height * image.scale).rounded())
        let longEdge = max(pixelWidth, pixelHeight)
        let estimate = ImageDownscale.estimatedJPEGBytes(maxPixelDimension: longEdge, quality: 1.0)

        let steps: [ImageDownscaleStep]
        if estimate <= limit && longEdge > 0 {
            steps = [ImageDownscaleStep(maxPixelDimension: longEdge, quality: 0.9)]
        } else {
            steps = ImageDownscale.steps(decodedBytes: estimate,
                                         pixelWidth: pixelWidth, pixelHeight: pixelHeight, limit: limit)
        }

        for step in steps {
            guard let data = jpegData(from: image, step: step) else { continue }
            if data.count <= limit {
                return AttachmentPayload(name: AttachmentName.sanitized(baseName + ".jpg") ?? "attachment.jpg",
                                         data: data, isImage: true)
            }
        }
        throw AttachmentBudgetError.tooLarge(byteCount: estimate, maximumBytes: limit)
    }

    // MARK: Encoding

    private static func jpegData(from source: CGImageSource, step: ImageDownscaleStep) -> Data? {
        let image: CGImage?
        if step.maxPixelDimension > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // Bakes the EXIF orientation in, so a portrait photo is not sent sideways.
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: step.maxPixelDimension,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
                                                                UTType.jpeg.identifier as CFString,
                                                                1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: step.quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func jpegData(from image: UIImage, step: ImageDownscaleStep) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        var target = CGSize(width: pixelWidth, height: pixelHeight)
        if step.maxPixelDimension > 0 {
            let longEdge = max(pixelWidth, pixelHeight)
            let ratio = min(1, CGFloat(step.maxPixelDimension) / max(longEdge, 1))
            target = CGSize(width: (pixelWidth * ratio).rounded(), height: (pixelHeight * ratio).rounded())
        }
        guard target.width >= 1, target.height >= 1 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // `target` is already in pixels.
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { context in
            // JPEG has no alpha; white keeps transparent PNGs from turning black.
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: CGFloat(step.quality))
    }

    /// `IMG_0001.HEIC` becomes `IMG_0001.jpg`: the bytes are JPEG now, and the host trusts the
    /// suffix when it decides what it was given.
    private static func jpegName(basedOn name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let base = stem.isEmpty ? "Photo" : stem
        return AttachmentName.sanitized(base + ".jpg") ?? "attachment.jpg"
    }
}
