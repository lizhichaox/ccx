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

public enum SnipHistoryRetention: String, CaseIterable, Codable, Sendable {
    case keep20
    case clearAfter24Hours
    case clearOnQuit
    case disabled

    public var localizedTitle: String {
        switch self {
        case .keep20:
            CCXL10n.text("Keep Last 20", zh: "保留最近 20 条")
        case .clearAfter24Hours:
            CCXL10n.text("Clear After 24h", zh: "24 小时后清理")
        case .clearOnQuit:
            CCXL10n.text("Clear on Quit", zh: "退出时清理")
        case .disabled:
            CCXL10n.text("Don't Save", zh: "不保存记录")
        }
    }
}

private final class LazyHistoryImageStorage: @unchecked Sendable {
    let inMemoryImage: CGImage?
    let backingFileURL: URL?
    let fallbackThumbnail: CGImage

    init(inMemoryImage: CGImage?, backingFileURL: URL?, fallbackThumbnail: CGImage) {
        self.inMemoryImage = inMemoryImage
        self.backingFileURL = backingFileURL
        self.fallbackThumbnail = fallbackThumbnail
    }

    func resolveImage() -> CGImage {
        if let inMemoryImage {
            return inMemoryImage
        }
        if let backingFileURL,
           let data = SnipHistoryDiskStore.readPrivateRegularFile(at: backingFileURL, maxBytes: ClipboardStore.maxDecodeFileBytes),
           let (decoded, _) = ClipboardStore.decode(data)
        {
            return decoded
        }
        return fallbackThumbnail
    }
}

/// One captured snip kept in the in-memory history.
public struct SnipHistoryEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Pre-downsampled thumbnail (max 160px on longest side) for fast popover rendering.
    public let thumbnail: CGImage
    /// Visual fingerprint used to deduplicate clipboard copies and on-screen pins.
    public let fingerprint: ImageFingerprint
    /// Pixels per point of `image`.
    public let scale: CGFloat
    /// Captured area in AppKit global screen coordinates (points).
    public let screenRect: CGRect

    private let imageStorage: LazyHistoryImageStorage

    /// Full-resolution image, loaded lazily from the private disk cache when backed on disk.
    public var image: CGImage {
        imageStorage.resolveImage()
    }

    /// Returns `true` when the full-resolution `CGImage` is already resident in RAM (not disk-backed).
    public var hasInMemoryFullImage: Bool {
        imageStorage.inMemoryImage != nil
    }

    /// Exposed for testing lazy startup loading without decoding disk-backed full PNGs.
    public var hasInMemoryFullImageForTesting: Bool {
        hasInMemoryFullImage
    }

    var estimatedMemoryBytes: Int {
        ClipboardStore.estimatedMemoryBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    public var pinIdentity: PinContentIdentity {
        .image(fingerprint, historyEntryID: id)
    }

    public init(id: UUID = UUID(), timestamp: Date = Date(), image: CGImage, scale: CGFloat, screenRect: CGRect) {
        let thumb = Self.makeThumbnail(from: image, maxPixelDimension: 160)
        self.id = id
        self.timestamp = timestamp
        self.pixelWidth = image.width
        self.pixelHeight = image.height
        self.thumbnail = thumb
        self.fingerprint = ImageFingerprint(image: image)
        self.scale = scale
        self.screenRect = screenRect
        self.imageStorage = LazyHistoryImageStorage(
            inMemoryImage: image,
            backingFileURL: nil,
            fallbackThumbnail: thumb
        )
    }

    internal init(
        id: UUID,
        timestamp: Date,
        pixelWidth: Int,
        pixelHeight: Int,
        thumbnail: CGImage,
        fingerprint: ImageFingerprint,
        scale: CGFloat,
        screenRect: CGRect,
        backingFileURL: URL?,
        inMemoryImage: CGImage?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.thumbnail = thumbnail
        self.fingerprint = fingerprint
        self.scale = scale
        self.screenRect = screenRect
        self.imageStorage = LazyHistoryImageStorage(
            inMemoryImage: inMemoryImage,
            backingFileURL: backingFileURL,
            fallbackThumbnail: thumbnail
        )
    }

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    static func makeThumbnail(from image: CGImage, maxPixelDimension: CGFloat) -> CGImage {
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
    func writeLazyImage(png: Data, concealed: Bool, tiffProvider: @escaping @Sendable () -> Data?)
    func writeString(_ string: String)
    func writeString(_ string: String, concealed: Bool)
    func writeFileURLs(_ urls: [URL])
    func writeFileURLs(_ urls: [URL], concealed: Bool)
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

    func writeLazyImage(png: Data, concealed: Bool, tiffProvider: @escaping @Sendable () -> Data?) {
        if !concealed {
            writeLazyImage(png: png, tiffProvider: tiffProvider)
            return
        }
        var items: [(NSPasteboard.PasteboardType, Data)] = [
            (.png, png),
            (ClipboardStore.transientPasteboardType, Data()),
        ]
        if let tiff = tiffProvider() {
            items.append((.tiff, tiff))
        }
        writeData(items)
    }

    func writeString(_ string: String, concealed: Bool) {
        writeString(string)
    }

    func writeFileURLs(_ urls: [URL]) {}

    func writeFileURLs(_ urls: [URL], concealed: Bool) {
        writeFileURLs(urls)
    }

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
        writeLazyImage(png: png, concealed: false, tiffProvider: tiffProvider)
    }

    func writeLazyImage(png: Data, concealed: Bool, tiffProvider: @escaping @Sendable () -> Data?) {
        releaseActiveProvider()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if concealed {
            item.setData(Data(), forType: ClipboardStore.transientPasteboardType)
        }
        let provider = LazyTIFFDataProvider(tiffProvider)
        activeDataProvider = provider
        item.setDataProvider(provider, forTypes: [.tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func writeString(_ string: String) {
        writeString(string, concealed: false)
    }

    func writeString(_ string: String, concealed: Bool) {
        releaseActiveProvider()
        pasteboard.clearContents()
        if concealed {
            let item = NSPasteboardItem()
            item.setString(string, forType: .string)
            item.setData(Data(), forType: ClipboardStore.transientPasteboardType)
            pasteboard.writeObjects([item])
        } else {
            pasteboard.setString(string, forType: .string)
        }
    }

    func writeFileURLs(_ urls: [URL]) {
        writeFileURLs(urls, concealed: false)
    }

    func writeFileURLs(_ urls: [URL], concealed: Bool) {
        releaseActiveProvider()
        pasteboard.clearContents()
        guard concealed, !urls.isEmpty else {
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            return
        }
        let items: [NSPasteboardItem] = urls.enumerated().map { index, url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index == 0 {
                item.setData(Data(), forType: ClipboardStore.transientPasteboardType)
            }
            return item
        }
        pasteboard.writeObjects(items)
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
        writeString(string, concealed: false)
    }

    public func writeString(_ string: String, concealed: Bool) {
        dataByType.removeAll()
        storedImageFileURLs = []
        storedAllFileURLs = []
        text = string
        if concealed {
            dataByType[ClipboardStore.transientPasteboardType] = Data()
        }
        changeCount += 1
    }

    public func writeFileURLs(_ urls: [URL]) {
        writeFileURLs(urls, concealed: false)
    }

    public func writeFileURLs(_ urls: [URL], concealed: Bool) {
        dataByType.removeAll()
        text = nil
        storedAllFileURLs = urls
        storedImageFileURLs = urls.filter(Self.isImageFileURL)
        if concealed {
            dataByType[ClipboardStore.transientPasteboardType] = Data()
        }
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
    /// Expiration window applied when `retentionPolicy == .clearAfter24Hours`.
    public nonisolated static let retention24HoursInterval: TimeInterval = 24 * 60 * 60
    /// Convention pasteboard marker honored by 3rd-party clipboard managers (Paste, Raycast, Maccy, Alfred)
    /// to skip indexing transient or private copies.
    public nonisolated static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// Upper bound on text characters extracted from the pasteboard for floating text pins.
    public nonisolated static let maxPinTextLength = 100_000
    nonisolated static let maxDecodeFileBytes = 100 * 1024 * 1024 // 100 MB
    nonisolated static let maxDecodeDimension = 32_768
    nonisolated static let maxDecodePixels = 100_000_000 // 100 MP

    private static let retentionDefaultsKey = "CCXSnipHistoryRetention"
    private static let concealDefaultsKey = "CCXConcealClipboardFromManagers"

    public let maxHistoryCount: Int
    public let maxHistoryMemoryBytes: Int
    /// Controls how long recent snips remain stored on disk and in memory.
    public var retentionPolicy: SnipHistoryRetention {
        didSet {
            guard retentionPolicy != oldValue else { return }
            userDefaults?.set(retentionPolicy.rawValue, forKey: Self.retentionDefaultsKey)
            switch retentionPolicy {
            case .disabled:
                clearHistory()
            case .clearAfter24Hours:
                pruneExpiredHistoryIfNeeded()
            case .keep20, .clearOnQuit:
                break
            }
        }
    }
    /// When enabled, copies written by CCX tag the item with `org.nspasteboard.TransientType`.
    public var concealFromClipboardManagers: Bool {
        didSet {
            guard concealFromClipboardManagers != oldValue else { return }
            userDefaults?.set(concealFromClipboardManagers, forKey: Self.concealDefaultsKey)
        }
    }
    /// Most recent snip first, capped at `maxHistoryCount` and `maxHistoryMemoryBytes`.
    public private(set) var history: [SnipHistoryEntry] = []
    /// Invoked on the main actor whenever `history` changes (snip recorded, cleared, or loaded from disk).
    public var onHistoryChanged: (() -> Void)?

    private let pasteboard: any ClipboardPasteboard
    private let diskStore: SnipHistoryDiskStore?
    private let userDefaults: UserDefaults?
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
        maxHistoryMemoryBytes: Int = ClipboardStore.defaultMaxHistoryMemoryBytes,
        userDefaults: UserDefaults? = nil
    ) {
        self.maxHistoryCount = max(0, maxHistoryCount)
        self.maxHistoryMemoryBytes = max(0, maxHistoryMemoryBytes)
        self.pasteboard = SystemClipboardPasteboard(.general)
        self.userDefaults = userDefaults
        self.retentionPolicy = Self.loadRetentionPolicy(from: userDefaults)
        self.concealFromClipboardManagers = userDefaults?.bool(forKey: Self.concealDefaultsKey) ?? false
        if let historyDirectoryURL, self.maxHistoryCount > 0 {
            let store = SnipHistoryDiskStore(directoryURL: historyDirectoryURL)
            self.diskStore = store
            if self.retentionPolicy == .disabled || self.retentionPolicy == .clearOnQuit {
                store.clearAll()
            } else {
                loadPersistedHistory(from: store)
            }
        } else {
            self.diskStore = nil
        }
    }

    /// Creates a store backed by a custom pasteboard (useful for isolated unit tests).
    public init(
        maxHistoryCount: Int = 20,
        pasteboard: any ClipboardPasteboard,
        historyDirectoryURL: URL? = nil,
        maxHistoryMemoryBytes: Int = ClipboardStore.defaultMaxHistoryMemoryBytes,
        userDefaults: UserDefaults? = nil
    ) {
        self.maxHistoryCount = max(0, maxHistoryCount)
        self.maxHistoryMemoryBytes = max(0, maxHistoryMemoryBytes)
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults
        self.retentionPolicy = Self.loadRetentionPolicy(from: userDefaults)
        self.concealFromClipboardManagers = userDefaults?.bool(forKey: Self.concealDefaultsKey) ?? false
        if let historyDirectoryURL, self.maxHistoryCount > 0 {
            let store = SnipHistoryDiskStore(directoryURL: historyDirectoryURL)
            self.diskStore = store
            if self.retentionPolicy == .disabled || self.retentionPolicy == .clearOnQuit {
                store.clearAll()
            } else {
                loadPersistedHistory(from: store)
            }
        } else {
            self.diskStore = nil
        }
    }

    private static func loadRetentionPolicy(from defaults: UserDefaults?) -> SnipHistoryRetention {
        guard let raw = defaults?.string(forKey: retentionDefaultsKey),
              let parsed = SnipHistoryRetention(rawValue: raw)
        else {
            return .keep20
        }
        return parsed
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
            pasteboard.writeLazyImage(png: png, concealed: concealFromClipboardManagers) {
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
        guard maxHistoryCount > 0, retentionPolicy != .disabled else { return nil }
        latestSnipPasteboardChangeCount = pasteboard.changeCount

        let baseEntry = SnipHistoryEntry(image: image, scale: scale, screenRect: screenRect)
        let entry: SnipHistoryEntry
        if let preEncodedPNG, let compactImage = Self.decode(preEncodedPNG)?.0 {
            entry = SnipHistoryEntry(
                id: baseEntry.id,
                timestamp: baseEntry.timestamp,
                pixelWidth: compactImage.width,
                pixelHeight: compactImage.height,
                thumbnail: baseEntry.thumbnail,
                fingerprint: baseEntry.fingerprint,
                scale: baseEntry.scale,
                screenRect: baseEntry.screenRect,
                backingFileURL: nil,
                inMemoryImage: compactImage
            )
        } else {
            entry = baseEntry
        }

        history.insert(entry, at: 0)
        trimHistoryToLimits()
        let startGeneration = clearGeneration
        let onPersistedToDisk: (@Sendable (UUID, URL) -> Void)?
        if diskStore != nil {
            onPersistedToDisk = { [weak self] entryID, pngURL in
                Task { @MainActor [weak self] in
                    self?.compactHistoryEntryToDisk(id: entryID, pngURL: pngURL, expectedGeneration: startGeneration)
                }
            }
        } else {
            onPersistedToDisk = nil
        }
        diskStore?.save(
            entry: entry,
            manifest: currentManifest(),
            preEncodedPNG: preEncodedPNG,
            onPersistedToDisk: onPersistedToDisk
        )
        onHistoryChanged?()
        return entry
    }

    private func compactHistoryEntryToDisk(id: UUID, pngURL: URL, expectedGeneration: UInt64) {
        guard clearGeneration == expectedGeneration,
              let index = history.firstIndex(where: { $0.id == id })
        else { return }
        let existing = history[index]
        history[index] = SnipHistoryEntry(
            id: existing.id,
            timestamp: existing.timestamp,
            pixelWidth: existing.pixelWidth,
            pixelHeight: existing.pixelHeight,
            thumbnail: existing.thumbnail,
            fingerprint: existing.fingerprint,
            scale: existing.scale,
            screenRect: existing.screenRect,
            backingFileURL: pngURL,
            inMemoryImage: nil
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

    /// Removes entries older than 24 hours when `retentionPolicy == .clearAfter24Hours`.
    public func pruneExpiredHistoryIfNeeded(now: Date = Date()) {
        guard retentionPolicy == .clearAfter24Hours else { return }
        let cutoff = now.addingTimeInterval(-Self.retention24HoursInterval)
        let originalCount = history.count
        history.removeAll { $0.timestamp < cutoff }
        guard history.count != originalCount else { return }
        if history.isEmpty {
            latestSnipPasteboardChangeCount = nil
        }
        diskStore?.saveManifestOnly(currentManifest())
        onHistoryChanged?()
    }

    /// Flushes or purges history on application termination according to `retentionPolicy`.
    public func handleApplicationWillTerminate() {
        if retentionPolicy == .clearOnQuit || retentionPolicy == .disabled {
            clearHistory()
        }
        flushPendingPersistence()
    }

    public func flushPendingPersistence() {
        diskStore?.flush()
    }

    private func trimHistoryToLimits(now: Date = Date()) {
        if retentionPolicy == .clearAfter24Hours {
            let cutoff = now.addingTimeInterval(-Self.retention24HoursInterval)
            history.removeAll { $0.timestamp < cutoff }
        }
        if history.count > maxHistoryCount {
            history.removeLast(history.count - maxHistoryCount)
        }
        guard maxHistoryMemoryBytes > 0, history.count > 1 else { return }
        var totalBytes = 0
        for entry in history {
            let (next, overflow) = totalBytes.addingReportingOverflow(entry.estimatedMemoryBytes)
            totalBytes = overflow ? Int.max : next
        }
        while history.count > 1, totalBytes > maxHistoryMemoryBytes {
            let removed = history.removeLast()
            totalBytes = max(0, totalBytes - removed.estimatedMemoryBytes)
        }
    }

    nonisolated static func estimatedMemoryBytes(pixelWidth: Int, pixelHeight: Int) -> Int {
        let (pixelBytes, overflow1) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        let (rgbaBytes, overflow2) = pixelBytes.multipliedReportingOverflow(by: 4)
        if overflow1 || overflow2 {
            return Int.max / 4
        }
        return max(0, rgbaBytes)
    }

    nonisolated static func estimatedMemoryBytes(for image: CGImage) -> Int {
        let rgbaBytes = estimatedMemoryBytes(pixelWidth: image.width, pixelHeight: image.height)
        let (rowBytes, overflow3) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
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
                screenRect: entry.screenRect,
                pixelWidth: entry.pixelWidth,
                pixelHeight: entry.pixelHeight,
                fingerprint: entry.fingerprint
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
        guard clearGeneration == expectedGeneration,
              retentionPolicy != .disabled,
              !loaded.isEmpty
        else { return }
        let existingIDs = Set(history.map(\.id))
        let appended = loaded.filter { !existingIDs.contains($0.id) }
        guard !appended.isEmpty else { return }
        let beforeCount = history.count + appended.count
        history.append(contentsOf: appended)
        trimHistoryToLimits()
        if history.count < beforeCount, retentionPolicy == .clearAfter24Hours {
            diskStore?.saveManifestOnly(currentManifest())
        }
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
            pasteboard.writeLazyImage(png: png, concealed: concealFromClipboardManagers) {
                Self.convertImageDataToTIFF(png, scale: scale)
            }
        } else if let tiff = Self.encode(image, type: .tiff, scale: scale) {
            cachedBadge = nil
            var items: [(NSPasteboard.PasteboardType, Data)] = [(.tiff, tiff)]
            if concealFromClipboardManagers {
                items.append((Self.transientPasteboardType, Data()))
            }
            pasteboard.writeData(items)
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
        pasteboard.writeString(text, concealed: concealFromClipboardManagers)
    }

    public func copyFileURL(_ url: URL) {
        cachedBadge = nil
        cachedCopiedImageIdentity = nil
        pasteboard.writeFileURLs([url], concealed: concealFromClipboardManagers)
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
        do {
            try AtomicFileWriter.writeDataAtomically(data, to: url)
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
        do {
            return try AtomicFileWriter.writeDataExclusively(
                data,
                in: directory,
                stem: stem,
                fileExtension: "png",
                maxSuffixAttempts: maxSuffixAttempts
            )
        } catch {
            throw ClipboardStoreError.writeFailed
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

    /// Generates a bounded thumbnail directly via ImageIO without decoding the full bitmap when possible.
    nonisolated static func inspectAndMakeThumbnail(
        from pngData: Data,
        maxPixelDimension: CGFloat = 160
    ) -> (thumbnail: CGImage?, pixelWidth: Int, pixelHeight: Int)? {
        guard !pngData.isEmpty, pngData.count <= maxDecodeFileBytes else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(pngData as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let propWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let propHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              isSafeImageSize(width: propWidth, height: propHeight)
        else {
            return nil
        }
        // Ultra-tall scroll captures use a top-cropped thumbnail built from full decode in `loadAll`.
        if Double(propHeight) > Double(propWidth) * 2.5 {
            return (nil, propWidth, propHeight)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelDimension.rounded())),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary),
              thumbnail.width > 0,
              thumbnail.height > 0
        else {
            return nil
        }
        return (thumbnail, propWidth, propHeight)
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
