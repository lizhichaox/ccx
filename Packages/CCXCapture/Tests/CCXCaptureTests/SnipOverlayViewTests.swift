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

    @Test func scrollShortcutToolbarOptionResizeSquareAndSpaceMove() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 600, height: 400)), topInset: 0)
        var actions: [OverlayAction] = []
        view.onFinish = { actions.append($0) }

        // Shift+Drag draws a square, and holding Space mid-drag translates its origin without resizing.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 40, y: 40)))
        let shiftDrag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: CGPoint(x: 160, y: 90),
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 1
        ))
        view.mouseDragged(with: shiftDrag)
        #expect(view.machine.selectionRect == CGRect(x: 40, y: 40, width: 120, height: 120))

        // Press Spacebar (keyCode 49), drag +20pt, then release Spacebar.
        view.keyDown(with: try makeKeyEvent(characters: " ", modifiers: [], keyCode: 49))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 180, y: 180)))
        #expect(view.machine.selectionRect == CGRect(x: 60, y: 60, width: 120, height: 120))
        let spaceUp = try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))
        view.keyUp(with: spaceUp)
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 180, y: 180)))
        let settled = try #require(view.machine.selectionRect)
        #expect(settled == CGRect(x: 60, y: 60, width: 120, height: 120))

        // Option+Right expands width by 1pt; Shift+Option+Up expands height by 10pt.
        view.keyDown(with: try makeKeyEvent(characters: "", modifiers: [.option], keyCode: 124))
        view.keyDown(with: try makeKeyEvent(characters: "", modifiers: [.option, .shift], keyCode: 126))
        let resized = try #require(view.machine.selectionRect)
        #expect(resized == CGRect(x: 60, y: 50, width: 121, height: 130))

        // "L" triggers .scroll, and toolbar .scroll button triggers .scroll.
        view.keyDown(with: try makeKeyEvent(characters: "l", modifiers: [], keyCode: 37))
        view.toolbar.onAction?(.scroll)
        #expect(actions == [.scroll(resized), .scroll(resized)])
    }

    @Test func atomicCardHoverHighlightsWithoutQueryingAXAndOverlayFallbackAppliesAcrossDesktopAndWindows() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 1512, height: 982)), topInset: 0)
        let cardRect = CGRect(x: 1142, y: 740, width: 352, height: 160)
        let chromeRect = CGRect(x: 0, y: 34, width: 1000, height: 948)

        var axQueries: [CGPoint] = []
        view.hoverRectProvider = { pt in
            if cardRect.contains(pt) { return cardRect }
            if chromeRect.contains(pt) { return chromeRect }
            return nil
        }
        view.shouldQueryElementRect = { pt in
            !cardRect.contains(pt)
        }
        view.elementRectRequester = { pt in
            axQueries.append(pt)
        }

        // Hovering an atomic Notification Center card highlights immediately and never invokes AX.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 1250, y: 820)))
        #expect(view.machine.highlightedRect == cardRect)
        #expect(axQueries.isEmpty)

        // Hovering over Desktop (no Tier 1 window) inside a fallback overlay still queries AX and accepts the overlay card.
        let desktopOverlayPoint = CGPoint(x: 1250, y: 500)
        let fallbackCard = CGRect(x: 1142, y: 420, width: 352, height: 162)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: desktopOverlayPoint))
        #expect(axQueries == [desktopOverlayPoint])
        view.applyRefinedElementRect(fallbackCard, forGlobalPoint: desktopOverlayPoint, isOverlayElement: true)
        #expect(view.machine.highlightedRect == fallbackCard)

        // Hovering near the edge of a narrower underlying window accepts an overlay element extending beyond it.
        let edgePoint = CGPoint(x: 990, y: 300)
        let overlappingOverlayCard = CGRect(x: 960, y: 240, width: 352, height: 162)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: edgePoint))
        #expect(axQueries == [desktopOverlayPoint, edgePoint])
        view.applyRefinedElementRect(overlappingOverlayCard, forGlobalPoint: edgePoint, isOverlayElement: true)
        #expect(view.machine.highlightedRect == overlappingOverlayCard)
    }

    @Test func snipOverlayPanelConfiguredAsNonActivatingFloatingKeyPanel() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let panel = SnipOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        SnipOverlayController.configurePanel(panel, frame: frame)

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .screenSaver)
        #expect(panel.frame == frame)
        #expect(panel.becomesKeyOnlyIfNeeded == false)
        #expect(panel.worksWhenModal)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.stationary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(panel.constrainFrameRect(frame, to: nil) == frame)
    }

    private func makeSnapshot(
        scale: CGFloat = 2,
        frame: CGRect
    ) throws -> DisplaySnapshot {
        let width = Int(frame.width * scale)
        let height = Int(frame.height * scale)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return DisplaySnapshot(
            displayID: 2,
            screenFrame: frame,
            backingScaleFactor: scale,
            image: image
        )
    }

    @Test func staleAXRepliesDroppedByEpochStaleNilParentBounceAndOverlayRecheck() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 1000, height: 600)), topInset: 0)
        let window1 = CGRect(x: 10, y: 10, width: 500, height: 400)
        let window2 = CGRect(x: 550, y: 10, width: 400, height: 400)
        let atomicCard = CGRect(x: 20, y: 20, width: 200, height: 120)
        let elementA = CGRect(x: 250, y: 100, width: 40, height: 40)
        let elementB = CGRect(x: 300, y: 100, width: 40, height: 40)
        let parentG = CGRect(x: 230, y: 80, width: 140, height: 100)

        var cancelCount = 0
        view.cancelElementRectRequests = { cancelCount += 1 }
        view.hoverRectProvider = { pt in
            if atomicCard.contains(pt) { return atomicCard }
            if window1.contains(pt) { return window1 }
            if window2.contains(pt) { return window2 }
            return nil
        }
        view.shouldQueryElementRect = { pt in !atomicCard.contains(pt) }

        // 1. Stale epoch reply from window1 ignored after moving to window2.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 260, y: 120)))
        let window1Epoch = view.axEpoch
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 600, y: 120)))
        #expect(view.axEpoch != window1Epoch)
        #expect(cancelCount == 1)
        view.applyRefinedElementRect(CGRect(x: 580, y: 100, width: 60, height: 50), forGlobalPoint: CGPoint(x: 600, y: 120), epoch: window1Epoch)
        #expect(view.machine.highlightedRect == window2)

        // 2. Sweeping elementA -> gap(pt1) -> elementB(pt2): stale nil from pt1 must not tear down gap bridge.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 265, y: 120)))
        let elemEpoch = view.axEpoch
        view.applyRefinedElementRect(elementA, forGlobalPoint: CGPoint(x: 265, y: 120), epoch: elemEpoch)
        #expect(view.machine.highlightedRect == elementA)

        let gapPt = CGPoint(x: 295, y: 120)
        let ptB = CGPoint(x: 310, y: 120)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: gapPt))
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: ptB))
        view.applyRefinedElementRect(nil, forGlobalPoint: gapPt, epoch: elemEpoch)
        #expect(view.machine.highlightedRect == elementA)
        view.applyRefinedElementRect(elementB, forGlobalPoint: ptB, epoch: elemEpoch)
        #expect(view.machine.highlightedRect == elementB)

        // 3. Stale outer container G queried outside elementB must not overwrite elementB when cursor is inside elementB.
        view.applyRefinedElementRect(parentG, forGlobalPoint: CGPoint(x: 240, y: 90), epoch: elemEpoch)
        #expect(view.machine.highlightedRect == elementB)

        // 4. Non-overlay rect exceeding lastTier1LocalRect by > 2pt and degenerate/offscreen rects are rejected.
        view.applyRefinedElementRect(CGRect(x: 0, y: 0, width: 600, height: 500), forGlobalPoint: ptB, epoch: elemEpoch)
        #expect(view.machine.highlightedRect == elementB)
        view.applyRefinedElementRect(CGRect(x: 1500, y: 1500, width: 50, height: 50), forGlobalPoint: ptB, epoch: elemEpoch)
        #expect(view.machine.highlightedRect == elementB)

        // 5. Moving onto an atomic card while an AX query is in flight cancels pending AX and rejects stale overlay replies.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 330, y: 120)))
        let beforeAtomicEpoch = view.axEpoch
        let cancelsBeforeAtomic = cancelCount
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 100, y: 80)))
        #expect(view.machine.highlightedRect == atomicCard)
        #expect(view.axEpoch != beforeAtomicEpoch)
        #expect(cancelCount == cancelsBeforeAtomic + 1)
        view.applyRefinedElementRect(
            CGRect(x: 10, y: 10, width: 300, height: 200),
            forGlobalPoint: CGPoint(x: 100, y: 80),
            isOverlayElement: true
        )
        #expect(view.machine.highlightedRect == atomicCard)
    }

    @Test func fallbackOverlayCardStableAcrossUnderlyingWindowBoundaryAndDesktopGaps() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 1512, height: 982)), topInset: 0)
        let chromeRect = CGRect(x: 0, y: 0, width: 1000, height: 900)
        let overlayRegion = CGRect(x: 950, y: 100, width: 562, height: 800)
        let card1 = CGRect(x: 960, y: 400, width: 352, height: 160)
        let card2 = CGRect(x: 960, y: 228, width: 352, height: 160) // 12pt gap below card1

        var queries: [CGPoint] = []
        view.hoverRectProvider = { pt in chromeRect.contains(pt) ? chromeRect : nil }
        view.shouldQueryElementRect = { pt in overlayRegion.contains(pt) || chromeRect.contains(pt) }
        view.elementRectRequester = { pt in queries.append(pt) }

        // Apply fallback overlay card while cursor is over Chrome + card1.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 990, y: 480)))
        view.applyRefinedElementRect(card1, forGlobalPoint: CGPoint(x: 990, y: 480), isOverlayElement: true)
        #expect(view.machine.highlightedRect == card1)

        // Move across Chrome -> Desktop boundary while staying inside card1: must NOT flash bounds.
        queries.removeAll()
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 1015, y: 480)))
        #expect(view.machine.highlightedRect == card1)
        #expect(queries == [CGPoint(x: 1015, y: 480)])

        // Move into the 12pt gap between card1 and card2 over Desktop: gap bridge holds card1.
        let gapPoint = CGPoint(x: 1100, y: 394)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: gapPoint))
        #expect(view.machine.highlightedRect == card1)

        // Receive card2 across the gap.
        let card2Point = CGPoint(x: 1100, y: 350)
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: card2Point))
        view.applyRefinedElementRect(card2, forGlobalPoint: card2Point, isOverlayElement: true)
        #expect(view.machine.highlightedRect == card2)

        // Move completely outside fallback overlay region onto regular Desktop: drops card cleanly.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 1200, y: 50)))
        #expect(view.machine.highlightedRect == view.bounds)
    }

    @Test func negativeOriginDisplayTransformsEdgePrimingAndSnapshotMatching() throws {
        let negativeFrame = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let primaryFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frames = [negativeFrame, primaryFrame]

        // Shared border x == 0 belongs strictly to primary display; outer top/right edges fall back inclusively.
        #expect(SnipOverlayController.matchingSnapshotIndex(for: CGPoint(x: 0, y: 500), in: frames) == 1)
        #expect(SnipOverlayController.matchingSnapshotIndex(for: CGPoint(x: 1512, y: 982), in: frames) == 1)
        #expect(SnipOverlayController.matchingSnapshotIndex(for: CGPoint(x: -1920, y: 880), in: frames) == 0)
        #expect(SnipOverlayController.matchingSnapshotIndex(for: CGPoint(x: -500, y: 200), in: frames) == 0)

        let snapshot = try makeSnapshot(scale: 2, frame: negativeFrame)
        let view = SnipOverlayView(snapshot: snapshot, topInset: 0)
        let globalWindow = CGRect(x: -1700, y: -100, width: 600, height: 400)
        let globalElement = CGRect(x: -1650, y: -50, width: 200, height: 120)
        var queriedGlobal: [CGPoint] = []
        view.hoverRectProvider = { pt in globalWindow.contains(pt) ? globalWindow : nil }
        view.elementRectRequester = { pt in queriedGlobal.append(pt) }

        // Priming inside negative-origin display translates global -> local -> global accurately.
        let globalCursor = CGPoint(x: -1600, y: 0)
        view.primeWithMouseLocation(globalCursor)
        #expect(view.machine.highlightedRect == CGRect(x: 220, y: 100, width: 600, height: 400))
        #expect(queriedGlobal.count == 1)
        #expect(abs(queriedGlobal[0].x - globalCursor.x) < 0.01 && abs(queriedGlobal[0].y - globalCursor.y) < 0.01)

        view.applyRefinedElementRect(globalElement, forGlobalPoint: globalCursor)
        #expect(view.machine.highlightedRect == CGRect(x: 270, y: 150, width: 200, height: 120))

        // Inclusive top-edge prime succeeds when allowed, and off-display prime clears hover.
        view.primeWithMouseLocation(CGPoint(x: -500, y: 880), allowClosedEdge: true)
        #expect(!view.isMagnifierHidden)
        view.primeWithMouseLocation(CGPoint(x: 100, y: 100), allowClosedEdge: false)
        #expect(view.machine.highlightedRect == nil)
        #expect(view.isMagnifierHidden)

        // Cropped SnipResult maps local selection back to negative global screen coordinates.
        let result = try #require(SnipOverlayController.makeResult(
            localRect: CGRect(x: 270, y: 150, width: 200, height: 120),
            snapshot: snapshot
        ))
        #expect(result.screenRect == globalElement)
    }

    @Test func mouseExitedResetSelectionAndKeyboardShortcutsClearHoverAndSiblings() throws {
        let view = SnipOverlayView(
            snapshot: try makeSnapshot(size: CGSize(width: 400, height: 300)),
            topInset: 0,
            previousSelectionRect: CGRect(x: 20, y: 20, width: 100, height: 80)
        )
        let windowRect = CGRect(x: 50, y: 50, width: 200, height: 150)
        var hoverActiveCount = 0
        var beginInteractionCount = 0
        var cancelAXCount = 0
        var actions: [OverlayAction] = []

        view.hoverRectProvider = { pt in windowRect.contains(pt) ? windowRect : nil }
        view.onHoverActive = { hoverActiveCount += 1 }
        view.onBeginInteraction = { beginInteractionCount += 1 }
        view.cancelElementRectRequests = { cancelAXCount += 1 }
        view.onFinish = { actions.append($0) }

        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 100, y: 100)))
        #expect(hoverActiveCount == 1)
        #expect(view.machine.highlightedRect == windowRect)
        #expect(!view.isMagnifierHidden)
        #expect(!view.isSizeLabelHidden)

        // Exiting the display clears hover highlight, size label, magnifier, and cancels pending AX.
        let exitEvent = try #require(NSEvent.enterExitEvent(
            with: .mouseExited,
            location: CGPoint(x: -5, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        view.mouseExited(with: exitEvent)
        #expect(view.machine.highlightedRect == nil)
        #expect(view.isMagnifierHidden)
        #expect(view.isSizeLabelHidden)
        #expect(cancelAXCount == 1)

        // Cmd+A and R both call onBeginInteraction so sibling displays reset cleanly.
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "a", modifiers: [.command], keyCode: 0)))
        #expect(beginInteractionCount == 1)
        #expect(view.machine.selectionRect == view.bounds)

        // resetSelection clears lastMousePoint so magnifier does not pop back open on an inactive display.
        view.resetSelection()
        #expect(view.machine.isHovering)
        #expect(view.isMagnifierHidden)

        view.keyDown(with: try makeKeyEvent(characters: "r", modifiers: [], keyCode: 15))
        #expect(beginInteractionCount == 2)
        #expect(view.machine.selectionRect == CGRect(x: 20, y: 20, width: 100, height: 80))

        // cancelOperation forwards cleanly to .cancel instead of closing only a single NSPanel.
        view.cancelOperation(nil)
        #expect(actions == [.cancel])
    }

    @Test func mouseDownRequeriesFreshTier1SupportsMicroDragClickAndTinyBorderPathIsNonNull() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 400, height: 300)), topInset: 0)
        let window1 = CGRect(x: 10, y: 10, width: 150, height: 200)
        let window2 = CGRect(x: 200, y: 10, width: 150, height: 200)
        let element1 = CGRect(x: 30, y: 30, width: 60, height: 40)
        var axQueries: [CGPoint] = []

        view.hoverRectProvider = { pt in
            if window1.contains(pt) { return window1 }
            if window2.contains(pt) { return window2 }
            return nil
        }
        view.elementRectRequester = { pt in axQueries.append(pt) }

        // Clicking an unprimed view queries fresh Tier 1 window instead of selecting full bounds.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 250, y: 100)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 250, y: 100)))
        #expect(view.machine.selectionRect == window2)

        // Reset, hover element1, and step 1pt (< axRequeryDistance) across its right edge -> forces AX re-query.
        view.resetSelection()
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 89.5, y: 50)))
        view.applyRefinedElementRect(element1, forGlobalPoint: CGPoint(x: 89.5, y: 50))
        #expect(view.machine.highlightedRect == element1)
        axQueries.removeAll()
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 90.5, y: 50)))
        #expect(axQueries == [CGPoint(x: 90.5, y: 50)])

        // Click inside element1 with 1.5pt trackpad micro-drag still selects element1.
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 50, y: 50)))
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 51.5, y: 50.5)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 51.5, y: 50.5)))
        #expect(view.machine.selectionRect == element1)

        // Flick-click directly onto window2 from hovered element1 without intermediate mouseMoved selects window2.
        view.resetSelection()
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 50, y: 50)))
        view.applyRefinedElementRect(element1, forGlobalPoint: CGPoint(x: 50, y: 50))
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 250, y: 100)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 250, y: 100)))
        #expect(view.machine.selectionRect == window2)

        // A 1x1 selection still produces a valid non-null borderLayer path (no CGRect.null inset bug).
        view.resetSelection()
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 120, y: 100)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 100, y: 100)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 100, y: 100)))
        #expect(view.machine.selectionRect == CGRect(x: 100, y: 100, width: 1, height: 1))
        let borderBox = try #require(view.borderLayerPath?.boundingBoxOfPath)
        #expect(!borderBox.isNull && borderBox.minX.isFinite && borderBox.minY.isFinite)
    }

    @Test func sizeLabelClampsBelowNotchAndHidesOnFullBoundsHover() throws {
        let size = CGSize(width: 1512, height: 982)
        let topInset: CGFloat = 38
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: size), topInset: topInset)

        // Full-display hover hides sizeLabel.
        view.hoverRectProvider = { _ in nil }
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 500, y: 500)))
        #expect(view.isSizeLabelHidden)

        // Top-touching tall window keeps sizeLabel below topInset (not hidden behind hardware Notch).
        let tallWindow = CGRect(x: 100, y: 100, width: 600, height: 882)
        view.hoverRectProvider = { _ in tallWindow }
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 300, y: 400)))
        #expect(!view.isSizeLabelHidden)
        #expect(view.sizeLabelFrame.maxY <= size.height - topInset)
        #expect(view.sizeLabelFrame.minY >= 0)

        // Thin Menu Bar item entirely inside topInset places sizeLabel below the Notch.
        let menuBarItem = CGRect(x: 600, y: 954, width: 120, height: 28)
        view.hoverRectProvider = { _ in menuBarItem }
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 650, y: 968)))
        #expect(!view.isSizeLabelHidden)
        #expect(view.sizeLabelFrame.maxY <= size.height - topInset)
        #expect(view.sizeLabelFrame.minY >= 0)
    }

    @Test func hoverColorCopyGuardsRightClickSiblingResetAndShiftStartupInit() throws {
        let view = SnipOverlayView(
            snapshot: try makeSnapshot(size: CGSize(width: 400, height: 300)),
            topInset: 0,
            initialShiftDown: true
        )
        var actions: [OverlayAction] = []
        var beginCount = 0
        var siblingHasSelection = true
        view.onFinish = { actions.append($0) }
        view.onBeginInteraction = {
            beginCount += 1
            siblingHasSelection = false
        }
        view.hasSiblingSelection = { siblingHasSelection }

        view.primeWithMouseLocation(CGPoint(x: 100, y: 100))

        // Shift already held on startup must NOT spuriously advance colorFormat from .hex -> .rgb.
        let shiftStillHeld = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 56
        ))
        view.flagsChanged(with: shiftStillHeld)

        // Ctrl+C while hovering must NOT copy color.
        view.keyDown(with: try makeKeyEvent(characters: "c", modifiers: [.control], keyCode: 8))
        #expect(actions.isEmpty)

        // Right-click while a sibling display has a selection resets the sibling instead of cancelling.
        view.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, at: CGPoint(x: 120, y: 120)))
        #expect(beginCount == 1)
        #expect(actions.isEmpty)

        // Mid-drag C and Cmd+C must NOT abort drag with .copyColor.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 150, y: 150)))
        view.keyDown(with: try makeKeyEvent(characters: "c", modifiers: [], keyCode: 8))
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "c", modifiers: [.command], keyCode: 8)) == false)
        #expect(actions.isEmpty)
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 150, y: 150)))

        // Return to hover and verify colorFormat is still .hex (not cycled on startup).
        view.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, at: CGPoint(x: 100, y: 100)))
        view.keyDown(with: try makeKeyEvent(characters: "c", modifiers: [], keyCode: 8))
        guard case let .copyColor(_, format) = actions.last else {
            Issue.record("Expected .copyColor, got \(actions)")
            return
        }
        #expect(format == .hex)
    }

    @Test func directResizeAndMoveWhileRectangleOrMosaicToolActiveAndModeSync() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 500, height: 400)), topInset: 0)
        try selectRect(CGRect(x: 20, y: 20, width: 460, height: 360), on: view)

        // 1. Activate Rectangle ("1") and draw a box.
        view.keyDown(with: try makeKeyEvent(characters: "1", modifiers: [], keyCode: 18))
        #expect(view.activeTool == .rectangle)
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 60, y: 60)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 160, y: 140)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 160, y: 140)))
        #expect(view.annotations.items.count == 1)
        let firstRectID = try #require(view.annotations.selectedID)

        // Grab right-edge midpoint handle (160, 100) WITHOUT switching to .select -> resizes the same rectangle.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 160, y: 100)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 200, y: 100)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 200, y: 100)))
        #expect(view.annotations.items.count == 1)
        #expect(view.annotations.selectedID == firstRectID)
        #expect(view.annotations.selectedItem?.boundingBox == CGRect(x: 60, y: 60, width: 140, height: 80))

        // Dragging rectangle's border (away from corner/midpoint handles) moves it without creating a new item.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 60, y: 80)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 70, y: 90)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 70, y: 90)))
        #expect(view.annotations.items.count == 1)
        #expect(view.annotations.selectedItem?.boundingBox == CGRect(x: 70, y: 70, width: 140, height: 80))

        // Dragging in its hollow interior draws a second rectangle.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 110, y: 90)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 160, y: 120)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 160, y: 120)))
        #expect(view.annotations.items.count == 2)

        // 2. Switching to Mosaic ("6") clears previous selection cleanly and lets us draw & edit mosaics directly.
        view.keyDown(with: try makeKeyEvent(characters: "6", modifiers: [], keyCode: 22))
        #expect(view.activeTool == .mosaic)
        #expect(view.annotations.selectedID == nil)

        // Draw Mosaic 1 overlapping the first rectangle's outer border (70, 70) -> draws Mosaic instead of grabbing Rectangle.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 65, y: 65)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 145, y: 105)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 145, y: 105)))
        #expect(view.annotations.items.count == 3)
        let mosaic1ID = try #require(view.annotations.selectedID)

        // Immediately resize Mosaic 1 via its top-right corner handle while Mosaic tool stays active.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 145, y: 105)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 175, y: 125)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 175, y: 125)))
        #expect(view.annotations.items.count == 3)
        #expect(view.annotations.selectedID == mosaic1ID)
        #expect(view.annotations.selectedItem?.boundingBox == CGRect(x: 65, y: 65, width: 110, height: 60))

        // Dragging inside Mosaic 1 moves it.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 100, y: 95)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 120, y: 105)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 120, y: 105)))
        #expect(view.annotations.items.count == 3)
        #expect(view.annotations.selectedItem?.boundingBox == CGRect(x: 85, y: 75, width: 110, height: 60))

        // Toggling Mosaic -> Blur via applyStyle syncs the item's `.mosaic(..., mode)` kind live.
        view.applyStyle(AnnotationStyle(color: .red, size: .large, mosaicMode: .blur))
        if case let .mosaic(_, mode)? = view.annotations.selectedItem?.kind {
            #expect(mode == .blur)
        } else {
            Issue.record("Expected selected mosaic item")
        }

        // Draw Mosaic 2 in free space, then click Mosaic 1 to re-select it.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 260, y: 200)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 360, y: 260)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 360, y: 260)))
        #expect(view.annotations.items.count == 4)
        #expect(view.annotations.selectedID != mosaic1ID)

        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 100, y: 95)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 100, y: 95)))
        #expect(view.annotations.selectedID == mosaic1ID)
    }

    @Test func strokeSizeSliderHitTestingDraggingAndUndoCoalescing() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 800, height: 600)), topInset: 0)
        try selectRect(CGRect(x: 40, y: 80, width: 640, height: 440), on: view)
        view.keyDown(with: try makeKeyEvent(characters: "1", modifiers: [], keyCode: 18))
        view.layoutSubtreeIfNeeded()

        // Draw an initial rectangle at default `.medium` size.
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 100, y: 160)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 240, y: 260)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 240, y: 260)))
        #expect(view.annotations.selectedItem?.style.size == .medium)
        view.layoutSubtreeIfNeeded()

        var persistedSizes: [StrokeSize] = []
        view.onStyleUpdated = { persistedSizes.append($0.size) }

        let slider = view.toolbar.sizeSliderView
        let toolbarBeforeDrag = view.toolbar.frame
        let leftEndInView = slider.convert(CGPoint(x: 4, y: slider.bounds.midY), to: view)
        let midInView = slider.convert(CGPoint(x: 50, y: slider.bounds.midY), to: view)
        let rightEndInView = slider.convert(CGPoint(x: 96, y: slider.bounds.midY), to: view)
        let midInToolbar = slider.convert(CGPoint(x: 50, y: slider.bounds.midY), to: view.toolbar)

        #expect(view.toolbar.hitTest(midInView) === slider)
        #expect(!view.toolbar.hitsDragRegion(midInToolbar))

        // Drag slider from left end (.minimum) through middle to right end (.maximum).
        slider.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: leftEndInView))
        #expect(view.currentStyle.size == .minimum)
        #expect(view.annotations.selectedItem?.style.size == .minimum)

        slider.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: midInView))
        #expect(view.currentStyle.size.progress > 0.3 && view.currentStyle.size.progress < 0.7)

        slider.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: rightEndInView))
        slider.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: rightEndInView))

        #expect(view.currentStyle.size == .maximum)
        #expect(view.annotations.selectedItem?.style.size == .maximum)
        #expect(persistedSizes.last == .maximum)
        #expect(view.toolbar.frame == toolbarBeforeDrag)

        // Single Cmd+Z reverts the entire continuous slider drag back to `.medium`.
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "z", modifiers: [.command], keyCode: 6)))
        #expect(view.annotations.selectedItem?.style.size == .medium)
    }

    @Test func scrollGestureAdjustsThicknessAcrossToolsRespectsInversionAndCoalescesUndo() throws {
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 800, height: 600)), topInset: 0)

        // Ignored while hovering before a selection exists.
        #expect(!view.handleScrollThickness(deltaY: 40))
        #expect(view.currentStyle.size == .medium)

        try selectRect(CGRect(x: 40, y: 80, width: 640, height: 440), on: view)

        // Ignored in `.select` when no annotation is selected.
        #expect(!view.handleScrollThickness(deltaY: 40))

        // Active drawing tool accepts scroll even before an item is drawn, updates style + HUD, ignores momentum/horizontal.
        view.keyDown(with: try makeKeyEvent(characters: "1", modifiers: [], keyCode: 18))
        var persistedSizes: [StrokeSize] = []
        view.onStyleUpdated = { persistedSizes.append($0.size) }

        #expect(!view.handleScrollThickness(deltaY: 20, deltaX: 0, momentumPhase: .changed))
        #expect(!view.handleScrollThickness(deltaY: 8, deltaX: 40))
        #expect(view.handleScrollThickness(deltaY: 50, isPrecise: true, isDirectionInverted: false))
        #expect(view.currentStyle.size.progress > StrokeSize.medium.progress)
        #expect(persistedSizes.last == view.currentStyle.size)
        #expect(!view.isSizeHUDHidden)
        #expect(view.sizeHUDText.hasSuffix(" pt"))

        // Draw a rectangle, then perform a Natural Scrolling physical-up gesture (negative deltaY with isDirectionInverted = true).
        view.applyStrokeSize(.medium, recordUndo: false, showHUD: false)
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 100, y: 160)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 240, y: 260)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 240, y: 260)))
        let beforeScroll = try #require(view.annotations.selectedItem?.style.size)
        #expect(beforeScroll == .medium)

        #expect(view.handleScrollThickness(deltaY: -40, isPrecise: true, isDirectionInverted: true, phase: .began))
        #expect(view.handleScrollThickness(deltaY: -60, isPrecise: true, isDirectionInverted: true, phase: .changed))
        #expect(view.handleScrollThickness(deltaY: 0, isPrecise: true, isDirectionInverted: true, phase: .ended))

        let thickened = try #require(view.annotations.selectedItem?.style.size)
        #expect(thickened.lineWidth > beforeScroll.lineWidth)
        #expect(view.sizeHUDText == "\(thickened.formattedLineWidth) pt")

        // Coalesced into 1 undo snapshot so single Cmd+Z returns straight to `.medium`.
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "z", modifiers: [.command], keyCode: 6)))
        #expect(view.annotations.selectedItem?.style.size == .medium)

        // Clamps cleanly at minimum and maximum bounds.
        #expect(view.handleScrollThickness(deltaY: -1000, isPrecise: true, isDirectionInverted: false, phase: .began))
        #expect(view.annotations.selectedItem?.style.size == .minimum)
        #expect(view.sizeHUDText == "1.5 pt")
        #expect(view.handleScrollThickness(deltaY: 0, isPrecise: true, isDirectionInverted: false, phase: .ended))

        #expect(view.handleScrollThickness(deltaY: 1000, isPrecise: true, isDirectionInverted: false, phase: .began))
        #expect(view.annotations.selectedItem?.style.size == .maximum)
        #expect(view.sizeHUDText == "12 pt")
        #expect(view.handleScrollThickness(deltaY: 0, isPrecise: true, isDirectionInverted: false, phase: .ended))

        // Mosaic tool adjusts block/blur strength and formats HUD accordingly.
        let blurSize: StrokeSize = try CCXL10n.withLanguageForTesting(.en) {
            view.keyDown(with: try makeKeyEvent(characters: "6", modifiers: [], keyCode: 22))
            view.applyStrokeSize(.small, recordUndo: false, showHUD: false)
            view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 300, y: 180)))
            view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 420, y: 280)))
            view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 420, y: 280)))

            #expect(view.handleScrollThickness(deltaY: 5, isPrecise: false, isDirectionInverted: false, timestamp: 100))
            let mosaicSize = try #require(view.annotations.selectedItem?.style.size)
            #expect(mosaicSize.mosaicBlockSize > StrokeSize.small.mosaicBlockSize)
            #expect(view.sizeHUDText == "Mosaic \(Int(mosaicSize.mosaicBlockSize.rounded()))")

            view.applyStyle(AnnotationStyle(color: .red, size: mosaicSize, mosaicMode: .blur))
            #expect(view.handleScrollThickness(deltaY: 5, isPrecise: false, isDirectionInverted: false, timestamp: 101))
            let size = try #require(view.annotations.selectedItem?.style.size)
            #expect(size.blurRadius >= mosaicSize.blurRadius)
            #expect(view.sizeHUDText == "Blur \(Int(size.blurRadius.rounded()))")
            return size
        }

        // Real NSEvent.scrollWheel path (when CGEvent conversion succeeds) routes through `scrollWheel(with:)`.
        if let cgScroll = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: -30,
            wheel2: 0,
            wheel3: 0
        ), let nsScroll = NSEvent(cgEvent: cgScroll) {
            let previousProgress = blurSize.progress
            view.scrollWheel(with: nsScroll)
            let afterNS = try #require(view.annotations.selectedItem?.style.size.progress)
            #expect(afterNS != previousProgress)
        }
    }

    @Test func recordEntryShortcutAndDirectRecordSelectionMode() throws {
        // 1. In normal `.snip` mode, pressing `r` after selecting a region emits `.record(rect)`.
        let snipView = SnipOverlayView(snapshot: try makeSnapshot(size: CGSize(width: 400, height: 300)), topInset: 0)
        var snipActions: [OverlayAction] = []
        snipView.onFinish = { snipActions.append($0) }

        let targetRect = CGRect(x: 40, y: 50, width: 200, height: 120)
        try selectRect(targetRect, on: snipView)
        snipView.keyDown(with: try makeKeyEvent(characters: "r", modifiers: [], keyCode: 15))
        #expect(snipActions == [.record(targetRect)])

        // 2. In `.record` mode, dragging a region immediately finishes with `.record(rect)`.
        let dragView = SnipOverlayView(
            snapshot: try makeSnapshot(size: CGSize(width: 400, height: 300)),
            topInset: 0,
            selectionMode: .record
        )
        var dragActions: [OverlayAction] = []
        dragView.onFinish = { dragActions.append($0) }
        try selectRect(targetRect, on: dragView)
        #expect(dragActions == [.record(targetRect)])

        // 3. In `.record` mode, Cmd+A while hovering immediately finishes with `.record(bounds)`.
        let cmdAView = SnipOverlayView(
            snapshot: try makeSnapshot(size: CGSize(width: 400, height: 300)),
            topInset: 0,
            selectionMode: .record
        )
        var cmdAActions: [OverlayAction] = []
        cmdAView.onFinish = { cmdAActions.append($0) }
        #expect(cmdAView.performKeyEquivalent(with: try makeKeyEvent(characters: "a", modifiers: [.command], keyCode: 0)))
        #expect(cmdAActions == [.record(CGRect(x: 0, y: 0, width: 400, height: 300))])
    }

    @Test func scrollCaptureHUDPanelFitsAllControlsWithoutOverflow() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let hintFont = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)

        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                let hud = ScrollCaptureHUDPanel(
                    captureRect: CGRect(x: 220, y: 260, width: 520, height: 500),
                    visibleFrame: visibleFrame
                )

                @MainActor
                func assertControlsFit() {
                    let contentBounds = hud.hudContentBounds
                    let frames = hud.hudControlFrames
                    #expect(contentBounds.height == 44)
                    #expect(frames.count == 9)
                    #expect(visibleFrame.contains(hud.frame))
                    for frame in frames {
                        #expect(frame.width > 0)
                        #expect(frame.height > 0)
                        #expect(contentBounds.contains(frame))
                    }
                    for i in 0 ..< frames.count {
                        for j in (i + 1) ..< frames.count {
                            #expect(!frames[i].intersects(frames[j]))
                        }
                    }
                }

                assertControlsFit()

                hud.updateMetrics(
                    width: 1440,
                    height: 12850,
                    status: CCXL10n.text("Auto-scrolling", zh: "滚动中…"),
                    accent: .autoScroll,
                    isAutoScrolling: true
                )
                assertControlsFit()

                hud.updateMetrics(
                    width: 2880,
                    height: 24500,
                    status: CCXL10n.text("Needs Accessibility", zh: "需要辅助功能"),
                    accent: .warning,
                    isAutoScrolling: false
                )
                assertControlsFit()

                hud.updateAutoScroll(
                    isRunning: false,
                    status: CCXL10n.text("Reached bottom", zh: "已到底部"),
                    accent: .warning
                )
                assertControlsFit()

                hud.updateAutoScroll(
                    isRunning: false,
                    status: CCXL10n.text("Max height", zh: "已达最大高度"),
                    accent: .warning
                )
                assertControlsFit()

                let bottomHUD = ScrollCaptureHUDPanel(
                    captureRect: CGRect(x: 200, y: 8, width: 500, height: 500),
                    visibleFrame: visibleFrame
                )
                #expect(visibleFrame.contains(bottomHUD.frame))
                #expect(bottomHUD.hudControlFrames.allSatisfy { bottomHUD.hudContentBounds.contains($0) })

                let magnifier = PixelMagnifierView()
                let expectedHint = language == .zhHans ? "C 拷贝 · ⇧ 格式" : "C copy · ⇧ format"
                #expect(magnifier.displayedHintText == expectedHint)
                let hintWidth = (magnifier.displayedHintText as NSString).size(withAttributes: [.font: hintFont]).width
                #expect(hintWidth <= 142)
            }
        }
    }

    @Test func autoScrollDriverAvoidsHUDAndPostsDiscreteScrollUntilBottomOrTakeover() async throws {
        @MainActor
        final class DriverProbe {
            var pointerLocation: CGPoint
            var warpedQuartz: [CGPoint] = []
            var postedScrolls: [(point: CGPoint, lines: Int32)] = []
            var reachedBottomCount = 0
            var accessibilityCount = 0

            init(pointerLocation: CGPoint) {
                self.pointerLocation = pointerLocation
            }
        }

        // 1. Target selection avoids HUD frame by picking the larger unobstructed vertical band.
        let captureRect = CGRect(x: 100, y: 100, width: 400, height: 600)
        #expect(AutoScrollDriver.scrollTargetPoint(in: captureRect, avoiding: nil) == CGPoint(x: 300, y: 400))

        let centeredHUD = CGRect(x: 160, y: 378, width: 280, height: 44)
        let avoidedTarget = AutoScrollDriver.scrollTargetPoint(in: captureRect, avoiding: centeredHUD)
        #expect(captureRect.contains(avoidedTarget))
        #expect(!centeredHUD.insetBy(dx: -10, dy: -10).contains(avoidedTarget))

        let highHUD = CGRect(x: 160, y: 390, width: 280, height: 220)
        let bottomTarget = AutoScrollDriver.scrollTargetPoint(in: captureRect, avoiding: highHUD)
        #expect(bottomTarget.y < highHUD.minY - 10)

        // 2. Step lines clamp cleanly between 2 and 5.
        #expect(AutoScrollDriver.scrollStepLines(for: 200) == 2)
        #expect(AutoScrollDriver.scrollStepLines(for: 540) == 3)
        #expect(AutoScrollDriver.scrollStepLines(for: 2000) == 5)

        // 3. Missing Accessibility permission triggers callback and refuses to start.
        let untrustedProbe = DriverProbe(pointerLocation: .zero)
        let untrustedDriver = AutoScrollDriver(
            trustChecker: { false },
            startDelay: 0,
            tickInterval: 0.005
        )
        untrustedDriver.onAccessibilityRequired = { untrustedProbe.accessibilityCount += 1 }
        untrustedDriver.start(captureScreenRect: captureRect, primaryScreenHeight: 900, currentPixelHeight: 1200)
        #expect(!untrustedDriver.isRunning)
        #expect(untrustedProbe.accessibilityCount == 1)

        // 4. Grace ticks tolerate brief displacement (e.g. click on HUD), advance resets stall counter, then bottom stops.
        let probe = DriverProbe(pointerLocation: CGPoint(x: 300, y: 720))
        let driver = AutoScrollDriver(
            trustChecker: { true },
            pointerLocationProvider: { probe.pointerLocation },
            pointerWarper: { quartz in
                probe.warpedQuartz.append(quartz)
                if probe.warpedQuartz.count >= 2 {
                    probe.pointerLocation = CGPoint(x: quartz.x, y: 900 - quartz.y)
                }
            },
            scrollPoster: { quartz, lines in
                probe.postedScrolls.append((quartz, lines))
            },
            startDelay: 0,
            tickInterval: 0.005
        )
        driver.onReachedBottom = { probe.reachedBottomCount += 1 }

        driver.start(
            captureScreenRect: captureRect,
            primaryScreenHeight: 900,
            currentPixelHeight: 1200,
            avoiding: centeredHUD
        )
        #expect(driver.isRunning)
        #expect(probe.warpedQuartz.count == 1)
        #expect(probe.warpedQuartz[0].y == 900 - avoidedTarget.y)

        for _ in 0 ..< 40 where probe.postedScrolls.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(driver.isRunning)
        let ticksBeforeAdvance = probe.postedScrolls.count
        #expect(ticksBeforeAdvance >= 2)
        #expect(probe.postedScrolls.allSatisfy { $0.lines == AutoScrollDriver.scrollStepLines(for: 600) })

        driver.notifyHeightAdvanced(1600)

        for _ in 0 ..< 100 where driver.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!driver.isRunning)
        #expect(probe.reachedBottomCount == 1)
        #expect(probe.postedScrolls.count >= ticksBeforeAdvance + 10)

        // 5. Deliberate pointer takeover outside captureRect pauses without reporting bottom.
        let takeoverProbe = DriverProbe(pointerLocation: CGPoint(x: 300, y: 400))
        let takeoverDriver = AutoScrollDriver(
            trustChecker: { true },
            pointerLocationProvider: { takeoverProbe.pointerLocation },
            pointerWarper: { _ in },
            scrollPoster: { quartz, lines in
                takeoverProbe.postedScrolls.append((quartz, lines))
            },
            startDelay: 0,
            tickInterval: 0.005
        )
        takeoverDriver.onReachedBottom = { takeoverProbe.reachedBottomCount += 1 }
        takeoverDriver.start(captureScreenRect: captureRect, primaryScreenHeight: 900, currentPixelHeight: 1200)
        for _ in 0 ..< 40 where takeoverProbe.postedScrolls.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(takeoverDriver.isRunning)
        takeoverProbe.pointerLocation = CGPoint(x: 20, y: 20)
        for _ in 0 ..< 100 where takeoverDriver.isRunning {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!takeoverDriver.isRunning)
        #expect(takeoverProbe.reachedBottomCount == 0)

        // 6. Non-finite delays/intervals clamp safely without trapping.
        let safeDriver = AutoScrollDriver(
            trustChecker: { true },
            pointerLocationProvider: { CGPoint(x: 300, y: 400) },
            pointerWarper: { _ in },
            scrollPoster: { _, _ in },
            startDelay: .nan,
            tickInterval: -.infinity
        )
        safeDriver.start(captureScreenRect: captureRect, primaryScreenHeight: 900, currentPixelHeight: 1200)
        try await Task.sleep(for: .milliseconds(15))
        safeDriver.stop()
        #expect(!safeDriver.isRunning)
    }

    @Test func gpuPixelMagnifierOrientationEdgeClampingAndTinyBoundsFrame() throws {
        // Build a 40x40 image whose TOP half (image y 0..<20) is pure RED and BOTTOM half (image y 20..<40) is pure BLUE.
        let ctx = try #require(CGContext(
            data: nil,
            width: 40,
            height: 40,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20)) // CG bottom = image bottom (rows 20..<40)
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 20, width: 40, height: 20)) // CG top = image top (rows 0..<20)
        let image = try #require(ctx.makeImage())

        let magnifier = PixelMagnifierView(frame: CGRect(origin: .zero, size: PixelMagnifierView.preferredSize))
        let sample = CCXColorSample(red: 255, green: 0, blue: 0)
        // Center on the exact seam (pixelX = 20, pixelY = 20 -> rows 15..25: top 5 rows red, bottom 6 rows blue).
        magnifier.update(image: image, pixelX: 20, pixelY: 20, sample: sample, format: .hex, sizeText: "40 × 40")
        #expect(magnifier.displayedPositionText == "(20, 20)")
        #expect(magnifier.displayedSizeText == "40 × 40")
        #expect(magnifier.displayedColorText == "#FF0000")

        // Render magnifier's CALayer tree into a bitmap context to empirically verify top-vs-bottom orientation.
        let renderW = Int(PixelMagnifierView.preferredSize.width)
        let renderH = Int(PixelMagnifierView.preferredSize.height)
        let renderCtx = try #require(CGContext(
            data: nil,
            width: renderW,
            height: renderH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let rootLayer = try #require(magnifier.layer)
        rootLayer.render(in: renderCtx)
        let rendered = try #require(renderCtx.makeImage())
        // Top of magnifier grid (top-down y = 10, x = 20 -> away from center crosshair) must be RED.
        let topSample = try #require(CCXColorSample.samplePixel(from: rendered, pixelX: 20, pixelY: 10))
        // Bottom of magnifier grid (top-down y = 140, x = 20 -> inside gridSide = 154) must be BLUE.
        let bottomSample = try #require(CCXColorSample.samplePixel(from: rendered, pixelX: 20, pixelY: 140))
        #expect(topSample.red > 180 && topSample.blue < 40)
        #expect(bottomSample.blue > 180 && bottomSample.red < 40)

        // Edge pixel (0, 0) offsets pixelLayer frame cleanly inside grid.
        magnifier.update(image: image, pixelX: 0, pixelY: 0, sample: sample, format: .rgb, sizeText: "")
        #expect(magnifier.pixelLayerFrame.minX == 5 * PixelMagnifierView.cellSize)
        #expect(magnifier.pixelLayerFrame.width == 6 * PixelMagnifierView.cellSize)
        #expect(magnifier.displayedColorText == "rgb(255, 0, 0)")

        // Tiny / degenerate bounds never invert PixelMagnifierView.frame origin below usable.minX/minY.
        let tinyBounds = CGRect(x: 10, y: 20, width: 80, height: 80)
        let clampedTiny = PixelMagnifierView.frame(near: CGPoint(x: 50, y: 60), in: tinyBounds, topInset: 10)
        #expect(clampedTiny.minX >= tinyBounds.minX)
        #expect(clampedTiny.minY >= tinyBounds.minY)
        let nanCursor = PixelMagnifierView.frame(near: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), in: tinyBounds, topInset: .nan)
        #expect(nanCursor.minX.isFinite && nanCursor.minY.isFinite)

        magnifier.clear()
    }

    @Test func inlineTextStyleRollbackFocusCommitCounterDuplicateEdgeExitLiveShiftAndTearDown() throws {
        let size = CGSize(width: 400, height: 300)
        let view = SnipOverlayView(snapshot: try makeSnapshot(size: size), topInset: 0)
        let selection = CGRect(x: 20, y: 20, width: 220, height: 200)
        try selectRect(selection, on: view)

        // 1. Existing text edit: previewing style changes then cancelling with Esc leaves item & undo history untouched.
        let originalStyle = AnnotationStyle(color: .red, size: .medium)
        let textItem = AnnotationItem(kind: .text(origin: CGPoint(x: 40, y: 150), content: "Hello"), style: originalStyle)
        view.annotations.commit(textItem)
        let undoDepthBefore = view.annotations.canUndo
        #expect(undoDepthBefore)

        // Double-click existing text item in `.select` tool to open inline editor.
        let box = textItem.boundingBox
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: box.midX, y: box.midY), clickCount: 2))
        #expect(view.isEditingTextForTesting)

        // Preview blue color and large stroke while editing.
        view.applyStyle(AnnotationStyle(color: .blue, size: .large))
        view.applyStrokeSize(.maximum, recordUndo: true, showHUD: false)
        // Underlying committed item must NOT be mutated while inline editor is still open.
        #expect(view.annotations.selectedItem?.style == originalStyle)

        // Cancel with Escape -> restores original style cleanly and pushes zero undo snapshots.
        view.keyDown(with: try makeKeyEvent(characters: "\u{1B}", modifiers: [], keyCode: 53))
        #expect(!view.isEditingTextForTesting)
        #expect(view.currentStyle == originalStyle)
        #expect(view.annotations.selectedItem?.style == originalStyle)
        #expect(view.annotations.undo())
        #expect(view.annotations.items.isEmpty) // Single undo undid the original commit directly.

        // 2. External focus loss (`controlTextDidEndEditing`) commits inline text cleanly.
        view.keyDown(with: try makeKeyEvent(characters: "7", modifiers: [], keyCode: 26)) // Text tool
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 50, y: 140)))
        #expect(view.isEditingTextForTesting)
        let field = try #require(view.inlineEditorFieldForTesting)
        field.stringValue = "Committed on blur"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(!view.isEditingTextForTesting)
        #expect(view.annotations.items.count == 1)

        // 3. Cmd+D on a step counter increments to the next counter number (1 -> 2).
        view.keyDown(with: try makeKeyEvent(characters: "8", modifiers: [], keyCode: 28)) // Counter tool
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 100, y: 100)))
        #expect(view.performKeyEquivalent(with: try makeKeyEvent(characters: "d", modifiers: [.command], keyCode: 2)))
        let counterNumbers = view.annotations.items.compactMap { item -> Int? in
            if case let .counter(_, n) = item.kind { return n }
            return nil
        }
        #expect(counterNumbers == [1, 2])

        // 4. Live Shift toggle in flagsChanged updates an in-flight drag immediately without extra mouseDragged.
        view.resetSelection()
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: try makeMouseEvent(type: .leftMouseDragged, at: CGPoint(x: 170, y: 100)))
        #expect(view.machine.selectionRect == CGRect(x: 50, y: 50, width: 120, height: 50))
        let shiftDown = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56
        ))
        view.flagsChanged(with: shiftDown)
        #expect(view.machine.selectionRect == CGRect(x: 50, y: 50, width: 120, height: 120))
        view.mouseUp(with: try makeMouseEvent(type: .leftMouseUp, at: CGPoint(x: 170, y: 100)))

        // 5. mouseExited at closed top/right edge (x == width or y == height) keeps hover & magnifier active.
        view.resetSelection()
        view.mouseMoved(with: try makeMouseEvent(type: .mouseMoved, at: CGPoint(x: 100, y: 100)))
        #expect(!view.isMagnifierHidden)
        let topEdgeExit = try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: CGPoint(x: 200, y: size.height), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        view.mouseExited(with: topEdgeExit)
        #expect(!view.isMagnifierHidden)

        // 6. tearDown releases annotations, caches, and layers cleanly.
        view.tearDown()
        #expect(view.annotations.isEmpty)
        #expect(view.borderLayerPath == nil)
    }

    @Test func scrollCaptureKeyMonitorScopingAndDisplayIDVisibleFrameMatching() {
        // Local key monitor accepts only owned scroll-capture panel windows and never active field editors.
        let owned: Set<Int> = [101, 102, 103]
        #expect(ScrollCaptureController.shouldHandleLocalKeyEvent(windowNumber: 102, ownedWindowNumbers: owned, isFieldEditorFirstResponder: false))
        #expect(!ScrollCaptureController.shouldHandleLocalKeyEvent(windowNumber: 999, ownedWindowNumbers: owned, isFieldEditorFirstResponder: false))
        #expect(!ScrollCaptureController.shouldHandleLocalKeyEvent(windowNumber: 102, ownedWindowNumbers: owned, isFieldEditorFirstResponder: true))

        // Adjacent display edge-touching selection resolves exact `displayID` visibleFrame instead of neighboring monitor.
        let leftScreen = (
            displayID: CGDirectDisplayID(1),
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 904)
        )
        let rightScreen = (
            displayID: CGDirectDisplayID(2),
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        )
        let edgeRectOnRight = CGRect(x: 1512, y: 100, width: 600, height: 500)
        let resolved = ScrollCaptureController.visibleFrame(
            for: 2,
            captureRect: edgeRectOnRight,
            screens: [leftScreen, rightScreen]
        )
        #expect(resolved == rightScreen.visibleFrame)
    }
}
