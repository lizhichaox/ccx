import AppKit
import CCXCore
import CoreGraphics
import OSLog
import ScreenCaptureKit

/// Errors thrown by `ScreenSnapshotEngine`.
public enum ScreenSnapshotError: Error, LocalizedError, Sendable {
    /// No `SCDisplay` could be matched to an `NSScreen`.
    case noDisplays
    /// Every display capture failed (typically a missing Screen Recording grant).
    case captureFailed

    public var errorDescription: String? {
        switch self {
        case .noDisplays:
            return CCXL10n.text("No active display was found.", zh: "未找到可用显示器。")
        case .captureFailed:
            return CCXL10n.text("Could not capture the screen. Please try again.", zh: "无法截取屏幕，请重试。")
        }
    }
}

/// Freezes every connected display using ScreenCaptureKit only.
///
/// - On macOS 26+, uses `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)`
///   with `SCScreenshotConfiguration` (SDR image in the display's native color space, HDR fallback)
///   and automatically falls back to `captureImage(contentFilter:configuration:)` on non-permission errors.
/// - On macOS 15.x, uses `SCScreenshotManager.captureImage(contentFilter:configuration:)`.
public enum ScreenSnapshotEngine {
    /// Geometry of an `NSScreen` captured on the main actor before going async.
    struct ScreenGeometry: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "ScreenSnapshotEngine")

    /// Returns `true` when ScreenCaptureKit reported that the user declined or lacks
    /// Screen Recording permission (`SCStreamError.userDeclined`, `-3801`).
    public static func isPermissionDeniedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userDeclined.rawValue
    }

    /// Maps ScreenCaptureKit and snapshot errors into concise, localized user-facing text.
    public static func userFacingErrorMessage(for error: Error) -> String {
        if let snapshotError = error as? ScreenSnapshotError, let description = snapshotError.errorDescription {
            return description
        }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch SCStreamError.Code(rawValue: nsError.code) {
            case .userDeclined:
                return CCXL10n.text("Screen Recording permission is required.", zh: "需要屏幕录制权限。")
            case .systemStoppedStream, .userStopped:
                return CCXL10n.text("Screen capture was stopped by the system.", zh: "屏幕捕获已被系统停止。")
            case .noDisplayList, .noCaptureSource, .noWindowList:
                return CCXL10n.text("No active display was found.", zh: "未找到可用显示器。")
            case .missingEntitlements:
                return CCXL10n.text("Screen capture permission is unavailable.", zh: "屏幕捕获权限不可用。")
            default:
                return CCXL10n.text("Could not capture the screen. Please try again.", zh: "无法截取屏幕，请重试。")
            }
        }
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if localized.isEmpty
            || localized.contains("The operation couldn’t be completed.")
            || localized.contains("The operation couldn't be completed.")
            || localized.contains("未能完成该操作") {
            return CCXL10n.text("Could not capture the screen. Please try again.", zh: "无法截取屏幕，请重试。")
        }
        return localized
    }

    /// Captures every active display concurrently, including all visible windows except `excludingWindowIDs`.
    @MainActor
    public static func captureAllDisplays(excludingWindowIDs: Set<CGWindowID> = []) async throws -> [DisplaySnapshot] {
        let geometries = currentScreenGeometries()
        return try await capture(geometries: geometries, excludingWindowIDs: excludingWindowIDs)
    }

    /// Reads `NSScreen` geometry keyed by `CGDirectDisplayID`.
    @MainActor
    static func currentScreenGeometries() -> [CGDirectDisplayID: ScreenGeometry] {
        var result: [CGDirectDisplayID: ScreenGeometry] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            result[displayID] = ScreenGeometry(
                displayID: displayID,
                frame: screen.frame,
                scale: screen.backingScaleFactor
            )
        }
        return result
    }

    nonisolated static func capture(
        geometries: [CGDirectDisplayID: ScreenGeometry],
        excludingWindowIDs: Set<CGWindowID> = []
    ) async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedWindows = excludingWindowIDs.isEmpty
            ? []
            : content.windows.filter { excludingWindowIDs.contains($0.windowID) }

        var jobs: [(UncheckedSendableBox<SCContentFilter>, ScreenGeometry)] = []
        for display in content.displays {
            guard let geometry = geometries[display.displayID] else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            jobs.append((UncheckedSendableBox(filter), geometry))
        }
        guard !jobs.isEmpty else { throw ScreenSnapshotError.noDisplays }

        let (snapshots, errors) = await withTaskGroup(of: Result<DisplaySnapshot, Error>.self) { group in
            for (filterBox, geometry) in jobs {
                group.addTask {
                    do {
                        let image = try await captureImage(filter: filterBox.value, geometry: geometry)
                        return .success(DisplaySnapshot(
                            displayID: geometry.displayID,
                            screenFrame: geometry.frame,
                            backingScaleFactor: geometry.scale,
                            image: image
                        ))
                    } catch {
                        logger.error("Display \(geometry.displayID) capture failed: \(error.localizedDescription)")
                        return .failure(error)
                    }
                }
            }
            var collected: [DisplaySnapshot] = []
            var failures: [Error] = []
            for await result in group {
                switch result {
                case .success(let snapshot):
                    collected.append(snapshot)
                case .failure(let error):
                    failures.append(error)
                }
            }
            return (collected, failures)
        }

        if !snapshots.isEmpty {
            return snapshots
        }
        if let permissionError = errors.first(where: { isPermissionDeniedError($0) }) {
            throw permissionError
        }
        if let firstError = errors.first {
            throw firstError
        }
        throw ScreenSnapshotError.captureFailed
    }

    nonisolated private static func captureImage(filter: SCContentFilter, geometry: ScreenGeometry) async throws -> CGImage {
        guard geometry.frame.width.isFinite,
              geometry.frame.height.isFinite,
              geometry.scale.isFinite,
              geometry.frame.width > 0,
              geometry.frame.height > 0,
              geometry.scale > 0
        else {
            throw ScreenSnapshotError.captureFailed
        }
        let rawWidth = (geometry.frame.width * geometry.scale).rounded()
        let rawHeight = (geometry.frame.height * geometry.scale).rounded()
        guard rawWidth.isFinite, rawHeight.isFinite, rawWidth >= 1, rawHeight >= 1 else {
            throw ScreenSnapshotError.captureFailed
        }
        let pixelWidth = min(max(1, Int(rawWidth)), 16_384)
        let pixelHeight = min(max(1, Int(rawHeight)), 16_384)

        if #available(macOS 26.0, *) {
            do {
                let configuration = SCScreenshotConfiguration()
                configuration.width = pixelWidth
                configuration.height = pixelHeight
                configuration.showsCursor = false
                configuration.ignoreShadows = false
                configuration.displayIntent = .local
                configuration.dynamicRange = .sdr
                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: configuration
                )
                if let image = output.sdrImage ?? output.hdrImage {
                    return image
                }
            } catch {
                if isPermissionDeniedError(error) { throw error }
                logger.warning("macOS 26 captureScreenshot failed, falling back to captureImage: \(error.localizedDescription)")
            }
        }

        return try await captureLegacyImage(filter: filter, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    nonisolated private static func captureLegacyImage(
        filter: SCContentFilter,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
