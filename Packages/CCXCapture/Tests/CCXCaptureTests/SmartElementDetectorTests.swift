import CoreGraphics
import Foundation
import Testing
@testable import CCXCapture

@Suite("SmartElementDetector")
struct SmartElementDetectorTests {
    private func entry(
        id: Int,
        pid: Int32,
        layer: Int,
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
        alpha: Double = 1,
        owner: String = "App"
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: CGRect(x: x, y: y, width: width, height: height).dictionaryRepresentation,
        ]
    }

    @Test func filtersOwnProcessSystemLayersTinyAndTransparentWindows() {
        let ownPID: Int32 = 42
        let list: [[String: Any]] = [
            entry(id: 1, pid: ownPID, layer: 0, x: 0, y: 0, width: 500, height: 500),           // own overlay
            entry(id: 2, pid: 7, layer: 25, x: 0, y: 0, width: 1512, height: 37, owner: "Menubar"), // status/menu bar
            entry(id: 3, pid: 8, layer: 20, x: 0, y: 900, width: 1512, height: 80, owner: "Dock"),
            entry(id: 4, pid: 9, layer: 0, x: 10, y: 10, width: 4, height: 4),                    // too small
            entry(id: 5, pid: 10, layer: 0, x: 10, y: 10, width: 300, height: 300, alpha: 0),     // invisible
            entry(id: 6, pid: 11, layer: 3, x: 100, y: 100, width: 200, height: 100),             // floating
            entry(id: 7, pid: 12, layer: 0, x: 50, y: 50, width: 800, height: 600),               // normal
        ]
        let windows = SmartElementDetector.parseWindowList(list, excludingPID: ownPID, primaryScreenHeight: 982)
        #expect(windows.map(\.windowID) == [6, 7])
        #expect(windows.map(\.layer) == [3, 0])
        #expect(windows.last?.ownerPID == 12)
    }

    @Test func includesOwnProcessVisibleWindowsAndSupportsWindowIDExclusion() {
        let ownPID: Int32 = 42
        let utilityLayer = Int(CGWindowLevelForKey(.utilityWindow))
        let popupLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let list: [[String: Any]] = [
            entry(id: 10, pid: ownPID, layer: 0, x: 20, y: 20, width: 620, height: 490),           // Guide window
            entry(id: 11, pid: ownPID, layer: 3, x: 40, y: 40, width: 200, height: 150),           // Pin panel
            entry(id: 12, pid: ownPID, layer: utilityLayer, x: 60, y: 60, width: 300, height: 200),
            entry(id: 13, pid: ownPID, layer: popupLayer, x: 80, y: 80, width: 304, height: 320),  // MenuBar popover
            entry(id: 14, pid: ownPID, layer: 20, x: 0, y: 900, width: 1512, height: 80),          // Dock
            entry(id: 15, pid: ownPID, layer: 25, x: 0, y: 0, width: 1512, height: 37),            // Menubar
        ]

        let allVisible = SmartElementDetector.parseWindowList(list, excludingPID: nil, primaryScreenHeight: 982)
        #expect(allVisible.map(\.windowID) == [10, 11, 12, 13])

        let withoutExcluded = SmartElementDetector.parseWindowList(
            list,
            excludingPID: nil,
            excludingWindowIDs: [13],
            primaryScreenHeight: 982
        )
        #expect(withoutExcluded.map(\.windowID) == [10, 11, 12])
    }

    @Test func convertsQuartzBoundsToAppKitGlobal() {
        let list = [entry(id: 1, pid: 5, layer: 0, x: 100, y: 50, width: 400, height: 300)]
        let windows = SmartElementDetector.parseWindowList(list, excludingPID: 1, primaryScreenHeight: 1000)
        // AppKit y = primaryHeight - (quartzY + height) = 1000 - 350 = 650.
        #expect(windows.first?.frame == CGRect(x: 100, y: 650, width: 400, height: 300))
    }

    @Test func malformedEntriesAreSkipped() {
        let list: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 1)],
            entry(id: 2, pid: 5, layer: 0, x: 0, y: 0, width: 100, height: 100),
        ]
        let windows = SmartElementDetector.parseWindowList(list, excludingPID: 1, primaryScreenHeight: 1000)
        #expect(windows.map(\.windowID) == [2])
    }

    @Test func hitTestReturnsFrontMostContainingWindow() {
        let front = DetectedWindow(windowID: 1, ownerPID: 1, ownerName: nil, layer: 0, frame: CGRect(x: 100, y: 100, width: 100, height: 100))
        let back = DetectedWindow(windowID: 2, ownerPID: 2, ownerName: nil, layer: 0, frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let windows = [front, back]
        #expect(SmartElementDetector.hitTest(windows, at: CGPoint(x: 150, y: 150)) == front)
        #expect(SmartElementDetector.hitTest(windows, at: CGPoint(x: 50, y: 50)) == back)
        #expect(SmartElementDetector.hitTest(windows, at: CGPoint(x: 600, y: 600)) == nil)
    }

    @Test func hitTestHandlesNegativeMultiDisplayCoordinates() {
        let left = DetectedWindow(windowID: 9, ownerPID: 1, ownerName: nil, layer: 0, frame: CGRect(x: -1920, y: -200, width: 800, height: 600))
        #expect(SmartElementDetector.hitTest([left], at: CGPoint(x: -1500, y: 0)) == left)
    }

    @Test func plausibleElementRectChecks() {
        let container = CGRect(x: 0, y: 0, width: 500, height: 500)
        let point = CGPoint(x: 50, y: 50)
        #expect(SmartElementDetector.isPlausibleElementRect(CGRect(x: 40, y: 40, width: 30, height: 20), containing: point, within: container))
        // Too small.
        #expect(!SmartElementDetector.isPlausibleElementRect(CGRect(x: 49, y: 49, width: 2, height: 2), containing: point, within: container))
        // Does not contain the cursor.
        #expect(!SmartElementDetector.isPlausibleElementRect(CGRect(x: 100, y: 100, width: 30, height: 30), containing: point, within: container))
        // Escapes the containing window.
        #expect(!SmartElementDetector.isPlausibleElementRect(CGRect(x: 0, y: 0, width: 900, height: 900), containing: point, within: container))
        // No container: only size and containment matter.
        #expect(SmartElementDetector.isPlausibleElementRect(CGRect(x: 0, y: 0, width: 900, height: 900), containing: point, within: nil))
    }
}

@Suite("Overlay geometry")
struct OverlayGeometryTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test @MainActor func toolbarPrefersBelowThenAboveThenInside() {
        let size = SnipActionToolbar.preferredSize
        let below = SnipActionToolbar.frame(for: CGRect(x: 400, y: 400, width: 300, height: 200), in: bounds, topInset: 32)
        #expect(below.maxY <= 400 && below.maxX == 700)
        let above = SnipActionToolbar.frame(for: CGRect(x: 400, y: 0, width: 300, height: 200), in: bounds, topInset: 32)
        #expect(above.minY >= 200)
        let inside = SnipActionToolbar.frame(for: bounds, in: bounds, topInset: 32)
        #expect(bounds.contains(inside) && inside.size == size)
        let leftEdge = SnipActionToolbar.frame(for: CGRect(x: 0, y: 400, width: 20, height: 20), in: bounds, topInset: 32)
        #expect(leftEdge.minX == 0)

        let expanded = SnipActionToolbar.frame(for: CGRect(x: 400, y: 400, width: 300, height: 200), in: bounds, topInset: 32, showsStyleBar: true)
        #expect(bounds.contains(expanded) && expanded.size == SnipActionToolbar.expandedSize)
        #expect(expanded.maxY <= 400)
    }

    @Test @MainActor func toolbarClampedFramePreservesPrimaryTopAndRespectsBoundsAndTopInset() {
        let compactSize = SnipActionToolbar.preferredSize
        let expandedSize = SnipActionToolbar.expandedSize

        let freeAnchor = CGPoint(x: 220, y: 640)
        let compact = SnipActionToolbar.clampedFrame(anchoredAtTopLeft: freeAnchor, size: compactSize, in: bounds, topInset: 32)
        let expanded = SnipActionToolbar.clampedFrame(anchoredAtTopLeft: freeAnchor, size: expandedSize, in: bounds, topInset: 32)
        #expect(compact == CGRect(x: 220, y: 640 - compactSize.height, width: compactSize.width, height: compactSize.height))
        #expect(expanded.minX == compact.minX)
        #expect(expanded.maxY == compact.maxY)
        #expect(expanded.size == expandedSize)

        let overflow = SnipActionToolbar.clampedFrame(anchoredAtTopLeft: CGPoint(x: 2000, y: 1200), size: compactSize, in: bounds, topInset: 32)
        #expect(overflow.maxX == bounds.maxX)
        #expect(overflow.maxY == bounds.maxY - 32)

        // When anchored near the bottom and expanded, pushes upward so the style bar remains inside bounds.
        let nearBottomCompact = SnipActionToolbar.clampedFrame(anchoredAtTopLeft: CGPoint(x: 100, y: compactSize.height), size: compactSize, in: bounds, topInset: 32)
        #expect(nearBottomCompact.minY == 0)
        let nearBottomExpanded = SnipActionToolbar.clampedFrame(anchoredAtTopLeft: CGPoint(x: 100, y: compactSize.height), size: expandedSize, in: bounds, topInset: 32)
        #expect(nearBottomExpanded.minY == 0)
        #expect(nearBottomExpanded.size == expandedSize)

        let narrowBounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let narrowClamped = SnipActionToolbar.clampedFrame(anchoredAtTopLeft: CGPoint(x: 80, y: 180), size: compactSize, in: narrowBounds, topInset: 10)
        #expect(narrowClamped.minX == narrowBounds.minX)
    }

    @Test @MainActor func magnifierStaysInsideAndAvoidsNotch() {
        let topInset: CGFloat = 32
        for cursor in [CGPoint(x: 0, y: 0), CGPoint(x: 1512, y: 982), CGPoint(x: 1500, y: 10), CGPoint(x: 5, y: 970), CGPoint(x: 700, y: 500)] {
            let frame = PixelMagnifierView.frame(near: cursor, in: bounds, topInset: topInset)
            #expect(bounds.contains(frame))
            #expect(frame.maxY <= bounds.maxY - topInset)
            #expect(!frame.contains(cursor))
        }
    }
}
