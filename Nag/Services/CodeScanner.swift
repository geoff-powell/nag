@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Live camera view that reports QR codes and barcodes. Reports each distinct code once, so a wrong
/// code can be followed by the right one without restarting.
struct CodeScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> CodeScannerViewController {
        let controller = CodeScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: CodeScannerViewController, context: Context) {
        controller.onCode = onCode
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}

final class CodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastCodeAt = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        let wanted: [AVMetadataObject.ObjectType] = [.qr, .ean8, .ean13, .upce, .code39, .code93, .code128, .pdf417, .aztec, .dataMatrix, .itf14]
        output.metadataObjectTypes = wanted.filter(output.availableMetadataObjectTypes.contains)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning { session.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let value = metadataObjects.lazy
            .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            .first
        guard let value else { return }
        // Delivered on the main queue (see setMetadataObjectsDelegate).
        MainActor.assumeIsolated {
            report(value)
        }
    }

    private func report(_ value: String) {
        let now = Date()
        guard value != lastCode || now.timeIntervalSince(lastCodeAt) > 3 else { return }
        lastCode = value
        lastCodeAt = now
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCode?(value)
    }
}
