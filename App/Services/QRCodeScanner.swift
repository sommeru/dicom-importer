import AppKit
import AVFoundation
import PDFKit
import SwiftUI
import Vision

/// Detects QR codes in still images, PDFs and the pasteboard.
enum QRCodeDetector {
    static func detect(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    static func detect(inFile url: URL) -> [String] {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            var codes: [String] = []
            for index in 0..<min(document.pageCount, 10) {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = 2400 / max(bounds.width, bounds.height, 1)
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    codes += detect(in: cgImage)
                }
            }
            return codes
        }
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return detect(in: cgImage)
    }

    /// Returns QR codes from an image on the pasteboard, or the pasted text itself.
    static func detectInPasteboard() -> [String] {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let file = urls.first {
            return detect(inFile: file)
        }
        if let image = NSImage(pasteboard: pasteboard),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return detect(in: cgImage)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [text]
        }
        return []
    }
}

/// Live QR code scanning with the Mac camera (incl. Continuity Camera of an iPhone).
final class CameraScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "de.sommeru.DICOMImporter.camera")
    private let videoQueue = DispatchQueue(label: "de.sommeru.DICOMImporter.video")
    private let output = AVCaptureVideoDataOutput()
    private var lastAnalysis = Date.distantPast
    var onCode: (@Sendable (String) -> Void)?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    func start(deviceID: String?) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.outputs.isEmpty, session.canAddOutput(output) {
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: videoQueue)
                session.addOutput(output)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) > 0.25 else { return }
        lastAnalysis = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        if let payload = request.results?.compactMap(\.payloadStringValue).first {
            onCode?(payload)
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
