import CoreGraphics
import Foundation
import Vision

/// Performs local macOS Vision OCR on frozen snips and pinned images.
public enum TextRecognizer {
    /// Extracts multi-line text using Apple Vision's accurate recognizer across
    /// Simplified/Traditional Chinese and English without leaving the device.
    public static func recognizeText(in image: CGImage) async throws -> String {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0 else { return "" }

        let cancelBox = CancelableVisionRequestBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

                guard cancelBox.install(request) else {
                    throw CancellationError()
                }
                defer { cancelBox.clear() }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try handler.perform([request])
                try Task.checkCancellation()

                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        } onCancel: {
            cancelBox.cancel()
        }
    }
}

private final class CancelableVisionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var isCancelled = false

    func install(_ request: VNRecognizeTextRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            return false
        }
        self.request = request
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let activeRequest = request
        lock.unlock()
        activeRequest?.cancel()
    }

    func clear() {
        lock.lock()
        request = nil
        lock.unlock()
    }
}
