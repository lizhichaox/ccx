import CPXCore
import Foundation

/// Observable, periodically refreshed snapshot of CPX's TCC permissions,
/// shared by the onboarding and settings windows.
@MainActor
final class PermissionStatusModel: ObservableObject {
    @Published private(set) var status: CPXPermissionStatus

    private var pollTask: Task<Void, Never>?

    init() {
        status = PermissionManager.currentStatus()
    }

    func refresh() {
        let latest = PermissionManager.currentStatus()
        if latest != status {
            status = latest
        }
    }

    /// Polls once per second while a window that displays the status is open.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func requestScreenRecording() {
        PermissionManager.requestScreenRecording()
        refresh()
    }

    func requestAccessibility() {
        PermissionManager.requestAccessibility(prompt: true)
        refresh()
    }

    func openScreenRecordingSettings() {
        PermissionManager.openScreenRecordingSettings()
    }

    func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }
}
