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

    /// Frozen display snapshots together with the on-screen `SCWindow` catalog captured during
    /// the same `SCShareableContent` call (zero extra startup latency for adaptive corner masking).
    struct DisplayCaptureSession: Sendable {
        let snapshots: [DisplaySnapshot]
        let shareableWindows: [CGWindowID: UncheckedSendableBox<SCWindow>]
    }

    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "ScreenSnapshotEngine")
    /// Strongly retained transparent `CGColor` because `SCStreamConfiguration.backgroundColor`
    /// is an Objective-C `assign` (`unowned(unsafe)`) property.
    private nonisolated static let clearCGColor = CGColor(gray: 0, alpha: 0)

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
        try await captureSession(geometries: geometries, excludingWindowIDs: excludingWindowIDs).snapshots
    }

    nonisolated static func captureSession(
        geometries: [CGDirectDisplayID: ScreenGeometry],
        excludingWindowIDs: Set<CGWindowID> = [],
        includeShareableWindows: Bool = true
    ) async throws -> DisplayCaptureSession {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedWindows = excludingWindowIDs.isEmpty
            ? []
            : content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        var shareableWindows: [CGWindowID: UncheckedSendableBox<SCWindow>] = [:]
        if includeShareableWindows {
            shareableWindows.reserveCapacity(content.windows.count)
            for window in content.windows where !excludingWindowIDs.contains(window.windowID) {
                shareableWindows[window.windowID] = UncheckedSendableBox(window)
            }
        }

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
            return DisplayCaptureSession(snapshots: snapshots, shareableWindows: shareableWindows)
        }
        if let permissionError = errors.first(where: { isPermissionDeniedError($0) }) {
            throw permissionError
        }
        if let firstError = errors.first {
            throw firstError
        }
        throw ScreenSnapshotError.captureFailed
    }

    /// Reads the live Quartz bounds of a single on-screen window from WindowServer (`nil` if closed/offscreen).
    nonisolated static func liveQuartzWindowBounds(for windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = list.first,
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              isFinitePositiveRect(bounds, minimumSide: 2)
        else {
            return nil
        }
        if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
            return nil
        }
        return bounds
    }

    nonisolated static func windowBoundsMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = WindowCornerMaskExtractor.windowSizeMatchTolerance
    ) -> Bool {
        guard isFinitePositiveRect(lhs, minimumSide: 2),
              isFinitePositiveRect(rhs, minimumSide: 2),
              tolerance.isFinite,
              tolerance >= 0
        else {
            return false
        }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    nonisolated static func validateWindowSilhouetteBounds(
        expectedFrame: CGRect,
        contentSize: CGSize,
        liveBoundsBefore: CGRect?,
        liveBoundsAfter: CGRect?,
        tolerance: CGFloat = WindowCornerMaskExtractor.windowSizeMatchTolerance
    ) -> Bool {
        guard isFinitePositiveRect(expectedFrame, minimumSide: 2),
              contentSize.width.isFinite, contentSize.height.isFinite,
              abs(contentSize.width - expectedFrame.width) <= tolerance,
              abs(contentSize.height - expectedFrame.height) <= tolerance,
              let liveBoundsBefore,
              let liveBoundsAfter,
              windowBoundsMatch(liveBoundsBefore, expectedFrame, tolerance: tolerance),
              windowBoundsMatch(liveBoundsAfter, expectedFrame, tolerance: tolerance),
              windowBoundsMatch(liveBoundsBefore, liveBoundsAfter, tolerance: tolerance)
        else {
            return false
        }
        return true
    }

    nonisolated static func clampedPixelDimension(
        _ raw: CGFloat,
        minimum: Int,
        maximum: Int = 16_384
    ) -> Int? {
        guard raw.isFinite, raw >= CGFloat(minimum), maximum >= minimum else { return nil }
        return Int(min(raw, CGFloat(maximum)))
    }

    private nonisolated static func isFinitePositiveRect(_ rect: CGRect, minimumSide: CGFloat) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width >= minimumSide && rect.size.height >= minimumSide
    }

    /// Captures a single isolated window with shadow framing stripped and transparent exterior
    /// corners preserved so `WindowCornerMaskExtractor` can read its real corner geometry.
    nonisolated static func captureWindowSilhouette(
        window: SCWindow,
        scale: CGFloat
    ) async -> CGImage? {
        await captureWindowSilhouetteWithMetadata(window: window, scale: scale)?.image
    }

    nonisolated static func captureWindowSilhouetteWithMetadata(
        window: SCWindow,
        scale: CGFloat,
        expectedQuartzFrame: CGRect? = nil
    ) async -> CapturedWindowSilhouette? {
        let referenceFrame = expectedQuartzFrame ?? window.frame
        guard isFinitePositiveRect(referenceFrame, minimumSide: 2) else { return nil }
        if let expectedQuartzFrame, !windowBoundsMatch(window.frame, expectedQuartzFrame) {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let contentRect = filter.contentRect
        let effectiveScale = filter.pointPixelScale > 0
            ? CGFloat(filter.pointPixelScale)
            : (scale.isFinite && scale > 0 ? scale : 1)
        guard !contentRect.isNull,
              !contentRect.isInfinite,
              contentRect.width.isFinite,
              contentRect.height.isFinite,
              contentRect.width >= 2,
              contentRect.height >= 2,
              effectiveScale.isFinite,
              effectiveScale > 0,
              abs(contentRect.width - referenceFrame.width) <= WindowCornerMaskExtractor.windowSizeMatchTolerance,
              abs(contentRect.height - referenceFrame.height) <= WindowCornerMaskExtractor.windowSizeMatchTolerance
        else { return nil }

        // Guard before capture: reject stale SCWindow if the live window disappeared, moved, or resized.
        guard let preBounds = liveQuartzWindowBounds(for: window.windowID),
              windowBoundsMatch(preBounds, referenceFrame)
        else { return nil }

        let rawWidth = (contentRect.width * effectiveScale).rounded()
        let rawHeight = (contentRect.height * effectiveScale).rounded()
        guard let pixelWidth = clampedPixelDimension(rawWidth, minimum: 2),
              let pixelHeight = clampedPixelDimension(rawHeight, minimum: 2)
        else {
            return nil
        }

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.backgroundColor = clearCGColor
        configuration.includeChildWindows = false
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            // Guard after capture: discard letterboxed frames if the window changed mid-capture.
            let postBounds = liveQuartzWindowBounds(for: window.windowID)
            guard validateWindowSilhouetteBounds(
                expectedFrame: referenceFrame,
                contentSize: contentRect.size,
                liveBoundsBefore: preBounds,
                liveBoundsAfter: postBounds
            ) else {
                return nil
            }
            return CapturedWindowSilhouette(
                image: image,
                contentSize: contentRect.size,
                pointPixelScale: effectiveScale
            )
        } catch {
            logger.debug("Window silhouette capture failed for window \(window.windowID): \(error.localizedDescription)")
            return nil
        }
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
        guard let pixelWidth = clampedPixelDimension(rawWidth, minimum: 1),
              let pixelHeight = clampedPixelDimension(rawHeight, minimum: 1)
        else {
            throw ScreenSnapshotError.captureFailed
        }

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
                if isPermissionDeniedError(error) || error is CancellationError || Task.isCancelled {
                    throw error
                }
                logger.warning("macOS 26 captureScreenshot failed, falling back to captureImage: \(error.localizedDescription)")
            }
        }

        try Task.checkCancellation()
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
