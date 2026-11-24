import AVFoundation
import CoreMedia
import Foundation

/// Identifies the originating audio stream in `ScreenRecordingEngine`.
public enum RecordingAudioSource: Sendable {
    case system
    case microphone
}

/// Converts arbitrary `CMSampleBuffer` PCM formats (non-interleaved stereo system audio,
/// mono 44.1/48kHz native microphone audio, etc.) into interleaved 48 kHz stereo Float32 samples.
public final class AudioSampleNormalizer {
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2
    public static let maxFramesPerBuffer = 480_000 // 10 seconds at 48 kHz
    private static let minSupportedSampleRate: Double = 8_000
    private static let maxSupportedSampleRate: Double = 384_000
    private static let maxSupportedChannels: AVAudioChannelCount = 64

    public let targetFormat: AVAudioFormat

    private var cachedSourceFormat: AVAudioFormat?
    private var cachedConverter: AVAudioConverter?
    private var cachedInputBuffer: AVAudioPCMBuffer?
    private var cachedOutputBuffer: AVAudioPCMBuffer?

    public init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: true
        ) else {
            preconditionFailure("Failed to construct standard 48 kHz stereo Float32 AVAudioFormat.")
        }
        self.targetFormat = format
    }

    /// Resets cached resampler filter state across discontinuities such as pause/resume.
    public func reset() {
        cachedConverter?.reset()
    }

    public func normalize(_ sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM
        else {
            return []
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Self.maxFramesPerBuffer else { return [] }

        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        guard Self.isValidPCMFormat(sourceFormat) else { return [] }

        let requestedFrames = AVAudioFrameCount(frameCount)
        let inputBuffer: AVAudioPCMBuffer
        if let cached = cachedInputBuffer,
           cached.format == sourceFormat,
           cached.frameCapacity >= requestedFrames {
            inputBuffer = cached
        } else {
            guard let created = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: requestedFrames
            ) else {
                return []
            }
            cachedInputBuffer = created
            inputBuffer = created
        }
        inputBuffer.frameLength = requestedFrames

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return [] }

        return normalize(pcmBuffer: inputBuffer)
    }

    public func normalize(pcmBuffer inputBuffer: AVAudioPCMBuffer) -> [Float] {
        let format = inputBuffer.format
        let frames = Int(inputBuffer.frameLength)
        guard frames > 0,
              frames <= Int(inputBuffer.frameCapacity),
              frames <= Self.maxFramesPerBuffer,
              Self.isValidPCMFormat(format)
        else {
            return []
        }

        // Fast paths avoid AVAudioConverter allocation when sample rate and Float32 already match.
        if format.sampleRate == Self.sampleRate, format.commonFormat == .pcmFormatFloat32 {
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBuffer.audioBufferList))
            if format.channelCount == 2, format.isInterleaved {
                guard let buf = list.first, let mData = buf.mData else { return [] }
                let requiredBytes = frames * 2 * MemoryLayout<Float>.stride
                guard Int(buf.mDataByteSize) >= requiredBytes else { return [] }
                let ptr = mData.assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: ptr, count: frames * 2))
            } else if format.channelCount == 2, !format.isInterleaved {
                let requiredPerChannel = frames * MemoryLayout<Float>.stride
                guard list.count >= 2,
                      Int(list[0].mDataByteSize) >= requiredPerChannel,
                      Int(list[1].mDataByteSize) >= requiredPerChannel,
                      let channels = inputBuffer.floatChannelData
                else {
                    return []
                }
                let left = channels[0]
                let right = channels[1]
                return [Float](unsafeUninitializedCapacity: frames * 2) { buffer, initializedCount in
                    for idx in 0..<frames {
                        buffer[idx * 2] = left[idx]
                        buffer[idx * 2 + 1] = right[idx]
                    }
                    initializedCount = frames * 2
                }
            } else if format.channelCount == 1 {
                let requiredPerChannel = frames * MemoryLayout<Float>.stride
                guard let first = list.first,
                      Int(first.mDataByteSize) >= requiredPerChannel,
                      let channels = inputBuffer.floatChannelData
                else {
                    return []
                }
                let mono = channels[0]
                return [Float](unsafeUninitializedCapacity: frames * 2) { buffer, initializedCount in
                    for idx in 0..<frames {
                        let sample = mono[idx]
                        buffer[idx * 2] = sample
                        buffer[idx * 2 + 1] = sample
                    }
                    initializedCount = frames * 2
                }
            }
        }

        guard let converter = resolveConverter(for: format) else { return [] }
        let ratio = Self.sampleRate / format.sampleRate
        let scaledFrames = ceil(Double(frames) * ratio)
        guard scaledFrames.isFinite, scaledFrames >= 1 else { return [] }
        let maxConvertedFrames = Double(Self.maxFramesPerBuffer) * 6.0
        guard scaledFrames <= maxConvertedFrames else { return [] }
        let capacity = AVAudioFrameCount(Int(scaledFrames) + 32)

        let outputBuffer: AVAudioPCMBuffer
        if let cached = cachedOutputBuffer, cached.frameCapacity >= capacity {
            cached.frameLength = 0
            outputBuffer = cached
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return []
            }
            cachedOutputBuffer = created
            outputBuffer = created
        }

        final class InputProviderState: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
            var consumed = false
            init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let state = InputProviderState(buffer: inputBuffer)
        var convertError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if state.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        guard status == .haveData || status == .inputRanDry || status == .endOfStream,
              convertError == nil
        else {
            return []
        }

        let outFrames = Int(outputBuffer.frameLength)
        guard outFrames > 0, outFrames <= Int(outputBuffer.frameCapacity) else { return [] }
        let outList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: outputBuffer.audioBufferList))
        guard let outBuf = outList.first, let mData = outBuf.mData else { return [] }
        let requiredBytes = outFrames * 2 * MemoryLayout<Float>.stride
        guard Int(outBuf.mDataByteSize) >= requiredBytes else { return [] }
        let ptr = mData.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: outFrames * 2))
    }

    private static func isValidPCMFormat(_ format: AVAudioFormat) -> Bool {
        format.commonFormat != .otherFormat &&
            format.channelCount >= 1 &&
            format.channelCount <= Self.maxSupportedChannels &&
            format.sampleRate.isFinite &&
            format.sampleRate >= Self.minSupportedSampleRate &&
            format.sampleRate <= Self.maxSupportedSampleRate
    }

    private func resolveConverter(for sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        guard Self.isValidPCMFormat(sourceFormat) else { return nil }
        if let cachedSourceFormat, cachedSourceFormat == sourceFormat, let cachedConverter {
            return cachedConverter
        }
        let usableSource: AVAudioFormat
        if sourceFormat.channelCount > 2, sourceFormat.channelLayout == nil {
            let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(sourceFormat.channelCount)
            guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
                return nil
            }
            usableSource = AVAudioFormat(
                commonFormat: sourceFormat.commonFormat,
                sampleRate: sourceFormat.sampleRate,
                interleaved: sourceFormat.isInterleaved,
                channelLayout: layout
            )
        } else {
            usableSource = sourceFormat
        }
        guard let converter = AVAudioConverter(from: usableSource, to: targetFormat) else { return nil }
        cachedSourceFormat = sourceFormat
        cachedConverter = converter
        return converter
    }
}

/// Combines system audio and microphone streams into a single stereo Float32 interleaved track
/// with C1-continuous soft-clipping headroom protection and stall fallback for silent system-audio intervals.
public struct DualAudioMixer: Sendable {
    public static let sampleRate: Double = 48_000
    public static let maxBufferedFloats = 96_000 // 1 second of 48kHz stereo
    private static let micStallThresholdFloats = 8_192 // 4096 stereo frames (~85ms)
    private static let maxMicLagSeconds: TimeInterval = 0.5
    private static let softClipKnee: Float = 0.85
    private static let softClipHeadroom: Float = 0.15

    private static let defaultFormatDescriptionBox = UncheckedSendableBox(
        createStereoFloat32FormatDescription(sampleRate: DualAudioMixer.sampleRate)
    )

    private var micQueue: [Float] = []
    private var micReadOffset: Int = 0
    private var micQueuePTS: CMTime?
    private var lastMixPTS: CMTime?
    private var lastEmittedEndPTS: CMTime?

    private var unreadMicCount: Int {
        micQueue.count - micReadOffset
    }

    public init() {}

    public mutating func reset() {
        micQueue.removeAll()
        micReadOffset = 0
        micQueuePTS = nil
        lastMixPTS = nil
        lastEmittedEndPTS = nil
    }

    private mutating func compactMicQueueIfNeeded() {
        if micReadOffset >= micQueue.count {
            micQueue.removeAll(keepingCapacity: true)
            micReadOffset = 0
        } else if micReadOffset >= 4_096 && micReadOffset * 2 >= micQueue.count {
            micQueue.removeFirst(micReadOffset)
            micReadOffset = 0
        }
    }

    /// Mixes two Float32 buffers sample-wise with C1-continuous tanh soft clipping above 0.85
    /// and non-finite sample sanitization.
    public static func mix(system: [Float], microphone: [Float]) -> [Float] {
        mix(system: system, microphone: microphone[...])
    }

    private static func mix(system: [Float], microphone: ArraySlice<Float>) -> [Float] {
        let micCount = microphone.count
        let micStart = microphone.startIndex
        let count = max(system.count, micCount)
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { output, initializedCount in
            let knee = Self.softClipKnee
            let headroom = Self.softClipHeadroom
            for idx in 0..<count {
                let rawS = idx < system.count ? system[idx] : 0
                let rawM = idx < micCount ? microphone[micStart + idx] : 0
                let s = rawS.isFinite ? rawS : 0
                let m = rawM.isFinite ? rawM : 0
                let sum = s + m
                let absSum = abs(sum)
                if absSum <= knee {
                    output[idx] = sum
                } else {
                    let excess = (absSum - knee) / headroom
                    let shaped = knee + headroom * Float(tanh(Double(excess)))
                    output[idx] = sum >= 0 ? shaped : -shaped
                }
            }
            initializedCount = count
        }
    }

    public mutating func pushSystem(_ samples: [Float], pts: CMTime) -> [(samples: [Float], pts: CMTime)] {
        guard pts.isNumeric else { return [] }
        let usableSystemCount = samples.count - (samples.count % 2)
        guard usableSystemCount > 0 else { return [] }
        let alignedSystem = usableSystemCount == samples.count ? samples : Array(samples.prefix(usableSystemCount))

        // Discard stale queued microphone samples when mic timestamps lag far behind system audio.
        if unreadMicCount > 0, let headPTS = micQueuePTS, headPTS.isNumeric {
            let lag = CMTimeSubtract(pts, headPTS).seconds
            if lag.isFinite, lag > Self.maxMicLagSeconds {
                let staleFrames = Int((lag * Self.sampleRate).rounded(.down))
                let staleFloats = min(unreadMicCount, max(0, staleFrames) * 2)
                if staleFloats >= unreadMicCount {
                    micQueue.removeAll(keepingCapacity: true)
                    micReadOffset = 0
                    micQueuePTS = nil
                } else if staleFloats > 0 {
                    micReadOffset += staleFloats
                    let advance = CMTime(value: CMTimeValue(staleFloats / 2), timescale: CMTimeScale(Self.sampleRate))
                    micQueuePTS = CMTimeAdd(headPTS, advance)
                    compactMicQueueIfNeeded()
                }
            }
        }

        lastMixPTS = pts
        let frameDuration = CMTime(value: CMTimeValue(alignedSystem.count / 2), timescale: CMTimeScale(Self.sampleRate))
        let systemEnd = CMTimeAdd(pts, frameDuration)
        if let prevEnd = lastEmittedEndPTS, prevEnd.isNumeric {
            lastEmittedEndPTS = systemEnd > prevEnd ? systemEnd : prevEnd
        } else {
            lastEmittedEndPTS = systemEnd
        }

        let availableMic = unreadMicCount
        if availableMic == 0 {
            return [(Self.mix(system: alignedSystem, microphone: [][...]), pts)]
        }

        let takeCount = min(alignedSystem.count, availableMic)
        let alignedCount = takeCount - (takeCount % 2)
        guard alignedCount > 0 else {
            return [(Self.mix(system: alignedSystem, microphone: [][...]), pts)]
        }

        let micSlice = micQueue[micReadOffset..<(micReadOffset + alignedCount)]
        let mixed = Self.mix(system: alignedSystem, microphone: micSlice)
        micReadOffset += alignedCount
        compactMicQueueIfNeeded()

        if unreadMicCount == 0 {
            micQueuePTS = nil
        } else if let head = micQueuePTS {
            let advance = CMTime(value: CMTimeValue(alignedCount / 2), timescale: CMTimeScale(Self.sampleRate))
            micQueuePTS = CMTimeAdd(head, advance)
        }

        return [(mixed, pts)]
    }

    public mutating func pushMicrophone(_ samples: [Float], pts: CMTime) -> [(samples: [Float], pts: CMTime)] {
        guard pts.isNumeric else { return [] }
        let usableCount = samples.count - (samples.count % 2)
        guard usableCount > 0 else { return [] }

        if unreadMicCount == 0 {
            micQueuePTS = pts
        }
        if usableCount == samples.count {
            micQueue.append(contentsOf: samples)
        } else {
            micQueue.append(contentsOf: samples.prefix(usableCount))
        }

        if unreadMicCount > Self.maxBufferedFloats {
            let rawDrop = unreadMicCount - Self.maxBufferedFloats
            let drop = rawDrop + (rawDrop % 2)
            let actualDrop = min(drop, unreadMicCount)
            micReadOffset += actualDrop
            if unreadMicCount == 0 {
                micQueuePTS = nil
            } else if let head = micQueuePTS {
                let advance = CMTime(value: CMTimeValue(actualDrop / 2), timescale: CMTimeScale(Self.sampleRate))
                micQueuePTS = CMTimeAdd(head, advance)
            }
            compactMicQueueIfNeeded()
        }

        let systemStalled: Bool = if let lastMixPTS, lastMixPTS.isNumeric {
            CMTimeSubtract(pts, lastMixPTS).seconds > 0.085
        } else {
            true
        }
        let shouldFlushStalledMic = unreadMicCount > Self.micStallThresholdFloats && systemStalled
        guard shouldFlushStalledMic else { return [] }

        guard let flushed = drainMicQueue(fallbackPTS: pts) else { return [] }
        return [flushed]
    }

    /// Flushes any remaining buffered microphone tail (for clean end-of-stream finalization).
    public mutating func flush() -> (samples: [Float], pts: CMTime)? {
        guard let fallbackPTS = micQueuePTS ?? lastEmittedEndPTS ?? lastMixPTS else {
            micQueue.removeAll(keepingCapacity: true)
            micReadOffset = 0
            micQueuePTS = nil
            return nil
        }
        return drainMicQueue(fallbackPTS: fallbackPTS)
    }

    private mutating func drainMicQueue(fallbackPTS: CMTime) -> (samples: [Float], pts: CMTime)? {
        let usableCount = unreadMicCount - (unreadMicCount % 2)
        guard usableCount > 0 else {
            micQueue.removeAll(keepingCapacity: true)
            micReadOffset = 0
            micQueuePTS = nil
            return nil
        }
        let slice = micQueue[micReadOffset..<(micReadOffset + usableCount)]
        let sanitized = Self.mix(system: [], microphone: slice)
        var flushPTS = micQueuePTS ?? fallbackPTS
        if let minNextPTS = lastEmittedEndPTS, minNextPTS.isNumeric, flushPTS < minNextPTS {
            flushPTS = minNextPTS
        }
        micQueue.removeAll(keepingCapacity: true)
        micReadOffset = 0
        micQueuePTS = nil

        guard flushPTS.isNumeric else { return nil }
        let duration = CMTime(value: CMTimeValue(sanitized.count / 2), timescale: CMTimeScale(Self.sampleRate))
        lastEmittedEndPTS = CMTimeAdd(flushPTS, duration)
        return (sanitized, flushPTS)
    }

    private static func createStereoFloat32FormatDescription(sampleRate: Double) -> CMAudioFormatDescription? {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000 else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr else { return nil }
        return formatDesc
    }

    /// Packages interleaved 48 kHz stereo Float32 samples into an owned CoreMedia `CMSampleBuffer`.
    public static func makePCMSampleBuffer(
        interleavedStereoFloat32 samples: [Float],
        pts: CMTime,
        sampleRate: Double = DualAudioMixer.sampleRate
    ) -> CMSampleBuffer? {
        guard pts.isNumeric, sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000 else { return nil }
        let frameCount = samples.count / 2
        guard frameCount > 0, frameCount <= AudioSampleNormalizer.maxFramesPerBuffer else { return nil }

        let resolvedDesc: CMAudioFormatDescription? = if sampleRate == Self.sampleRate {
            Self.defaultFormatDescriptionBox.value ?? createStereoFloat32FormatDescription(sampleRate: sampleRate)
        } else {
            createStereoFloat32FormatDescription(sampleRate: sampleRate)
        }
        guard let formatDesc = resolvedDesc else { return nil }

        let byteCount = frameCount * 8
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress, raw.count >= byteCount else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }
        return sampleBuffer
    }
}
