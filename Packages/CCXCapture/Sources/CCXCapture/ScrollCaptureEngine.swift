import AppKit
import ApplicationServices
import CCXCore
import CoreMedia
import CoreVideo
import Foundation
import os
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
    private var isStarted = false
    private var isStopped = false

    public init(request: ScrollCaptureRequest, fallbackInitialImage: CGImage) {
        self.request = request
        self.fallbackInitialImage = fallbackInitialImage
        self.worker = ScrollStitchWorker(scale: request.scale)
    }

    public func start(excludingWindowIDs: Set<CGWindowID>) async throws {
        guard !isStopped, !isStarted else { return }
        isStarted = true

        if let seeded = ScrollFrameBuffer(cgImage: fallbackInitialImage) {
            await worker.seedInitial(seeded)
        }
        guard !isStopped else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !isStopped else { return }
        guard let display = content.displays.first(where: { $0.displayID == request.displayID }) else {
            throw ScreenSnapshotError.noDisplays
        }

        let excludedWindows = excludingWindowIDs.isEmpty
            ? []
            : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let rawLocal = request.localRect.standardized
        let displayBounds = CGRect(origin: .zero, size: request.displayFrame.size)
        let intersected = rawLocal.intersection(displayBounds)
        let effectiveLocal = (!intersected.isNull && intersected.width >= 1 && intersected.height >= 1)
            ? intersected
            : rawLocal

        let config = SCStreamConfiguration()
        // SCStreamConfiguration.sourceRect uses top-left origin in display points.
        config.sourceRect = CGRect(
            x: effectiveLocal.minX,
            y: max(0, request.displayFrame.height - effectiveLocal.maxY),
            width: effectiveLocal.width,
            height: effectiveLocal.height
        )
        config.width = max(2, fallbackInitialImage.width)
        config.height = max(2, fallbackInitialImage.height)
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.queueDepth = 3

        let sourceRectDescription = NSStringFromRect(config.sourceRect)
        let streamWidth = config.width
        let streamHeight = config.height
        let fallbackWidth = fallbackInitialImage.width
        let fallbackHeight = fallbackInitialImage.height
        Self.logger.info(
            "Starting scroll stream sourceRect=\(sourceRectDescription, privacy: .public) config=\(streamWidth)x\(streamHeight) fallback=\(fallbackWidth)x\(fallbackHeight)"
        )

        let stitchWorker = self.worker
        let handler = StreamOutputHandler(
            worker: stitchWorker,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.emitProgress(progress)
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

        let candidateStream = SCStream(filter: filter, configuration: config, delegate: handler)
        try candidateStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: streamQueue)

        do {
            try await candidateStream.startCapture()
        } catch {
            try? candidateStream.removeStreamOutput(handler, type: .screen)
            throw error
        }

        // Guard against `cancel()` or `finishAndBuildImage()` racing while `startCapture()` was in flight.
        guard !isStopped else {
            try? candidateStream.removeStreamOutput(handler, type: .screen)
            try? await candidateStream.stopCapture()
            return
        }

        self.stream = candidateStream
        self.streamOutput = handler

        let initialProgress = await worker.currentProgress(preview: true)
        guard !isStopped else { return }
        emitProgress(initialProgress)
    }

    public func finishAndBuildImage() async -> CGImage? {
        guard !isStopped else { return fallbackInitialImage }
        isStopped = true
        onProgress = nil
        onError = nil
        let activeStream = stream
        let activeOutput = streamOutput
        stream = nil
        streamOutput = nil
        if let activeStream {
            if let activeOutput {
                try? activeStream.removeStreamOutput(activeOutput, type: .screen)
            }
            try? await activeStream.stopCapture()
        }
        return await worker.finalizeImage() ?? fallbackInitialImage
    }

    public func cancel() {
        // Always cancel the stitch worker even if `finishAndBuildImage()` already set `isStopped`.
        worker.cancel()
        onProgress = nil
        onError = nil
        guard !isStopped else { return }
        isStopped = true
        let activeStream = stream
        let activeOutput = streamOutput
        stream = nil
        streamOutput = nil
        if let activeStream {
            if let activeOutput {
                try? activeStream.removeStreamOutput(activeOutput, type: .screen)
            }
            let streamBox = UncheckedSendableBox(activeStream)
            Task.detached {
                try? await streamBox.value.stopCapture()
            }
        }
    }

    private func emitProgress(_ progress: ScrollCaptureProgress) {
        onProgress?(progress)
    }
}

// MARK: - Serial Stitch Worker

/// Serial off-main stitcher owning `ScrollImageStitcher` on `queue`, with lock-protected
/// slot reservation so `StreamOutputHandler` drops backpressured frames before copying pixels.
private final class ScrollStitchWorker: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "ScrollStitchWorker")

    private struct GateState: Sendable {
        var inFlightCount = 0
        var isCancelled = false
    }

    private let queue = DispatchQueue(label: "com.lizhichaox.ccx.scroll-stitch", qos: .userInitiated)
    private let gate = OSAllocatedUnfairLock(initialState: GateState())
    private let stitcher: ScrollImageStitcher
    private var hasReceivedStreamFrame = false
    private var rejectedFrameCount = 0

    init(scale: CGFloat) {
        self.stitcher = ScrollImageStitcher(scale: scale)
    }

    func seedInitial(_ frame: ScrollFrameBuffer) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let self, !self.cancelled() {
                    self.hasReceivedStreamFrame = false
                    self.rejectedFrameCount = 0
                    self.stitcher.seed(frame)
                }
                continuation.resume()
            }
        }
    }

    func currentProgress(preview: Bool) async -> ScrollCaptureProgress {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: ScrollCaptureProgress(
                        pixelWidth: 0, pixelHeight: 0, frameCount: 0, previewImage: nil, reachedLimit: false
                    ))
                    return
                }
                continuation.resume(returning: self.makeProgress(includePreview: preview))
            }
        }
    }

    /// Reserves an in-flight stitching slot before allocating/copying `CVPixelBuffer` bytes.
    func tryReserveSlot() -> Bool {
        gate.withLock { state in
            guard !state.isCancelled, state.inFlightCount < 2 else { return false }
            state.inFlightCount += 1
            return true
        }
    }

    /// Releases a previously reserved slot if `ScrollFrameBuffer` creation failed.
    func releaseReservedSlot() {
        gate.withLock { state in
            state.inFlightCount = max(0, state.inFlightCount - 1)
        }
    }

    func enqueueReserved(_ frame: ScrollFrameBuffer, onUpdate: @escaping @Sendable (ScrollCaptureProgress) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.releaseReservedSlot() }
            guard !self.cancelled() else { return }

            if !self.hasReceivedStreamFrame {
                self.hasReceivedStreamFrame = true
                if self.stitcher.stitchedFrameCount <= 1 {
                    let previousSize = (self.stitcher.width, self.stitcher.totalStitchedHeight)
                    self.stitcher.seed(frame)
                    Self.logger.info(
                        "Seeded first stream frame \(frame.width)x\(frame.height) (fallback was \(previousSize.0)x\(previousSize.1))"
                    )
                    if (self.stitcher.width, self.stitcher.totalStitchedHeight) != previousSize {
                        let progress = self.makeProgress(includePreview: true)
                        onUpdate(progress)
                    }
                    return
                }
            }

            if self.stitcher.append(frame) {
                self.rejectedFrameCount = 0
                let progress = self.makeProgress(includePreview: true)
                onUpdate(progress)
            } else {
                self.rejectedFrameCount += 1
                if self.rejectedFrameCount == 1 || self.rejectedFrameCount % 20 == 0 {
                    Self.logger.debug(
                        "Rejected scroll frame #\(self.rejectedFrameCount) size=\(frame.width)x\(frame.height) stitcher=\(self.stitcher.width)x\(self.stitcher.totalStitchedHeight)"
                    )
                }
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
                let finalImage = self.stitcher.buildFinalImage()
                self.stitcher.clear()
                continuation.resume(returning: finalImage)
            }
        }
    }

    func cancel() {
        gate.withLock { $0.isCancelled = true }
        queue.async { [weak self] in
            self?.stitcher.clear()
        }
    }

    private func cancelled() -> Bool {
        gate.withLock { $0.isCancelled }
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

/// Bridges ScreenCaptureKit callbacks directly onto `ScrollStitchWorker` without bouncing frames through `@MainActor`.
private final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let worker: ScrollStitchWorker
    private let onProgress: @Sendable (ScrollCaptureProgress) -> Void
    private let onStreamError: @Sendable (Error) -> Void

    init(
        worker: ScrollStitchWorker,
        onProgress: @escaping @Sendable (ScrollCaptureProgress) -> Void,
        onStreamError: @escaping @Sendable (Error) -> Void
    ) {
        self.worker = worker
        self.onProgress = onProgress
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

        guard worker.tryReserveSlot() else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = ScrollFrameBuffer(pixelBuffer: pixelBuffer)
        else {
            worker.releaseReservedSlot()
            return
        }

        worker.enqueueReserved(frame, onUpdate: onProgress)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStreamError(error)
    }
}

// MARK: - Accessibility Auto-Scroll Driver

/// Synthesizes discrete wheel-line scroll events over the capture region while avoiding
/// floating HUD chrome, and stops automatically once pixel height stalls or the user takes over.
@MainActor
public final class AutoScrollDriver {
    public var onStateChanged: ((Bool) -> Void)?
    public var onReachedBottom: (() -> Void)?
    public var onAccessibilityRequired: (() -> Void)?

    public private(set) var isRunning = false

    private let trustChecker: @Sendable () -> Bool
    private let pointerLocationProvider: @MainActor () -> CGPoint
    private let pointerWarper: @MainActor (CGPoint) -> Void
    private let scrollPoster: @MainActor (CGPoint, Int32) -> Void
    private let startDelay: TimeInterval
    private let tickInterval: TimeInterval

    private var loopTask: Task<Void, Never>?
    private var captureScreenRect: CGRect = .zero
    private var targetAppKitPoint: CGPoint = .zero
    private var targetQuartzPoint: CGPoint = .zero
    private var lastObservedHeight = 0
    private var stalledTicks = 0
    private var graceTicksRemaining = 0

    private static let initialGraceTicks = 2
    private static let maxStalledTicks = 12
    private static let pointerTakeoverThreshold: CGFloat = 40

    public init(
        trustChecker: (@Sendable () -> Bool)? = nil,
        pointerLocationProvider: (@MainActor () -> CGPoint)? = nil,
        pointerWarper: (@MainActor (CGPoint) -> Void)? = nil,
        scrollPoster: (@MainActor (CGPoint, Int32) -> Void)? = nil,
        startDelay: TimeInterval = 0.12,
        tickInterval: TimeInterval = 0.18
    ) {
        self.trustChecker = trustChecker ?? { AXIsProcessTrusted() }
        self.pointerLocationProvider = pointerLocationProvider ?? { NSEvent.mouseLocation }
        self.pointerWarper = pointerWarper ?? { Self.defaultWarpPointer(to: $0) }
        self.scrollPoster = scrollPoster ?? { Self.defaultPostScroll(at: $0, lines: $1) }
        self.startDelay = startDelay
        self.tickInterval = tickInterval
    }

    public static func scrollTargetPoint(in captureScreenRect: CGRect, avoiding hudFrame: CGRect? = nil) -> CGPoint {
        let rect = captureScreenRect.standardized
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let hudFrame, !hudFrame.isNull, !hudFrame.isEmpty else {
            return center
        }

        let paddedHUD = hudFrame.insetBy(dx: -10, dy: -10)
        guard paddedHUD.contains(center) else {
            return center
        }

        let aboveBand = rect.maxY - paddedHUD.maxY
        let belowBand = paddedHUD.minY - rect.minY
        if aboveBand >= 24 || belowBand >= 24 {
            if aboveBand >= belowBand {
                return CGPoint(x: rect.midX, y: paddedHUD.maxY + aboveBand * 0.5)
            }
            return CGPoint(x: rect.midX, y: rect.minY + belowBand * 0.5)
        }

        let leftBand = paddedHUD.minX - rect.minX
        let rightBand = rect.maxX - paddedHUD.maxX
        if leftBand >= 24 || rightBand >= 24 {
            if leftBand >= rightBand {
                return CGPoint(x: rect.minX + leftBand * 0.5, y: rect.midY)
            }
            return CGPoint(x: paddedHUD.maxX + rightBand * 0.5, y: rect.midY)
        }

        return center
    }

    public static func scrollStepLines(for captureHeight: CGFloat) -> Int32 {
        guard captureHeight.isFinite, captureHeight > 0 else { return 2 }
        return Int32(min(max(Int((captureHeight / 180).rounded()), 2), 5))
    }

    public func start(
        captureScreenRect: CGRect,
        primaryScreenHeight: CGFloat,
        currentPixelHeight: Int,
        avoiding hudFrame: CGRect? = nil
    ) {
        guard !isRunning else { return }
        guard trustChecker() else {
            onAccessibilityRequired?()
            return
        }

        let rect = captureScreenRect.standardized
        self.captureScreenRect = rect
        self.lastObservedHeight = currentPixelHeight
        self.stalledTicks = 0
        self.graceTicksRemaining = Self.initialGraceTicks
        self.targetAppKitPoint = Self.scrollTargetPoint(in: rect, avoiding: hudFrame)
        self.targetQuartzPoint = CoordinateConverter.appKitToQuartz(
            targetAppKitPoint,
            primaryScreenHeight: primaryScreenHeight
        )

        isRunning = true
        onStateChanged?(true)

        let stepLines = Self.scrollStepLines(for: rect.height)
        if startDelay <= 0 {
            pointerWarper(targetQuartzPoint)
        }
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runScrollLoop(stepLines: stepLines, initialDelay: self.startDelay)
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
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        if wasRunning {
            onStateChanged?(false)
        }
    }

    private func runScrollLoop(stepLines: Int32, initialDelay: TimeInterval) async {
        let clampedDelay = initialDelay.isFinite ? min(max(initialDelay, 0), 60) : 0
        if clampedDelay > 0 {
            let delayNanoseconds = UInt64((clampedDelay * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, isRunning else { return }
            pointerWarper(targetQuartzPoint)
        }

        let clampedTick = tickInterval.isFinite ? min(max(tickInterval, 0.001), 60) : 0.18
        let intervalNanoseconds = UInt64((clampedTick * 1_000_000_000).rounded())
        while !Task.isCancelled, isRunning {
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
            guard !Task.isCancelled, isRunning else { break }
            tick(stepLines: stepLines)
        }
        loopTask = nil
    }

    private func tick(stepLines: Int32) {
        guard isRunning else { return }

        let inGracePeriod = graceTicksRemaining > 0
        let currentPointer = pointerLocationProvider()
        let pointerDistance = hypot(
            currentPointer.x - targetAppKitPoint.x,
            currentPointer.y - targetAppKitPoint.y
        )
        let pointerDisplaced = !captureScreenRect.contains(currentPointer)
            || pointerDistance > Self.pointerTakeoverThreshold

        if inGracePeriod {
            graceTicksRemaining -= 1
            if pointerDisplaced {
                // Re-assert pointer position while click release and warp suppression settle.
                pointerWarper(targetQuartzPoint)
            }
        } else if pointerDisplaced {
            stop()
            return
        }

        scrollPoster(targetQuartzPoint, stepLines)

        if !inGracePeriod {
            stalledTicks += 1
            if stalledTicks >= Self.maxStalledTicks {
                stop()
                onReachedBottom?()
            }
        }
    }

    private static func defaultWarpPointer(to quartzPoint: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        CGWarpMouseCursorPosition(quartzPoint)
        if let moved = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) {
            moved.post(tap: .cgSessionEventTap)
        }
    }

    private static func defaultPostScroll(at quartzPoint: CGPoint, lines: Int32) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 1,
            wheel1: -lines,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = quartzPoint
        event.post(tap: .cgSessionEventTap)
    }
}
