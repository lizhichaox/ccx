import AVFoundation
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
    public var onNotice: ((String, String) -> Void)?
    public var onLimitReached: (() -> Void)?

    public let region: RecordingRegion
    public let settings: RecordingSettings
    public private(set) var effectiveSettings: RecordingSettings
    public let outputURL: URL

    private let targetPixelSize: CGSize
    private var videoWriter: VideoRecordingWriter?
    private var gifEncoder: GifRecordingEncoder?
    private var stream: SCStream?
    private var streamOutput: RecordingStreamHandler?
    private let videoQueue = DispatchQueue(label: "com.lizhichaox.ccx.record-video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.lizhichaox.ccx.record-audio", qos: .userInitiated)
    private var isStarted = false
    private var isStartingCapture = false
    private var isStopped = false

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
            onNotice?("No Microphone Detected — Recording Without Mic", "mic.slash")
        }

        try prepareOutputPipeline(for: effectiveSettings)

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
            throw RecordingError.writerStartFailed("Display is no longer available.")
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
                videoWriter?.cancelAndWait()
                videoWriter = nil
                effectiveSettings.capturesMicrophone = false
                onNotice?("Microphone Unavailable — Recording Without Mic", "mic.slash")
                do {
                    try prepareOutputPipeline(for: effectiveSettings)
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
        guard !isStopped else { return }
        videoWriter?.pause()
        gifEncoder?.pause()
    }

    public func resume() {
        guard !isStopped else { return }
        videoWriter?.resume()
        gifEncoder?.resume()
    }

    public func stop() async throws -> RecordingResult {
        guard !isStopped else {
            throw RecordingError.noFramesCaptured
        }
        isStopped = true
        defer { clearCallbacks() }

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

        let summary: (duration: TimeInterval, frameCount: Int)
        if let videoWriter {
            self.videoWriter = nil
            summary = try await videoWriter.finish()
        } else if let gifEncoder {
            self.gifEncoder = nil
            summary = try await gifEncoder.finish()
        } else {
            throw RecordingError.noFramesCaptured
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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
        guard !isStopped else { return }
        isStopped = true
        clearCallbacks()
        let activeStream = stream
        let activeHandler = streamOutput
        let activeSettings = effectiveSettings
        stream = nil
        streamOutput = nil
        videoWriter?.cancel()
        videoWriter = nil
        gifEncoder?.cancel()
        gifEncoder = nil
        // If `startStream` is currently awaiting `startCapture()`, it checks `isStopped`
        // immediately on return and performs the stop without racing `startCapture()`.
        if let activeStream, !isStartingCapture {
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
        onNotice = nil
        onLimitReached = nil
    }

    // MARK: - Private Setup Helpers

    private func prepareOutputPipeline(for runSettings: RecordingSettings) throws {
        if runSettings.format == .gif {
            gifEncoder = try GifRecordingEncoder(
                outputURL: outputURL,
                pixelSize: targetPixelSize,
                fps: runSettings.effectiveFPS,
                onLimitReached: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isStopped else { return }
                        self.onLimitReached?()
                    }
                }
            )
            videoWriter = nil
        } else {
            let writer = try VideoRecordingWriter(
                outputURL: outputURL,
                format: runSettings.format,
                pixelSize: targetPixelSize,
                fps: runSettings.effectiveFPS,
                capturesSystemAudio: runSettings.effectiveSystemAudio,
                capturesMicrophone: runSettings.effectiveMicrophone,
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isStopped else { return }
                        Self.logger.error("Video writer failed mid-recording: \(error.localizedDescription)")
                        self.onUnexpectedStop?(error)
                    }
                }
            )
            try writer.start()
            videoWriter = writer
            gifEncoder = nil
        }
    }

    private func startStream(filter: SCContentFilter, runSettings: RecordingSettings) async throws {
        guard !isStopped else { throw CancellationError() }

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
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(min(max(1, runSettings.effectiveFPS), 240)))
        config.queueDepth = 5
        config.capturesAudio = runSettings.effectiveSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AudioSampleNormalizer.sampleRate)
        config.channelCount = Int(AudioSampleNormalizer.channelCount)
        config.captureMicrophone = runSettings.effectiveMicrophone

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

        if isStopped {
            try? await candidateStream.stopCapture()
            Self.removeOutputs(handler, from: candidateStream, settings: runSettings)
            throw CancellationError()
        }

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
