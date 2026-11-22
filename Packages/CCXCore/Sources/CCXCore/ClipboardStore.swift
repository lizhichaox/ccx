import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Content read from the pasteboard that can be turned into a pin.
public enum ClipboardPinPayload: Sendable {
    case image(CGImage, scale: CGFloat)
    case color(CCXColorSample)
    case text(String)
}

/// One captured snip kept in the in-memory history.
public struct SnipHistoryEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let image: CGImage
    /// Pixels per point of `image`.
    public let scale: CGFloat
    /// Captured area in AppKit global screen coordinates (points).
    public let screenRect: CGRect

    public init(id: UUID = UUID(), timestamp: Date = Date(), image: CGImage, scale: CGFloat, screenRect: CGRect) {
        self.id = id
        self.timestamp = timestamp
        self.image = image
        self.scale = scale
        self.screenRect = screenRect
    }
}

public enum ClipboardStoreError: Error, Equatable {
    case encodingFailed
    case writeFailed
}

/// Pasteboard abstraction used by `ClipboardStore` (defaults to `NSPasteboard.general`;
/// tests can supply `InMemoryClipboardPasteboard` when the pasteboard daemon is unavailable).
@MainActor
public protocol ClipboardPasteboard: AnyObject {
    func clearContents()
    func writeData(_ items: [(NSPasteboard.PasteboardType, Data)])
    func writeString(_ string: String)
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string() -> String?
    func readImageFileURLs() -> [URL]
}

@MainActor
private final class SystemClipboardPasteboard: ClipboardPasteboard {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    func writeData(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        let item = NSPasteboardItem()
        for (type, data) in items {
            item.setData(data, forType: type)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func writeString(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        pasteboard.data(forType: type)
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func readImageFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// In-memory `ClipboardPasteboard` implementation for deterministic, isolated tests.
@MainActor
public final class InMemoryClipboardPasteboard: ClipboardPasteboard {
    private var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    private var text: String?
    public var imageFileURLs: [URL] = []

    public init() {}

    public func clearContents() {
        dataByType.removeAll()
        text = nil
        imageFileURLs.removeAll()
    }

    public func writeData(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        clearContents()
        for (type, data) in items {
            dataByType[type] = data
        }
    }

    public func writeString(_ string: String) {
        clearContents()
        text = string
    }

    public func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataByType[type]
    }

    public func string() -> String? {
        text
    }

    public func readImageFileURLs() -> [URL] {
        imageFileURLs
    }
}

/// Pasteboard access plus an in-memory, newest-first history of recent snips.
@MainActor
public final class ClipboardStore {
    public let maxHistoryCount: Int
    /// Most recent snip first, capped at `maxHistoryCount`.
    public private(set) var history: [SnipHistoryEntry] = []

    private let pasteboard: any ClipboardPasteboard

    public init(maxHistoryCount: Int = 20) {
        self.maxHistoryCount = max(0, maxHistoryCount)
        self.pasteboard = SystemClipboardPasteboard(.general)
    }

    /// Creates a store backed by a custom pasteboard (useful for isolated unit tests).
    public init(maxHistoryCount: Int = 20, pasteboard: any ClipboardPasteboard) {
        self.maxHistoryCount = max(0, maxHistoryCount)
        self.pasteboard = pasteboard
    }

    public func recordSnip(image: CGImage, scale: CGFloat, screenRect: CGRect) {
        guard maxHistoryCount > 0 else { return }
        history.insert(SnipHistoryEntry(image: image, scale: scale, screenRect: screenRect), at: 0)
        if history.count > maxHistoryCount {
            history.removeLast(history.count - maxHistoryCount)
        }
    }

    public func clearHistory() {
        history.removeAll()
    }

    /// Writes PNG and TIFF representations tagged with `72 * scale` DPI so receiving apps
    /// paste the image at its point size.
    public func copyImage(_ image: CGImage, scale: CGFloat) {
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        if let png = Self.encode(image, type: .png, scale: scale) {
            items.append((.png, png))
        }
        if let tiff = Self.encode(image, type: .tiff, scale: scale) {
            items.append((.tiff, tiff))
        }
        pasteboard.writeData(items)
    }

    public func copyText(_ text: String) {
        pasteboard.writeString(text)
    }

    /// Reads the pasteboard in priority order: bitmap image (PNG/TIFF data or an image
    /// file URL), then a HEX color string, then trimmed non-empty text.
    public func readPinPayload() -> ClipboardPinPayload? {
        if let (image, scale) = readImage() {
            return .image(image, scale: scale)
        }
        guard let string = pasteboard.string() else { return nil }
        if let color = CCXColorSample.parseHex(string) {
            return .color(color)
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .text(trimmed)
    }

    public func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ClipboardStoreError.writeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ClipboardStoreError.encodingFailed }
    }

    // MARK: - Helpers

    private func readImage() -> (CGImage, CGFloat)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let decoded = Self.decode(data) {
                return decoded
            }
        }
        for url in pasteboard.readImageFileURLs() {
            if let data = try? Data(contentsOf: url), let decoded = Self.decode(data) {
                return decoded
            }
        }
        return nil
    }

    static func encode(_ image: CGImage, type: UTType, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil
        ) else { return nil }
        let dpi = 72 * max(scale, 0.01)
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if type == .tiff {
            // Lossless LZW compression keeps Retina clipboard copies small and fast over IPC.
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFCompression: 5,
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decodes image data and derives the pixel scale from its DPI metadata (72 DPI = 1x).
    static func decode(_ data: Data) -> (CGImage, CGFloat)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var scale: CGFloat = 1
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
           dpi > 0 {
            scale = max(1, (CGFloat(dpi) / 72 * 100).rounded() / 100)
        }
        return (image, scale)
    }
}
