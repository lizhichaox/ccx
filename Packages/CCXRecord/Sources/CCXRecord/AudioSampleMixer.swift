import AVFoundation
import CoreMedia
import Darwin
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

    private final class InputProviderState: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        var consumed = false
    }

    public let targetFormat: AVAudioFormat

    private var cachedSourceFormat: AVAudioFormat?
    private var cachedConverter: AVAudioConverter?
    private var cachedInputBuffer: AVAudioPCMBuffer?
    private var cachedOutputBuffer: AVAudioPCMBuffer?
    private let inputProviderState = InputProviderState()
    private var scratchOutput: [Float] = []

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
        if scratchOutput.capacity > 65_536 {
            scratchOutput.removeAll(keepingCapacity: false)
        }
    }

    public func normalize(_ sampleBuffer: CMSampleBuffer) -> [Float] {
        let slice = normalizeSlice(sampleBuffer)
        return slice.isEmpty ? [] : Array(slice)
    }

    public func normalize(pcmBuffer inputBuffer: AVAudioPCMBuffer) -> [Float] {
        let slice = normalizeSlice(pcmBuffer: inputBuffer)
        return slice.isEmpty ? [] : Array(slice)
    }

    /// Normalizes `sampleBuffer` into the internal reusable scratch buffer, returning a slice
    /// valid until the next `normalize*` or `reset()` call on this normalizer.
    func normalizeSlice(_ sampleBuffer: CMSampleBuffer) -> ArraySlice<Float> {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM
        else {
            return [][...]
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Self.maxFramesPerBuffer else { return [][...] }

        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        guard Self.isValidPCMFormat(sourceFormat) else { return [][...] }

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
                return [][...]
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
        guard copyStatus == noErr else { return [][...] }

        return normalizeSlice(pcmBuffer: inputBuffer)
    }

    private func ensureScratchCount(_ sampleCount: Int) {
        if scratchOutput.count < sampleCount {
            scratchOutput = [Float](repeating: 0, count: sampleCount)
        }
    }

    func normalizeSlice(pcmBuffer inputBuffer: AVAudioPCMBuffer) -> ArraySlice<Float> {
        let format = inputBuffer.format
        let frames = Int(inputBuffer.frameLength)
        guard frames > 0,
              frames <= Int(inputBuffer.frameCapacity),
              frames <= Self.maxFramesPerBuffer,
              Self.isValidPCMFormat(format)
        else {
            return [][...]
        }

        // Fast paths avoid AVAudioConverter allocation when sample rate and Float32 already match.
        if format.sampleRate == Self.sampleRate, format.commonFormat == .pcmFormatFloat32 {
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputBuffer.audioBufferList))
            let sampleCount = frames * 2
            if format.channelCount == 2, format.isInterleaved {
                guard let buf = list.first, let mData = buf.mData else { return [][...] }
                let requiredBytes = sampleCount * MemoryLayout<Float>.stride
                guard Int(buf.mDataByteSize) >= requiredBytes else { return [][...] }
                ensureScratchCount(sampleCount)
                scratchOutput.withUnsafeMutableBytes { dst in
                    if let base = dst.baseAddress {
                        memcpy(base, mData, requiredBytes)
                    }
                }
                return scratchOutput[0..<sampleCount]
            } else if format.channelCount == 2, !format.isInterleaved {
                let requiredPerChannel = frames * MemoryLayout<Float>.stride
                guard list.count >= 2,
                      Int(list[0].mDataByteSize) >= requiredPerChannel,
                      Int(list[1].mDataByteSize) >= requiredPerChannel,
                      let channels = inputBuffer.floatChannelData
                else {
                    return [][...]
                }
                let left = channels[0]
                let right = channels[1]
                ensureScratchCount(sampleCount)
                scratchOutput.withUnsafeMutableBufferPointer { buffer in
                    for idx in 0..<frames {
                        buffer[idx * 2] = left[idx]
                        buffer[idx * 2 + 1] = right[idx]
                    }
                }
                return scratchOutput[0..<sampleCount]
            } else if format.channelCount == 1 {
                let requiredPerChannel = frames * MemoryLayout<Float>.stride
                guard let first = list.first,
                      Int(first.mDataByteSize) >= requiredPerChannel,
                      let channels = inputBuffer.floatChannelData
                else {
                    return [][...]
                }
                let mono = channels[0]
                ensureScratchCount(sampleCount)
                scratchOutput.withUnsafeMutableBufferPointer { buffer in
                    for idx in 0..<frames {
                        let sample = mono[idx]
                        buffer[idx * 2] = sample
                        buffer[idx * 2 + 1] = sample
                    }
                }
                return scratchOutput[0..<sampleCount]
            }
        }

        guard let converter = resolveConverter(for: format) else { return [][...] }
        let ratio = Self.sampleRate / format.sampleRate
        let scaledFrames = ceil(Double(frames) * ratio)
        guard scaledFrames.isFinite, scaledFrames >= 1 else { return [][...] }
        let maxConvertedFrames = Double(Self.maxFramesPerBuffer) * 6.0
        guard scaledFrames <= maxConvertedFrames else { return [][...] }
        let capacity = AVAudioFrameCount(Int(scaledFrames) + 32)

        let outputBuffer: AVAudioPCMBuffer
        if let cached = cachedOutputBuffer, cached.frameCapacity >= capacity {
            cached.frameLength = 0
            outputBuffer = cached
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return [][...]
            }
            cachedOutputBuffer = created
            outputBuffer = created
        }

        let state = inputProviderState
        state.buffer = inputBuffer
        state.consumed = false
        defer { state.buffer = nil }

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
            return [][...]
        }

        let outFrames = Int(outputBuffer.frameLength)
        guard outFrames > 0, outFrames <= Int(outputBuffer.frameCapacity) else { return [][...] }
        let outList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: outputBuffer.audioBufferList))
        guard let outBuf = outList.first, let mData = outBuf.mData else { return [][...] }
        let sampleCount = outFrames * 2
        let requiredBytes = sampleCount * MemoryLayout<Float>.stride
        guard Int(outBuf.mDataByteSize) >= requiredBytes else { return [][...] }
        ensureScratchCount(sampleCount)
        scratchOutput.withUnsafeMutableBytes { dst in
            if let base = dst.baseAddress {
                memcpy(base, mData, requiredBytes)
            }
        }
        return scratchOutput[0..<sampleCount]
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
    private var outputScratch: [Float] = []

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
        if outputScratch.capacity > 65_536 {
            outputScratch.removeAll(keepingCapacity: false)
        }
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

    @inline(__always)
    private static func softClip(_ raw: Float) -> Float {
        let value = raw.isFinite ? raw : 0
        let absVal = abs(value)
        if absVal <= softClipKnee {
            return value
        }
        let excess = (absVal - softClipKnee) / softClipHeadroom
        let shaped = softClipKnee + softClipHeadroom * Darwin.tanhf(excess)
        return value >= 0 ? shaped : -shaped
    }

    /// Mixes two Float32 buffers sample-wise with C1-continuous tanh soft clipping above 0.85
    /// and non-finite sample sanitization.
    public static func mix(system: [Float], microphone: [Float]) -> [Float] {
        mix(system: system[...], microphone: microphone[...])
    }

    private static func mix(system: ArraySlice<Float>, microphone: ArraySlice<Float>) -> [Float] {
        let count = max(system.count, microphone.count)
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { output, initializedCount in
            mix(system: system, microphone: microphone, into: output)
            initializedCount = count
        }
    }

    private static func mix(
        system: ArraySlice<Float>,
        microphone: ArraySlice<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        let sysCount = system.count
        let micCount = microphone.count
        let commonCount = min(sysCount, micCount)
        let count = max(sysCount, micCount)
        guard count > 0, output.count >= count else { return }

        system.withUnsafeBufferPointer { sysBuf in
            microphone.withUnsafeBufferPointer { micBuf in
                if let sysBase = sysBuf.baseAddress, let micBase = micBuf.baseAddress {
                    for idx in 0..<commonCount {
                        let rawS = sysBase[idx]
                        let rawM = micBase[idx]
                        let s = rawS.isFinite ? rawS : 0
                        let m = rawM.isFinite ? rawM : 0
                        output[idx] = softClip(s + m)
                    }
                }
                if sysCount > commonCount, let sysBase = sysBuf.baseAddress {
                    for idx in commonCount..<sysCount {
                        output[idx] = softClip(sysBase[idx])
                    }
                } else if micCount > commonCount, let micBase = micBuf.baseAddress {
                    for idx in commonCount..<micCount {
                        output[idx] = softClip(micBase[idx])
                    }
                }
            }
        }
    }

    /// Sanitizes non-finite samples and applies soft-clipping into `output` (single-source safety).
    static func sanitize(_ samples: ArraySlice<Float>, into scratch: inout [Float]) -> ArraySlice<Float> {
        let usableCount = samples.count - (samples.count % 2)
        guard usableCount > 0 else { return [][...] }
        if scratch.count < usableCount {
            scratch = [Float](repeating: 0, count: usableCount)
        }
        let aligned = samples.prefix(usableCount)
        scratch.withUnsafeMutableBufferPointer { dst in
            aligned.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress else { return }
                for idx in 0..<usableCount {
                    let raw = srcBase[idx]
                    dst[idx] = raw.isFinite ? raw : 0
                }
            }
        }
        return scratch[0..<usableCount]
    }

    private mutating func mixIntoScratch(system: ArraySlice<Float>, microphone: ArraySlice<Float>) -> ArraySlice<Float> {
        let count = max(system.count, microphone.count)
        guard count > 0 else { return [][...] }
        if outputScratch.count < count {
            outputScratch = [Float](repeating: 0, count: count)
        }
        outputScratch.withUnsafeMutableBufferPointer { dst in
            Self.mix(system: system, microphone: microphone, into: dst)
        }
        return outputScratch[0..<count]
    }

    public mutating func pushSystem(_ samples: [Float], pts: CMTime) -> [(samples: [Float], pts: CMTime)] {
        guard let chunk = pushSystemSlice(samples[...], pts: pts) else { return [] }
        return [(Array(chunk.samples), chunk.pts)]
    }

    mutating func pushSystemSlice(_ samples: ArraySlice<Float>, pts: CMTime) -> (samples: ArraySlice<Float>, pts: CMTime)? {
        guard pts.isNumeric else { return nil }
        let usableSystemCount = samples.count - (samples.count % 2)
        guard usableSystemCount > 0 else { return nil }
        let alignedSystem = samples.prefix(usableSystemCount)

        // Discard stale queued microphone samples when mic timestamps lag far behind system audio.
        if unreadMicCount > 0, let headPTS = micQueuePTS, headPTS.isNumeric {
            let lag = CMTimeSubtract(pts, headPTS).seconds
            if lag.isFinite, lag > Self.maxMicLagSeconds {
                let unreadFrames = Double(unreadMicCount / 2)
                let rawStaleFrames = (lag * Self.sampleRate).rounded(.down)
                if !rawStaleFrames.isFinite || rawStaleFrames >= unreadFrames {
                    micQueue.removeAll(keepingCapacity: true)
                    micReadOffset = 0
                    micQueuePTS = nil
                } else if rawStaleFrames >= 1 {
                    let staleFloats = min(unreadMicCount, Int(rawStaleFrames) * 2)
                    micReadOffset += staleFloats
                    let advance = CMTime(value: CMTimeValue(staleFloats / 2), timescale: CMTimeScale(Self.sampleRate))
                    micQueuePTS = CMTimeAdd(headPTS, advance)
                    compactMicQueueIfNeeded()
                }
            }
        }

        lastMixPTS = pts
        let frameDuration = CMTime(value: CMTimeValue(usableSystemCount / 2), timescale: CMTimeScale(Self.sampleRate))
        let systemEnd = CMTimeAdd(pts, frameDuration)
        if let prevEnd = lastEmittedEndPTS, prevEnd.isNumeric {
            lastEmittedEndPTS = systemEnd > prevEnd ? systemEnd : prevEnd
        } else {
            lastEmittedEndPTS = systemEnd
        }

        let availableMic = unreadMicCount
        if availableMic == 0 {
            let mixed = mixIntoScratch(system: alignedSystem, microphone: [][...])
            return (mixed, pts)
        }

        let takeCount = min(usableSystemCount, availableMic)
        let alignedCount = takeCount - (takeCount % 2)
        guard alignedCount > 0 else {
            let mixed = mixIntoScratch(system: alignedSystem, microphone: [][...])
            return (mixed, pts)
        }

        let micSlice = micQueue[micReadOffset..<(micReadOffset + alignedCount)]
        let mixed = mixIntoScratch(system: alignedSystem, microphone: micSlice)
        micReadOffset += alignedCount
        compactMicQueueIfNeeded()

        if unreadMicCount == 0 {
            micQueuePTS = nil
        } else if let head = micQueuePTS {
            let advance = CMTime(value: CMTimeValue(alignedCount / 2), timescale: CMTimeScale(Self.sampleRate))
            micQueuePTS = CMTimeAdd(head, advance)
        }

        return (mixed, pts)
    }

    public mutating func pushMicrophone(_ samples: [Float], pts: CMTime) -> [(samples: [Float], pts: CMTime)] {
        guard let chunk = pushMicrophoneSlice(samples[...], pts: pts) else { return [] }
        return [(Array(chunk.samples), chunk.pts)]
    }

    mutating func pushMicrophoneSlice(_ samples: ArraySlice<Float>, pts: CMTime) -> (samples: ArraySlice<Float>, pts: CMTime)? {
        guard pts.isNumeric else { return nil }
        let usableCount = samples.count - (samples.count % 2)
        guard usableCount > 0 else { return nil }

        let maxEvenBuffered = Self.maxBufferedFloats - (Self.maxBufferedFloats % 2)
        if usableCount >= maxEvenBuffered {
            // Bound peak allocation: retain only the newest `maxEvenBuffered` floats from an oversized chunk.
            let skipCount = usableCount - maxEvenBuffered
            let startIdx = samples.index(samples.startIndex, offsetBy: skipCount)
            let endIdx = samples.index(startIdx, offsetBy: maxEvenBuffered)
            micQueue.removeAll(keepingCapacity: true)
            micReadOffset = 0
            micQueue.append(contentsOf: samples[startIdx..<endIdx])
            let advance = CMTime(value: CMTimeValue(skipCount / 2), timescale: CMTimeScale(Self.sampleRate))
            micQueuePTS = CMTimeAdd(pts, advance)
        } else {
            if unreadMicCount == 0 {
                micQueuePTS = pts
            }
            micQueue.append(contentsOf: samples.prefix(usableCount))

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
        }

        let systemStalled: Bool = if let lastMixPTS, lastMixPTS.isNumeric {
            CMTimeSubtract(pts, lastMixPTS).seconds > 0.085
        } else {
            true
        }
        let shouldFlushStalledMic = unreadMicCount > Self.micStallThresholdFloats && systemStalled
        guard shouldFlushStalledMic else { return nil }

        return drainMicQueueSlice(fallbackPTS: pts)
    }

    /// Flushes any remaining buffered microphone tail (for clean end-of-stream finalization).
    public mutating func flush() -> (samples: [Float], pts: CMTime)? {
        guard let tail = flushSlice() else { return nil }
        return (Array(tail.samples), tail.pts)
    }

    mutating func flushSlice() -> (samples: ArraySlice<Float>, pts: CMTime)? {
        guard let fallbackPTS = micQueuePTS ?? lastEmittedEndPTS ?? lastMixPTS else {
            micQueue.removeAll(keepingCapacity: true)
            micReadOffset = 0
            micQueuePTS = nil
            return nil
        }
        return drainMicQueueSlice(fallbackPTS: fallbackPTS)
    }

    private mutating func drainMicQueueSlice(fallbackPTS: CMTime) -> (samples: ArraySlice<Float>, pts: CMTime)? {
        let usableCount = unreadMicCount - (unreadMicCount % 2)
        guard usableCount > 0 else {
            micQueue.removeAll(keepingCapacity: true)
            micReadOffset = 0
            micQueuePTS = nil
            return nil
        }
        let slice = micQueue[micReadOffset..<(micReadOffset + usableCount)]
        let sanitized = mixIntoScratch(system: [][...], microphone: slice)
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
        makePCMSampleBuffer(interleavedStereoFloat32: samples[...], pts: pts, sampleRate: sampleRate)
    }

    static func makePCMSampleBuffer(
        interleavedStereoFloat32 samples: ArraySlice<Float>,
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
