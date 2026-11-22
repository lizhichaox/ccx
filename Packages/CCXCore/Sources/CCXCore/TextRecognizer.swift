import CoreGraphics
import Foundation
import Vision

/// Performs local macOS Vision OCR on frozen snips and pinned images.
public enum TextRecognizer {
    /// Extracts multi-line text using Apple Vision's accurate recognizer across
    /// Simplified/Traditional Chinese and English without leaving the device.
    public static func recognizeText(in image: CGImage) async throws -> String {
        let box = UncheckedSendableCGImage(image)
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: box.image, options: [:])
            try handler.perform([request])

            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

private struct UncheckedSendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
