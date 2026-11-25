import AppKit
import ApplicationServices
import CoreGraphics
import CCXCore
import os

/// A visible on-screen window (or extracted composite overlay card) in AppKit global coordinates.
public struct DetectedWindow: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String?
    public let layer: Int
    /// Window bounds in AppKit global coordinates (points, bottom-left origin of the primary screen).
    public let frame: CGRect
    /// Whether Tier 2 Accessibility sub-element refinement may run inside this window.
    public let allowsTier2Refinement: Bool
    /// Full backing `SCWindow` frame in AppKit global coordinates when this entry is an extracted card
    /// inside a larger transparent composite overlay (`nil` when `frame` is the full window frame).
    public let containerWindowFrame: CGRect?

    /// The backing `SCWindow` bounds corresponding to `windowID`.
    public var backingWindowFrame: CGRect { containerWindowFrame ?? frame }

    public init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        ownerName: String?,
        layer: Int,
        frame: CGRect,
        allowsTier2Refinement: Bool = true,
        containerWindowFrame: CGRect? = nil
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.frame = frame
        self.allowsTier2Refinement = allowsTier2Refinement
        self.containerWindowFrame = containerWindowFrame
    }
}

/// Resolved Z-order match linking a selection rectangle to a detected window's unoccluded corners.
public struct WindowCornerTarget: Equatable, Sendable {
    public let window: DetectedWindow
    /// Full backing `SCWindow` frame in AppKit global coordinates.
    public let backingWindowFrame: CGRect
    /// Selection corners aligned with `window.frame` (`<= 1pt`) and unobstructed by higher-Z windows.
    public let eligibleCorners: WindowCornerSet
    /// `true` when `window` is an extracted card inside a larger transparent composite overlay.
    public let isCompositeOverlayCard: Bool
}

/// Composite system overlay (such as Notification Center) tracked alongside its insertion slot
/// in the regular window Z-order.
struct OverlayWindowEntry: Sendable, Equatable {
    let window: DetectedWindow
    let zOrderIndex: Int
}

struct ParsedWindowSnapshot: Sendable, Equatable {
    let windows: [DetectedWindow]
    let overlayWindows: [OverlayWindowEntry]
}

struct OverlayExtractionResult: Sendable, Equatable {
    let cards: [CGRect]
    /// `true` when AX responded cleanly without timeouts/cancellation and confirmed zero cards,
    /// so live Tier 2 fallback should not repeatedly probe this empty overlay on every mouse move.
    let confirmedEmpty: Bool
}

struct AXNodeSnapshot: Sendable, Equatable {
    let pid: pid_t
    let role: String?
    let subrole: String?
    let identifier: String?
    let roleDescription: String?
    let frame: CGRect
    let children: [AXNodeSnapshot]
}

struct AXAncestorInfo: Sendable, Equatable {
    let pid: pid_t
    let role: String?
    let subrole: String?
    let identifier: String?
    let roleDescription: String?
    let frame: CGRect
}

/// Smart window / UI element detection for snip hover highlighting.
///
/// - Tier 1 (instant, synchronous): a Z-ordered `CGWindowListCopyWindowInfo` snapshot taken once
///   per session, augmented by pre-captured Notification Center card bounds and hit-tested on every mouse move.
/// - Tier 2 (async, non-blocking): when Accessibility is trusted, `AXUIElementCopyElementAtPosition`
///   runs on a dedicated throttled background queue with a short messaging timeout. Results are
///   delivered back to the main actor; the caller keeps showing the Tier 1 rect until then.
@MainActor
public final class SmartElementDetector {
    /// Core window layers treated as user content (normal, floating, modal panel, utility, popup menu).
    /// Additional semantic ranges (sheets/child windows `0...19`, Spotlight `23`, non-strip status
    /// popovers `25...26`, nested submenus `100...105`) are accepted by `isAllowedRegularWindow`.
    public nonisolated static let allowedLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow)),
        Int(CGWindowLevelForKey(.modalPanelWindow)),
        Int(CGWindowLevelForKey(.utilityWindow)),
        Int(CGWindowLevelForKey(.popUpMenuWindow)),
    ]

    nonisolated private static let excludedSystemOwners: Set<String> = [
        "Window Server",
        "WindowManager",
    ]

    nonisolated private static let menuBarOnlyOwners: Set<String> = [
        "Menubar",
        "MenuBarAgent",
    ]

    nonisolated private static let statusBackdropOwners: Set<String> = [
        "Control Center",
        "SystemUIServer",
    ]

    nonisolated private static let menuBarStripMaxHeight: CGFloat = 44

    nonisolated private static let cardCapableRoles: Set<String> = [
        "AXGroup",
        "AXCell",
        "AXRow",
        "AXHostingView",
        "AXButton",
        "AXLayoutItem",
    ]

    nonisolated private static let explicitNotificationLeafSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterAlert",
    ]

    nonisolated private static let explicitNotificationStackSubroles: Set<String> = [
        "AXNotificationCenterStack",
        "AXNotificationCenterAlertStack",
        "AXNotificationCenterBannerStack",
    ]

    nonisolated private static let explicitNotificationSubroles: Set<String> =
        explicitNotificationLeafSubroles.union(explicitNotificationStackSubroles)

    nonisolated private static let ignoredTier2ChromeRoles: Set<String> = [
        "AXScrollBar",
        "AXValueIndicator",
        "AXSplitter",
        "AXGrowArea",
        "AXRuler",
        "AXRulerMarker",
    ]

    nonisolated private static let leafPromotableRoles: Set<String> = [
        "AXStaticText",
        "AXImage",
    ]

    nonisolated private static let interactiveControlRoles: Set<String> = [
        "AXButton",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXRadioButton",
        "AXPopUpButton",
        "AXCheckBox",
        "AXCell",
        "AXRow",
        "AXTabButton",
        "AXDisclosureTriangle",
        "AXLink",
    ]

    nonisolated private static let semanticContainerRoles: Set<String> = [
        "AXButton",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXRadioButton",
        "AXPopUpButton",
        "AXCheckBox",
        "AXCell",
        "AXRow",
        "AXTabButton",
        "AXGroup",
        "AXToolbar",
        "AXTabGroup",
        "AXList",
        "AXWebArea",
        "AXTextArea",
        "AXTextField",
        "AXOutline",
        "AXLink",
    ]

    nonisolated static let minimumCardWidth: CGFloat = 80
    nonisolated static let minimumCardHeight: CGFloat = 40
    nonisolated private static let tinyLeafPromotionThreshold: CGFloat = 18

    /// Front-to-back visible windows (and extracted overlay cards) for the current session.
    public private(set) var windows: [DetectedWindow] = []
    private var regularWindows: [DetectedWindow] = []
    private var pendingOverlayWindows: [OverlayWindowEntry] = []
    private(set) var fallbackOverlayWindows: [OverlayWindowEntry] = []

    private let excludedPID: pid_t?
    private let excludedWindowIDs: Set<CGWindowID>
    private let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    private let axWorker: AXQueryWorker?
    private(set) var cachedPrimaryScreenHeight: CGFloat = 0
    private var snapshotGeneration: UInt64 = 0

    /// - Parameters:
    ///   - excludingPID: optional process ID to exclude from Tier 1 detection (`nil` includes all visible windows, including CCX's).
    ///   - excludingWindowIDs: specific window IDs to exclude from Tier 1 detection.
    ///   - enableAccessibility: when `true` and the process is AX-trusted, Tier 2 detection is enabled.
    public convenience init(
        excludingPID: pid_t? = nil,
        excludingWindowIDs: Set<CGWindowID> = [],
        enableAccessibility: Bool = true
    ) {
        self.init(
            excludingPID: excludingPID,
            excludingWindowIDs: excludingWindowIDs,
            enableAccessibility: enableAccessibility,
            forceAccessibilityForTesting: false
        )
    }

    init(
        excludingPID: pid_t? = nil,
        excludingWindowIDs: Set<CGWindowID> = [],
        enableAccessibility: Bool = true,
        forceAccessibilityForTesting: Bool = false,
        customAXWorker: AXQueryWorker? = nil
    ) {
        self.excludedPID = excludingPID
        self.excludedWindowIDs = excludingWindowIDs
        // Tier 2 AX always skips querying CCX's own PID because SnipOverlayPanel covers the screen while hovering.
        if let customAXWorker {
            self.axWorker = customAXWorker
        } else {
            let axActive = enableAccessibility && (forceAccessibilityForTesting || AXIsProcessTrusted())
            self.axWorker = axActive ? AXQueryWorker(excludedPID: ownPID) : nil
        }
    }

    public var isAccessibilityEnabled: Bool { axWorker != nil }

    // MARK: - Tier 1

    /// Re-reads the on-screen window list (call once when a snip session starts, before showing overlays).
    public func refreshWindowList() {
        refreshWindowList(screenFrames: NSScreen.screens.map(\.frame))
    }

    /// Re-reads the on-screen window list using a pre-captured `NSScreen` frame snapshot
    /// so window coordinates align exactly with `ScreenSnapshotEngine`.
    func refreshWindowList(screenFrames: [CGRect]) {
        snapshotGeneration &+= 1
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let raw = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        let primaryHeight = CoordinateConverter.primaryScreenHeight(screens: screenFrames)
        cachedPrimaryScreenHeight = primaryHeight
        let parsed = Self.parseWindowSnapshot(
            raw,
            excludingPID: excludedPID,
            excludingWindowIDs: excludedWindowIDs,
            primaryScreenHeight: primaryHeight,
            screenFrames: screenFrames
        )
        regularWindows = parsed.windows
        windows = parsed.windows
        pendingOverlayWindows = parsed.overlayWindows
        fallbackOverlayWindows = []
    }

    /// Pre-captures individual cards from composite system overlays (such as Notification Center)
    /// before snip overlays are presented, without blocking normal snips when no overlay is open.
    public func prepareOverlayElements() async {
        guard !pendingOverlayWindows.isEmpty else { return }
        let generation = snapshotGeneration
        let overlays = pendingOverlayWindows
        pendingOverlayWindows = []

        let primaryHeight = cachedPrimaryScreenHeight > 0
            ? cachedPrimaryScreenHeight
            : CoordinateConverter.primaryScreenHeight(screens: NSScreen.screens.map(\.frame))
        let isRightToLeft = NSApp?.userInterfaceLayoutDirection == .rightToLeft

        let extractionsByWindowID: [CGWindowID: OverlayExtractionResult]
        if isAccessibilityEnabled {
            let cancelledFlag = OSAllocatedUnfairLock(initialState: false)
            extractionsByWindowID = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let extracted = AXOverlayCardExtractor.extractCards(
                            for: overlays,
                            primaryScreenHeight: primaryHeight,
                            isRightToLeft: isRightToLeft,
                            isCancelled: { cancelledFlag.withLock { $0 } }
                        )
                        continuation.resume(returning: extracted)
                    }
                }
            } onCancel: {
                cancelledFlag.withLock { $0 = true }
            }
        } else {
            extractionsByWindowID = [:]
        }

        guard generation == snapshotGeneration, !Task.isCancelled else { return }

        var cardsByWindowID: [CGWindowID: [CGRect]] = [:]
        var confirmedEmptyIDs: Set<CGWindowID> = []
        for (windowID, result) in extractionsByWindowID {
            if !result.cards.isEmpty {
                cardsByWindowID[windowID] = result.cards
            } else if result.confirmedEmpty {
                confirmedEmptyIDs.insert(windowID)
            }
        }

        let merged = Self.mergingOverlayCards(
            regularWindows: regularWindows,
            overlays: overlays,
            cardsByWindowID: cardsByWindowID,
            confirmedEmptyWindowIDs: confirmedEmptyIDs
        )
        windows = merged.windows
        fallbackOverlayWindows = merged.fallbackOverlays
    }

    /// The front-most window or card containing `globalPoint` (AppKit global coordinates).
    public func windowRect(at globalPoint: CGPoint) -> CGRect? {
        Self.hitTest(windows, at: globalPoint)?.frame
    }

    /// The front-most `DetectedWindow` (with Z-order metadata) containing `globalPoint`.
    public func window(at globalPoint: CGPoint) -> DetectedWindow? {
        Self.hitTest(windows, at: globalPoint)
    }

    /// Resolves the front-most detected window whose outer edges align with at least one corner of
    /// `globalSelectionRect` (`<= edgeTolerance` points), excluding any corners occluded by a higher-Z window.
    public func matchingWindowCornerTarget(
        for globalSelectionRect: CGRect,
        edgeTolerance: CGFloat = 1.0,
        occlusionPatchSize: CGFloat = 24
    ) -> WindowCornerTarget? {
        Self.matchingWindowCornerTarget(
            for: globalSelectionRect,
            in: windows,
            edgeTolerance: edgeTolerance,
            occlusionPatchSize: occlusionPatchSize
        )
    }

    /// Pure Z-order window-corner matcher and occlusion checker (front-to-back order in `windows`).
    public nonisolated static func matchingWindowCornerTarget(
        for globalSelectionRect: CGRect,
        in windows: [DetectedWindow],
        edgeTolerance: CGFloat = 1.0,
        occlusionPatchSize: CGFloat = 24
    ) -> WindowCornerTarget? {
        guard !globalSelectionRect.isNull,
              !globalSelectionRect.isInfinite,
              globalSelectionRect.origin.x.isFinite,
              globalSelectionRect.origin.y.isFinite,
              globalSelectionRect.size.width.isFinite,
              globalSelectionRect.size.height.isFinite,
              globalSelectionRect.width >= 8,
              globalSelectionRect.height >= 8
        else { return nil }

        let rect = globalSelectionRect.standardized
        let tol = max(0, edgeTolerance.isFinite ? edgeTolerance : 1.0)

        for (index, candidate) in windows.enumerated() {
            let expanded = candidate.frame.insetBy(dx: -tol, dy: -tol)
            guard expanded.contains(rect) else { continue }

            let matchesLeft = abs(rect.minX - candidate.frame.minX) <= tol
            let matchesRight = abs(rect.maxX - candidate.frame.maxX) <= tol
            let matchesBottom = abs(rect.minY - candidate.frame.minY) <= tol
            let matchesTop = abs(rect.maxY - candidate.frame.maxY) <= tol

            var alignedCorners: WindowCornerSet = []
            if matchesLeft && matchesTop { alignedCorners.insert(.topLeft) }
            if matchesRight && matchesTop { alignedCorners.insert(.topRight) }
            if matchesLeft && matchesBottom { alignedCorners.insert(.bottomLeft) }
            if matchesRight && matchesBottom { alignedCorners.insert(.bottomRight) }

            guard !alignedCorners.isEmpty else {
                // `candidate` fully covers `rect` interior without matching any outer corner, so any
                // lower-Z window behind it is occluded across the entire selection.
                return nil
            }

            let eligible = unoccludedCorners(
                for: rect,
                alignedCorners: alignedCorners,
                targetIndex: index,
                in: windows,
                occlusionPatchSize: occlusionPatchSize
            )
            guard !eligible.isEmpty else { return nil }

            return WindowCornerTarget(
                window: candidate,
                backingWindowFrame: candidate.backingWindowFrame,
                eligibleCorners: eligible,
                isCompositeOverlayCard: !candidate.allowsTier2Refinement && candidate.containerWindowFrame != nil
            )
        }
        return nil
    }

    /// Removes any corner in `alignedCorners` whose corner patch is overlapped by a higher-Z window
    /// (`windows[0..<targetIndex]`), preventing corner cutouts from punching through foreground windows.
    public nonisolated static func unoccludedCorners(
        for globalSelectionRect: CGRect,
        alignedCorners: WindowCornerSet,
        targetIndex: Int,
        in windows: [DetectedWindow],
        occlusionPatchSize: CGFloat = 24
    ) -> WindowCornerSet {
        guard !alignedCorners.isEmpty, targetIndex > 0 else { return alignedCorners }
        let rect = globalSelectionRect.standardized
        let safePatch = occlusionPatchSize.isFinite && occlusionPatchSize > 0 ? occlusionPatchSize : 24
        let patchW = min(safePatch, rect.width * 0.5)
        let patchH = min(safePatch, rect.height * 0.5)
        guard patchW > 0, patchH > 0 else { return alignedCorners }

        let higherWindows = windows[0..<min(targetIndex, windows.count)]

        func isOccluded(_ patch: CGRect) -> Bool {
            for higher in higherWindows {
                let overlap = higher.frame.intersection(patch)
                if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 {
                    return true
                }
            }
            return false
        }

        var remaining = alignedCorners
        if remaining.contains(.topLeft) {
            let patch = CGRect(x: rect.minX, y: rect.maxY - patchH, width: patchW, height: patchH)
            if isOccluded(patch) { remaining.remove(.topLeft) }
        }
        if remaining.contains(.topRight) {
            let patch = CGRect(x: rect.maxX - patchW, y: rect.maxY - patchH, width: patchW, height: patchH)
            if isOccluded(patch) { remaining.remove(.topRight) }
        }
        if remaining.contains(.bottomLeft) {
            let patch = CGRect(x: rect.minX, y: rect.minY, width: patchW, height: patchH)
            if isOccluded(patch) { remaining.remove(.bottomLeft) }
        }
        if remaining.contains(.bottomRight) {
            let patch = CGRect(x: rect.maxX - patchW, y: rect.minY, width: patchW, height: patchH)
            if isOccluded(patch) { remaining.remove(.bottomRight) }
        }
        return remaining
    }

    /// Returns whether Tier 2 AX element refinement should run at `globalPoint`.
    public func shouldRequestElementRect(at globalPoint: CGPoint) -> Bool {
        guard axWorker != nil else { return false }
        let (target, overlay) = resolveTier2Targets(at: globalPoint)
        return target != nil || overlay != nil
    }

    func setDetectedStateForTesting(
        regularWindows: [DetectedWindow],
        windows: [DetectedWindow],
        fallbackOverlayWindows: [OverlayWindowEntry],
        pendingOverlayWindows: [OverlayWindowEntry] = []
    ) {
        snapshotGeneration &+= 1
        self.regularWindows = regularWindows
        self.windows = windows
        self.fallbackOverlayWindows = fallbackOverlayWindows
        self.pendingOverlayWindows = pendingOverlayWindows
    }

    private func resolveTier2Targets(
        at globalPoint: CGPoint
    ) -> (targetWindow: DetectedWindow?, overlayFallback: OverlayWindowEntry?) {
        let hit = Self.hitTest(windows, at: globalPoint)
        if let hit, !hit.allowsTier2Refinement {
            return (nil, nil)
        }

        let regularHitIndex = hit.flatMap { window in
            regularWindows.firstIndex { $0.windowID == window.windowID }
        }
        let overlayFallback = fallbackOverlayWindows.first { entry in
            guard entry.window.frame.contains(globalPoint) else { return false }
            if let regularHitIndex {
                return entry.zOrderIndex <= regularHitIndex
            }
            return true
        }

        let regularTarget: DetectedWindow?
        if let hit, hit.allowsTier2Refinement, hit.ownerPID != ownPID {
            regularTarget = hit
        } else {
            regularTarget = nil
        }

        return (regularTarget, overlayFallback)
    }

    /// Converts raw `CGWindowListCopyWindowInfo` dictionaries into filtered, Z-ordered windows.
    public nonisolated static func parseWindowList(
        _ list: [[String: Any]],
        excludingPID: pid_t? = nil,
        excludingWindowIDs: Set<CGWindowID> = [],
        primaryScreenHeight: CGFloat,
        minimumSize: CGFloat = 8
    ) -> [DetectedWindow] {
        parseWindowList(
            list,
            excludingPID: excludingPID,
            excludingWindowIDs: excludingWindowIDs,
            primaryScreenHeight: primaryScreenHeight,
            minimumSize: minimumSize,
            screenFrames: []
        )
    }

    nonisolated static func parseWindowList(
        _ list: [[String: Any]],
        excludingPID: pid_t? = nil,
        excludingWindowIDs: Set<CGWindowID> = [],
        primaryScreenHeight: CGFloat,
        minimumSize: CGFloat = 8,
        screenFrames: [CGRect]
    ) -> [DetectedWindow] {
        list.compactMap { info -> DetectedWindow? in
            guard let entry = parseWindowEntry(
                info,
                excludingPID: excludingPID,
                excludingWindowIDs: excludingWindowIDs,
                primaryScreenHeight: primaryScreenHeight,
                minimumSize: minimumSize
            ), isAllowedRegularWindow(entry, screenFrames: screenFrames) else {
                return nil
            }
            return entry
        }
    }

    nonisolated static func defaultBundleIdentifier(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    nonisolated static func parseWindowSnapshot(
        _ list: [[String: Any]],
        excludingPID: pid_t? = nil,
        excludingWindowIDs: Set<CGWindowID> = [],
        primaryScreenHeight: CGFloat,
        minimumSize: CGFloat = 8,
        screenFrames: [CGRect] = [],
        bundleIdentifierResolver: (pid_t) -> String? = defaultBundleIdentifier(for:)
    ) -> ParsedWindowSnapshot {
        var regular: [DetectedWindow] = []
        var overlays: [OverlayWindowEntry] = []
        var bundleIDCache: [pid_t: String?] = [:]

        func resolvedBundleID(for pid: pid_t) -> String? {
            if let cached = bundleIDCache[pid] {
                return cached
            }
            let resolved = bundleIdentifierResolver(pid)
            bundleIDCache[pid] = resolved
            return resolved
        }

        for info in list {
            guard let window = parseWindowEntry(
                info,
                excludingPID: excludingPID,
                excludingWindowIDs: excludingWindowIDs,
                primaryScreenHeight: primaryScreenHeight,
                minimumSize: minimumSize
            ) else { continue }

            if isNotificationCenterProcess(
                window,
                bundleIdentifierResolver: resolvedBundleID(for:)
            ) {
                if isValidCompositeOverlayGeometryAndLayer(window) {
                    overlays.append(OverlayWindowEntry(window: window, zOrderIndex: regular.count))
                }
            } else if isAllowedRegularWindow(window, screenFrames: screenFrames) {
                regular.append(window)
            }
        }

        return ParsedWindowSnapshot(windows: regular, overlayWindows: overlays)
    }

    private nonisolated static func parseWindowEntry(
        _ info: [String: Any],
        excludingPID: pid_t?,
        excludingWindowIDs: Set<CGWindowID>,
        primaryScreenHeight: CGFloat,
        minimumSize: CGFloat
    ) -> DetectedWindow? {
        guard
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
            let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
            let quartzBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        let ownerName = info[kCGWindowOwnerName as String] as? String
        if let ownerName, excludedSystemOwners.contains(ownerName) { return nil }
        let windowID = CGWindowID(number)
        if let excludingPID, pid == excludingPID { return nil }
        guard !excludingWindowIDs.contains(windowID) else { return nil }
        if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { return nil }
        guard !quartzBounds.isNull,
              !quartzBounds.isInfinite,
              quartzBounds.origin.x.isFinite,
              quartzBounds.origin.y.isFinite,
              quartzBounds.size.width.isFinite,
              quartzBounds.size.height.isFinite,
              quartzBounds.size.width >= minimumSize,
              quartzBounds.size.height >= minimumSize
        else { return nil }
        let frame = CoordinateConverter.quartzToAppKit(quartzBounds, primaryScreenHeight: primaryScreenHeight)
        return DetectedWindow(
            windowID: windowID,
            ownerPID: pid,
            ownerName: ownerName,
            layer: layer,
            frame: frame
        )
    }

    nonisolated static func isAllowedRegularWindow(
        _ window: DetectedWindow,
        screenFrames: [CGRect] = []
    ) -> Bool {
        if let owner = window.ownerName,
           owner == "Notification Center" || excludedSystemOwners.contains(owner) {
            return false
        }
        let layer = window.layer
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))         // 0
        let utilityLayer = Int(CGWindowLevelForKey(.utilityWindow))       // 19
        let spotlightLayer = 23
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))         // 25
        let popupLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))       // 101

        // Normal, sheets/child windows, floating, modal panel, utility (0...19).
        if (normalLayer...utilityLayer).contains(layer) {
            return true
        }
        // Spotlight and comparable system search/overlay panels (non-Notification Center).
        if layer == spotlightLayer {
            return true
        }
        // Control Center & MenuBarExtra/status popovers (25...26), excluding menu-bar icon strips
        // and full-screen transparent click-catcher backdrops.
        if layer == statusLayer || layer == statusLayer + 1 {
            if let owner = window.ownerName, menuBarOnlyOwners.contains(owner) {
                return false
            }
            if window.frame.height <= menuBarStripMaxHeight {
                return false
            }
            if let owner = window.ownerName,
               statusBackdropOwners.contains(owner),
               screenFrames.contains(where: { screen in
                   window.frame.width >= screen.width - 4 && window.frame.height >= screen.height - 4
               }) {
                return false
            }
            return true
        }
        // Popup menus, kCGOverlayWindowLevel (102), and nested NSMenu submenus (100...105).
        if ((popupLayer - 1)...(popupLayer + 4)).contains(layer) {
            return true
        }
        return false
    }

    private nonisolated static func isNotificationCenterProcess(
        _ window: DetectedWindow,
        bundleIdentifierResolver: (pid_t) -> String?
    ) -> Bool {
        if let owner = window.ownerName {
            if owner == "Notification Center" { return true }
            if excludedSystemOwners.contains(owner) || menuBarOnlyOwners.contains(owner) || owner == "Dock" {
                return false
            }
        }
        return bundleIdentifierResolver(window.ownerPID) == "com.apple.notificationcenterui"
    }

    private nonisolated static func isValidCompositeOverlayGeometryAndLayer(_ window: DetectedWindow) -> Bool {
        let screenSaverLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let layer = window.layer

        guard layer >= 0 && layer < screenSaverLayer else { return false }
        if layer == mainMenuLayer { return false }
        if (layer == statusLayer || layer == statusLayer + 1) && window.frame.height <= menuBarStripMaxHeight {
            return false
        }
        return window.frame.width >= minimumCardWidth && window.frame.height >= minimumCardHeight
    }

    /// Returns the front-most window (first in Z-order) containing `point`.
    public nonisolated static func hitTest(_ windows: [DetectedWindow], at point: CGPoint) -> DetectedWindow? {
        windows.first { $0.frame.contains(point) }
    }

    // MARK: - Card Extraction & Merging

    nonisolated static func isCardSized(
        _ rect: CGRect,
        in windowFrame: CGRect,
        allowExtraLarge: Bool = false
    ) -> Bool {
        guard !rect.isNull,
              !rect.isInfinite,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.size.width >= minimumCardWidth,
              rect.size.height >= minimumCardHeight
        else { return false }

        let maxWidth: CGFloat
        if windowFrame.width >= 600 {
            maxWidth = allowExtraLarge
                ? min(windowFrame.width * 0.75, 760)
                : min(windowFrame.width * 0.65, 560)
        } else {
            maxWidth = windowFrame.width + 4
        }
        guard rect.width <= maxWidth else { return false }

        let maxHeight = windowFrame.height < 650
            ? windowFrame.height + 4
            : min(windowFrame.height * 0.80, 650)
        guard rect.height <= maxHeight else { return false }

        let clipped = rect.standardized.intersection(windowFrame.insetBy(dx: -12, dy: -12))
        return !clipped.isNull && clipped.width >= minimumCardWidth && clipped.height >= minimumCardHeight
    }

    nonisolated static func extractOverlayCards(
        from root: AXNodeSnapshot,
        ownerPID: pid_t,
        windowFrame: CGRect
    ) -> [CGRect] {
        let (rawRects, _) = extractRawOverlayCards(
            from: root,
            ownerPID: ownerPID,
            windowFrame: windowFrame,
            clipRect: windowFrame
        )
        return deduplicateAndPruneCards(rawRects, in: windowFrame)
    }

    private nonisolated static func extractRawOverlayCards(
        from node: AXNodeSnapshot,
        ownerPID: pid_t,
        windowFrame: CGRect,
        clipRect: CGRect
    ) -> (rects: [CGRect], hasExplicitMarker: Bool) {
        let effectiveClip: CGRect
        if node.role == "AXScrollArea", !node.frame.isEmpty {
            let narrowed = clipRect.intersection(node.frame)
            if !narrowed.isNull, narrowed.width >= minimumCardWidth, narrowed.height >= minimumCardHeight {
                effectiveClip = narrowed
            } else {
                effectiveClip = clipRect
            }
        } else {
            effectiveClip = clipRect
        }

        func clippedCard(_ rect: CGRect) -> [CGRect] {
            let clipped = rect.standardized.intersection(effectiveClip)
            guard !clipped.isNull,
                  clipped.width >= minimumCardWidth,
                  clipped.height >= minimumCardHeight
            else { return [] }
            return [clipped]
        }

        let childMeta = node.children.map { (pid: $0.pid, frame: $0.frame) }
        if isExplicitWidgetCard(
            pid: node.pid,
            subrole: node.subrole,
            identifier: node.identifier,
            roleDescription: node.roleDescription,
            frame: node.frame,
            childrenFramesAndPIDs: childMeta,
            ownerPID: ownerPID,
            windowFrame: windowFrame
        ) {
            return (clippedCard(node.frame), true)
        }

        if isExplicitNotificationCard(
            subrole: node.subrole,
            identifier: node.identifier,
            frame: node.frame,
            windowFrame: windowFrame
        ) {
            // Only expand children for notification stacks; leaf banners/alerts remain atomic.
            if isExplicitNotificationStack(subrole: node.subrole) {
                let expanded = collectExplicitNotificationCards(
                    in: node.children,
                    ownerPID: ownerPID,
                    windowFrame: windowFrame,
                    clipRect: effectiveClip
                )
                let distinct = deduplicateWithinTolerance(expanded, tolerance: 4)
                if distinct.count >= 2 {
                    return (distinct, true)
                }
            }
            return (clippedCard(node.frame), true)
        }

        var childCards: [CGRect] = []
        var anyExplicit = false
        for child in node.children {
            let result = extractRawOverlayCards(
                from: child,
                ownerPID: ownerPID,
                windowFrame: windowFrame,
                clipRect: effectiveClip
            )
            childCards.append(contentsOf: result.rects)
            if result.hasExplicitMarker { anyExplicit = true }
        }

        if !childCards.isEmpty {
            if !anyExplicit,
               isCardSized(node.frame, in: windowFrame),
               let role = node.role,
               cardCapableRoles.contains(role),
               shouldCollapsePaddedCard(parentFrame: node.frame, childCards: childCards) {
                return (clippedCard(node.frame), false)
            }
            return (childCards, anyExplicit)
        }

        if isCardSized(node.frame, in: windowFrame),
           let role = node.role,
           cardCapableRoles.contains(role) {
            return (clippedCard(node.frame), false)
        }

        return ([], false)
    }

    /// Returns `true` when `parentFrame` is a genuine padded single card wrapping internal sub-parts
    /// (such as a Calendar 2-column widget or Batteries row stack), and `false` when `parentFrame`
    /// is a layout/section container wrapping multiple distinct standalone cards separated by gaps.
    private nonisolated static func shouldCollapsePaddedCard(
        parentFrame: CGRect,
        childCards: [CGRect]
    ) -> Bool {
        guard !childCards.isEmpty else { return false }
        let childUnion = childCards.dropFirst().reduce(childCards[0]) { $0.union($1) }

        // A true padded card insets its inner content on all four sides.
        guard childUnion.minX - parentFrame.minX >= 6,
              parentFrame.maxX - childUnion.maxX >= 6,
              childUnion.minY - parentFrame.minY >= 6,
              parentFrame.maxY - childUnion.maxY >= 6
        else { return false }

        if childCards.count >= 2 {
            // Multiple vertically separated standalone cards (e.g. notifications/widgets in a padded section).
            let tallCardChildren = childCards.filter { $0.width >= 150 && $0.height >= 68 }
            if tallCardChildren.count >= 2, hasDisjointVerticalGap(tallCardChildren, minGap: 6) {
                return false
            }
            // Side-by-side small widgets (each ~160-172pt square) inside a padded section wrapper.
            let smallWidgetChildren = childCards.filter { $0.width >= 160 && $0.height >= 150 }
            if smallWidgetChildren.count >= 2, hasDisjointHorizontalGap(smallWidgetChildren, minGap: 8) {
                return false
            }
        }
        return true
    }

    private nonisolated static func hasDisjointVerticalGap(_ rects: [CGRect], minGap: CGFloat) -> Bool {
        let sorted = rects.sorted { $0.minY < $1.minY }
        for index in 0..<(sorted.count - 1) {
            if sorted[index + 1].minY - sorted[index].maxY >= minGap {
                return true
            }
        }
        return false
    }

    private nonisolated static func hasDisjointHorizontalGap(_ rects: [CGRect], minGap: CGFloat) -> Bool {
        let sorted = rects.sorted { $0.minX < $1.minX }
        for index in 0..<(sorted.count - 1) {
            if sorted[index + 1].minX - sorted[index].maxX >= minGap {
                return true
            }
        }
        return false
    }

    private nonisolated static func collectExplicitNotificationCards(
        in nodes: [AXNodeSnapshot],
        ownerPID: pid_t,
        windowFrame: CGRect,
        clipRect: CGRect
    ) -> [CGRect] {
        var result: [CGRect] = []
        for node in nodes {
            if isExplicitNotificationCard(
                subrole: node.subrole,
                identifier: node.identifier,
                frame: node.frame,
                windowFrame: windowFrame
            ) {
                if isExplicitNotificationStack(subrole: node.subrole) {
                    let nested = collectExplicitNotificationCards(
                        in: node.children,
                        ownerPID: ownerPID,
                        windowFrame: windowFrame,
                        clipRect: clipRect
                    )
                    let distinctNested = deduplicateWithinTolerance(nested, tolerance: 4)
                    if distinctNested.count >= 2 {
                        result.append(contentsOf: distinctNested)
                        continue
                    }
                }
                let clipped = node.frame.standardized.intersection(clipRect)
                if !clipped.isNull, clipped.width >= minimumCardWidth, clipped.height >= minimumCardHeight {
                    result.append(clipped)
                }
            } else {
                result.append(contentsOf: collectExplicitNotificationCards(
                    in: node.children,
                    ownerPID: ownerPID,
                    windowFrame: windowFrame,
                    clipRect: clipRect
                ))
            }
        }
        return result
    }

    nonisolated static func selectCardFromAncestorChain(
        _ chain: [AXAncestorInfo],
        ownerPID: pid_t,
        windowFrame: CGRect
    ) -> CGRect? {
        // 1a. Prefer explicit leaf notification/widget subroles first (avoiding inner identifier false matches
        //     and parent stacks when a concrete banner/alert/widget subrole is present).
        for item in chain {
            if isExplicitNotificationLeafSubrole(item.subrole),
               isCardSized(item.frame, in: windowFrame) {
                return item.frame
            }
            if isExplicitWidgetSubrole(item.subrole),
               isCardSized(item.frame, in: windowFrame, allowExtraLarge: true) {
                return item.frame
            }
        }

        // 1b. Fall back to explicit notification stacks, card identifiers, or widget role descriptions.
        for item in chain {
            if isExplicitNotificationCard(
                subrole: item.subrole,
                identifier: item.identifier,
                frame: item.frame,
                windowFrame: windowFrame
            ) {
                return item.frame
            }
            if isExplicitWidgetMetadata(
                subrole: item.subrole,
                identifier: item.identifier,
                roleDescription: item.roleDescription,
                frame: item.frame,
                windowFrame: windowFrame
            ) {
                return item.frame
            }
        }

        // 2. If the chain crosses from a remote WidgetKit XPC PID back to Notification Center's PID,
        //    prefer the outermost card-sized remote root or its enclosing card-sized host wrapper.
        if let lastRemoteIndex = chain.lastIndex(where: { $0.pid != ownerPID }) {
            let remoteRoot = chain[lastRemoteIndex]
            if isCardSized(remoteRoot.frame, in: windowFrame, allowExtraLarge: true) {
                return remoteRoot.frame
            }
            let hostUpperBound = min(chain.count, lastRemoteIndex + 4)
            for hostIndex in (lastRemoteIndex + 1)..<hostUpperBound {
                let host = chain[hostIndex]
                guard host.pid == ownerPID else { break }
                if isCardSized(host.frame, in: windowFrame, allowExtraLarge: true) {
                    return host.frame
                }
                if !host.frame.isEmpty { break }
            }
            if let innerRemote = chain[...lastRemoteIndex].last(where: {
                $0.pid != ownerPID && isCardSized($0.frame, in: windowFrame, allowExtraLarge: true)
            }) {
                return innerRemote.frame
            }
        }

        // 3. Structural fallback: start from the innermost card-sized ancestor and only promote to
        //    an enclosing padded card wrapper (never to flush rows/stacks or tall multi-card sections).
        var best: CGRect?
        for item in chain {
            guard isCardSized(item.frame, in: windowFrame),
                  let role = item.role,
                  cardCapableRoles.contains(role)
            else { continue }

            guard let current = best else {
                best = item.frame
                continue
            }

            if framesNearlyMatch(current, item.frame, tolerance: 8) {
                if item.frame.width <= 368 && item.frame.width * item.frame.height >= current.width * current.height {
                    best = item.frame
                }
                continue
            }

            guard item.frame.insetBy(dx: -2, dy: -2).contains(current) else { continue }

            // Require genuine padding on both vertical edges and at least one horizontal edge
            // so flush 2-column rows and flush vertical notification stacks are not collapsed.
            let paddedVertically = (current.minY - item.frame.minY >= 6) && (item.frame.maxY - current.maxY >= 6)
            let paddedHorizontally = (current.minX - item.frame.minX >= 6) || (item.frame.maxX - current.maxX >= 6)
            guard paddedVertically && paddedHorizontally else { continue }

            // If `current` is already a standalone card (full-width notification/widget or small square widget),
            // do not promote it into a wider or substantially taller section container.
            let alreadyStandaloneCard =
                (current.width >= 300 && current.height >= 68) ||
                (current.width >= 160 && current.height >= 150)
            if alreadyStandaloneCard {
                let heightGrowth = item.frame.height - current.height
                if item.frame.width > 368 || heightGrowth > 60 || item.frame.height >= current.height * 1.5 {
                    continue
                }
            }

            best = item.frame
        }
        return best
    }

    nonisolated static func mergingOverlayCards(
        regularWindows: [DetectedWindow],
        overlays: [OverlayWindowEntry],
        cardsByWindowID: [CGWindowID: [CGRect]],
        confirmedEmptyWindowIDs: Set<CGWindowID> = []
    ) -> (windows: [DetectedWindow], fallbackOverlays: [OverlayWindowEntry]) {
        var overlaysByIndex: [Int: [OverlayWindowEntry]] = [:]
        for entry in overlays {
            let clampedIndex = min(max(entry.zOrderIndex, 0), regularWindows.count)
            overlaysByIndex[clampedIndex, default: []].append(entry)
        }

        var merged: [DetectedWindow] = []
        var fallback: [OverlayWindowEntry] = []

        for index in 0...regularWindows.count {
            if let bucket = overlaysByIndex[index] {
                for entry in bucket {
                    if let cards = cardsByWindowID[entry.window.windowID], !cards.isEmpty {
                        for cardFrame in cards {
                            merged.append(DetectedWindow(
                                windowID: entry.window.windowID,
                                ownerPID: entry.window.ownerPID,
                                ownerName: entry.window.ownerName,
                                layer: entry.window.layer,
                                frame: cardFrame,
                                allowsTier2Refinement: false,
                                containerWindowFrame: entry.window.frame
                            ))
                        }
                    } else if confirmedEmptyWindowIDs.contains(entry.window.windowID) {
                        continue
                    } else if entry.window.frame.width >= minimumCardWidth,
                              entry.window.frame.height >= minimumCardHeight,
                              entry.window.frame.width <= 560,
                              entry.window.frame.height <= 650 {
                        merged.append(DetectedWindow(
                            windowID: entry.window.windowID,
                            ownerPID: entry.window.ownerPID,
                            ownerName: entry.window.ownerName,
                            layer: entry.window.layer,
                            frame: entry.window.frame,
                            allowsTier2Refinement: false
                        ))
                    } else {
                        fallback.append(entry)
                    }
                }
            }
            if index < regularWindows.count {
                merged.append(regularWindows[index])
            }
        }

        return (merged, fallback)
    }

    nonisolated static func deduplicateAndPruneCards(_ rects: [CGRect], in windowFrame: CGRect) -> [CGRect] {
        var clamped: [CGRect] = []
        for rect in rects {
            let clipped = rect.standardized.intersection(windowFrame)
            guard !clipped.isNull, clipped.width >= minimumCardWidth, clipped.height >= minimumCardHeight else {
                continue
            }
            if !clamped.contains(where: { framesNearlyMatch($0, clipped, tolerance: 4) }) {
                clamped.append(clipped)
            }
        }

        let pruned = clamped.enumerated().filter { index, candidate in
            let container = candidate.insetBy(dx: -2, dy: -2)
            var containedCount = 0
            for (otherIndex, other) in clamped.enumerated() where otherIndex != index {
                if container.contains(other) && !framesNearlyMatch(candidate, other, tolerance: 4) {
                    containedCount += 1
                    if containedCount >= 2 { return false }
                }
            }
            return true
        }.map(\.element)

        return sortOverlappingSmallerFirst(pruned)
    }

    private nonisolated static func sortOverlappingSmallerFirst(_ rects: [CGRect]) -> [CGRect] {
        let count = rects.count
        guard count > 1 else { return rects }

        var adjacency = Array(repeating: [Int](), count: count)
        var indegree = Array(repeating: 0, count: count)
        var hasEdges = false

        for i in 0..<count {
            for j in (i + 1)..<count {
                let overlap = rects[i].intersection(rects[j])
                guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }
                let overlapArea = overlap.width * overlap.height
                let areaI = rects[i].width * rects[i].height
                let areaJ = rects[j].width * rects[j].height
                // Only prioritize the smaller rect when it is substantially contained inside the larger
                // rect (>= 85% overlap AND contained within 4pt). Shifted background peek cards in a
                // collapsed stack protrude outside the front card and must preserve front-to-back order.
                if areaJ < areaI - 1,
                   areaJ > 0,
                   overlapArea / areaJ >= 0.85,
                   rects[i].insetBy(dx: -4, dy: -4).contains(rects[j]) {
                    adjacency[j].append(i)
                    indegree[i] += 1
                    hasEdges = true
                } else if areaI < areaJ - 1,
                          areaI > 0,
                          overlapArea / areaI >= 0.85,
                          rects[j].insetBy(dx: -4, dy: -4).contains(rects[i]) {
                    adjacency[i].append(j)
                    indegree[j] += 1
                    hasEdges = true
                }
            }
        }

        guard hasEdges else { return rects }

        var ordered: [CGRect] = []
        ordered.reserveCapacity(count)
        var ready = (0..<count).filter { indegree[$0] == 0 }
        while !ready.isEmpty {
            ready.sort()
            let current = ready.removeFirst()
            ordered.append(rects[current])
            for next in adjacency[current] {
                indegree[next] -= 1
                if indegree[next] == 0 {
                    ready.append(next)
                }
            }
        }
        return ordered.count == count ? ordered : rects
    }

    private nonisolated static func deduplicateWithinTolerance(_ rects: [CGRect], tolerance: CGFloat) -> [CGRect] {
        var unique: [CGRect] = []
        for rect in rects where !unique.contains(where: { framesNearlyMatch($0, rect, tolerance: tolerance) }) {
            unique.append(rect)
        }
        return unique
    }

    private nonisolated static func framesNearlyMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 16) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.maxX - rhs.maxX) <= tolerance &&
            abs(lhs.maxY - rhs.maxY) <= tolerance
    }

    private nonisolated static func isExplicitWidgetSubrole(_ subrole: String?) -> Bool {
        guard let subrole else { return false }
        return subrole == "AXWidget" || subrole.lowercased().contains("widget")
    }

    private nonisolated static func isExplicitNotificationLeafSubrole(_ subrole: String?) -> Bool {
        guard let subrole else { return false }
        if explicitNotificationLeafSubroles.contains(subrole) { return true }
        let lower = subrole.lowercased()
        return lower.contains("notificationcenter")
            && !lower.contains("stack")
            && !lower.contains("window")
            && !lower.contains("systemdialog")
    }

    nonisolated static func isExplicitNotificationStack(subrole: String?) -> Bool {
        guard let subrole else { return false }
        if explicitNotificationStackSubroles.contains(subrole) { return true }
        let lower = subrole.lowercased()
        return lower.contains("notificationcenter") && lower.contains("stack")
    }

    private nonisolated static func isExplicitWidgetCard(
        pid: pid_t,
        subrole: String?,
        identifier: String?,
        roleDescription: String?,
        frame: CGRect,
        childrenFramesAndPIDs: [(pid: pid_t, frame: CGRect)],
        ownerPID: pid_t,
        windowFrame: CGRect
    ) -> Bool {
        guard isCardSized(frame, in: windowFrame, allowExtraLarge: true) else { return false }
        if pid != ownerPID { return true }
        if childrenFramesAndPIDs.contains(where: { $0.pid != ownerPID && framesNearlyMatch($0.frame, frame, tolerance: 16) }) {
            return true
        }
        return isExplicitWidgetMetadata(
            subrole: subrole,
            identifier: identifier,
            roleDescription: roleDescription,
            frame: frame,
            windowFrame: windowFrame
        )
    }

    private nonisolated static func isExplicitWidgetMetadata(
        subrole: String?,
        identifier: String?,
        roleDescription: String?,
        frame: CGRect,
        windowFrame: CGRect
    ) -> Bool {
        guard isCardSized(frame, in: windowFrame, allowExtraLarge: true) else { return false }
        if isExplicitWidgetSubrole(subrole) { return true }
        if let identifier {
            let lower = identifier.lowercased()
            let excludedWords = [
                "edit", "container", "list", "scroll", "section", "gallery",
                "content", "header", "footer", "title", "subtitle", "body",
                "chart", "icon", "image", "label", "button", "action",
            ]
            if (lower.hasPrefix("widget") || lower.contains("widget-"))
                && !excludedWords.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        if let roleDescription {
            let lower = roleDescription.lowercased()
            if lower == "widget" || lower == "小组件" || lower == "小工具" || lower == "ウィジェット" {
                return true
            }
        }
        return false
    }

    private nonisolated static func isExplicitNotificationCard(
        subrole: String?,
        identifier: String?,
        frame: CGRect,
        windowFrame: CGRect
    ) -> Bool {
        guard isCardSized(frame, in: windowFrame) else { return false }
        if let subrole {
            if explicitNotificationSubroles.contains(subrole) { return true }
            let lower = subrole.lowercased()
            if lower.contains("notificationcenter") && !lower.contains("window") && !lower.contains("systemdialog") {
                return true
            }
        }
        if let identifier {
            let lower = identifier.lowercased()
            let excludedWords = [
                "notification-center", "notificationcenter", "container", "list", "scroll",
                "header", "section", "action", "button", "body", "content", "text",
                "title", "subtitle", "icon", "image", "label", "close", "clear", "dismiss", "reply",
            ]
            if lower.contains("notification") && !excludedWords.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// Returns `true` when `node` is an atomic leaf overlay card whose internal descendants do not
    /// need to be traversed during pre-capture snapshot building.
    nonisolated static func isAtomicOverlayLeaf(
        pid: pid_t,
        subrole: String?,
        identifier: String?,
        roleDescription: String?,
        frame: CGRect,
        ownerPID: pid_t,
        windowFrame: CGRect
    ) -> Bool {
        if isExplicitWidgetMetadata(
            subrole: subrole,
            identifier: identifier,
            roleDescription: roleDescription,
            frame: frame,
            windowFrame: windowFrame
        ) {
            return true
        }
        if isExplicitNotificationCard(
            subrole: subrole,
            identifier: identifier,
            frame: frame,
            windowFrame: windowFrame
        ) && !isExplicitNotificationStack(subrole: subrole) {
            return true
        }
        return pid != ownerPID && isCardSized(frame, in: windowFrame, allowExtraLarge: true)
    }

    // MARK: - Tier 2

    /// Requests the accessibility element frame under `globalPoint` (AppKit global coordinates).
    ///
    /// Backward-compatible wrapper discarding whether the match came from a composite overlay.
    public func requestElementRect(
        at globalPoint: CGPoint,
        completion: @escaping @MainActor @Sendable (CGRect?, CGPoint) -> Void
    ) {
        requestElementRect(at: globalPoint) { rect, point, _ in
            completion(rect, point)
        }
    }

    /// Requests the accessibility element frame under `globalPoint` (AppKit global coordinates).
    ///
    /// Requests are coalesced (latest point wins) and throttled to ~30 Hz on a background queue.
    /// `completion` runs on the main actor with the refined rect, the point it was computed for,
    /// and whether the rect came from a composite system overlay fallback probe.
    public func requestElementRect(
        at globalPoint: CGPoint,
        completion: @escaping @MainActor @Sendable (CGRect?, CGPoint, Bool) -> Void
    ) {
        guard let axWorker else { return }

        let (targetWindow, overlayFallback) = resolveTier2Targets(at: globalPoint)
        guard targetWindow != nil || overlayFallback != nil else {
            axWorker.cancelPending()
            return
        }

        let primaryHeight = cachedPrimaryScreenHeight > 0
            ? cachedPrimaryScreenHeight
            : CoordinateConverter.primaryScreenHeight(screens: NSScreen.screens.map(\.frame))

        axWorker.enqueue(
            AXQueryWorker.Request(
                point: globalPoint,
                primaryScreenHeight: primaryHeight,
                targetWindow: targetWindow.map {
                    AXQueryWorker.WindowTarget(windowID: $0.windowID, pid: $0.ownerPID, containerFrame: $0.frame)
                },
                overlayFallback: overlayFallback.map {
                    AXQueryWorker.WindowTarget(windowID: $0.window.windowID, pid: $0.window.ownerPID, containerFrame: $0.window.frame)
                }
            ),
            completion: completion
        )
    }

    /// Drops any queued AX query (call when the session ends or hover leaves Tier-2 targets).
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
        guard !rect.isNull,
              !rect.isInfinite,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.size.width >= minimumSize,
              rect.size.height >= minimumSize,
              rect.insetBy(dx: -1, dy: -1).contains(point)
        else {
            return false
        }
        if let container {
            return container.insetBy(dx: -2, dy: -2).contains(rect)
        }
        return true
    }

    /// Selects and clips a semantically meaningful Tier 2 element rect from a leaf-to-root AX chain.
    ///
    /// - Skips chrome roles (`AXScrollBar`, `AXValueIndicator`, `AXSplitter`, `AXGrowArea`, etc.).
    /// - Promotes `AXStaticText` / `AXImage` inside interactive controls (buttons, menu items, cells)
    ///   and tiny leaves (`< 18x18`) up 1-2 semantic parents to reduce leaf jitter.
    /// - Clips scroll-overflowing rects against enclosing `AXScrollArea` bounds and `containerFrame`.
    /// - Rejects near-full-window rects so Tier 1 handles window-sized highlights cleanly.
    nonisolated static func selectRefinedElementRect(
        from chain: [AXAncestorInfo],
        at point: CGPoint,
        containerFrame: CGRect
    ) -> CGRect? {
        guard !chain.isEmpty,
              !containerFrame.isNull,
              !containerFrame.isInfinite,
              containerFrame.width > 0,
              containerFrame.height > 0
        else { return nil }

        // Compute effective clip bounds by intersecting containerFrame with any enclosing AXScrollArea
        // that contains the cursor.
        var clipBounds = containerFrame
        for item in chain where item.role == "AXScrollArea" {
            let f = item.frame
            guard isValidPositiveFrame(f) else { continue }
            let narrowed = clipBounds.intersection(f)
            if !narrowed.isNull,
               narrowed.width >= 8,
               narrowed.height >= 8,
               narrowed.insetBy(dx: -1, dy: -1).contains(point) {
                clipBounds = narrowed
            }
        }

        func clippedAndValid(_ raw: CGRect, minSize: CGFloat = 8) -> CGRect? {
            guard isValidPositiveFrame(raw) else { return nil }
            let clipped = raw.intersection(clipBounds)
            guard !clipped.isNull,
                  isPlausibleElementRect(clipped, containing: point, within: containerFrame, minimumSize: minSize)
            else { return nil }
            return clipped
        }

        func isNearFullWindow(_ rect: CGRect) -> Bool {
            framesNearlyMatch(rect, containerFrame, tolerance: 4)
        }

        // Find the first non-chrome, non-window/application leaf element with a valid clipped frame.
        guard let leafIndex = chain.firstIndex(where: { item in
            if let role = item.role {
                if ignoredTier2ChromeRoles.contains(role) || role == "AXWindow" || role == "AXApplication" {
                    return false
                }
            }
            return clippedAndValid(item.frame, minSize: 4) != nil
        }) else {
            return nil
        }

        let leaf = chain[leafIndex]
        guard var selected = clippedAndValid(leaf.frame, minSize: 4) else { return nil }

        let maxPromoteIndex = min(chain.count - 1, leafIndex + 2)
        if leafIndex < maxPromoteIndex {
            // 1. Promote static text / icon leaves directly inside interactive controls.
            if let leafRole = leaf.role, leafPromotableRoles.contains(leafRole) {
                for idx in (leafIndex + 1)...maxPromoteIndex {
                    let parent = chain[idx]
                    guard let parentRole = parent.role, interactiveControlRoles.contains(parentRole) else { continue }
                    if let parentClipped = clippedAndValid(parent.frame, minSize: 8), !isNearFullWindow(parentClipped) {
                        selected = parentClipped
                        break
                    }
                }
            }

            // 2. Promote tiny leaves (< 18x18) up 1-2 semantic containers.
            if selected.width < tinyLeafPromotionThreshold || selected.height < tinyLeafPromotionThreshold {
                for idx in (leafIndex + 1)...maxPromoteIndex {
                    let parent = chain[idx]
                    guard let parentRole = parent.role, semanticContainerRoles.contains(parentRole) else { continue }
                    if let parentClipped = clippedAndValid(parent.frame, minSize: tinyLeafPromotionThreshold),
                       !isNearFullWindow(parentClipped) {
                        selected = parentClipped
                        break
                    }
                }
            }
        }

        guard isPlausibleElementRect(selected, containing: point, within: containerFrame, minimumSize: 8),
              !isNearFullWindow(selected)
        else {
            return nil
        }
        return selected
    }

    private nonisolated static func isValidPositiveFrame(_ rect: CGRect) -> Bool {
        !rect.isNull &&
            !rect.isInfinite &&
            rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.size.width.isFinite &&
            rect.size.height.isFinite &&
            rect.size.width > 0 &&
            rect.size.height > 0
    }
}

// MARK: - Shared AX IPC Helpers

enum AXElementReader {
    struct NodeAttributes {
        let pid: pid_t
        let role: String?
        let subrole: String?
        let identifier: String?
        let roleDescription: String?
        let frame: CGRect?
        let parent: AXUIElement?
        let timedOut: Bool
    }

    struct LightElementAttributes {
        let pid: pid_t
        let role: String?
        let frame: CGRect?
        let parent: AXUIElement?
        let timedOut: Bool
    }

    private static let maxCoordinateMagnitude: CGFloat = 1_000_000

    private static let leafRolesToSkipChildren: Set<String> = [
        "AXStaticText",
        "AXImage",
        "AXScrollBar",
        "AXValueIndicator",
        "AXCheckBox",
        "AXMenuButton",
        "AXProgressIndicator",
        "AXSlider",
        "AXTextField",
        "AXPopUpButton",
        "AXRadioButton",
        "AXDisclosureTriangle",
    ]

    private static let visibleFirstContainerRoles: Set<String> = [
        "AXScrollArea",
        "AXList",
        "AXTable",
        "AXOutline",
        "AXCollection",
    ]

    private static func shouldFallbackFromMultiCopy(_ status: AXError) -> Bool {
        status == .notImplemented || status == .illegalArgument
    }

    static func convertQuartzFrame(
        position: CGPoint,
        size: CGSize,
        primaryScreenHeight: CGFloat
    ) -> CGRect? {
        guard position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              primaryScreenHeight.isFinite,
              size.width > 0, size.height > 0,
              abs(position.x) <= maxCoordinateMagnitude,
              abs(position.y) <= maxCoordinateMagnitude,
              size.width <= maxCoordinateMagnitude,
              size.height <= maxCoordinateMagnitude
        else { return nil }
        let quartzRect = CGRect(origin: position, size: size)
        guard !quartzRect.isNull, !quartzRect.isInfinite else { return nil }
        return CoordinateConverter.quartzToAppKit(quartzRect, primaryScreenHeight: primaryScreenHeight)
    }

    /// Detects `AXValue` entries wrapping `kAXErrorCannotComplete` inside a multi-attribute result array.
    static func containsCannotCompleteError(in values: [AnyObject]) -> Bool {
        for value in values where CFGetTypeID(value) == AXValueGetTypeID() {
            // swiftlint:disable:next force_cast
            let axValue = value as! AXValue
            guard AXValueGetType(axValue) == .axError else { continue }
            var err: AXError = .success
            if AXValueGetValue(axValue, .axError, &err), err == .cannotComplete {
                return true
            }
        }
        return false
    }

    static func readNodeAttributes(
        _ element: AXUIElement,
        primaryScreenHeight: CGFloat,
        timeout: Float,
        includeParent: Bool = false
    ) -> NodeAttributes {
        AXUIElementSetMessagingTimeout(element, timeout)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let attributes: [CFString] = includeParent
            ? ["AXRole" as CFString, "AXSubrole" as CFString, "AXIdentifier" as CFString, "AXRoleDescription" as CFString, "AXPosition" as CFString, "AXSize" as CFString, "AXParent" as CFString]
            : ["AXRole" as CFString, "AXSubrole" as CFString, "AXIdentifier" as CFString, "AXRoleDescription" as CFString, "AXPosition" as CFString, "AXSize" as CFString]

        var rawValues: CFArray?
        var role: String?
        var subrole: String?
        var identifier: String?
        var roleDescription: String?
        var position: CGPoint?
        var size: CGSize?
        var parent: AXUIElement?
        var timedOut = false

        let status = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &rawValues)
        if status == .success,
           let array = rawValues as? [AnyObject],
           array.count == attributes.count {
            if containsCannotCompleteError(in: array) {
                timedOut = true
            }
            role = array[0] as? String
            subrole = array[1] as? String
            identifier = array[2] as? String
            roleDescription = array[3] as? String
            position = extractPoint(from: array[4])
            size = extractSize(from: array[5])
            if includeParent {
                parent = extractElement(from: array[6])
            }
        } else if shouldFallbackFromMultiCopy(status) {
            role = copyString(element, attribute: "AXRole", timedOut: &timedOut)
            if !timedOut { subrole = copyString(element, attribute: "AXSubrole", timedOut: &timedOut) }
            if !timedOut { identifier = copyString(element, attribute: "AXIdentifier", timedOut: &timedOut) }
            if !timedOut { roleDescription = copyString(element, attribute: "AXRoleDescription", timedOut: &timedOut) }
            if !timedOut { position = copyPoint(element, attribute: "AXPosition", timedOut: &timedOut) }
            if !timedOut { size = copySize(element, attribute: "AXSize", timedOut: &timedOut) }
            if !timedOut && includeParent {
                parent = copyElement(element, attribute: "AXParent", timedOut: &timedOut)
            }
        } else if status == .cannotComplete {
            timedOut = true
        }

        let frame: CGRect?
        if let position, let size {
            frame = convertQuartzFrame(position: position, size: size, primaryScreenHeight: primaryScreenHeight)
        } else {
            frame = nil
        }

        return NodeAttributes(
            pid: pid,
            role: role,
            subrole: subrole,
            identifier: identifier,
            roleDescription: roleDescription,
            frame: frame,
            parent: parent,
            timedOut: timedOut
        )
    }

    static func readLightAttributesWithParent(
        _ element: AXUIElement,
        primaryScreenHeight: CGFloat,
        timeout: Float
    ) -> LightElementAttributes {
        AXUIElementSetMessagingTimeout(element, timeout)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let attributes = [
            "AXRole" as CFString,
            "AXPosition" as CFString,
            "AXSize" as CFString,
            "AXParent" as CFString,
        ] as CFArray

        var rawValues: CFArray?
        var role: String?
        var position: CGPoint?
        var size: CGSize?
        var parent: AXUIElement?
        var timedOut = false

        let status = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &rawValues)
        if status == .success,
           let array = rawValues as? [AnyObject],
           array.count == 4 {
            if containsCannotCompleteError(in: array) {
                timedOut = true
            }
            role = array[0] as? String
            position = extractPoint(from: array[1])
            size = extractSize(from: array[2])
            parent = extractElement(from: array[3])
        } else if shouldFallbackFromMultiCopy(status) {
            role = copyString(element, attribute: "AXRole", timedOut: &timedOut)
            if !timedOut { position = copyPoint(element, attribute: "AXPosition", timedOut: &timedOut) }
            if !timedOut { size = copySize(element, attribute: "AXSize", timedOut: &timedOut) }
            if !timedOut { parent = copyElement(element, attribute: "AXParent", timedOut: &timedOut) }
        } else if status == .cannotComplete {
            timedOut = true
        }

        let frame: CGRect?
        if let position, let size {
            frame = convertQuartzFrame(position: position, size: size, primaryScreenHeight: primaryScreenHeight)
        } else {
            frame = nil
        }

        return LightElementAttributes(
            pid: pid,
            role: role,
            frame: frame,
            parent: parent,
            timedOut: timedOut
        )
    }

    static func readWindows(of appElement: AXUIElement, timedOut: inout Bool) -> [AXUIElement] {
        if let windows = copyElementArray(appElement, attribute: "AXWindows", timedOut: &timedOut), !windows.isEmpty {
            return windows
        }
        guard !timedOut else { return [] }
        var fallback: [AXUIElement] = []
        if let focused = copyElement(appElement, attribute: "AXFocusedWindow", timedOut: &timedOut) {
            fallback.append(focused)
        }
        guard !timedOut else { return fallback }
        if let main = copyElement(appElement, attribute: "AXMainWindow", timedOut: &timedOut),
           !fallback.contains(where: { CFEqual($0, main) }) {
            fallback.append(main)
        }
        return fallback
    }

    static func readChildren(of element: AXUIElement, role: String?, timedOut: inout Bool) -> [AXUIElement] {
        if let role, leafRolesToSkipChildren.contains(role) {
            return []
        }
        if let role, visibleFirstContainerRoles.contains(role) {
            if let visible = copyElementArray(element, attribute: "AXVisibleChildren", timedOut: &timedOut), !visible.isEmpty {
                return visible
            }
            guard !timedOut else { return [] }
            if let children = copyElementArray(element, attribute: "AXChildren", timedOut: &timedOut), !children.isEmpty {
                return children
            }
            guard !timedOut else { return [] }
            if role == "AXScrollArea", let contents = copyElementArray(element, attribute: "AXContents", timedOut: &timedOut) {
                return contents
            }
            return []
        }
        if let children = copyElementArray(element, attribute: "AXChildren", timedOut: &timedOut), !children.isEmpty {
            return children
        }
        guard !timedOut else { return [] }
        if let visible = copyElementArray(element, attribute: "AXVisibleChildren", timedOut: &timedOut), !visible.isEmpty {
            return visible
        }
        return []
    }

    static func probeCardAtPosition(
        appElement: AXUIElement,
        ownerPID: pid_t,
        globalPoint: CGPoint,
        primaryScreenHeight: CGFloat,
        windowFrame: CGRect,
        timeout: Float,
        deadline: TimeInterval? = nil,
        isCancelled: () -> Bool = { false },
        timedOut: inout Bool
    ) -> CGRect? {
        guard !isCancelled() else { return nil }
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return nil }

        let quartzPoint = CoordinateConverter.appKitToQuartz(globalPoint, primaryScreenHeight: primaryScreenHeight)
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(appElement, Float(quartzPoint.x), Float(quartzPoint.y), &hit)
        if status == .cannotComplete {
            timedOut = true
            return nil
        }
        guard status == .success, let hit else { return nil }

        var chain: [AXAncestorInfo] = []
        chain.reserveCapacity(16)
        var clipRect = windowFrame
        var current: AXUIElement? = hit

        for _ in 0..<22 {
            guard let node = current, !isCancelled() else { break }
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { break }

            let attrs = readNodeAttributes(
                node,
                primaryScreenHeight: primaryScreenHeight,
                timeout: timeout,
                includeParent: true
            )
            if attrs.timedOut {
                timedOut = true
                break
            }
            if attrs.role == "AXApplication" { break }
            if attrs.role == "AXScrollArea", let scrollFrame = attrs.frame, !scrollFrame.isEmpty {
                let narrowed = clipRect.intersection(scrollFrame)
                if !narrowed.isNull,
                   narrowed.width >= SmartElementDetector.minimumCardWidth,
                   narrowed.height >= SmartElementDetector.minimumCardHeight,
                   narrowed.insetBy(dx: -1, dy: -1).contains(globalPoint) {
                    clipRect = narrowed
                }
            }
            chain.append(AXAncestorInfo(
                pid: attrs.pid,
                role: attrs.role,
                subrole: attrs.subrole,
                identifier: attrs.identifier,
                roleDescription: attrs.roleDescription,
                frame: attrs.frame ?? .zero
            ))
            guard let next = attrs.parent, !CFEqual(next, node) else { break }
            current = next
        }

        guard !isCancelled(),
              let candidate = SmartElementDetector.selectCardFromAncestorChain(
                  chain,
                  ownerPID: ownerPID,
                  windowFrame: windowFrame
              )
        else { return nil }

        let clipped = candidate.standardized.intersection(clipRect)
        guard !clipped.isNull,
              SmartElementDetector.isPlausibleElementRect(
                  clipped,
                  containing: globalPoint,
                  within: windowFrame,
                  minimumSize: SmartElementDetector.minimumCardHeight
              )
        else { return nil }
        return clipped
    }

    private static func copyElement(_ element: AXUIElement, attribute: String, timedOut: inout Bool) -> AXUIElement? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        if status == .cannotComplete { timedOut = true }
        guard status == .success, let raw else { return nil }
        return extractElement(from: raw as AnyObject)
    }

    private static func copyElementArray(_ element: AXUIElement, attribute: String, timedOut: inout Bool) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        if status == .cannotComplete { timedOut = true }
        guard status == .success, let array = raw as? [AnyObject] else { return nil }
        return array.compactMap(extractElement(from:))
    }

    private static func copyString(_ element: AXUIElement, attribute: String, timedOut: inout Bool) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        if status == .cannotComplete { timedOut = true }
        guard status == .success else { return nil }
        return raw as? String
    }

    private static func copyPoint(_ element: AXUIElement, attribute: String, timedOut: inout Bool) -> CGPoint? {
        guard let axValue = copyAXValue(element, attribute: attribute, timedOut: &timedOut) else { return nil }
        return extractPoint(from: axValue)
    }

    private static func copySize(_ element: AXUIElement, attribute: String, timedOut: inout Bool) -> CGSize? {
        guard let axValue = copyAXValue(element, attribute: attribute, timedOut: &timedOut) else { return nil }
        return extractSize(from: axValue)
    }

    private static func copyAXValue(_ element: AXUIElement, attribute: String, timedOut: inout Bool) -> AXValue? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        if status == .cannotComplete { timedOut = true }
        guard status == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (raw as! AXValue)
    }

    private static func extractElement(from value: AnyObject) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func extractPoint(from value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var pt = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &pt) ? pt : nil
    }

    private static func extractSize(from value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var sz = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &sz) ? sz : nil
    }
}

// MARK: - Pre-Capture Overlay Extractor

enum AXOverlayCardExtractor {
    private static let totalBudgetSeconds: TimeInterval = 0.14
    private static let perCallTimeout: Float = 0.04
    private static let maxDepth = 18
    private static let maxVisitedNodes = 350

    static func extractCards(
        for overlays: [OverlayWindowEntry],
        primaryScreenHeight: CGFloat,
        isRightToLeft: Bool,
        isCancelled: () -> Bool
    ) -> [CGWindowID: OverlayExtractionResult] {
        guard !overlays.isEmpty else { return [:] }
        let start = ProcessInfo.processInfo.systemUptime
        let globalDeadline = start + totalBudgetSeconds
        var results: [CGWindowID: OverlayExtractionResult] = [:]
        var cachedWindowsByPID: [pid_t: (app: AXUIElement, windows: [AXUIElement], timedOut: Bool)] = [:]

        for (index, entry) in overlays.enumerated() {
            guard !isCancelled(), ProcessInfo.processInfo.systemUptime < globalDeadline else { break }

            // Allocate a fair share of the remaining budget so one empty overlay cannot starve siblings.
            let remainingCount = overlays.count - index
            let remainingBudget = globalDeadline - ProcessInfo.processInfo.systemUptime
            let overlayDeadline = min(
                globalDeadline,
                ProcessInfo.processInfo.systemUptime + max(remainingBudget / Double(remainingCount), 0.05)
            )

            let pid = entry.window.ownerPID
            let appEntry: (app: AXUIElement, windows: [AXUIElement], timedOut: Bool)
            if let cached = cachedWindowsByPID[pid] {
                appEntry = cached
            } else {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, perCallTimeout)
                var readTimedOut = false
                let axWindows = AXElementReader.readWindows(of: appElement, timedOut: &readTimedOut)
                appEntry = (appElement, axWindows, readTimedOut)
                cachedWindowsByPID[pid] = appEntry
            }

            let extracted = extractCards(
                for: entry.window,
                appElement: appEntry.app,
                axWindows: appEntry.windows,
                initialTimedOut: appEntry.timedOut,
                primaryScreenHeight: primaryScreenHeight,
                isRightToLeft: isRightToLeft,
                deadline: overlayDeadline,
                isCancelled: isCancelled
            )
            results[entry.window.windowID] = extracted
        }
        return results
    }

    private static func extractCards(
        for window: DetectedWindow,
        appElement: AXUIElement,
        axWindows: [AXUIElement],
        initialTimedOut: Bool,
        primaryScreenHeight: CGFloat,
        isRightToLeft: Bool,
        deadline: TimeInterval,
        isCancelled: () -> Bool
    ) -> OverlayExtractionResult {
        var discovered: [CGRect] = []
        var visitedNodes = 0
        var sawTimeout = initialTimedOut

        for axWindow in axWindows {
            guard !isCancelled(),
                  ProcessInfo.processInfo.systemUptime < deadline,
                  visitedNodes < maxVisitedNodes
            else { break }

            // Pre-check window frame before recursing so off-screen/other-display windows cost only 1 IPC.
            visitedNodes += 1
            let rootAttrs = AXElementReader.readNodeAttributes(
                axWindow,
                primaryScreenHeight: primaryScreenHeight,
                timeout: perCallTimeout
            )
            if rootAttrs.timedOut {
                sawTimeout = true
                continue
            }
            if let rootFrame = rootAttrs.frame,
               !rootFrame.isEmpty,
               !rootFrame.intersects(window.frame.insetBy(dx: -12, dy: -12)) {
                continue
            }

            let rootSnapshot = buildSnapshotChildren(
                for: axWindow,
                attrs: rootAttrs,
                ownerPID: window.ownerPID,
                windowFrame: window.frame,
                clipRect: window.frame,
                fallbackFrame: window.frame,
                parentFrame: window.frame,
                parentHasSingleChild: true,
                primaryScreenHeight: primaryScreenHeight,
                depth: 0,
                visitedNodes: &visitedNodes,
                sawTimeout: &sawTimeout,
                deadline: deadline,
                isCancelled: isCancelled
            )
            if let rootSnapshot {
                discovered.append(contentsOf: SmartElementDetector.extractOverlayCards(
                    from: rootSnapshot,
                    ownerPID: window.ownerPID,
                    windowFrame: window.frame
                ))
            }
        }

        var cards = SmartElementDetector.deduplicateAndPruneCards(discovered, in: window.frame)

        // Run a targeted probeSweep when the tree walk found nothing OR when the tree walk may have
        // missed remote WidgetKit views (node cap reached or sparse sidebar coverage with budget left).
        let shouldProbe = cards.isEmpty ||
            (visitedNodes >= maxVisitedNodes) ||
            (window.frame.height >= 500 && cards.count <= 2)
        if shouldProbe,
           !isCancelled(),
           ProcessInfo.processInfo.systemUptime < deadline {
            let probed = probeSweep(
                appElement: appElement,
                ownerPID: window.ownerPID,
                windowFrame: window.frame,
                existingCards: cards,
                primaryScreenHeight: primaryScreenHeight,
                isRightToLeft: isRightToLeft,
                deadline: deadline,
                isCancelled: isCancelled,
                sawTimeout: &sawTimeout
            )
            if !probed.isEmpty {
                cards = SmartElementDetector.deduplicateAndPruneCards(cards + probed, in: window.frame)
            }
        }

        let completedWithinBudget = !isCancelled() && !sawTimeout && ProcessInfo.processInfo.systemUptime < deadline
        return OverlayExtractionResult(
            cards: cards,
            confirmedEmpty: cards.isEmpty && completedWithinBudget
        )
    }

    private static func buildSnapshot(
        _ element: AXUIElement,
        ownerPID: pid_t,
        windowFrame: CGRect,
        clipRect: CGRect,
        fallbackFrame: CGRect?,
        parentFrame: CGRect,
        parentHasSingleChild: Bool,
        primaryScreenHeight: CGFloat,
        depth: Int,
        visitedNodes: inout Int,
        sawTimeout: inout Bool,
        deadline: TimeInterval,
        isCancelled: () -> Bool
    ) -> AXNodeSnapshot? {
        guard !isCancelled(),
              depth <= maxDepth,
              visitedNodes < maxVisitedNodes,
              ProcessInfo.processInfo.systemUptime < deadline
        else { return nil }

        visitedNodes += 1
        let attrs = AXElementReader.readNodeAttributes(
            element,
            primaryScreenHeight: primaryScreenHeight,
            timeout: perCallTimeout
        )
        if attrs.timedOut {
            sawTimeout = true
            return nil
        }

        return buildSnapshotChildren(
            for: element,
            attrs: attrs,
            ownerPID: ownerPID,
            windowFrame: windowFrame,
            clipRect: clipRect,
            fallbackFrame: fallbackFrame,
            parentFrame: parentFrame,
            parentHasSingleChild: parentHasSingleChild,
            primaryScreenHeight: primaryScreenHeight,
            depth: depth,
            visitedNodes: &visitedNodes,
            sawTimeout: &sawTimeout,
            deadline: deadline,
            isCancelled: isCancelled
        )
    }

    private static func buildSnapshotChildren(
        for element: AXUIElement,
        attrs: AXElementReader.NodeAttributes,
        ownerPID: pid_t,
        windowFrame: CGRect,
        clipRect: CGRect,
        fallbackFrame: CGRect?,
        parentFrame: CGRect,
        parentHasSingleChild: Bool,
        primaryScreenHeight: CGFloat,
        depth: Int,
        visitedNodes: inout Int,
        sawTimeout: inout Bool,
        deadline: TimeInterval,
        isCancelled: () -> Bool
    ) -> AXNodeSnapshot? {
        let resolvedPID = attrs.pid != 0 ? attrs.pid : ownerPID
        let isRemote = resolvedPID != ownerPID

        // Only inherit parentFrame for a remote view whose frame read failed when the parent is a
        // tight single-child host; otherwise avoid poisoning multi-widget rows/sections.
        let remoteFallback: CGRect? = (isRemote && parentHasSingleChild &&
            SmartElementDetector.isCardSized(parentFrame, in: windowFrame, allowExtraLarge: true))
            ? parentFrame
            : nil
        let resolvedFrame = attrs.frame ?? remoteFallback ?? fallbackFrame ?? .zero

        // Skip off-viewport scrolled subtrees early before recursing into their descendants.
        if depth > 0, !resolvedFrame.isEmpty,
           !resolvedFrame.intersects(clipRect.insetBy(dx: -4, dy: -4)) {
            return nil
        }

        // Never recurse across remote WidgetKit XPC boundaries or inside atomic leaf cards.
        if isRemote || SmartElementDetector.isAtomicOverlayLeaf(
            pid: resolvedPID,
            subrole: attrs.subrole,
            identifier: attrs.identifier,
            roleDescription: attrs.roleDescription,
            frame: resolvedFrame,
            ownerPID: ownerPID,
            windowFrame: windowFrame
        ) {
            return AXNodeSnapshot(
                pid: resolvedPID,
                role: attrs.role,
                subrole: attrs.subrole,
                identifier: attrs.identifier,
                roleDescription: attrs.roleDescription,
                frame: resolvedFrame,
                children: []
            )
        }

        let childClip: CGRect
        if attrs.role == "AXScrollArea", !resolvedFrame.isEmpty {
            let narrowed = clipRect.intersection(resolvedFrame)
            childClip = (!narrowed.isNull && narrowed.width >= SmartElementDetector.minimumCardWidth &&
                         narrowed.height >= SmartElementDetector.minimumCardHeight) ? narrowed : clipRect
        } else {
            childClip = clipRect
        }

        var childSnapshots: [AXNodeSnapshot] = []
        if depth < maxDepth {
            let children = AXElementReader.readChildren(of: element, role: attrs.role, timedOut: &sawTimeout)
            let isSingleChild = children.count == 1
            childSnapshots.reserveCapacity(children.count)
            for child in children {
                guard !isCancelled(),
                      visitedNodes < maxVisitedNodes,
                      ProcessInfo.processInfo.systemUptime < deadline
                else { break }
                if let childSnapshot = buildSnapshot(
                    child,
                    ownerPID: ownerPID,
                    windowFrame: windowFrame,
                    clipRect: childClip,
                    fallbackFrame: nil,
                    parentFrame: resolvedFrame,
                    parentHasSingleChild: isSingleChild,
                    primaryScreenHeight: primaryScreenHeight,
                    depth: depth + 1,
                    visitedNodes: &visitedNodes,
                    sawTimeout: &sawTimeout,
                    deadline: deadline,
                    isCancelled: isCancelled
                ) {
                    childSnapshots.append(childSnapshot)
                }
            }
        }

        return AXNodeSnapshot(
            pid: resolvedPID,
            role: attrs.role,
            subrole: attrs.subrole,
            identifier: attrs.identifier,
            roleDescription: attrs.roleDescription,
            frame: resolvedFrame,
            children: childSnapshots
        )
    }

    static func probeXColumns(for windowFrame: CGRect, isRightToLeft: Bool) -> [CGFloat] {
        let candidates = isRightToLeft
            ? [windowFrame.minX + 100, windowFrame.minX + 270]
            : [windowFrame.maxX - 100, windowFrame.maxX - 270]
        return candidates.filter { $0 > windowFrame.minX + 8 && $0 < windowFrame.maxX - 8 }
    }

    private static func probeSweep(
        appElement: AXUIElement,
        ownerPID: pid_t,
        windowFrame: CGRect,
        existingCards: [CGRect],
        primaryScreenHeight: CGFloat,
        isRightToLeft: Bool,
        deadline: TimeInterval,
        isCancelled: () -> Bool,
        sawTimeout: inout Bool
    ) -> [CGRect] {
        let probeXs = probeXColumns(for: windowFrame, isRightToLeft: isRightToLeft)
        guard !probeXs.isEmpty else { return [] }

        var discovered = existingCards
        var newlyFound: [CGRect] = []
        var y = windowFrame.maxY - 52
        while y >= windowFrame.minY + 32 {
            for x in probeXs {
                guard !isCancelled(), ProcessInfo.processInfo.systemUptime < deadline else {
                    return SmartElementDetector.deduplicateAndPruneCards(newlyFound, in: windowFrame)
                }
                let point = CGPoint(x: x, y: y)
                if discovered.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) {
                    continue
                }
                if let card = AXElementReader.probeCardAtPosition(
                    appElement: appElement,
                    ownerPID: ownerPID,
                    globalPoint: point,
                    primaryScreenHeight: primaryScreenHeight,
                    windowFrame: windowFrame,
                    timeout: perCallTimeout,
                    deadline: deadline,
                    isCancelled: isCancelled,
                    timedOut: &sawTimeout
                ) {
                    discovered.append(card)
                    newlyFound.append(card)
                }
            }
            // 36pt step guarantees even minimum-height (40pt) compact notifications cannot fall between rows.
            y -= 36
        }

        return SmartElementDetector.deduplicateAndPruneCards(newlyFound, in: windowFrame)
    }
}

// MARK: - Tier 2 Background Worker

/// Serial, coalescing, throttled `AXUIElementCopyElementAtPosition` worker.
///
/// Pending work and cancellation state are lock-protected so 120Hz `enqueue` calls overwrite in O(1)
/// without piling closures on `queue`, and `cancelPending()` invalidates in-flight IPC immediately.
final class AXQueryWorker: Sendable {
    struct WindowTarget: Sendable, Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let containerFrame: CGRect
    }

    struct Request: Sendable {
        let point: CGPoint
        let primaryScreenHeight: CGFloat
        let targetWindow: WindowTarget?
        let overlayFallback: WindowTarget?
    }

    struct QueryResult: Sendable {
        let rect: CGRect?
        let isOverlay: Bool
        let timedOut: Bool
    }

    private struct PendingWork {
        let request: Request
        let generation: UInt64
        let completion: @MainActor @Sendable (CGRect?, CGPoint, Bool) -> Void
    }

    private struct State {
        var pending: PendingWork?
        var isScheduled = false
        var lastQueryEndTime: TimeInterval = 0
        var cancelGeneration: UInt64 = 0
        var lastTargetWindowID: CGWindowID?
        var lastOverlayWindowID: CGWindowID?
        var consecutiveTimeoutsByPID: [pid_t: Int] = [:]
        var cooldownUntilByPID: [pid_t: TimeInterval] = [:]
    }

    /// Minimum interval between AX queries (~30 Hz).
    static let minimumInterval: TimeInterval = 1.0 / 30.0
    /// AX messaging timeout; slow apps (Chromium/Electron) fall back to Tier 1 window bounds.
    static let messagingTimeout: Float = 0.04
    /// Hard wall-clock budget for one live Tier 2 AX query across all ancestor hops.
    static let perQueryBudget: TimeInterval = 0.06
    private static let maxTrackedPIDs = 64

    private let queue = DispatchQueue(label: "com.lizhichaox.ccx.ax-detector", qos: .userInteractive)
    private let excludedPID: pid_t
    private let minimumInterval: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let customQueryHandler: (@Sendable (Request, @Sendable () -> Bool) -> QueryResult)?

    init(
        excludedPID: pid_t,
        minimumInterval: TimeInterval = AXQueryWorker.minimumInterval,
        queryHandler: (@Sendable (Request, @Sendable () -> Bool) -> QueryResult)? = nil
    ) {
        self.excludedPID = excludedPID
        self.minimumInterval = minimumInterval
        self.customQueryHandler = queryHandler
    }

    func enqueue(_ request: Request, completion: @escaping @MainActor @Sendable (CGRect?, CGPoint, Bool) -> Void) {
        let scheduleDelay: TimeInterval? = state.withLock { state in
            let nextTargetID = request.targetWindow?.windowID
            let nextOverlayID = request.overlayFallback?.windowID
            if state.lastTargetWindowID != nextTargetID || state.lastOverlayWindowID != nextOverlayID {
                // Target switched: invalidate any in-flight IPC from the previous window/overlay.
                // Per-PID timeout tracking is intentionally preserved across sibling windows of the same hung PID.
                state.cancelGeneration &+= 1
                state.lastTargetWindowID = nextTargetID
                state.lastOverlayWindowID = nextOverlayID
            }
            state.pending = PendingWork(
                request: request,
                generation: state.cancelGeneration,
                completion: completion
            )
            guard !state.isScheduled else { return nil }
            state.isScheduled = true
            return computeDelayLocked(state, for: request)
        }

        if let delay = scheduleDelay {
            dispatchDrain(after: delay)
        }
    }

    func cancelPending() {
        state.withLock { state in
            state.cancelGeneration &+= 1
            state.pending = nil
            state.lastTargetWindowID = nil
            state.lastOverlayWindowID = nil
        }
    }

    private static func primaryPID(for request: Request) -> pid_t? {
        request.overlayFallback?.pid ?? request.targetWindow?.pid
    }

    private func computeDelayLocked(_ state: State, for request: Request?) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let pid = request.flatMap(Self.primaryPID(for:))
        let pidTimeouts = pid.flatMap { state.consecutiveTimeoutsByPID[$0] } ?? 0
        let backoffMultiplier = pidTimeouts > 0
            ? min(Double(1 << min(pidTimeouts, 2)), 4.0)
            : 1.0
        let effectiveInterval = min(0.15, minimumInterval * backoffMultiplier)
        let elapsed = now - state.lastQueryEndTime
        var delay = max(0, effectiveInterval - elapsed)
        if let pid, let cooldownUntil = state.cooldownUntilByPID[pid], cooldownUntil > now {
            delay = max(delay, cooldownUntil - now)
        }
        return delay
    }

    private func dispatchDrain(after delay: TimeInterval) {
        if delay <= 0 {
            queue.async { [weak self] in self?.drain() }
        } else {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        let popped: PendingWork? = state.withLock { state in
            guard let work = state.pending else {
                state.isScheduled = false
                return nil
            }
            state.pending = nil
            if work.generation != state.cancelGeneration {
                state.isScheduled = false
                return nil
            }
            return work
        }
        guard let work = popped else { return }

        let workGen = work.generation
        let isCancelled: @Sendable () -> Bool = { [state] in
            state.withLock { $0.cancelGeneration != workGen }
        }

        let result: QueryResult
        if let customQueryHandler {
            result = customQueryHandler(work.request, isCancelled)
        } else {
            result = performQuery(work.request, isCancelled: isCancelled)
        }

        let (shouldDeliver, nextDelay): (Bool, TimeInterval?) = state.withLock { state in
            // Stamp end-time after IPC completes so slow apps get real cooldown instead of 100% saturation.
            let now = ProcessInfo.processInfo.systemUptime
            state.lastQueryEndTime = now
            if let pid = Self.primaryPID(for: work.request) {
                if result.timedOut {
                    let count = min((state.consecutiveTimeoutsByPID[pid] ?? 0) + 1, 4)
                    state.consecutiveTimeoutsByPID[pid] = count
                    if count >= 3 {
                        state.cooldownUntilByPID[pid] = now + min(0.5, 0.15 * Double(count - 1))
                    }
                    if state.consecutiveTimeoutsByPID.count > Self.maxTrackedPIDs {
                        state.consecutiveTimeoutsByPID.removeAll()
                        state.cooldownUntilByPID.removeAll()
                        state.consecutiveTimeoutsByPID[pid] = count
                    }
                } else {
                    state.consecutiveTimeoutsByPID.removeValue(forKey: pid)
                    state.cooldownUntilByPID.removeValue(forKey: pid)
                }
            }

            let stillValid = state.cancelGeneration == workGen
            let hasNewerPending = state.pending != nil

            let delay: TimeInterval?
            if hasNewerPending {
                state.isScheduled = true
                delay = computeDelayLocked(state, for: state.pending?.request)
            } else {
                state.isScheduled = false
                delay = nil
            }

            // Drop cancelled results and suppress stale `nil` when a newer query is already queued.
            let deliver = stillValid && !(result.rect == nil && hasNewerPending)
            return (deliver, delay)
        }

        if shouldDeliver {
            let point = work.request.point
            let completion = work.completion
            let stateLock = self.state
            let rect = result.rect
            let isOverlay = result.isOverlay
            DispatchQueue.main.async {
                let validOnMain = stateLock.withLock { $0.cancelGeneration == workGen }
                guard validOnMain else { return }
                MainActor.assumeIsolated { completion(rect, point, isOverlay) }
            }
        }

        if let nextDelay {
            dispatchDrain(after: nextDelay)
        }
    }

    private func performQuery(_ request: Request, isCancelled: () -> Bool) -> QueryResult {
        var sawTimeout = false
        let deadline = ProcessInfo.processInfo.systemUptime + Self.perQueryBudget

        if let overlay = request.overlayFallback, overlay.pid != excludedPID {
            guard !isCancelled() else { return QueryResult(rect: nil, isOverlay: false, timedOut: false) }
            let appElement = AXUIElementCreateApplication(overlay.pid)
            AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
            if let cardRect = AXElementReader.probeCardAtPosition(
                appElement: appElement,
                ownerPID: overlay.pid,
                globalPoint: request.point,
                primaryScreenHeight: request.primaryScreenHeight,
                windowFrame: overlay.containerFrame,
                timeout: Self.messagingTimeout,
                deadline: deadline,
                isCancelled: isCancelled,
                timedOut: &sawTimeout
            ) {
                return QueryResult(rect: cardRect, isOverlay: true, timedOut: sawTimeout)
            }
        }

        if let target = request.targetWindow, target.pid != excludedPID {
            guard !isCancelled(), ProcessInfo.processInfo.systemUptime < deadline else {
                return QueryResult(rect: nil, isOverlay: false, timedOut: sawTimeout)
            }
            let rect = queryRefinedElement(
                at: request.point,
                target: target,
                primaryScreenHeight: request.primaryScreenHeight,
                deadline: deadline,
                isCancelled: isCancelled,
                timedOut: &sawTimeout
            )
            return QueryResult(rect: rect, isOverlay: false, timedOut: sawTimeout)
        }

        return QueryResult(rect: nil, isOverlay: false, timedOut: sawTimeout)
    }

    private func queryRefinedElement(
        at point: CGPoint,
        target: WindowTarget,
        primaryScreenHeight: CGFloat,
        deadline: TimeInterval,
        isCancelled: () -> Bool,
        timedOut: inout Bool
    ) -> CGRect? {
        let quartzPoint = CoordinateConverter.appKitToQuartz(point, primaryScreenHeight: primaryScreenHeight)
        // Query the underlying app directly so CCX's own full-screen overlay panel does not shadow it.
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(appElement, Float(quartzPoint.x), Float(quartzPoint.y), &element)
        if status == .cannotComplete {
            timedOut = true
            return nil
        }
        guard status == .success, let element else { return nil }

        var chain: [AXAncestorInfo] = []
        chain.reserveCapacity(6)
        var current: AXUIElement? = element
        var sawScrollArea = false

        for hop in 0..<6 {
            guard let node = current, !isCancelled() else { break }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                break
            }
            let attrs = AXElementReader.readLightAttributesWithParent(
                node,
                primaryScreenHeight: primaryScreenHeight,
                timeout: Self.messagingTimeout
            )
            if attrs.timedOut {
                timedOut = true
                break
            }
            if attrs.role == "AXApplication" { break }
            chain.append(AXAncestorInfo(
                pid: attrs.pid,
                role: attrs.role,
                subrole: nil,
                identifier: nil,
                roleDescription: nil,
                frame: attrs.frame ?? .zero
            ))
            if attrs.role == "AXWindow" { break }
            if attrs.role == "AXScrollArea" {
                sawScrollArea = true
                if hop >= 2 { break }
            }
            guard let next = attrs.parent, !CFEqual(next, node) else { break }
            current = next
            if hop >= 3 && sawScrollArea { break }
        }

        guard !isCancelled() else { return nil }
        return SmartElementDetector.selectRefinedElementRect(
            from: chain,
            at: point,
            containerFrame: target.containerFrame
        )
    }

    internal func timeoutCountForTesting(pid: pid_t) -> Int {
        state.withLock { $0.consecutiveTimeoutsByPID[pid] ?? 0 }
    }
}
