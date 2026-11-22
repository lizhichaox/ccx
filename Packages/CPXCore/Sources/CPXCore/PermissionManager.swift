import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Snapshot of the TCC permissions CPX relies on.
public struct CPXPermissionStatus: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

/// Queries and requests Screen Recording and Accessibility permissions.
@MainActor
public enum PermissionManager {
    private static var screenRecordingVerified = false

    public static func setScreenRecordingVerified(_ granted: Bool) {
        screenRecordingVerified = granted
    }

    public static func currentStatus() -> CPXPermissionStatus {
        CPXPermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess() || screenRecordingVerified,
            accessibility: AXIsProcessTrusted()
        )
    }

    /// Probes ScreenCaptureKit directly so macOS 15+ TCC grants that
    /// `CGPreflightScreenCaptureAccess()` misses or caches as false are detected live.
    public static func verifyScreenRecordingLive() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            screenRecordingVerified = true
            return true
        }
        let granted = await hasLiveShareableDisplays()
        screenRecordingVerified = granted
        return granted
    }

    /// Triggers the system Screen Recording prompt (first call only). Returns the current
    /// grant state; macOS only applies a new grant after the app relaunches.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            screenRecordingVerified = true
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        Task.detached {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        return granted
    }

    /// Checks Accessibility trust, optionally showing the system prompt.
    @discardableResult
    public static func requestAccessibility(prompt: Bool = true) -> Bool {
        // Literal value of `kAXTrustedCheckOptionPrompt` (avoids a non-Sendable global).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    nonisolated private static func hasLiveShareableDisplays() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
