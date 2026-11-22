import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

/// Live progress delivered on the main actor during a scrolling screenshot session.
public struct ScrollCaptureProgress: Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameCount: Int
    public let previewImage: CGImage?
    public let reachedLimit: Bool
}

/// Captures frames from a fixed display rectangle via `SCStream` and incrementally
/// stitches newly revealed vertical slices off the main thread.
@MainActor
public final class ScrollCaptureEngine {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "ScrollCaptureEngine")

    public var onProgress: ((ScrollCaptureProgress) -> Void)?
    public var onError: ((Error) -> Void)?

    private let request: ScrollCaptureRequest
    private let fallbackInitialImage: CGImage
    private let worker: ScrollStitchWorker
    private var stream: SCStream?
    private var streamOutput: StreamOutputHandler?
    private let streamQueue = DispatchQueue(label: "com.lizhichaox.ccx.scroll-stream", qos: .userInitiated)
    private var isStopped = false

    public init(request: ScrollCaptureRequest, fallbackInitialImage: CGImage) {
        self.request = request
        self.fallbackInitialImage = fallbackInitialImage
        self.worker = ScrollStitchWorker(scale: request.scale)
    }

    public func start(excludingWindowIDs: Set<CGWindowID>) async throws {
        guard !isStopped else { return }

        if let seeded = ScrollFrameBuffer(cgImage: fallbackInitialImage) {
            worker.seedInitial(seeded)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !isStopped,
              let display = content.displays.first(where: { $0.displayID == request.displayID })
        else {
            throw ScreenSnapshotError.noDisplays
        }

        let excludedWindows = excludingWindowIDs.isEmpty
            ? []
            : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let config = SCStreamConfiguration()
        // SCStreamConfiguration.sourceRect uses top-left origin in display points.
        config.sourceRect = CGRect(
            x: request.localRect.minX,
            y: max(0, request.displayFrame.height - request.localRect.maxY),
            width: request.localRect.width,
            height: request.localRect.height
        )
        config.width = max(2, Int((request.localRect.width * request.scale).rounded()))
        config.height = max(2, Int((request.localRect.height * request.scale).rounded()))
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.queueDepth = 3

        let handler = StreamOutputHandler(
            onFrame: { [weak self] frame in
                Task { @MainActor [weak self] in
                    self?.submit(frame: frame)
                }
            },
            onStreamError: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    Self.logger.error("Scroll stream stopped with error: \(error.localizedDescription)")
                    self.onError?(error)
                }
            }
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: handler)
        try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: streamQueue)
        self.stream = stream
        self.streamOutput = handler

        try await stream.startCapture()
        emitProgress(worker.currentProgress(preview: true))
    }

    public func finishAndBuildImage() async -> CGImage? {
        guard !isStopped else { return fallbackInitialImage }
        isStopped = true
        let activeStream = stream
        stream = nil
        streamOutput = nil
        if let activeStream {
            try? await activeStream.stopCapture()
        }
        return await worker.finalizeImage() ?? fallbackInitialImage
    }

    public func cancel() {
        guard !isStopped else { return }
        isStopped = true
        let activeStream = stream
        stream = nil
        streamOutput = nil
        worker.cancel()
        if let activeStream {
            let streamBox = UncheckedSendableBox(activeStream)
            Task.detached {
                try? await streamBox.value.stopCapture()
            }
        }
    }

    private func submit(frame: ScrollFrameBuffer) {
        guard !isStopped else { return }
        worker.enqueue(frame) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.emitProgress(progress)
            }
        }
    }

    private func emitProgress(_ progress: ScrollCaptureProgress) {
        onProgress?(progress)
    }
}

// MARK: - Serial Stitch Worker

private final class ScrollStitchWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lizhichaox.ccx.scroll-stitch", qos: .userInitiated)
    private let stateLock = NSLock()
    private let stitcher: ScrollImageStitcher
    private var inFlightCount = 0
    private var isCancelled = false

    init(scale: CGFloat) {
        self.stitcher = ScrollImageStitcher(scale: scale)
    }

    func seedInitial(_ frame: ScrollFrameBuffer) {
        queue.sync {
            stitcher.seed(frame)
        }
    }

    func currentProgress(preview: Bool) -> ScrollCaptureProgress {
        queue.sync {
            makeProgress(includePreview: preview)
        }
    }

    func enqueue(_ frame: ScrollFrameBuffer, onUpdate: @escaping @Sendable (ScrollCaptureProgress) -> Void) {
        stateLock.lock()
        // Drop excess queued frames so ScreenCaptureKit backpressure never grows memory.
        guard !isCancelled, inFlightCount < 2 else {
            stateLock.unlock()
            return
        }
        inFlightCount += 1
        stateLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.inFlightCount = max(0, self.inFlightCount - 1)
                self.stateLock.unlock()
            }
            guard !self.cancelled() else { return }
            if self.stitcher.append(frame) {
                let progress = self.makeProgress(includePreview: true)
                onUpdate(progress)
            }
        }
    }

    func finalizeImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.cancelled() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.stitcher.buildFinalImage())
            }
        }
    }

    func cancel() {
        stateLock.lock()
        isCancelled = true
        stateLock.unlock()
    }

    private func cancelled() -> Bool {
        stateLock.lock()
        let result = isCancelled
        stateLock.unlock()
        return result
    }

    private func makeProgress(includePreview: Bool) -> ScrollCaptureProgress {
        ScrollCaptureProgress(
            pixelWidth: stitcher.width,
            pixelHeight: stitcher.totalStitchedHeight,
            frameCount: stitcher.stitchedFrameCount,
            previewImage: includePreview ? stitcher.buildPreviewImage() : nil,
            reachedLimit: stitcher.isAtHeightLimit
        )
    }
}

// MARK: - SCStream Handler

private final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onFrame: @Sendable (ScrollFrameBuffer) -> Void
    private let onStreamError: @Sendable (Error) -> Void

    init(
        onFrame: @escaping @Sendable (ScrollFrameBuffer) -> Void,
        onStreamError: @escaping @Sendable (Error) -> Void
    ) {
        self.onFrame = onFrame
        self.onStreamError = onStreamError
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = ScrollFrameBuffer(pixelBuffer: pixelBuffer)
        else { return }

        onFrame(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamError(error)
    }
}

// MARK: - Accessibility Auto-Scroll Driver

/// Synthesizes smooth downward scroll-wheel events over the capture region and stops
/// automatically once height stalls for several ticks.
@MainActor
public final class AutoScrollDriver {
    public var onStateChanged: ((Bool) -> Void)?
    public var onReachedBottom: (() -> Void)?
    public var onAccessibilityRequired: (() -> Void)?

    public private(set) var isRunning = false

    private var timer: Timer?
    private var captureScreenRect: CGRect = .zero
    private var lastObservedHeight = 0
    private var stalledTicks = 0
    private static let maxStalledTicks = 8

    public init() {}

    public func start(captureScreenRect: CGRect, primaryScreenHeight: CGFloat, currentPixelHeight: Int) {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            onAccessibilityRequired?()
            return
        }

        self.captureScreenRect = captureScreenRect
        self.lastObservedHeight = currentPixelHeight
        self.stalledTicks = 0

        // Position pointer inside the scrollable region once in Quartz coordinates.
        let centerAppKit = CGPoint(x: captureScreenRect.midX, y: captureScreenRect.midY)
        let centerQuartz = CGPoint(x: centerAppKit.x, y: primaryScreenHeight - centerAppKit.y)
        CGWarpMouseCursorPosition(centerQuartz)

        isRunning = true
        onStateChanged?(true)

        let stepPixels = Int32(min(max(captureScreenRect.height * 0.30, 120), 280))
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick(stepPixels: stepPixels)
            }
        }
    }

    public func notifyHeightAdvanced(_ newHeight: Int) {
        if newHeight > lastObservedHeight {
            lastObservedHeight = newHeight
            stalledTicks = 0
        }
    }

    public func stop() {
        let wasRunning = isRunning
        timer?.invalidate()
        timer = nil
        isRunning = false
        if wasRunning {
            onStateChanged?(false)
        }
    }

    private func tick(stepPixels: Int32) {
        guard isRunning else { return }
        // Pause if the user moves the pointer outside the capture region.
        guard captureScreenRect.contains(NSEvent.mouseLocation) else {
            stop()
            return
        }

        if let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -stepPixels,
            wheel2: 0,
            wheel3: 0
        ) {
            event.post(tap: .cghidEventTap)
        }

        stalledTicks += 1
        if stalledTicks >= Self.maxStalledTicks {
            stop()
            onReachedBottom?()
        }
    }
}
