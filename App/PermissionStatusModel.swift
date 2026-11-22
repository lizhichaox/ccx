import AppKit
import CPXCore
import Foundation

/// Observable, periodically refreshed snapshot of CPX's TCC permissions,
/// shared by the onboarding and settings windows.
@MainActor
final class PermissionStatusModel: ObservableObject {
    @Published private(set) var status: CPXPermissionStatus

    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    nonisolated(unsafe) private var activeObserver: NSObjectProtocol?

    init() {
        status = PermissionManager.currentStatus()
    }

    deinit {
        pollTask?.cancel()
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    func refresh() {
        let latest = PermissionManager.currentStatus()
        if latest != status {
            status = latest
        }
    }

    /// Polls every 750ms and refreshes immediately whenever the user switches
    /// back to CPX from System Settings.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }

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

    func stopPolling() {
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

    /// Triggers the native Screen Recording prompt and opens System Settings
    /// directly when access is still not granted.
    func allowScreenRecording() {
        PermissionManager.requestScreenRecording()
        refresh()
        if !status.screenRecording {
            Task { @MainActor in
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
}
