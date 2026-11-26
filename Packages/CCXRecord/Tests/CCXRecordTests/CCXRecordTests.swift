import AppKit
import AVFoundation
import CCXCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import os
import QuartzCore
import ScreenCaptureKit
import Testing
import UniformTypeIdentifiers
import XCTest
@testable import CCXRecord

@Suite("CCXRecord")
struct CCXRecordTests {
    @Test @MainActor func modelsFormatsPixelSizingAndSettingsStoreRoundTrip() throws {
        #expect(RecordingFormat.mp4.supportsAudio)
        #expect(RecordingFormat.mov.supportsAudio)
        #expect(!RecordingFormat.gif.supportsAudio)
        #expect(RecordingFormat.mp4.avFileType == .mp4)
        #expect(RecordingFormat.mov.avFileType == .mov)
        #expect(RecordingFormat.gif.avFileType == nil)
        #expect(RecordingFormat.mp4.utType == .mpeg4Movie)
        #expect(RecordingFormat.mov.utType == .quickTimeMovie)
        #expect(RecordingFormat.gif.utType == .gif)
        #expect(RecordingFormat.mp4.targetFPS == 60)
        #expect(RecordingFormat.gif.targetFPS == 15)
        #expect(RecordingFormat.mp4.availableFPSOptions == [24, 30, 60])
        #expect(RecordingFormat.mov.availableFPSOptions == [24, 30, 60])
        #expect(RecordingFormat.gif.availableFPSOptions == [10, 15, 20, 30])

        // Odd fractional region snaps cleanly to even dimensions and caps GIF at 1280px.
        let region = RecordingRegion(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            localRect: CGRect(x: 100.4, y: 80.2, width: 1001.3, height: 501.7),
            screenRect: CGRect(x: 100.4, y: 80.2, width: 1001.3, height: 501.7),
            scale: 2
        )
        let videoSize = region.videoPixelSize
        #expect(Int(videoSize.width) >= 2 && Int(videoSize.width).isMultiple(of: 2))
        #expect(Int(videoSize.height) >= 2 && Int(videoSize.height).isMultiple(of: 2))

        let gifSize = region.gifPixelSize()
        #expect(max(gifSize.width, gifSize.height) <= 1280)
        #expect(Int(gifSize.width).isMultiple(of: 2) && Int(gifSize.height).isMultiple(of: 2))

        let sourceRect = region.sourceRectInDisplayPoints
        #expect(abs(sourceRect.minX - 100.4) < 0.01)
        #expect(abs(sourceRect.minY - (982 - 581.9)) < 0.01)

        // GIF disables effective audio regardless of stored audio preferences.
        var settings = RecordingSettings(format: .gif, capturesSystemAudio: true, capturesMicrophone: true, showsCursor: false)
        #expect(!settings.effectiveSystemAudio)
        #expect(!settings.effectiveMicrophone)
        #expect(!settings.hasAudio)
        #expect(settings.effectiveFPS == 15)
        settings.setFPS(20)
        settings.setFPS(60) // 60 fps is unsupported for GIF and ignored.
        #expect(settings.gifFPS == 20 && settings.effectiveFPS == 20)

        settings.format = .mp4
        #expect(settings.effectiveSystemAudio)
        #expect(settings.effectiveMicrophone)
        #expect(settings.hasAudio)
        #expect(settings.effectiveFPS == 60)
        settings.setFPS(24)
        #expect(settings.videoFPS == 24 && settings.effectiveFPS == 24)

        // Settings store persists across instances using an isolated suite.
        let suiteName = "CCXRecordTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = RecordingSettingsStore(defaults: defaults)
        let saved = RecordingSettings(
            format: .mov,
            videoFPS: 30,
            gifFPS: 20,
            capturesSystemAudio: false,
            capturesMicrophone: true,
            showsCursor: false
        )
        store1.save(saved)
        let store2 = RecordingSettingsStore(defaults: defaults)
        let loaded = store2.load()
        #expect(loaded == saved)

        // Legacy persisted JSON without `videoFPS`/`gifFPS` decodes safely with defaults.
        let legacyJSON = Data(#"{"format":"mov","capturesSystemAudio":false,"capturesMicrophone":true,"showsCursor":false}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(RecordingSettings.self, from: legacyJSON)
        #expect(legacyDecoded.format == .mov)
        #expect(legacyDecoded.videoFPS == 60)
        #expect(legacyDecoded.gifFPS == 15)
        #expect(!legacyDecoded.capturesSystemAudio && legacyDecoded.capturesMicrophone && !legacyDecoded.showsCursor)
    }

    @Test func timelineRebasesStartDropsPreVideoAudioAndShiftsMultiplePauses() {
        var timeline = RecordingTimeline()

        // Audio arriving before the first video frame is dropped.
        #expect(timeline.acceptAudioPTS(CMTime(seconds: 99.5, preferredTimescale: 1000)) == nil)
        #expect(timeline.sessionStartPTS == nil)

        // First video frame rebases output PTS to 0.
        let v0 = timeline.acceptVideoPTS(CMTime(seconds: 100.0, preferredTimescale: 1000))
        #expect(v0 == .zero)
        #expect(timeline.sessionStartPTS?.seconds == 100.0)

        // Pre-start audio timestamp arriving late is dropped.
        #expect(timeline.acceptAudioPTS(CMTime(seconds: 99.8, preferredTimescale: 1000)) == nil)
        let a0 = timeline.acceptAudioPTS(CMTime(seconds: 100.5, preferredTimescale: 1000))
        #expect(abs((a0?.seconds ?? -1) - 0.5) < 0.001)

        let v1 = timeline.acceptVideoPTS(CMTime(seconds: 101.0, preferredTimescale: 1000))
        #expect(abs((v1?.seconds ?? -1) - 1.0) < 0.001)

        // First pause: 102.0 .. 105.0 (3 seconds paused).
        timeline.pause()
        #expect(timeline.acceptVideoPTS(CMTime(seconds: 102.0, preferredTimescale: 1000)) == nil)
        #expect(timeline.acceptVideoPTS(CMTime(seconds: 104.0, preferredTimescale: 1000)) == nil)
        #expect(timeline.acceptAudioPTS(CMTime(seconds: 104.5, preferredTimescale: 1000)) == nil)

        timeline.resume()
        let v2 = timeline.acceptVideoPTS(CMTime(seconds: 105.0, preferredTimescale: 1000))
        #expect(abs((v2?.seconds ?? -1) - 2.0) < 0.001)

        // Non-monotonic timestamps are dropped cleanly.
        #expect(timeline.acceptVideoPTS(CMTime(seconds: 104.9, preferredTimescale: 1000)) == nil)
        #expect(timeline.acceptAudioPTS(CMTime(seconds: 100.4, preferredTimescale: 1000)) == nil)

        // Second pause: 106.0 .. 108.0 (+2 seconds paused => total 5s removed).
        timeline.pause()
        #expect(timeline.acceptVideoPTS(CMTime(seconds: 106.0, preferredTimescale: 1000)) == nil)
        timeline.resume()
        let v3 = timeline.acceptVideoPTS(CMTime(seconds: 108.0, preferredTimescale: 1000))
        #expect(abs((v3?.seconds ?? -1) - 3.0) < 0.001)
        let v4 = timeline.acceptVideoPTS(CMTime(seconds: 108.5, preferredTimescale: 1000))
        #expect(abs((v4?.seconds ?? -1) - 3.5) < 0.001)
        #expect(abs(timeline.recordedDurationSeconds - 3.5) < 0.001)
    }

    @Test func dualAudioMixerNormalizesMixesSoftClipsAndFlushesStalledMic() throws {
        // Mono 48kHz Float32 normalizes by duplicating into stereo L/R.
        let normalizer = AudioSampleNormalizer()
        let monoFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let monoPCM = try #require(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 4))
        monoPCM.frameLength = 4
        if let ch0 = monoPCM.floatChannelData?[0] {
            ch0[0] = 0.25; ch0[1] = -0.5; ch0[2] = 0.75; ch0[3] = 0.1
        }
        let stereo = normalizer.normalize(pcmBuffer: monoPCM)
        #expect(stereo.count == 8)
        #expect(stereo[0] == 0.25 && stereo[1] == 0.25)
        #expect(stereo[2] == -0.5 && stereo[3] == -0.5)

        // Soft clipping keeps mixed sums within [-1, 1] without harsh digital wrap.
        let mixed = DualAudioMixer.mix(system: [0.9, -0.9, 0.2], microphone: [0.9, -0.9, 0.3])
        #expect(mixed.count == 3)
        #expect(mixed[0] > 0.85 && mixed[0] <= 1.0)
        #expect(mixed[1] < -0.85 && mixed[1] >= -1.0)
        #expect(abs(mixed[2] - 0.5) < 0.0001)

        // Stateful mixer blends queued mic audio with system audio and flushes stalled mic if system audio is quiet.
        var mixer = DualAudioMixer()
        let t0 = CMTime(value: 0, timescale: 48_000)
        #expect(mixer.pushMicrophone([Float](repeating: 0.2, count: 1000), pts: t0).isEmpty)
        let blended = mixer.pushSystem([Float](repeating: 0.3, count: 1000), pts: t0)
        #expect(blended.count == 1)
        #expect(abs((blended.first?.samples.first ?? 0) - 0.5) < 0.001)

        // Pushing > 4096 mic frames without system audio after > 85ms triggers fallback flush.
        let later = CMTime(seconds: 0.25, preferredTimescale: 48_000)
        let flushed = mixer.pushMicrophone([Float](repeating: 0.15, count: 9000), pts: later)
        #expect(flushed.count == 1)
        #expect(flushed.first?.samples.count == 9000)

        // CoreMedia buffer packaging caches the default 48kHz format description and preserves sample count & timing.
        let pcmSample = try #require(DualAudioMixer.makePCMSampleBuffer(
            interleavedStereoFloat32: [Float](repeating: 0.1, count: 1024),
            pts: CMTime(value: 4800, timescale: 48_000)
        ))
        #expect(CMSampleBufferGetNumSamples(pcmSample) == 512)

        let pcmSample2 = try #require(DualAudioMixer.makePCMSampleBuffer(
            interleavedStereoFloat32: [Float](repeating: 0.2, count: 1024),
            pts: CMTime(value: 5312, timescale: 48_000)
        ))
        let desc1 = try #require(CMSampleBufferGetFormatDescription(pcmSample))
        let desc2 = try #require(CMSampleBufferGetFormatDescription(pcmSample2))
        #expect(CFEqual(desc1, desc2))

        let pcm44k = try #require(DualAudioMixer.makePCMSampleBuffer(
            interleavedStereoFloat32: [Float](repeating: 0.1, count: 512),
            pts: CMTime(value: 0, timescale: 44_100),
            sampleRate: 44_100
        ))
        let desc44k = try #require(CMSampleBufferGetFormatDescription(pcm44k))
        #expect(!CFEqual(desc1, desc44k))

        // Repeated mic + partial system drains cross the 4096 compaction threshold cleanly, and cap at maxBufferedFloats.
        var streamingMixer = DualAudioMixer()
        for chunkIdx in 0..<8 {
            let chunkPTS = CMTime(value: CMTimeValue(chunkIdx * 1000), timescale: 48_000)
            #expect(streamingMixer.pushMicrophone([Float](repeating: 0.2, count: 2000), pts: chunkPTS).isEmpty)
            let mixedChunk = streamingMixer.pushSystem([Float](repeating: 0.1, count: 1600), pts: chunkPTS)
            #expect(mixedChunk.count == 1)
            #expect(mixedChunk[0].samples.count == 1600)
            #expect(abs(mixedChunk[0].samples[0] - 0.3) < 0.001)
        }
        streamingMixer.reset()
        let tStart = CMTime(value: 0, timescale: 48_000)
        _ = streamingMixer.pushSystem([0.0, 0.0], pts: tStart)
        var overflowMic = [Float](repeating: 0.2, count: 2400)
        overflowMic.append(contentsOf: repeatElement(0.4, count: DualAudioMixer.maxBufferedFloats))
        let overflowFlushed = streamingMixer.pushMicrophone(overflowMic, pts: CMTime(seconds: 0.02, preferredTimescale: 48_000))
        #expect(overflowFlushed.isEmpty)
        let drainedAfterOverflow = streamingMixer.pushSystem([Float](repeating: 0.1, count: 1000), pts: CMTime(seconds: 0.03, preferredTimescale: 48_000))
        #expect(drainedAfterOverflow.count == 1)
        #expect(abs((drainedAfterOverflow.first?.samples.first ?? 0) - 0.5) < 0.001)
    }

    @Test func gifEncoderStreamsCoalescesDuplicatesAndProducesValidAnimatedGIF() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = try GifRecordingEncoder(outputURL: url, pixelSize: CGSize(width: 64, height: 48), fps: 15)
        let redImg = try makeCGImage(width: 64, height: 48, red: 0.9, green: 0.1, blue: 0.1)
        let greenImg = try makeCGImage(width: 64, height: 48, red: 0.1, green: 0.9, blue: 0.1)
        let blueImg = try makeCGImage(width: 64, height: 48, red: 0.1, green: 0.2, blue: 0.9)

        // Stream 6 raw frames where middle red frames duplicate -> coalesces to 3 GIF frames.
        encoder.appendImage(redImg, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        encoder.appendImage(redImg, pts: CMTime(seconds: 0.10, preferredTimescale: 1000))
        encoder.appendImage(redImg, pts: CMTime(seconds: 0.20, preferredTimescale: 1000))
        encoder.appendImage(greenImg, pts: CMTime(seconds: 0.30, preferredTimescale: 1000))
        encoder.appendImage(greenImg, pts: CMTime(seconds: 0.45, preferredTimescale: 1000))
        encoder.appendImage(blueImg, pts: CMTime(seconds: 0.60, preferredTimescale: 1000))

        let summary = try await encoder.finish()
        let materializedCount = await encoder.debugMaterializedFrameCount()
        #expect(materializedCount == 3)
        #expect(summary.frameCount == 3)
        #expect(summary.duration >= 0.55)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        #expect(CGImageSourceGetCount(source) == 3)

        let frame0Props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gif0Props = try #require(frame0Props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay0 = (gif0Props[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif0Props[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0
        #expect(delay0 >= 0.25)
    }

    @Test func gifEncoderThrottlesFramesAccordingToConfiguredFPS() async throws {
        let lowFPSURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-10fps-\(UUID().uuidString).gif")
        let highFPSURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-30fps-\(UUID().uuidString).gif")
        defer {
            try? FileManager.default.removeItem(at: lowFPSURL)
            try? FileManager.default.removeItem(at: highFPSURL)
        }

        let red = try makeCGImage(width: 48, height: 32, red: 0.9, green: 0.1, blue: 0.1)
        let green = try makeCGImage(width: 48, height: 32, red: 0.1, green: 0.9, blue: 0.1)
        let blue = try makeCGImage(width: 48, height: 32, red: 0.1, green: 0.2, blue: 0.9)

        let lowEncoder = try GifRecordingEncoder(outputURL: lowFPSURL, pixelSize: CGSize(width: 48, height: 32), fps: 10)
        lowEncoder.appendImage(red, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        lowEncoder.appendImage(green, pts: CMTime(seconds: 0.04, preferredTimescale: 1000))
        lowEncoder.appendImage(blue, pts: CMTime(seconds: 0.12, preferredTimescale: 1000))
        let lowSummary = try await lowEncoder.finish()
        #expect(lowSummary.frameCount == 2)

        let highEncoder = try GifRecordingEncoder(outputURL: highFPSURL, pixelSize: CGSize(width: 48, height: 32), fps: 30)
        highEncoder.appendImage(red, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        highEncoder.appendImage(green, pts: CMTime(seconds: 0.04, preferredTimescale: 1000))
        highEncoder.appendImage(blue, pts: CMTime(seconds: 0.12, preferredTimescale: 1000))
        let highSummary = try await highEncoder.finish()
        #expect(highSummary.frameCount == 3)
    }

    @Test @MainActor func controlPanelTogglesAudioForVideoOnlyAndUpdatesAllPhases() throws {
        let panel = RecordingControlPanel(
            captureRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            settings: RecordingSettings(format: .mp4, capturesSystemAudio: true, capturesMicrophone: true)
        )
        #expect(panel.isReadyContainerVisible)
        #expect(panel.areAudioTogglesEnabled)

        var latestSettings = RecordingSettings()
        panel.onSettingsChanged = { latestSettings = $0 }
        panel.selectFormat(.gif)
        #expect(latestSettings.format == .gif)

        panel.update(phase: .ready, settings: latestSettings, elapsedSeconds: 0)
        #expect(!panel.areAudioTogglesEnabled)

        panel.update(phase: .recording, settings: latestSettings, elapsedSeconds: 5)
        #expect(panel.isRecordingContainerVisible)
        #expect(panel.timerText == "00:05")

        panel.update(phase: .paused, settings: latestSettings, elapsedSeconds: 5)
        #expect(panel.isRecordingContainerVisible)

        panel.update(phase: .finalizing, settings: latestSettings, elapsedSeconds: 5)
        #expect(panel.isFinalizingContainerVisible)

        let fakeResult = RecordingResult(
            fileURL: URL(fileURLWithPath: "/tmp/test.gif"),
            format: .gif,
            duration: 5,
            fileSizeBytes: 1_048_576,
            pixelSize: CGSize(width: 400, height: 300),
            screenRect: CGRect(x: 200, y: 200, width: 400, height: 300)
        )
        panel.update(phase: .completed(fakeResult), settings: latestSettings, elapsedSeconds: 5)
        #expect(panel.isCompletedContainerVisible)
        #expect(panel.summaryText.contains("GIF · 00:05"))
    }

    @Test @MainActor func controlPanelGlassSurfaceClipsLayerToContinuousRoundedCorners() throws {
        let panel = RecordingControlPanel(
            captureRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            settings: RecordingSettings(format: .mp4)
        )
        defer { panel.tearDown() }

        let surface = try #require(panel.contentView)
        surface.layoutSubtreeIfNeeded()
        #expect(surface.wantsLayer)
        let layer = try #require(surface.layer)
        #expect(layer.masksToBounds)
        #expect(layer.cornerCurve == .continuous)
        #expect(layer.cornerRadius == 14)

        if #available(macOS 26.0, *) {
            let glass = try #require(surface as? NSGlassEffectView)
            #expect(glass.cornerRadius == 14)
        }
    }

    @Test @MainActor func controlPanelFPSSelectionAndZeroOverflowLayoutAcrossAllPhases() {
        CCXL10n.withLanguageForTesting(.en) {
            let initialSettings = RecordingSettings(format: .mp4, capturesSystemAudio: true, capturesMicrophone: true)
            let panel = RecordingControlPanel(
                captureRect: CGRect(x: 200, y: 200, width: 600, height: 400),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                settings: initialSettings
            )

            var latestSettings = initialSettings
            panel.onSettingsChanged = { updated in
                latestSettings = updated
                panel.update(phase: .ready, settings: updated, elapsedSeconds: 0)
            }

            // Default MP4 offers video FPS choices and starts at 60 fps.
            #expect(panel.fpsBadgeText == "60 fps")
            #expect(panel.availableFPSMenuOptions == [24, 30, 60])
            assertCleanHUDLayout(in: panel)

            panel.selectFPS(30)
            #expect(latestSettings.videoFPS == 30)
            #expect(panel.fpsBadgeText == "30 fps")
            assertCleanHUDLayout(in: panel)

            // Switching to GIF offers GIF FPS choices (defaulting to 15 fps) without losing videoFPS.
            panel.selectFormat(.gif)
            #expect(panel.fpsBadgeText == "15 fps")
            #expect(panel.availableFPSMenuOptions == [10, 15, 20, 30])
            assertCleanHUDLayout(in: panel)

            panel.selectFPS(20)
            #expect(latestSettings.gifFPS == 20)
            #expect(panel.fpsBadgeText == "20 fps")
            assertCleanHUDLayout(in: panel)

            // Switching back to MOV/MP4 preserves the chosen videoFPS (30 fps).
            panel.selectFormat(.mov)
            #expect(panel.fpsBadgeText == "30 fps")
            assertCleanHUDLayout(in: panel)

            // Recording & paused phases embed selected FPS in badge text without overflow.
            panel.update(phase: .recording, settings: latestSettings, elapsedSeconds: 12)
            #expect(panel.recordingBadgeText == "MOV · 30fps · Sys+Mic")
            assertCleanHUDLayout(in: panel)

            panel.update(phase: .paused, settings: latestSettings, elapsedSeconds: 12)
            #expect(panel.recordingBadgeText == "MOV · Paused")
            assertCleanHUDLayout(in: panel)

            var gifRecording = latestSettings
            gifRecording.format = .gif
            panel.update(phase: .recording, settings: gifRecording, elapsedSeconds: 4)
            #expect(panel.recordingBadgeText == "GIF · 20fps")
            assertCleanHUDLayout(in: panel)

            // Finalizing phase.
            panel.update(phase: .finalizing, settings: latestSettings, elapsedSeconds: 12)
            assertCleanHUDLayout(in: panel)

            // Completed phase with long summary stays cleanly inside container bounds.
            let longResult = RecordingResult(
                fileURL: URL(fileURLWithPath: "/tmp/long-test.mov"),
                format: .mov,
                duration: 754,
                fileSizeBytes: 128 * 1024 * 1024,
                pixelSize: CGSize(width: 1920, height: 1080),
                screenRect: CGRect(x: 200, y: 200, width: 600, height: 400)
            )
            panel.update(phase: .completed(longResult), settings: latestSettings, elapsedSeconds: 754)
            assertCleanHUDLayout(in: panel)
        }
    }

    @Test @MainActor func simplifiedChineseHUDLayoutDescriptionsAndErrorsFitWithoutOverflow() {
        CCXL10n.withLanguageForTesting(.zhHans) {
            #expect(RecordingFormat.mp4.detailDescription == "H.264 视频")
            #expect(RecordingFormat.mov.detailDescription == "HEVC 视频")
            #expect(RecordingFormat.gif.detailDescription == "动图")
            #expect(RecordingFormat.mp4.fpsOptionDescription(for: 60) == "60 fps · 流畅")
            #expect(RecordingFormat.gif.fpsOptionDescription(for: 15) == "15 fps · 均衡")

            let settings = RecordingSettings(
                format: .mov,
                videoFPS: 30,
                gifFPS: 15,
                capturesSystemAudio: true,
                capturesMicrophone: true
            )
            let panel = RecordingControlPanel(
                captureRect: CGRect(x: 200, y: 200, width: 600, height: 400),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                settings: settings
            )
            defer { panel.tearDown() }

            assertCleanHUDLayout(in: panel)

            panel.update(phase: .recording, settings: settings, elapsedSeconds: 12)
            #expect(panel.recordingBadgeText == "MOV · 30fps · 系统+麦")
            assertCleanHUDLayout(in: panel)

            panel.update(phase: .paused, settings: settings, elapsedSeconds: 12)
            #expect(panel.recordingBadgeText == "MOV · 已暂停")
            assertCleanHUDLayout(in: panel)

            panel.update(phase: .finalizing, settings: settings, elapsedSeconds: 12)
            assertCleanHUDLayout(in: panel)

            let result = RecordingResult(
                fileURL: URL(fileURLWithPath: "/tmp/zh-test.mov"),
                format: .mov,
                duration: 754,
                fileSizeBytes: 128 * 1024 * 1024,
                pixelSize: CGSize(width: 1920, height: 1080),
                screenRect: CGRect(x: 200, y: 200, width: 600, height: 400)
            )
            panel.update(phase: .completed(result), settings: settings, elapsedSeconds: 754)
            assertCleanHUDLayout(in: panel)

            #expect(RecordingError.noFramesCaptured.errorDescription == "未捕获到视频画面。")
            #expect(RecordingError.encoderFinalizeFailed.errorDescription == "无法生成 GIF 文件。")
            let startErr = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.failedToStart.rawValue)
            #expect(RecordingCoordinator.userFacingErrorMessage(for: startErr) == "无法开始录屏，请重试。")
            let diskFull = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            #expect(RecordingCoordinator.userFacingErrorMessage(for: diskFull) == "磁盘空间不足，无法保存录屏。")
        }
    }

    @MainActor
    private func assertCleanHUDLayout(in panel: RecordingControlPanel) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let bounds = panel.contentContainerBounds
        let frames = panel.activeControlFramesInContent
        #expect(!frames.isEmpty)
        #expect(bounds.height == 44)
        for frame in frames {
            #expect(frame.width > 0 && frame.height > 0)
            #expect(frame.minX >= -0.5 && frame.maxX <= bounds.width + 0.5)
            #expect(frame.minY >= -0.5 && frame.maxY <= bounds.height + 0.5)
        }
        for pair in zip(frames, frames.dropFirst()) {
            #expect(pair.0.maxX <= pair.1.minX + 0.5)
        }
    }

    @Test func frameAdjusterHitTestsCornersEdgesInteriorAndOutsideWithPriority() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = CGRect(x: 200, y: 150, width: 400, height: 300)
        let adjuster = RecordingFrameAdjuster(bounds: bounds, initialRect: rect)

        // Corners win over adjacent edge midpoints/bands inside handleHitRadius.
        #expect(adjuster.hitTarget(at: CGPoint(x: 200, y: 450)) == .handle(.topLeft))
        #expect(adjuster.hitTarget(at: CGPoint(x: 205, y: 446)) == .handle(.topLeft))
        #expect(adjuster.hitTarget(at: CGPoint(x: 600, y: 150)) == .handle(.bottomRight))

        // Midpoints and off-midpoint edge bands both hit the corresponding edge handle.
        #expect(adjuster.hitTarget(at: CGPoint(x: 400, y: 450)) == .handle(.top))
        #expect(adjuster.hitTarget(at: CGPoint(x: 260, y: 453)) == .handle(.top))
        #expect(adjuster.hitTarget(at: CGPoint(x: 600, y: 300)) == .handle(.right))
        #expect(adjuster.hitTarget(at: CGPoint(x: 596, y: 210)) == .handle(.right))
        #expect(adjuster.hitTarget(at: CGPoint(x: 200, y: 210)) == .handle(.left))
        #expect(adjuster.hitTarget(at: CGPoint(x: 260, y: 150)) == .handle(.bottom))

        // Interior and outside.
        #expect(adjuster.hitTarget(at: CGPoint(x: 350, y: 300)) == .interior)
        #expect(adjuster.hitTarget(at: CGPoint(x: 100, y: 100)) == .outside)
    }

    @Test func frameAdjusterResizesFlipsConstrainsMovesRedrawsAndKeyboardNudges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var adjuster = RecordingFrameAdjuster(bounds: bounds, initialRect: CGRect(x: 200, y: 150, width: 400, height: 300))

        // 1. Edge resize along top edge (off-midpoint) expands height without moving left/right.
        adjuster.mouseDown(at: CGPoint(x: 260, y: 450))
        adjuster.mouseDragged(to: CGPoint(x: 260, y: 550))
        adjuster.mouseUp(at: CGPoint(x: 260, y: 550))
        #expect(adjuster.rect == CGRect(x: 200, y: 150, width: 400, height: 400))

        // 2. Corner resize past opposite corner flips edges cleanly.
        adjuster.mouseDown(at: CGPoint(x: 600, y: 550))
        adjuster.mouseDragged(to: CGPoint(x: 100, y: 50))
        #expect(adjuster.interaction == .resizing(rect: CGRect(x: 100, y: 50, width: 100, height: 100), handle: .bottomLeft))
        adjuster.mouseUp(at: CGPoint(x: 100, y: 50))
        #expect(adjuster.rect == CGRect(x: 100, y: 50, width: 100, height: 100))

        // 3. Shift-constrained corner drag produces a 1:1 square, and mouseUp enforces minimumSide >= 16.
        adjuster.mouseDown(at: CGPoint(x: 200, y: 150))
        adjuster.mouseDragged(to: CGPoint(x: 320, y: 180), constrainSquare: true)
        #expect(adjuster.activeRect == CGRect(x: 100, y: 50, width: 220, height: 220))
        adjuster.mouseDragged(to: CGPoint(x: 104, y: 54))
        adjuster.mouseUp(at: CGPoint(x: 104, y: 54))
        #expect(adjuster.rect == CGRect(x: 100, y: 50, width: 16, height: 16))

        // 4. Resize larger, move inside with edge clamping & stable anchor.
        adjuster.setRect(CGRect(x: 850, y: 100, width: 100, height: 80))
        adjuster.mouseDown(at: CGPoint(x: 900, y: 140))
        adjuster.mouseDragged(to: CGPoint(x: 1050, y: 140))
        #expect(adjuster.activeRect == CGRect(x: 900, y: 100, width: 100, height: 80))
        adjuster.mouseDragged(to: CGPoint(x: 920, y: 140))
        #expect(adjuster.activeRect == CGRect(x: 870, y: 100, width: 100, height: 80))
        adjuster.mouseUp(at: CGPoint(x: 920, y: 140))
        #expect(adjuster.rect == CGRect(x: 870, y: 100, width: 100, height: 80))

        // 5. Micro-click outside preserves previous rect; drag outside redraws (with Space origin-shift).
        adjuster.mouseDown(at: CGPoint(x: 50, y: 50))
        adjuster.mouseDragged(to: CGPoint(x: 51, y: 51))
        adjuster.mouseUp(at: CGPoint(x: 51, y: 51))
        #expect(adjuster.rect == CGRect(x: 870, y: 100, width: 100, height: 80))

        adjuster.mouseDown(at: CGPoint(x: 50, y: 50))
        adjuster.mouseDragged(to: CGPoint(x: 250, y: 200))
        #expect(adjuster.activeRect == CGRect(x: 50, y: 50, width: 200, height: 150))
        adjuster.mouseDragged(to: CGPoint(x: 290, y: 230), moveOrigin: true)
        #expect(adjuster.activeRect == CGRect(x: 90, y: 80, width: 200, height: 150))
        adjuster.mouseUp(at: CGPoint(x: 290, y: 230))
        #expect(adjuster.rect == CGRect(x: 90, y: 80, width: 200, height: 150))

        // 6. Keyboard nudge, resizeBy, and selectAll.
        let nudged = adjuster.nudge(dx: 10, dy: 20)
        #expect(nudged)
        #expect(adjuster.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
        let resizedByKey = adjuster.resizeBy(dw: 20, dh: 10)
        #expect(resizedByKey)
        #expect(adjuster.rect == CGRect(x: 100, y: 90, width: 220, height: 160))
        let selectedAll = adjuster.selectAll()
        #expect(selectedAll)
        #expect(adjuster.rect == bounds)
    }

    @Test func regionUpdatingClampsAndMapsNegativeOriginDisplays() {
        let secondaryDisplay = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let base = RecordingRegion(
            displayID: 42,
            displayFrame: secondaryDisplay,
            localRect: CGRect(x: 20, y: 20, width: 100, height: 100),
            screenRect: CGRect(x: -1900, y: -180, width: 100, height: 100),
            scale: 2
        )

        let updated = base.updating(localRect: CGRect(x: 100, y: 200, width: 400, height: 300))
        #expect(updated.localRect == CGRect(x: 100, y: 200, width: 400, height: 300))
        #expect(updated.screenRect == CGRect(x: -1820, y: 0, width: 400, height: 300))
        #expect(updated.sourceRectInDisplayPoints == CGRect(x: 100, y: 580, width: 400, height: 300))
        #expect(updated.videoPixelSize == CGSize(width: 800, height: 600))
        #expect(updated.gifPixelSize() == CGSize(width: 800, height: 600))

        // Oversized or negative local rect clamps cleanly inside display bounds.
        let clamped = base.updating(localRect: CGRect(x: 1800, y: -40, width: 300, height: 200))
        #expect(clamped.localRect == CGRect(x: 1620, y: 0, width: 300, height: 200))
        #expect(clamped.screenRect == CGRect(x: -300, y: -200, width: 300, height: 200))
    }

    @Test @MainActor func borderPanelInteractiveReadyAdjustsRegionAndLocksIntoCaptureMode() throws {
        let displayFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let initialRegion = RecordingRegion(
            displayID: 1,
            displayFrame: displayFrame,
            localRect: CGRect(x: 200, y: 150, width: 400, height: 300),
            screenRect: CGRect(x: 200, y: 150, width: 400, height: 300),
            scale: 2
        )
        let settings = RecordingSettings(format: .mp4)
        let borderPanel = RecordingBorderPanel(region: initialRegion, topInset: 32, settings: settings)
        let controlPanel = RecordingControlPanel(
            captureRect: initialRegion.screenRect,
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 768),
            settings: settings
        )

        #expect(borderPanel.frame == displayFrame)
        #expect(borderPanel.constrainFrameRect(displayFrame, to: nil) == displayFrame)
        #expect(borderPanel.isInteractive)
        #expect(!borderPanel.ignoresMouseEvents)
        #expect(borderPanel.canBecomeKey)
        #expect(borderPanel.level == .statusBar)
        #expect(controlPanel.level.rawValue > borderPanel.level.rawValue)
        #expect(!borderPanel.isSizeLabelHidden)
        #expect(borderPanel.sizeLabelText.contains("800 × 600"))

        borderPanel.onRegionChanged = { updated in
            controlPanel.updateCaptureRect(updated.screenRect)
        }
        borderPanel.onInteractionStateChanged = { adjusting in
            controlPanel.setTemporarilyHidden(adjusting)
            if !adjusting {
                controlPanel.updateCaptureRect(borderPanel.currentRegion.screenRect)
            }
        }

        let borderView = borderPanel.borderContentView
        let controlOriginBefore = controlPanel.frame.origin

        // Drag top-right corner handle from (600, 450) to (900, 500) -> 700x350pt (1400x700px MP4).
        borderView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 600, y: 450)))
        #expect(borderPanel.isActivelyAdjusting)
        #expect(controlPanel.alphaValue == 0)
        #expect(controlPanel.ignoresMouseEvents)

        borderView.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 900, y: 500)))
        borderView.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 900, y: 500)))

        #expect(!borderPanel.isActivelyAdjusting)
        #expect(borderPanel.currentRegion.localRect == CGRect(x: 200, y: 150, width: 700, height: 350))
        #expect(borderPanel.sizeLabelText.contains("1400 × 700"))
        #expect(controlPanel.alphaValue == 1)
        #expect(!controlPanel.ignoresMouseEvents)
        #expect(controlPanel.frame.origin != controlOriginBefore)

        // Switching format to GIF updates the displayed pixel dimensions (capped at 1280px).
        let gifSettings = RecordingSettings(format: .gif)
        borderPanel.update(phase: .ready, region: borderPanel.currentRegion, settings: gifSettings)
        #expect(borderPanel.sizeLabelText.contains("1280 × 640"))

        // Move interior by (+50, +40).
        borderView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 550, y: 325)))
        borderView.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 600, y: 365)))
        borderView.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 600, y: 365)))
        #expect(borderPanel.currentRegion.localRect == CGRect(x: 250, y: 190, width: 700, height: 350))

        // Lock into capture mode before async permission checks / stream recording.
        borderPanel.prepareForCapture(region: borderPanel.currentRegion)
        #expect(!borderPanel.isInteractive)
        #expect(borderPanel.ignoresMouseEvents)
        #expect(!borderPanel.canBecomeKey)
        #expect(borderPanel.frame == borderPanel.currentRegion.screenRect.insetBy(dx: -4, dy: -4))
        #expect(borderPanel.isSizeLabelHidden)

        borderPanel.update(phase: .recording, region: borderPanel.currentRegion, settings: gifSettings)
        #expect(!borderPanel.isInteractive)
        #expect(borderPanel.ignoresMouseEvents)
    }

    @Test @MainActor func borderPanelSkipsRedundantRendersAndControlPanelThrottlesTimerAndPreservesCustomPosition() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let region = RecordingRegion(
            displayID: 1,
            displayFrame: displayFrame,
            localRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            screenRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            scale: 2
        )
        let settings = RecordingSettings(format: .mp4)
        let borderPanel = RecordingBorderPanel(region: region, topInset: 24, settings: settings)
        let controlPanel = RecordingControlPanel(
            captureRect: region.screenRect,
            visibleFrame: displayFrame,
            settings: settings
        )

        #expect(controlPanel.isMovableByWindowBackground)
        #expect(!controlPanel.hasCustomPosition)

        // Transitioning into recording renders capture chrome once; repeating identical updates is a no-op.
        borderPanel.prepareForCapture(region: region)
        borderPanel.update(phase: .recording, region: region, settings: settings)
        let rendersAfterStart = borderPanel.renderCountForTesting
        borderPanel.update(phase: .recording, region: region, settings: settings)
        borderPanel.update(phase: .recording, region: region, settings: settings)
        #expect(borderPanel.renderCountForTesting == rendersAfterStart)

        // Control HUD updates timer only when the formatted second changes.
        controlPanel.update(phase: .recording, settings: settings, elapsedSeconds: 5.1)
        #expect(controlPanel.timerText == "00:05")
        controlPanel.update(phase: .recording, settings: settings, elapsedSeconds: 5.9)
        #expect(controlPanel.timerText == "00:05")
        controlPanel.update(phase: .recording, settings: settings, elapsedSeconds: 6.0)
        #expect(controlPanel.timerText == "00:06")

        // Moving the control HUD by background drag preserves custom position across phase transitions until region moves.
        controlPanel.setFrameOrigin(CGPoint(x: 120, y: 640))
        #expect(controlPanel.hasCustomPosition)
        controlPanel.update(phase: .paused, settings: settings, elapsedSeconds: 6.0)
        #expect(controlPanel.hasCustomPosition)
        #expect(abs(controlPanel.frame.minY - 640) < 0.5)

        controlPanel.updateCaptureRect(CGRect(x: 100, y: 300, width: 500, height: 300))
        #expect(!controlPanel.hasCustomPosition)
    }

    @Test func fileSecurityEnforcesPermissionsRejectsSymlinksAndScopesCleanup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccx-sec-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. Staging directory created with 0700 and widens tightened back to 0700.
        let stageDir = root.appendingPathComponent("CCXRecordings", isDirectory: true)
        try RecordingFileSecurity.ensureSecureStagingDirectory(at: stageDir)
        var st = stat()
        #expect(lstat(stageDir.path, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o700)

        #expect(chmod(stageDir.path, 0o755) == 0)
        try RecordingFileSecurity.ensureSecureStagingDirectory(at: stageDir)
        #expect(lstat(stageDir.path, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o700)

        // 2. Symlinked staging directory is rejected and ignored by cleanup.
        let victimDir = root.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victimDir, withIntermediateDirectories: true)
        let victimFile = victimDir.appendingPathComponent("CCX-Rec-keep.mp4")
        try Data("keep".utf8).write(to: victimFile)
        let symlinkStage = root.appendingPathComponent("SymlinkStage")
        try fm.createSymbolicLink(at: symlinkStage, withDestinationURL: victimDir)

        #expect(throws: Error.self) {
            try RecordingFileSecurity.ensureSecureStagingDirectory(at: symlinkStage)
        }
        RecordingFileSecurity.cleanupStagingDirectory(at: symlinkStage, olderThan: 0)
        #expect(fm.fileExists(atPath: victimFile.path))

        // 3. validateOutputURLForWriting rejects symlinks, directories, and traversal paths.
        let symlinkOutput = stageDir.appendingPathComponent("CCX-Rec-link.mp4")
        try fm.createSymbolicLink(at: symlinkOutput, withDestinationURL: victimFile)
        #expect(throws: Error.self) {
            try RecordingFileSecurity.validateOutputURLForWriting(symlinkOutput)
        }
        #expect(throws: Error.self) {
            try RecordingFileSecurity.validateOutputURLForWriting(stageDir)
        }
        let traversalURL = URL(fileURLWithPath: stageDir.path + "/../escape.mp4")
        #expect(throws: Error.self) {
            try RecordingFileSecurity.validateOutputURLForWriting(traversalURL)
        }

        // 4. restrictFilePermissions sets 0600 on regular files and skips symlinks.
        let regularFile = stageDir.appendingPathComponent("CCX-Rec-old.mp4")
        try Data("video".utf8).write(to: regularFile)
        #expect(chmod(regularFile.path, 0o644) == 0)
        RecordingFileSecurity.restrictFilePermissions(at: regularFile)
        #expect(lstat(regularFile.path, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o600)

        // 5. Scoped cleanup removes only stale CCX-Rec-* regular files, preserving active/unrelated/symlinks.
        let activeFile = stageDir.appendingPathComponent("CCX-Rec-active.mp4")
        let unrelatedFile = stageDir.appendingPathComponent("notes.txt")
        try Data("active".utf8).write(to: activeFile)
        try Data("note".utf8).write(to: unrelatedFile)

        RecordingFileSecurity.cleanupStagingDirectory(
            at: stageDir,
            olderThan: 0,
            activeFileURLs: [activeFile]
        )
        #expect(!fm.fileExists(atPath: regularFile.path))
        #expect(fm.fileExists(atPath: activeFile.path))
        #expect(fm.fileExists(atPath: unrelatedFile.path))
        #expect(lstat(symlinkOutput.path, &st) == 0)
        #expect(fm.fileExists(atPath: victimFile.path))

        // Non-finite maxAge falls back safely without crashing.
        RecordingFileSecurity.cleanupStagingDirectory(at: stageDir, olderThan: .nan)
        RecordingFileSecurity.cleanupStagingDirectory(at: stageDir, olderThan: -.infinity)
    }

    @Test func nonFiniteAndOverflowGuardsProtectModelsAdjusterAndEncoders() throws {
        // Non-finite RecordingRegion values clamp to finite, even, positive dimensions.
        let nanRegion = RecordingRegion(
            displayID: 1,
            displayFrame: CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: CGFloat.nan, height: -50),
            localRect: .null,
            screenRect: .infinite,
            scale: .nan
        )
        let nanSource = nanRegion.sourceRectInDisplayPoints
        #expect(nanSource.origin.x.isFinite && nanSource.origin.y.isFinite)
        #expect(nanSource.width >= 1 && nanSource.height >= 1)
        let nanVideo = nanRegion.videoPixelSize
        #expect(nanVideo.width >= 2 && nanVideo.height >= 2 && Int(nanVideo.width).isMultiple(of: 2))
        let nanGif = nanRegion.gifPixelSize(maxDimension: 1280)
        #expect(nanGif.width >= 2 && nanGif.height >= 2 && Int(nanGif.width).isMultiple(of: 2))

        // Out-of-bounds localRect clamps strictly inside displayFrame.
        let outsideRegion = RecordingRegion(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            localRect: CGRect(x: 1500, y: -300, width: 200, height: 150),
            screenRect: CGRect(x: 1500, y: -300, width: 200, height: 150),
            scale: 2
        )
        let clampedSource = outsideRegion.sourceRectInDisplayPoints
        #expect(clampedSource.minX >= 0 && clampedSource.maxX <= 1000)
        #expect(clampedSource.minY >= 0 && clampedSource.maxY <= 800)

        let updatedWithNaN = outsideRegion.updating(localRect: CGRect(x: CGFloat.nan, y: 10, width: CGFloat.infinity, height: 50))
        #expect(updatedWithNaN.localRect.origin.x.isFinite && updatedWithNaN.localRect.width.isFinite)

        // Duration formatting never traps on non-finite or hour+ inputs.
        #expect(RecordingResult.formatDuration(.nan) == "00:00")
        #expect(RecordingResult.formatDuration(.infinity) == "00:00")
        #expect(RecordingResult.formatDuration(-.infinity) == "00:00")
        #expect(RecordingResult.formatDuration(-5) == "00:00")
        #expect(RecordingResult.formatDuration(754) == "12:34")
        #expect(RecordingResult.formatDuration(3661) == "1:01:01")

        // Unknown future RecordingFormat preserves remaining settings fields.
        let futureJSON = Data(#"{"format":"webp","videoFPS":30,"gifFPS":20,"capturesSystemAudio":false,"capturesMicrophone":true,"showsCursor":false}"#.utf8)
        let decodedFuture = try JSONDecoder().decode(RecordingSettings.self, from: futureJSON)
        #expect(decodedFuture.format == .mp4)
        #expect(decodedFuture.videoFPS == 30)
        #expect(decodedFuture.gifFPS == 20)
        #expect(!decodedFuture.capturesSystemAudio && decodedFuture.capturesMicrophone && !decodedFuture.showsCursor)

        // RecordingFrameAdjuster ignores non-finite points and deltas safely.
        var adjuster = RecordingFrameAdjuster(bounds: CGRect(x: 0, y: 0, width: 800, height: 600), initialRect: CGRect(x: 50, y: 50, width: 100, height: 100))
        #expect(adjuster.hitTarget(at: CGPoint(x: CGFloat.nan, y: 50)) == .outside)
        adjuster.mouseDown(at: CGPoint(x: CGFloat.infinity, y: 50))
        #expect(!adjuster.isInteracting)
        let didNudgeNaN = adjuster.nudge(dx: .nan, dy: 0)
        #expect(!didNudgeNaN)
        let didResizeInf = adjuster.resizeBy(dw: .infinity, dh: 0)
        #expect(!didResizeInf)
        adjuster.setRect(.null)
        #expect(adjuster.rect.origin.x.isFinite && adjuster.rect.width >= 16)

        // Writers/encoders reject non-finite or zero pixel dimensions cleanly.
        let tempMP4 = FileManager.default.temporaryDirectory.appendingPathComponent("ccx-invalid-\(UUID().uuidString).mp4")
        let tempGIF = FileManager.default.temporaryDirectory.appendingPathComponent("ccx-invalid-\(UUID().uuidString).gif")
        #expect(throws: Error.self) {
            _ = try VideoRecordingWriter(
                outputURL: tempMP4,
                format: .mp4,
                pixelSize: CGSize(width: CGFloat.nan, height: 100),
                capturesSystemAudio: false,
                capturesMicrophone: false
            )
        }
        #expect(throws: Error.self) {
            _ = try VideoRecordingWriter(
                outputURL: tempMP4,
                format: .mp4,
                pixelSize: CGSize(width: 0, height: 100),
                capturesSystemAudio: false,
                capturesMicrophone: false
            )
        }
        #expect(throws: Error.self) {
            _ = try GifRecordingEncoder(outputURL: tempGIF, pixelSize: CGSize(width: CGFloat.infinity, height: 100))
        }
        #expect(throws: Error.self) {
            _ = try GifRecordingEncoder(outputURL: tempGIF, pixelSize: CGSize(width: -10, height: 100))
        }
    }

    @Test func audioNormalizerBoundsSafetyAndMixerC1SoftClipStaleSyncAndFlush() throws {
        // 1. C1-continuous soft clipper is strictly monotonic across 0.85 (no cliff drop) and sanitizes NaN/Inf.
        let probe: [Float] = [0.80, 0.85, 0.8501, 0.86, 0.90, 1.20, 1.80, .nan, .infinity, -.infinity]
        let clipped = DualAudioMixer.mix(system: probe, microphone: [])
        #expect(clipped.count == probe.count)
        #expect(abs(clipped[0] - 0.80) < 0.0001)
        #expect(abs(clipped[1] - 0.85) < 0.0001)
        #expect(clipped[2] > clipped[1] && clipped[2] < clipped[3])
        #expect(clipped[3] < clipped[4] && clipped[4] < clipped[5] && clipped[5] < clipped[6])
        #expect(clipped[6] <= 1.0)
        #expect(clipped[7] == 0 && clipped[8] == 0 && clipped[9] == 0)

        // 2. Stale mic samples (>0.5s behind system PTS) are dropped instead of mixed out of sync.
        var mixer = DualAudioMixer()
        let t0 = CMTime(seconds: 0.0, preferredTimescale: 48_000)
        #expect(mixer.pushMicrophone([Float](repeating: 0.4, count: 400), pts: t0).isEmpty)
        let tLate = CMTime(seconds: 2.0, preferredTimescale: 48_000)
        let sysOnly = mixer.pushSystem([Float](repeating: 0.2, count: 400), pts: tLate)
        #expect(sysOnly.count == 1)
        #expect(abs((sysOnly[0].samples.first ?? 0) - 0.2) < 0.001)

        // 3. Stall-flushed mic PTS never regresses below last emitted end PTS, and flush() drains tail.
        let tMicEarly = CMTime(seconds: 1.99, preferredTimescale: 48_000)
        #expect(mixer.pushMicrophone([Float](repeating: 0.1, count: 4000), pts: tMicEarly).isEmpty)
        let tMicLater = CMTime(seconds: 2.20, preferredTimescale: 48_000)
        let stalledFlush = mixer.pushMicrophone([Float](repeating: 0.1, count: 5000), pts: tMicLater)
        #expect(stalledFlush.count == 1)
        #expect(stalledFlush[0].pts >= tLate)

        // Odd-length push trims to even stereo framing and flush() emits remaining tail.
        let oddPush = mixer.pushMicrophone([0.1, 0.2, 0.3], pts: CMTime(seconds: 2.5, preferredTimescale: 48_000))
        #expect(oddPush.isEmpty)
        let flushedTail = mixer.flush()
        let tail = try #require(flushedTail)
        #expect(tail.samples.count == 2)
        #expect(tail.pts >= stalledFlush[0].pts)
        let emptyTail = mixer.flush()
        #expect(emptyTail == nil)

        // 4. makePCMSampleBuffer rejects non-numeric PTS and invalid sample rates.
        #expect(DualAudioMixer.makePCMSampleBuffer(interleavedStereoFloat32: [0.1, 0.1], pts: .indefinite) == nil)
        #expect(DualAudioMixer.makePCMSampleBuffer(interleavedStereoFloat32: [0.1, 0.1], pts: .positiveInfinity) == nil)
        #expect(DualAudioMixer.makePCMSampleBuffer(interleavedStereoFloat32: [0.1, 0.1], pts: .zero, sampleRate: 0) == nil)
        #expect(DualAudioMixer.makePCMSampleBuffer(interleavedStereoFloat32: [0.1, 0.1], pts: .zero, sampleRate: .nan) == nil)

        // 5. AudioSampleNormalizer rejects truncated mDataByteSize and handles >2ch discrete layout safely.
        let normalizer = AudioSampleNormalizer()
        let stereoFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let truncatedBuf = try #require(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 16))
        truncatedBuf.frameLength = 16
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: truncatedBuf.audioBufferList))
        list[0].mDataByteSize = 4 // Too small for 16 stereo Float32 frames (128 bytes).
        #expect(normalizer.normalize(pcmBuffer: truncatedBuf).isEmpty)

        // Resampling path (44.1 kHz mono -> 48 kHz stereo) converts cleanly and reuses scratch output buffer across calls.
        let mono44kFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let mono44kBuf = try #require(AVAudioPCMBuffer(pcmFormat: mono44kFormat, frameCapacity: 441))
        mono44kBuf.frameLength = 441
        if let ch0 = mono44kBuf.floatChannelData?[0] {
            for i in 0..<441 { ch0[i] = 0.25 }
        }
        let resampled1 = normalizer.normalize(pcmBuffer: mono44kBuf)
        let resampled2 = normalizer.normalize(pcmBuffer: mono44kBuf)
        #expect(!resampled1.isEmpty && resampled1.count.isMultiple(of: 2))
        #expect(!resampled2.isEmpty && resampled2.count.isMultiple(of: 2))

        // Multi-channel (>2ch) buffer converts without force-unwrap crashes.
        if let fourChLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4) {
            let fourChFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: fourChLayout)
            if let fourChBuf = AVAudioPCMBuffer(pcmFormat: fourChFormat, frameCapacity: 8) {
                fourChBuf.frameLength = 8
                _ = normalizer.normalize(pcmBuffer: fourChBuf)
                normalizer.reset()
            }
        }
    }

    @Test func timelineWallClockPauseHandlesStaticScreensRejectsInfinityAndTracksFinalDuration() {
        var timeline = RecordingTimeline()

        // Non-numeric (+/-infinity, indefinite) timestamps are rejected cleanly.
        #expect(timeline.acceptVideoPTS(.positiveInfinity) == nil)
        #expect(timeline.acceptVideoPTS(.negativeInfinity) == nil)
        #expect(timeline.acceptVideoPTS(.indefinite) == nil)
        #expect(timeline.acceptAudioPTS(.positiveInfinity) == nil)

        // Pause before first video frame does not distort session start.
        timeline.pause(at: CMTime(seconds: 50.0, preferredTimescale: 1000))
        timeline.resume(at: CMTime(seconds: 55.0, preferredTimescale: 1000))

        // First video frame at PTS 100.0 (wall 100.0), second at 101.0 (wall 101.0).
        let v0 = timeline.acceptVideoPTS(CMTime(seconds: 100.0, preferredTimescale: 1000), wallTime: CMTime(seconds: 100.0, preferredTimescale: 1000))
        #expect(v0 == .zero)
        let v1 = timeline.acceptVideoPTS(CMTime(seconds: 101.0, preferredTimescale: 1000), wallTime: CMTime(seconds: 101.0, preferredTimescale: 1000))
        #expect(abs((v1?.seconds ?? -1) - 1.0) < 0.001)

        // Pause for 10 seconds with ZERO frames arriving during pause (completely static screen!).
        timeline.pause(at: CMTime(seconds: 101.5, preferredTimescale: 1000))
        timeline.resume(at: CMTime(seconds: 111.5, preferredTimescale: 1000))

        // Next frame arrives at 112.0 -> 10.0s removed cleanly => adjusted PTS = 2.0s.
        let v2 = timeline.acceptVideoPTS(CMTime(seconds: 112.0, preferredTimescale: 1000), wallTime: CMTime(seconds: 112.0, preferredTimescale: 1000))
        #expect(abs((v2?.seconds ?? -1) - 2.0) < 0.001)

        // Screen remains static until stop at wall 118.0 -> total active duration = 118 - 100 - 10 = 8.0s.
        timeline.finish(at: CMTime(seconds: 118.0, preferredTimescale: 1000))
        #expect(abs(timeline.recordedDurationSeconds - 8.0) < 0.001)
    }

    @Test func gifEncoderEnforcesMemoryCapZeroCopyBGRAPathDelayCarryPermissionsAndCancelRelease() async throws {
        // 1. Frame cap fires onLimitReached once, caps written frames, and sets 0600 permissions.
        let cappedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-cap-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: cappedURL) }

        let limitHits = OSAllocatedUnfairLock<Int>(initialState: 0)
        let cappedEncoder = try GifRecordingEncoder(
            outputURL: cappedURL,
            pixelSize: CGSize(width: 48, height: 32),
            fps: 30,
            maxFrameCount: 2,
            onLimitReached: { limitHits.withLock { $0 += 1 } }
        )
        #expect(cappedEncoder.maxFrames == 2)

        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.9, 0.1, 0.1), (0.1, 0.9, 0.1), (0.1, 0.1, 0.9), (0.9, 0.9, 0.1),
        ]
        for (idx, color) in colors.enumerated() {
            let img = try makeCGImage(width: 48, height: 32, red: color.0, green: color.1, blue: color.2)
            cappedEncoder.appendImage(img, pts: CMTime(seconds: Double(idx) * 0.10, preferredTimescale: 1000))
        }
        let cappedSummary = try await cappedEncoder.finish()
        #expect(cappedSummary.frameCount == 2)
        #expect(limitHits.withLock { $0 } == 1)
        #expect(await cappedEncoder.debugIsDestinationReleased())

        var st = stat()
        #expect(lstat(cappedURL.path, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o600)

        // 2. 1:1 BGRA CVPixelBuffer static coalescing skips materializing duplicate frames & rejects planar buffers.
        let bgraURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-bgra-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: bgraURL) }

        let bgraEncoder = try GifRecordingEncoder(outputURL: bgraURL, pixelSize: CGSize(width: 64, height: 48), fps: 15)
        let pbA = try #require(makeTestBGRAPixelBuffer(width: 64, height: 48, r: 220, g: 40, b: 40))
        let pbB = try #require(makeTestBGRAPixelBuffer(width: 64, height: 48, r: 40, g: 220, b: 60))
        bgraEncoder.appendVideo(pixelBuffer: pbA, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        bgraEncoder.appendVideo(pixelBuffer: pbA, pts: CMTime(seconds: 0.10, preferredTimescale: 1000))
        bgraEncoder.appendVideo(pixelBuffer: pbA, pts: CMTime(seconds: 0.20, preferredTimescale: 1000))
        bgraEncoder.appendVideo(pixelBuffer: pbB, pts: CMTime(seconds: 0.30, preferredTimescale: 1000))

        // Planar NV12 pixel buffer is safely ignored without crashing.
        var planarPB: CVPixelBuffer?
        if CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &planarPB) == kCVReturnSuccess,
           let planarPB {
            bgraEncoder.appendVideo(pixelBuffer: planarPB, pts: CMTime(seconds: 0.40, preferredTimescale: 1000))
        }

        let bgraSummary = try await bgraEncoder.finish()
        #expect(bgraSummary.frameCount == 2)
        #expect(await bgraEncoder.debugMaterializedFrameCount() == 2)

        // 3. Centisecond delay carry preserves average 30fps timing without cumulative rounding drift.
        let carryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-carry-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: carryURL) }

        let carryEncoder = try GifRecordingEncoder(outputURL: carryURL, pixelSize: CGSize(width: 32, height: 32), fps: 30)
        for idx in 0..<6 {
            let tone = CGFloat(idx + 1) / 7.0
            let img = try makeCGImage(width: 32, height: 32, red: tone, green: 1.0 - tone, blue: 0.3)
            carryEncoder.appendImage(img, pts: CMTime(value: CMTimeValue(idx), timescale: 30))
        }
        let carrySummary = try await carryEncoder.finish()
        #expect(carrySummary.frameCount == 6)
        let carrySource = try #require(CGImageSourceCreateWithURL(carryURL as CFURL, nil))
        var totalDelay: Double = 0
        for idx in 0..<CGImageSourceGetCount(carrySource) {
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(carrySource, idx, nil) as? [CFString: Any])
            let gifProps = try #require(props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            totalDelay += (gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gifProps[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0
        }
        #expect(abs(totalDelay - 0.20) <= 0.015)

        // 4. maxBufferedBytes caps maxFrames proportionally to frame pixel byte size.
        let byteBudgetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-budget-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: byteBudgetURL) }
        // 64 x 64 x 4 = 16_384 bytes/frame -> budget 50_000 allows 3 frames.
        let budgetEncoder = try GifRecordingEncoder(
            outputURL: byteBudgetURL,
            pixelSize: CGSize(width: 64, height: 64),
            fps: 15,
            maxFrameCount: 900,
            maxBufferedBytes: 50_000
        )
        #expect(budgetEncoder.maxFrames == 3)
        budgetEncoder.cancel()

        // 5. Cancel immediately releases destination and removes output file.
        let cancelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-cancel-\(UUID().uuidString).gif")
        let cancelEncoder = try GifRecordingEncoder(outputURL: cancelURL, pixelSize: CGSize(width: 32, height: 32), fps: 15)
        cancelEncoder.appendImage(try makeCGImage(width: 32, height: 32, red: 0.5, green: 0.5, blue: 0.5), pts: .zero)
        cancelEncoder.cancel()
        #expect(await cancelEncoder.debugIsDestinationReleased())
        #expect(!FileManager.default.fileExists(atPath: cancelURL.path))
    }

    @Test @MainActor func tinyRectInteriorIsGrabbableAndHUDHandlesTinyBorderAndCancel() {
        // 16x16 minimum-size rect still exposes an interior hit target at its center.
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var tinyAdjuster = RecordingFrameAdjuster(bounds: bounds, initialRect: CGRect(x: 100, y: 100, width: 16, height: 16))
        #expect(tinyAdjuster.hitTarget(at: CGPoint(x: 108, y: 108)) == .interior)
        #expect(tinyAdjuster.hitTarget(at: CGPoint(x: 100, y: 116)) == .handle(.topLeft))
        #expect(tinyAdjuster.hitTarget(at: CGPoint(x: 95, y: 120)) == .handle(.topLeft))

        // cancelInteraction resets drag state without modifying committed rect.
        tinyAdjuster.mouseDown(at: CGPoint(x: 108, y: 108))
        #expect(tinyAdjuster.isInteracting)
        tinyAdjuster.mouseDragged(to: CGPoint(x: 150, y: 150))
        tinyAdjuster.cancelInteraction()
        #expect(!tinyAdjuster.isInteracting)
        #expect(tinyAdjuster.rect == CGRect(x: 100, y: 100, width: 16, height: 16))

        // Tiny border panel capture chrome does not trap in CGPath(roundedRect:).
        let tinyRegion = RecordingRegion(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 8, height: 8),
            localRect: CGRect(x: 1, y: 1, width: 6, height: 6),
            screenRect: CGRect(x: 1, y: 1, width: 6, height: 6),
            scale: 1
        )
        let tinyBorder = RecordingBorderPanel(region: tinyRegion, topInset: 0, settings: RecordingSettings())
        tinyBorder.prepareForCapture(region: tinyRegion)
        tinyBorder.update(phase: .recording, region: tinyRegion, settings: RecordingSettings())
        tinyBorder.tearDown()
    }

    @Test @MainActor func coordinatorCancelIfInReadyPhaseKeyScopingAndStreamErrorClassification() throws {
        let suiteName = "CCXRecordCoordTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = RecordingCoordinator(settingsStore: RecordingSettingsStore(defaults: defaults))
        let region = RecordingRegion(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            localRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            screenRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            scale: 2
        )

        // Inactive coordinator returns false for cancelIfInReadyPhase.
        #expect(!coordinator.cancelIfInReadyPhase())

        var outcomes: [RecordingOutcome] = []
        coordinator.startSession(region: region) { outcomes.append($0) }
        #expect(coordinator.isSessionActive)
        #expect(coordinator.phase == .ready)

        // Global Escape allowed ONLY for unmodified Esc in .ready.
        #expect(coordinator.shouldHandleGlobalEscape(modifiers: []))
        #expect(!coordinator.shouldHandleGlobalEscape(modifiers: [.command, .option]))

        // Local key monitor ignores unrelated windows and text field editors.
        #expect(!coordinator.handleLocalKeyDown(keyCode: 53, modifiers: [], chars: "", windowNumber: 999_999, isEditingText: false))
        if let controlWin = coordinator.controlPanelWindowNumberForTesting, controlWin > 0 {
            #expect(!coordinator.handleLocalKeyDown(keyCode: 53, modifiers: [], chars: "", windowNumber: controlWin, isEditingText: true))
        }

        // Non-.ready phases reject global Esc, cancelIfInReadyPhase, and .finalizing rejects local Esc.
        coordinator.setPhaseForTesting(.recording)
        #expect(!coordinator.shouldHandleGlobalEscape(modifiers: []))
        #expect(!coordinator.cancelIfInReadyPhase())

        coordinator.setPhaseForTesting(.finalizing)
        #expect(!coordinator.shouldHandleGlobalEscape(modifiers: []))
        #expect(!coordinator.cancelIfInReadyPhase())
        if let controlWin = coordinator.controlPanelWindowNumberForTesting, controlWin > 0 {
            #expect(!coordinator.handleLocalKeyDown(keyCode: 53, modifiers: [], chars: "", windowNumber: controlWin, isEditingText: false))
        }

        // Back in .ready, cancelIfInReadyPhase cancels cleanly and emits .cancelled.
        coordinator.setPhaseForTesting(.ready)
        #expect(coordinator.cancelIfInReadyPhase())
        #expect(!coordinator.isSessionActive)
        #expect(outcomes.count == 1)
        if case .cancelled = outcomes.first {
            // Expected
        } else {
            Issue.record("Expected .cancelled outcome from cancelIfInReadyPhase")
        }

        // Typed SCStreamError classification.
        let declined = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let stopped = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.systemStoppedStream.rawValue)
        #expect(RecordingCoordinator.isPermissionDeniedError(declined))
        #expect(!RecordingCoordinator.isPermissionDeniedError(stopped))
        #expect(RecordingCoordinator.isUserStoppedStreamError(stopped))
        #expect(!RecordingCoordinator.isUserStoppedStreamError(declined))

        // ScreenRecordingEngine clears callbacks on cancel() so no retain cycle leaks the engine.
        weak var weakEngine: ScreenRecordingEngine?
        do {
            let engineURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ccx-engine-deinit-\(UUID().uuidString).mp4")
            let engine = ScreenRecordingEngine(region: region, settings: RecordingSettings(), outputURL: engineURL)
            weakEngine = engine
            engine.onNotice = { _, _ in _ = engine.effectiveSettings }
            engine.onUnexpectedStop = { _ in _ = engine.effectiveSettings }
            engine.onLimitReached = { _ = engine.effectiveSettings }
            engine.cancel()
        }
        #expect(weakEngine == nil)

        // User-facing error mapping translates technical SCStream/AVFoundation/POSIX codes to clear copy.
        CCXL10n.withLanguageForTesting(.en) {
            let startErr = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.failedToStart.rawValue)
            let startMsg = RecordingCoordinator.userFacingErrorMessage(for: startErr)
            #expect(!startMsg.contains("SCStreamErrorDomain"))
            #expect(startMsg.contains("start screen recording"))

            let audioErr = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.failedToStartMicrophoneCapture.rawValue)
            #expect(RecordingCoordinator.userFacingErrorMessage(for: audioErr).contains("audio"))

            let diskFullCocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            #expect(RecordingCoordinator.userFacingErrorMessage(for: diskFullCocoa).contains("disk space"))

            let diskFullAV = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)
            #expect(RecordingCoordinator.userFacingErrorMessage(for: diskFullAV).contains("disk space"))

            let diskFullPOSIX = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            #expect(RecordingCoordinator.userFacingErrorMessage(for: diskFullPOSIX).contains("disk space"))
        }

        // 5K/6K display proportional H.264 4096px cap vs HEVC 8192px & GIF 1280px cap.
        let fiveKRegion = RecordingRegion(
            displayID: 99,
            displayFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            localRect: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            screenRect: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            scale: 2
        )
        let mp4Size = fiveKRegion.pixelSize(for: .mp4)
        #expect(mp4Size == CGSize(width: 4096, height: 2304))
        let movSize = fiveKRegion.pixelSize(for: .mov)
        #expect(movSize == CGSize(width: 5120, height: 2880))
        let gifSize5K = fiveKRegion.pixelSize(for: .gif)
        #expect(gifSize5K == CGSize(width: 1280, height: 720))
    }

    @Test func videoWriterRejectsSymlinkFinishWithNoFramesThrowsAndCancelCleansUp() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccx-vw-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. Symlink output path is rejected at init time.
        let targetFile = root.appendingPathComponent("target.mp4")
        try Data("orig".utf8).write(to: targetFile)
        let linkURL = root.appendingPathComponent("link.mp4")
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: targetFile)
        #expect(throws: Error.self) {
            _ = try VideoRecordingWriter(
                outputURL: linkURL,
                format: .mp4,
                pixelSize: CGSize(width: 64, height: 48),
                capturesSystemAudio: false,
                capturesMicrophone: false
            )
        }
        #expect(try Data(contentsOf: targetFile) == Data("orig".utf8))

        // 2. Finishing a writer with 0 frames throws RecordingError.noFramesCaptured and leaves no stray file.
        let emptyURL = root.appendingPathComponent("empty.mp4")
        let emptyWriter = try VideoRecordingWriter(
            outputURL: emptyURL,
            format: .mp4,
            pixelSize: CGSize(width: 64, height: 48),
            capturesSystemAudio: false,
            capturesMicrophone: false
        )
        await #expect(throws: Error.self) {
            _ = try await emptyWriter.finish()
        }
        #expect(!fm.fileExists(atPath: emptyURL.path))

        // 3. Synchronous cancelAndWait cleans up cleanly and rejects subsequent starts.
        let cancelURL = root.appendingPathComponent("cancel.mp4")
        let cancelWriter = try VideoRecordingWriter(
            outputURL: cancelURL,
            format: .mp4,
            pixelSize: CGSize(width: 64, height: 48),
            capturesSystemAudio: true,
            capturesMicrophone: true
        )
        cancelWriter.cancelAndWait()
        #expect(throws: Error.self) {
            try cancelWriter.start()
        }
        #expect(!fm.fileExists(atPath: cancelURL.path))
    }

    @Test func timelineTracksIndependentMonotonicAudioPTSPerSource() {
        var timeline = RecordingTimeline()
        let v0 = timeline.acceptVideoPTS(CMTime(seconds: 100.0, preferredTimescale: 1000))
        #expect(v0 == .zero)

        // Equal timestamps from system audio and microphone must both pass into the dual mixer.
        let t1 = CMTime(seconds: 100.5, preferredTimescale: 1000)
        let mic1 = timeline.acceptAudioPTS(t1, source: .microphone)
        let sys1 = timeline.acceptAudioPTS(t1, source: .system)
        #expect(mic1 != nil && abs((mic1?.seconds ?? -1) - 0.5) < 0.001)
        #expect(sys1 != nil && abs((sys1?.seconds ?? -1) - 0.5) < 0.001)

        // Interleaved timestamps where system runs ahead and mic arrives slightly earlier must both pass.
        let sys2 = timeline.acceptAudioPTS(CMTime(seconds: 100.70, preferredTimescale: 1000), source: .system)
        let mic2 = timeline.acceptAudioPTS(CMTime(seconds: 100.65, preferredTimescale: 1000), source: .microphone)
        #expect(sys2 != nil && abs((sys2?.seconds ?? -1) - 0.70) < 0.001)
        #expect(mic2 != nil && abs((mic2?.seconds ?? -1) - 0.65) < 0.001)

        // Regressing within the same source is still rejected.
        #expect(timeline.acceptAudioPTS(CMTime(seconds: 100.68, preferredTimescale: 1000), source: .system) == nil)
        #expect(timeline.acceptAudioPTS(CMTime(seconds: 100.60, preferredTimescale: 1000), source: .microphone) == nil)

        // Duration tracks the maximum across video, system audio, and microphone streams.
        let mic3 = timeline.acceptAudioPTS(CMTime(seconds: 102.0, preferredTimescale: 1000), source: .microphone)
        #expect(mic3 != nil)
        #expect(abs(timeline.recordedDurationSeconds - 2.0) < 0.001)
    }

    @Test func audioMixerHandlesExtremeStaleLagOversizedPushAndSingleSourceSanitize() {
        var mixer = DualAudioMixer()
        let t0 = CMTime(seconds: 0.0, preferredTimescale: 48_000)
        #expect(mixer.pushMicrophone([Float](repeating: 0.4, count: 400), pts: t0).isEmpty)

        // Extreme PTS jump (> Int.max / 2 samples) must not overflow/trap; it must clear stale mic samples.
        let extremePTS = CMTime(seconds: 1e12, preferredTimescale: 1)
        let sysAfterJump = mixer.pushSystem([0.25, -0.25, 0.25, -0.25], pts: extremePTS)
        #expect(sysAfterJump.count == 1)
        #expect(abs((sysAfterJump[0].samples.first ?? 0) - 0.25) < 0.001)

        // Oversized single mic push caps cleanly to maxBufferedFloats retaining newest tail.
        var capMixer = DualAudioMixer()
        _ = capMixer.pushSystem([0.0, 0.0], pts: t0)
        var hugeChunk = [Float](repeating: 0.1, count: 4_000)
        hugeChunk.append(contentsOf: repeatElement(0.35, count: DualAudioMixer.maxBufferedFloats))
        #expect(capMixer.pushMicrophone(hugeChunk, pts: CMTime(seconds: 0.01, preferredTimescale: 48_000)).isEmpty)
        let mixedAfterCap = capMixer.pushSystem([Float](repeating: 0.15, count: 500), pts: CMTime(seconds: 0.02, preferredTimescale: 48_000))
        #expect(mixedAfterCap.count == 1)
        #expect(abs((mixedAfterCap[0].samples.first ?? 0) - 0.5) < 0.001)

        // Single-source sanitize replaces NaN/Inf with 0 and trims odd length without throwing.
        var scratch: [Float] = []
        let dirty: [Float] = [0.5, .nan, .infinity, -.infinity, -0.25]
        let clean = DualAudioMixer.sanitize(dirty[...], into: &scratch)
        #expect(clean.count == 4)
        #expect(clean[0] == 0.5 && clean[1] == 0 && clean[2] == 0 && clean[3] == 0)
    }

    @Test func gifEncoderScaledAccelerateFastPathPauseCausalOrderCancelAndErrorIdempotency() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccx-gif-opt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. Scaled BGRA CVPixelBuffer path fingerprints before scaling, uses Accelerate vImageScale without CGContext,
        //    coalesces static duplicates, and writes a valid target-sized 0600 GIF.
        let scaledURL = root.appendingPathComponent("scaled.gif")
        let scaledEncoder = try GifRecordingEncoder(outputURL: scaledURL, pixelSize: CGSize(width: 64, height: 48), fps: 15)
        let bigRed = try #require(makeTestBGRAPixelBuffer(width: 128, height: 96, r: 220, g: 30, b: 30))
        let bigBlue = try #require(makeTestBGRAPixelBuffer(width: 128, height: 96, r: 30, g: 60, b: 220))
        scaledEncoder.appendVideo(pixelBuffer: bigRed, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        scaledEncoder.appendVideo(pixelBuffer: bigRed, pts: CMTime(seconds: 0.10, preferredTimescale: 1000))
        scaledEncoder.appendVideo(pixelBuffer: bigRed, pts: CMTime(seconds: 0.20, preferredTimescale: 1000))
        scaledEncoder.appendVideo(pixelBuffer: bigBlue, pts: CMTime(seconds: 0.30, preferredTimescale: 1000))

        let scaledSummary = try await scaledEncoder.finish()
        #expect(scaledSummary.frameCount == 2)
        #expect(await scaledEncoder.debugMaterializedFrameCount() == 2)
        #expect(await scaledEncoder.debugHasAllocatedScaleContext() == false)

        let scaledSource = try #require(CGImageSourceCreateWithURL(scaledURL as CFURL, nil))
        #expect(CGImageSourceGetCount(scaledSource) == 2)
        let firstCG = try #require(CGImageSourceCreateImageAtIndex(scaledSource, 0, nil))
        #expect(firstCG.width == 64 && firstCG.height == 48)
        var st = stat()
        #expect(lstat(scaledURL.path, &st) == 0 && (st.st_mode & 0o777) == 0o600)

        // 2. Rapid pause()/resume() followed immediately by a post-resume frame stays causally ordered
        //    so pause duration is subtracted before the post-resume frame is timestamped.
        let pauseURL = root.appendingPathComponent("pause-order.gif")
        let pauseEncoder = try GifRecordingEncoder(outputURL: pauseURL, pixelSize: CGSize(width: 64, height: 48), fps: 15)
        pauseEncoder.appendVideo(pixelBuffer: bigRed, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        #expect(await pauseEncoder.debugMaterializedFrameCount() == 1)
        pauseEncoder.pause()
        try await Task.sleep(for: .milliseconds(150))
        pauseEncoder.resume()
        pauseEncoder.appendVideo(pixelBuffer: bigBlue, pts: CMTime(seconds: 0.30, preferredTimescale: 1000))
        let pauseSummary = try await pauseEncoder.finish()
        #expect(pauseSummary.frameCount == 2)
        #expect(pauseSummary.duration < 0.24)

        // 3. Repeated finish() after an error (0 frames) re-throws instead of returning success.
        let emptyURL = root.appendingPathComponent("empty.gif")
        let emptyEncoder = try GifRecordingEncoder(outputURL: emptyURL, pixelSize: CGSize(width: 32, height: 32), fps: 15)
        await #expect(throws: Error.self) {
            _ = try await emptyEncoder.finish()
        }
        await #expect(throws: Error.self) {
            _ = try await emptyEncoder.finish()
        }
        #expect(!fm.fileExists(atPath: emptyURL.path))

        // 4. Cancel before/during finalize aborts cleanly with CancellationError and removes output file.
        let cancelURL = root.appendingPathComponent("cancel-fin.gif")
        let cancelEncoder = try GifRecordingEncoder(outputURL: cancelURL, pixelSize: CGSize(width: 64, height: 48), fps: 15)
        cancelEncoder.appendVideo(pixelBuffer: bigRed, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        cancelEncoder.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelEncoder.finish()
        }
        #expect(!fm.fileExists(atPath: cancelURL.path))

        // 5. Symlink planted between init and finish is rejected before CGImageDestinationFinalize.
        let victimFile = root.appendingPathComponent("victim.txt")
        try Data("do-not-overwrite".utf8).write(to: victimFile)
        let swappedURL = root.appendingPathComponent("swapped.gif")
        let swappedEncoder = try GifRecordingEncoder(outputURL: swappedURL, pixelSize: CGSize(width: 64, height: 48), fps: 15)
        swappedEncoder.appendVideo(pixelBuffer: bigRed, pts: CMTime(seconds: 0.00, preferredTimescale: 1000))
        try fm.removeItem(at: swappedURL)
        try fm.createSymbolicLink(at: swappedURL, withDestinationURL: victimFile)
        await #expect(throws: Error.self) {
            _ = try await swappedEncoder.finish()
        }
        #expect(try Data(contentsOf: victimFile) == Data("do-not-overwrite".utf8))
    }

    @Test func fdFileSecurityProtectsSymlinkTargetsAndResolvesVarPrivateVarAliasing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccx-fd-sec-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let stageDir = root.appendingPathComponent("CCXRecordings", isDirectory: true)
        try RecordingFileSecurity.ensureSecureStagingDirectory(at: stageDir)

        // 1. restrictFilePermissions never follows symlinks to alter victim permissions.
        let victim = root.appendingPathComponent("victim.dat")
        try Data("keep".utf8).write(to: victim)
        #expect(chmod(victim.path, 0o644) == 0)
        let symlink = stageDir.appendingPathComponent("CCX-Rec-sym.mp4")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: victim)
        RecordingFileSecurity.restrictFilePermissions(at: symlink)
        var st = stat()
        #expect(lstat(victim.path, &st) == 0 && (st.st_mode & 0o777) == 0o644)

        // 2. removeRegularFileIfPresent never removes directories or symlinks.
        let nestedDir = stageDir.appendingPathComponent("CCX-Rec-dir", isDirectory: true)
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        RecordingFileSecurity.removeRegularFileIfPresent(at: nestedDir)
        RecordingFileSecurity.removeRegularFileIfPresent(at: symlink)
        #expect(fm.fileExists(atPath: nestedDir.path))
        #expect(lstat(symlink.path, &st) == 0)

        // 3. cleanupStagingDirectory matches active files across `/var` vs `/private/var` aliasing.
        let activeFile = stageDir.appendingPathComponent("CCX-Rec-aliased.mp4")
        let staleFile = stageDir.appendingPathComponent("CCX-Rec-stale.mp4")
        try Data("active".utf8).write(to: activeFile)
        try Data("stale".utf8).write(to: staleFile)
        let resolvedActive = activeFile.resolvingSymlinksInPath()
        let unaliasedStage = stageDir
        RecordingFileSecurity.cleanupStagingDirectory(
            at: unaliasedStage,
            olderThan: 0,
            activeFileURLs: [resolvedActive]
        )
        #expect(fm.fileExists(atPath: activeFile.path))
        #expect(!fm.fileExists(atPath: staleFile.path))

        // 4. createRestrictedEmptyFile enforces 0600 and rejects existing files via O_EXCL.
        let freshFile = stageDir.appendingPathComponent("CCX-Rec-fresh.gif")
        try RecordingFileSecurity.createRestrictedEmptyFile(at: freshFile)
        #expect(lstat(freshFile.path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
        #expect(throws: Error.self) {
            try RecordingFileSecurity.createRestrictedEmptyFile(at: freshFile)
        }
    }

    @Test @MainActor func streamConfigurationUses420vForVideoAndBorderPanelDropsShapeBackingDuringCapture() {
        let region = RecordingRegion(
            displayID: 1,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            localRect: CGRect(x: 100, y: 100, width: 601, height: 401),
            screenRect: CGRect(x: 100, y: 100, width: 601, height: 401),
            scale: 2
        )

        let mp4Settings60 = RecordingSettings(format: .mp4, videoFPS: 60)
        let mp4Config60 = ScreenRecordingEngine.makeStreamConfiguration(
            region: region,
            targetPixelSize: region.pixelSize(for: .mp4),
            runSettings: mp4Settings60
        )
        #expect(mp4Config60.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(mp4Config60.width >= 2 && mp4Config60.width.isMultiple(of: 2))
        #expect(mp4Config60.height >= 2 && mp4Config60.height.isMultiple(of: 2))
        #expect(mp4Config60.queueDepth == 5)

        let movSettings30 = RecordingSettings(format: .mov, videoFPS: 30)
        let movConfig30 = ScreenRecordingEngine.makeStreamConfiguration(
            region: region,
            targetPixelSize: region.pixelSize(for: .mov),
            runSettings: movSettings30
        )
        #expect(movConfig30.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(movConfig30.queueDepth == 3)

        let gifSettings = RecordingSettings(format: .gif, gifFPS: 15)
        let gifConfig = ScreenRecordingEngine.makeStreamConfiguration(
            region: region,
            targetPixelSize: region.pixelSize(for: .gif),
            runSettings: gifSettings
        )
        #expect(gifConfig.pixelFormat == kCVPixelFormatType_32BGRA)
        #expect(gifConfig.queueDepth == 3)

        // Border panel disables mouse-moved tracking and drops all CAShapeLayer backing during capture phases.
        let borderPanel = RecordingBorderPanel(region: region, topInset: 24, settings: mp4Settings60)
        defer { borderPanel.tearDown() }
        #expect(borderPanel.acceptsMouseMovedEvents)
        #expect(borderPanel.hasActiveShapeLayerBackingForTesting)

        borderPanel.prepareForCapture(region: borderPanel.currentRegion)
        #expect(!borderPanel.acceptsMouseMovedEvents)

        borderPanel.update(phase: .recording, region: borderPanel.currentRegion, settings: mp4Settings60)
        #expect(!borderPanel.acceptsMouseMovedEvents)
        #expect(!borderPanel.hasActiveShapeLayerBackingForTesting)

        borderPanel.update(phase: .paused, region: borderPanel.currentRegion, settings: mp4Settings60)
        #expect(!borderPanel.hasActiveShapeLayerBackingForTesting)

        borderPanel.update(phase: .finalizing, region: borderPanel.currentRegion, settings: mp4Settings60)
        #expect(!borderPanel.hasActiveShapeLayerBackingForTesting)
    }

    private func makeTestBGRAPixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let idx = row + x * 4
                ptr[idx] = b
                ptr[idx + 1] = g
                ptr[idx + 2] = r
                ptr[idx + 3] = 255
            }
        }
        return pb
    }

    private func makeMouseEvent(type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func makeCGImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(ctx.makeImage())
    }
}

final class VideoRecordingWriterTests: XCTestCase {
    func testWritesMP4H264WithMixedAudioAndMOVHEVCWithAudio() async throws {
        try await verifyVideoWrite(format: .mp4, expectedCodec: kCMVideoCodecType_H264)
        try await verifyVideoWrite(format: .mov, expectedCodec: kCMVideoCodecType_HEVC)
    }

    private func verifyVideoWrite(format: RecordingFormat, expectedCodec: CMVideoCodecType) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }

        let width = 160
        let height = 120
        let writer = try VideoRecordingWriter(
            outputURL: url,
            format: format,
            pixelSize: CGSize(width: width, height: height),
            capturesSystemAudio: true,
            capturesMicrophone: true
        )
        do {
            try writer.start()
        } catch {
            throw XCTSkip("AVAssetWriter start unavailable in test environment: \(error.localizedDescription)")
        }

        for frameIdx in 0..<10 {
            guard let pb = makeBGRAPixelBuffer(width: width, height: height, tone: UInt8(frameIdx * 24)) else {
                XCTFail("Failed to allocate CVPixelBuffer")
                return
            }
            let pts = CMTime(value: CMTimeValue(frameIdx), timescale: 30)
            writer.appendVideo(pixelBuffer: pb, pts: pts)

            if let sysPCM = DualAudioMixer.makePCMSampleBuffer(
                interleavedStereoFloat32: [Float](repeating: 0.1, count: 3200),
                pts: pts
            ),
               let micPCM = DualAudioMixer.makePCMSampleBuffer(
                   interleavedStereoFloat32: [Float](repeating: 0.15, count: 3200),
                   pts: pts
               ) {
                writer.appendAudio(sampleBuffer: micPCM, source: .microphone)
                writer.appendAudio(sampleBuffer: sysPCM, source: .system)
            }
        }

        let summary: (duration: TimeInterval, frameCount: Int)
        do {
            summary = try await writer.finish()
        } catch {
            let nsError = error as NSError
            if nsError.domain == AVFoundationErrorDomain || nsError.domain == NSOSStatusErrorDomain {
                throw XCTSkip("Hardware video encoder unavailable in sandboxed shell: \(error.localizedDescription)")
            }
            throw error
        }

        XCTAssertGreaterThanOrEqual(summary.frameCount, 1)
        XCTAssertGreaterThan(summary.duration, 0.15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        var st = stat()
        XCTAssertEqual(lstat(url.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)

        if let videoTrack = videoTracks.first {
            let descriptions = try await videoTrack.load(.formatDescriptions)
            if let desc = descriptions.first {
                XCTAssertEqual(CMFormatDescriptionGetMediaSubType(desc), expectedCodec)
            }
        }
    }

    func testDoubleStartThrowsCleanlyAndCancelRemovesNoFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-test-dblstart-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try VideoRecordingWriter(
            outputURL: url,
            format: .mp4,
            pixelSize: CGSize(width: 64, height: 48),
            capturesSystemAudio: false,
            capturesMicrophone: false
        )
        do {
            try writer.start()
        } catch {
            throw XCTSkip("AVAssetWriter start unavailable in sandboxed test environment: \(error.localizedDescription)")
        }
        XCTAssertThrowsError(try writer.start())
        writer.cancel()
    }

    private func makeBGRAPixelBuffer(width: Int, height: Int, tone: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, Int32(tone), CVPixelBufferGetBytesPerRow(pb) * height)
        }
        return pb
    }
}
