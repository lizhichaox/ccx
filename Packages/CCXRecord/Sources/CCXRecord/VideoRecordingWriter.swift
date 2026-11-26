import AVFoundation
import CCXCore
import CoreMedia
import CoreVideo
import Foundation
import os
import OSLog

public enum RecordingError: LocalizedError, Sendable {
    case unsupportedFormat
    case writerInitializationFailed(String)
    case writerStartFailed(String)
    case encoderInitializationFailed
    case encoderFinalizeFailed
    case noFramesCaptured

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            CCXL10n.text("Unsupported recording format.", zh: "不支持的录屏格式。")
        case .writerInitializationFailed(let reason):
            CCXL10n.text("Could not initialize video writer: \(reason)", zh: "无法初始化视频写入器：\(reason)")
        case .writerStartFailed(let reason):
            CCXL10n.text("Could not start writing recording: \(reason)", zh: "无法开始写入录屏：\(reason)")
        case .encoderInitializationFailed:
            CCXL10n.text("Could not initialize GIF encoder.", zh: "无法初始化 GIF 编码器。")
        case .encoderFinalizeFailed:
            CCXL10n.text("Could not finalize GIF file.", zh: "无法生成 GIF 文件。")
        case .noFramesCaptured:
            CCXL10n.text("No video frames were captured.", zh: "未捕获到视频画面。")
        }
    }
}

/// Hardware-accelerated MP4 (H.264) and MOV (HEVC) writer with an optional mixed 48 kHz stereo AAC track.
///
/// All mutable `AVAssetWriter` state is strictly serialized on a single private dispatch queue,
/// while an `OSAllocatedUnfairLock`-guarded bounded pending buffer enforces backpressure so
/// `IOSurface`-backed `CVPixelBuffer`s never accumulate unboundedly.
public final class VideoRecordingWriter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "VideoRecordingWriter")
    private static let maxH264Dimension = 4_096
    private static let maxVideoDimension = 8_192
    private static let maxFPS = 240
    static let maxPendingVideoFrames = 3
    private static let maxPendingAudioBuffers = 32

    private struct PendingVideoFrame: Sendable {
        let pixelBuffer: UncheckedSendableBox<CVPixelBuffer>
        let pts: CMTime
    }

    private struct PendingAudioSample: Sendable {
        let sampleBuffer: UncheckedSendableBox<CMSampleBuffer>
        let source: RecordingAudioSource
    }

    private enum PendingItem: Sendable {
        case video(PendingVideoFrame)
        case audio(PendingAudioSample)
        case pause(CMTime)
        case resume(CMTime)
    }

    private struct GateState: Sendable {
        var items: [PendingItem] = []
        var pendingVideoCount = 0
        var pendingAudioCount = 0
        var hasPoppedFirstVideo = false
        var isDrainScheduled = false
        var isPaused = false
        var isAcceptingInput = true
        var isCancelled = false
        var droppedVideoFrames = 0
        var droppedAudioBuffers = 0
        var onError: (@Sendable (Error) -> Void)?
        var didReportError = false
    }

    private let queue = DispatchQueue(label: "com.lizhichaox.ccx.video-writer", qos: .userInitiated)
    private let gate: OSAllocatedUnfairLock<GateState>
    private let outputURL: URL
    private let expectsSystemAudio: Bool
    private let expectsMicrophone: Bool
    private var hasAudioTrack: Bool { expectsSystemAudio || expectsMicrophone }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    private let systemNormalizer = AudioSampleNormalizer()
    private let micNormalizer = AudioSampleNormalizer()
    private var singleSourceAudioScratch: [Float] = []
    private var mixer = DualAudioMixer()
    private var timeline = RecordingTimeline()
    private var sessionStarted = false
    private var isFinished = false
    private var isFinalizing = false
    private var finishedSummary: (duration: TimeInterval, frameCount: Int)?
    private var finishedError: Error?
    private var pendingFinishContinuations: [CheckedContinuation<(duration: TimeInterval, frameCount: Int), Error>] = []
    private var frameCount = 0
    private var lastAppendedAudioPTS: CMTime?

    public var onError: (@Sendable (Error) -> Void)? {
        get { gate.withLock { $0.onError } }
        set { gate.withLock { $0.onError = newValue } }
    }

    var droppedVideoFrameCountForTesting: Int {
        gate.withLock { $0.droppedVideoFrames }
    }

    public init(
        outputURL: URL,
        format: RecordingFormat,
        pixelSize: CGSize,
        fps: Int? = nil,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        onError: (@Sendable (Error) -> Void)? = nil
    ) throws {
        guard let fileType = format.avFileType, let codec = format.videoCodec else {
            throw RecordingError.unsupportedFormat
        }
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0
        else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Invalid video dimensions.", zh: "视频尺寸无效。")
            )
        }

        self.outputURL = outputURL
        self.expectsSystemAudio = capturesSystemAudio
        self.expectsMicrophone = capturesMicrophone
        self.gate = OSAllocatedUnfairLock(initialState: GateState(onError: onError))

        let maxDim = Double(codec == .h264 ? Self.maxH264Dimension : Self.maxVideoDimension)
        var scaledW = max(2.0, pixelSize.width.rounded())
        var scaledH = max(2.0, pixelSize.height.rounded())
        let largest = max(scaledW, scaledH)
        if largest > maxDim {
            let ratio = maxDim / largest
            scaledW = max(2.0, (scaledW * ratio).rounded())
            scaledH = max(2.0, (scaledH * ratio).rounded())
        }
        let rawW = Int(min(scaledW, maxDim))
        let rawH = Int(min(scaledH, maxDim))
        let width = max(2, rawW - rawW % 2)
        let height = max(2, rawH - rawH % 2)

        try RecordingFileSecurity.validateOutputURLForWriting(outputURL)
        do {
            self.writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw RecordingError.writerInitializationFailed(error.localizedDescription)
        }
        if format == .mp4 {
            writer.shouldOptimizeForNetworkUse = true
            writer.directoryForTemporaryFiles = outputURL.deletingLastPathComponent()
        } else {
            writer.shouldOptimizeForNetworkUse = false
        }

        let effectiveFPS = min(max(1, fps ?? format.targetFPS), Self.maxFPS)
        let pixelCount = Double(width) * Double(height)
        let fpsScale = 0.45 + 0.55 * min(1.0, max(0.25, Double(effectiveFPS) / 60.0))
        let baseBitRate = Int(min(100_000_000.0, pixelCount * 9.0 * fpsScale))
        let targetBitRate = max(2_000_000, min(35_000_000, baseBitRate))
        // Disable B-frame reordering for real-time capture: lowers Intel/Apple Silicon encoder
        // latency and prevents VFR/pause-gap timestamp reordering failures across hardware encoders.
        var compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: format == .mov ? Int(Double(targetBitRate) * 0.78) : targetBitRate,
            AVVideoExpectedSourceFrameRateKey: effectiveFPS,
            AVVideoMaxKeyFrameIntervalKey: effectiveFPS * 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 {
            compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(vInput) else {
            throw RecordingError.writerInitializationFailed(
                CCXL10n.text("Cannot add video input for requested dimensions.", zh: "当前尺寸无法添加视频轨道。")
            )
        }
        self.videoInput = vInput

        // `pixelBufferPool` is never used; passing `nil` avoids creating an unused pool and lets
        // VideoToolbox ingest both zero-copy `420v` (NV12) IOSurfaces and `32BGRA` buffers directly.
        self.pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: nil
        )
        writer.add(vInput)

        if capturesSystemAudio || capturesMicrophone {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Int(AudioSampleNormalizer.sampleRate),
                AVNumberOfChannelsKey: Int(AudioSampleNormalizer.channelCount),
                AVEncoderBitRateKey: 192_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(aInput) else {
                throw RecordingError.writerInitializationFailed(
                    CCXL10n.text("Cannot add audio input to video writer.", zh: "无法添加音频轨道。")
                )
            }
            writer.add(aInput)
            self.audioInput = aInput
        } else {
            self.audioInput = nil
        }
    }

    public func start() throws {
        try queue.sync {
            guard !isFinished, writer.status == .unknown else {
                throw RecordingError.writerStartFailed(
                    CCXL10n.text("Recording session has already started.", zh: "录制会话已开始。")
                )
            }
            guard writer.startWriting() else {
                let reason = writer.error?.localizedDescription
                    ?? CCXL10n.text("The video encoder could not start.", zh: "视频编码器无法启动。")
                RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
                throw RecordingError.writerStartFailed(reason)
            }
            RecordingFileSecurity.restrictFilePermissions(at: outputURL)
        }
    }

    public func appendVideo(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard pts.isNumeric,
              CVPixelBufferGetWidth(pixelBuffer) > 0,
              CVPixelBufferGetHeight(pixelBuffer) > 0
        else {
            return
        }
        let frame = PendingVideoFrame(pixelBuffer: UncheckedSendableBox(pixelBuffer), pts: pts)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused, !state.isCancelled else { return false }
            if state.pendingVideoCount >= Self.maxPendingVideoFrames {
                // Before the first frame establishes sessionStartPTS, keep slot 0 and evict slot 1.
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

    public func appendAudio(sampleBuffer: CMSampleBuffer, source: RecordingAudioSource) {
        guard hasAudioTrack else { return }
        let sample = PendingAudioSample(sampleBuffer: UncheckedSendableBox(sampleBuffer), source: source)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused, !state.isCancelled else { return false }
            if state.pendingAudioCount >= Self.maxPendingAudioBuffers {
                if let evictIdx = state.items.firstIndex(where: {
                    if case .audio = $0 { return true }
                    return false
                }) {
                    state.items.remove(at: evictIdx)
                    state.pendingAudioCount -= 1
                    state.droppedAudioBuffers += 1
                }
            }
            state.items.append(.audio(sample))
            state.pendingAudioCount += 1
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
                case .video, .audio: true
                case .pause, .resume: false
                }
            }
            state.pendingVideoCount = 0
            state.pendingAudioCount = 0
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
                if let summary = self.finishedSummary {
                    continuation.resume(returning: summary)
                    return
                }
                if let error = self.finishedError {
                    continuation.resume(throwing: error)
                    return
                }
                if self.isFinalizing {
                    self.pendingFinishContinuations.append(continuation)
                    return
                }
                if self.isFinished {
                    continuation.resume(throwing: RecordingError.noFramesCaptured)
                    return
                }
                if self.gate.withLock({ $0.isCancelled }) {
                    self.isFinished = true
                    self.pendingFinishContinuations.append(continuation)
                    if self.writer.status == .writing || self.writer.status == .unknown {
                        self.writer.cancelWriting()
                    }
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    self.completeFinish(with: .failure(CancellationError()))
                    return
                }

                // Drain any frames accepted prior to finish() before closing inputs.
                self.drainPending()
                if self.gate.withLock({ $0.isCancelled }) {
                    self.isFinished = true
                    self.pendingFinishContinuations.append(continuation)
                    if self.writer.status == .writing || self.writer.status == .unknown {
                        self.writer.cancelWriting()
                    }
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    self.completeFinish(with: .failure(CancellationError()))
                    return
                }

                self.isFinished = true
                self.isFinalizing = true
                self.pendingFinishContinuations.append(continuation)

                if self.sessionStarted && self.expectsSystemAudio && self.expectsMicrophone {
                    if let tail = self.mixer.flushSlice() {
                        self.appendMixedPCM(tail.samples, pts: tail.pts)
                    }
                }
                self.timeline.finish(at: finishWallTime)

                guard self.sessionStarted, self.frameCount > 0, self.writer.status != .failed else {
                    let failure: Error = self.writer.error ?? RecordingError.noFramesCaptured
                    if self.writer.status == .writing || self.writer.status == .unknown {
                        self.writer.cancelWriting()
                    }
                    RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                    self.completeFinish(with: .failure(failure))
                    return
                }

                let capturedDuration = self.timeline.recordedDurationSeconds
                let capturedFrames = self.frameCount
                self.videoInput.markAsFinished()
                self.audioInput?.markAsFinished()

                let writerRef = UncheckedSendableBox(self.writer)
                // Capture `self` strongly in this one-shot completion so pending continuations can never leak.
                self.writer.finishWriting {
                    let status = writerRef.value.status
                    let writerError = writerRef.value.error
                    self.queue.async {
                        if self.finishedSummary != nil || self.finishedError != nil {
                            if self.gate.withLock({ $0.isCancelled }) {
                                RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                            }
                            return
                        }
                        if self.gate.withLock({ $0.isCancelled }) {
                            RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                            self.completeFinish(with: .failure(CancellationError()))
                            return
                        }
                        if status == .completed {
                            RecordingFileSecurity.restrictFilePermissions(at: self.outputURL)
                            self.completeFinish(with: .success((capturedDuration, capturedFrames)))
                        } else {
                            RecordingFileSecurity.removeRegularFileIfPresent(at: self.outputURL)
                            let error = writerError
                                ?? RecordingError.writerStartFailed(
                                    CCXL10n.text("Failed to finalize video recording.", zh: "无法完成视频封装。")
                                )
                            self.completeFinish(with: .failure(error))
                        }
                    }
                }
            }
        }
    }

    public func cancel() {
        gate.withLock { state in
            state.isAcceptingInput = false
            state.isCancelled = true
            state.items.removeAll()
            state.pendingVideoCount = 0
            state.pendingAudioCount = 0
        }
        queue.async { [weak self] in
            self?.performCancelOnQueue()
        }
    }

    /// Synchronously cancels writing and removes the partial file before reusing `outputURL`.
    func cancelAndWait() {
        gate.withLock { state in
            state.isAcceptingInput = false
            state.isCancelled = true
            state.items.removeAll()
            state.pendingVideoCount = 0
            state.pendingAudioCount = 0
        }
        queue.sync {
            performCancelOnQueue()
        }
    }

    private func performCancelOnQueue() {
        if isFinalizing {
            mixer.reset()
            systemNormalizer.reset()
            micNormalizer.reset()
            if writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
            RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
            completeFinish(with: .failure(CancellationError()))
            return
        }
        guard !isFinished else { return }
        isFinished = true
        finishedError = CancellationError()
        mixer.reset()
        systemNormalizer.reset()
        micNormalizer.reset()
        if writer.status == .writing || writer.status == .unknown {
            writer.cancelWriting()
        }
        RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
    }

    // MARK: - Serial Queue Helpers

    private func completeFinish(with result: Result<(duration: TimeInterval, frameCount: Int), Error>) {
        isFinalizing = false
        switch result {
        case .success(let summary):
            finishedSummary = summary
        case .failure(let error):
            finishedError = error
        }
        let continuations = pendingFinishContinuations
        pendingFinishContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func drainPending() {
        while true {
            let items: [PendingItem] = gate.withLock { state in
                if state.isCancelled {
                    state.items.removeAll()
                    state.pendingVideoCount = 0
                    state.pendingAudioCount = 0
                    state.isDrainScheduled = false
                    return []
                }
                let batch = state.items
                state.items.removeAll(keepingCapacity: true)
                if state.pendingVideoCount > 0 {
                    state.hasPoppedFirstVideo = true
                }
                state.pendingVideoCount = 0
                state.pendingAudioCount = 0
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
                case .pause(let now):
                    timeline.pause(at: now)
                    mixer.reset()
                    systemNormalizer.reset()
                    micNormalizer.reset()
                case .resume(let now):
                    timeline.resume(at: now)
                case .video(let frame):
                    processVideo(pixelBuffer: frame.pixelBuffer.value, pts: frame.pts)
                case .audio(let sample):
                    processAudio(sampleBuffer: sample.sampleBuffer.value, source: sample.source)
                }
            }
        }
    }

    private func reportWriterFailureIfNeeded() {
        guard writer.status == .failed else { return }
        let error = writer.error ?? RecordingError.writerStartFailed(
            CCXL10n.text("Video writer failed unexpectedly.", zh: "视频写入意外失败。")
        )
        let callback: (@Sendable (Error) -> Void)? = gate.withLock { state in
            guard !state.didReportError else { return nil }
            state.didReportError = true
            state.isAcceptingInput = false
            state.items.removeAll()
            state.pendingVideoCount = 0
            state.pendingAudioCount = 0
            return state.onError
        }
        if let callback {
            Self.logger.error("AVAssetWriter failed mid-recording: \(error.localizedDescription)")
            callback(error)
        }
    }

    private func processVideo(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard !isFinished else { return }
        if writer.status == .failed {
            reportWriterFailureIfNeeded()
            return
        }
        guard writer.status == .writing else { return }
        guard videoInput.isReadyForMoreMediaData else {
            gate.withLock { $0.droppedVideoFrames += 1 }
            return
        }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let adjustedPTS = timeline.acceptVideoPTS(pts, wallTime: now) else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: adjustedPTS)
            sessionStarted = true
        }
        if pixelAdaptor.append(pixelBuffer, withPresentationTime: adjustedPTS) {
            frameCount += 1
        } else {
            reportWriterFailureIfNeeded()
            if writer.status != .failed {
                Self.logger.warning("Failed to append video frame at pts=\(adjustedPTS.seconds) (status=\(self.writer.status.rawValue))")
            }
        }
    }

    private func processAudio(sampleBuffer: CMSampleBuffer, source: RecordingAudioSource) {
        guard !isFinished, let audioInput else { return }
        if writer.status == .failed {
            reportWriterFailureIfNeeded()
            return
        }
        guard writer.status == .writing else { return }

        let isDualSource = expectsSystemAudio && expectsMicrophone
        if !isDualSource {
            guard sessionStarted, audioInput.isReadyForMoreMediaData else { return }
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let adjustedPTS = timeline.acceptAudioPTS(rawPTS, source: source) else { return }

        let activeNormalizer = (source == .system) ? systemNormalizer : micNormalizer
        let samples = activeNormalizer.normalizeSlice(sampleBuffer)
        guard !samples.isEmpty else { return }

        if isDualSource {
            let emitted: (samples: ArraySlice<Float>, pts: CMTime)? = switch source {
            case .system:
                mixer.pushSystemSlice(samples, pts: adjustedPTS)
            case .microphone:
                mixer.pushMicrophoneSlice(samples, pts: adjustedPTS)
            }
            if let chunk = emitted {
                appendMixedPCM(chunk.samples, pts: chunk.pts)
            }
        } else {
            let sanitized = DualAudioMixer.sanitize(samples, into: &singleSourceAudioScratch)
            if !sanitized.isEmpty {
                appendMixedPCM(sanitized, pts: adjustedPTS)
            }
        }
    }

    private func appendMixedPCM(_ samples: ArraySlice<Float>, pts: CMTime) {
        guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        if let prev = lastAppendedAudioPTS, pts <= prev {
            return
        }
        guard let pcmBuffer = DualAudioMixer.makePCMSampleBuffer(
            interleavedStereoFloat32: samples,
            pts: pts
        ) else {
            Self.logger.warning("Failed to build PCM sample buffer at pts=\(pts.seconds)")
            return
        }
        if audioInput.append(pcmBuffer) {
            lastAppendedAudioPTS = pts
        } else {
            reportWriterFailureIfNeeded()
        }
    }
}
