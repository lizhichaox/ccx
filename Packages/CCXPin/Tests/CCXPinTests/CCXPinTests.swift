import AppKit
import CoreGraphics
import CCXCore
@testable import CCXPin
import XCTest

private func makePinTestImage(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b, a) = pixel(x, y)
            let i = (y * width + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
}

final class PinStateTests: XCTestCase {
    func testDefaultsAndClampingOnInit() {
        let defaults = PinState()
        XCTAssertEqual(defaults.zoom, 1.0)
        XCTAssertEqual(defaults.opacity, 1.0)
        XCTAssertEqual(defaults.rotationDegrees, 0)
        XCTAssertFalse(defaults.isClickThrough)
        XCTAssertFalse(defaults.isThumbnail)
        XCTAssertTrue(defaults.showsBorder)
        XCTAssertTrue(defaults.showsShadow)

        let clampedLow = PinState(zoom: 0.01, opacity: -0.5, rotationDegrees: -90)
        XCTAssertEqual(clampedLow.zoom, 0.1)
        XCTAssertEqual(clampedLow.opacity, 0.1)
        XCTAssertEqual(clampedLow.rotationDegrees, 270)
        XCTAssertTrue(clampedLow.isQuarterTurned)

        let clampedHigh = PinState(zoom: 50, opacity: 2.5, rotationDegrees: 450)
        XCTAssertEqual(clampedHigh.zoom, 10.0)
        XCTAssertEqual(clampedHigh.opacity, 1.0)
        XCTAssertEqual(clampedHigh.rotationDegrees, 90)

        let nonFinite = PinState(zoom: .nan, opacity: .infinity)
        XCTAssertEqual(nonFinite.zoom, 1.0)
        XCTAssertEqual(nonFinite.opacity, 1.0)
    }

    func testMutatingHelpers() {
        var state = PinState()
        state.multiplyZoom(by: 20)
        XCTAssertEqual(state.zoom, 10.0)
        state.multiplyZoom(by: 0.001)
        XCTAssertEqual(state.zoom, 0.1)
        state.resetZoom()
        XCTAssertEqual(state.zoom, 1.0)

        state.adjustOpacity(by: -0.6)
        XCTAssertEqual(state.opacity, 0.4, accuracy: 0.0001)
        state.adjustOpacity(by: -1.0)
        XCTAssertEqual(state.opacity, 0.1, accuracy: 0.0001)
        state.setOpacity(5.0)
        XCTAssertEqual(state.opacity, 1.0)

        state.rotateClockwise()
        XCTAssertEqual(state.rotationDegrees, 90)
        XCTAssertTrue(state.isQuarterTurned)
        state.rotateClockwise()
        XCTAssertEqual(state.rotationDegrees, 180)
        XCTAssertFalse(state.isQuarterTurned)
        state.rotate(byDegrees: -270)
        XCTAssertEqual(state.rotationDegrees, 270)
        state.rotateClockwise()
        XCTAssertEqual(state.rotationDegrees, 0)

        state.toggleClickThrough()
        XCTAssertTrue(state.isClickThrough)
        state.toggleThumbnail()
        XCTAssertTrue(state.isThumbnail)

        state.rotateCounterClockwise()
        XCTAssertEqual(state.rotationDegrees, 270)
        state.toggleFlipHorizontal()
        XCTAssertTrue(state.isFlippedHorizontally)
        state.toggleFlipVertical()
        XCTAssertTrue(state.isFlippedVertically)
    }
}

final class PinLayoutTests: XCTestCase {
    func testBaseSizeForContents() {
        let img = makePinTestImage(width: 200, height: 100) { _, _ in (255, 0, 0, 255) }
        XCTAssertEqual(PinLayout.baseSize(for: .image(img, scale: 2)), CGSize(width: 100, height: 50))
        XCTAssertEqual(PinLayout.baseSize(for: .image(img, scale: 0)), CGSize(width: 200, height: 100))
        XCTAssertEqual(PinLayout.baseSize(for: .color(CCXColorSample(red: 1, green: 2, blue: 3))),
                       PinLayout.colorCardSize)
        let textSize = PinLayout.baseSize(for: .text("Hello CCX"))
        XCTAssertGreaterThanOrEqual(textSize.width, PinLayout.minTextCardSize.width)
        XCTAssertGreaterThanOrEqual(textSize.height, PinLayout.minTextCardSize.height)
    }

    func testFrameSizeWithRotationZoomAndThumbnail() {
        let base = CGSize(width: 200, height: 100)
        XCTAssertEqual(PinLayout.frameSize(baseSize: base, state: PinState(zoom: 1.5)),
                       CGSize(width: 300, height: 150))
        XCTAssertEqual(PinLayout.frameSize(baseSize: base, state: PinState(zoom: 1.0, rotationDegrees: 90)),
                       CGSize(width: 100, height: 200))
        XCTAssertEqual(PinLayout.frameSize(baseSize: base, state: PinState(zoom: 2.0, isThumbnail: true)),
                       CGSize(width: 72, height: 72))
    }

    func testResizedFramePreservesAnchor() {
        let frame = CGRect(x: 100, y: 200, width: 100, height: 50)
        let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        let collapsed = PinLayout.resizedFrame(frame, to: CGSize(width: 72, height: 72), keeping: topLeft)
        XCTAssertEqual(collapsed.minX, frame.minX)
        XCTAssertEqual(collapsed.maxY, frame.maxY)
        XCTAssertEqual(collapsed.size, CGSize(width: 72, height: 72))

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let zoomed = PinLayout.resizedFrame(frame, to: CGSize(width: 200, height: 100), keeping: center)
        XCTAssertEqual(zoomed.midX, frame.midX)
        XCTAssertEqual(zoomed.midY, frame.midY)
    }

    func testInitialPlacementSeamlessAndCentered() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 300, y: 400, width: 120, height: 80)
        let seamless = PinLayout.initialPlacement(baseSize: CGSize(width: 120, height: 80),
                                                  screenRect: rect,
                                                  visibleFrame: visible)
        XCTAssertEqual(seamless.frame, rect)
        XCTAssertEqual(seamless.zoom, 1.0)

        let centered = PinLayout.initialPlacement(baseSize: CGSize(width: 200, height: 100),
                                                  screenRect: nil,
                                                  visibleFrame: visible)
        XCTAssertEqual(centered.zoom, 1.0)
        XCTAssertEqual(centered.frame.midX, visible.midX)
        XCTAssertEqual(centered.frame.midY, visible.midY)

        // Oversize image shrinks to fit within 90% of visibleFrame.
        let huge = PinLayout.initialPlacement(baseSize: CGSize(width: 4000, height: 2000),
                                              screenRect: nil,
                                              visibleFrame: visible)
        XCTAssertLessThan(huge.zoom, 1.0)
        XCTAssertLessThanOrEqual(huge.frame.width, visible.width * 0.9 + 1)
        XCTAssertLessThanOrEqual(huge.frame.height, visible.height * 0.9 + 1)
    }

    func testRotatedImageDimensionsAndPixelMapping() {
        // 4x2 image with red pixel at top-left (0, 0).
        let img = makePinTestImage(width: 4, height: 2) { x, y in
            (x == 0 && y == 0) ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        let rot90 = PinLayout.rotatedImage(img, clockwiseDegrees: 90)!
        XCTAssertEqual(rot90.width, 2)
        XCTAssertEqual(rot90.height, 4)
        // Rotating 90 deg clockwise moves top-left (0, 0) to top-right (1, 0).
        XCTAssertEqual(CCXColorSample.samplePixel(from: rot90, pixelX: 1, pixelY: 0)?.red, 255)

        let rot180 = PinLayout.rotatedImage(img, clockwiseDegrees: 180)!
        XCTAssertEqual(rot180.width, 4)
        XCTAssertEqual(rot180.height, 2)
        XCTAssertEqual(CCXColorSample.samplePixel(from: rot180, pixelX: 3, pixelY: 1)?.red, 255)

        let flipH = PinLayout.transformedImage(img, clockwiseDegrees: 0, flipHorizontal: true, flipVertical: false)!
        XCTAssertEqual(CCXColorSample.samplePixel(from: flipH, pixelX: 3, pixelY: 0)?.red, 255)

        let flipV = PinLayout.transformedImage(img, clockwiseDegrees: 0, flipHorizontal: false, flipVertical: true)!
        XCTAssertEqual(CCXColorSample.samplePixel(from: flipV, pixelX: 0, pixelY: 1)?.red, 255)

        let rot90FlipH = PinLayout.transformedImage(img, clockwiseDegrees: 90, flipHorizontal: true, flipVertical: false)!
        XCTAssertEqual(CCXColorSample.samplePixel(from: rot90FlipH, pixelX: 0, pixelY: 0)?.red, 255)
    }

    @MainActor
    func testExportImageForAllContentKinds() {
        let colorImg = PinRenderer.exportImage(for: .color(CCXColorSample(red: 12, green: 34, blue: 56)),
                                               rotationDegrees: 0, scale: 2)
        XCTAssertEqual(colorImg?.width, Int(PinLayout.colorCardSize.width * 2))
        XCTAssertEqual(colorImg?.height, Int(PinLayout.colorCardSize.height * 2))

        let textImg = PinRenderer.exportImage(for: .text("Pinned note"), rotationDegrees: 90, scale: 1)
        XCTAssertNotNil(textImg)
    }
}

@MainActor
final class PinPanelAndManagerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }

    private func makeStore() -> (ClipboardStore, InMemoryClipboardPasteboard) {
        let pb = InMemoryClipboardPasteboard()
        return (ClipboardStore(pasteboard: pb), pb)
    }

    func testPinPanelWindowPropertiesAndContextMenu() {
        let img = makePinTestImage(width: 200, height: 100) { _, _ in (10, 20, 30, 255) }
        let frame = CGRect(x: 100, y: 200, width: 100, height: 50)
        let panel = PinPanel(content: .image(img, scale: 2), frame: frame)
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)

        // Zoom, opacity, rotation, click-through, thumbnail.
        panel.setZoom(2.0)
        XCTAssertEqual(panel.frame.size, CGSize(width: 200, height: 100))

        panel.setOpacity(0.6)
        XCTAssertEqual(panel.alphaValue, 0.6, accuracy: 0.001)

        panel.rotateClockwise()
        XCTAssertEqual(panel.state.rotationDegrees, 90)
        XCTAssertEqual(panel.frame.size, CGSize(width: 100, height: 200))

        panel.setClickThrough(true)
        XCTAssertTrue(panel.ignoresMouseEvents)

        let topLeftBefore = panel.frameTopLeft
        panel.toggleThumbnail()
        XCTAssertTrue(panel.state.isThumbnail)
        XCTAssertEqual(panel.frame.size, CGSize(width: 72, height: 72))
        XCTAssertEqual(panel.frameTopLeft.x, topLeftBefore.x, accuracy: 1)
        XCTAssertEqual(panel.frameTopLeft.y, topLeftBefore.y, accuracy: 1)

        panel.toggleThumbnail()
        XCTAssertFalse(panel.state.isThumbnail)
        XCTAssertEqual(panel.frame.size, CGSize(width: 100, height: 200))

        // Verify right-click context menu items.
        let menu = panel.makeContextMenu()
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Copy"))
        XCTAssertTrue(titles.contains("Copy Text (OCR)"))
        XCTAssertTrue(titles.contains("Save PNG"))
        XCTAssertTrue(titles.contains("Quick Save PNG"))
        XCTAssertTrue(titles.contains("Duplicate"))
        XCTAssertTrue(titles.contains("Reset Zoom (100%)"))
        XCTAssertTrue(titles.contains("Rotate 90°"))
        XCTAssertTrue(titles.contains("Flip Horizontal"))
        XCTAssertTrue(titles.contains("Flip Vertical"))
        XCTAssertTrue(titles.contains("Opacity"))
        XCTAssertTrue(titles.contains("Toggle Click-Through"))
        XCTAssertTrue(titles.contains("Toggle Thumbnail"))
        XCTAssertTrue(titles.contains("Show Border"))
        XCTAssertTrue(titles.contains("Show Shadow"))
        XCTAssertTrue(titles.contains("Close Pin"))
        XCTAssertTrue(titles.contains("Hide All Pins"))
        XCTAssertTrue(titles.contains("Close All Pins"))

        // Keyboard shortcuts on focused panel: arrows nudge 1pt / Shift+Arrow 10pt, R, H, V, 0, Shift+0 reset.
        let originBeforeNudge = panel.frame.origin
        if let rightArrow = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124
        ) {
            panel.keyDown(with: rightArrow)
            XCTAssertEqual(panel.frame.origin.x, originBeforeNudge.x + 1, accuracy: 0.01)
        }
        if let shiftUp = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126
        ) {
            panel.keyDown(with: shiftUp)
            XCTAssertEqual(panel.frame.origin.y, originBeforeNudge.y + 10, accuracy: 0.01)
        }
        if let rKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
        ) {
            panel.keyDown(with: rKey)
            XCTAssertEqual(panel.state.rotationDegrees, 180)
        }
        if let hKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4
        ) {
            panel.keyDown(with: hKey)
            XCTAssertTrue(panel.state.isFlippedHorizontally)
        }
        if let zeroKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29
        ) {
            panel.keyDown(with: zeroKey)
            XCTAssertEqual(panel.state.zoom, 1.0)
        }
        if let shiftZero = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: ")", charactersIgnoringModifiers: ")", isARepeat: false, keyCode: 29
        ) {
            panel.setOpacity(0.5)
            panel.keyDown(with: shiftZero)
            XCTAssertEqual(panel.state.rotationDegrees, 0)
            XCTAssertEqual(panel.state.opacity, 1.0)
            XCTAssertFalse(panel.state.isFlippedHorizontally)
        }

        let opacitySubmenu = menu.items.first(where: { $0.title == "Opacity" })?.submenu
        XCTAssertEqual(opacitySubmenu?.items.map(\.title), ["100%", "80%", "60%", "40%", "20%"])
    }

    func testPinDuplicateQuickSaveAndColorFormatMenu() {
        let (store, pb) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        var quickSavedImages: [CGImage] = []
        manager.onRequestQuickSavePNG = { quickSavedImages.append($0) }
        var copiedMessages: [String] = []
        manager.onCopied = { copiedMessages.append($0) }

        let img = makePinTestImage(width: 80, height: 40) { _, _ in (10, 20, 30, 255) }
        manager.pin(content: .image(img, scale: 2), at: CGRect(x: 150, y: 150, width: 40, height: 20))
        let original = try! XCTUnwrap(manager.panels.first)
        original.setClickThrough(true)
        original.rotateClockwise()

        if let cmdD = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
        ) {
            XCTAssertTrue(original.performKeyEquivalent(with: cmdD))
        }
        XCTAssertEqual(manager.pinCount, 2)
        let cloned = try! XCTUnwrap(manager.panels.last)
        XCTAssertFalse(cloned.state.isClickThrough)
        XCTAssertEqual(cloned.state.rotationDegrees, 90)

        if let shiftCmdS = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
        ) {
            XCTAssertTrue(cloned.performKeyEquivalent(with: shiftCmdS))
        }
        XCTAssertEqual(quickSavedImages.count, 1)
        XCTAssertEqual(quickSavedImages.first?.width, 40)

        store.copyText("#FF8000")
        XCTAssertTrue(manager.pinFromClipboard())
        let colorPanel = try! XCTUnwrap(manager.panels.last)
        let colorTitles = colorPanel.makeContextMenu().items.map(\.title)
        XCTAssertTrue(colorTitles.contains("Copy HEX"))
        XCTAssertTrue(colorTitles.contains("Copy RGB"))
        XCTAssertTrue(colorTitles.contains("Copy HSL"))

        colorPanel.copyRGBColor(nil)
        XCTAssertEqual(pb.string(), "rgb(255, 128, 0)")
        colorPanel.copyHSLColor(nil)
        XCTAssertEqual(pb.string(), "hsl(30, 100%, 50%)")
        XCTAssertEqual(copiedMessages.suffix(2), ["Copied rgb(255, 128, 0)", "Copied hsl(30, 100%, 50%)"])
    }

    func testPinManagerLifecycleClipboardAndCallbacks() {
        let (store, pb) = makeStore()
        let manager = PinManager(clipboardStore: store)
        var changeCount = 0
        manager.onPinsChanged = { changeCount += 1 }
        var savedImages: [CGImage] = []
        manager.onRequestSavePNG = { savedImages.append($0) }
        var copiedMessages: [String] = []
        manager.onCopied = { copiedMessages.append($0) }
        var ocrImages: [CGImage] = []
        manager.onRequestRecognizeText = { ocrImages.append($0) }

        // Empty clipboard -> returns false.
        pb.clearContents()
        XCTAssertFalse(manager.pinFromClipboard())
        XCTAssertEqual(manager.pinCount, 0)

        // Pin HEX color from clipboard.
        store.copyText("#336699")
        XCTAssertTrue(manager.pinFromClipboard())
        XCTAssertEqual(manager.pinCount, 1)

        // Pin text from clipboard.
        store.copyText("Remember to ship")
        XCTAssertTrue(manager.pinFromClipboard())
        XCTAssertEqual(manager.pinCount, 2)

        // Pin image at explicit rect.
        let img = makePinTestImage(width: 160, height: 80) { _, _ in (255, 128, 0, 255) }
        let targetRect = CGRect(x: 200, y: 200, width: 80, height: 40)
        manager.pin(content: .image(img, scale: 2), at: targetRect)
        XCTAssertEqual(manager.pinCount, 3)
        XCTAssertEqual(manager.panels.last?.frame, targetRect)

        // Click-through tracking and global unlock.
        XCTAssertFalse(manager.hasClickThroughPins)
        manager.panels[0].setClickThrough(true)
        XCTAssertTrue(manager.hasClickThroughPins)
        manager.disableClickThroughForAllPins()
        XCTAssertFalse(manager.hasClickThroughPins)

        // Hide/show all pins, and verify pinning while hidden reveals pins.
        XCTAssertFalse(manager.arePinsHidden)
        manager.toggleVisibilityOfAllPins()
        XCTAssertTrue(manager.arePinsHidden)
        store.copyImage(img, scale: 2)
        XCTAssertTrue(manager.pinFromClipboard())
        XCTAssertFalse(manager.arePinsHidden)
        XCTAssertEqual(manager.pinCount, 4)

        // Save and copy callbacks on panels.
        manager.panels[2].savePin(nil)
        XCTAssertEqual(savedImages.count, 1)
        XCTAssertEqual(savedImages.first?.width, 160)

        manager.panels[0].copyPin(nil)
        XCTAssertEqual(pb.string(), "#336699")

        manager.panels[1].copyPin(nil)
        XCTAssertEqual(pb.string(), "Remember to ship")

        manager.panels[2].copyPin(nil)
        XCTAssertNotNil(pb.data(forType: .png))
        XCTAssertEqual(copiedMessages.count, 3)

        manager.panels[2].recognizeTextFromMenu(nil)
        XCTAssertEqual(ocrImages.count, 1)

        // Closing one panel via Esc (`cancelOperation`) updates pinCount.
        manager.panels[0].cancelOperation(nil)
        XCTAssertEqual(manager.pinCount, 3)

        // Close all.
        manager.closeAllPins()
        XCTAssertEqual(manager.pinCount, 0)
        XCTAssertFalse(manager.arePinsHidden)
        XCTAssertGreaterThan(changeCount, 0)
    }

    func testPinViewRendersAllModesWithoutCrash() {
        let img = makePinTestImage(width: 40, height: 20) { _, _ in (200, 100, 50, 255) }
        let contents: [PinContent] = [
            .image(img, scale: 2),
            .text("Sample text card"),
            .color(CCXColorSample(red: 255, green: 64, blue: 128)),
        ]
        for content in contents {
            let panel = PinPanel(content: content, frame: CGRect(x: 0, y: 0, width: 120, height: 80))
            defer { panel.close() }
            if let view = panel.contentView {
                XCTAssertNotNil(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
                panel.setClickThrough(true)
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
                panel.toggleThumbnail()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
            }
        }
    }
}
