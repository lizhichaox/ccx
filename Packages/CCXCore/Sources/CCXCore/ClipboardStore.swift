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

/// Lightweight badge classification for the menu bar popover without decoding clipboard images.
public enum ClipboardPinBadge: Equatable, Sendable {
    case image
    case color(CCXColorSample)
    case text
    case empty

    public var displayText: String {
        switch self {
        case .image: "Image"
        case let .color(sample): sample.hexString
        case .text: "Text"
        case .empty: "Empty"
        }
    }
}

/// One captured snip kept in the in-memory history.
public struct SnipHistoryEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let image: CGImage
    /// Pre-downsampled thumbnail (max 160px on longest side) for fast popover rendering.
    public let thumbnail: CGImage
    /// Pixels per point of `image`.
    public let scale: CGFloat
    /// Captured area in AppKit global screen coordinates (points).
    public let screenRect: CGRect

    public init(id: UUID = UUID(), timestamp: Date = Date(), image: CGImage, scale: CGFloat, screenRect: CGRect) {
        self.id = id
        self.timestamp = timestamp
        self.image = image
        self.thumbnail = Self.makeThumbnail(from: image, maxPixelDimension: 160)
        self.scale = scale
        self.screenRect = screenRect
    }

    private static func makeThumbnail(from image: CGImage, maxPixelDimension: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxPixelDimension, width > 0, height > 0 else {
            return image
        }
        let scale = maxPixelDimension / longest
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: targetWidth,
                  height: targetHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return image
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
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
    var changeCount: Int { get }
    func clearContents()
    func writeData(_ items: [(NSPasteboard.PasteboardType, Data)])
    func writeLazyImage(png: Data, tiffProvider: @escaping @Sendable () -> Data?)
    func writeString(_ string: String)
    func hasImageData() -> Bool
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string() -> String?
    func readImageFileURLs() -> [URL]
}

public extension ClipboardPasteboard {
    func writeLazyImage(png: Data, tiffProvider: @escaping @Sendable () -> Data?) {
        var items: [(NSPasteboard.PasteboardType, Data)] = [(.png, png)]
        if let tiff = tiffProvider() {
            items.append((.tiff, tiff))
        }
        writeData(items)
    }
}

private final class LazyTIFFDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable () -> Data?)?
    private var cachedTIFF: Data?

    init(_ provider: @escaping @Sendable () -> Data?) {
        self.provider = provider
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .tiff else { return }
        lock.lock()
        let cached = cachedTIFF
        let fn = provider
        lock.unlock()

        if let cached {
            item.setData(cached, forType: .tiff)
            return
        }
        if let data = fn?() {
            lock.lock()
            cachedTIFF = data
            provider = nil
            lock.unlock()
            item.setData(data, forType: .tiff)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        lock.lock()
        provider = nil
        cachedTIFF = nil
        lock.unlock()
    }
}

@MainActor
private final class SystemClipboardPasteboard: ClipboardPasteboard {
    private let pasteboard: NSPasteboard
    private var activeDataProvider: LazyTIFFDataProvider?

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func clearContents() {
        activeDataProvider = nil
        pasteboard.clearContents()
    }

    func writeData(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        activeDataProvider = nil
        let item = NSPasteboardItem()
        for (type, data) in items {
            item.setData(data, forType: type)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func writeLazyImage(png: Data, tiffProvider: @escaping @Sendable () -> Data?) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = LazyTIFFDataProvider(tiffProvider)
        activeDataProvider = provider
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func writeString(_ string: String) {
        activeDataProvider = nil
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func hasImageData() -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil
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
    public private(set) var changeCount: Int = 0
    private var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
    private var text: String?
    public var imageFileURLs: [URL] = [] {
        didSet { changeCount += 1 }
    }

    public init() {}

    public func clearContents() {
        dataByType.removeAll()
        text = nil
        imageFileURLs = []
        changeCount += 1
    }

    public func writeData(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        dataByType.removeAll()
        text = nil
        imageFileURLs = []
        for (type, data) in items {
            dataByType[type] = data
        }
        changeCount += 1
    }

    public func writeString(_ string: String) {
        dataByType.removeAll()
        imageFileURLs = []
        text = string
        changeCount += 1
    }

    public func hasImageData() -> Bool {
        dataByType[.png] != nil || dataByType[.tiff] != nil
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
    private var cachedBadge: (changeCount: Int, badge: ClipboardPinBadge)?

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

    /// Writes PNG immediately and registers a lazy LZW-compressed TIFF provider (only
    /// encoded if a receiving app explicitly requests TIFF).
    public func copyImage(_ image: CGImage, scale: CGFloat) {
        if let png = Self.encode(image, type: .png, scale: scale) {
            pasteboard.writeLazyImage(png: png) {
                Self.encode(image, type: .tiff, scale: scale)
            }
            return
        }
        if let tiff = Self.encode(image, type: .tiff, scale: scale) {
            pasteboard.writeData([(.tiff, tiff)])
        } else {
            pasteboard.writeData([])
        }
    }

    public func copyText(_ text: String) {
        pasteboard.writeString(text)
    }

    /// Classifies the current pasteboard content without decoding full bitmap image payloads,
    /// caching the result against `pasteboard.changeCount`.
    public func peekPinBadge() -> ClipboardPinBadge {
        let changeCount = pasteboard.changeCount
        if let cached = cachedBadge, cached.changeCount == changeCount {
            return cached.badge
        }
        let badge: ClipboardPinBadge
        if pasteboard.hasImageData() || !pasteboard.readImageFileURLs().isEmpty {
            badge = .image
        } else if let string = pasteboard.string() {
            if let color = CCXColorSample.parseHex(string) {
                badge = .color(color)
            } else if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                badge = .text
            } else {
                badge = .empty
            }
        } else {
            badge = .empty
        }
        cachedBadge = (changeCount, badge)
        return badge
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

    nonisolated static func encode(_ image: CGImage, type: UTType, scale: CGFloat) -> Data? {
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
