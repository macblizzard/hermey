import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code, drawn by the system, for pairing invites.
///
/// Both apps need the same picture — the desktop shows it for a phone to scan, the phone shows it for
/// the desktop's camera. CoreImage's `CIQRCodeGenerator` is on every platform this app ships to and
/// takes no dependency; the output is scaled with `.interpolation(.none)` so the modules stay square
/// instead of blurring into grey.
public struct QRCodeView: View {
    let content: String
    var side: CGFloat

    public init(content: String, side: CGFloat = 180) {
        self.content = content
        self.side = side
    }

    public var body: some View {
        Image(QRCodeView.qrImage(content: content))
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
    }

    /// Black modules on white: a QR code's finder patterns assume contrast, and the app's dark canvas
    /// behind a translucent pane is exactly what a dark-on-dark code needs to be defended against.
    @MainActor
    static func qrImage(content: String) -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        let output = filter.outputImage ?? CIImage.empty()
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            // Unreachable for a QR payload: the generator always produces an image. Fail loud rather
            // than render a blank rectangle that scans as nothing.
            preconditionFailure("CIQRCodeGenerator produced no image")
        }
        return cg
    }
}

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

private extension QRCodeView {
    /// `Image` takes the platform's image type; this is the one place the spelling differs.
    @MainActor
    func qrImage(_ cg: CGImage) -> PlatformImage {
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
        #endif
    }
}
