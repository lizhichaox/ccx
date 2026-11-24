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
/// backpressure, 1:1 zero-copy static fingerprinting on matching BGRA pixel buffers,
/// centisecond delay-carry timing accuracy, and a hard pixel-memory / frame cap to prevent OOM.
public final class GifRecordingEncoder: @unchecked Sendable {
    public static let defaultMaxFrameCount = 900
    public static let defaultMaxBufferedBytes = 256 * 1024 * 1024 // 256 MB uncompressed RGBA budget

    private static let maxDimension = 4_096
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

    private struct GateState: Sendable {
        var pendingVideo: [PendingVideoFrame] = []
        var pendingImages: [PendingImageFrame] = []
        var hasPoppedFirstVideo = false
        var isDrainScheduled = false
        var isPaused = false
        var isAcceptingInput = true
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
    private let scaleContext: CGContext
    private let rgbColorSpace: CGColorSpace

    private var timeline = RecordingTimeline()
    private var lastAcceptedPTS: TimeInterval?
    private var pendingFrame: (image: CGImage, startPTS: TimeInterval, fingerprint: [UInt8])?
    private var scratchFingerprint: [UInt8]
    private var lastObservedPTS: TimeInterval = 0
    private var delayCarry: TimeInterval = 0
    private var writtenFrames = 0
    private var materializedFrameCount = 0
    private var isFinished = false

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
        self.scratchFingerprint = [UInt8](repeating: 0, count: Self.fingerprintGrid * Self.fingerprintGrid * 3)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.rgbColorSpace = colorSpace

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw RecordingError.encoderInitializationFailed
        }
        context.interpolationQuality = .high
        self.scaleContext = context

        try RecordingFileSecurity.validateOutputURLForWriting(outputURL)
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            0,
            nil
        ) else {
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

    public func appendVideo(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard pts.isNumeric,
              !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else {
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return }

        let frame = PendingVideoFrame(pixelBuffer: UncheckedSendableBox(pixelBuffer), pts: pts)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused, !state.limitReached else { return false }
            if state.pendingVideo.count >= Self.maxPendingVideoFrames {
                if !state.hasPoppedFirstVideo && state.pendingVideo.count >= 2 {
                    state.pendingVideo.remove(at: 1)
                } else {
                    state.pendingVideo.removeFirst()
                }
                state.droppedVideoFrames += 1
            }
            state.pendingVideo.append(frame)
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
        guard pts.isNumeric else { return }
        let frame = PendingImageFrame(image: image, pts: pts)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused, !state.limitReached else { return false }
            if state.pendingImages.count >= Self.maxPendingImageFrames {
                state.pendingImages.removeFirst()
            }
            state.pendingImages.append(frame)
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
        gate.withLock { state in
            state.isPaused = true
            state.pendingVideo.removeAll(keepingCapacity: true)
            state.pendingImages.removeAll(keepingCapacity: true)
        }
        queue.async { [weak self] in
            self?.timeline.pause(at: now)
        }
    }

    public func resume() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        gate.withLock { state in
            state.isPaused = false
        }
        queue.async { [weak self] in
            self?.timeline.resume(at: now)
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
                guard !self.isFinished else {
                    continuation.resume(returning: (max(self.lastObservedPTS, self.timeline.recordedDurationSeconds), self.writtenFrames))
                    return
                }
                self.drainPending()
                self.isFinished = true
                self.timeline.finish(at: finishWallTime)

                let finalEnd = max(self.lastObservedPTS, self.timeline.recordedDurationSeconds)
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
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    continuation.resume(throwing: RecordingError.noFramesCaptured)
                    return
                }

                let finalized = autoreleasepool {
                    CGImageDestinationFinalize(dest)
                }
                self.destination = nil
                guard finalized else {
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    continuation.resume(throwing: RecordingError.encoderFinalizeFailed)
                    return
                }

                RecordingFileSecurity.restrictFilePermissions(at: self.outputURL)
                let duration = max(self.minInterval, finalEnd)
                continuation.resume(returning: (duration, self.writtenFrames))
            }
        }
    }

    public func cancel() {
        gate.withLock { state in
            state.isAcceptingInput = false
            state.pendingVideo.removeAll()
            state.pendingImages.removeAll()
        }
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.isFinished = true
            self.pendingFrame = nil
            self.destination = nil
            RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
        }
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

    // MARK: - Serial Queue Helpers

    private func drainPending() {
        while true {
            let batch: ([PendingVideoFrame], [PendingImageFrame]) = gate.withLock { state in
                let videos = state.pendingVideo
                let images = state.pendingImages
                state.pendingVideo.removeAll(keepingCapacity: true)
                state.pendingImages.removeAll(keepingCapacity: true)
                if !videos.isEmpty {
                    state.hasPoppedFirstVideo = true
                }
                if videos.isEmpty && images.isEmpty {
                    state.isDrainScheduled = false
                }
                return (videos, images)
            }
            if batch.0.isEmpty && batch.1.isEmpty {
                break
            }
            if isFinished {
                break
            }
            for frame in batch.0 {
                autoreleasepool {
                    processVideoBuffer(frame.pixelBuffer.value, pts: frame.pts)
                }
            }
            for frame in batch.1 {
                autoreleasepool {
                    processCGImage(frame.image, pts: frame.pts)
                }
            }
        }
    }

    private func notifyLimitReachedIfNeeded() -> Bool {
        guard writtenFrames >= maxFrames else { return false }
        let callback: (@Sendable () -> Void)? = gate.withLock { state in
            guard !state.limitReached else { return nil }
            state.limitReached = true
            state.pendingVideo.removeAll()
            state.pendingImages.removeAll()
            return state.onLimitReached
        }
        callback?()
        return true
    }

    private func processVideoBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard !isFinished, writtenFrames < maxFrames else { return }
        guard !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA
        else {
            return
        }
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0, bytesPerRow >= srcWidth * 4 else { return }

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

        // Fast 1:1 path: fingerprint directly from locked BGRA memory before any full-frame copy.
        if srcWidth == targetWidth && srcHeight == targetHeight {
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
                   Self.areFingerprintsNearlyIdentical(pending.fingerprint, scratchFingerprint) {
                    return
                }
                flushPendingFrame(pending, delay: elapsed)
                pendingFrame = nil
                if notifyLimitReachedIfNeeded() {
                    return
                }
            }
            guard copyBGRAToScaleContext(
                baseAddress: baseAddress,
                width: srcWidth,
                height: srcHeight,
                srcBytesPerRow: bytesPerRow
            ) else {
                return
            }
            guard let scaled = scaleContext.makeImage() else { return }
            materializedFrameCount += 1
            pendingFrame = (image: scaled, startPTS: seconds, fingerprint: scratchFingerprint)
            return
        }

        // Scaled path: copy bytes once into CFData-backed CGImage (no throwaway CGContext).
        guard let sourceImage = makeOwnedBGRAImage(
            baseAddress: baseAddress,
            width: srcWidth,
            height: srcHeight,
            bytesPerRow: bytesPerRow
        ) else {
            return
        }
        drawIntoScaleContext(from: sourceImage)
        acceptScaleContextFrame(seconds: seconds)
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
        drawIntoScaleContext(from: image)
        acceptScaleContextFrame(seconds: seconds)
    }

    private func acceptScaleContextFrame(seconds: TimeInterval) {
        lastAcceptedPTS = seconds
        guard computeFingerprint(into: &scratchFingerprint) else { return }

        if let pending = pendingFrame {
            let elapsed = seconds - pending.startPTS
            if elapsed < Self.maxFrameDelay,
               Self.areFingerprintsNearlyIdentical(pending.fingerprint, scratchFingerprint) {
                return
            }
            flushPendingFrame(pending, delay: elapsed)
            pendingFrame = nil
            if notifyLimitReachedIfNeeded() {
                return
            }
        }

        guard let scaled = scaleContext.makeImage() else { return }
        materializedFrameCount += 1
        pendingFrame = (image: scaled, startPTS: seconds, fingerprint: scratchFingerprint)
    }

    private func flushPendingFrame(_ frame: (image: CGImage, startPTS: TimeInterval, fingerprint: [UInt8]), delay: TimeInterval) {
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

    private func makeOwnedBGRAImage(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        let (totalBytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, totalBytes > 0 else { return nil }
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
        guard let cfData = CFDataCreate(kCFAllocatorDefault, srcPtr, totalBytes),
              let provider = CGDataProvider(data: cfData)
        else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
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
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func copyBGRAToScaleContext(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        srcBytesPerRow: Int
    ) -> Bool {
        guard let dstRaw = scaleContext.data else { return false }
        let dstBytesPerRow = scaleContext.bytesPerRow
        guard dstBytesPerRow >= width * 4, scaleContext.height >= height else { return false }

        let src = baseAddress.assumingMemoryBound(to: UInt8.self)
        let dst = dstRaw.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let srcRow = y * srcBytesPerRow
            let dstRow = y * dstBytesPerRow
            var offset = 0
            let rowByteWidth = width * 4
            while offset < rowByteWidth {
                let s = srcRow + offset
                let d = dstRow + offset
                dst[d] = src[s + 2]     // R
                dst[d + 1] = src[s + 1] // G
                dst[d + 2] = src[s]     // B
                dst[d + 3] = src[s + 3] // A
                offset += 4
            }
        }
        return true
    }

    private func drawIntoScaleContext(from sourceImage: CGImage) {
        scaleContext.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        scaleContext.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
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
        var writeIndex = 0
        for gy in 0..<grid {
            let y = min(height - 1, (gy * height) / grid)
            let rowOffset = y * bytesPerRow
            for gx in 0..<grid {
                let x = min(width - 1, (gx * width) / grid)
                let idx = rowOffset + x * 4
                buffer[writeIndex] = bytes[idx + 2]     // R
                buffer[writeIndex + 1] = bytes[idx + 1] // G
                buffer[writeIndex + 2] = bytes[idx]     // B
                writeIndex += 3
            }
        }
    }

    @discardableResult
    private func computeFingerprint(into buffer: inout [UInt8]) -> Bool {
        guard let rawPtr = scaleContext.data else { return false }
        let bytesPerRow = scaleContext.bytesPerRow
        guard bytesPerRow >= targetWidth * 4, scaleContext.height >= targetHeight else { return false }

        let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
        let grid = Self.fingerprintGrid
        let expectedCount = grid * grid * 3
        if buffer.count != expectedCount {
            buffer = [UInt8](repeating: 0, count: expectedCount)
        }
        var writeIndex = 0
        for gy in 0..<grid {
            let y = min(targetHeight - 1, (gy * targetHeight) / grid)
            let rowOffset = y * bytesPerRow
            for gx in 0..<grid {
                let x = min(targetWidth - 1, (gx * targetWidth) / grid)
                let idx = rowOffset + x * 4
                buffer[writeIndex] = bytes[idx]
                buffer[writeIndex + 1] = bytes[idx + 1]
                buffer[writeIndex + 2] = bytes[idx + 2]
                writeIndex += 3
            }
        }
        return true
    }

    private static func areFingerprintsNearlyIdentical(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        var totalDiff = 0
        for idx in 0..<lhs.count {
            totalDiff += abs(Int(lhs[idx]) - Int(rhs[idx]))
        }
        let meanDiff = Double(totalDiff) / Double(lhs.count)
        return meanDiff <= identicalMeanChannelDelta
    }
}
