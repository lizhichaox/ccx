import CoreGraphics
import Foundation
import Vision

/// Recognized text fragment paired with its Vision normalized bottom-left bounding box (`0...1`).
public struct RecognizedTextBlock: Equatable, Sendable {
    public let text: String
    public let boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// Content source produced by `TextRecognizer.recognize(in:)`.
public enum TextRecognitionKind: Equatable, Sendable {
    case text
    case qrCode
}

/// Extracted text or barcode payload returned by on-device Vision recognition.
public struct TextRecognitionResult: Equatable, Sendable {
    public let text: String
    public let kind: TextRecognitionKind

    public init(text: String, kind: TextRecognitionKind) {
        self.text = text
        self.kind = kind
    }
}

/// Performs local macOS Vision OCR and barcode/QR decoding on frozen snips and pinned images.
public enum TextRecognizer {
    /// Reconstructs visual rows, tabular column gaps (`\t`), and paragraph breaks (`\n\n`) from
    /// unordered normalized bottom-left Vision bounding boxes (`0...1`).
    public static func assembleLayout(from blocks: [RecognizedTextBlock]) -> String {
        struct NormalizedBlock {
            let text: String
            let box: CGRect
            var charWidth: CGFloat {
                max(0.002, box.width / CGFloat(max(1, text.count)))
            }
        }

        let cleaned: [NormalizedBlock] = blocks.compactMap { block in
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let box = block.boundingBox
            guard !box.isNull, !box.isInfinite,
                  box.origin.x.isFinite, box.origin.y.isFinite,
                  box.width.isFinite, box.height.isFinite,
                  box.width > 0, box.height > 0
            else { return nil }
            let standardized = box.standardized
            guard standardized.minX.isFinite,
                  standardized.maxX.isFinite,
                  standardized.minY.isFinite,
                  standardized.maxY.isFinite,
                  standardized.midY.isFinite
            else { return nil }
            return NormalizedBlock(text: trimmed, box: standardized)
        }
        guard !cleaned.isEmpty else { return "" }

        let sortedHeights = cleaned.map(\.box.height).sorted()
        let medianRowHeight = max(0.004, sortedHeights[sortedHeights.count / 2])

        let topToBottom = cleaned.sorted { lhs, rhs in
            if lhs.box.midY != rhs.box.midY {
                return lhs.box.midY > rhs.box.midY
            }
            return lhs.box.minX < rhs.box.minX
        }

        struct VisualRow {
            var items: [NormalizedBlock]
            var minY: CGFloat
            var maxY: CGFloat
            var averageMidY: CGFloat

            mutating func append(_ item: NormalizedBlock) {
                let count = CGFloat(items.count)
                averageMidY = (averageMidY * count + item.box.midY) / (count + 1)
                minY = min(minY, item.box.minY)
                maxY = max(maxY, item.box.maxY)
                items.append(item)
            }
        }

        var rows: [VisualRow] = []
        for item in topToBottom {
            var bestRowIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for index in rows.indices {
                let row = rows[index]
                let overlap = min(row.maxY, item.box.maxY) - max(row.minY, item.box.minY)
                let minHeight = min(row.maxY - row.minY, item.box.height)
                let overlapRatio = minHeight > 0 ? (overlap / minHeight) : 0
                let midDistance = abs(item.box.midY - row.averageMidY)
                if overlapRatio >= 0.45 || midDistance <= 0.5 * medianRowHeight {
                    if midDistance < bestDistance {
                        bestDistance = midDistance
                        bestRowIndex = index
                    }
                }
            }
            if let bestRowIndex {
                rows[bestRowIndex].append(item)
            } else {
                rows.append(VisualRow(
                    items: [item],
                    minY: item.box.minY,
                    maxY: item.box.maxY,
                    averageMidY: item.box.midY
                ))
            }
        }

        rows.sort { $0.averageMidY > $1.averageMidY }

        var output = ""
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 {
                let previousRow = rows[rowIndex - 1]
                let verticalGap = previousRow.minY - row.maxY
                output.append(verticalGap > 1.2 * medianRowHeight ? "\n\n" : "\n")
            }

            let leftToRight = row.items.sorted { lhs, rhs in
                if lhs.box.minX != rhs.box.minX {
                    return lhs.box.minX < rhs.box.minX
                }
                return lhs.box.midY > rhs.box.midY
            }

            for (itemIndex, item) in leftToRight.enumerated() {
                if itemIndex > 0 {
                    let prev = leftToRight[itemIndex - 1]
                    let horizontalGap = item.box.minX - prev.box.maxX
                    let estCharW = max(0.002, (prev.charWidth + item.charWidth) * 0.5)
                    if horizontalGap >= 1.6 * estCharW {
                        output.append("\t")
                    } else if horizontalGap < 0.45 * estCharW,
                              isCJKCharacter(prev.text.last),
                              isCJKCharacter(item.text.first)
                    {
                        // Join tightly adjacent CJK text observations without inserting stray ASCII spaces.
                    } else {
                        output.append(" ")
                    }
                }
                output.append(item.text)
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCJKCharacter(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,
             0x3400...0x4DBF,
             0x3040...0x309F,
             0x30A0...0x30FF,
             0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// Extracts multi-line text using Apple Vision's accurate recognizer across
    /// Simplified/Traditional Chinese and English without leaving the device, falling back to
    /// QR/2D barcode payload detection when no readable text is present.
    public static func recognize(in image: CGImage) async throws -> TextRecognitionResult {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0 else {
            return TextRecognitionResult(text: "", kind: .text)
        }

        let cancelBox = CancelableVisionRequestBox()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    try cancelBox.checkCancellation()

                    let textRequest = VNRecognizeTextRequest()
                    textRequest.recognitionLevel = .accurate
                    textRequest.usesLanguageCorrection = true
                    textRequest.automaticallyDetectsLanguage = true
                    textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

                    guard cancelBox.install([textRequest]) else {
                        throw CancellationError()
                    }
                    defer { cancelBox.clear() }

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([textRequest])
                    try cancelBox.checkCancellation()

                    let blocks: [RecognizedTextBlock] = (textRequest.results ?? []).compactMap { observation in
                        guard let text = observation.topCandidates(1).first?.string else { return nil }
                        return RecognizedTextBlock(text: text, boundingBox: observation.boundingBox)
                    }
                    let assembled = assembleLayout(from: blocks)
                    if !assembled.isEmpty {
                        return TextRecognitionResult(text: assembled, kind: .text)
                    }

                    // Fallback to QR / 2D barcode payload decoding when OCR finds no readable text.
                    let barcodeRequest = VNDetectBarcodesRequest()
                    barcodeRequest.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]
                    guard cancelBox.install([barcodeRequest]) else {
                        throw CancellationError()
                    }

                    try handler.perform([barcodeRequest])
                    try cancelBox.checkCancellation()

                    var payloads: [String] = []
                    for observation in barcodeRequest.results ?? [] {
                        guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !payload.isEmpty
                        else { continue }
                        if !payloads.contains(payload) {
                            payloads.append(payload)
                        }
                    }
                    if !payloads.isEmpty {
                        return TextRecognitionResult(text: payloads.joined(separator: "\n"), kind: .qrCode)
                    }
                    return TextRecognitionResult(text: "", kind: .text)
                }
            }.value
        } onCancel: {
            cancelBox.cancel()
        }
    }

    /// Backwards-compatible convenience returning the recognized text or barcode string.
    public static func recognizeText(in image: CGImage) async throws -> String {
        try await recognize(in: image).text
    }
}

private final class CancelableVisionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [VNRequest] = []
    private var isCancelled = false

    func install(_ requests: [VNRequest]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            return false
        }
        self.requests = requests
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let activeRequests = requests
        lock.unlock()
        for request in activeRequests {
            request.cancel()
        }
    }

    func clear() {
        lock.lock()
        requests = []
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
    }
}
