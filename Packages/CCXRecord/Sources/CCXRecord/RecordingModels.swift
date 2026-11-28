import AVFoundation
import CCXCore
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Supported screen recording output formats.
public enum RecordingFormat: String, CaseIterable, Codable, Sendable {
    case mp4
    case mov
    case gif

    public var label: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .gif: "GIF"
        }
    }

    public var fileExtension: String {
        rawValue
    }

    /// Video formats embed an optional mixed AAC audio track; GIF images do not carry audio.
    public var supportsAudio: Bool {
        self != .gif
    }

    public var utType: UTType {
        switch self {
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .gif: .gif
        }
    }

    public var avFileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .gif: nil
        }
    }

    public var videoCodec: AVVideoCodecType? {
        switch self {
        case .mp4: .h264
        case .mov: .hevc
        case .gif: nil
        }
    }

    public var targetFPS: Int {
        switch self {
        case .mp4, .mov: 60
        case .gif: 15
        }
    }

    /// User-selectable frame rates offered in the pre-recording HUD for each format.
    public var availableFPSOptions: [Int] {
        switch self {
        case .mp4, .mov: [24, 30, 60]
        case .gif: [10, 15, 20, 30]
        }
    }

    public func fpsOptionDescription(for fps: Int) -> String {
        switch self {
        case .gif:
            switch fps {
            case 10: CCXL10n.text("10 fps · Compact", zh: "10 fps · 精简")
            case 15: CCXL10n.text("15 fps · Balanced", zh: "15 fps · 均衡")
            case 20: CCXL10n.text("20 fps · Smooth", zh: "20 fps · 流畅")
            case 30: CCXL10n.text("30 fps · High", zh: "30 fps · 高帧率")
            default: "\(fps) fps"
            }
        case .mp4, .mov:
            switch fps {
            case 24: CCXL10n.text("24 fps · Compact", zh: "24 fps · 精简")
            case 30: CCXL10n.text("30 fps · Standard", zh: "30 fps · 标准")
            case 60: CCXL10n.text("60 fps · Smooth", zh: "60 fps · 流畅")
            default: "\(fps) fps"
            }
        }
    }

    public var detailDescription: String {
        switch self {
        case .mp4: CCXL10n.text("H.264 Video", zh: "H.264 视频")
        case .mov: CCXL10n.text("HEVC Video", zh: "HEVC 视频")
        case .gif: CCXL10n.text("Animated Image", zh: "动图")
        }
    }
}

/// Selected display rectangle handed from `CCXCapture` to start a recording session.
public struct RecordingRegion: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let displayFrame: CGRect
    public let localRect: CGRect
    public let screenRect: CGRect
    public let scale: CGFloat

    public init(
        displayID: CGDirectDisplayID,
        displayFrame: CGRect,
        localRect: CGRect,
        screenRect: CGRect,
        scale: CGFloat
    ) {
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.localRect = localRect
        self.screenRect = screenRect
        self.scale = scale
    }

    private static let maxH264PixelDimension: CGFloat = 4_096
    private static let maxVideoPixelDimension: CGFloat = 8_192
    private static let maxGifPixelDimension: Int = 4_096

    private static func isFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite &&
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite
    }

    private static func sanitizeScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(1, scale), 8)
    }

    /// Region in top-left display point coordinates suitable for `SCStreamConfiguration.sourceRect`.
    public var sourceRectInDisplayPoints: CGRect {
        let safeDisplay = Self.isFiniteRect(displayFrame) ? displayFrame.standardized : .zero
        let raw = Self.isFiniteRect(localRect) ? localRect.standardized : CGRect(x: 0, y: 0, width: 1, height: 1)

        guard safeDisplay.width >= 1, safeDisplay.height >= 1 else {
            let safeW = min(max(1, raw.width), Self.maxVideoPixelDimension)
            let safeH = min(max(1, raw.height), Self.maxVideoPixelDimension)
            return CGRect(x: 0, y: 0, width: safeW, height: safeH)
        }

        let bounds = CGRect(origin: .zero, size: safeDisplay.size)
        let clipped = raw.intersection(bounds)
        let effective: CGRect
        if !clipped.isNull && clipped.width >= 1 && clipped.height >= 1 {
            effective = clipped
        } else {
            let clampedW = min(max(1, raw.width), bounds.width)
            let clampedH = min(max(1, raw.height), bounds.height)
            let maxX = max(0, bounds.width - clampedW)
            let maxY = max(0, bounds.height - clampedH)
            let clampedX = min(max(raw.minX, 0), maxX)
            let clampedY = min(max(raw.minY, 0), maxY)
            effective = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
        }
        let topY = min(max(0, safeDisplay.height - effective.maxY), max(0, safeDisplay.height - effective.height))
        return CGRect(
            x: effective.minX,
            y: topY,
            width: max(1, effective.width),
            height: max(1, effective.height)
        )
    }

    /// Returns a copy with `localRect` (and derived `screenRect`) clamped inside `displayFrame`.
    public func updating(localRect newLocalRect: CGRect) -> RecordingRegion {
        let safeDisplay = Self.isFiniteRect(displayFrame) ? displayFrame.standardized : .zero
        let localBounds = CGRect(origin: .zero, size: safeDisplay.size)
        let fallbackLocal = Self.isFiniteRect(localRect) ? localRect.standardized : CGRect(x: 0, y: 0, width: 1, height: 1)
        let standardized = Self.isFiniteRect(newLocalRect) ? newLocalRect.standardized : fallbackLocal

        let maxBoundsW = max(1, localBounds.width)
        let maxBoundsH = max(1, localBounds.height)
        let clampedWidth = min(max(1, standardized.width), maxBoundsW)
        let clampedHeight = min(max(1, standardized.height), maxBoundsH)
        let maxX = max(localBounds.minX, localBounds.maxX - clampedWidth)
        let maxY = max(localBounds.minY, localBounds.maxY - clampedHeight)
        let clamped = CGRect(
            x: min(max(standardized.minX, localBounds.minX), maxX),
            y: min(max(standardized.minY, localBounds.minY), maxY),
            width: clampedWidth,
            height: clampedHeight
        )
        let updatedScreenRect = clamped.offsetBy(dx: safeDisplay.minX, dy: safeDisplay.minY)
        return RecordingRegion(
            displayID: displayID,
            displayFrame: safeDisplay,
            localRect: clamped,
            screenRect: updatedScreenRect,
            scale: Self.sanitizeScale(scale)
        )
    }

    /// Even-pixel dimensions required by H.264 / HEVC hardware encoders (`>= 2`).
    public var videoPixelSize: CGSize {
        let source = sourceRectInDisplayPoints
        let effectiveScale = Self.sanitizeScale(scale)
        let rawW = min(max(2, source.width * effectiveScale), Self.maxVideoPixelDimension)
        let rawH = min(max(2, source.height * effectiveScale), Self.maxVideoPixelDimension)
        let snapped = CoordinateConverter.snapToEvenPixels(
            CGRect(x: 0, y: 0, width: rawW, height: rawH)
        )
        return snapped.size
    }

    /// Proportional even-pixel dimensions for GIF recording capped at `maxDimension`.
    public func gifPixelSize(maxDimension: Int = 1280) -> CGSize {
        let source = sourceRectInDisplayPoints
        let effectiveScale = Self.sanitizeScale(scale)
        var width = min(max(2, source.width * effectiveScale), Self.maxVideoPixelDimension)
        var height = min(max(2, source.height * effectiveScale), Self.maxVideoPixelDimension)
        let safeCap = min(max(2, maxDimension), Self.maxGifPixelDimension)
        let cap = CGFloat(safeCap)
        let largest = max(width, height)
        if largest > cap {
            let ratio = cap / largest
            width *= ratio
            height *= ratio
        }
        return CoordinateConverter.snapToEvenPixels(CGRect(x: 0, y: 0, width: width, height: height)).size
    }

    /// Encoded even-pixel dimensions tailored to `format` hardware encoder limits
    /// (H.264 MP4 capped proportionally at 4096 px for Intel/Apple Silicon 5K/6K display reliability,
    /// HEVC MOV up to 8192 px, GIF capped at 1280 px).
    public func pixelSize(for format: RecordingFormat) -> CGSize {
        switch format {
        case .gif:
            return gifPixelSize()
        case .mov:
            return videoPixelSize
        case .mp4:
            let base = videoPixelSize
            let largest = max(base.width, base.height)
            guard largest > Self.maxH264PixelDimension else { return base }
            let ratio = Self.maxH264PixelDimension / largest
            return CoordinateConverter.snapToEvenPixels(
                CGRect(x: 0, y: 0, width: base.width * ratio, height: base.height * ratio)
            ).size
        }
    }
}

/// User-configured options for recording format, frame rates, audio tracks, and cursor visibility.
public struct RecordingSettings: Codable, Equatable, Sendable {
    public var format: RecordingFormat
    public var videoFPS: Int
    public var gifFPS: Int
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    public var showsCursor: Bool
    public var countdownSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case format, videoFPS, gifFPS, capturesSystemAudio, capturesMicrophone, showsCursor, countdownSeconds
    }

    public init(
        format: RecordingFormat = .mp4,
        videoFPS: Int = RecordingFormat.mp4.targetFPS,
        gifFPS: Int = RecordingFormat.gif.targetFPS,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        showsCursor: Bool = true,
        countdownSeconds: Int = 0
    ) {
        self.format = format
        self.videoFPS = RecordingFormat.mp4.availableFPSOptions.contains(videoFPS)
            ? videoFPS
            : RecordingFormat.mp4.targetFPS
        self.gifFPS = RecordingFormat.gif.availableFPSOptions.contains(gifFPS)
            ? gifFPS
            : RecordingFormat.gif.targetFPS
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.showsCursor = showsCursor
        self.countdownSeconds = (countdownSeconds == 3) ? 3 : 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = (try? container.decodeIfPresent(RecordingFormat.self, forKey: .format)) ?? .mp4
        let videoFPS = (try? container.decodeIfPresent(Int.self, forKey: .videoFPS)) ?? RecordingFormat.mp4.targetFPS
        let gifFPS = (try? container.decodeIfPresent(Int.self, forKey: .gifFPS)) ?? RecordingFormat.gif.targetFPS
        let capturesSystemAudio = (try? container.decodeIfPresent(Bool.self, forKey: .capturesSystemAudio)) ?? true
        let capturesMicrophone = (try? container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone)) ?? false
        let showsCursor = (try? container.decodeIfPresent(Bool.self, forKey: .showsCursor)) ?? true
        let countdownSeconds = (try? container.decodeIfPresent(Int.self, forKey: .countdownSeconds)) ?? 0
        self.init(
            format: format,
            videoFPS: videoFPS,
            gifFPS: gifFPS,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            showsCursor: showsCursor,
            countdownSeconds: countdownSeconds
        )
    }

    /// Active target frame rate for the currently selected format.
    public var effectiveFPS: Int {
        switch format {
        case .gif:
            RecordingFormat.gif.availableFPSOptions.contains(gifFPS) ? gifFPS : RecordingFormat.gif.targetFPS
        case .mp4, .mov:
            format.availableFPSOptions.contains(videoFPS) ? videoFPS : format.targetFPS
        }
    }

    /// Updates the frame rate for the current format when `fps` is a supported option.
    public mutating func setFPS(_ fps: Int) {
        guard format.availableFPSOptions.contains(fps) else { return }
        switch format {
        case .gif:
            gifFPS = fps
        case .mp4, .mov:
            videoFPS = fps
        }
    }

    public var effectiveSystemAudio: Bool { format.supportsAudio && capturesSystemAudio }
    public var effectiveMicrophone: Bool { format.supportsAudio && capturesMicrophone }
    public var hasAudio: Bool { effectiveSystemAudio || effectiveMicrophone }
}

/// Persists the user's last recording preferences across sessions.
@MainActor
public final class RecordingSettingsStore {
    private static let defaultsKey = "CCXRecordingSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(RecordingSettings.self, from: data)
        else {
            return RecordingSettings()
        }
        return decoded
    }

    public func save(_ settings: RecordingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Completed screen recording output staged on disk for copy / save / reveal.
public struct RecordingResult: Equatable, Sendable {
    public let fileURL: URL
    public let format: RecordingFormat
    public let duration: TimeInterval
    public let fileSizeBytes: Int64
    public let pixelSize: CGSize
    public let screenRect: CGRect

    public init(
        fileURL: URL,
        format: RecordingFormat,
        duration: TimeInterval,
        fileSizeBytes: Int64,
        pixelSize: CGSize,
        screenRect: CGRect
    ) {
        self.fileURL = fileURL
        self.format = format
        self.duration = duration
        self.fileSizeBytes = fileSizeBytes
        self.pixelSize = pixelSize
        self.screenRect = screenRect
    }

    public var formattedDuration: String {
        Self.formatDuration(duration)
    }

    public var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: max(0, fileSizeBytes), countStyle: .file)
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let safeSeconds = min(seconds, Double(Int.max / 2))
        let clamped = max(0, Int(safeSeconds.rounded(.down)))
        let hours = clamped / 3600
        let mins = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
}

/// Interactive states of the floating recording HUD.
public enum RecordingPhase: Equatable, Sendable {
    case ready
    case countdown(remaining: Int)
    case recording
    case paused
    case finalizing
    case completed(RecordingResult)
}

/// Lightweight status summary mirrored into the menu bar controller while recording.
public struct RecordingMenuBarStatus: Equatable, Sendable {
    public let isPaused: Bool
    public let elapsedSeconds: TimeInterval
    public let format: RecordingFormat

    public init(isPaused: Bool, elapsedSeconds: TimeInterval, format: RecordingFormat) {
        self.isPaused = isPaused
        self.elapsedSeconds = elapsedSeconds
        self.format = format
    }

    public var formattedElapsed: String {
        RecordingResult.formatDuration(elapsedSeconds)
    }
}

/// Final outcome emitted when a recording session finishes or is dismissed.
public enum RecordingOutcome: Sendable {
    case save(RecordingResult)
    case quickSave(RecordingResult)
    case copy(RecordingResult)
    case reveal(RecordingResult)
    case permissionDenied
    case failed(String)
    case cancelled
}

/// Wraps a non-`Sendable` value handed across an explicit queue boundary that owns sole access.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
