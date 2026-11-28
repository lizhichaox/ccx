import AVFoundation
import CCXCore
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

/// Drives a live `SCStream` capture session into either `VideoRecordingWriter` (MP4/MOV)
/// or `GifRecordingEncoder` (GIF) with optional system audio and microphone capture.
@MainActor
public final class ScreenRecordingEngine {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "ScreenRecordingEngine")

    public var onUnexpectedStop: ((Error) -> Void)?
    public var onWriterError: ((Error) -> Void)?
    public var onNotice: ((String, String) -> Void)?
    public var onLimitReached: (() -> Void)?
    public var onMicrophoneLevel: ((Float) -> Void)?

    public let region: RecordingRegion
    public let settings: RecordingSettings
    public private(set) var effectiveSettings: RecordingSettings
    public let outputURL: URL

    private let targetPixelSize: CGSize
    private var videoWriter: VideoRecordingWriter?
    private var gifEncoder: GifRecordingEncoder?
    private var activeFinalizingWriter: VideoRecordingWriter?
    private var activeFinalizingEncoder: GifRecordingEncoder?
    private var stream: SCStream?
    private var streamOutput: RecordingStreamHandler?
    private var activeStreamConfig: SCStreamConfiguration?
    private var activeFrameInterval: CMTime?
    private var isStreamPaused = false
    private var configUpdateTask: Task<Void, Never>?
    private let videoQueue = DispatchQueue(label: "com.lizhichaox.ccx.record-video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.lizhichaox.ccx.record-audio", qos: .userInitiated)
    private var isStarted = false
    private var isStartingCapture = false
    private var isStopping = false
    private var isCancelled = false
    private var didCompleteSuccessfully = false
    private var isStopped: Bool { isStopping || isCancelled }

    public init(region: RecordingRegion, settings: RecordingSettings, outputURL: URL) {
        self.region = region
        self.settings = settings
        self.effectiveSettings = settings
        self.outputURL = outputURL
        self.targetPixelSize = region.pixelSize(for: settings.format)
    }

    public func start(excludingWindowIDs: Set<CGWindowID>) async throws {
        guard !isStopped, !isStarted else { return }
        isStarted = true

        // Fallback gracefully when microphone is enabled & authorized, but no audio input device exists.
        if effectiveSettings.effectiveMicrophone, AVCaptureDevice.default(for: .audio) == nil {
            effectiveSettings.capturesMicrophone = false
            onNotice?(
                CCXL10n.text("No Mic Found — Recording No Mic", zh: "未检测到麦克风，将无麦录制"),
                "mic.slash"
            )
        }

        try await prepareOutputPipeline(for: effectiveSettings)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            cancel()
            throw error
        }

        guard !isStopped else {
            throw CancellationError()
        }
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            cancel()
            throw RecordingError.writerStartFailed(
                CCXL10n.text("Display is no longer available.", zh: "显示器已不可用。")
            )
        }

        let excluded = excludingWindowIDs.isEmpty
            ? []
            : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        do {
            try await startStream(filter: filter, runSettings: effectiveSettings)
        } catch {
            if !isStopped,
               effectiveSettings.effectiveMicrophone,
               !Self.isPermissionDeniedError(error) {
                Self.logger.warning("Stream start failed with microphone enabled; retrying without microphone: \(error.localizedDescription)")
                if let failedWriter = videoWriter {
                    videoWriter = nil
                    await Task.detached(priority: .userInitiated) {
                        failedWriter.cancelAndWait()
                    }.value
                }
                guard !isStopped else { throw CancellationError() }
                effectiveSettings.capturesMicrophone = false
                onNotice?(
                    CCXL10n.text("Mic Unavailable — No Mic Audio", zh: "麦克风不可用，将无麦录制"),
                    "mic.slash"
                )
                do {
                    try await prepareOutputPipeline(for: effectiveSettings)
                    try await startStream(filter: filter, runSettings: effectiveSettings)
                    return
                } catch let retryError {
                    cancel()
                    throw retryError
                }
            }
            cancel()
            throw error
        }
    }

    public func pause() {
        guard !isStopped, !isStreamPaused else { return }
        isStreamPaused = true
        videoWriter?.pause()
        gifEncoder?.pause()
        scheduleStreamThrottleUpdate(paused: true)
    }

    public func resume() {
        guard !isStopped, isStreamPaused else { return }
        isStreamPaused = false
        videoWriter?.resume()
        gifEncoder?.resume()
        scheduleStreamThrottleUpdate(paused: false)
    }

    public func stop() async throws -> RecordingResult {
        guard !isStopped else {
            throw isCancelled ? CancellationError() : RecordingError.noFramesCaptured
        }
        isStopping = true
        configUpdateTask?.cancel()
        configUpdateTask = nil
        activeStreamConfig = nil
        activeFrameInterval = nil
        isStreamPaused = false
        defer {
            activeFinalizingWriter = nil
            activeFinalizingEncoder = nil
            clearCallbacks()
        }

        let activeStream = stream
        let activeHandler = streamOutput
        stream = nil
        streamOutput = nil
        if let activeStream {
            try? await activeStream.stopCapture()
            if let activeHandler {
                Self.removeOutputs(activeHandler, from: activeStream, settings: effectiveSettings)
            }
        }

        if isCancelled {
            videoWriter?.cancel()
            videoWriter = nil
            gifEncoder?.cancel()
            gifEncoder = nil
            RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
            throw CancellationError()
        }

        let summary: (duration: TimeInterval, frameCount: Int)
        if let videoWriter {
            self.videoWriter = nil
            self.activeFinalizingWriter = videoWriter
            videoWriter.onMicrophoneLevel = nil
            summary = try await videoWriter.finish()
        } else if let gifEncoder {
            self.gifEncoder = nil
            self.activeFinalizingEncoder = gifEncoder
            summary = try await gifEncoder.finish()
        } else {
            throw RecordingError.noFramesCaptured
        }

        if isCancelled {
            RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
            throw CancellationError()
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        didCompleteSuccessfully = true
        return RecordingResult(
            fileURL: outputURL,
            format: effectiveSettings.format,
            duration: summary.duration,
            fileSizeBytes: bytes,
            pixelSize: targetPixelSize,
            screenRect: region.screenRect
        )
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        clearCallbacks()
        configUpdateTask?.cancel()
        configUpdateTask = nil
        activeStreamConfig = nil
        activeFrameInterval = nil
        isStreamPaused = false

        let activeStream = stream
        let activeHandler = streamOutput
        let activeSettings = effectiveSettings
        stream = nil
        streamOutput = nil

        videoWriter?.cancel()
        videoWriter = nil
        gifEncoder?.cancel()
        gifEncoder = nil
        activeFinalizingWriter?.cancel()
        activeFinalizingWriter = nil
        activeFinalizingEncoder?.cancel()
        activeFinalizingEncoder = nil
        if !didCompleteSuccessfully {
            RecordingFileSecurity.removeRegularFileIfPresent(at: outputURL)
        }

        // If `startStream` is currently awaiting `startCapture()`, or `stop()` is already
        // awaiting `stopCapture()`, they observe `isCancelled` on return without racing.
        if let activeStream, !isStartingCapture, !isStopping {
            let streamBox = UncheckedSendableBox(activeStream)
            Task.detached {
                try? await streamBox.value.stopCapture()
                if let activeHandler {
                    Self.removeOutputs(activeHandler, from: streamBox.value, settings: activeSettings)
                }
            }
        }
    }

    private func clearCallbacks() {
        onUnexpectedStop = nil
        onWriterError = nil
        onNotice = nil
        onLimitReached = nil
        onMicrophoneLevel = nil
        videoWriter?.onMicrophoneLevel = nil
        activeFinalizingWriter?.onMicrophoneLevel = nil
    }

    private func scheduleStreamThrottleUpdate(paused: Bool) {
        guard let activeStream = stream,
              let config = activeStreamConfig,
              let normalInterval = activeFrameInterval
        else {
            return
        }
        let targetInterval = paused ? CMTime(value: 1, timescale: 1) : normalInterval
        let previousTask = configUpdateTask
        configUpdateTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self, !self.isStopped, self.stream === activeStream else { return }
            config.minimumFrameInterval = targetInterval
            try? await activeStream.updateConfiguration(config)
        }
    }

    // MARK: - Private Setup Helpers

    private func prepareOutputPipeline(for runSettings: RecordingSettings) async throws {
        let outputURL = self.outputURL
        let targetPixelSize = self.targetPixelSize

        if runSettings.format == .gif {
            let encoder = try await Task.detached(priority: .userInitiated) {
                try GifRecordingEncoder(
                    outputURL: outputURL,
                    pixelSize: targetPixelSize,
                    fps: runSettings.effectiveFPS
                )
            }.value
            guard !isStopped else {
                encoder.cancel()
                throw CancellationError()
            }
            encoder.onLimitReached = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.onLimitReached?()
                }
            }
            gifEncoder = encoder
            videoWriter = nil
        } else {
            let writer = try await Task.detached(priority: .userInitiated) {
                let candidate = try VideoRecordingWriter(
                    outputURL: outputURL,
                    format: runSettings.format,
                    pixelSize: targetPixelSize,
                    fps: runSettings.effectiveFPS,
                    capturesSystemAudio: runSettings.effectiveSystemAudio,
                    capturesMicrophone: runSettings.effectiveMicrophone
                )
                try candidate.start()
                return candidate
            }.value
            guard !isStopped else {
                writer.cancel()
                throw CancellationError()
            }
            writer.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    Self.logger.error("Video writer failed mid-recording: \(error.localizedDescription)")
                    if let onWriterError = self.onWriterError {
                        onWriterError(error)
                    } else {
                        self.onUnexpectedStop?(error)
                    }
                }
            }
            if runSettings.effectiveMicrophone {
                writer.onMicrophoneLevel = { [weak self] level in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !self.isStopped else { return }
                        self.onMicrophoneLevel?(level)
                    }
                }
            }
            videoWriter = writer
            gifEncoder = nil
        }
    }

    static func makeStreamConfiguration(
        region: RecordingRegion,
        targetPixelSize: CGSize,
        runSettings: RecordingSettings
    ) -> SCStreamConfiguration {
        let safeWidth = targetPixelSize.width.isFinite
            ? min(max(2, Int(targetPixelSize.width.rounded())), 8_192)
            : 2
        let safeHeight = targetPixelSize.height.isFinite
            ? min(max(2, Int(targetPixelSize.height.rounded())), 8_192)
            : 2
        let evenWidth = max(2, safeWidth - safeWidth % 2)
        let evenHeight = max(2, safeHeight - safeHeight % 2)

        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRectInDisplayPoints
        config.width = evenWidth
        config.height = evenHeight
        config.captureResolution = .best
        config.scalesToFit = true
        config.showsCursor = runSettings.showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(min(max(1, runSettings.effectiveFPS), 240)))
        if runSettings.format == .gif {
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3
        } else {
            // Native 4:2:0 YCbCr IOSurfaces cut VRAM/memory bandwidth by 62.5% and eliminate per-frame BGRA->NV12 conversion.
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            config.colorSpaceName = CGColorSpace.sRGB
            config.queueDepth = runSettings.effectiveFPS > 30 ? 5 : 3
        }
        config.capturesAudio = runSettings.effectiveSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AudioSampleNormalizer.sampleRate)
        config.channelCount = Int(AudioSampleNormalizer.channelCount)
        config.captureMicrophone = runSettings.effectiveMicrophone
        return config
    }

    private func startStream(filter: SCContentFilter, runSettings: RecordingSettings) async throws {
        guard !isStopped else { throw CancellationError() }

        let config = Self.makeStreamConfiguration(
            region: region,
            targetPixelSize: targetPixelSize,
            runSettings: runSettings
        )

        let handler = RecordingStreamHandler(
            videoWriter: videoWriter,
            gifEncoder: gifEncoder,
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped else { return }
                    Self.logger.error("Recording stream stopped unexpectedly: \(error.localizedDescription)")
                    self.onUnexpectedStop?(error)
                }
            }
        )

        let candidateStream = SCStream(filter: filter, configuration: config, delegate: handler)
        do {
            try candidateStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: videoQueue)
            if runSettings.effectiveSystemAudio {
                try candidateStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: audioQueue)
            }
            if runSettings.effectiveMicrophone {
                try candidateStream.addStreamOutput(handler, type: .microphone, sampleHandlerQueue: audioQueue)
            }

            isStartingCapture = true
            defer { isStartingCapture = false }

            try await candidateStream.startCapture()
        } catch {
            Self.removeOutputs(handler, from: candidateStream, settings: runSettings)
            throw error
        }

        if isStopped {
            try? await candidateStream.stopCapture()
            Self.removeOutputs(handler, from: candidateStream, settings: runSettings)
            throw CancellationError()
        }

        self.activeStreamConfig = config
        self.activeFrameInterval = config.minimumFrameInterval
        self.isStreamPaused = false
        self.stream = candidateStream
        self.streamOutput = handler
    }

    private nonisolated static func removeOutputs(
        _ handler: RecordingStreamHandler,
        from stream: SCStream,
        settings: RecordingSettings
    ) {
        try? stream.removeStreamOutput(handler, type: .screen)
        if settings.effectiveSystemAudio {
            try? stream.removeStreamOutput(handler, type: .audio)
        }
        if settings.effectiveMicrophone {
            try? stream.removeStreamOutput(handler, type: .microphone)
        }
    }

    private static func isPermissionDeniedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamError.errorDomain &&
            nsError.code == SCStreamError.Code.userDeclined.rawValue
    }
}

// MARK: - SCStreamOutput & Delegate

private final class RecordingStreamHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let videoWriter: VideoRecordingWriter?
    private let gifEncoder: GifRecordingEncoder?
    private let onError: @Sendable (Error) -> Void

    init(
        videoWriter: VideoRecordingWriter?,
        gifEncoder: GifRecordingEncoder?,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.videoWriter = videoWriter
        self.gifEncoder = gifEncoder
        self.onError = onError
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else {
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let videoWriter {
                videoWriter.appendVideo(pixelBuffer: pixelBuffer, pts: pts)
            } else if let gifEncoder {
                gifEncoder.appendVideo(pixelBuffer: pixelBuffer, pts: pts)
            }

        case .audio:
            videoWriter?.appendAudio(sampleBuffer: sampleBuffer, source: .system)

        case .microphone:
            videoWriter?.appendAudio(sampleBuffer: sampleBuffer, source: .microphone)

        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError(error)
    }
}
