import AppKit
import CCXAnnotate
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

        // Tall scrolling snip shrinks to fit within 90% of visibleFrame even with screenRect supplied.
        let tallRect = CGRect(x: 400, y: 200, width: 400, height: 500)
        let tallPlaced = PinLayout.initialPlacement(baseSize: CGSize(width: 400, height: 3000),
                                                    screenRect: tallRect,
                                                    visibleFrame: visible)
        XCTAssertLessThan(tallPlaced.zoom, 1.0)
        XCTAssertLessThanOrEqual(tallPlaced.frame.height, visible.height * 0.9 + 1)
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

    nonisolated override func setUp() {
        super.setUp()
        CCXL10n.setLanguageOverrideForTesting(.en)
    }

    nonisolated override func tearDown() {
        CCXL10n.setLanguageOverrideForTesting(nil)
        super.tearDown()
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

        // Hide/show all pins, and verify pinning a new item while hidden reveals pins.
        XCTAssertFalse(manager.arePinsHidden)
        manager.toggleVisibilityOfAllPins()
        XCTAssertTrue(manager.arePinsHidden)
        let img2 = makePinTestImage(width: 90, height: 45) { _, _ in (0, 200, 255, 255) }
        store.copyImage(img2, scale: 2)
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

    func testPinFromClipboardFailsAfterClearHistoryAndClipboard() {
        let (store, pb) = makeStore()
        let manager = PinManager(clipboardStore: store)
        let img = makePinTestImage(width: 80, height: 60) { _, _ in (10, 200, 120, 255) }

        store.recordSnip(image: img, scale: 2, screenRect: CGRect(x: 0, y: 0, width: 40, height: 30))
        store.copyImage(img, scale: 2)
        XCTAssertEqual(store.peekPinBadge(), .image)

        store.clearHistoryAndClipboard()
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.peekPinBadge(), .empty)
        XCTAssertFalse(manager.pinFromClipboard())
        XCTAssertEqual(manager.pinCount, 0)
        XCTAssertNil(pb.data(forType: .png))

        // Clearing after copying another image while existing pins are hidden must not pin or unhide pins.
        manager.pin(content: .text("Existing"), at: CGRect(x: 50, y: 50, width: 100, height: 40))
        manager.toggleVisibilityOfAllPins()
        XCTAssertTrue(manager.arePinsHidden)

        store.copyImage(img, scale: 2)
        store.clearHistoryAndClipboard()
        XCTAssertFalse(manager.pinFromClipboard())
        XCTAssertEqual(manager.pinCount, 1)
        XCTAssertTrue(manager.arePinsHidden)
    }

    func testPinNextAvailablePinsNewestToOldestWithoutDuplicatesAndPromptsWhenExhausted() {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        XCTAssertEqual(manager.pinTileStatus(), .empty)
        XCTAssertEqual(manager.pinNextAvailable(), .nothingAvailable)

        let img1 = makePinTestImage(width: 80, height: 60) { _, _ in (220, 40, 40, 255) }
        let img2 = makePinTestImage(width: 80, height: 60) { _, _ in (40, 200, 80, 255) }
        let img3 = makePinTestImage(width: 80, height: 60) { _, _ in (40, 120, 240, 255) }

        let s1 = store.recordSnip(image: img1, scale: 2, screenRect: .zero)!
        store.copyImage(img1, scale: 2, historyEntryID: s1.id)
        let s2 = store.recordSnip(image: img2, scale: 2, screenRect: .zero)!
        let s3 = store.recordSnip(image: img3, scale: 2, screenRect: .zero)!
        store.copyImage(img3, scale: 2, historyEntryID: s3.id)

        XCTAssertEqual(manager.pinTileStatus(), .ready(count: 3, primaryLabel: "Image"))

        // Clicks 1, 2, 3 pin newest-to-oldest (S3 -> S2 -> S1) with cascaded frames.
        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertEqual(manager.pinCount, 1)
        XCTAssertTrue(manager.panels[0].contentIdentity.matches(s3.pinIdentity))

        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertEqual(manager.pinCount, 2)
        XCTAssertTrue(manager.panels[1].contentIdentity.matches(s2.pinIdentity))
        XCTAssertNotEqual(manager.panels[1].frame.origin, manager.panels[0].frame.origin)

        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertEqual(manager.pinCount, 3)
        XCTAssertTrue(manager.panels[2].contentIdentity.matches(s1.pinIdentity))

        // Exhausted: tile shows `.allPinned`, next click reports `.allAlreadyPinned`, no duplicate pin.
        XCTAssertEqual(manager.pinTileStatus(), .allPinned)
        XCTAssertEqual(manager.pinNextAvailable(), .allAlreadyPinned)
        XCTAssertEqual(manager.pinCount, 3)
        XCTAssertFalse(manager.pin(content: .image(img2, scale: 2), at: nil, contentIdentity: s2.pinIdentity))

        // Closing S2 makes only S2 eligible again.
        manager.panels[1].close()
        XCTAssertEqual(manager.pinCount, 2)
        XCTAssertEqual(manager.pinTileStatus(), .ready(count: 1, primaryLabel: "Image"))
        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertEqual(manager.pinCount, 3)
        XCTAssertTrue(manager.isPinned(s2.pinIdentity))
        XCTAssertEqual(manager.pinNextAvailable(), .allAlreadyPinned)

        // Copying an older snip S1 while S3 and S1 are unpinned still pins newest (S3) first.
        let s3Panel = manager.existingPanel(matching: s3.pinIdentity)
        let s1Panel = manager.existingPanel(matching: s1.pinIdentity)
        s3Panel?.close()
        s1Panel?.close()
        XCTAssertEqual(manager.pinCount, 1)
        store.copyImage(img1, scale: 2, historyEntryID: s1.id)
        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertTrue(manager.panels.last?.contentIdentity.matches(s3.pinIdentity) == true)
        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertTrue(manager.panels.last?.contentIdentity.matches(s1.pinIdentity) == true)

        // External text copied AFTER latest snip pins first, and will not duplicate.
        store.copyText("External Note")
        XCTAssertEqual(manager.pinTileStatus(), .ready(count: 1, primaryLabel: "Text"))
        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertEqual(manager.pinCount, 4)
        XCTAssertEqual(manager.pinNextAvailable(), .allAlreadyPinned)
        XCTAssertEqual(manager.pinCount, 4)

        // Clearing history + clipboard and closing pins returns to `.nothingAvailable`.
        store.clearHistoryAndClipboard()
        manager.closeAllPins()
        XCTAssertEqual(manager.pinTileStatus(), .empty)
        XCTAssertEqual(manager.pinNextAvailable(), .nothingAvailable)
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

    func testPinPanelTransformHUDAndDuplicateFocusHUD() {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (120, 180, 240, 255) }
        let identity = PinContentIdentity.image(ImageFingerprint(image: img))
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70), contentIdentity: identity))
        let panel = try! XCTUnwrap(manager.panels.first)

        panel.rotateClockwise()
        XCTAssertEqual(panel.lastHUDTextForTesting, "90°")
        panel.toggleFlipHorizontal()
        XCTAssertEqual(panel.lastHUDTextForTesting, "Flipped H")
        panel.toggleFlipHorizontal()
        XCTAssertEqual(panel.lastHUDTextForTesting, "Unflipped H")
        panel.toggleFlipVertical()
        XCTAssertEqual(panel.lastHUDTextForTesting, "Flipped V")
        panel.resetAllTransforms()
        XCTAssertEqual(panel.lastHUDTextForTesting, "Reset")

        panel.toggleThumbnail()
        XCTAssertNil(panel.lastHUDTextForTesting)
        panel.flashHUD("Pinned")
        XCTAssertNil(panel.lastHUDTextForTesting)
        panel.toggleThumbnail()

        XCTAssertFalse(manager.pin(content: .image(img, scale: 2), at: nil, contentIdentity: identity))
        XCTAssertEqual(panel.lastHUDTextForTesting, "Pinned")
    }

    func testDoubleClickImagePinOpensAnnotationToolbarSupportsNonDestructiveEditsAndCoordination() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let imgA = makePinTestImage(width: 240, height: 140) { _, _ in (240, 240, 240, 255) }
        let entryID = UUID()
        let identityA = PinContentIdentity.image(ImageFingerprint(image: imgA), historyEntryID: entryID)
        XCTAssertTrue(manager.pin(content: .image(imgA, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70), contentIdentity: identityA))
        let panelA = try XCTUnwrap(manager.panels.first)

        let closedMenu = panelA.makeContextMenu()
        let closedMenuTitles = closedMenu.items.map(\.title)
        XCTAssertEqual(closedMenuTitles.first, "Show Toolbar")
        XCTAssertTrue(closedMenu.items[1].isSeparatorItem)
        XCTAssertTrue(closedMenuTitles.contains("Toggle Thumbnail"))

        // Double-clicking an image pin opens its floating annotation toolbar instead of collapsing to thumbnail.
        let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 60, y: 35),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        panelA.contentView?.mouseDown(with: doubleClick)
        XCTAssertTrue(panelA.isToolbarVisible)
        XCTAssertFalse(panelA.state.isThumbnail)
        XCTAssertNotNil(panelA.toolbarPanelForTesting)
        XCTAssertEqual(panelA.makeContextMenu().items.first?.title, "Hide Toolbar")

        // Select rectangle tool (`1`), draw a bright red rectangle across the center, and test undo/redo.
        let key1 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        panelA.keyDown(with: key1)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 15), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 100, y: 55), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 100, y: 55), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panelA.contentView?.mouseDown(with: down)
        panelA.contentView?.mouseDragged(with: drag)
        panelA.contentView?.mouseUp(with: up)
        XCTAssertEqual(panelA.annotationDocumentForTesting?.items.count, 1)

        // While open, exportImage() bakes the rectangle stroke at pixel edge (x=40, y=30 -> top-left local(20,55) -> y_img=(70-55)*2=30).
        let liveExport = try XCTUnwrap(panelA.exportImage())
        let edgePixel = try XCTUnwrap(CCXColorSample.samplePixel(from: liveExport, pixelX: 40, pixelY: 30))
        XCTAssertGreaterThan(edgePixel.red, 180)
        XCTAssertLessThan(edgePixel.blue, 100)

        // Commit via Return / Done -> toolbar closes, baked image stays on panel, history identity remains dedup-matched.
        panelA.toolbarViewForTesting?.onAction?(.done)
        XCTAssertFalse(panelA.isToolbarVisible)
        XCTAssertNil(panelA.toolbarPanelForTesting)
        XCTAssertTrue(panelA.contentIdentity.matches(.image(ImageFingerprint(image: imgA), historyEntryID: entryID)))

        // Non-destructive re-open preserves prior annotation items, and cancelling edits rolls back new strokes only.
        panelA.showAnnotationToolbar()
        XCTAssertTrue(panelA.isToolbarVisible)
        XCTAssertEqual(panelA.annotationDocumentForTesting?.items.count, 1)

        panelA.keyDown(with: key1)
        let down2 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 48, y: 28), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let drag2 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 72, y: 42), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up2 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 72, y: 42), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panelA.contentView?.mouseDown(with: down2)
        panelA.contentView?.mouseDragged(with: drag2)
        panelA.contentView?.mouseUp(with: up2)
        XCTAssertEqual(panelA.annotationDocumentForTesting?.items.count, 2)

        panelA.cancelOperation(nil) // Esc cancels session edits, keeps panel open & rolls back to 1 item
        XCTAssertFalse(panelA.isToolbarVisible)
        XCTAssertEqual(panelA.annotationDocumentForTesting?.items.count, 1)
        XCTAssertEqual(manager.pinCount, 1)

        // Double-clicking a collapsed image thumbnail restores it without opening the toolbar.
        panelA.toggleThumbnail()
        XCTAssertTrue(panelA.state.isThumbnail)
        panelA.contentView?.mouseDown(with: doubleClick)
        XCTAssertFalse(panelA.state.isThumbnail)
        XCTAssertFalse(panelA.isToolbarVisible)

        // Opening toolbar on a rotated image pin flattens rotation into the canvas while preserving frame size.
        panelA.rotateClockwise()
        let rotatedFrameSize = panelA.frame.size
        panelA.showAnnotationToolbar()
        XCTAssertTrue(panelA.isToolbarVisible)
        XCTAssertEqual(panelA.state.rotationDegrees, 0)
        XCTAssertEqual(panelA.frame.size, rotatedFrameSize)

        // Opening toolbar on Pin B automatically commits & closes Pin A's toolbar; Hide All closes any open toolbar.
        let imgB = makePinTestImage(width: 200, height: 120) { _, _ in (20, 40, 200, 255) }
        XCTAssertTrue(manager.pin(content: .image(imgB, scale: 2), at: CGRect(x: 320, y: 120, width: 100, height: 60)))
        let panelB = try XCTUnwrap(manager.panels.last)
        panelB.showAnnotationToolbar()
        XCTAssertFalse(panelA.isToolbarVisible)
        XCTAssertTrue(panelB.isToolbarVisible)

        manager.toggleVisibilityOfAllPins()
        XCTAssertFalse(panelB.isToolbarVisible)
        manager.toggleVisibilityOfAllPins()

        // Text / color pins keep double-click -> thumbnail behavior.
        XCTAssertTrue(manager.pin(content: .text("Keep thumbnail"), at: CGRect(x: 500, y: 120, width: 140, height: 50)))
        let textPanel = try XCTUnwrap(manager.panels.last)
        textPanel.contentView?.mouseDown(with: doubleClick)
        XCTAssertTrue(textPanel.state.isThumbnail)
        XCTAssertFalse(textPanel.isToolbarVisible)
    }

    func testEscapeOnContentViewFirstResponderCancelsInlineTextThenSessionBeforeClosingPin() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (235, 235, 235, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70)))
        let panel = try XCTUnwrap(manager.panels.first)

        panel.showAnnotationToolbar()
        XCTAssertTrue(panel.isToolbarVisible)

        // Select text tool (`7`), click canvas to start inline text editor.
        let key7 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "7", charactersIgnoringModifiers: "7", isARepeat: false, keyCode: 26
        ))
        panel.keyDown(with: key7)
        let clickText = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 35), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: clickText)
        XCTAssertNotNil(panel.inlineEditorForTesting)

        let esc = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))

        // First Esc cancels inline text editor only — toolbar & pin remain open.
        panel.contentView?.keyDown(with: esc)
        XCTAssertNil(panel.inlineEditorForTesting)
        XCTAssertTrue(panel.isToolbarVisible)
        XCTAssertEqual(manager.pinCount, 1)

        // Draw a rectangle, then Esc on contentView cancels session without closing pin.
        let key1 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        panel.keyDown(with: key1)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 15, y: 15), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 80, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 80, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: down)
        panel.contentView?.mouseDragged(with: drag)
        panel.contentView?.mouseUp(with: up)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 1)

        panel.contentView?.keyDown(with: esc)
        XCTAssertFalse(panel.isToolbarVisible)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 0)
        XCTAssertEqual(manager.pinCount, 1)

        // Esc when toolbar is closed closes the pin.
        panel.contentView?.keyDown(with: esc)
        XCTAssertEqual(manager.pinCount, 0)
    }

    func testCmdDDuplicatesSelectedAnnotationAndIncrementsCounterAndPenDoesNotGrabShapes() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 300, height: 200) { _, _ in (240, 240, 240, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 100, y: 100, width: 150, height: 100)))
        let panel = try XCTUnwrap(manager.panels.first)
        panel.showAnnotationToolbar()

        // Place a step counter (`8`) and duplicate it with Cmd+D via performKeyEquivalent.
        let key8 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "8", charactersIgnoringModifiers: "8", isARepeat: false, keyCode: 28
        ))
        panel.keyDown(with: key8)
        let clickCounter = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 40, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: clickCounter)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 1)

        let cmdD = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdD))
        XCTAssertEqual(manager.pinCount, 1, "Cmd+D while annotating must not duplicate the PinPanel")
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 2)
        if case let .counter(_, secondNum)? = panel.annotationDocumentForTesting?.items.last?.kind {
            XCTAssertEqual(secondNum, 2)
        } else {
            XCTFail("Expected duplicated item to be a counter with incremented number")
        }

        // Switch to Pen (`4`) and drag right across counter #1 — must draw a new pen stroke, not move counter.
        let key4 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "4", charactersIgnoringModifiers: "4", isARepeat: false, keyCode: 21
        ))
        panel.keyDown(with: key4)
        let penDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 40, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let penDrag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 90, y: 70), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let penUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 90, y: 70), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: penDown)
        panel.contentView?.mouseDragged(with: penDrag)
        panel.contentView?.mouseUp(with: penUp)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 3)
        if case .pen? = panel.annotationDocumentForTesting?.items.last?.kind {
            // Expected
        } else {
            XCTFail("Expected pen stroke instead of moving existing counter")
        }

        // Slider undo coalescing: dragging slider through multiple sizes records only 1 undo step.
        let toolbar = try XCTUnwrap(panel.toolbarViewForTesting)
        let initialSize = try XCTUnwrap(panel.annotationDocumentForTesting?.selectedItem?.style.size)
        toolbar.onSizeEditingStateChanged?(true)
        toolbar.onSizeChanged?(StrokeSize(progress: 0.2))
        toolbar.onSizeChanged?(StrokeSize(progress: 0.5))
        toolbar.onSizeChanged?(StrokeSize(progress: 0.85))
        toolbar.onSizeEditingStateChanged?(false)
        XCTAssertEqual(panel.annotationDocumentForTesting?.selectedItem?.style.size, StrokeSize(progress: 0.85))

        let cmdZ = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdZ))
        XCTAssertEqual(panel.annotationDocumentForTesting?.selectedItem?.style.size, initialSize)
    }

    func testInlineTextLiveStyleSyncZoomAlignmentAndEditShortcuts() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (240, 240, 240, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 100, y: 100, width: 120, height: 70)))
        let panel = try XCTUnwrap(manager.panels.first)
        panel.showAnnotationToolbar()

        // Commit an initial text annotation.
        let key7 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "7", charactersIgnoringModifiers: "7", isARepeat: false, keyCode: 26
        ))
        panel.keyDown(with: key7)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 35), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: down)
        let editor = try XCTUnwrap(panel.inlineEditorForTesting)
        editor.stringValue = "Hello"

        // Standard editing shortcuts should be handled while editing text.
        for key in ["a", "c", "v", "x", "z"] {
            let ev = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            ))
            XCTAssertTrue(panel.performKeyEquivalent(with: ev), "Cmd+\(key) should be handled in inline text editor")
        }

        // Style changes update live editor color & font; zooming rescales editor frame.
        let frameAt1x = editor.frame
        let toolbar = try XCTUnwrap(panel.toolbarViewForTesting)
        toolbar.onStyleChanged?(AnnotationStyle(color: .blue, size: .large, mosaicMode: .pixelate))
        XCTAssertEqual(editor.textColor, AnnotationColor.blue.nsColor)

        panel.setZoom(2.0)
        XCTAssertGreaterThan(editor.frame.width, frameAt1x.width * 1.5)

        // Commit via closing toolbar, then re-open, double-click text, change style, and cancel with Esc:
        // original committed item style must remain unchanged and undo stack must not leak.
        panel.closeToolbar(commit: true)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 1)
        let committedItem = try XCTUnwrap(panel.annotationDocumentForTesting?.items.first)
        XCTAssertEqual(committedItem.style.color, .blue)

        panel.setZoom(1.0)
        panel.showAnnotationToolbar()
        let textCenter = CGPoint(x: committedItem.boundingBox.midX, y: committedItem.boundingBox.midY)
        let doubleClickText = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: textCenter, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
        ))
        panel.contentView?.mouseDown(with: doubleClickText)
        XCTAssertNotNil(panel.inlineEditorForTesting)
        let reopenedToolbar = try XCTUnwrap(panel.toolbarViewForTesting)
        reopenedToolbar.onStyleChanged?(AnnotationStyle(color: .red, size: .small, mosaicMode: .pixelate))
        XCTAssertEqual(panel.inlineEditorForTesting?.textColor, AnnotationColor.red.nsColor)

        let esc = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        ))
        panel.contentView?.keyDown(with: esc)
        XCTAssertNil(panel.inlineEditorForTesting)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.first?.style.color, .blue)

        // Tiny pin clamps inline editor frame inside content bounds.
        let tinyImg = makePinTestImage(width: 50, height: 30) { _, _ in (220, 220, 220, 255) }
        XCTAssertTrue(manager.pin(content: .image(tinyImg, scale: 1), at: CGRect(x: 300, y: 200, width: 50, height: 30)))
        let tinyPanel = try XCTUnwrap(manager.panels.last)
        tinyPanel.showAnnotationToolbar()
        tinyPanel.keyDown(with: key7)
        let tinyClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 10, y: 15), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        tinyPanel.contentView?.mouseDown(with: tinyClick)
        let tinyEditor = try XCTUnwrap(tinyPanel.inlineEditorForTesting)
        XCTAssertLessThanOrEqual(tinyEditor.frame.maxX, (tinyPanel.contentView?.bounds.width ?? 50) + 0.5)
        XCTAssertLessThanOrEqual(tinyEditor.frame.maxY, (tinyPanel.contentView?.bounds.height ?? 30) + 0.5)
    }

    func testCommandZoomShortcutsAndDuplicateCommitsLiveAnnotations() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (240, 240, 240, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70)))
        let panel = try XCTUnwrap(manager.panels.first)

        // Cmd+=, Cmd+-, Cmd+0, Shift+Cmd+0 via performKeyEquivalent.
        let cmdPlus = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdPlus))
        XCTAssertGreaterThan(panel.state.zoom, 1.05)

        let cmdMinus = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "-", charactersIgnoringModifiers: "-", isARepeat: false, keyCode: 27
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdMinus))
        XCTAssertEqual(panel.state.zoom, 1.0, accuracy: 0.01)

        panel.setZoom(2.0)
        let cmdZero = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdZero))
        XCTAssertEqual(panel.state.zoom, 1.0, accuracy: 0.001)

        panel.rotateClockwise()
        panel.setOpacity(0.5)
        let shiftCmdZero = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: ")", charactersIgnoringModifiers: ")", isARepeat: false, keyCode: 29
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: shiftCmdZero))
        XCTAssertEqual(panel.state.rotationDegrees, 0)
        XCTAssertEqual(panel.state.opacity, 1.0, accuracy: 0.001)

        // Duplicating a pin via context menu while annotation toolbar is open commits live annotations into the clone.
        panel.showAnnotationToolbar()
        let key1 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        panel.keyDown(with: key1)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 15), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 100, y: 55), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 100, y: 55), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: down)
        panel.contentView?.mouseDragged(with: drag)
        panel.contentView?.mouseUp(with: up)

        panel.duplicatePin(nil)
        XCTAssertFalse(panel.isToolbarVisible)
        XCTAssertEqual(manager.pinCount, 2)
        let cloned = try XCTUnwrap(manager.panels.last)
        let clonedExport = try XCTUnwrap(cloned.exportImage())
        let edgePixel = try XCTUnwrap(CCXColorSample.samplePixel(from: clonedExport, pixelX: 40, pixelY: 30))
        XCTAssertGreaterThan(edgePixel.red, 180)
        XCTAssertLessThan(edgePixel.blue, 100)
    }

    func testGPULayerRenderMatchesTransformedOrientation() throws {
        // 40x20 image with a solid red top-left quadrant and blue everywhere else.
        let img = makePinTestImage(width: 40, height: 20) { x, y in
            (x < 20 && y < 10) ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        let panel = PinPanel(content: .image(img, scale: 1), frame: CGRect(x: 100, y: 100, width: 40, height: 20))
        defer { panel.close() }
        panel.setShowsBorder(false)
        panel.rotateClockwise()
        panel.toggleFlipHorizontal()

        let view = try XCTUnwrap(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let rendered = try XCTUnwrap(rep.cgImage)
        // 90° CW moves top-left -> top-right; flipH moves top-right -> top-left.
        let topLeft = try XCTUnwrap(CCXColorSample.samplePixel(
            from: rendered,
            pixelX: rendered.width / 4,
            pixelY: rendered.height / 4
        ))
        XCTAssertGreaterThan(topLeft.red, 200)
        XCTAssertLessThan(topLeft.blue, 50)
    }

    func testMomentumAndHorizontalScrollDoNotZoomOrLeakFromThicknessScroll() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (220, 220, 220, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70)))
        let panel = try XCTUnwrap(manager.panels.first)

        func makeScrollEvent(deltaY: Int32, deltaX: Int32 = 0, momentumPhase: Int64 = 0) -> NSEvent? {
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            ) else { return nil }
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
            return NSEvent(cgEvent: cgEvent)
        }

        // Momentum scroll with toolbar closed must not change zoom.
        if let momentum = makeScrollEvent(deltaY: 40, momentumPhase: 2) {
            XCTAssertFalse(momentum.momentumPhase.isEmpty)
            panel.scrollWheel(with: momentum)
            XCTAssertEqual(panel.state.zoom, 1.0, accuracy: 0.0001)
        }

        // Horizontal-dominant scroll must not change zoom.
        if let horizontal = makeScrollEvent(deltaY: 2, deltaX: 30, momentumPhase: 0) {
            panel.scrollWheel(with: horizontal)
            XCTAssertEqual(panel.state.zoom, 1.0, accuracy: 0.0001)
        }

        // Active vertical scroll with toolbar closed zooms smoothly.
        if let activeZoom = makeScrollEvent(deltaY: 20, momentumPhase: 0) {
            panel.scrollWheel(with: activeZoom)
            XCTAssertGreaterThan(panel.state.zoom, 1.05)
        }

        // With toolbar open & drawing tool active, momentum scroll from thickness gesture must NOT zoom the pin.
        panel.setZoom(1.0)
        panel.showAnnotationToolbar()
        let key1 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        panel.keyDown(with: key1)
        let sizeBefore = panel.currentAnnotationStyle.size
        if let momentumDuringTool = makeScrollEvent(deltaY: 40, momentumPhase: 2) {
            panel.scrollWheel(with: momentumDuringTool)
            XCTAssertEqual(panel.state.zoom, 1.0, accuracy: 0.0001)
            XCTAssertEqual(panel.currentAnnotationStyle.size, sizeBefore)
        }
    }

    func testClickThroughSafetyCoalescingContextMenuAndCloseAllToolbars() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img1 = makePinTestImage(width: 160, height: 100) { _, _ in (100, 150, 200, 255) }
        let img2 = makePinTestImage(width: 160, height: 100) { _, _ in (200, 150, 100, 255) }
        XCTAssertTrue(manager.pin(content: .image(img1, scale: 2), at: CGRect(x: 100, y: 100, width: 80, height: 50)))
        XCTAssertTrue(manager.pin(content: .image(img2, scale: 2), at: CGRect(x: 240, y: 100, width: 80, height: 50)))

        let p1 = manager.panels[0]
        let p2 = manager.panels[1]
        XCTAssertTrue(p1.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(p1.canBecomeKey)

        p1.setClickThrough(true)
        XCTAssertFalse(p1.canBecomeKey)
        XCTAssertEqual(p1.lastHUDTextForTesting, "Click-Through")
        XCTAssertEqual(manager.clickThroughPinCount, 1)

        // Interactive pin p2 exposes "Unlock Click-Through Pins (1)" plus new transform menu items.
        let menuTitles = p2.makeContextMenu().items.map(\.title)
        XCTAssertTrue(menuTitles.contains("Unlock Click-Through Pins (1)"))
        XCTAssertTrue(menuTitles.contains("Rotate 90° CCW"))
        XCTAssertTrue(menuTitles.contains("Reset All Transforms"))

        // Thumbnail mode disables zoom/rotate/flip menu items.
        p2.toggleThumbnail()
        let thumbMenu = p2.makeContextMenu()
        XCTAssertEqual(thumbMenu.items.first(where: { $0.title == "Rotate 90°" })?.isEnabled, false)
        XCTAssertEqual(thumbMenu.items.first(where: { $0.title == "Reset Zoom (100%)" })?.isEnabled, false)
        p2.toggleThumbnail()

        // Unlocking multiple click-through pins fires onPinsChanged exactly once.
        p2.setClickThrough(true)
        XCTAssertEqual(manager.clickThroughPinCount, 2)
        var notifications = 0
        manager.onPinsChanged = { notifications += 1 }
        manager.disableClickThroughForAllPins()
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(manager.clickThroughPinCount, 0)
        XCTAssertTrue(p1.canBecomeKey)
        XCTAssertEqual(p1.lastHUDTextForTesting, "Interactive")

        // closeAllToolbars commits and closes any open annotation toolbars.
        p1.showAnnotationToolbar()
        XCTAssertTrue(p1.isToolbarVisible)
        manager.closeAllToolbars(commit: true)
        XCTAssertFalse(p1.isToolbarVisible)
    }

    func testNoOpCommitAndCloseSkipRedundantBakingAndReleaseController() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 200, height: 120) { _, _ in (80, 120, 160, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 100, y: 100, width: 100, height: 60)))
        let panel = try XCTUnwrap(manager.panels.first)

        // Opening and committing without drawing must skip baking entirely.
        panel.showAnnotationToolbar()
        panel.closeToolbar(commit: true)
        XCTAssertEqual(panel.annotationBakeCountForTesting, 0)

        // Closing panel while toolbar has unsaved strokes must not bake and must release annotationController.
        panel.showAnnotationToolbar()
        let key8 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "8", charactersIgnoringModifiers: "8", isARepeat: false, keyCode: 28
        ))
        panel.keyDown(with: key8)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: click)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 1)

        panel.close()
        XCTAssertFalse(panel.hasAnnotationControllerForTesting)
        XCTAssertEqual(panel.annotationBakeCountForTesting, 0)
        XCTAssertEqual(manager.pinCount, 0)
    }

    func testExtendedHDRColorSpaceTransformAndGPULayerRender() throws {
        // Create a 16-bit float extended sRGB CGImage (typical of macOS 26 HDR captures).
        let width = 16
        let height = 8
        let extendedSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB))
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        )
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: 0,
            space: extendedSpace,
            bitmapInfo: bitmapInfo.rawValue
        ))
        ctx.setFillColor(CGColor(colorSpace: extendedSpace, components: [0.9, 0.2, 0.1, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let hdrImage = try XCTUnwrap(ctx.makeImage())

        let rotated = PinLayout.transformedImage(hdrImage, clockwiseDegrees: 90, flipHorizontal: true, flipVertical: false)
        XCTAssertNotNil(rotated)
        XCTAssertEqual(rotated?.width, height)
        XCTAssertEqual(rotated?.height, width)

        // Opening toolbar on a rotated HDR pin flattens successfully without misaligning state.
        let panel = PinPanel(content: .image(hdrImage, scale: 1), frame: CGRect(x: 100, y: 100, width: 16, height: 8))
        defer { panel.close() }
        panel.rotateClockwise()
        panel.showAnnotationToolbar()
        XCTAssertTrue(panel.isToolbarVisible)
        XCTAssertEqual(panel.state.rotationDegrees, 0)
    }

    func testSecurityBoundsRobustnessMultiDisplayAndPinCap() {
        // PinState non-finite / overflow safety.
        var state = PinState(zoom: 2.5, opacity: 0.6, rotationDegrees: 90)
        state.multiplyZoom(by: .nan)
        state.multiplyZoom(by: .infinity)
        state.multiplyZoom(by: -2)
        state.multiplyZoom(by: 0)
        XCTAssertEqual(state.zoom, 2.5, accuracy: 0.0001)

        state.adjustOpacity(by: .nan)
        state.adjustOpacity(by: .infinity)
        XCTAssertEqual(state.opacity, 0.6, accuracy: 0.0001)

        state.rotate(byDegrees: Int.max)
        XCTAssertTrue((0..<360).contains(state.rotationDegrees))
        state.rotate(byDegrees: Int.min)
        XCTAssertTrue((0..<360).contains(state.rotationDegrees))

        // PinLayout subnormal scale, null/infinite/NaN rects, 10x huge window cap, multi-MB text cap.
        let img = makePinTestImage(width: 200, height: 100) { _, _ in (10, 20, 30, 255) }
        let subnormalBase = PinLayout.baseSize(for: .image(img, scale: 1e-300))
        XCTAssertTrue(subnormalBase.width.isFinite && subnormalBase.height.isFinite)
        XCTAssertEqual(subnormalBase.width, 200 / PinLayout.minImageScale, accuracy: 0.01)

        let nullPlaced = PinLayout.initialPlacement(
            baseSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
            screenRect: .null,
            visibleFrame: .infinite
        )
        XCTAssertTrue(PinLayout.isFiniteRect(nullPlaced.frame))
        XCTAssertGreaterThanOrEqual(nullPlaced.frame.width, 1)
        XCTAssertGreaterThanOrEqual(nullPlaced.frame.height, 1)

        let nanResized = PinLayout.resizedFrame(
            CGRect(x: 10, y: 20, width: 100, height: 50),
            to: CGSize(width: CGFloat.nan, height: -5),
            keeping: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)
        )
        XCTAssertTrue(PinLayout.isFiniteRect(nanResized))
        XCTAssertGreaterThanOrEqual(nanResized.width, 1)
        XCTAssertGreaterThanOrEqual(nanResized.height, 1)

        // 10x zoom on a 4000x2000pt pin must be capped within maxWindowDimension & maxWindowArea.
        let cappedSize = PinLayout.frameSize(baseSize: CGSize(width: 4000, height: 2000), state: PinState(zoom: 10.0))
        XCTAssertLessThanOrEqual(cappedSize.width, PinLayout.maxWindowDimension)
        XCTAssertLessThanOrEqual(cappedSize.height, PinLayout.maxWindowDimension)
        XCTAssertLessThanOrEqual(cappedSize.width * cappedSize.height, PinLayout.maxWindowArea + 10_000)
        XCTAssertEqual(cappedSize.width / cappedSize.height, 2.0, accuracy: 0.02)

        // Multi-MB clipboard text is bounded for layout/display.
        let hugeText = String(repeating: "A", count: 250_000)
        let boundedText = PinLayout.displayText(for: hugeText)
        XCTAssertEqual(boundedText.count, PinLayout.maxDisplayTextLength + 1)
        let cardSize = PinLayout.textCardSize(for: hugeText)
        XCTAssertLessThanOrEqual(cardSize.height, PinLayout.maxTextHeight + PinLayout.textPadding * 2 + 1)

        // Non-finite export scale does not trap.
        let exported = PinRenderer.exportImage(for: .text("Safe"), rotationDegrees: 0, scale: .infinity)
        XCTAssertNotNil(exported)

        // Multi-display bestScreenFrame picks largest overlap, not first intersecting.
        let screenA = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                       visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let screenB = (frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
                       visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415))
        let mostlyOnB = CGRect(x: 1430, y: 200, width: 300, height: 200)
        XCTAssertEqual(PinLayout.bestScreenFrame(for: mostlyOnB, in: [screenA, screenB]), screenB.visibleFrame)

        // Off-screen clamping rescues stranded pins while preserving on-screen pins.
        let onScreen = CGRect(x: 100, y: 100, width: 120, height: 80)
        XCTAssertEqual(PinLayout.clampedOriginToScreens(onScreen, screens: [screenA.visibleFrame]), onScreen)
        let stranded = CGRect(x: 3200, y: 500, width: 120, height: 80)
        let rescued = PinLayout.clampedOriginToScreens(stranded, screens: [screenA.visibleFrame])
        XCTAssertTrue(screenA.visibleFrame.intersection(rescued).width >= PinLayout.minVisibleMargin)

        // PinManager rejects whitespace text, enforces active pin cap, and rescues off-screen panels.
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }
        XCTAssertFalse(manager.pin(content: .text("   \n\t  "), at: nil))
        XCTAssertEqual(manager.pinCount, 0)

        XCTAssertTrue(manager.pin(content: .text("Stranded"), at: CGRect(x: 5000, y: 5000, width: 120, height: 50)))
        manager.rescueOffScreenPanels(visibleScreens: [screenA.visibleFrame])
        let rescuedOrigin = manager.panels[0].frame
        XCTAssertTrue(screenA.visibleFrame.intersection(rescuedOrigin).width >= PinLayout.minVisibleMargin)
        manager.closeAllPins()

        for i in 0..<(PinManager.maxActivePins + 5) {
            _ = manager.pin(content: .text("Pin \(i)"), at: CGRect(x: 100, y: 100, width: 80, height: 40))
        }
        XCTAssertEqual(manager.pinCount, PinManager.maxActivePins)
    }

    func testPinNextAvailableSkipsClipboardDecodeWhenHistoryTakesPriority() {
        final class CountingPasteboard: ClipboardPasteboard {
            var changeCount = 0
            var dataReadCount = 0
            var stringReadCount = 0
            var fileURLReadCount = 0
            private var pngData: Data?
            private var text: String?

            func clearContents() { pngData = nil; text = nil; changeCount += 1 }
            func writeData(_ items: [(NSPasteboard.PasteboardType, Data)]) {
                pngData = items.first(where: { $0.0 == .png })?.1
                text = nil
                changeCount += 1
            }
            func writeString(_ string: String) { text = string; pngData = nil; changeCount += 1 }
            func hasImageData() -> Bool { pngData != nil }
            func data(forType type: NSPasteboard.PasteboardType) -> Data? {
                dataReadCount += 1
                return type == .png ? pngData : nil
            }
            func string() -> String? {
                stringReadCount += 1
                return text
            }
            func readImageFileURLs() -> [URL] {
                fileURLReadCount += 1
                return []
            }
        }

        let pb = CountingPasteboard()
        let store = ClipboardStore(pasteboard: pb)
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 80, height: 60) { _, _ in (12, 34, 56, 255) }
        store.copyImage(img, scale: 2)
        // Record snip AFTER copy so `!hasClipboardChangedSinceLatestSnip`.
        let img2 = makePinTestImage(width: 80, height: 60) { _, _ in (90, 180, 240, 255) }
        _ = store.recordSnip(image: img2, scale: 2, screenRect: .zero)

        let readsBefore = pb.dataReadCount
        XCTAssertEqual(manager.pinNextAvailable(), .pinned)
        XCTAssertEqual(pb.dataReadCount, readsBefore, "Should pin unpinned history without decoding clipboard image")
    }

    func testReleaseReadinessShortcutsAccessibilityClickThroughFocusAndDarkTextContrast() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (220, 220, 220, 255) }
        let identity = PinContentIdentity.image(ImageFingerprint(image: img))
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70), contentIdentity: identity))
        let panel = try XCTUnwrap(manager.panels.first)

        // Accessibility label reflects content type & state transitions.
        XCTAssertEqual(panel.contentView?.accessibilityLabel(), "Pinned image")
        panel.setClickThrough(true)
        XCTAssertEqual(panel.contentView?.accessibilityLabel(), "Pinned image, click-through")
        XCTAssertFalse(manager.pin(content: .image(img, scale: 2), at: nil, contentIdentity: identity))
        XCTAssertEqual(panel.lastHUDTextForTesting, "Pinned · Click-Through")
        panel.setClickThrough(false)

        // Context menu exposes shortcut equivalents matching implemented keyboard handlers.
        let menu = panel.makeContextMenu()
        let rotateCW = try XCTUnwrap(menu.items.first(where: { $0.title == "Rotate 90°" }))
        XCTAssertEqual(rotateCW.keyEquivalent, "r")
        XCTAssertEqual(rotateCW.keyEquivalentModifierMask, [])
        let rotateCCW = try XCTUnwrap(menu.items.first(where: { $0.title == "Rotate 90° CCW" }))
        XCTAssertEqual(rotateCCW.keyEquivalent, "r")
        XCTAssertEqual(rotateCCW.keyEquivalentModifierMask, [.shift])
        let resetAll = try XCTUnwrap(menu.items.first(where: { $0.title == "Reset All Transforms" }))
        XCTAssertEqual(resetAll.keyEquivalent, "0")
        XCTAssertEqual(resetAll.keyEquivalentModifierMask, [.command, .shift])

        // Inline text editor uses a light backdrop when charcoal dark ink is selected.
        panel.showAnnotationToolbar()
        let key7 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "7", charactersIgnoringModifiers: "7", isARepeat: false, keyCode: 26
        ))
        panel.keyDown(with: key7)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 35), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: down)
        let editor = try XCTUnwrap(panel.inlineEditorForTesting)
        panel.toolbarViewForTesting?.onStyleChanged?(AnnotationStyle(color: .charcoal, size: .medium, mosaicMode: .pixelate))
        let bgBrightness = editor.backgroundColor?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
        XCTAssertGreaterThan(bgBrightness, 0.8)
    }

    func testLocalizationInEnglishAndSimplifiedChinese() throws {
        CCXL10n.withLanguageForTesting(.zhHans) {
            let (store, _) = makeStore()
            let manager = PinManager(clipboardStore: store)
            defer { manager.closeAllPins() }

            var copiedMessages: [String] = []
            manager.onCopied = { copiedMessages.append($0) }

            let img = makePinTestImage(width: 240, height: 140) { _, _ in (120, 180, 240, 255) }
            let entry = store.recordSnip(image: img, scale: 2, screenRect: .zero)!
            XCTAssertEqual(manager.pinTileStatus(), .ready(count: 1, primaryLabel: "图片"))

            XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70), contentIdentity: entry.pinIdentity))
            let imagePanel = manager.panels[0]
            XCTAssertEqual(imagePanel.title, "CCX 贴图")
            XCTAssertEqual(imagePanel.contentView?.accessibilityLabel(), "贴图图片")

            imagePanel.setClickThrough(true)
            XCTAssertEqual(imagePanel.lastHUDTextForTesting, "鼠标穿透")
            XCTAssertEqual(imagePanel.contentView?.accessibilityLabel(), "贴图图片，鼠标穿透")
            XCTAssertFalse(manager.pin(content: .image(img, scale: 2), at: nil, contentIdentity: entry.pinIdentity))
            XCTAssertEqual(imagePanel.lastHUDTextForTesting, "已贴图 · 鼠标穿透")

            imagePanel.setClickThrough(false)
            XCTAssertEqual(imagePanel.lastHUDTextForTesting, "已解除穿透")
            imagePanel.toggleFlipHorizontal()
            XCTAssertEqual(imagePanel.lastHUDTextForTesting, "水平翻转")
            imagePanel.toggleFlipVertical()
            XCTAssertEqual(imagePanel.lastHUDTextForTesting, "垂直翻转")
            imagePanel.setOpacity(0.8)
            XCTAssertEqual(imagePanel.lastHUDTextForTesting, "不透明度 80%")
            imagePanel.resetAllTransforms()
            XCTAssertEqual(imagePanel.lastHUDTextForTesting, "已重置")

            imagePanel.setClickThrough(true)
            let img2 = makePinTestImage(width: 160, height: 100) { _, _ in (200, 150, 100, 255) }
            XCTAssertTrue(manager.pin(content: .image(img2, scale: 2), at: CGRect(x: 260, y: 120, width: 80, height: 50)))
            let imagePanel2 = manager.panels[1]
            let imageMenu = imagePanel2.makeContextMenu()
            let imageTitles = imageMenu.items.map(\.title)
            XCTAssertEqual(imageTitles.first, "显示工具栏")
            XCTAssertTrue(imageMenu.items[1].isSeparatorItem)
            XCTAssertTrue(imageTitles.contains("拷贝"))
            XCTAssertTrue(imageTitles.contains("识别文字 (OCR)"))
            XCTAssertTrue(imageTitles.contains("保存 PNG"))
            XCTAssertTrue(imageTitles.contains("快速保存 PNG"))
            XCTAssertTrue(imageTitles.contains("创建副本"))
            XCTAssertTrue(imageTitles.contains("实际大小 (100%)"))
            XCTAssertTrue(imageTitles.contains("顺时针旋转 90°"))
            XCTAssertTrue(imageTitles.contains("逆时针旋转 90°"))
            XCTAssertTrue(imageTitles.contains("水平翻转"))
            XCTAssertTrue(imageTitles.contains("垂直翻转"))
            XCTAssertTrue(imageTitles.contains("重置全部变换"))
            XCTAssertTrue(imageTitles.contains("不透明度"))
            XCTAssertTrue(imageTitles.contains("鼠标穿透"))
            XCTAssertTrue(imageTitles.contains("缩略图模式"))
            XCTAssertTrue(imageTitles.contains("显示边框"))
            XCTAssertTrue(imageTitles.contains("显示阴影"))
            XCTAssertTrue(imageTitles.contains("关闭贴图"))
            XCTAssertTrue(imageTitles.contains("解除全部穿透 (1)"))
            XCTAssertTrue(imageTitles.contains("隐藏全部贴图"))
            XCTAssertTrue(imageTitles.contains("关闭全部贴图"))

            imagePanel2.showAnnotationToolbar()
            XCTAssertEqual(imagePanel2.makeContextMenu().items.first?.title, "收起工具栏")
            imagePanel2.closeToolbar(commit: false)

            imagePanel2.copyPin(nil)
            XCTAssertEqual(copiedMessages.last, "已拷贝到剪贴板")

            store.copyText("#FF8000")
            XCTAssertTrue(manager.pinFromClipboard())
            let colorPanel = manager.panels.last!
            let colorTitles = colorPanel.makeContextMenu().items.map(\.title)
            XCTAssertTrue(colorTitles.contains("拷贝 HEX"))
            XCTAssertTrue(colorTitles.contains("拷贝 RGB"))
            XCTAssertTrue(colorTitles.contains("拷贝 HSL"))
            colorPanel.copyHexColor(nil)
            XCTAssertEqual(copiedMessages.last, "已拷贝 #FF8000")

            store.copyText("测试文本")
            XCTAssertEqual(manager.pinTileStatus(), .ready(count: 1, primaryLabel: "文本"))
        }
    }

    func testContextMenuToolbarTriggerAtIndexZeroWithShortcutLocalizationAndThumbnailSupport() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (210, 220, 230, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70)))
        let panel = try XCTUnwrap(manager.panels.first)

        // Index 0 is "Show Toolbar" with shortcut "e" (empty modifiers) and SF symbol icon, followed by separator.
        let closedMenu = panel.makeContextMenu()
        let firstItem = try XCTUnwrap(closedMenu.items.first)
        XCTAssertEqual(firstItem.title, "Show Toolbar")
        XCTAssertEqual(firstItem.keyEquivalent, "e")
        XCTAssertEqual(firstItem.keyEquivalentModifierMask, [])
        XCTAssertNotNil(firstItem.image)
        XCTAssertTrue(closedMenu.items[1].isSeparatorItem)
        XCTAssertFalse(closedMenu.items.map(\.title).contains("Annotate"))
        XCTAssertFalse(closedMenu.items.map(\.title).contains("Done Annotating"))

        // Invoking from menu opens toolbar and flips index 0 to "Hide Toolbar".
        panel.toggleAnnotationToolbarFromMenu(nil)
        XCTAssertTrue(panel.isToolbarVisible)
        let openMenu = panel.makeContextMenu()
        let openFirst = try XCTUnwrap(openMenu.items.first)
        XCTAssertEqual(openFirst.title, "Hide Toolbar")
        XCTAssertEqual(openFirst.keyEquivalent, "e")
        XCTAssertEqual(openFirst.keyEquivalentModifierMask, [])
        XCTAssertNotNil(openFirst.image)
        XCTAssertTrue(openMenu.items[1].isSeparatorItem)

        // Invoking again from menu commits and closes toolbar.
        panel.toggleAnnotationToolbarFromMenu(nil)
        XCTAssertFalse(panel.isToolbarVisible)

        // Simplified Chinese localization at index 0 for closed and open states.
        CCXL10n.withLanguageForTesting(.zhHans) {
            let zhClosed = panel.makeContextMenu()
            XCTAssertEqual(zhClosed.items.first?.title, "显示工具栏")
            XCTAssertTrue(zhClosed.items[1].isSeparatorItem)

            panel.showAnnotationToolbar()
            let zhOpen = panel.makeContextMenu()
            XCTAssertEqual(zhOpen.items.first?.title, "收起工具栏")
            XCTAssertTrue(zhOpen.items[1].isSeparatorItem)
            panel.closeToolbar(commit: false)
        }

        // Thumbnail mode keeps "Show Toolbar" at index 0; menu toggle restores full size and opens toolbar,
        // while direct programmatic showAnnotationToolbar() stays safely guarded.
        panel.toggleThumbnail()
        XCTAssertTrue(panel.state.isThumbnail)
        panel.showAnnotationToolbar()
        XCTAssertFalse(panel.isToolbarVisible)
        XCTAssertTrue(panel.state.isThumbnail)

        let thumbMenu = panel.makeContextMenu()
        XCTAssertEqual(thumbMenu.items.first?.title, "Show Toolbar")
        XCTAssertEqual(thumbMenu.items.first?.isEnabled, true)
        panel.toggleAnnotationToolbarFromMenu(nil)
        XCTAssertFalse(panel.state.isThumbnail)
        XCTAssertTrue(panel.isToolbarVisible)
        panel.closeToolbar(commit: false)

        // Text and color pins must NOT include the toolbar item or leading separator.
        XCTAssertTrue(manager.pin(content: .text("Note"), at: CGRect(x: 300, y: 120, width: 120, height: 60)))
        let textPanel = try XCTUnwrap(manager.panels.last)
        XCTAssertEqual(textPanel.makeContextMenu().items.first?.title, "Copy")

        XCTAssertTrue(manager.pin(content: .color(CCXColorSample(red: 12, green: 34, blue: 56)), at: CGRect(x: 450, y: 120, width: 120, height: 60)))
        let colorPanel = try XCTUnwrap(manager.panels.last)
        XCTAssertEqual(colorPanel.makeContextMenu().items.first?.title, "Copy")
    }

    func testDeferredDragAndResilientDoubleClickDetection() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (225, 225, 225, 255) }
        let initialFrame = CGRect(x: 160, y: 160, width: 120, height: 70)
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: initialFrame))
        let panel = try XCTUnwrap(manager.panels.first)
        let contentView = try XCTUnwrap(panel.contentView as? PinContentView)

        var simulatedMouse = CGPoint(x: 220, y: 195)
        contentView.mouseLocationProvider = { simulatedMouse }

        // Single-click + mouseUp without dragging does NOT move the panel or open toolbar.
        let click1 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 60, y: 35), modifierFlags: [], timestamp: 10.0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let up1 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 60, y: 35), modifierFlags: [], timestamp: 10.04,
            windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        contentView.mouseDown(with: click1)
        // Tiny sub-3pt jitter before mouseUp must NOT move the panel or cancel double-click detection.
        simulatedMouse = CGPoint(x: 221.5, y: 196.0)
        let tinyJitterDrag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 61.5, y: 36), modifierFlags: [], timestamp: 10.02,
            windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 1
        ))
        contentView.mouseDragged(with: tinyJitterDrag)
        contentView.mouseUp(with: up1)
        XCTAssertEqual(panel.frame.origin, initialFrame.origin)
        XCTAssertFalse(panel.isToolbarVisible)

        // Rapid second click with clickCount == 1 and 2.2pt jitter triggers double-click fallback & opens toolbar.
        let click2 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 62, y: 36), modifierFlags: [], timestamp: 10.16,
            windowNumber: 0, context: nil, eventNumber: 4, clickCount: 1, pressure: 1
        ))
        contentView.mouseDown(with: click2)
        XCTAssertTrue(panel.isToolbarVisible)

        // A 3rd rapid click immediately afterward must NOT bounce back and close the toolbar.
        let click3 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 62, y: 36), modifierFlags: [], timestamp: 10.28,
            windowNumber: 0, context: nil, eventNumber: 5, clickCount: 1, pressure: 1
        ))
        contentView.mouseDown(with: click3)
        XCTAssertTrue(panel.isToolbarVisible)

        // A genuine subsequent double-click on empty canvas while open in .select commits & closes toolbar.
        let closeClick1 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 50, y: 30), modifierFlags: [], timestamp: 12.0,
            windowNumber: 0, context: nil, eventNumber: 6, clickCount: 1, pressure: 1
        ))
        let closeUp1 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 50, y: 30), modifierFlags: [], timestamp: 12.03,
            windowNumber: 0, context: nil, eventNumber: 7, clickCount: 1, pressure: 0
        ))
        let closeClick2 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 52, y: 31), modifierFlags: [], timestamp: 12.15,
            windowNumber: 0, context: nil, eventNumber: 8, clickCount: 1, pressure: 1
        ))
        contentView.mouseDown(with: closeClick1)
        contentView.mouseUp(with: closeUp1)
        XCTAssertTrue(panel.isToolbarVisible)
        contentView.mouseDown(with: closeClick2)
        XCTAssertFalse(panel.isToolbarVisible)

        // Synthetic zero-timestamp clicks must NEVER false-trigger double-click.
        let synthetic1 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 60, y: 35), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 9, clickCount: 1, pressure: 1
        ))
        let synthetic2 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 60, y: 35), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 10, clickCount: 1, pressure: 1
        ))
        contentView.mouseDown(with: synthetic1)
        contentView.mouseDown(with: synthetic2)
        XCTAssertFalse(panel.isToolbarVisible)

        // Two rapid real-timestamp clicks > 6pt apart must NOT trigger double-click.
        let farClick1 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 20.0,
            windowNumber: 0, context: nil, eventNumber: 11, clickCount: 1, pressure: 1
        ))
        let farClick2 = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 90, y: 50), modifierFlags: [], timestamp: 20.12,
            windowNumber: 0, context: nil, eventNumber: 12, clickCount: 1, pressure: 1
        ))
        contentView.mouseDown(with: farClick1)
        contentView.mouseDown(with: farClick2)
        XCTAssertFalse(panel.isToolbarVisible)

        // Dragging >= 3pt moves the panel cleanly and cancels double-click fallback.
        simulatedMouse = CGPoint(x: 200, y: 200)
        let dragDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 40, y: 40), modifierFlags: [], timestamp: 30.0,
            windowNumber: 0, context: nil, eventNumber: 13, clickCount: 1, pressure: 1
        ))
        contentView.mouseDown(with: dragDown)
        simulatedMouse = CGPoint(x: 225, y: 215)
        let dragMove = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 40, y: 40), modifierFlags: [], timestamp: 30.04,
            windowNumber: 0, context: nil, eventNumber: 14, clickCount: 1, pressure: 1
        ))
        contentView.mouseDragged(with: dragMove)
        let dragUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 40, y: 40), modifierFlags: [], timestamp: 30.08,
            windowNumber: 0, context: nil, eventNumber: 15, clickCount: 1, pressure: 0
        ))
        contentView.mouseUp(with: dragUp)
        XCTAssertEqual(panel.frame.origin.x, initialFrame.origin.x + 25, accuracy: 0.5)
        XCTAssertEqual(panel.frame.origin.y, initialFrame.origin.y + 15, accuracy: 0.5)

        // Explicit clickCount == 2 opens the toolbar reliably.
        let explicitDoubleClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 60, y: 35), modifierFlags: [], timestamp: 35.0,
            windowNumber: 0, context: nil, eventNumber: 16, clickCount: 2, pressure: 1
        ))
        contentView.mouseDown(with: explicitDoubleClick)
        XCTAssertTrue(panel.isToolbarVisible)
    }

    func testHoverToolbarButtonVisibilityAndClickAction() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (230, 230, 230, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70)))
        let panel = try XCTUnwrap(manager.panels.first)
        let contentView = try XCTUnwrap(panel.contentView)
        let button = try XCTUnwrap(panel.hoverToolbarButtonForTesting)

        let enterEvent = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: CGPoint(x: 60, y: 35), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil
        ))
        let exitEvent = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: CGPoint(x: -5, y: -5), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 2, trackingNumber: 1, userData: nil
        ))

        // Starts hidden so non-hovered rendering stays pure; acceptsFirstMouse for non-activating click.
        XCTAssertTrue(button.isHidden)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertEqual(button.frame.size, CGSize(width: 26, height: 26))
        XCTAssertEqual(button.frame.maxX, contentView.bounds.maxX - 8, accuracy: 0.5)
        XCTAssertEqual(button.frame.minY, 8, accuracy: 0.5)

        // Hover reveals button; exit hides it.
        contentView.mouseEntered(with: enterEvent)
        XCTAssertFalse(button.isHidden)
        contentView.mouseExited(with: exitEvent)
        XCTAssertTrue(button.isHidden)

        // Clicking the hover button opens the toolbar and hides the button.
        contentView.mouseEntered(with: enterEvent)
        XCTAssertFalse(button.isHidden)
        button.performClick(nil)
        XCTAssertTrue(panel.isToolbarVisible)
        XCTAssertTrue(button.isHidden)
        panel.closeToolbar(commit: false)

        // Collapsing to thumbnail hides hover button.
        contentView.mouseEntered(with: enterEvent)
        XCTAssertFalse(button.isHidden)
        panel.toggleThumbnail()
        XCTAssertTrue(button.isHidden)
        contentView.mouseEntered(with: enterEvent)
        XCTAssertTrue(button.isHidden)
        panel.toggleThumbnail()

        // Entering click-through hides hover button.
        contentView.mouseEntered(with: enterEvent)
        XCTAssertFalse(button.isHidden)
        panel.setClickThrough(true)
        XCTAssertTrue(button.isHidden)
        contentView.mouseEntered(with: enterEvent)
        XCTAssertTrue(button.isHidden)
        panel.setClickThrough(false)

        // Resizing below 84x52 hides hover button.
        contentView.mouseEntered(with: enterEvent)
        XCTAssertFalse(button.isHidden)
        panel.setZoom(0.5) // 60x35 < 84x52
        XCTAssertTrue(button.isHidden)

        // Tiny image pin (< 84x52) keeps hover button hidden even on mouseEntered.
        let tinyImg = makePinTestImage(width: 70, height: 44) { _, _ in (180, 180, 180, 255) }
        XCTAssertTrue(manager.pin(content: .image(tinyImg, scale: 1), at: CGRect(x: 300, y: 120, width: 70, height: 44)))
        let tinyPanel = try XCTUnwrap(manager.panels.last)
        let tinyButton = try XCTUnwrap(tinyPanel.hoverToolbarButtonForTesting)
        tinyPanel.contentView?.mouseEntered(with: enterEvent)
        XCTAssertTrue(tinyButton.isHidden)

        // Text pin keeps hover button hidden even on mouseEntered.
        XCTAssertTrue(manager.pin(content: .text("No toolbar"), at: CGRect(x: 420, y: 120, width: 140, height: 60)))
        let textPanel = try XCTUnwrap(manager.panels.last)
        let textButton = try XCTUnwrap(textPanel.hoverToolbarButtonForTesting)
        textPanel.contentView?.mouseEntered(with: enterEvent)
        XCTAssertTrue(textButton.isHidden)
    }

    func testKeyboardDirectAccessOnFocusedImagePin() throws {
        let (store, _) = makeStore()
        let manager = PinManager(clipboardStore: store)
        defer { manager.closeAllPins() }

        var ocrCount = 0
        manager.onRequestRecognizeText = { _ in ocrCount += 1 }

        let img = makePinTestImage(width: 240, height: 140) { _, _ in (240, 240, 240, 255) }
        XCTAssertTrue(manager.pin(content: .image(img, scale: 2), at: CGRect(x: 120, y: 120, width: 120, height: 70)))
        let panel = try XCTUnwrap(manager.panels.first)

        let eKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14
        ))
        let spaceKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        let tKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17
        ))
        let key1 = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        let shiftE = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "E", charactersIgnoringModifiers: "E", isARepeat: false, keyCode: 14
        ))

        // Pressing 'e' opens toolbar, pressing 'e' again commits & closes it.
        panel.keyDown(with: eKey)
        XCTAssertTrue(panel.isToolbarVisible)
        XCTAssertEqual(panel.activeAnnotationToolForTesting, .select)
        panel.keyDown(with: eKey)
        XCTAssertFalse(panel.isToolbarVisible)

        // Pressing Space opens toolbar.
        panel.keyDown(with: spaceKey)
        XCTAssertTrue(panel.isToolbarVisible)
        XCTAssertEqual(panel.activeAnnotationToolForTesting, .select)
        panel.closeToolbar(commit: false)

        // Pressing 't' triggers OCR directly without opening toolbar.
        panel.keyDown(with: tKey)
        XCTAssertEqual(ocrCount, 1)
        XCTAssertFalse(panel.isToolbarVisible)

        // Pressing '1' opens toolbar with .rectangle immediately active and ready to draw.
        panel.keyDown(with: key1)
        XCTAssertTrue(panel.isToolbarVisible)
        XCTAssertEqual(panel.activeAnnotationToolForTesting, .rectangle)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 15), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 90, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 90, y: 50), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 1
        ))
        panel.contentView?.mouseDown(with: down)
        panel.contentView?.mouseDragged(with: drag)
        panel.contentView?.mouseUp(with: up)
        XCTAssertEqual(panel.annotationDocumentForTesting?.items.count, 1)
        panel.closeToolbar(commit: false)

        // Shift+E is ignored when toolbar is closed.
        panel.keyDown(with: shiftE)
        XCTAssertFalse(panel.isToolbarVisible)

        // Thumbnail image pin ignores 'e', Space, '1', and 't'.
        panel.toggleThumbnail()
        panel.keyDown(with: eKey)
        panel.keyDown(with: spaceKey)
        panel.keyDown(with: key1)
        panel.keyDown(with: tKey)
        XCTAssertFalse(panel.isToolbarVisible)
        XCTAssertEqual(ocrCount, 1)

        // Text and color pins ignore 'e', Space, '1', and 't'.
        XCTAssertTrue(manager.pin(content: .text("Hello"), at: CGRect(x: 300, y: 120, width: 120, height: 60)))
        let textPanel = try XCTUnwrap(manager.panels.last)
        textPanel.keyDown(with: eKey)
        textPanel.keyDown(with: spaceKey)
        textPanel.keyDown(with: key1)
        textPanel.keyDown(with: tKey)
        XCTAssertFalse(textPanel.isToolbarVisible)
        XCTAssertEqual(ocrCount, 1)

        XCTAssertTrue(manager.pin(content: .color(CCXColorSample(red: 255, green: 0, blue: 0)), at: CGRect(x: 450, y: 120, width: 120, height: 60)))
        let colorPanel = try XCTUnwrap(manager.panels.last)
        colorPanel.keyDown(with: eKey)
        colorPanel.keyDown(with: spaceKey)
        colorPanel.keyDown(with: key1)
        colorPanel.keyDown(with: tKey)
        XCTAssertFalse(colorPanel.isToolbarVisible)
        XCTAssertEqual(ocrCount, 1)
    }
}
