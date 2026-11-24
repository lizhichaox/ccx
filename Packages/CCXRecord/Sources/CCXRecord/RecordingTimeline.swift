import CoreMedia
import Foundation

/// Synchronizes video and audio sample timestamps around session start and pause/resume gaps
/// so paused segments leave zero dead time and audio/video remain strictly monotonic.
public struct RecordingTimeline: Sendable {
    public private(set) var sessionStartPTS: CMTime?
    public private(set) var isPaused = false

    private var pauseStartPTS: CMTime?
    private var pauseWallTime: CMTime?
    private var sessionStartWallTime: CMTime?
    private var totalPausedDuration: CMTime = .zero
    private var lastAdjustedVideoPTS: CMTime?
    private var lastAdjustedAudioPTS: CMTime?
    private var finalAdjustedDuration: TimeInterval?

    public init() {}

    public var recordedDurationSeconds: TimeInterval {
        let videoSeconds = lastAdjustedVideoPTS.flatMap { $0.isNumeric ? $0.seconds : nil } ?? 0
        let audioSeconds = lastAdjustedAudioPTS.flatMap { $0.isNumeric ? $0.seconds : nil } ?? 0
        let mediaMax = max(videoSeconds, audioSeconds)
        return max(0, max(mediaMax, finalAdjustedDuration ?? 0))
    }

    /// Marks the timeline paused. Passing a monotonic host `wallTime` removes the exact pause
    /// duration on `resume(at:)` even when the captured screen is static and emits zero frames.
    public mutating func pause(at wallTime: CMTime? = nil) {
        guard !isPaused else { return }
        isPaused = true
        if let wallTime, wallTime.isNumeric {
            pauseWallTime = wallTime
        }
    }

    /// Resumes the timeline after `pause(at:)`.
    public mutating func resume(at wallTime: CMTime? = nil) {
        guard isPaused else { return }
        isPaused = false
        if let wallTime, wallTime.isNumeric, let startedPause = pauseWallTime {
            pauseWallTime = nil
            pauseStartPTS = nil
            if sessionStartPTS != nil {
                let delta = CMTimeSubtract(wallTime, startedPause)
                if delta.isNumeric && delta > .zero {
                    totalPausedDuration = CMTimeAdd(totalPausedDuration, delta)
                }
            }
        } else {
            pauseWallTime = nil
        }
    }

    /// Records final recording wall-clock time so static-screen tails report accurate duration.
    public mutating func finish(at wallTime: CMTime? = nil) {
        if isPaused {
            isPaused = false
            if let wallTime, wallTime.isNumeric, let startedPause = pauseWallTime, sessionStartPTS != nil {
                let delta = CMTimeSubtract(wallTime, startedPause)
                if delta.isNumeric && delta > .zero {
                    totalPausedDuration = CMTimeAdd(totalPausedDuration, delta)
                }
            }
            pauseWallTime = nil
            pauseStartPTS = nil
        }
        if let wallTime, wallTime.isNumeric, let startWall = sessionStartWallTime, sessionStartPTS != nil {
            let elapsed = CMTimeSubtract(CMTimeSubtract(wallTime, totalPausedDuration), startWall)
            if elapsed.isNumeric && elapsed > .zero {
                finalAdjustedDuration = max(finalAdjustedDuration ?? 0, elapsed.seconds)
            }
        }
    }

    public mutating func acceptVideoPTS(_ rawPTS: CMTime, wallTime: CMTime? = nil) -> CMTime? {
        guard rawPTS.isNumeric else { return nil }

        if isPaused {
            if pauseWallTime == nil, pauseStartPTS == nil {
                pauseStartPTS = rawPTS
            }
            return nil
        }

        if let pauseStart = pauseStartPTS {
            pauseStartPTS = nil
            if sessionStartPTS != nil {
                let delta = CMTimeSubtract(rawPTS, pauseStart)
                if delta.isNumeric && delta > .zero {
                    totalPausedDuration = CMTimeAdd(totalPausedDuration, delta)
                }
            }
        }

        if sessionStartPTS == nil {
            sessionStartPTS = rawPTS
            if let wallTime, wallTime.isNumeric {
                sessionStartWallTime = wallTime
            }
        }
        guard let start = sessionStartPTS else { return nil }

        let shifted = CMTimeSubtract(rawPTS, totalPausedDuration)
        let rebased = CMTimeSubtract(shifted, start)
        guard rebased.isNumeric, rebased >= .zero else { return nil }

        if let prev = lastAdjustedVideoPTS, rebased <= prev {
            return nil
        }
        lastAdjustedVideoPTS = rebased
        return rebased
    }

    public mutating func acceptAudioPTS(_ rawPTS: CMTime) -> CMTime? {
        guard rawPTS.isNumeric else { return nil }

        if isPaused {
            if pauseWallTime == nil, pauseStartPTS == nil, sessionStartPTS != nil {
                pauseStartPTS = rawPTS
            }
            return nil
        }

        guard let start = sessionStartPTS else { return nil }

        if let pauseStart = pauseStartPTS {
            pauseStartPTS = nil
            let delta = CMTimeSubtract(rawPTS, pauseStart)
            if delta.isNumeric && delta > .zero {
                totalPausedDuration = CMTimeAdd(totalPausedDuration, delta)
            }
        }

        let shifted = CMTimeSubtract(rawPTS, totalPausedDuration)
        guard shifted.isNumeric, shifted >= start else { return nil }
        let rebased = CMTimeSubtract(shifted, start)
        guard rebased.isNumeric else { return nil }

        if let prev = lastAdjustedAudioPTS, rebased <= prev {
            return nil
        }
        lastAdjustedAudioPTS = rebased
        return rebased
    }
}
