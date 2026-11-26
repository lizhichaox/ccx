import ApplicationServices
import CoreGraphics
import Foundation
import os
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

    @Test func parseWindowSnapshotSeparatesNotificationCenterByOwnerOrBundleID() {
        let ncPID: pid_t = 1127
        let customOwnerNCPID: pid_t = 2222
        let chromePID: pid_t = 1237
        let popoverPID: pid_t = 3333
        let list: [[String: Any]] = [
            entry(id: 1, pid: popoverPID, layer: 101, x: 600, y: 100, width: 200, height: 150, owner: "Popup"),
            entry(id: 2, pid: ncPID, layer: 23, x: 0, y: 0, width: 1512, height: 982, owner: "Notification Center"),
            entry(id: 3, pid: customOwnerNCPID, layer: 23, x: 0, y: 0, width: 1512, height: 982, owner: "LocalizedNC"),
            entry(id: 4, pid: chromePID, layer: 0, x: 0, y: 34, width: 1512, height: 948, owner: "Google Chrome"),
        ]

        let snapshot = SmartElementDetector.parseWindowSnapshot(
            list,
            primaryScreenHeight: 982,
            bundleIdentifierResolver: { pid in
                pid == customOwnerNCPID ? "com.apple.notificationcenterui" : nil
            }
        )

        #expect(snapshot.windows.map(\.windowID) == [1, 4])
        #expect(snapshot.overlayWindows.map(\.window.windowID) == [2, 3])
        #expect(snapshot.overlayWindows.map(\.zOrderIndex) == [1, 1])

        // Full-screen Notification Center is excluded from regular windows so left-side Chrome hit-tests cleanly.
        #expect(SmartElementDetector.hitTest(snapshot.windows, at: CGPoint(x: 300, y: 500))?.windowID == 4)
    }

    @Test func mergingOverlayCardsSplicesZOrderLeavesGapsTransparentAndHandlesFallbacks() {
        let popover = DetectedWindow(windowID: 1, ownerPID: 10, ownerName: "Popup", layer: 101, frame: CGRect(x: 1180, y: 780, width: 160, height: 120))
        let chrome = DetectedWindow(windowID: 4, ownerPID: 20, ownerName: "Google Chrome", layer: 0, frame: CGRect(x: 0, y: 0, width: 1512, height: 948))

        let fullScreenNC = DetectedWindow(windowID: 2, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let compactBanner = DetectedWindow(windowID: 5, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 1140, y: 860, width: 350, height: 90))
        let unresolvedFullScreen = DetectedWindow(windowID: 6, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))

        let card1 = CGRect(x: 1142, y: 750, width: 352, height: 160)
        let card2 = CGRect(x: 1142, y: 570, width: 352, height: 165)

        let merged = SmartElementDetector.mergingOverlayCards(
            regularWindows: [popover, chrome],
            overlays: [
                OverlayWindowEntry(window: fullScreenNC, zOrderIndex: 1),
                OverlayWindowEntry(window: compactBanner, zOrderIndex: 1),
                OverlayWindowEntry(window: unresolvedFullScreen, zOrderIndex: 1),
            ],
            cardsByWindowID: [2: [card1, card2]]
        )

        #expect(merged.windows.map(\.frame) == [popover.frame, card1, card2, compactBanner.frame, chrome.frame])
        #expect(merged.windows[1].allowsTier2Refinement == false)
        #expect(merged.windows[2].allowsTier2Refinement == false)
        #expect(merged.windows[3].allowsTier2Refinement == false)
        #expect(merged.windows[0].allowsTier2Refinement == true)
        #expect(merged.windows[4].allowsTier2Refinement == true)

        // Popover stays above Notification Center cards; gaps between cards fall through to Chrome.
        #expect(SmartElementDetector.hitTest(merged.windows, at: CGPoint(x: 1200, y: 820))?.windowID == 1)
        #expect(SmartElementDetector.hitTest(merged.windows, at: CGPoint(x: 1200, y: 742))?.windowID == 4)
        #expect(SmartElementDetector.hitTest(merged.windows, at: CGPoint(x: 1200, y: 650))?.frame == card2)
        #expect(merged.fallbackOverlays.map(\.window.windowID) == [6])
    }

    @Test func extractOverlayCardsHandlesExplicitNotificationsAndExpandedStacks() {
        let ncPID: pid_t = 1127
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        func node(
            pid: pid_t = ncPID,
            role: String? = "AXGroup",
            subrole: String? = nil,
            identifier: String? = nil,
            roleDescription: String? = nil,
            frame: CGRect,
            children: [AXNodeSnapshot] = []
        ) -> AXNodeSnapshot {
            AXNodeSnapshot(
                pid: pid,
                role: role,
                subrole: subrole,
                identifier: identifier,
                roleDescription: roleDescription,
                frame: frame,
                children: children
            )
        }

        let singleAlertFrame = CGRect(x: 1142, y: 800, width: 352, height: 96)
        let singleAlert = node(
            subrole: "AXNotificationCenterAlert",
            frame: singleAlertFrame,
            children: [
                node(role: "AXStaticText", frame: CGRect(x: 1160, y: 840, width: 280, height: 42)),
            ]
        )

        let collapsedStackFrame = CGRect(x: 1142, y: 690, width: 352, height: 96)
        let collapsedStack = node(
            subrole: "AXNotificationCenterStack",
            frame: collapsedStackFrame,
            children: [
                node(subrole: "AXNotificationCenterBanner", frame: collapsedStackFrame),
            ]
        )

        let expandedBanner1 = CGRect(x: 1142, y: 580, width: 352, height: 84)
        let expandedBanner2 = CGRect(x: 1142, y: 488, width: 352, height: 84)
        let expandedStack = node(
            subrole: "AXNotificationCenterStack",
            frame: CGRect(x: 1142, y: 488, width: 352, height: 176),
            children: [
                node(subrole: "AXNotificationCenterBanner", frame: expandedBanner1),
                node(subrole: "AXNotificationCenterBanner", frame: expandedBanner2),
            ]
        )

        let root = node(
            role: "AXWindow",
            frame: windowFrame,
            children: [
                node(role: "AXScrollArea", frame: CGRect(x: 1130, y: 40, width: 382, height: 900), children: [
                    singleAlert,
                    collapsedStack,
                    expandedStack,
                ]),
            ]
        )

        let cards = SmartElementDetector.extractOverlayCards(from: root, ownerPID: ncPID, windowFrame: windowFrame)
        #expect(cards == [singleAlertFrame, collapsedStackFrame, expandedBanner1, expandedBanner2])
    }

    @Test func extractOverlayCardsKeepsRemoteWidgetKitCardsAndExplicitWidgetsAtomic() {
        let ncPID: pid_t = 1127
        let calendarPID: pid_t = 1232
        let batteriesPID: pid_t = 1233
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        func node(
            pid: pid_t = ncPID,
            role: String? = "AXGroup",
            subrole: String? = nil,
            identifier: String? = nil,
            roleDescription: String? = nil,
            frame: CGRect,
            children: [AXNodeSnapshot] = []
        ) -> AXNodeSnapshot {
            AXNodeSnapshot(
                pid: pid,
                role: role,
                subrole: subrole,
                identifier: identifier,
                roleDescription: roleDescription,
                frame: frame,
                children: children
            )
        }

        let calendarFrame = CGRect(x: 1142, y: 560, width: 352, height: 162)
        // Host AXGroup wrapping a remote WidgetKit XPC view (must stay a single card, never split into columns).
        let calendarHost = node(
            frame: calendarFrame,
            children: [
                node(pid: calendarPID, frame: calendarFrame, children: [
                    node(pid: calendarPID, frame: CGRect(x: 1154, y: 572, width: 156, height: 138)),
                    node(pid: calendarPID, frame: CGRect(x: 1322, y: 572, width: 156, height: 138)),
                ]),
            ]
        )

        let weatherFrame = CGRect(x: 1142, y: 382, width: 352, height: 162)
        let weatherWidget = node(
            subrole: "AXWidget",
            frame: weatherFrame,
            children: [
                node(frame: CGRect(x: 1154, y: 394, width: 156, height: 138)),
                node(frame: CGRect(x: 1322, y: 394, width: 156, height: 138)),
            ]
        )

        let batteriesFrame = CGRect(x: 1142, y: 130, width: 352, height: 236)
        let batteriesRemoteRoot = node(
            pid: batteriesPID,
            frame: batteriesFrame,
            children: [
                node(pid: batteriesPID, frame: CGRect(x: 1154, y: 300, width: 328, height: 48)),
                node(pid: batteriesPID, frame: CGRect(x: 1154, y: 240, width: 328, height: 48)),
            ]
        )

        let root = node(
            role: "AXWindow",
            frame: windowFrame,
            children: [calendarHost, weatherWidget, batteriesRemoteRoot]
        )

        let cards = SmartElementDetector.extractOverlayCards(from: root, ownerPID: ncPID, windowFrame: windowFrame)
        #expect(cards == [calendarFrame, weatherFrame, batteriesFrame])
    }

    @Test func extractOverlayCardsStructuralFallbackSplitsColumnsAndStacksWhilePreservingPaddedCards() {
        let ncPID: pid_t = 1127
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        func group(_ frame: CGRect, role: String = "AXGroup", children: [AXNodeSnapshot] = []) -> AXNodeSnapshot {
            AXNodeSnapshot(pid: ncPID, role: role, subrole: nil, identifier: nil, roleDescription: nil, frame: frame, children: children)
        }

        // Top section header (< 40pt tall) and Edit Widgets button (< 40pt tall) must be ignored.
        let header = group(CGRect(x: 1142, y: 920, width: 352, height: 26))
        let editButton = group(CGRect(x: 1268, y: 36, width: 100, height: 28), role: "AXButton")

        // Flush vertical stack of two notification cards (child minX/maxX flush with parent -> split).
        let notif1 = CGRect(x: 1142, y: 820, width: 352, height: 84)
        let notif2 = CGRect(x: 1142, y: 726, width: 352, height: 84)
        let notifStack = group(CGRect(x: 1142, y: 726, width: 352, height: 178), children: [
            group(notif1),
            group(notif2),
        ])

        // 2-column small widget row (left/right children touch row's outer horizontal edges -> split).
        let smallLeft = CGRect(x: 1142, y: 540, width: 168, height: 168)
        let smallRight = CGRect(x: 1326, y: 540, width: 168, height: 168)
        let smallRow = group(CGRect(x: 1142, y: 540, width: 352, height: 168), children: [
            group(smallLeft),
            group(smallRight),
        ])

        // Padded Calendar-like card without explicit widget markers (inner columns inset >= 6pt on both sides -> collapse to card).
        let calendarCard = CGRect(x: 1142, y: 360, width: 352, height: 162)
        let paddedCalendar = group(calendarCard, children: [
            group(CGRect(x: 1154, y: 372, width: 156, height: 138)),
            group(CGRect(x: 1322, y: 372, width: 156, height: 138)),
        ])

        // Padded Batteries-like card (stacked inner rows inset >= 6pt on both sides -> collapse to card).
        let batteriesCard = CGRect(x: 1142, y: 108, width: 352, height: 236)
        let paddedBatteries = group(batteriesCard, children: [
            group(CGRect(x: 1154, y: 280, width: 328, height: 48)),
            group(CGRect(x: 1154, y: 220, width: 328, height: 48)),
        ])

        let scrollWrapper = group(CGRect(x: 1130, y: 30, width: 382, height: 920), role: "AXScrollArea", children: [
            header,
            notifStack,
            smallRow,
            paddedCalendar,
            paddedBatteries,
            editButton,
        ])
        let root = group(windowFrame, role: "AXWindow", children: [scrollWrapper])

        let cards = SmartElementDetector.extractOverlayCards(from: root, ownerPID: ncPID, windowFrame: windowFrame)
        #expect(cards == [notif1, notif2, smallLeft, smallRight, calendarCard, batteriesCard])
    }

    @Test func selectCardFromAncestorChainHandlesExplicitRemoteAndStructuralChains() {
        let ncPID: pid_t = 1127
        let widgetPID: pid_t = 1232
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        func info(
            pid: pid_t = ncPID,
            role: String? = "AXGroup",
            subrole: String? = nil,
            identifier: String? = nil,
            roleDescription: String? = nil,
            frame: CGRect
        ) -> AXAncestorInfo {
            AXAncestorInfo(
                pid: pid,
                role: role,
                subrole: subrole,
                identifier: identifier,
                roleDescription: roleDescription,
                frame: frame
            )
        }

        // 1. Explicit banner inside an expanded stack prefers the banner over the stack.
        let bannerFrame = CGRect(x: 1142, y: 740, width: 352, height: 84)
        let stackFrame = CGRect(x: 1142, y: 640, width: 352, height: 184)
        let notifChain = [
            info(role: "AXStaticText", frame: CGRect(x: 1190, y: 760, width: 200, height: 24)),
            info(subrole: "AXNotificationCenterBanner", frame: bannerFrame),
            info(subrole: "AXNotificationCenterStack", frame: stackFrame),
            info(role: "AXScrollArea", frame: CGRect(x: 1130, y: 40, width: 382, height: 900)),
        ]
        #expect(SmartElementDetector.selectCardFromAncestorChain(notifChain, ownerPID: ncPID, windowFrame: windowFrame) == bannerFrame)

        // 2. Remote WidgetKit chain crosses from remote PID to Notification Center host PID: chooses remote root card, not inner column.
        let innerColumnFrame = CGRect(x: 1154, y: 572, width: 156, height: 138)
        let remoteWidgetFrame = CGRect(x: 1142, y: 560, width: 352, height: 162)
        let remoteChain = [
            info(pid: widgetPID, role: "AXStaticText", frame: CGRect(x: 1160, y: 650, width: 80, height: 20)),
            info(pid: widgetPID, role: "AXGroup", frame: innerColumnFrame),
            info(pid: widgetPID, role: "AXGroup", frame: remoteWidgetFrame),
            info(pid: ncPID, role: "AXGroup", frame: remoteWidgetFrame),
            info(pid: ncPID, role: "AXScrollArea", frame: CGRect(x: 1130, y: 40, width: 382, height: 900)),
        ]
        #expect(SmartElementDetector.selectCardFromAncestorChain(remoteChain, ownerPID: ncPID, windowFrame: windowFrame) == remoteWidgetFrame)

        // 3. Structural fallback selects largest card-sized container, skipping full-height list wrapper.
        let structuralCardFrame = CGRect(x: 1142, y: 380, width: 352, height: 162)
        let structuralChain = [
            info(role: "AXStaticText", frame: CGRect(x: 1160, y: 460, width: 120, height: 30)),
            info(role: "AXGroup", frame: CGRect(x: 1154, y: 392, width: 156, height: 138)),
            info(role: "AXGroup", frame: structuralCardFrame),
            info(role: "AXGroup", frame: CGRect(x: 1130, y: 40, width: 382, height: 900)),
        ]
        #expect(SmartElementDetector.selectCardFromAncestorChain(structuralChain, ownerPID: ncPID, windowFrame: windowFrame) == structuralCardFrame)
    }

    @Test @MainActor func shouldRequestElementRectSkipsAtomicCardsAndQueriesRegularAndFallbackOverlays() {
        let detector = SmartElementDetector(enableAccessibility: true, forceAccessibilityForTesting: true)
        #expect(detector.isAccessibilityEnabled)

        let card = DetectedWindow(
            windowID: 2,
            ownerPID: 1127,
            ownerName: "Notification Center",
            layer: 23,
            frame: CGRect(x: 1142, y: 740, width: 352, height: 160),
            allowsTier2Refinement: false
        )
        let chrome = DetectedWindow(
            windowID: 4,
            ownerPID: 1237,
            ownerName: "Google Chrome",
            layer: 0,
            frame: CGRect(x: 0, y: 34, width: 1120, height: 948),
            allowsTier2Refinement: true
        )
        let fallbackNC = OverlayWindowEntry(
            window: DetectedWindow(
                windowID: 9,
                ownerPID: 1127,
                ownerName: "Notification Center",
                layer: 23,
                frame: CGRect(x: 1120, y: 0, width: 392, height: 982)
            ),
            zOrderIndex: 0
        )

        detector.setDetectedStateForTesting(
            regularWindows: [chrome],
            windows: [card, chrome],
            fallbackOverlayWindows: [fallbackNC]
        )

        // Atomic card skips Tier 2 AX.
        #expect(detector.shouldRequestElementRect(at: CGPoint(x: 1200, y: 800)) == false)
        // Regular window enables Tier 2 AX.
        #expect(detector.shouldRequestElementRect(at: CGPoint(x: 500, y: 500)) == true)
        // Fallback overlay over Desktop (outside regular Chrome) still enables Tier 2 AX.
        #expect(detector.shouldRequestElementRect(at: CGPoint(x: 1200, y: 200)) == true)
        // Empty Desktop outside both regular windows and fallback overlays skips Tier 2 AX.
        #expect(detector.shouldRequestElementRect(at: CGPoint(x: 500, y: 10)) == false)
    }

    @Test func tier1AllowsSpotlightControlCenterPopoversSubmenusSheetsAndExcludesChromeAndGhosts() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let list: [[String: Any]] = [
            entry(id: 1, pid: 10, layer: 105, x: 200, y: 120, width: 180, height: 220, owner: "Submenu"),
            entry(id: 2, pid: 11, layer: 102, x: 180, y: 100, width: 200, height: 260, owner: "OverlayMenu"),
            entry(id: 3, pid: 12, layer: 200, x: 300, y: 300, width: 140, height: 24, owner: "Tooltip"), // help tooltip excluded
            entry(id: 4, pid: 13, layer: 25, x: 1180, y: 37, width: 320, height: 380, owner: "Control Center"), // real CC panel
            entry(id: 5, pid: 13, layer: 25, x: 0, y: 0, width: 1512, height: 982, owner: "Control Center"), // full-screen click backdrop excluded
            entry(id: 6, pid: 13, layer: 25, x: 1300, y: 0, width: 28, height: 24, owner: "Control Center"), // status icon strip excluded
            entry(id: 7, pid: 14, layer: 26, x: 900, y: 37, width: 300, height: 240, owner: "MenuBarApp"), // status popover
            entry(id: 8, pid: 15, layer: 25, x: 0, y: 0, width: 1512, height: 38, owner: "MenuBarAgent"), // menu bar agent excluded
            entry(id: 9, pid: 16, layer: 24, x: 0, y: 0, width: 1512, height: 37, owner: "MainMenu"), // main menu excluded
            entry(id: 10, pid: 17, layer: 23, x: 450, y: 180, width: 680, height: 420, owner: "Spotlight"), // Spotlight included
            entry(id: 11, pid: 18, layer: 8, x: 400, y: 200, width: 420, height: 240, owner: "ModalSheet"), // modal panel
            entry(id: 12, pid: 19, layer: 4, x: 500, y: 200, width: 320, height: 180, owner: "FloatingChild"), // floating+1
            entry(id: 13, pid: 20, layer: 1, x: 100, y: 100, width: 500, height: 300, owner: "SheetWindow"), // normal+1 sheet
            entry(id: 14, pid: 21, layer: 0, x: 0, y: 0, width: 1512, height: 982, owner: "Window Server"), // ghost excluded
            entry(id: 15, pid: 22, layer: 3, x: 0, y: 0, width: 1512, height: 982, owner: "WindowManager"), // ghost excluded
            entry(id: 16, pid: 23, layer: 1000, x: 0, y: 0, width: 1512, height: 982, owner: "ScreenSaver"), // excluded
            entry(id: 17, pid: 24, layer: -20, x: 0, y: 0, width: 1512, height: 982, owner: "Desktop"), // excluded
        ]

        let windows = SmartElementDetector.parseWindowList(
            list,
            primaryScreenHeight: 982,
            screenFrames: [screenFrame]
        )
        #expect(windows.map(\.windowID) == [1, 2, 4, 7, 10, 11, 12, 13])
    }

    @Test func parseWindowSnapshotMemoizesBundleIDsAndFiltersOverlayEdgeCases() {
        let ncPID: pid_t = 500
        let chromePID: pid_t = 600
        var lookupsByPID: [pid_t: Int] = [:]

        var omittedAlphaEntry = entry(id: 10, pid: chromePID, layer: 0, x: 20, y: 40, width: 400, height: 300, owner: "Chrome")
        omittedAlphaEntry.removeValue(forKey: kCGWindowAlpha as String)

        let list: [[String: Any]] = [
            // Invalid NC overlays: desktop layer (<0), screenSaver (>=1000), status strip (<=44pt), sub-card (<80x40).
            entry(id: 1, pid: ncPID, layer: -10, x: 0, y: 0, width: 350, height: 350, owner: "Notification Center"),
            entry(id: 2, pid: ncPID, layer: 1000, x: 0, y: 0, width: 1512, height: 982, owner: "Notification Center"),
            entry(id: 3, pid: ncPID, layer: 25, x: 1300, y: 0, width: 140, height: 37, owner: "Notification Center"),
            entry(id: 4, pid: ncPID, layer: 23, x: 1400, y: 50, width: 50, height: 30, owner: "Notification Center"),
            // Valid NC overlay via bundle ID (should trigger 1 lookup for pid 501).
            entry(id: 5, pid: 501, layer: 23, x: 0, y: 0, width: 1512, height: 982, owner: "通知中心"),
            // Alpha boundary: 0.01 excluded, 0.02 included, omitted included.
            entry(id: 6, pid: chromePID, layer: 0, x: 10, y: 10, width: 200, height: 200, alpha: 0.01, owner: "Chrome"),
            entry(id: 7, pid: chromePID, layer: 0, x: 10, y: 10, width: 200, height: 200, alpha: 0.02, owner: "Chrome"),
            entry(id: 8, pid: chromePID, layer: 0, x: 30, y: 30, width: 200, height: 200, alpha: 1.0, owner: "Chrome"),
            omittedAlphaEntry,
            // Excluded overlay by windowID.
            entry(id: 9, pid: ncPID, layer: 23, x: 0, y: 0, width: 1512, height: 982, owner: "Notification Center"),
        ]

        let snapshot = SmartElementDetector.parseWindowSnapshot(
            list,
            excludingWindowIDs: [9],
            primaryScreenHeight: 982,
            bundleIdentifierResolver: { pid in
                lookupsByPID[pid, default: 0] += 1
                return pid == 501 ? "com.apple.notificationcenterui" : "com.example.app"
            }
        )

        #expect(snapshot.overlayWindows.map(\.window.windowID) == [5])
        #expect(snapshot.windows.map(\.windowID) == [7, 8, 10])
        // Chrome appeared 3 times after alpha filtering, yet bundleIdentifierResolver was called only once.
        #expect(lookupsByPID[chromePID] == 1)
        #expect(lookupsByPID[501] == 1)
    }

    @Test func cardSizingBoundsExtraLargeAndMetadataHeuristics() {
        let fullScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let narrowWindow = CGRect(x: 1120, y: 0, width: 392, height: 500)

        // NaN, infinite, null, and sub-minimum sizes rejected.
        #expect(!SmartElementDetector.isCardSized(.null, in: fullScreen))
        #expect(!SmartElementDetector.isCardSized(.infinite, in: fullScreen))
        #expect(!SmartElementDetector.isCardSized(CGRect(x: CGFloat.nan, y: 0, width: 200, height: 100), in: fullScreen))
        #expect(!SmartElementDetector.isCardSized(CGRect(x: 100, y: 100, width: 79, height: 40), in: fullScreen))
        #expect(!SmartElementDetector.isCardSized(CGRect(x: 100, y: 100, width: 80, height: 39), in: fullScreen))
        #expect(SmartElementDetector.isCardSized(CGRect(x: 100, y: 100, width: 80, height: 40), in: fullScreen))

        // Narrow & short windows permit full-window-sized cards (+4pt tolerance).
        #expect(SmartElementDetector.isCardSized(CGRect(x: 1120, y: 0, width: 392, height: 500), in: narrowWindow))

        // Extra-large widget (~716pt wide) rejected by default, accepted with allowExtraLarge.
        let xlWidget = CGRect(x: 780, y: 400, width: 716, height: 350)
        #expect(!SmartElementDetector.isCardSized(xlWidget, in: fullScreen))
        #expect(SmartElementDetector.isCardSized(xlWidget, in: fullScreen, allowExtraLarge: true))
    }

    @Test func extractOverlayCardsHandlesLeafBannersPaddedMultiCardSectionsScrollClippingAndXLWidgets() {
        let ncPID: pid_t = 1127
        let xlWidgetPID: pid_t = 1555
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        func node(
            pid: pid_t = ncPID,
            role: String? = "AXGroup",
            subrole: String? = nil,
            identifier: String? = nil,
            roleDescription: String? = nil,
            frame: CGRect,
            children: [AXNodeSnapshot] = []
        ) -> AXNodeSnapshot {
            AXNodeSnapshot(
                pid: pid,
                role: role,
                subrole: subrole,
                identifier: identifier,
                roleDescription: roleDescription,
                frame: frame,
                children: children
            )
        }

        // 1. Leaf AXNotificationCenterBanner with 2 internal children containing "notification" in identifier must stay atomic.
        let leafBannerFrame = CGRect(x: 1142, y: 820, width: 352, height: 96)
        let leafBanner = node(
            subrole: "AXNotificationCenterBanner",
            frame: leafBannerFrame,
            children: [
                node(identifier: "notification-body", frame: CGRect(x: 1154, y: 866, width: 320, height: 42)),
                node(identifier: "notification-action", frame: CGRect(x: 1154, y: 824, width: 320, height: 40)),
            ]
        )

        // 2. Padded section container (<650pt tall, 15pt padding on all 4 sides) wrapping 2 standalone cards must SPLIT, not collapse.
        let secCard1 = CGRect(x: 1145, y: 690, width: 352, height: 96)
        let secCard2 = CGRect(x: 1145, y: 500, width: 352, height: 168)
        let paddedSection = node(
            frame: CGRect(x: 1130, y: 485, width: 382, height: 316),
            children: [node(frame: secCard1), node(frame: secCard2)]
        )

        // 3. Padded section wrapping 2 side-by-side small widgets must SPLIT into 2 small widgets.
        let smallA = CGRect(x: 1145, y: 310, width: 168, height: 168)
        let smallB = CGRect(x: 1329, y: 310, width: 168, height: 168)
        let paddedSmallRow = node(
            frame: CGRect(x: 1130, y: 298, width: 382, height: 192),
            children: [node(frame: smallA), node(frame: smallB)]
        )

        // 4. Partially scrolled card clipped to AXScrollArea (y = 80...940) + fully scrolled-out card behind footer (y = 0...60).
        let partiallyScrolled = node(
            subrole: "AXNotificationCenterAlert",
            frame: CGRect(x: 1142, y: 40, width: 352, height: 100) // clipped to y=80..140 (height 60)
        )
        let scrolledOff = node(
            subrole: "AXNotificationCenterAlert",
            frame: CGRect(x: 1142, y: 0, width: 352, height: 70) // outside scrollArea (y >= 80) -> dropped
        )

        // 5. Extra-large remote WidgetKit widget (716pt wide) + localized roleDescription widget.
        let xlFrame = CGRect(x: 780, y: 100, width: 716, height: 180)
        let xlWidget = node(pid: xlWidgetPID, frame: xlFrame)
        let localizedWidgetFrame = CGRect(x: 800, y: 700, width: 300, height: 150)
        let localizedWidget = node(roleDescription: "小组件", frame: localizedWidgetFrame)
        // Container-word identifier must NOT match as a single widget.
        let ignoredContainer = node(
            identifier: "widget-container",
            frame: CGRect(x: 800, y: 500, width: 300, height: 150),
            children: [
                node(subrole: "AXNotificationCenterSystemDialog", frame: CGRect(x: 800, y: 500, width: 300, height: 150)),
            ]
        )

        let scrollArea = node(
            role: "AXScrollArea",
            frame: CGRect(x: 770, y: 80, width: 742, height: 860),
            children: [
                leafBanner,
                paddedSection,
                paddedSmallRow,
                partiallyScrolled,
                scrolledOff,
                xlWidget,
                localizedWidget,
                ignoredContainer,
            ]
        )
        let root = node(role: "AXWindow", frame: windowFrame, children: [scrollArea])
        let cards = SmartElementDetector.extractOverlayCards(from: root, ownerPID: ncPID, windowFrame: windowFrame)

        #expect(cards.contains(leafBannerFrame))
        #expect(cards.contains(secCard1))
        #expect(cards.contains(secCard2))
        #expect(cards.contains(smallA))
        #expect(cards.contains(smallB))
        #expect(cards.contains(CGRect(x: 1142, y: 80, width: 352, height: 60)))
        #expect(!cards.contains { $0.minY < 80 })
        #expect(cards.contains(xlFrame))
        #expect(cards.contains(localizedWidgetFrame))
    }

    @Test func selectCardFromAncestorChainAvoidsSectionCollapseAndHandlesZeroRemoteProxy() {
        let ncPID: pid_t = 1127
        let widgetPID: pid_t = 1232
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        func info(
            pid: pid_t = ncPID,
            role: String? = "AXGroup",
            subrole: String? = nil,
            identifier: String? = nil,
            roleDescription: String? = nil,
            frame: CGRect
        ) -> AXAncestorInfo {
            AXAncestorInfo(
                pid: pid,
                role: role,
                subrole: subrole,
                identifier: identifier,
                roleDescription: roleDescription,
                frame: frame
            )
        }

        // 1. Structural chain inside a <650pt tall padded section must pick the card, not the section or 2-col row.
        let smallLeft = CGRect(x: 1142, y: 540, width: 168, height: 168)
        let smallRow = CGRect(x: 1142, y: 540, width: 352, height: 168)
        let shortSection = CGRect(x: 1130, y: 400, width: 382, height: 420)
        let smallChain = [
            info(role: "AXStaticText", frame: CGRect(x: 1160, y: 600, width: 60, height: 20)),
            info(role: "AXGroup", frame: smallLeft),
            info(role: "AXGroup", frame: smallRow),
            info(role: "AXGroup", frame: shortSection),
        ]
        #expect(SmartElementDetector.selectCardFromAncestorChain(smallChain, ownerPID: ncPID, windowFrame: windowFrame) == smallLeft)

        // 2. Inner "notification-body" identifier must not beat enclosing AXNotificationCenterBanner subrole.
        let bannerFrame = CGRect(x: 1142, y: 740, width: 352, height: 84)
        let innerIDChain = [
            info(identifier: "notification-body", frame: CGRect(x: 1154, y: 760, width: 280, height: 44)),
            info(subrole: "AXNotificationCenterBanner", frame: bannerFrame),
        ]
        #expect(SmartElementDetector.selectCardFromAncestorChain(innerIDChain, ownerPID: ncPID, windowFrame: windowFrame) == bannerFrame)

        // 3. Remote root with .zero frame + immediate .zero host proxy climbs to lastRemoteIndex + 2 card-sized host.
        let hostCardFrame = CGRect(x: 1142, y: 360, width: 352, height: 162)
        let remoteProxyChain = [
            info(pid: widgetPID, role: "AXStaticText", frame: CGRect(x: 1160, y: 420, width: 60, height: 20)),
            info(pid: widgetPID, role: "AXGroup", frame: .zero),
            info(pid: ncPID, role: "AXGroup", frame: .zero),
            info(pid: ncPID, role: "AXGroup", frame: hostCardFrame),
        ]
        #expect(SmartElementDetector.selectCardFromAncestorChain(remoteProxyChain, ownerPID: ncPID, windowFrame: windowFrame) == hostCardFrame)

        // 4. Remote chain with non-card outer host falls back to innerRemote; chain with no card-sized nodes returns nil.
        let innerRemoteFrame = CGRect(x: 1150, y: 370, width: 160, height: 140)
        let innerFallbackChain = [
            info(pid: widgetPID, role: "AXGroup", frame: innerRemoteFrame),
            info(pid: widgetPID, role: "AXGroup", frame: .zero),
            info(pid: ncPID, role: "AXScrollArea", frame: CGRect(x: 1130, y: 40, width: 382, height: 900)),
        ]
        #expect(SmartElementDetector.selectCardFromAncestorChain(innerFallbackChain, ownerPID: ncPID, windowFrame: windowFrame) == innerRemoteFrame)

        let emptyChain = [info(role: "AXStaticText", frame: CGRect(x: 1150, y: 400, width: 40, height: 20))]
        #expect(SmartElementDetector.selectCardFromAncestorChain(emptyChain, ownerPID: ncPID, windowFrame: windowFrame) == nil)
    }

    @Test func deduplicateAndPrunePreservesCollapsedStackZOrderWhilePrioritizingContainedCards() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

        // 1. Collapsed notification stack: front card (352x84) + depth-scaled protruding peek card behind it (336x84, shifted 10pt lower).
        //    Front card must stay FIRST despite having larger area.
        let frontCard = CGRect(x: 1142, y: 700, width: 352, height: 84)
        let peekCard = CGRect(x: 1150, y: 690, width: 336, height: 84)
        let stackResult = SmartElementDetector.deduplicateAndPruneCards([frontCard, peekCard], in: windowFrame)
        #expect(stackResult == [frontCard, peekCard])

        // 2. Contained inner card inside a larger single-child wrapper: smaller contained card comes FIRST.
        let wrapper = CGRect(x: 1134, y: 500, width: 368, height: 120)
        let inner = CGRect(x: 1142, y: 508, width: 352, height: 104)
        let nestedResult = SmartElementDetector.deduplicateAndPruneCards([wrapper, inner], in: windowFrame)
        #expect(nestedResult == [inner, wrapper])

        // 3. Wrapper containing >= 2 distinct cards is pruned; duplicates within 4pt deduped; partial off-window card clamped.
        let container = CGRect(x: 1138, y: 100, width: 360, height: 260)
        let child1 = CGRect(x: 1142, y: 240, width: 352, height: 100)
        let child1Dup = CGRect(x: 1144, y: 241, width: 350, height: 99)
        let child2 = CGRect(x: 1142, y: 110, width: 352, height: 100)
        let clampedOffEdge = CGRect(x: 1142, y: -40, width: 352, height: 90) // clipped to y=0..50 (height 50)
        let pruned = SmartElementDetector.deduplicateAndPruneCards(
            [container, child1, child1Dup, child2, clampedOffEdge],
            in: windowFrame
        )
        #expect(pruned == [child1, child2, CGRect(x: 1142, y: 0, width: 352, height: 50)])
    }

    @Test func mergingOverlayCardsDropsConfirmedEmptyOverlaysAndClampsZOrderAndCompactBounds() {
        let chrome = DetectedWindow(windowID: 1, ownerPID: 20, ownerName: "Chrome", layer: 0, frame: CGRect(x: 0, y: 0, width: 1512, height: 948))
        let confirmedEmptyNC = DetectedWindow(windowID: 2, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let tinyNC = DetectedWindow(windowID: 3, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 1400, y: 900, width: 60, height: 30))
        let compactNC = DetectedWindow(windowID: 4, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 1140, y: 860, width: 350, height: 90))

        let merged = SmartElementDetector.mergingOverlayCards(
            regularWindows: [chrome],
            overlays: [
                OverlayWindowEntry(window: confirmedEmptyNC, zOrderIndex: -5), // clamped to 0, confirmed empty -> dropped completely
                OverlayWindowEntry(window: tinyNC, zOrderIndex: 0), // below minimumCardWidth/Height -> not spliced as compact banner
                OverlayWindowEntry(window: compactNC, zOrderIndex: 99), // clamped to end
            ],
            cardsByWindowID: [:],
            confirmedEmptyWindowIDs: [2]
        )

        #expect(merged.windows.map(\.windowID) == [1, 4])
        #expect(merged.fallbackOverlays.map(\.window.windowID) == [3])
    }

    @Test func probeXColumnsSupportsLTRAndRTL() {
        let full = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(AXOverlayCardExtractor.probeXColumns(for: full, isRightToLeft: false) == [-100, -270])
        #expect(AXOverlayCardExtractor.probeXColumns(for: full, isRightToLeft: true) == [-1820, -1650])
        let narrow = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(AXOverlayCardExtractor.probeXColumns(for: narrow, isRightToLeft: false).isEmpty)
    }

    @Test func tier2SelectRefinedElementRectPromotesLeavesSkipsChromeClipsScrollAndRejectsFullWindow() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)

        func info(role: String?, frame: CGRect) -> AXAncestorInfo {
            AXAncestorInfo(pid: 100, role: role, subrole: nil, identifier: nil, roleDescription: nil, frame: frame)
        }

        // 1. AXStaticText inside AXButton promotes to AXButton.
        let buttonFrame = CGRect(x: 100, y: 800, width: 88, height: 28)
        let buttonChain = [
            info(role: "AXStaticText", frame: CGRect(x: 124, y: 807, width: 40, height: 14)),
            info(role: "AXGroup", frame: CGRect(x: 104, y: 802, width: 80, height: 24)),
            info(role: "AXButton", frame: buttonFrame),
            info(role: "AXWindow", frame: windowFrame),
        ]
        #expect(SmartElementDetector.selectRefinedElementRect(from: buttonChain, at: CGPoint(x: 140, y: 814), containerFrame: windowFrame) == buttonFrame)

        // 2. Tiny (<18x18) icon leaf promotes to semantic parent container.
        let chipFrame = CGRect(x: 200, y: 700, width: 64, height: 26)
        let tinyChain = [
            info(role: "AXImage", frame: CGRect(x: 208, y: 707, width: 12, height: 12)),
            info(role: "AXGroup", frame: chipFrame),
            info(role: "AXWindow", frame: windowFrame),
        ]
        #expect(SmartElementDetector.selectRefinedElementRect(from: tinyChain, at: CGPoint(x: 214, y: 713), containerFrame: windowFrame) == chipFrame)

        // 3. Scroll-overflowing AXTextArea is clipped to enclosing AXScrollArea instead of rejected.
        let scrollArea = CGRect(x: 220, y: 40, width: 960, height: 800)
        let scrolledTextChain = [
            info(role: "AXTextArea", frame: CGRect(x: 220, y: -1200, width: 960, height: 2800)),
            info(role: "AXScrollArea", frame: scrollArea),
            info(role: "AXWindow", frame: windowFrame),
        ]
        #expect(SmartElementDetector.selectRefinedElementRect(from: scrolledTextChain, at: CGPoint(x: 500, y: 400), containerFrame: windowFrame) == scrollArea)

        // 4. Chrome roles (AXScrollBar, AXValueIndicator, AXSplitter) are skipped; full-window hits return nil.
        let scrollbarChain = [
            info(role: "AXValueIndicator", frame: CGRect(x: 1185, y: 300, width: 10, height: 80)),
            info(role: "AXScrollBar", frame: CGRect(x: 1185, y: 0, width: 15, height: 900)),
            info(role: "AXWindow", frame: windowFrame),
        ]
        #expect(SmartElementDetector.selectRefinedElementRect(from: scrollbarChain, at: CGPoint(x: 1190, y: 340), containerFrame: windowFrame) == nil)

        // 5. Near-full-window element returns nil (Tier 1 already highlights the window).
        let fullHitChain = [
            info(role: "AXWebArea", frame: CGRect(x: 1, y: 1, width: 1198, height: 898)),
            info(role: "AXWindow", frame: windowFrame),
        ]
        #expect(SmartElementDetector.selectRefinedElementRect(from: fullHitChain, at: CGPoint(x: 500, y: 500), containerFrame: windowFrame) == nil)

        // 6. Non-finite and negative-size rects fail isPlausibleElementRect cleanly.
        #expect(!SmartElementDetector.isPlausibleElementRect(CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 20), containing: CGPoint(x: 20, y: 20), within: nil))
        #expect(!SmartElementDetector.isPlausibleElementRect(CGRect(x: 50, y: 50, width: -20, height: -20), containing: CGPoint(x: 40, y: 40), within: windowFrame))
    }

    @Test @MainActor func fallbackOverlayTakesPriorityAboveOwnPIDWindowAndRespectsZOrder() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let receivedRequests = OSAllocatedUnfairLock(initialState: [AXQueryWorker.Request]())
        let worker = AXQueryWorker(excludedPID: ownPID, minimumInterval: 0) { request, _ in
            receivedRequests.withLock { $0.append(request) }
            return AXQueryWorker.QueryResult(rect: CGRect(x: 1150, y: 500, width: 340, height: 120), isOverlay: true, timedOut: false)
        }
        let detector = SmartElementDetector(customAXWorker: worker)

        let ownPin = DetectedWindow(
            windowID: 50,
            ownerPID: ownPID,
            ownerName: "CCX",
            layer: 3,
            frame: CGRect(x: 1100, y: 400, width: 400, height: 300)
        )
        let frontFallbackNC = OverlayWindowEntry(
            window: DetectedWindow(
                windowID: 51,
                ownerPID: 1127,
                ownerName: "Notification Center",
                layer: 23,
                frame: CGRect(x: 1120, y: 0, width: 392, height: 982)
            ),
            zOrderIndex: 0
        )
        let behindFallbackNC = OverlayWindowEntry(
            window: DetectedWindow(
                windowID: 52,
                ownerPID: 1127,
                ownerName: "Notification Center",
                layer: 23,
                frame: CGRect(x: 1120, y: 0, width: 392, height: 982)
            ),
            zOrderIndex: 1
        )

        // Overlay in front of ownPin (zOrderIndex 0 <= regularHitIndex 0): Tier 2 runs overlay-only!
        detector.setDetectedStateForTesting(
            regularWindows: [ownPin],
            windows: [ownPin],
            fallbackOverlayWindows: [frontFallbackNC]
        )
        let pt = CGPoint(x: 1200, y: 550)
        #expect(detector.shouldRequestElementRect(at: pt) == true)

        let delivered = await withCheckedContinuation { continuation in
            detector.requestElementRect(at: pt) { rect, point, isOverlay in
                continuation.resume(returning: (rect, point, isOverlay))
            }
        }
        #expect(delivered.2 == true)
        #expect(delivered.1 == pt)
        let recorded = receivedRequests.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.targetWindow == nil)
        #expect(recorded.first?.overlayFallback?.windowID == 51)

        // Overlay behind ownPin (zOrderIndex 1 > regularHitIndex 0): skipped!
        detector.setDetectedStateForTesting(
            regularWindows: [ownPin],
            windows: [ownPin],
            fallbackOverlayWindows: [behindFallbackNC]
        )
        #expect(detector.shouldRequestElementRect(at: pt) == false)
    }

    @Test @MainActor func prepareOverlayElementsWithAccessibilityDisabledFallsBackCleanly() async {
        let detector = SmartElementDetector(enableAccessibility: false)
        let chrome = DetectedWindow(windowID: 1, ownerPID: 20, ownerName: "Chrome", layer: 0, frame: CGRect(x: 0, y: 0, width: 1512, height: 948))
        let compactBanner = OverlayWindowEntry(
            window: DetectedWindow(windowID: 2, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 1140, y: 860, width: 350, height: 90)),
            zOrderIndex: 0
        )
        let fullScreenNC = OverlayWindowEntry(
            window: DetectedWindow(windowID: 3, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            zOrderIndex: 0
        )
        detector.setDetectedStateForTesting(
            regularWindows: [chrome],
            windows: [chrome],
            fallbackOverlayWindows: [],
            pendingOverlayWindows: [compactBanner, fullScreenNC]
        )

        await detector.prepareOverlayElements()
        #expect(detector.windows.map(\.windowID) == [2, 1])
        #expect(detector.fallbackOverlayWindows.map(\.window.windowID) == [3])
    }

    private nonisolated func waitOnBackground(_ semaphore: DispatchSemaphore, timeoutSeconds: TimeInterval = 2) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = semaphore.wait(timeout: .now() + timeoutSeconds)
                continuation.resume()
            }
        }
    }

    @Test @MainActor func axQueryWorkerCoalescesCancelsMidIPCAndSuppressesStaleNil() async {
        // 1. Mid-IPC cancellation immediately drops in-flight completion (even while worker thread is blocked).
        let ipcStarted = DispatchSemaphore(value: 0)
        let releaseIPC = DispatchSemaphore(value: 0)
        let observedCancel = OSAllocatedUnfairLock(initialState: false)
        let deliveredCount = OSAllocatedUnfairLock(initialState: 0)

        let cancelWorker = AXQueryWorker(excludedPID: 1, minimumInterval: 0) { _, isCancelled in
            ipcStarted.signal()
            releaseIPC.wait()
            observedCancel.withLock { $0 = isCancelled() }
            return AXQueryWorker.QueryResult(rect: CGRect(x: 10, y: 10, width: 100, height: 40), isOverlay: false, timedOut: false)
        }

        let targetA = AXQueryWorker.WindowTarget(windowID: 10, pid: 100, containerFrame: CGRect(x: 0, y: 0, width: 800, height: 600))
        cancelWorker.enqueue(
            AXQueryWorker.Request(point: CGPoint(x: 50, y: 50), primaryScreenHeight: 982, targetWindow: targetA, overlayFallback: nil)
        ) { _, _, _ in
            deliveredCount.withLock { $0 += 1 }
        }

        await waitOnBackground(ipcStarted)
        cancelWorker.cancelPending()
        releaseIPC.signal()
        try? await Task.sleep(for: .milliseconds(40))

        #expect(observedCancel.withLock { $0 } == true)
        #expect(deliveredCount.withLock { $0 } == 0)

        // 2. Coalescing + stale nil suppression: while request 1 (returning nil) is in flight,
        //    requests 2 and 3 arrive -> request 1's stale nil is dropped and only latest point (3) runs.
        let ipc2Started = DispatchSemaphore(value: 0)
        let releaseIPC2 = DispatchSemaphore(value: 0)
        let queriedPoints = OSAllocatedUnfairLock(initialState: [CGPoint]())
        let deliveredPoints = OSAllocatedUnfairLock(initialState: [(CGRect?, CGPoint)]())
        let finalDone = DispatchSemaphore(value: 0)

        let coalesceWorker = AXQueryWorker(excludedPID: 1, minimumInterval: 0.01) { request, _ in
            let count = queriedPoints.withLock { list -> Int in
                list.append(request.point)
                return list.count
            }
            if count == 1 {
                ipc2Started.signal()
                releaseIPC2.wait()
                return AXQueryWorker.QueryResult(rect: nil, isOverlay: false, timedOut: false)
            }
            return AXQueryWorker.QueryResult(rect: CGRect(x: 200, y: 200, width: 120, height: 40), isOverlay: false, timedOut: false)
        }

        let p1 = CGPoint(x: 10, y: 10)
        let p2 = CGPoint(x: 20, y: 20)
        let p3 = CGPoint(x: 250, y: 220)
        coalesceWorker.enqueue(AXQueryWorker.Request(point: p1, primaryScreenHeight: 982, targetWindow: targetA, overlayFallback: nil)) { rect, pt, _ in
            deliveredPoints.withLock { $0.append((rect, pt)) }
        }
        await waitOnBackground(ipc2Started)
        coalesceWorker.enqueue(AXQueryWorker.Request(point: p2, primaryScreenHeight: 982, targetWindow: targetA, overlayFallback: nil)) { rect, pt, _ in
            deliveredPoints.withLock { $0.append((rect, pt)) }
        }
        coalesceWorker.enqueue(AXQueryWorker.Request(point: p3, primaryScreenHeight: 982, targetWindow: targetA, overlayFallback: nil)) { rect, pt, _ in
            deliveredPoints.withLock { $0.append((rect, pt)) }
            finalDone.signal()
        }
        releaseIPC2.signal()
        await waitOnBackground(finalDone)

        #expect(queriedPoints.withLock { $0 } == [p1, p3])
        let results = deliveredPoints.withLock { $0 }
        #expect(results.count == 1)
        #expect(results.first?.1 == p3)
        #expect(results.first?.0 == CGRect(x: 200, y: 200, width: 120, height: 40))

        // 3. Switching target windowID mid-IPC invalidates the previous window's in-flight result.
        let ipc3Started = DispatchSemaphore(value: 0)
        let releaseIPC3 = DispatchSemaphore(value: 0)
        let switchDeliveries = OSAllocatedUnfairLock(initialState: [CGPoint]())
        let switchDone = DispatchSemaphore(value: 0)
        let targetB = AXQueryWorker.WindowTarget(windowID: 20, pid: 100, containerFrame: CGRect(x: 0, y: 0, width: 800, height: 600))

        let switchWorker = AXQueryWorker(excludedPID: 1, minimumInterval: 0) { request, _ in
            if request.targetWindow?.windowID == 10 {
                ipc3Started.signal()
                releaseIPC3.wait()
            }
            return AXQueryWorker.QueryResult(rect: CGRect(x: 30, y: 30, width: 100, height: 40), isOverlay: false, timedOut: false)
        }
        let ptA = CGPoint(x: 50, y: 50)
        let ptB = CGPoint(x: 60, y: 60)
        switchWorker.enqueue(AXQueryWorker.Request(point: ptA, primaryScreenHeight: 982, targetWindow: targetA, overlayFallback: nil)) { _, pt, _ in
            switchDeliveries.withLock { $0.append(pt) }
        }
        await waitOnBackground(ipc3Started)
        switchWorker.enqueue(AXQueryWorker.Request(point: ptB, primaryScreenHeight: 982, targetWindow: targetB, overlayFallback: nil)) { _, pt, _ in
            switchDeliveries.withLock { $0.append(pt) }
            switchDone.signal()
        }
        releaseIPC3.signal()
        await waitOnBackground(switchDone)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(switchDeliveries.withLock { $0 } == [ptB])
    }

    @Test @MainActor func axElementReaderDetectsMultiCopyTimeoutsRejectsHugeCoordsAndPreservesPerPIDBackoff() async throws {
        // 1. AXValue wrapping kAXErrorCannotComplete inside multi-copy array is detected as timedOut.
        var cannotComplete = AXError.cannotComplete
        let timeoutVal = try #require(AXValueCreate(.axError, &cannotComplete))
        var unsupported = AXError.attributeUnsupported
        let unsupportedVal = try #require(AXValueCreate(.axError, &unsupported))
        #expect(AXElementReader.containsCannotCompleteError(in: ["AXGroup" as NSString, timeoutVal]))
        #expect(!AXElementReader.containsCannotCompleteError(in: ["AXGroup" as NSString, unsupportedVal]))

        // 2. Extreme / corrupt AX coordinates (> 1e6) are rejected cleanly.
        #expect(AXElementReader.convertQuartzFrame(
            position: CGPoint(x: 1e12, y: 10),
            size: CGSize(width: 100, height: 50),
            primaryScreenHeight: 982
        ) == nil)
        #expect(AXElementReader.convertQuartzFrame(
            position: CGPoint(x: 10, y: 10),
            size: CGSize(width: 2_000_000, height: 50),
            primaryScreenHeight: 982
        ) == nil)
        #expect(AXElementReader.convertQuartzFrame(
            position: CGPoint(x: 10, y: 50),
            size: CGSize(width: 100, height: 40),
            primaryScreenHeight: 982
        ) != nil)

        // 3. Per-PID timeout backoff persists across sibling windowIDs of the same hung PID and resets on success.
        let hungPID: pid_t = 4242
        let win1 = AXQueryWorker.WindowTarget(windowID: 101, pid: hungPID, containerFrame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let win2 = AXQueryWorker.WindowTarget(windowID: 102, pid: hungPID, containerFrame: CGRect(x: 600, y: 0, width: 600, height: 400))
        let queryCount = OSAllocatedUnfairLock(initialState: 0)
        let done1 = DispatchSemaphore(value: 0)
        let done2 = DispatchSemaphore(value: 0)
        let done3 = DispatchSemaphore(value: 0)

        let worker = AXQueryWorker(excludedPID: 1, minimumInterval: 0) { _, _ in
            let n = queryCount.withLock { c -> Int in
                c += 1
                return c
            }
            if n <= 2 {
                return AXQueryWorker.QueryResult(rect: nil, isOverlay: false, timedOut: true)
            }
            return AXQueryWorker.QueryResult(rect: CGRect(x: 10, y: 10, width: 80, height: 30), isOverlay: false, timedOut: false)
        }

        worker.enqueue(AXQueryWorker.Request(point: CGPoint(x: 50, y: 50), primaryScreenHeight: 982, targetWindow: win1, overlayFallback: nil)) { _, _, _ in
            done1.signal()
        }
        await waitOnBackground(done1)
        #expect(worker.timeoutCountForTesting(pid: hungPID) == 1)

        // Switch to sibling window of same PID -> timeout count must NOT reset to 0, advances to 2.
        worker.enqueue(AXQueryWorker.Request(point: CGPoint(x: 650, y: 50), primaryScreenHeight: 982, targetWindow: win2, overlayFallback: nil)) { _, _, _ in
            done2.signal()
        }
        await waitOnBackground(done2)
        #expect(worker.timeoutCountForTesting(pid: hungPID) == 2)

        // Successful query clears per-PID timeout backoff.
        worker.enqueue(AXQueryWorker.Request(point: CGPoint(x: 660, y: 50), primaryScreenHeight: 982, targetWindow: win2, overlayFallback: nil)) { _, _, _ in
            done3.signal()
        }
        await waitOnBackground(done3)
        #expect(worker.timeoutCountForTesting(pid: hungPID) == 0)
    }

    @Test @MainActor func snipCoordinatorAwaitTaskTimesOutPromptlyAndPreservesOverlayFallback() async throws {
        // 1. SnipCoordinator.awaitTask returns promptly at timeout even when an unstructured task blocks.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }

        let (completed, elapsed) = await Task.detached(priority: .userInitiated) {
            let hungTask = Task<Void, Never> {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async {
                        _ = gate.wait(timeout: .now() + 3)
                        cont.resume()
                    }
                }
            }
            let start = ContinuousClock.now
            let ok = await SnipCoordinator.awaitTask(hungTask, timeoutNanoseconds: 40_000_000)
            return (ok, ContinuousClock.now - start)
        }.value

        #expect(!completed)
        #expect(elapsed < .milliseconds(400))

        // 2. Cancelling a hung prepareOverlayElements wakes promptly and preserves fallback overlays & compact banners.
        let chrome = DetectedWindow(windowID: 1, ownerPID: 20, ownerName: "Chrome", layer: 0, frame: CGRect(x: 0, y: 0, width: 1512, height: 948))
        let compactBanner = OverlayWindowEntry(
            window: DetectedWindow(windowID: 2, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 1140, y: 860, width: 350, height: 90)),
            zOrderIndex: 0
        )
        let fullScreenNC = OverlayWindowEntry(
            window: DetectedWindow(windowID: 3, ownerPID: 1127, ownerName: "Notification Center", layer: 23, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            zOrderIndex: 0
        )
        let detector = SmartElementDetector(enableAccessibility: true, forceAccessibilityForTesting: true)
        detector.setDetectedStateForTesting(
            regularWindows: [chrome],
            windows: [chrome],
            fallbackOverlayWindows: [],
            pendingOverlayWindows: [compactBanner, fullScreenNC]
        )

        let xpcBlocked = DispatchSemaphore(value: 0)
        let releaseXPC = DispatchSemaphore(value: 0)
        defer { releaseXPC.signal() }

        let prepTask = Task { @MainActor in
            await detector.prepareOverlayElements { _, _ in
                xpcBlocked.signal()
                _ = releaseXPC.wait(timeout: .now() + 3)
                return [:]
            }
        }
        await waitOnBackground(xpcBlocked)
        let cancelStart = ContinuousClock.now
        let prepFinished = await SnipCoordinator.awaitTask(prepTask, timeoutNanoseconds: 35_000_000)
        let wakeElapsed = ContinuousClock.now - cancelStart
        detector.finalizePendingOverlayFallbackIfNeeded()

        #expect(!prepFinished)
        #expect(wakeElapsed < .milliseconds(400))
        // Compact banner is spliced into `windows`, and full-screen NC is preserved in `fallbackOverlayWindows`.
        #expect(detector.windows.map(\.windowID) == [2, 1])
        #expect(detector.fallbackOverlayWindows.map(\.window.windowID) == [3])
    }

    @Test @MainActor func axQueryWorkerSwitchingFromHungPIDToFastPIDDoesNotStallBehindCooldown() async throws {
        let hungPID: pid_t = 9001
        let fastPID: pid_t = 9002
        let hungWin = AXQueryWorker.WindowTarget(windowID: 201, pid: hungPID, containerFrame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let fastWin = AXQueryWorker.WindowTarget(windowID: 202, pid: fastPID, containerFrame: CGRect(x: 500, y: 0, width: 500, height: 400))

        let worker = AXQueryWorker(excludedPID: 1, minimumInterval: 0) { request, _ in
            if request.targetWindow?.pid == hungPID {
                return AXQueryWorker.QueryResult(rect: nil, isOverlay: false, timedOut: true)
            }
            return AXQueryWorker.QueryResult(rect: CGRect(x: 520, y: 40, width: 80, height: 30), isOverlay: false, timedOut: false)
        }

        // Trigger 3 consecutive timeouts on hungPID so it enters a 300ms cooldown.
        for i in 0..<3 {
            let sem = DispatchSemaphore(value: 0)
            worker.enqueue(AXQueryWorker.Request(point: CGPoint(x: 20 + i, y: 20), primaryScreenHeight: 982, targetWindow: hungWin, overlayFallback: nil)) { _, _, _ in
                sem.signal()
            }
            await waitOnBackground(sem)
        }
        #expect(worker.timeoutCountForTesting(pid: hungPID) == 3)

        // Schedule a query on hungPID (armed on a 300ms asyncAfter cooldown timer), then immediately switch to fastPID.
        worker.enqueue(AXQueryWorker.Request(point: CGPoint(x: 40, y: 20), primaryScreenHeight: 982, targetWindow: hungWin, overlayFallback: nil)) { _, _, _ in }

        let fastDone = DispatchSemaphore(value: 0)
        let switchStart = ContinuousClock.now
        worker.enqueue(AXQueryWorker.Request(point: CGPoint(x: 550, y: 50), primaryScreenHeight: 982, targetWindow: fastWin, overlayFallback: nil)) { _, _, _ in
            fastDone.signal()
        }
        await waitOnBackground(fastDone)
        let elapsed = ContinuousClock.now - switchStart
        #expect(elapsed < .milliseconds(150))
    }

    @Test @MainActor func sanitizationGuardsNaNInfHugeRectsAndOversizedAXStrings() {
        // 1. parseWindowList drops NaN/Inf alpha, non-finite screen height, huge magnitudes, and NaN bounds.
        let validEntry = entry(id: 100, pid: 42, layer: 0, x: 40, y: 60, width: 320, height: 220, alpha: 1.0, owner: "ValidApp")
        let nanAlphaEntry = entry(id: 101, pid: 42, layer: 0, x: 40, y: 60, width: 320, height: 220, alpha: .nan, owner: "BadAlpha")
        let infAlphaEntry = entry(id: 102, pid: 42, layer: 0, x: 40, y: 60, width: 320, height: 220, alpha: .infinity, owner: "InfAlpha")
        let hugeCoordEntry = entry(id: 103, pid: 42, layer: 0, x: 1e12, y: 60, width: 320, height: 220, alpha: 1.0, owner: "HugeX")
        let hugeSizeEntry = entry(id: 104, pid: 42, layer: 0, x: 40, y: 60, width: 2_000_000, height: 220, alpha: 1.0, owner: "HugeW")
        let nanBoundEntry = entry(id: 105, pid: 42, layer: 0, x: .nan, y: 60, width: 320, height: 220, alpha: 1.0, owner: "NaNX")

        let parsed = SmartElementDetector.parseWindowList(
            [validEntry, nanAlphaEntry, infAlphaEntry, hugeCoordEntry, hugeSizeEntry, nanBoundEntry],
            primaryScreenHeight: 982
        )
        #expect(parsed.map(\.windowID) == [100])

        // Non-finite primaryScreenHeight rejects all entries cleanly instead of producing NaN frames.
        #expect(SmartElementDetector.parseWindowList([validEntry], primaryScreenHeight: .nan).isEmpty)
        #expect(SmartElementDetector.parseWindowList([validEntry], primaryScreenHeight: .infinity).isEmpty)

        // 2. hitTest / shouldRequestElementRect reject non-finite and out-of-range coordinates.
        let detector = SmartElementDetector(enableAccessibility: true, forceAccessibilityForTesting: true)
        let normalWindow = DetectedWindow(windowID: 100, ownerPID: 42, ownerName: "ValidApp", layer: 0, frame: CGRect(x: 40, y: 40, width: 400, height: 300))
        detector.setDetectedStateForTesting(regularWindows: [normalWindow], windows: [normalWindow], fallbackOverlayWindows: [])
        #expect(SmartElementDetector.hitTest([normalWindow], at: CGPoint(x: CGFloat.nan, y: 100)) == nil)
        #expect(SmartElementDetector.hitTest([normalWindow], at: CGPoint(x: CGFloat.infinity, y: 100)) == nil)
        #expect(SmartElementDetector.hitTest([normalWindow], at: CGPoint(x: 1e12, y: 100)) == nil)
        #expect(SmartElementDetector.hitTest([normalWindow], at: CGPoint(x: 100, y: 100))?.windowID == 100)
        #expect(detector.shouldRequestElementRect(at: CGPoint(x: CGFloat.nan, y: 100)) == false)
        #expect(detector.shouldRequestElementRect(at: CGPoint(x: 1e12, y: 100)) == false)

        // 3. Card & Tier-2 element geometry helpers reject NaN / Inf / > 1e6 rects.
        let windowFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let hugeRect = CGRect(x: 0, y: 0, width: 2_000_000, height: 200)
        let hugeOrigin = CGRect(x: 2_000_000, y: 100, width: 300, height: 120)
        #expect(!SmartElementDetector.isCardSized(hugeRect, in: windowFrame))
        #expect(!SmartElementDetector.isCardSized(hugeOrigin, in: windowFrame))
        #expect(!SmartElementDetector.isPlausibleElementRect(hugeRect, containing: CGPoint(x: 50, y: 50), within: windowFrame))
        #expect(!SmartElementDetector.isPlausibleElementRect(CGRect(x: 10, y: 10, width: 80, height: 40), containing: CGPoint(x: CGFloat.nan, y: 20), within: windowFrame))

        let badChain = [
            AXAncestorInfo(pid: 42, role: "AXButton", subrole: nil, identifier: nil, roleDescription: nil, frame: hugeRect),
            AXAncestorInfo(pid: 42, role: "AXGroup", subrole: nil, identifier: nil, roleDescription: nil, frame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 50)),
        ]
        #expect(SmartElementDetector.selectRefinedElementRect(from: badChain, at: CGPoint(x: 50, y: 50), containerFrame: windowFrame) == nil)
        #expect(SmartElementDetector.selectRefinedElementRect(from: badChain, at: CGPoint(x: CGFloat.nan, y: 50), containerFrame: windowFrame) == nil)

        let pruned = SmartElementDetector.deduplicateAndPruneCards(
            [.null, .infinite, hugeRect, CGRect(x: 1142, y: 700, width: 352, height: 84)],
            in: windowFrame
        )
        #expect(pruned == [CGRect(x: 1142, y: 700, width: 352, height: 84)])
        #expect(SmartElementDetector.deduplicateAndPruneCards([CGRect(x: 100, y: 100, width: 200, height: 100)], in: .infinite).isEmpty)

        // 4. AXElementReader.boundedAXString rejects empty, non-string, and > 256-byte untrusted AX strings.
        #expect(AXElementReader.boundedAXString("AXButton" as NSString) == "AXButton")
        #expect(AXElementReader.boundedAXString("" as NSString) == nil)
        #expect(AXElementReader.boundedAXString(NSNumber(value: 42)) == nil)
        let exactLimit = String(repeating: "a", count: 256)
        let overLimit = String(repeating: "a", count: 257)
        let multibyteOverLimit = String(repeating: "中", count: 90) // 270 UTF-8 bytes > 256
        #expect(AXElementReader.boundedAXString(exactLimit as NSString) == exactLimit)
        #expect(AXElementReader.boundedAXString(overLimit as NSString) == nil)
        #expect(AXElementReader.boundedAXString(multibyteOverLimit as NSString) == nil)
    }
}

@Suite("Overlay geometry")
struct OverlayGeometryTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test @MainActor func toolbarPrefersBelowThenAboveThenInside() {
        let size = SnipActionToolbar.preferredSize
        let below = SnipActionToolbar.frame(for: CGRect(x: 400, y: 400, width: 300, height: 200), in: bounds, topInset: 32)
        #expect(below.maxY <= 400 && below.midX == 550)
        let above = SnipActionToolbar.frame(for: CGRect(x: 400, y: 0, width: 300, height: 200), in: bounds, topInset: 32)
        #expect(above.minY >= 200 && above.midX == 550)
        let inside = SnipActionToolbar.frame(for: bounds, in: bounds, topInset: 32)
        #expect(bounds.contains(inside) && inside.size == size && inside.midX == bounds.midX)
        let leftEdge = SnipActionToolbar.frame(for: CGRect(x: 0, y: 400, width: 20, height: 20), in: bounds, topInset: 32)
        #expect(leftEdge.minX == 0)
        let rightEdge = SnipActionToolbar.frame(for: CGRect(x: 1492, y: 400, width: 20, height: 20), in: bounds, topInset: 32)
        #expect(rightEdge.maxX == bounds.maxX)

        let expanded = SnipActionToolbar.frame(for: CGRect(x: 400, y: 400, width: 300, height: 200), in: bounds, topInset: 32, showsStyleBar: true)
        #expect(bounds.contains(expanded) && expanded.size == SnipActionToolbar.expandedSize)
        #expect(expanded.maxY <= 400 && expanded.midX == 550)
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
