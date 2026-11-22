import AppKit
import ApplicationServices
import CoreGraphics
import CPXCore

/// A visible on-screen window in AppKit global coordinates.
public struct DetectedWindow: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String?
    public let layer: Int
    /// Window bounds in AppKit global coordinates (points, bottom-left origin of the primary screen).
    public let frame: CGRect

    public init(windowID: CGWindowID, ownerPID: pid_t, ownerName: String?, layer: Int, frame: CGRect) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.frame = frame
    }
}

/// Smart window / UI element detection for snip hover highlighting.
///
/// - Tier 1 (instant, synchronous): a Z-ordered `CGWindowListCopyWindowInfo` snapshot taken once
///   per session, hit-tested on every mouse move.
/// - Tier 2 (async, non-blocking): when Accessibility is trusted, `AXUIElementCopyElementAtPosition`
///   runs on a dedicated throttled background queue with a short messaging timeout. Results are
///   delivered back to the main actor; the caller keeps showing the Tier 1 rect until then.
@MainActor
public final class SmartElementDetector {
    /// Window layers treated as user content (normal, floating, modal panel).
    public nonisolated static let allowedLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow)),
        Int(CGWindowLevelForKey(.modalPanelWindow)),
    ]

    /// Front-to-back visible windows for the current session.
    public private(set) var windows: [DetectedWindow] = []
    private let excludedPID: pid_t
    private let axWorker: AXQueryWorker?

    /// - Parameter enableAccessibility: when `true` and the process is AX-trusted, Tier 2 detection is enabled.
    public init(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier, enableAccessibility: Bool = true) {
        self.excludedPID = excludingPID
        self.axWorker = enableAccessibility && AXIsProcessTrusted() ? AXQueryWorker(excludedPID: excludingPID) : nil
    }

    public var isAccessibilityEnabled: Bool { axWorker != nil }

    // MARK: - Tier 1

    /// Re-reads the on-screen window list (call once when a snip session starts, before showing overlays).
    public func refreshWindowList() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        let primaryHeight = CoordinateConverter.primaryScreenHeight(screens: NSScreen.screens.map(\.frame))
        windows = Self.parseWindowList(raw, excludingPID: excludedPID, primaryScreenHeight: primaryHeight)
    }

    /// The front-most window containing `globalPoint` (AppKit global coordinates).
    public func windowRect(at globalPoint: CGPoint) -> CGRect? {
        Self.hitTest(windows, at: globalPoint)?.frame
    }

    /// Converts raw `CGWindowListCopyWindowInfo` dictionaries into filtered, Z-ordered windows.
    public nonisolated static func parseWindowList(
        _ list: [[String: Any]],
        excludingPID: pid_t,
        primaryScreenHeight: CGFloat,
        minimumSize: CGFloat = 8
    ) -> [DetectedWindow] {
        list.compactMap { info -> DetectedWindow? in
            guard
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let quartzBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            guard pid != excludingPID, allowedLayers.contains(layer) else { return nil }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { return nil }
            guard quartzBounds.width >= minimumSize, quartzBounds.height >= minimumSize else { return nil }
            let frame = CoordinateConverter.quartzToAppKit(quartzBounds, primaryScreenHeight: primaryScreenHeight)
            return DetectedWindow(
                windowID: CGWindowID(number),
                ownerPID: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String,
                layer: layer,
                frame: frame
            )
        }
    }

    /// Returns the front-most window (first in Z-order) containing `point`.
    public nonisolated static func hitTest(_ windows: [DetectedWindow], at point: CGPoint) -> DetectedWindow? {
        windows.first { $0.frame.contains(point) }
    }

    // MARK: - Tier 2

    /// Requests the accessibility element frame under `globalPoint` (AppKit global coordinates).
    ///
    /// Requests are coalesced (latest point wins) and throttled to ~30 Hz on a background queue.
    /// `completion` runs on the main actor with the refined rect (AppKit global) and the point it was
    /// computed for, or is never called if AX is unavailable, times out, or yields an implausible rect.
    public func requestElementRect(
        at globalPoint: CGPoint,
        completion: @escaping @MainActor @Sendable (CGRect, CGPoint) -> Void
    ) {
        guard let axWorker, let targetWindow = Self.hitTest(windows, at: globalPoint) else { return }
        let primaryHeight = CoordinateConverter.primaryScreenHeight(screens: NSScreen.screens.map(\.frame))
        axWorker.enqueue(
            AXQueryWorker.Request(
                point: globalPoint,
                primaryScreenHeight: primaryHeight,
                targetPID: targetWindow.ownerPID,
                containerFrame: targetWindow.frame
            ),
            completion: completion
        )
    }

    /// Drops any queued AX query (call when the session ends).
    public func cancelPendingRequests() {
        axWorker?.cancelPending()
    }

    /// Whether an AX element rect is a plausible refinement of the Tier 1 window rect.
    public nonisolated static func isPlausibleElementRect(
        _ rect: CGRect,
        containing point: CGPoint,
        within container: CGRect?,
        minimumSize: CGFloat = 4
    ) -> Bool {
        guard rect.width >= minimumSize, rect.height >= minimumSize, rect.insetBy(dx: -1, dy: -1).contains(point) else {
            return false
        }
        if let container {
            return container.insetBy(dx: -2, dy: -2).contains(rect)
        }
        return true
    }
}

/// Serial, coalescing, throttled `AXUIElementCopyElementAtPosition` worker.
///
/// All mutable state is confined to `queue`.
final class AXQueryWorker: @unchecked Sendable {
    struct Request: Sendable {
        let point: CGPoint
        let primaryScreenHeight: CGFloat
        let targetPID: pid_t
        let containerFrame: CGRect
    }

    /// Minimum interval between AX queries (~30 Hz).
    static let minimumInterval: TimeInterval = 1.0 / 30.0
    /// AX messaging timeout; slow apps (Chromium/Electron) fall back to Tier 1 window bounds.
    static let messagingTimeout: Float = 0.04

    private let queue = DispatchQueue(label: "com.lizhichaox.cpx.ax-detector", qos: .userInteractive)
    private let excludedPID: pid_t
    private var pending: (Request, @MainActor @Sendable (CGRect, CGPoint) -> Void)?
    private var isScheduled = false
    private var lastQueryTime: TimeInterval = 0

    init(excludedPID: pid_t) {
        self.excludedPID = excludedPID
    }

    func enqueue(_ request: Request, completion: @escaping @MainActor @Sendable (CGRect, CGPoint) -> Void) {
        queue.async {
            self.pending = (request, completion)
            self.scheduleIfNeeded()
        }
    }

    func cancelPending() {
        queue.async { self.pending = nil }
    }

    private func scheduleIfNeeded() {
        guard !isScheduled, pending != nil else { return }
        isScheduled = true
        let elapsed = ProcessInfo.processInfo.systemUptime - lastQueryTime
        let delay = max(0, Self.minimumInterval - elapsed)
        queue.asyncAfter(deadline: .now() + delay) { self.drain() }
    }

    private func drain() {
        isScheduled = false
        guard let (request, completion) = pending else { return }
        pending = nil
        lastQueryTime = ProcessInfo.processInfo.systemUptime
        if let rect = query(request),
           SmartElementDetector.isPlausibleElementRect(rect, containing: request.point, within: request.containerFrame) {
            let point = request.point
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(rect, point) }
            }
        }
        scheduleIfNeeded()
    }

    private func query(_ request: Request) -> CGRect? {
        guard request.targetPID != excludedPID else { return nil }
        let quartzPoint = CoordinateConverter.appKitToQuartz(request.point, primaryScreenHeight: request.primaryScreenHeight)
        // Query the underlying app directly so CPX's own full-screen overlay panel does not shadow it.
        let appElement = AXUIElementCreateApplication(request.targetPID)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(appElement, Float(quartzPoint.x), Float(quartzPoint.y), &element)
        guard status == .success, let element else { return nil }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

        guard
            let position = Self.copyPoint(element, attribute: kAXPositionAttribute),
            let size = Self.copySize(element, attribute: kAXSizeAttribute)
        else { return nil }
        let quartzRect = CGRect(origin: position, size: size)
        return CoordinateConverter.quartzToAppKit(quartzRect, primaryScreenHeight: request.primaryScreenHeight)
    }

    private static func copyPoint(_ element: AXUIElement, attribute: String) -> CGPoint? {
        guard let axValue = copyAXValue(element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ element: AXUIElement, attribute: String) -> CGSize? {
        guard let axValue = copyAXValue(element, attribute: attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func copyAXValue(_ element: AXUIElement, attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (raw as! AXValue)
    }
}
