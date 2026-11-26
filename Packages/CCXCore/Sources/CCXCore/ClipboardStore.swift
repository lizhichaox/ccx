import AppKit
import CoreGraphics
import Darwin
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
        case .image: CCXL10n.text("Image", zh: "图片")
        case let .color(sample): sample.hexString
        case .text: CCXL10n.text("Text", zh: "文本")
        case .empty: CCXL10n.text("Empty", zh: "空")
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
    /// Visual fingerprint used to deduplicate clipboard copies and on-screen pins.
    public let fingerprint: ImageFingerprint
    /// Pixels per point of `image`.
    public let scale: CGFloat
    /// Captured area in AppKit global screen coordinates (points).
    public let screenRect: CGRect

    public var pinIdentity: PinContentIdentity {
        .image(fingerprint, historyEntryID: id)
    }

    public init(id: UUID = UUID(), timestamp: Date = Date(), image: CGImage, scale: CGFloat, screenRect: CGRect) {
        self.id = id
        self.timestamp = timestamp
        self.image = image
        self.thumbnail = Self.makeThumbnail(from: image, maxPixelDimension: 160)
        self.fingerprint = ImageFingerprint(image: image)
        self.scale = scale
        self.screenRect = screenRect
    }

    internal init(
        id: UUID,
        timestamp: Date,
        image: CGImage,
        thumbnail: CGImage,
        fingerprint: ImageFingerprint,
        scale: CGFloat,
        screenRect: CGRect
    ) {
        self.id = id
        self.timestamp = timestamp
        self.image = image
        self.thumbnail = thumbnail
        self.fingerprint = fingerprint
        self.scale = scale
        self.screenRect = screenRect
    }

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    private static func makeThumbnail(from image: CGImage, maxPixelDimension: CGFloat) -> CGImage {
        // For ultra-tall scrolling captures, crop the top portion so thumbnails show crisp header content.
        let sourceImage: CGImage
        if CGFloat(image.height) > CGFloat(image.width) * 2.5, image.width > 0 {
            let cropHeight = min(image.height, image.width * 2)
            sourceImage = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: cropHeight)) ?? image
        } else {
            sourceImage = image
        }
        let width = CGFloat(sourceImage.width)
        let height = CGFloat(sourceImage.height)
        let longest = max(width, height)
        guard longest > maxPixelDimension, width > 0, height > 0 else {
            return sourceImage
        }
        let scale = maxPixelDimension / longest
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        guard let colorSpace = sRGBColorSpace,
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
            return sourceImage
        }
        context.interpolationQuality = .medium
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? sourceImage
    }
}

public enum ClipboardStoreError: Error, Equatable, LocalizedError {
    case encodingFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            CCXL10n.text("Could not encode the image as PNG.", zh: "无法将图片编码为 PNG。")
        case .writeFailed:
            CCXL10n.text("Could not write the PNG file to disk.", zh: "无法将 PNG 文件写入磁盘。")
        }
    }
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
    func writeFileURLs(_ urls: [URL])
    func hasImageData() -> Bool
    func hasAnyContent() -> Bool
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

    func writeFileURLs(_ urls: [URL]) {}

    func hasAnyContent() -> Bool {
        if hasImageData() || !readImageFileURLs().isEmpty { return true }
        if let text = string(), !text.allSatisfy(\.isWhitespace) { return true }
        return false
    }
}

final class LazyTIFFDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable () -> Data?)?
    private var isInvalidated = false

    init(_ provider: @escaping @Sendable () -> Data?) {
        self.provider = provider
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        provider = nil
        lock.unlock()
    }

    var invalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isInvalidated
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .tiff else { return }
        lock.lock()
        let fn = isInvalidated ? nil : provider
        lock.unlock()

        guard let data = fn?() else { return }

        lock.lock()
        let stillValid = !isInvalidated
        lock.unlock()
        guard stillValid else { return }
        // AppKit's pasteboard server retains the data once set; avoid keeping a duplicate
        // multi-MB TIFF buffer cached indefinitely in CCX's process memory.
        item.setData(data, forType: .tiff)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        invalidate()
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

    private func releaseActiveProvider() {
        activeDataProvider?.invalidate()
        activeDataProvider = nil
    }

    func clearContents() {
        releaseActiveProvider()
        pasteboard.clearContents()
    }

    func writeData(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        releaseActiveProvider()
        let item = NSPasteboardItem()
        for (type, data) in items {
            item.setData(data, forType: type)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func writeLazyImage(png: Data, tiffProvider: @escaping @Sendable () -> Data?) {
        releaseActiveProvider()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = LazyTIFFDataProvider(tiffProvider)
        activeDataProvider = provider
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func writeString(_ string: String) {
        releaseActiveProvider()
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func writeFileURLs(_ urls: [URL]) {
        releaseActiveProvider()
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    func hasImageData() -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    func hasAnyContent() -> Bool {
        !(pasteboard.types?.isEmpty ?? true)
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        pasteboard.data(forType: type)
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func readImageFileURLs() -> [URL] {
        guard pasteboard.availableType(from: [.fileURL]) != nil else { return [] }
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
    private var storedImageFileURLs: [URL] = []
    private var storedAllFileURLs: [URL] = []

    public var imageFileURLs: [URL] {
        get { storedImageFileURLs }
        set {
            storedImageFileURLs = newValue
            storedAllFileURLs = newValue
            changeCount += 1
        }
    }

    public init() {}

    public func clearContents() {
        dataByType.removeAll()
        text = nil
        storedImageFileURLs = []
        storedAllFileURLs = []
        changeCount += 1
    }

    public func writeData(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        dataByType.removeAll()
        text = nil
        storedImageFileURLs = []
        storedAllFileURLs = []
        for (type, data) in items {
            dataByType[type] = data
        }
        changeCount += 1
    }

    public func writeString(_ string: String) {
        dataByType.removeAll()
        storedImageFileURLs = []
        storedAllFileURLs = []
        text = string
        changeCount += 1
    }

    public func writeFileURLs(_ urls: [URL]) {
        dataByType.removeAll()
        text = nil
        storedAllFileURLs = urls
        storedImageFileURLs = urls.filter(Self.isImageFileURL)
        changeCount += 1
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "gif", "heic", "heif", "webp", "bmp", "ico",
    ]

    private static func isImageFileURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return true }
        if imageExtensions.contains(ext) { return true }
        if let utType = UTType(filenameExtension: ext), !utType.isDynamic {
            return utType.conforms(to: .image)
        }
        return false
    }

    public func hasImageData() -> Bool {
        dataByType[.png] != nil || dataByType[.tiff] != nil
    }

    public func hasAnyContent() -> Bool {
        hasImageData()
            || !storedAllFileURLs.isEmpty
            || !(text?.allSatisfy(\.isWhitespace) ?? true)
    }

    public func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        dataByType[type]
    }

    public func string() -> String? {
        text
    }

    public func readImageFileURLs() -> [URL] {
        storedImageFileURLs
    }
}

/// Pasteboard access plus an in-memory, newest-first history of recent snips.
@MainActor
public final class ClipboardStore {
    /// Default total uncompressed RGBA memory budget for in-memory snip history (160 MB).
    public nonisolated static let defaultMaxHistoryMemoryBytes = 160 * 1024 * 1024
    /// Upper bound on text characters extracted from the pasteboard for floating text pins.
    public nonisolated static let maxPinTextLength = 100_000
    nonisolated static let maxDecodeFileBytes = 100 * 1024 * 1024 // 100 MB
    nonisolated static let maxDecodeDimension = 32_768
    nonisolated static let maxDecodePixels = 100_000_000 // 100 MP

    public let maxHistoryCount: Int
    public let maxHistoryMemoryBytes: Int
    /// Most recent snip first, capped at `maxHistoryCount` and `maxHistoryMemoryBytes`.
    public private(set) var history: [SnipHistoryEntry] = []
    /// Invoked on the main actor whenever `history` changes (snip recorded, cleared, or loaded from disk).
    public var onHistoryChanged: (() -> Void)?

    private let pasteboard: any ClipboardPasteboard
    private let diskStore: SnipHistoryDiskStore?
    private var clearGeneration: UInt64 = 0
    private var cachedBadge: (changeCount: Int, badge: ClipboardPinBadge)?
    private var latestSnipPasteboardChangeCount: Int?
    private var cachedCopiedImageIdentity: (changeCount: Int, identity: PinContentIdentity)?

    public static func defaultHistoryDirectoryURL() -> URL {
        SnipHistoryDiskStore.defaultDirectoryURL()
    }

    public init(
        maxHistoryCount: Int = 20,
        historyDirectoryURL: URL? = nil,
        maxHistoryMemoryBytes: Int = ClipboardStore.defaultMaxHistoryMemoryBytes
    ) {
        self.maxHistoryCount = max(0, maxHistoryCount)
        self.maxHistoryMemoryBytes = max(0, maxHistoryMemoryBytes)
        self.pasteboard = SystemClipboardPasteboard(.general)
        if let historyDirectoryURL, self.maxHistoryCount > 0 {
            let store = SnipHistoryDiskStore(directoryURL: historyDirectoryURL)
            self.diskStore = store
            loadPersistedHistory(from: store)
        } else {
            self.diskStore = nil
        }
    }

    /// Creates a store backed by a custom pasteboard (useful for isolated unit tests).
    public init(
        maxHistoryCount: Int = 20,
        pasteboard: any ClipboardPasteboard,
        historyDirectoryURL: URL? = nil,
        maxHistoryMemoryBytes: Int = ClipboardStore.defaultMaxHistoryMemoryBytes
    ) {
        self.maxHistoryCount = max(0, maxHistoryCount)
        self.maxHistoryMemoryBytes = max(0, maxHistoryMemoryBytes)
        self.pasteboard = pasteboard
        if let historyDirectoryURL, self.maxHistoryCount > 0 {
            let store = SnipHistoryDiskStore(directoryURL: historyDirectoryURL)
            self.diskStore = store
            loadPersistedHistory(from: store)
        } else {
            self.diskStore = nil
        }
    }

    /// Whether the pasteboard currently holds any clearable content (images, text, or file URLs such as MP4/MOV recordings).
    public var hasPasteboardContent: Bool {
        pasteboard.hasAnyContent()
    }

    /// Whether the pasteboard has changed since the most recent snip was recorded (or no snip exists).
    public var hasClipboardChangedSinceLatestSnip: Bool {
        guard let latestSnipPasteboardChangeCount else { return true }
        return pasteboard.changeCount != latestSnipPasteboardChangeCount
    }

    @discardableResult
    public func recordSnip(image: CGImage, scale: CGFloat, screenRect: CGRect) -> SnipHistoryEntry? {
        recordSnipInternal(image: image, scale: scale, screenRect: screenRect, preEncodedPNG: nil)
    }

    /// Records a snip in history and copies it to the pasteboard while encoding PNG only once
    /// across both pasteboard writing and background history persistence.
    @discardableResult
    public func recordAndCopyImage(_ image: CGImage, scale: CGFloat, screenRect: CGRect) -> SnipHistoryEntry? {
        let png = Self.encode(image, type: .png, scale: scale)
        let entry = recordSnipInternal(image: image, scale: scale, screenRect: screenRect, preEncodedPNG: png)
        if let png {
            let fingerprint = entry?.fingerprint ?? ImageFingerprint(image: image)
            cachedBadge = nil
            pasteboard.writeLazyImage(png: png) {
                Self.convertImageDataToTIFF(png, scale: scale)
            }
            cachedCopiedImageIdentity = (
                pasteboard.changeCount,
                .image(fingerprint, historyEntryID: entry?.id)
            )
        } else {
            copyImage(image, scale: scale, historyEntryID: entry?.id)
        }
        return entry
    }

    private func recordSnipInternal(
        image: CGImage,
        scale: CGFloat,
        screenRect: CGRect,
        preEncodedPNG: Data?
    ) -> SnipHistoryEntry? {
        latestSnipPasteboardChangeCount = pasteboard.changeCount
        guard maxHistoryCount > 0 else { return nil }

        let baseEntry = SnipHistoryEntry(image: image, scale: scale, screenRect: screenRect)
        let entry: SnipHistoryEntry
        if let preEncodedPNG, let compactImage = Self.decode(preEncodedPNG)?.0 {
            entry = SnipHistoryEntry(
                id: baseEntry.id,
                timestamp: baseEntry.timestamp,
                image: compactImage,
                thumbnail: baseEntry.thumbnail,
                fingerprint: baseEntry.fingerprint,
                scale: baseEntry.scale,
                screenRect: baseEntry.screenRect
            )
        } else {
            entry = baseEntry
        }

        history.insert(entry, at: 0)
        trimHistoryToLimits()
        let startGeneration = clearGeneration
        let onEncodedPNG: (@Sendable (UUID, Data) -> Void)?
        if preEncodedPNG == nil {
            onEncodedPNG = { [weak self] entryID, pngData in
                guard let compactImage = Self.decode(pngData)?.0 else { return }
                Task { @MainActor [weak self] in
                    self?.compactHistoryEntry(id: entryID, with: compactImage, expectedGeneration: startGeneration)
                }
            }
        } else {
            onEncodedPNG = nil
        }
        diskStore?.save(
            entry: entry,
            manifest: currentManifest(),
            preEncodedPNG: preEncodedPNG,
            onEncodedPNG: onEncodedPNG
        )
        onHistoryChanged?()
        return entry
    }

    private func compactHistoryEntry(id: UUID, with compactImage: CGImage, expectedGeneration: UInt64) {
        guard clearGeneration == expectedGeneration,
              let index = history.firstIndex(where: { $0.id == id })
        else { return }
        let existing = history[index]
        guard existing.image.width == compactImage.width,
              existing.image.height == compactImage.height
        else { return }
        history[index] = SnipHistoryEntry(
            id: existing.id,
            timestamp: existing.timestamp,
            image: compactImage,
            thumbnail: existing.thumbnail,
            fingerprint: existing.fingerprint,
            scale: existing.scale,
            screenRect: existing.screenRect
        )
        onHistoryChanged?()
    }

    public func clearHistory() {
        clearGeneration &+= 1
        history.removeAll()
        latestSnipPasteboardChangeCount = nil
        diskStore?.clearAll()
        onHistoryChanged?()
    }

    public func flushPendingPersistence() {
        diskStore?.flush()
    }

    private func trimHistoryToLimits() {
        if history.count > maxHistoryCount {
            history.removeLast(history.count - maxHistoryCount)
        }
        guard maxHistoryMemoryBytes > 0, history.count > 1 else { return }
        var totalBytes = 0
        for entry in history {
            let (next, overflow) = totalBytes.addingReportingOverflow(Self.estimatedMemoryBytes(for: entry.image))
            totalBytes = overflow ? Int.max : next
        }
        while history.count > 1, totalBytes > maxHistoryMemoryBytes {
            let removed = history.removeLast()
            totalBytes = max(0, totalBytes - Self.estimatedMemoryBytes(for: removed.image))
        }
    }

    nonisolated static func estimatedMemoryBytes(for image: CGImage) -> Int {
        let (pixelBytes, overflow1) = image.width.multipliedReportingOverflow(by: image.height)
        let (rgbaBytes, overflow2) = pixelBytes.multipliedReportingOverflow(by: 4)
        let (rowBytes, overflow3) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        if overflow1 || overflow2 {
            return Int.max / 4
        }
        if overflow3 {
            return max(0, rgbaBytes)
        }
        return max(0, max(rgbaBytes, rowBytes))
    }

    private func currentManifest() -> [SnipHistoryManifestRecord] {
        history.map { entry in
            SnipHistoryManifestRecord(
                id: entry.id,
                timestamp: entry.timestamp,
                scale: entry.scale,
                screenRect: entry.screenRect
            )
        }
    }

    private func loadPersistedHistory(from store: SnipHistoryDiskStore) {
        let startGeneration = clearGeneration
        store.loadAll(maxCount: maxHistoryCount, maxTotalMemoryBytes: maxHistoryMemoryBytes) { [weak self] loaded in
            Task { @MainActor [weak self] in
                self?.applyLoadedHistory(loaded, expectedGeneration: startGeneration)
            }
        }
    }

    private func applyLoadedHistory(_ loaded: [SnipHistoryEntry], expectedGeneration: UInt64) {
        guard clearGeneration == expectedGeneration, !loaded.isEmpty else { return }
        let existingIDs = Set(history.map(\.id))
        let appended = loaded.filter { !existingIDs.contains($0.id) }
        guard !appended.isEmpty else { return }
        history.append(contentsOf: appended)
        trimHistoryToLimits()
        onHistoryChanged?()
    }

    /// Empties the pasteboard and invalidates any cached badge, identity, or lazy TIFF provider.
    public func clearClipboard() {
        cachedBadge = nil
        cachedCopiedImageIdentity = nil
        pasteboard.clearContents()
    }

    /// Clears both the in-memory recent snip history and the system pasteboard.
    public func clearHistoryAndClipboard() {
        clearHistory()
        clearClipboard()
    }

    /// Writes PNG immediately and registers a lazy LZW-compressed TIFF provider (only
    /// encoded if a receiving app explicitly requests TIFF).
    public func copyImage(_ image: CGImage, scale: CGFloat, historyEntryID: UUID? = nil) {
        let fingerprint = historyEntryID
            .flatMap { id in history.first(where: { $0.id == id })?.fingerprint }
            ?? ImageFingerprint(image: image)
        if let png = Self.encode(image, type: .png, scale: scale) {
            cachedBadge = nil
            // Capture the already-encoded PNG bytes rather than the uncompressed CGImage
            // so CCX releases the full bitmap immediately while idle.
            pasteboard.writeLazyImage(png: png) {
                Self.convertImageDataToTIFF(png, scale: scale)
            }
        } else if let tiff = Self.encode(image, type: .tiff, scale: scale) {
            cachedBadge = nil
            pasteboard.writeData([(.tiff, tiff)])
        } else {
            // Do not wipe the user's existing clipboard if image encoding fails.
            return
        }
        cachedCopiedImageIdentity = (
            pasteboard.changeCount,
            .image(fingerprint, historyEntryID: historyEntryID)
        )
    }

    public func copyText(_ text: String) {
        cachedBadge = nil
        cachedCopiedImageIdentity = nil
        pasteboard.writeString(text)
    }

    public func copyFileURL(_ url: URL) {
        cachedBadge = nil
        cachedCopiedImageIdentity = nil
        pasteboard.writeFileURLs([url])
    }

    /// Zero-decode clipboard identity lookup when the current pasteboard item is text, HEX color,
    /// or a previously fingerprinted image at the same `changeCount`.
    public func cachedClipboardIdentityIfKnown() -> PinContentIdentity? {
        let changeCount = pasteboard.changeCount
        if let cached = cachedCopiedImageIdentity, cached.changeCount == changeCount {
            return cached.identity
        }
        switch peekPinBadge() {
        case .image, .empty:
            return nil
        case let .color(sample):
            return .color(sample)
        case .text:
            guard let string = pasteboard.string(),
                  let trimmed = Self.trimmedPinText(from: string)
            else {
                return nil
            }
            return .text(trimmed)
        }
    }

    /// Computes or reuses the `PinContentIdentity` for a decoded `ClipboardPinPayload`.
    public func identity(for payload: ClipboardPinPayload) -> PinContentIdentity {
        let changeCount = pasteboard.changeCount
        switch payload {
        case let .image(image, _):
            if let cached = cachedCopiedImageIdentity, cached.changeCount == changeCount {
                return cached.identity
            }
            return .image(ImageFingerprint(image: image))
        case let .color(sample):
            return .color(sample)
        case let .text(string):
            return .text(string)
        }
    }

    /// Reads the pasteboard payload along with its cached or freshly computed identity.
    public func readPinPayloadWithIdentity() -> (payload: ClipboardPinPayload, identity: PinContentIdentity)? {
        let changeCount = pasteboard.changeCount
        guard let payload = readPinPayload() else { return nil }
        let resolved = identity(for: payload)
        if case .image = resolved {
            cachedCopiedImageIdentity = (changeCount, resolved)
        }
        return (payload, resolved)
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
            } else if !string.allSatisfy(\.isWhitespace) {
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
        guard let trimmed = Self.trimmedPinText(from: string) else { return nil }
        return .text(trimmed)
    }

    /// Trims leading/trailing whitespace and newlines on a slice and caps length to `maxPinTextLength`
    /// so multi-MB clipboard text payloads never trigger unbounded allocations or stalls.
    nonisolated static func trimmedPinText(from string: String, maxLength: Int = maxPinTextLength) -> String? {
        guard maxLength > 0 else { return nil }
        var start = string.startIndex
        let endLimit = string.endIndex
        while start < endLimit, string[start].isWhitespace || string[start].isNewline {
            string.formIndex(after: &start)
        }
        guard start < endLimit else { return nil }

        // Advance at most `maxLength` characters from the first non-whitespace character so
        // multi-MB blobs are bounded without ever scanning or copying the entire tail.
        var cappedEnd = start
        var count = 0
        while cappedEnd < endLimit, count < maxLength {
            string.formIndex(after: &cappedEnd)
            count += 1
        }
        var trimmedEnd = cappedEnd
        while trimmedEnd > start {
            let prev = string.index(before: trimmedEnd)
            if string[prev].isWhitespace || string[prev].isNewline {
                trimmedEnd = prev
            } else {
                break
            }
        }
        guard start < trimmedEnd else { return nil }
        return String(string[start..<trimmedEnd])
    }

    /// Encodes `image` as PNG data off or on the main actor.
    public nonisolated static func encodePNG(_ image: CGImage, scale: CGFloat = 1) -> Data? {
        encode(image, type: .png, scale: scale)
    }

    /// Atomically writes pre-encoded PNG data to `url`, refusing symlinks and non-regular destinations
    /// while preserving any existing file if writing fails.
    public nonisolated static func writePNGDataAtomically(_ data: Data, to url: URL) throws {
        guard url.isFileURL else {
            throw ClipboardStoreError.writeFailed
        }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty else {
            throw ClipboardStoreError.writeFailed
        }
        var st = stat()
        if Darwin.lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw ClipboardStoreError.writeFailed
            }
        } else if errno != ENOENT {
            throw ClipboardStoreError.writeFailed
        }
        let normalizedURL = URL(fileURLWithPath: path, isDirectory: false)
        do {
            try data.write(to: normalizedURL, options: .atomic)
        } catch {
            throw ClipboardStoreError.writeFailed
        }
    }

    /// Atomically creates a new unique `.png` file inside `directory` without ever overwriting
    /// existing files or following symlinks, even under concurrent quick saves in the same second.
    public nonisolated static func writePNGDataExclusively(
        _ data: Data,
        in directory: URL,
        stem: String,
        maxSuffixAttempts: Int = 9_999
    ) throws -> URL {
        guard directory.isFileURL,
              !stem.isEmpty,
              stem != ".",
              stem != "..",
              !stem.contains("/"),
              !stem.contains("\\"),
              !stem.contains("\0")
        else {
            throw ClipboardStoreError.writeFailed
        }
        var dirPath = directory.path
        while dirPath.count > 1 && dirPath.hasSuffix("/") {
            dirPath.removeLast()
        }
        guard !dirPath.isEmpty else {
            throw ClipboardStoreError.writeFailed
        }
        var dirStat = stat()
        guard Darwin.lstat(dirPath, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR
        else {
            throw ClipboardStoreError.writeFailed
        }

        let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        let tempURL = dirURL.appendingPathComponent(".ccx-save-\(UUID().uuidString).tmp", isDirectory: false)
        let tempPath = tempURL.path
        let fd = Darwin.open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw ClipboardStoreError.writeFailed
        }

        var movedTemp = false
        defer {
            if !movedTemp {
                _ = Darwin.unlink(tempPath)
            }
        }

        let wroteAll = writeAllBytes(data, to: fd)
        let closedOK = Darwin.close(fd) == 0
        guard wroteAll, closedOK else {
            throw ClipboardStoreError.writeFailed
        }

        var suffix = 1
        var usedUUIDFallback = false
        while true {
            let candidateName: String
            if suffix == 1 {
                candidateName = "\(stem).png"
            } else if suffix <= maxSuffixAttempts {
                candidateName = "\(stem)-\(suffix).png"
            } else if !usedUUIDFallback {
                usedUUIDFallback = true
                candidateName = "\(stem)-\(UUID().uuidString.prefix(8)).png"
            } else {
                throw ClipboardStoreError.writeFailed
            }

            let candidateURL = dirURL.appendingPathComponent(candidateName, isDirectory: false)
            let candidatePath = candidateURL.path

            if Darwin.renamex_np(tempPath, candidatePath, UInt32(RENAME_EXCL)) == 0 {
                movedTemp = true
                return candidateURL
            }
            let err = errno
            if err == EEXIST {
                suffix += 1
                continue
            }
            if err == ENOTSUP || err == EOPNOTSUPP || err == EINVAL {
                if Darwin.link(tempPath, candidatePath) == 0 {
                    _ = Darwin.unlink(tempPath)
                    movedTemp = true
                    return candidateURL
                }
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
                // Volumes without hard-link support (e.g. FAT32/exFAT): exclusive create directly.
                let directFD = Darwin.open(candidatePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                if directFD >= 0 {
                    let directOK = writeAllBytes(data, to: directFD)
                    let directClosed = Darwin.close(directFD) == 0
                    if directOK && directClosed {
                        return candidateURL
                    }
                    _ = Darwin.unlink(candidatePath)
                    throw ClipboardStoreError.writeFailed
                }
                if errno == EEXIST {
                    suffix += 1
                    continue
                }
            }
            throw ClipboardStoreError.writeFailed
        }
    }

    private nonisolated static func writeAllBytes(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written > 0 {
                    offset += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    public func savePNG(_ image: CGImage, to url: URL) throws {
        guard let data = Self.encodePNG(image, scale: 1) else {
            throw ClipboardStoreError.encodingFailed
        }
        try Self.writePNGDataAtomically(data, to: url)
    }

    // MARK: - Helpers

    private func readImage() -> (CGImage, CGFloat)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let decoded = Self.decode(data) {
                return decoded
            }
        }
        for url in pasteboard.readImageFileURLs() {
            if let decoded = Self.decodeImageFile(at: url) {
                return decoded
            }
        }
        return nil
    }

    /// Safely reads a regular image file URL (rejecting FIFOs, device nodes, directories, and
    /// files exceeding `maxDecodeFileBytes`) and decodes it with decompression-bomb guards.
    nonisolated static func decodeImageFile(at url: URL) -> (CGImage, CGFloat)? {
        guard url.isFileURL else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0,
              st.st_size <= Int64(maxDecodeFileBytes)
        else { return nil }

        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress, buf.count)
            }
            if bytesRead > 0 {
                if data.count + bytesRead > maxDecodeFileBytes { return nil }
                data.append(chunk, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return decode(data)
    }

    private nonisolated static func convertImageDataToTIFF(_ pngData: Data, scale: CGFloat) -> Data? {
        guard let (image, _) = decode(pngData) else { return nil }
        return encode(image, type: .tiff, scale: scale)
    }

    nonisolated static func encode(_ image: CGImage, type: UTType, scale: CGFloat) -> Data? {
        autoreleasepool {
            guard image.width > 0, image.height > 0 else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, type.identifier as CFString, 1, nil
            ) else { return nil }
            let safeScale = (scale.isFinite && scale > 0) ? max(scale, 0.01) : 1
            let dpi = 72 * safeScale
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
    }

    /// Decodes image data with pixel-dimension/decompression-bomb guards and derives the
    /// pixel scale from its DPI metadata (72 DPI = 1x).
    nonisolated static func decode(_ data: Data) -> (CGImage, CGFloat)? {
        guard !data.isEmpty, data.count <= maxDecodeFileBytes else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let propWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let propHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              isSafeImageSize(width: propWidth, height: propHeight)
        else {
            return nil
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions),
              isSafeImageSize(width: image.width, height: image.height)
        else { return nil }

        var scale: CGFloat = 1
        if let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
           dpi.isFinite, dpi > 0 {
            let computed = (CGFloat(dpi) / 72 * 100).rounded() / 100
            if computed.isFinite {
                scale = min(max(computed, 1), 8)
            }
        }
        return (image, scale)
    }

    private nonisolated static func isSafeImageSize(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0,
              width <= maxDecodeDimension,
              height <= maxDecodeDimension
        else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maxDecodePixels
    }
}
