import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Snapshot of the TCC permissions CCX relies on.
public struct CCXPermissionStatus: Equatable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var microphone: Bool

    public init(screenRecording: Bool, accessibility: Bool, microphone: Bool = false) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.microphone = microphone
    }
}

/// Queries and requests Screen Recording, Accessibility, and Microphone permissions.
@MainActor
public enum PermissionManager {
    /// Tri-state override from live ScreenCaptureKit results:
    /// - `nil`: defer to `CGPreflightScreenCaptureAccess()`.
    /// - `true`: live ScreenCaptureKit access succeeded (overrides stale-false preflight).
    /// - `false`: live ScreenCaptureKit access failed with permission denied (overrides stale-true preflight after revocation).
    private static var liveScreenRecordingOverride: Bool?

    public static func setScreenRecordingVerified(_ granted: Bool) {
        liveScreenRecordingOverride = granted
    }

    static func resetScreenRecordingOverrideForTesting() {
        liveScreenRecordingOverride = nil
    }

    public static func currentStatus() -> CCXPermissionStatus {
        let screenRecording = liveScreenRecordingOverride ?? CGPreflightScreenCaptureAccess()
        return CCXPermissionStatus(
            screenRecording: screenRecording,
            accessibility: AXIsProcessTrusted(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }

    /// Probes ScreenCaptureKit directly so both fresh macOS 15+ grants (stale-false preflight)
    /// and mid-session revocations (stale-true preflight) are detected accurately.
    public static func verifyScreenRecordingLive() async -> Bool {
        let granted = await hasLiveShareableDisplays()
        liveScreenRecordingOverride = granted
        return granted
    }

    /// Triggers the system Screen Recording prompt (first call only). Returns the current
    /// grant state; macOS only applies a new grant after the app relaunches.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        if liveScreenRecordingOverride == true
            || (liveScreenRecordingOverride == nil && CGPreflightScreenCaptureAccess()) {
            liveScreenRecordingOverride = true
            return true
        }
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            liveScreenRecordingOverride = true
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

    public static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
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
