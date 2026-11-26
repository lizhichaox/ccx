import AppKit
import CCXCore
import Foundation

/// Observable, periodically refreshed snapshot of CCX's TCC permissions,
/// shared by the onboarding and settings windows.
@MainActor
final class PermissionStatusModel: ObservableObject {
    private static let pendingScreenRecordingRelaunchKey = "CCXPendingScreenRecordingRelaunchCheck"

    @Published private(set) var status: CCXPermissionStatus
    @Published private(set) var isCheckingScreenRecording = false
    @Published private(set) var isResettingScreenRecording = false
    @Published private(set) var mayHaveStaleScreenRecordingGrant = false

    private var isPollingEnabled = false
    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?

    init() {
        status = PermissionManager.currentStatus()
    }

    static func markPendingScreenRecordingRelaunch() {
        UserDefaults.standard.set(true, forKey: pendingScreenRecordingRelaunchKey)
    }

    static func consumePendingScreenRecordingRelaunch() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingScreenRecordingRelaunchKey) else { return false }
        UserDefaults.standard.removeObject(forKey: pendingScreenRecordingRelaunchKey)
        return true
    }

    func markSuspectedStaleScreenRecordingGrant() {
        if !status.screenRecording {
            mayHaveStaleScreenRecordingGrant = true
        }
    }

    deinit {
        pollTask?.cancel()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    private var needsPeriodicPolling: Bool {
        !status.screenRecording || !status.accessibility
    }

    func refresh() {
        let latest = PermissionManager.currentStatus()
        if latest != status {
            status = latest
        }
        if status.screenRecording && mayHaveStaleScreenRecordingGrant {
            mayHaveStaleScreenRecordingGrant = false
        }
        if isPollingEnabled {
            if needsPeriodicPolling && pollTask == nil {
                schedulePollLoop()
            } else if !needsPeriodicPolling {
                pollTask?.cancel()
                pollTask = nil
            }
        }
    }

    /// Polls every 1.5s only while required permissions are still missing, pausing
    /// once granted and refreshing immediately whenever the user switches back to CCX.
    func startPolling() {
        isPollingEnabled = true
        refresh()

        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    private func schedulePollLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled, let self else { break }
                self.refresh()
                if !self.needsPeriodicPolling {
                    self.pollTask = nil
                    break
                }
            }
        }
    }

    func stopPolling() {
        isPollingEnabled = false
        pollTask?.cancel()
        pollTask = nil
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
    }

    func requestScreenRecording() {
        PermissionManager.requestScreenRecording()
        refresh()
    }

    func requestAccessibility() {
        PermissionManager.requestAccessibility(prompt: true)
        refresh()
    }

    /// Probes ScreenCaptureKit directly and refreshes published permission state.
    func verifyScreenRecordingLive() {
        guard !isCheckingScreenRecording, !isResettingScreenRecording else { return }
        isCheckingScreenRecording = true
        Task { @MainActor [weak self] in
            defer { self?.isCheckingScreenRecording = false }
            let granted = await PermissionManager.verifyScreenRecordingLive()
            self?.refresh()
            if !granted {
                self?.mayHaveStaleScreenRecordingGrant = true
            }
        }
    }

    /// Resets CCX's stale Screen Recording TCC record (plus ungranted Accessibility if needed)
    /// and re-opens System Settings so macOS writes a fresh signature entry.
    func resetAndReopenScreenRecording(onComplete: (@MainActor (Bool) -> Void)? = nil) {
        guard !isResettingScreenRecording, !isCheckingScreenRecording else { return }
        isResettingScreenRecording = true
        Task { @MainActor [weak self] in
            defer { self?.isResettingScreenRecording = false }
            guard let self else { return }
            let screenResetOK = await PermissionManager.resetTCCPermission(.screenCapture)
            if !self.status.accessibility {
                _ = await PermissionManager.resetTCCPermission(.accessibility)
            }
            self.refresh()
            if screenResetOK {
                self.mayHaveStaleScreenRecordingGrant = false
                PermissionManager.requestScreenRecording()
                try? await Task.sleep(for: .milliseconds(150))
            }
            PermissionManager.openScreenRecordingSettings()
            onComplete?(screenResetOK)
        }
    }

    /// Verifies live ScreenCaptureKit access first, then triggers the native prompt
    /// and opens System Settings only if access is still not granted.
    func allowScreenRecording() {
        guard !isCheckingScreenRecording, !isResettingScreenRecording else { return }
        isCheckingScreenRecording = true
        Task { @MainActor [weak self] in
            defer { self?.isCheckingScreenRecording = false }
            guard let self else { return }
            let liveGranted = await PermissionManager.verifyScreenRecordingLive()
            self.refresh()
            if !liveGranted {
                PermissionManager.requestScreenRecording()
                try? await Task.sleep(for: .milliseconds(150))
                PermissionManager.openScreenRecordingSettings()
            }
        }
    }

    /// Triggers the native Accessibility prompt and opens System Settings
    /// directly when access is still not granted.
    func allowAccessibility() {
        PermissionManager.requestAccessibility(prompt: true)
        refresh()
        if !status.accessibility {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                PermissionManager.openAccessibilitySettings()
            }
        }
    }

    func openScreenRecordingSettings() {
        PermissionManager.openScreenRecordingSettings()
    }

    func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }

    func openMicrophoneSettings() {
        PermissionManager.openMicrophoneSettings()
    }
}
