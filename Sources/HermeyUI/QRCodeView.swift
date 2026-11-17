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
        #if os(iOS)
        Image(uiImage: QRCodeView.image(content: content))
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
        #else
        Image(nsImage: QRCodeView.image(content: content))
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
        #endif
    }

    /// Black modules on white: a QR code's finder patterns assume contrast, and the app's dark canvas
    /// behind a translucent pane is exactly what a dark-on-dark code needs to be defended against.
    @MainActor
    static func image(content: String) -> PlatformImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        let output = filter.outputImage ?? CIImage.empty()
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            return PlatformImage()
        }
        return PlatformImage(cgImage: cg)
    }
}

#if os(iOS)
import UIKit
private typealias PlatformImage = UIImage
#else
import AppKit
private typealias PlatformImage = NSImage
#endif
