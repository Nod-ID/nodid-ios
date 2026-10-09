// Nod ID SDK: camera scan of the two machine-readable lines (screen 04).
// PRIVACY: frames are processed in memory only. No frame or image is saved, no recognized text is stored, logged or
// printed. The session stops and buffers are dropped as soon as a valid read is found.
import AVFoundation
import SwiftUI
import UIKit
import Vision

final class MRZScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.nodid.mrz-scan", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var busy = false          // touched only on `queue`
    private var finished = false      // touched only on `queue`
    private var lastRun = Date.distantPast
    /// Called once on the main thread with the validated read.
    var onRead: ((MRZData) -> Void)?
    var onUnavailable: (() -> Void)?

    var hasTorch: Bool { device?.hasTorch ?? false }

    func start() {
        queue.async { [self] in
            finished = false; busy = false
            if !configured {
                guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: dev) else {
                    DispatchQueue.main.async { self.onUnavailable?() }
                    return
                }
                device = dev
                session.beginConfiguration()
                session.sessionPreset = .hd1920x1080
                if session.canAddInput(input) { session.addInput(input) }
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            finished = true
            setTorchLocked(false)
            if session.isRunning { session.stopRunning() }
            output.setSampleBufferDelegate(nil, queue: nil)
            if configured { session.beginConfiguration(); session.inputs.forEach(session.removeInput); session.outputs.forEach(session.removeOutput); session.commitConfiguration(); configured = false }
        }
    }

    func setTorch(_ on: Bool) { queue.async { [self] in setTorchLocked(on) } }
    private func setTorchLocked(_ on: Bool) {
        guard let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        d.torchMode = on ? .on : .off
        d.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, !busy, Date().timeIntervalSince(lastRun) > 0.25, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true; lastRun = Date()
        var found: MRZData?
        let request = VNRecognizeTextRequest { req, _ in
            guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
            let lines = obs.sorted { $0.boundingBox.minY > $1.boundingBox.minY }.compactMap { $0.topCandidates(1).first?.string }
            found = MRZParser.find(in: lines)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right, options: [:])
        try? handler.perform([request])
        busy = false
        if let mrz = found, !finished {
            finished = true
            setTorchLocked(false)
            session.stopRunning()
            DispatchQueue.main.async { self.onRead?(mrz) }
        }
    }
}

/// Live preview of the session. Shows the camera only; never captures stills.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layer_: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer_.session = session
        v.layer_.videoGravity = .resizeAspectFill
        v.isAccessibilityElement = false
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
