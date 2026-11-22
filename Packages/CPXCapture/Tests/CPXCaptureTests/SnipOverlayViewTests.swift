import AppKit
import CoreGraphics
import CPXAnnotate
import CPXCore
import Testing
@testable import CPXCapture

@Suite("SnipOverlayView")
@MainActor
struct SnipOverlayViewTests {
    private func makeSnapshot(scale: CGFloat = 2) throws -> DisplaySnapshot {
        let width = Int(200 * scale)
        let height = Int(100 * scale)
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
            screenFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
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

    private func makeMouseEvent(type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
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
}
