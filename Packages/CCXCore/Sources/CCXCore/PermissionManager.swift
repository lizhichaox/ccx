import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import os
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

/// TCC service categories that CCX can reset for its own bundle ID when macOS retains a stale
/// code-signature requirement across builds or system updates.
public enum CCXTCCService: String, CaseIterable, Equatable, Sendable {
    case screenCapture = "ScreenCapture"
    case accessibility = "Accessibility"
}

/// Queries and requests Screen Recording, Accessibility, and Microphone permissions.
@MainActor
public enum PermissionManager {
    /// Localized single-line copy for Screen Recording permission guidance and stale-TCC recovery
    /// shared across Onboarding and Settings (verified by `NSFont` pixel-width unit tests).
    public enum ScreenRecordingCopy {
        public static var guideHintDefault: String {
            CCXL10n.text("Enable CCX in Settings, then relaunch.", zh: "请在系统设置中启用 CCX 后重启")
        }

        public static var guideHintStale: String {
            CCXL10n.text("Stuck on? Reset stale entry.", zh: "已开启仍无效？重置旧权限")
        }

        public static var settingsHintDefault: String {
            CCXL10n.text("Already enabled?", zh: "已开启权限？")
        }

        public static var settingsHintRelaunch: String {
            CCXL10n.text("Relaunch after enabling.", zh: "授权后请重启 CCX")
        }

        public static var settingsHintStale: String {
            CCXL10n.text("Stuck on?", zh: "已开仍无效？")
        }

        public static var resetButtonTitle: String {
            CCXL10n.text("Reset", zh: "重置")
        }

        public static var resettingButtonTitle: String {
            CCXL10n.text("Resetting…", zh: "重置中…")
        }

        public static var resetTooltip: String {
            CCXL10n.text(
                "Reset stale macOS permission record and re-open System Settings",
                zh: "清理 macOS 旧签名权限记录并重新打开系统设置"
            )
        }
    }

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

    /// Validates a macOS reverse-DNS bundle identifier before passing it to `/usr/bin/tccutil`.
    public nonisolated static func isValidBundleIdentifier(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty,
              bundleID.count <= 255,
              !bundleID.hasPrefix("-"),
              !bundleID.hasPrefix("."),
              !bundleID.hasSuffix("."),
              !bundleID.contains(".."),
              bundleID.contains(".")
        else { return false }
        return bundleID.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) // 0-9
                || (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x61 && byte <= 0x7A) // a-z
                || byte == 0x2E // .
                || byte == 0x2D // -
        }
    }

    /// Resets macOS TCC approval for CCX's own bundle identifier via `/usr/bin/tccutil reset`,
    /// clearing stale code-signature records that cause the System Settings toggle to appear enabled
    /// while `ScreenCaptureKit` continues denying access after relaunch.
    @discardableResult
    public static func resetTCCPermission(
        _ service: CCXTCCService,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async -> Bool {
        guard let bundleIdentifier, isValidBundleIdentifier(bundleIdentifier) else {
            return false
        }
        let succeeded = await runTCCUtilReset(service: service.rawValue, bundleIdentifier: bundleIdentifier)
        if service == .screenCapture {
            liveScreenRecordingOverride = nil
        }
        return succeeded
    }

    private nonisolated static func runTCCUtilReset(service: String, bundleIdentifier: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleIdentifier]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: Bool) {
                let shouldResume = resumed.withLock { already -> Bool in
                    if already { return false }
                    already = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: result)
                }
            }

            let timeoutTask = Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if process.isRunning {
                    process.terminate()
                }
                finish(false)
            }

            process.terminationHandler = { finishedProcess in
                timeoutTask.cancel()
                finish(finishedProcess.terminationReason == .exit && finishedProcess.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                finish(false)
            }
        }
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
