import Foundation
import os

/// Categorizes in-flight user workflows or UI states that gate quit and silent-update eligibility.
public enum ActivityKind: Hashable, Sendable, CaseIterable {
    case recordingSession
    case savePanel
    case backgroundExport
    case snipSession
    case ocrTask
    case pin
    case menuBarPopover
    case settingsWindow
    case onboardingWindow

    /// Whether an active item of this kind blocks process termination for silent updates.
    public var blocksTermination: Bool {
        switch self {
        case .recordingSession, .savePanel, .backgroundExport:
            true
        case .snipSession, .ocrTask, .pin, .menuBarPopover, .settingsWindow, .onboardingWindow:
            false
        }
    }

    /// Whether an active item of this kind defers idle silent update installation.
    public var blocksSilentInstall: Bool {
        true
    }
}

/// Scoped RAII activity token returned by `ActivityArbiter.begin(_:)`.
///
/// Calling `end()` releases the reservation immediately and idempotently; dropping the token
/// without calling `end()` releases it automatically on `deinit`.
public final class ActivityToken: Sendable {
    private let releaseHandler: OSAllocatedUnfairLock<(@Sendable () -> Void)?>

    fileprivate init(onRelease: @escaping @Sendable () -> Void) {
        self.releaseHandler = OSAllocatedUnfairLock(initialState: onRelease)
    }

    /// Releases the activity reservation immediately (idempotent).
    public func end() {
        let handler = releaseHandler.withLock { state -> (@Sendable () -> Void)? in
            let current = state
            state = nil
            return current
        }
        handler?()
    }

    deinit {
        end()
    }
}

/// Reference-counted, main-actor coordinator for app-wide active workflow arbitration.
@MainActor
public final class ActivityArbiter {
    /// Invoked whenever the effective active state of any `ActivityKind` flips.
    public var onStateChanged: (() -> Void)?

    private var tokenCounts: [ActivityKind: Int] = [:]
    private var activeConditions: Set<ActivityKind> = []

    public init() {}

    /// Returns whether `kind` currently has at least one active token or condition.
    public func isActive(_ kind: ActivityKind) -> Bool {
        (tokenCounts[kind] ?? 0) > 0 || activeConditions.contains(kind)
    }

    /// All currently active activity kinds.
    public var activeKinds: Set<ActivityKind> {
        var kinds = activeConditions
        for (kind, count) in tokenCounts where count > 0 {
            kinds.insert(kind)
        }
        return kinds
    }

    /// Whether no termination-blocking activity is currently in flight.
    public var canTerminateNow: Bool {
        !activeKinds.contains(where: \.blocksTermination)
    }

    /// Whether no silent-install-blocking activity is currently in flight.
    public var canInstallSilentlyNow: Bool {
        !activeKinds.contains(where: \.blocksSilentInstall)
    }

    /// Acquires a scoped token for `kind`, incrementing its active reference count until `end()` or `deinit`.
    public func begin(_ kind: ActivityKind) -> ActivityToken {
        let wasActive = isActive(kind)
        tokenCounts[kind, default: 0] += 1
        if !wasActive {
            onStateChanged?()
        }
        return ActivityToken { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.decrement(kind)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.decrement(kind)
                }
            }
        }
    }

    /// Updates a level-triggered condition for `kind`, notifying only when its effective active state flips.
    public func setCondition(_ kind: ActivityKind, active: Bool) {
        let wasActive = isActive(kind)
        if active {
            activeConditions.insert(kind)
        } else {
            activeConditions.remove(kind)
        }
        if isActive(kind) != wasActive {
            onStateChanged?()
        }
    }

    private func decrement(_ kind: ActivityKind) {
        let wasActive = isActive(kind)
        let current = tokenCounts[kind] ?? 0
        if current <= 1 {
            tokenCounts.removeValue(forKey: kind)
        } else {
            tokenCounts[kind] = current - 1
        }
        if isActive(kind) != wasActive {
            onStateChanged?()
        }
    }
}
