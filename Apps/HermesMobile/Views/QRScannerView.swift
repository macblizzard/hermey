import SwiftUI
import OpenBotUI

#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import UIKit

/// A QR viewfinder for the pairing code.
///
/// AVFoundation rather than a third-party scanner: one output type, no dependencies, and
/// the session is torn down when the sheet goes away (`dismantleUIView`) so the camera
/// light is never left on. If the device has no camera — simulator, or a denied
/// permission — nothing starts and the sheet's paste field is the whole flow.
struct QRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void
    /// `false` only in previews: it builds the layer without opening the camera, so the
    /// canvas never asks for permission or leaves a capture session running.
    var startsSession: Bool = true

    func makeCoordinator() -> ScannerCoordinator {
        ScannerCoordinator()
    }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.onCode = onCode
        context.coordinator.configure()
        view.previewLayer.session = context.coordinator.session
        view.previewLayer.videoGravity = .resizeAspectFill
        if startsSession {
            context.coordinator.start()
        }
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: ScannerCoordinator) {
        coordinator.stop()
    }

    /// True when the hardware exists; the sheet uses it to choose copy.
    static var isCameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // `layerClass` guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }
}

final class ScannerCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()

    var onCode: ((String) -> Void)?

    private var configured = false
    private var hasInput = false
    private var lastValue: String?

    func configure() {
        guard !configured else { return }
        configured = true
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }

        session.beginConfiguration()
        session.addInput(input)
        hasInput = true

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
        }
        session.commitConfiguration()
    }

    func start() {
        configure()
        guard hasInput else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.run() }
            }
        default:
            break
        }
    }

    func stop() {
        guard session.isRunning else { return }
        // `stopRunning` blocks; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    private func run() {
        guard hasInput, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    // MARK: AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty,
              value != lastValue else { return }
        lastValue = value
        onCode?(value)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("QR scanner · viewfinder") {
    QRScannerView(onCode: { _ in }, startsSession: false)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radiusGrouped, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 1)
        )
        .padding(16)
        .background(Tokens.canvas)
        .preferredColorScheme(.dark)
}
#endif
#endif
