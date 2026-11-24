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

    private struct GateState: Sendable {
        var pendingVideo: [PendingVideoFrame] = []
        var pendingAudio: [PendingAudioSample] = []
        var hasPoppedFirstVideo = false
        var isDrainScheduled = false
        var isPaused = false
        var isAcceptingInput = true
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

    private let normalizer = AudioSampleNormalizer()
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
        writer.shouldOptimizeForNetworkUse = (format == .mp4)

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

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
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

        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        self.pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourceAttrs
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
        guard pts.isNumeric else { return }
        let frame = PendingVideoFrame(pixelBuffer: UncheckedSendableBox(pixelBuffer), pts: pts)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused else { return false }
            if state.pendingVideo.count >= Self.maxPendingVideoFrames {
                // Before the first frame establishes sessionStartPTS, keep slot 0 and evict slot 1.
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

    public func appendAudio(sampleBuffer: CMSampleBuffer, source: RecordingAudioSource) {
        guard hasAudioTrack else { return }
        let sample = PendingAudioSample(sampleBuffer: UncheckedSendableBox(sampleBuffer), source: source)
        let shouldSchedule: Bool = gate.withLock { state in
            guard state.isAcceptingInput, !state.isPaused else { return false }
            if state.pendingAudio.count >= Self.maxPendingAudioBuffers {
                state.pendingAudio.removeFirst()
                state.droppedAudioBuffers += 1
            }
            state.pendingAudio.append(sample)
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
            state.pendingAudio.removeAll(keepingCapacity: true)
        }
        queue.async { [weak self] in
            self?.timeline.pause(at: now)
            self?.mixer.reset()
            self?.normalizer.reset()
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

                // Drain any frames accepted prior to finish() before closing inputs.
                self.drainPending()
                self.isFinished = true
                self.isFinalizing = true
                self.pendingFinishContinuations.append(continuation)

                if self.sessionStarted && self.expectsSystemAudio && self.expectsMicrophone {
                    if let tail = self.mixer.flush() {
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
                self.writer.finishWriting { [weak self] in
                    let status = writerRef.value.status
                    let writerError = writerRef.value.error
                    guard let self else { return }
                    self.queue.async {
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
            state.pendingVideo.removeAll()
            state.pendingAudio.removeAll()
        }
        queue.async { [weak self] in
            self?.performCancelOnQueue()
        }
    }

    /// Synchronously cancels writing and removes the partial file before reusing `outputURL`.
    func cancelAndWait() {
        gate.withLock { state in
            state.isAcceptingInput = false
            state.pendingVideo.removeAll()
            state.pendingAudio.removeAll()
        }
        queue.sync {
            performCancelOnQueue()
        }
    }

    private func performCancelOnQueue() {
        guard !isFinished else { return }
        isFinished = true
        mixer.reset()
        normalizer.reset()
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
            let batch: ([PendingVideoFrame], [PendingAudioSample]) = gate.withLock { state in
                let videos = state.pendingVideo
                let audios = state.pendingAudio
                state.pendingVideo.removeAll(keepingCapacity: true)
                state.pendingAudio.removeAll(keepingCapacity: true)
                if !videos.isEmpty {
                    state.hasPoppedFirstVideo = true
                }
                if videos.isEmpty && audios.isEmpty {
                    state.isDrainScheduled = false
                }
                return (videos, audios)
            }
            if batch.0.isEmpty && batch.1.isEmpty {
                break
            }
            if isFinished {
                break
            }
            for frame in batch.0 {
                processVideo(pixelBuffer: frame.pixelBuffer.value, pts: frame.pts)
            }
            for sample in batch.1 {
                processAudio(sampleBuffer: sample.sampleBuffer.value, source: sample.source)
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
            state.pendingVideo.removeAll()
            state.pendingAudio.removeAll()
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
        guard videoInput.isReadyForMoreMediaData else { return }

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
        guard let adjustedPTS = timeline.acceptAudioPTS(rawPTS) else { return }

        let samples = normalizer.normalize(sampleBuffer)
        guard !samples.isEmpty else { return }

        if isDualSource {
            let emitted: [(samples: [Float], pts: CMTime)] = switch source {
            case .system:
                mixer.pushSystem(samples, pts: adjustedPTS)
            case .microphone:
                mixer.pushMicrophone(samples, pts: adjustedPTS)
            }
            for chunk in emitted {
                appendMixedPCM(chunk.samples, pts: chunk.pts)
            }
        } else {
            appendMixedPCM(samples, pts: adjustedPTS)
        }
    }

    private func appendMixedPCM(_ samples: [Float], pts: CMTime) {
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
