import AppKit
import CoreGraphics
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
}
