import Accelerate
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Memory-bounded animated GIF encoder backed by ImageIO (`CGImageDestination`).
///
/// Frames are processed on a private serial queue with bounded `OSAllocatedUnfairLock`
/// backpressure, zero-copy static fingerprinting directly from locked BGRA pixel buffers
/// (both 1:1 and scaled paths), Accelerate (`vImageScale_ARGB8888`) downscaling,
/// centisecond delay-carry timing accuracy, and a hard pixel-memory / frame cap to prevent OOM.
public final class GifRecordingEncoder: @unchecked Sendable {
    public static let defaultMaxFrameCount = 900
    public static let defaultMaxBufferedBytes = 256 * 1024 * 1024 // 256 MB uncompressed RGBA budget

    private static let maxDimension = 4_096
    private static let maxSourcePixelDimension = 16_384
    private static let maxFPS = 60
    private static let maxFrameDelay: TimeInterval = 4.0
    private static let minFrameDelay: TimeInterval = 0.02
    private static let fingerprintGrid = 24
    private static let identicalMeanChannelDelta: Double = 2.0
    static let maxPendingVideoFrames = 2
    private static let maxPendingImageFrames = 64

    private struct PendingVideoFrame: Sendable {
        let pixelBuffer: UncheckedSendableBox<CVPixelBuffer>
        let pts: CMTime
    }

    private struct PendingImageFrame: Sendable {
        let image: CGImage
        let pts: CMTime
    }

    private enum PendingItem: Sendable {
        case video(PendingVideoFrame)
        case image(PendingImageFrame)
        case pause(CMTime)
        case resume(CMTime)
    }

    private struct GateState: Sendable {
        var items: [PendingItem] = []
        var pendingVideoCount = 0
        var pendingImageCount = 0
        var hasPoppedFirstVideo = false
        var isDrainScheduled = false
        var isPaused = false
        var isAcceptingInput = true
        var isCancelled = false
        var limitReached = false
        var droppedVideoFrames = 0
        var onLimitReached: (@Sendable () -> Void)?
    }

    private let queue = DispatchQueue(label: "com.lizhichaox.ccx.gif-encoder", qos: .userInitiated)
    private let gate: OSAllocatedUnfairLock<GateState>
    private let outputURL: URL
    private let targetWidth: Int
    private let targetHeight: Int
    private let minInterval: TimeInterval
    public let maxFrames: Int

    private var destination: CGImageDestination?
    private var lazyScaleContext: CGContext?
    private let rgbColorSpace: CGColorSpace

    private var timeline = RecordingTimeline()
    private var lastAcceptedPTS: TimeInterval?
    private var pendingFrame: (image: CGImage, startPTS: TimeInterval)?
    private var pendingFingerprint: [UInt8]
    private var scratchFingerprint: [UInt8]
    private var lastObservedPTS: TimeInterval = 0
    private var delayCarry: TimeInterval = 0
    private var writtenFrames = 0
    private var materializedFrameCount = 0
    private var isFinished = false
    private var finishedDuration: TimeInterval = 0
    private var finishedError: Error?

    public var onLimitReached: (@Sendable () -> Void)? {
        get { gate.withLock { $0.onLimitReached } }
        set { gate.withLock { $0.onLimitReached = newValue } }
    }

    var droppedVideoFrameCountForTesting: Int {
        gate.withLock { $0.droppedVideoFrames }
    }

    public init(
        outputURL: URL,
        pixelSize: CGSize,
        fps: Int = 15,
        maxFrameCount: Int = GifRecordingEncoder.defaultMaxFrameCount,
        maxBufferedBytes: Int = GifRecordingEncoder.defaultMaxBufferedBytes,
        onLimitReached: (@Sendable () -> Void)? = nil
    ) throws {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0
        else {
            throw RecordingError.encoderInitializationFailed
        }

        self.outputURL = outputURL
        let clampedW = min(max(2.0, pixelSize.width.rounded()), Double(Self.maxDimension))
        let clampedH = min(max(2.0, pixelSize.height.rounded()), Double(Self.maxDimension))
        let rawW = Int(clampedW)
        let rawH = Int(clampedH)
        self.targetWidth = max(2, rawW - rawW % 2)
        self.targetHeight = max(2, rawH - rawH % 2)

        let clampedFPS = min(max(1, fps), Self.maxFPS)
        self.minInterval = 1.0 / Double(clampedFPS)

        let bytesPerFrame = max(1, targetWidth * targetHeight * 4)
        let budgetFrames = max(1, max(1, maxBufferedBytes) / bytesPerFrame)
        self.maxFrames = max(1, min(max(1, maxFrameCount), budgetFrames))
        self.gate = OSAllocatedUnfairLock(initialState: GateState(onLimitReached: onLimitReached))
        let fingerprintLength = Self.fingerprintGrid * Self.fingerprintGrid * 3
        self.pendingFingerprint = [UInt8](repeating: 0, count: fingerprintLength)
        self.scratchFingerprint = [UInt8](repeating: 0, count: fingerprintLength)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.rgbColorSpace = colorSpace

        try RecordingFileSecurity.validateOutputURLForWriting(outputURL)
        try RecordingFileSecurity.createRestrictedEmptyFile(at: outputURL)
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            0,
            nil
        ) else {
            RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
            throw RecordingError.encoderInitializationFailed
        }
        let containerProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
                kCGImagePropertyGIFHasGlobalColorMap: false,
            ],
        ]
        CGImageDestinationSetProperties(dest, containerProperties as CFDictionary)
        self.destination = dest
    }

    static func validateBGRAPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> (width: Int, height: Int, bytesPerRow: Int)? {
        guard !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              width <= Self.maxSourcePixelDimension,
              height <= Self.maxSourcePixelDimension
        else {
            return nil
        }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow, bytesPerRow >= rowBytes else { return nil }
        let (lastRowOffset, offsetOverflow) = (height - 1).multipliedReportingOverflow(by: bytesPerRow)
        let (minRequiredBytes, totalOverflow) = lastRowOffset.addingReportingOverflow(rowBytes)
        guard !offsetOverflow, !totalOverflow, minRequiredBytes > 0 else { return nil }
        let dataSize = CVPixelBufferGetDataSize(pixelBuffer)
        guard dataSize == 0 || dataSize >= minRequiredBytes else { return nil }
        return (width, height, bytesPerRow)
    }

    public func appendVideo(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard pts.isNumeric, Self.validateBGRAPixelBuffer(pixelBuffer) != nil else { return }

        let frame = PendingVideoFrame(pixelBuffer: UncheckedSendableBox(pixelBuffer), pts: pts)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused, !state.limitReached, !state.isCancelled else { return false }
            if state.pendingVideoCount >= Self.maxPendingVideoFrames {
                var seenVideos = 0
                let targetOrdinal = (!state.hasPoppedFirstVideo && state.pendingVideoCount >= 2) ? 1 : 0
                if let evictIdx = state.items.firstIndex(where: { item in
                    guard case .video = item else { return false }
                    defer { seenVideos += 1 }
                    return seenVideos == targetOrdinal
                }) {
                    state.items.remove(at: evictIdx)
                    state.pendingVideoCount -= 1
                    state.droppedVideoFrames += 1
                }
            }
            state.items.append(.video(frame))
            state.pendingVideoCount += 1
            if state.isDrainScheduled { return false }
            state.isDrainScheduled = true
            return true
        }
        if shouldSchedule {
            queue.async { [weak self] in
                self?.drainPending()
            }
        }
    }

    public func appendImage(_ image: CGImage, pts: CMTime) {
        guard pts.isNumeric,
              image.width > 0, image.height > 0,
              image.width <= Self.maxSourcePixelDimension,
              image.height <= Self.maxSourcePixelDimension
        else { return }
        let frame = PendingImageFrame(image: image, pts: pts)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused, !state.limitReached, !state.isCancelled else { return false }
            if state.pendingImageCount >= Self.maxPendingImageFrames {
                if let evictIdx = state.items.firstIndex(where: {
                    if case .image = $0 { return true }
                    return false
                }) {
                    state.items.remove(at: evictIdx)
                    state.pendingImageCount -= 1
                }
            }
            state.items.append(.image(frame))
            state.pendingImageCount += 1
            if state.isDrainScheduled { return false }
            state.isDrainScheduled = true
            return true
        }
        if shouldSchedule {
            queue.async { [weak self] in
                self?.drainPending()
            }
        }
    }

    public func pause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let shouldSchedule: Bool = gate.withLock { state in
            guard !state.isCancelled else { return false }
            state.isPaused = true
            state.items.removeAll { item in
                switch item {
                case .video, .image: true
                case .pause, .resume: false
                }
            }
            state.pendingVideoCount = 0
            state.pendingImageCount = 0
            state.items.append(.pause(now))
            if state.isDrainScheduled { return false }
            state.isDrainScheduled = true
            return true
        }
        if shouldSchedule {
            queue.async { [weak self] in
                self?.drainPending()
            }
        }
    }

    public func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let shouldSchedule: Bool = gate.withLock { state in
            guard !state.isCancelled else { return false }
            state.isPaused = false
            state.items.append(.resume(now))
            if state.isDrainScheduled { return false }
            state.isDrainScheduled = true
            return true
        }
        if shouldSchedule {
            queue.async { [weak self] in
                self?.drainPending()
            }
        }
    }

    public func finish() async throws -> (duration: TimeInterval, frameCount: Int) {
        let finishWallTime = CMClockGetTime(CMClockGetHostTimeClock())
        gate.withLock { state in
            state.isAcceptingInput = false
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecordingError.noFramesCaptured)
                    return
                }
                if self.isFinished {
                    if let error = self.finishedError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (self.finishedDuration, self.writtenFrames))
                    }
                    return
                }
                if self.gate.withLock({ $0.isCancelled }) {
                    self.abortForCancellation()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.drainPending()
                if self.gate.withLock({ $0.isCancelled }) {
                    self.abortForCancellation()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.isFinished = true
                self.timeline.finish(at: finishWallTime)

                let rawFinalEnd = max(self.lastObservedPTS, self.timeline.recordedDurationSeconds)
                let finalEnd = rawFinalEnd.isFinite ? max(0, rawFinalEnd) : 0
                if let last = self.pendingFrame {
                    let finalSpan = finalEnd - last.startPTS
                    let delay = finalSpan >= Self.minFrameDelay ? finalSpan : self.minInterval
                    if self.writtenFrames < self.maxFrames {
                        self.flushPendingFrame(last, delay: delay)
                    }
                    self.pendingFrame = nil
                }

                guard self.writtenFrames > 0, let dest = self.destination else {
                    self.destination = nil
                    self.lazyScaleContext = nil
                    self.finishedError = RecordingError.noFramesCaptured
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    continuation.resume(throwing: RecordingError.noFramesCaptured)
                    return
                }

                if self.gate.withLock({ $0.isCancelled }) {
                    self.abortForCancellation()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    try RecordingFileSecurity.verifyOutputURLForFinalize(self.outputURL)
                } catch {
                    self.destination = nil
                    self.lazyScaleContext = nil
                    self.finishedError = error
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    continuation.resume(throwing: error)
                    return
                }

                let finalized = autoreleasepool {
                    CGImageDestinationFinalize(dest)
                }
                self.destination = nil
                self.lazyScaleContext = nil

                if self.gate.withLock({ $0.isCancelled }) {
                    self.finishedError = CancellationError()
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard finalized else {
                    self.finishedError = RecordingError.encoderFinalizeFailed
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    continuation.resume(throwing: RecordingError.encoderFinalizeFailed)
                    return
                }

                RecordingFileSecurity.restrictFilePermissions(at: self.outputURL)
                let duration = max(self.minInterval, finalEnd)
                self.finishedDuration = duration
                continuation.resume(returning: (duration, self.writtenFrames))
            }
        }
    }

    public func cancel() {
        gate.withLock { state in
            state.isAcceptingInput = false
            state.isCancelled = true
            state.items.removeAll()
            state.pendingVideoCount = 0
            state.pendingImageCount = 0
        }
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.abortForCancellation()
        }
    }

    private func abortForCancellation() {
        isFinished = true
        finishedError = CancellationError()
        pendingFrame = nil
        destination = nil
        lazyScaleContext = nil
        RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
    }

    func debugMaterializedFrameCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.materializedFrameCount ?? 0)
            }
        }
    }

    func debugIsDestinationReleased() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.destination == nil)
            }
        }
    }

    func debugHasAllocatedScaleContext() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.lazyScaleContext != nil)
            }
        }
    }

    // MARK: - Serial Queue Helpers

    private func drainPending() {
        while true {
            let items: [PendingItem] = gate.withLock { state in
                if state.isCancelled {
                    state.items.removeAll()
                    state.pendingVideoCount = 0
                    state.pendingImageCount = 0
                    state.isDrainScheduled = false
                    return []
                }
                let batch = state.items
                state.items.removeAll(keepingCapacity: true)
                if state.pendingVideoCount > 0 {
                    state.hasPoppedFirstVideo = true
                }
                state.pendingVideoCount = 0
                state.pendingImageCount = 0
                if batch.isEmpty {
                    state.isDrainScheduled = false
                }
                return batch
            }
            if items.isEmpty || isFinished {
                break
            }
            for item in items {
                if isFinished || gate.withLock({ $0.isCancelled }) {
                    break
                }
                switch item {
                case .pause(let wallTime):
                    timeline.pause(at: wallTime)
                case .resume(let wallTime):
                    timeline.resume(at: wallTime)
                case .video(let frame):
                    autoreleasepool {
                        processVideoBuffer(frame.pixelBuffer.value, pts: frame.pts)
                    }
                case .image(let frame):
                    autoreleasepool {
                        processCGImage(frame.image, pts: frame.pts)
                    }
                }
            }
        }
    }

    private func notifyLimitReachedIfNeeded() -> Bool {
        guard writtenFrames >= maxFrames else { return false }
        let callback: (@Sendable () -> Void)? = gate.withLock { state in
            guard !state.limitReached else { return nil }
            state.limitReached = true
            state.items.removeAll { item in
                switch item {
                case .video, .image: true
                case .pause, .resume: false
                }
            }
            state.pendingVideoCount = 0
            state.pendingImageCount = 0
            return state.onLimitReached
        }
        callback?()
        return true
    }

    private func processVideoBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard !isFinished, writtenFrames < maxFrames else { return }
        guard let (srcWidth, srcHeight, bytesPerRow) = Self.validateBGRAPixelBuffer(pixelBuffer) else {
            return
        }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let adjusted = timeline.acceptVideoPTS(pts, wallTime: now) else { return }
        let seconds = adjusted.seconds
        guard seconds.isFinite else { return }
        lastObservedPTS = max(lastObservedPTS, seconds)

        if let lastPTS = lastAcceptedPTS, (seconds - lastPTS) < minInterval * 0.85 {
            return
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        // Fingerprint directly from locked BGRA memory BEFORE any copy or scale (both 1:1 and scaled paths).
        lastAcceptedPTS = seconds
        computeBGRAFingerprint(
            baseAddress: baseAddress,
            width: srcWidth,
            height: srcHeight,
            bytesPerRow: bytesPerRow,
            into: &scratchFingerprint
        )
        if let pending = pendingFrame {
            let elapsed = seconds - pending.startPTS
            if elapsed < Self.maxFrameDelay,
               Self.areFingerprintsNearlyIdentical(pendingFingerprint, scratchFingerprint) {
                return
            }
            flushPendingFrame(pending, delay: elapsed)
            pendingFrame = nil
            if notifyLimitReachedIfNeeded() {
                return
            }
        }

        let frameImage: CGImage?
        if srcWidth == targetWidth && srcHeight == targetHeight {
            frameImage = makeTightOpaqueBGRAImage(
                baseAddress: baseAddress,
                width: targetWidth,
                height: targetHeight,
                srcBytesPerRow: bytesPerRow
            )
        } else {
            frameImage = makeScaledOpaqueBGRAImage(
                baseAddress: baseAddress,
                srcWidth: srcWidth,
                srcHeight: srcHeight,
                srcBytesPerRow: bytesPerRow
            )
        }
        guard let frameImage else { return }
        materializedFrameCount += 1
        swap(&pendingFingerprint, &scratchFingerprint)
        pendingFrame = (image: frameImage, startPTS: seconds)
    }

    private func processCGImage(_ image: CGImage, pts: CMTime) {
        guard !isFinished, writtenFrames < maxFrames else { return }
        guard let adjusted = timeline.acceptVideoPTS(pts) else { return }
        let seconds = adjusted.seconds
        guard seconds.isFinite else { return }
        lastObservedPTS = max(lastObservedPTS, seconds)

        if let lastPTS = lastAcceptedPTS, (seconds - lastPTS) < minInterval * 0.85 {
            return
        }
        guard let context = ensureScaleContext() else { return }
        drawIntoScaleContext(context, from: image)
        acceptScaleContextFrame(context: context, seconds: seconds)
    }

    private func acceptScaleContextFrame(context: CGContext, seconds: TimeInterval) {
        lastAcceptedPTS = seconds
        guard computeScaleContextFingerprint(context: context, into: &scratchFingerprint) else { return }

        if let pending = pendingFrame {
            let elapsed = seconds - pending.startPTS
            if elapsed < Self.maxFrameDelay,
               Self.areFingerprintsNearlyIdentical(pendingFingerprint, scratchFingerprint) {
                return
            }
            flushPendingFrame(pending, delay: elapsed)
            pendingFrame = nil
            if notifyLimitReachedIfNeeded() {
                return
            }
        }

        guard let scaled = context.makeImage() else { return }
        materializedFrameCount += 1
        swap(&pendingFingerprint, &scratchFingerprint)
        pendingFrame = (image: scaled, startPTS: seconds)
    }

    private func flushPendingFrame(_ frame: (image: CGImage, startPTS: TimeInterval), delay: TimeInterval) {
        guard let dest = destination else { return }
        let clamped = min(max(delay, Self.minFrameDelay), Self.maxFrameDelay)
        let adjusted = clamped + delayCarry
        let centiseconds = max(2, min(400, Int((adjusted * 100.0).rounded())))
        let actualDelay = Double(centiseconds) / 100.0
        delayCarry = min(max(adjusted - actualDelay, -0.05), 0.05)

        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: actualDelay,
                kCGImagePropertyGIFDelayTime: actualDelay,
            ],
        ]
        CGImageDestinationAddImage(dest, frame.image, frameProps as CFDictionary)
        writtenFrames += 1
    }

    private func ensureScaleContext() -> CGContext? {
        if let lazyScaleContext {
            return lazyScaleContext
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: rgbColorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        lazyScaleContext = context
        return context
    }

    private func makeTightOpaqueBGRAImage(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        srcBytesPerRow: Int
    ) -> CGImage? {
        let dstBytesPerRow = width * 4
        let (totalBytes, overflow) = dstBytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, totalBytes > 0,
              let cfData = CFDataCreateMutable(kCFAllocatorDefault, totalBytes)
        else {
            return nil
        }
        CFDataSetLength(cfData, totalBytes)
        guard let dstPtr = CFDataGetMutableBytePtr(cfData) else { return nil }
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        if srcBytesPerRow == dstBytesPerRow {
            memcpy(dstPtr, srcPtr, totalBytes)
        } else {
            for y in 0..<height {
                memcpy(dstPtr + y * dstBytesPerRow, srcPtr + y * srcBytesPerRow, dstBytesPerRow)
            }
        }
        return wrapOpaqueBGRAImage(data: cfData, width: width, height: height, bytesPerRow: dstBytesPerRow)
    }

    private func makeScaledOpaqueBGRAImage(
        baseAddress: UnsafeMutableRawPointer,
        srcWidth: Int,
        srcHeight: Int,
        srcBytesPerRow: Int
    ) -> CGImage? {
        let dstBytesPerRow = targetWidth * 4
        let (totalBytes, overflow) = dstBytesPerRow.multipliedReportingOverflow(by: targetHeight)
        guard !overflow, totalBytes > 0,
              let cfData = CFDataCreateMutable(kCFAllocatorDefault, totalBytes)
        else {
            return nil
        }
        CFDataSetLength(cfData, totalBytes)
        guard let dstPtr = CFDataGetMutableBytePtr(cfData) else { return nil }

        var srcBuf = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth),
            rowBytes: srcBytesPerRow
        )
        var dstBuf = vImage_Buffer(
            data: dstPtr,
            height: vImagePixelCount(targetHeight),
            width: vImagePixelCount(targetWidth),
            rowBytes: dstBytesPerRow
        )
        let err = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
        guard err == kvImageNoError else { return nil }
        return wrapOpaqueBGRAImage(data: cfData, width: targetWidth, height: targetHeight, bytesPerRow: dstBytesPerRow)
    }

    private func wrapOpaqueBGRAImage(
        data: CFMutableData,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // Screen captures are opaque; `noneSkipFirst` avoids ImageIO alpha overhead and preserves all 256 GIF palette slots.
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: rgbColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func drawIntoScaleContext(_ context: CGContext, from sourceImage: CGImage) {
        context.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    }

    private func computeBGRAFingerprint(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        into buffer: inout [UInt8]
    ) {
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let grid = Self.fingerprintGrid
        let expectedCount = grid * grid * 3
        if buffer.count != expectedCount {
            buffer = [UInt8](repeating: 0, count: expectedCount)
        }
        buffer.withUnsafeMutableBufferPointer { dst in
            var writeIndex = 0
            for gy in 0..<grid {
                let y = min(height - 1, (gy * height) / grid)
                let rowOffset = y * bytesPerRow
                for gx in 0..<grid {
                    let x = min(width - 1, (gx * width) / grid)
                    let idx = rowOffset + x * 4
                    dst[writeIndex] = bytes[idx + 2]     // R
                    dst[writeIndex + 1] = bytes[idx + 1] // G
                    dst[writeIndex + 2] = bytes[idx]     // B
                    writeIndex += 3
                }
            }
        }
    }

    @discardableResult
    private func computeScaleContextFingerprint(context: CGContext, into buffer: inout [UInt8]) -> Bool {
        guard let rawPtr = context.data else { return false }
        let bytesPerRow = context.bytesPerRow
        guard bytesPerRow >= targetWidth * 4, context.height >= targetHeight else { return false }
        computeBGRAFingerprint(
            baseAddress: rawPtr,
            width: targetWidth,
            height: targetHeight,
            bytesPerRow: bytesPerRow,
            into: &buffer
        )
        return true
    }

    private static func areFingerprintsNearlyIdentical(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        var totalDiff = 0
        lhs.withUnsafeBufferPointer { lBuf in
            rhs.withUnsafeBufferPointer { rBuf in
                guard let lBase = lBuf.baseAddress, let rBase = rBuf.baseAddress else { return }
                for idx in 0..<lBuf.count {
                    totalDiff += abs(Int(lBase[idx]) - Int(rBase[idx]))
                }
            }
        }
        let meanDiff = Double(totalDiff) / Double(lhs.count)
        return meanDiff <= identicalMeanChannelDelta
    }
}
