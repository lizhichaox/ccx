import AppKit
import CoreGraphics
import CCXAnnotate
import CCXCore
import Testing
@testable import CCXCapture

@Suite("SnipOverlayView")
@MainActor
struct SnipOverlayViewTests {
    private func makeSnapshot(scale: CGFloat = 2, size: CGSize = CGSize(width: 200, height: 100)) throws -> DisplaySnapshot {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return DisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(origin: .zero, size: size),
            backingScaleFactor: scale,
            image: image
        )
    }

    private func makeKeyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func makeMouseEvent(type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private func selectRect(_ rect: CGRect, on view: SnipOverlayView) throws {
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: rect.origin))
        let end = CGPoint(x: rect.maxX, y: rect.maxY)
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: end))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: end))
    }

    @Test func retinaContentsScaleAppliedToAllOverlayLayers() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(scale: 2), topInset: 0)
        let rootLayer = try #require(view.layer)
        #expect(rootLayer.contentsScale == 2)
        let sublayers = try #require(rootLayer.sublayers)
        #expect(sublayers.count >= 4)
        for layer in sublayers.prefix(4) {
            #expect(layer.contentsScale == 2)
        }
    }

    @Test func performKeyEquivalentHandlesCmdCAndCmdSForSelection() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        let selection = CGRect(x: 20, y: 10, width: 80, height: 40)
        try selectRect(selection, on: view)

        var actions: [OverlayAction] = []
        view.onFinish = { actions.append($0) }

        let cmdC = try makeKeyEvent(characters: "c", modifiers: [.command], keyCode: 8)
        #expect(view.performKeyEquivalent(with: cmdC) == true)
        #expect(actions == [.copy(selection)])

        let cmdS = try makeKeyEvent(characters: "s", modifiers: [.command, .capsLock], keyCode: 1)
        #expect(view.performKeyEquivalent(with: cmdS) == true)
        #expect(actions == [.copy(selection), .save(selection)])

        let cmdShiftC = try makeKeyEvent(characters: "C", modifiers: [.command, .shift], keyCode: 8)
        #expect(view.performKeyEquivalent(with: cmdShiftC) == false)
        #expect(actions.count == 2)

        let cmdX = try makeKeyEvent(characters: "x", modifiers: [.command], keyCode: 7)
        #expect(view.performKeyEquivalent(with: cmdX) == false)
        #expect(actions.count == 2)
    }

    @Test func performKeyEquivalentHandlesCmdCColorCopyAndIgnoresCmdSWhileHovering() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        view.primeWithMouseLocation(CGPoint(x: 50, y: 50))

        var actions: [OverlayAction] = []
        view.onFinish = { actions.append($0) }

        let cmdS = try makeKeyEvent(characters: "s", modifiers: [.command], keyCode: 1)
        #expect(view.performKeyEquivalent(with: cmdS) == false)
        #expect(actions.isEmpty)

        let cmdC = try makeKeyEvent(characters: "c", modifiers: [.command], keyCode: 8)
        #expect(view.performKeyEquivalent(with: cmdC) == true)
        guard case let .copyColor(sample, format) = actions.first else {
            Issue.record("Expected .copyColor action, got \(actions)")
            return
        }
        #expect(format == .hex)
        #expect(sample.red == 51 && sample.green == 102 && sample.blue == 153)
    }

    @Test func hoverInsideRefinedElementNeverBouncesBackToTier1Window() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        let windowRect = CGRect(x: 10, y: 10, width: 180, height: 80)
        let elementRect = CGRect(x: 20, y: 20, width: 50, height: 40)
        view.hoverRectProvider = { _ in windowRect }

        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 30, y: 30)))
        #expect(view.machine.highlightedRect == windowRect)

        view.applyRefinedElementRect(elementRect, forGlobalPoint: CGPoint(x: 30, y: 30))
        #expect(view.machine.highlightedRect == elementRect)

        for pt in [CGPoint(x: 32, y: 31), CGPoint(x: 45, y: 40), CGPoint(x: 65, y: 55)] {
            view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: pt))
            #expect(view.machine.highlightedRect == elementRect)
        }
    }

    @Test func hoverBridgesSmallGapAndSwitchesOrFallsBackCleanly() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        let windowRect = CGRect(x: 10, y: 10, width: 180, height: 80)
        let elementA = CGRect(x: 20, y: 20, width: 40, height: 30)
        let elementB = CGRect(x: 70, y: 20, width: 40, height: 30)
        view.hoverRectProvider = { _ in windowRect }

        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 35, y: 35)))
        view.applyRefinedElementRect(elementA, forGlobalPoint: CGPoint(x: 35, y: 35))
        #expect(view.machine.highlightedRect == elementA)

        // Step into 10pt gap between elementA and elementB: holds elementA without flashing windowRect.
        let gapPoint = CGPoint(x: 65, y: 35)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: gapPoint))
        #expect(view.machine.highlightedRect == elementA)

        // Move into elementB (even > 8pt from elementA's query point) and receive refined elementB.
        let pointB = CGPoint(x: 80, y: 35)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: pointB))
        view.applyRefinedElementRect(elementB, forGlobalPoint: pointB)
        #expect(view.machine.highlightedRect == elementB)

        // Step back into empty gap and receive nil from AX: falls back cleanly to windowRect.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: gapPoint))
        #expect(view.machine.highlightedRect == elementB)
        view.applyRefinedElementRect(nil, forGlobalPoint: gapPoint)
        #expect(view.machine.highlightedRect == windowRect)
    }

    @Test func nilAXResultDoesNotClearRefinedRectWhileCursorIsInside() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        let windowRect = CGRect(x: 10, y: 10, width: 180, height: 80)
        let elementRect = CGRect(x: 20, y: 20, width: 50, height: 40)
        view.hoverRectProvider = { _ in windowRect }

        let inside = CGPoint(x: 40, y: 35)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: inside))
        view.applyRefinedElementRect(elementRect, forGlobalPoint: inside)
        #expect(view.machine.highlightedRect == elementRect)

        view.applyRefinedElementRect(nil, forGlobalPoint: inside)
        #expect(view.machine.highlightedRect == elementRect)
    }

    @Test func leavingGapMarginOrWindowTransitionsToTier1Rect() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        let window1 = CGRect(x: 10, y: 10, width: 100, height: 80)
        let window2 = CGRect(x: 120, y: 10, width: 70, height: 80)
        let element1 = CGRect(x: 15, y: 20, width: 30, height: 30)
        view.hoverRectProvider = { pt in pt.x >= 120 ? window2 : window1 }

        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 25, y: 35)))
        view.applyRefinedElementRect(element1, forGlobalPoint: CGPoint(x: 25, y: 35))
        #expect(view.machine.highlightedRect == element1)

        // Beyond 24pt bridge margin inside window1 (element1.maxX == 45 -> x == 80 is +35pt).
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 80, y: 35)))
        #expect(view.machine.highlightedRect == window1)

        // Re-apply element1, then move directly into window2.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 25, y: 35)))
        view.applyRefinedElementRect(element1, forGlobalPoint: CGPoint(x: 25, y: 35))
        #expect(view.machine.highlightedRect == element1)

        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 140, y: 35)))
        #expect(view.machine.highlightedRect == window2)
    }

    @Test func clickingInGapBridgeSelectsTier1WindowNotStaleElement() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        let windowRect = CGRect(x: 10, y: 10, width: 180, height: 80)
        let elementA = CGRect(x: 20, y: 20, width: 40, height: 30)
        view.hoverRectProvider = { _ in windowRect }

        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 35, y: 35)))
        view.applyRefinedElementRect(elementA, forGlobalPoint: CGPoint(x: 35, y: 35))
        #expect(view.machine.highlightedRect == elementA)

        // Hover in the gap outside elementA (still bridged visually as elementA), then click.
        let gapPoint = CGPoint(x: 65, y: 35)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: gapPoint))
        #expect(view.machine.highlightedRect == elementA)

        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: gapPoint))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: gapPoint))
        #expect(view.machine.selectionRect == windowRect)
    }

    @Test func performKeyEquivalentHandlesCmdWCancelInHoverAndSelectedStates() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        var actions: [OverlayAction] = []
        view.onFinish = { actions.append($0) }

        let cmdW = try makeKeyEvent(characters: "w", modifiers: [.command], keyCode: 13)
        #expect(view.performKeyEquivalent(with: cmdW) == true)
        #expect(actions == [.cancel])

        try selectRect(CGRect(x: 20, y: 10, width: 80, height: 40), on: view)
        #expect(view.performKeyEquivalent(with: cmdW) == true)
        #expect(actions == [.cancel, .cancel])
    }

    @Test func annotationToolsDrawUndoRedoAndDeleteInSelectedRegion() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(), topInset: 0)
        try selectRect(CGRect(x: 10, y: 10, width: 180, height: 80), on: view)

        // Key "1" activates Rectangle tool.
        view.keyDown(with: try makeKeyEvent(characters: "1", modifiers: [], keyCode: 18))
        #expect(view.activeTool == .rectangle)

        // Draw rectangle inside selection.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 30, y: 20)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 80, y: 60)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 80, y: 60)))
        #expect(view.annotations.items.count == 1)
        #expect(view.annotations.canUndo)

        // Cmd+Z undoes, Shift+Cmd+Z redoes.
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "z", modifiers: [.command], keyCode: 6)))
        #expect(view.annotations.items.isEmpty)
        #expect(view.annotations.canRedo)

        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "Z", modifiers: [.command, .shift], keyCode: 6)))
        #expect(view.annotations.items.count == 1)

        // Delete key removes the selected annotation.
        view.keyDown(with: try makeKeyEvent(characters: "\u{7F}", modifiers: [], keyCode: 51))
        #expect(view.annotations.items.isEmpty)
    }

    @Test func snipErgonomicsOCRCmdACmdDArrowNudgeRightClickAndStylePersistence() throws {
        var persistedStyle: AnnotationStyle?
        let view = SnipOverlayView(
            snapshot: try makeSnapshot(),
            topInset: 0,
            initialStyle: AnnotationStyle(color: .blue, size: .large)
        )
        #expect(view.currentStyle.color == .blue)
        view.onStyleUpdated = { persistedStyle = $0 }
        view.applyStyle(AnnotationStyle(color: .green, size: .small))
        #expect(persistedStyle == AnnotationStyle(color: .green, size: .small))

        var actions: [OverlayAction] = []
        view.onFinish = { actions.append($0) }

        // Cmd+A while hovering selects the full display bounds.
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "a", modifiers: [.command], keyCode: 0)))
        #expect(view.machine.selectionRect == CGRect(x: 0, y: 0, width: 200, height: 100))

        // Activate Rectangle, draw, duplicate with Cmd+D, and nudge with Shift+Right arrow.
        view.keyDown(with: try makeKeyEvent(characters: "1", modifiers: [], keyCode: 18))
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 60, y: 60)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 60, y: 60)))
        #expect(view.annotations.items.count == 1)

        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "d", modifiers: [.command], keyCode: 2)))
        #expect(view.annotations.items.count == 2)
        #expect(view.annotations.items[0].id != view.annotations.items[1].id)

        let beforeNudge = try #require(view.annotations.selectedItem?.boundingBox)
        view.keyDown(with: try makeKeyEvent(characters: "", modifiers: [.shift], keyCode: 124))
        let afterNudge = try #require(view.annotations.selectedItem?.boundingBox)
        #expect(abs(afterNudge.minX - (beforeNudge.minX + 10)) < 0.01)

        // Pressing T triggers OCR for the active selection.
        view.keyDown(with: try makeKeyEvent(characters: "t", modifiers: [], keyCode: 17))
        #expect(actions == [.ocr(CGRect(x: 0, y: 0, width: 200, height: 100))])

        // Right-click exits active drawing tool -> resets to hovering -> cancels on next right-click.
        let rightClick = try makeMouseEvent(type: .rightMouseDown, at: CGPoint(x: 50, y: 50))
        view.rightMouseDown(with: rightClick)
        #expect(view.activeTool == .select)
        #expect(view.machine.selectionRect != nil)

        view.rightMouseDown(with: rightClick)
        #expect(view.machine.isHovering)

        view.rightMouseDown(with: rightClick)
        #expect(actions == [.ocr(CGRect(x: 0, y: 0, width: 200, height: 100)), .cancel])
    }

    @Test func draggableToolbarMovesClampsPersistsAcrossToolsAndResets() throws {
        let bounds = CGSize(width: 1200, height: 800)
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: bounds), topInset: 32)
        let selection = CGRect(x: 300, y: 200, width: 400, height: 300)
        try selectRect(selection, on: view)
        view.layoutSubtreeIfNeeded()

        let autoFrame = view.toolbar.frame
        #expect(autoFrame.size == SnipActionToolbar.preferredSize)
        #expect(view.customToolbarTopLeft == nil)

        let grip = view.toolbar.dragHandleView
        let gripCenterInOverlay = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: view)
        let gripCenterInToolbar = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: view.toolbar)
        #expect(view.toolbar.hitTest(gripCenterInOverlay) === grip)
        #expect(view.toolbar.hitsDragRegion(gripCenterInToolbar))

        let firstToolButtonPointInToolbar = CGPoint(x: gripCenterInToolbar.x + 25, y: gripCenterInToolbar.y)
        let firstToolButtonPointInOverlay = view.toolbar.convert(firstToolButtonPointInToolbar, to: view)
        #expect(!view.toolbar.hitsDragRegion(firstToolButtonPointInToolbar))
        #expect(view.toolbar.hitTest(firstToolButtonPointInOverlay) is NSButton)

        // Single-click without >= 1pt movement must not detach auto-positioning.
        grip.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: gripCenterInOverlay))
        grip.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: gripCenterInOverlay.x + 0.4, y: gripCenterInOverlay.y + 0.3)))
        grip.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: gripCenterInOverlay.x + 0.4, y: gripCenterInOverlay.y + 0.3)))
        #expect(view.customToolbarTopLeft == nil)
        #expect(view.toolbar.frame == autoFrame)
        #expect(!view.toolbar.isDragging)

        // Dragging the grip moves the toolbar smoothly in superview coordinates.
        let dragEnd = CGPoint(x: gripCenterInOverlay.x + 140, y: gripCenterInOverlay.y + 220)
        grip.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: gripCenterInOverlay))
        #expect(view.toolbar.isDragging)
        grip.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: dragEnd))
        #expect(view.toolbar.frame.origin == CGPoint(x: autoFrame.minX + 140, y: autoFrame.minY + 220))
        grip.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: dragEnd))
        #expect(!view.toolbar.isDragging)
        #expect(view.customToolbarTopLeft == CGPoint(x: autoFrame.minX + 140, y: autoFrame.minY + 220 + SnipActionToolbar.preferredSize.height))

        // Dragging far top-right clamps to display bounds and topInset (800 - 32 = 768).
        let clampedHandleCenter = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: view)
        grip.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: clampedHandleCenter))
        grip.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 2000, y: 2000)))
        grip.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 2000, y: 2000)))
        #expect(view.toolbar.frame.maxX == 1200)
        #expect(view.toolbar.frame.maxY == 768)

        // Enabling a drawing tool expands the style bar while keeping the primary bar's top anchored at 768.
        view.keyDown(with: try makeKeyEvent(characters: "1", modifiers: [], keyCode: 18))
        #expect(view.activeTool == .rectangle)
        #expect(view.toolbar.frame.size == SnipActionToolbar.expandedSize)
        #expect(view.toolbar.frame.maxX == 1200)
        #expect(view.toolbar.frame.maxY == 768)

        // Nudging the selection keeps the user-parked toolbar position.
        view.keyDown(with: try makeKeyEvent(characters: "", modifiers: [], keyCode: 124))
        #expect(view.toolbar.frame.maxX == 1200)
        #expect(view.toolbar.frame.maxY == 768)

        // Double-clicking the grip resets back to auto-anchored placement.
        let dockedHandleCenter = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: view)
        grip.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: dockedHandleCenter, clickCount: 2))
        #expect(view.customToolbarTopLeft == nil)
        let nudgedSelection = try #require(view.machine.selectionRect)
        #expect(view.toolbar.frame == SnipActionToolbar.frame(
            for: nudgedSelection,
            in: view.bounds,
            topInset: 32,
            showsStyleBar: true
        ))

        // Drag again, then switch back to Select ("v") and draw a brand-new selection -> resets custom position.
        let resetHandleCenter = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: view)
        grip.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: resetHandleCenter))
        grip.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: resetHandleCenter.x + 80, y: resetHandleCenter.y + 80)))
        grip.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: resetHandleCenter.x + 80, y: resetHandleCenter.y + 80)))
        #expect(view.customToolbarTopLeft != nil)

        view.keyDown(with: try makeKeyEvent(characters: "v", modifiers: [], keyCode: 9))
        try selectRect(CGRect(x: 40, y: 520, width: 220, height: 120), on: view)
        #expect(view.customToolbarTopLeft == nil)
    }

    @Test func repeatLastSelectionQuickSaveAndShiftGuard() throws {
        let prevRect = CGRect(x: 20, y: 15, width: 90, height: 45)
        let view = SnipOverlayView(
            snapshot: try makeSnapshot(),
            topInset: 0,
            previousSelectionRect: prevRect
        )
        view.primeWithMouseLocation(CGPoint(x: 50, y: 50))

        var actions: [OverlayAction] = []
        view.onFinish = { actions.append($0) }

        // Shift while hovering cycles format from .hex -> .rgb.
        let shiftDown = try #require(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        ))
        let shiftUp = try #require(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        ))
        view.flagsChanged(with: shiftDown)
        view.flagsChanged(with: shiftUp)

        // Pressing "R" while hovering restores the previous selection rect.
        view.keyDown(with: try makeKeyEvent(characters: "r", modifiers: [], keyCode: 15))
        #expect(view.machine.selectionRect == prevRect)

        // Pressing Shift while selected must not advance colorFormat to .hsl.
        view.flagsChanged(with: shiftDown)
        view.flagsChanged(with: shiftUp)

        // Shift+Cmd+S emits .quickSave for the active selection.
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "s", modifiers: [.command, .shift], keyCode: 1)))
        #expect(actions == [.quickSave(prevRect)])

        // Return to hovering via right-click and copy hovered color -> remains .rgb.
        view.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, at: CGPoint(x: 50, y: 50)))
        #expect(view.machine.isHovering)
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "c", modifiers: [.command], keyCode: 8)))
        guard case let .copyColor(_, format) = actions.last else {
            Issue.record("Expected .copyColor action, got \(actions)")
            return
        }
        #expect(format == .rgb)
    }
}
