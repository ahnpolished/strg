import AVFoundation
import UIKit
import Observation

@Observable
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private(set) var isReady = false
    private(set) var permissionDenied = false

    private let photoOutput = AVCapturePhotoOutput()
    private var captureCompletion: CheckedContinuation<UIImage, Error>?

    func setup() async {
        let authorized = await ensurePermission()
        guard authorized else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        await MainActor.run { isReady = true }
        Task.detached { [session] in session.startRunning() }
    }

    func stop() {
        Task.detached { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    func capturePhoto() async throws -> UIImage {
        try await withCheckedThrowingContinuation { cont in
            captureCompletion = cont
            DispatchQueue.main.async { [self] in
                photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    private func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { await MainActor.run { permissionDenied = true } }
            return granted
        default:
            await MainActor.run { permissionDenied = true }
            return false
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor [self] in
            defer { captureCompletion = nil }
            if let error { captureCompletion?.resume(throwing: error); return }
            guard let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                captureCompletion?.resume(throwing: CameraError.captureError)
                return
            }
            captureCompletion?.resume(returning: image)
        }
    }
}

enum CameraError: LocalizedError {
    case captureError
    var errorDescription: String? { "Failed to capture photo." }
}
