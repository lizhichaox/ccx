import AppKit
import CoreGraphics
import OSLog
import ScreenCaptureKit

/// Errors thrown by `ScreenSnapshotEngine`.
public enum ScreenSnapshotError: Error, Sendable {
    /// No `SCDisplay` could be matched to an `NSScreen`.
    case noDisplays
    /// Every display capture failed (typically a missing Screen Recording grant).
    case captureFailed
}

/// Freezes every connected display using ScreenCaptureKit only.
///
/// - On macOS 26+, uses `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)`
///   with `SCScreenshotConfiguration` (SDR image in the display's native color space, HDR fallback).
/// - On macOS 15.x, falls back to `SCScreenshotManager.captureImage(contentFilter:configuration:)`.
public enum ScreenSnapshotEngine {
    /// Geometry of an `NSScreen` captured on the main actor before going async.
    struct ScreenGeometry: Sendable {
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }

    private static let logger = Logger(subsystem: "com.lizhichaox.cpx", category: "ScreenSnapshotEngine")

    /// Captures every active display concurrently, excluding CPX's own windows.
    @MainActor
    public static func captureAllDisplays() async throws -> [DisplaySnapshot] {
        let geometries = currentScreenGeometries()
        return try await capture(geometries: geometries)
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

    nonisolated static func capture(geometries: [CGDirectDisplayID: ScreenGeometry]) async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }

        var jobs: [(UncheckedSendableBox<SCContentFilter>, ScreenGeometry)] = []
        for display in content.displays {
            guard let geometry = geometries[display.displayID] else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            jobs.append((UncheckedSendableBox(filter), geometry))
        }
        guard !jobs.isEmpty else { throw ScreenSnapshotError.noDisplays }

        let snapshots = await withTaskGroup(of: DisplaySnapshot?.self) { group in
            for (filterBox, geometry) in jobs {
                group.addTask {
                    do {
                        let image = try await captureImage(filter: filterBox.value, geometry: geometry)
                        return DisplaySnapshot(
                            displayID: geometry.displayID,
                            screenFrame: geometry.frame,
                            backingScaleFactor: geometry.scale,
                            image: image
                        )
                    } catch {
                        logger.error("Display \(geometry.displayID) capture failed: \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            var collected: [DisplaySnapshot] = []
            for await snapshot in group {
                if let snapshot { collected.append(snapshot) }
            }
            return collected
        }
        guard !snapshots.isEmpty else { throw ScreenSnapshotError.captureFailed }
        return snapshots
    }

    nonisolated private static func captureImage(filter: SCContentFilter, geometry: ScreenGeometry) async throws -> CGImage {
        let pixelWidth = Int((geometry.frame.width * geometry.scale).rounded())
        let pixelHeight = Int((geometry.frame.height * geometry.scale).rounded())

        if #available(macOS 26.0, *) {
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
            throw ScreenSnapshotError.captureFailed
        } else {
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
}
