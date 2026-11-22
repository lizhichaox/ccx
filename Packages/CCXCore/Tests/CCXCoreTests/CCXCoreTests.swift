import AppKit
import Carbon.HIToolbox
import CoreGraphics
@testable import CCXCore
import XCTest

/// Builds an RGBA8 sRGB image whose pixel at (x, y) (top-left origin) comes from `pixel`.
func makeTestImage(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
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

final class CoordinateConverterTests: XCTestCase {
    func testPrimaryScreenHeight() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(CoordinateConverter.primaryScreenHeight(screens: [external, primary]), 982)
        XCTAssertEqual(CoordinateConverter.primaryScreenHeight(screens: [external]), 1440)
        XCTAssertEqual(CoordinateConverter.primaryScreenHeight(screens: []), 0)
    }

    func testQuartzAppKitRoundTrip() {
        let quartz = CGRect(x: 100, y: 50, width: 300, height: 200)
        let appKit = CoordinateConverter.quartzToAppKit(quartz, primaryScreenHeight: 1000)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 750, width: 300, height: 200))
        XCTAssertEqual(CoordinateConverter.appKitToQuartz(appKit, primaryScreenHeight: 1000), quartz)
    }

    func testSecondaryScreenAboveAndNegativeRect() {
        // A display above the primary has negative Quartz Y and AppKit Y > primary height.
        let quartz = CGRect(x: -500, y: -1080, width: 1920, height: 1080)
        let appKit = CoordinateConverter.quartzToAppKit(quartz, primaryScreenHeight: 982)
        XCTAssertEqual(appKit, CGRect(x: -500, y: 982, width: 1920, height: 1080))
    }

    func testPointConversion() {
        let point = CoordinateConverter.appKitToQuartz(CGPoint(x: 10, y: 900), primaryScreenHeight: 1000)
        XCTAssertEqual(point, CGPoint(x: 10, y: 100))
    }

    func testLocalRectToImagePixelRectRetina() {
        // 1512x982 pt screen captured at 2x -> 3024x1964 px.
        let rect = CoordinateConverter.appKitLocalRectToImagePixelRect(
            CGRect(x: 10, y: 900, width: 100, height: 50),
            screenSize: CGSize(width: 1512, height: 982),
            imageSize: CGSize(width: 3024, height: 1964)
        )
        // Top edge in image space = (982 - 950) * 2 = 64.
        XCTAssertEqual(rect, CGRect(x: 20, y: 64, width: 200, height: 100))
    }

    func testLocalRectToImagePixelRectClampsAndRounds() {
        let rect = CoordinateConverter.appKitLocalRectToImagePixelRect(
            CGRect(x: -10, y: -10, width: 20.3, height: 20.3),
            screenSize: CGSize(width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 179, width: 21, height: 21))
        XCTAssertEqual(rect, rect.integral)

        let outside = CoordinateConverter.appKitLocalRectToImagePixelRect(
            CGRect(x: 500, y: 500, width: 10, height: 10),
            screenSize: CGSize(width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(outside, .zero)
        XCTAssertEqual(
            CoordinateConverter.appKitLocalRectToImagePixelRect(.zero, screenSize: .zero, imageSize: .zero),
            .zero
        )
    }

    func testSnapToEvenPixels() {
        let snapped = CoordinateConverter.snapToEvenPixels(CGRect(x: 10.4, y: 20.6, width: 101.7, height: 55.2))
        XCTAssertEqual(snapped, CGRect(x: 10, y: 21, width: 100, height: 54))
        XCTAssertEqual(CoordinateConverter.snapToEvenPixels(CGRect(x: 0, y: 0, width: 0.5, height: 1)).size,
                       CGSize(width: 2, height: 2))
    }
}

final class ColorSampleTests: XCTestCase {
    func testFormatCycle() {
        XCTAssertEqual(ColorFormat.hex.next, .rgb)
        XCTAssertEqual(ColorFormat.rgb.next, .hsl)
        XCTAssertEqual(ColorFormat.hsl.next, .hex)
        XCTAssertEqual(ColorFormat.allCases.map(\.displayName), ["HEX", "RGB", "HSL"])
    }

    func testStrings() {
        let color = CCXColorSample(red: 255, green: 128, blue: 0)
        XCTAssertEqual(color.hexString, "#FF8000")
        XCTAssertEqual(color.rgbString, "rgb(255, 128, 0)")
        XCTAssertEqual(color.hslString, "hsl(30, 100%, 50%)")
        XCTAssertEqual(color.formatted(as: .hex), "#FF8000")
        XCTAssertEqual(color.formatted(as: .rgb), "rgb(255, 128, 0)")
        XCTAssertEqual(color.formatted(as: .hsl), "hsl(30, 100%, 50%)")
        XCTAssertEqual(color.alpha, 255)
        XCTAssertEqual(color.colorSpaceName, "sRGB")
    }

    func testHSLEdgeCases() {
        XCTAssertEqual(CCXColorSample(red: 0, green: 0, blue: 0).hslString, "hsl(0, 0%, 0%)")
        XCTAssertEqual(CCXColorSample(red: 255, green: 255, blue: 255).hslString, "hsl(0, 0%, 100%)")
        XCTAssertEqual(CCXColorSample(red: 128, green: 128, blue: 128).hslString, "hsl(0, 0%, 50%)")
        XCTAssertEqual(CCXColorSample(red: 0, green: 0, blue: 255).hslString, "hsl(240, 100%, 50%)")
        XCTAssertEqual(CCXColorSample(red: 255, green: 0, blue: 255).hslString, "hsl(300, 100%, 50%)")
        XCTAssertEqual(CCXColorSample(red: 0, green: 255, blue: 0).hslString, "hsl(120, 100%, 50%)")
    }

    func testParseHex() {
        XCTAssertEqual(CCXColorSample.parseHex("#FF8000"), CCXColorSample(red: 255, green: 128, blue: 0))
        XCTAssertEqual(CCXColorSample.parseHex("  ff8000\n"), CCXColorSample(red: 255, green: 128, blue: 0))
        XCTAssertEqual(CCXColorSample.parseHex("0x00ff00"), CCXColorSample(red: 0, green: 255, blue: 0))
        XCTAssertEqual(CCXColorSample.parseHex("#f80"), CCXColorSample(red: 255, green: 136, blue: 0))
        XCTAssertEqual(CCXColorSample.parseHex("#11223380"),
                       CCXColorSample(red: 0x11, green: 0x22, blue: 0x33, alpha: 0x80))
        XCTAssertEqual(CCXColorSample.parseHex("#f808")?.alpha, 0x88)
        XCTAssertNil(CCXColorSample.parseHex("add"))
        XCTAssertNil(CCXColorSample.parseHex("#GG0000"))
        XCTAssertNil(CCXColorSample.parseHex("#12345"))
        XCTAssertNil(CCXColorSample.parseHex(""))
        XCTAssertNil(CCXColorSample.parseHex("#"))
        XCTAssertNil(CCXColorSample.parseHex("hello world"))
        XCTAssertNil(CCXColorSample.parseHex("#ＦＦ0000"))
    }

    func testHexRoundTrip() {
        let color = CCXColorSample(red: 18, green: 52, blue: 86)
        XCTAssertEqual(CCXColorSample.parseHex(color.hexString), color)
    }

    func testNSColor() {
        let color = CCXColorSample(red: 255, green: 0, blue: 0, alpha: 128).nsColor
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 128.0 / 255.0, accuracy: 0.001)
        let p3 = CCXColorSample(red: 0, green: 255, blue: 0, colorSpaceName: "Display P3").nsColor
        XCTAssertEqual(p3.colorSpace, .displayP3)
    }

    func testSamplePixelTopLeftOrigin() {
        let image = makeTestImage(width: 4, height: 3) { x, y in
            (UInt8(x * 60), UInt8(y * 100), 7, 255)
        }
        XCTAssertEqual(CCXColorSample.samplePixel(from: image, pixelX: 0, pixelY: 0),
                       CCXColorSample(red: 0, green: 0, blue: 7))
        XCTAssertEqual(CCXColorSample.samplePixel(from: image, pixelX: 3, pixelY: 2),
                       CCXColorSample(red: 180, green: 200, blue: 7))
        XCTAssertEqual(CCXColorSample.samplePixel(from: image, pixelX: 1, pixelY: 2),
                       CCXColorSample(red: 60, green: 200, blue: 7))
    }

    func testSamplePixelBounds() {
        let image = makeTestImage(width: 2, height: 2) { _, _ in (1, 2, 3, 255) }
        XCTAssertNil(CCXColorSample.samplePixel(from: image, pixelX: -1, pixelY: 0))
        XCTAssertNil(CCXColorSample.samplePixel(from: image, pixelX: 0, pixelY: 2))
        XCTAssertNil(CCXColorSample.samplePixel(from: image, pixelX: 2, pixelY: 0))
    }

    func testSamplePixelTranslucentIsUnpremultiplied() {
        let image = makeTestImage(width: 1, height: 1) { _, _ in (200, 100, 50, 128) }
        let sample = CCXColorSample.samplePixel(from: image, pixelX: 0, pixelY: 0)
        XCTAssertEqual(sample?.alpha, 128)
        XCTAssertEqual(Int(sample?.red ?? 0), 200, accuracy: 2)
        XCTAssertEqual(Int(sample?.green ?? 0), 100, accuracy: 2)
        XCTAssertEqual(Int(sample?.blue ?? 0), 50, accuracy: 2)
    }

    func testSamplePixelFromNonRGBAFormat() {
        // 16-bit-per-channel, BGRA-ordered (little-endian 32-bit) and grayscale sources.
        let gray = CGColorSpace(name: CGColorSpace.linearGray)!
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 16, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(CCXColorSample.samplePixel(from: ctx.makeImage()!, pixelX: 1, pixelY: 1),
                       CCXColorSample(red: 0, green: 0, blue: 255))

        let bgra = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        bgra.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        bgra.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(CCXColorSample.samplePixel(from: bgra.makeImage()!, pixelX: 0, pixelY: 0),
                       CCXColorSample(red: 255, green: 0, blue: 0))

        let grayCtx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        grayCtx.setFillColor(gray: 1, alpha: 1)
        grayCtx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(CCXColorSample.samplePixel(from: grayCtx.makeImage()!, pixelX: 0, pixelY: 0),
                       CCXColorSample(red: 255, green: 255, blue: 255))
    }
}

final class HotKeyComboTests: XCTestCase {
    func testDefaults() {
        XCTAssertEqual(HotKeyCombo.defaultSnip,
                       HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(controlKey | cmdKey)))
        XCTAssertEqual(CCXHotKeyAction.allCases.map(\.defaultCombo), [.defaultSnip])
    }

    func testDisplayString() {
        XCTAssertEqual(HotKeyCombo.defaultSnip.displayString, "⌃⌘X")
        let all = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A),
                              carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘A")
        XCTAssertEqual(HotKeyCombo(keyCode: 9999, carbonModifiers: 0).displayString, "Key 9999")
    }

    func testModifierFlagConversion() {
        let flags: NSEvent.ModifierFlags = [.command, .option]
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), modifierFlags: flags)
        XCTAssertEqual(combo.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(combo.modifierFlags, flags)
    }

    func testCodableRoundTrip() throws {
        let combo = HotKeyCombo.defaultSnip
        let decoded = try JSONDecoder().decode(HotKeyCombo.self, from: JSONEncoder().encode(combo))
        XCTAssertEqual(decoded, combo)
        let action = try JSONDecoder().decode(CCXHotKeyAction.self, from: JSONEncoder().encode(CCXHotKeyAction.snip))
        XCTAssertEqual(action, .snip)
    }

    func testCarbonIDRoundTrip() {
        for action in CCXHotKeyAction.allCases {
            XCTAssertNotEqual(action.carbonID, 0)
            XCTAssertEqual(CCXHotKeyAction(carbonID: action.carbonID), action)
        }
        XCTAssertNil(CCXHotKeyAction(carbonID: 0))
        XCTAssertNil(CCXHotKeyAction(carbonID: 99))
    }
}

@MainActor
final class GlobalHotKeyManagerTests: XCTestCase {
    func testRegisterUnregisterLifecycle() {
        let manager = GlobalHotKeyManager()
        // Use an unusual combo so it never collides with real shortcuts on the host.
        let combo = HotKeyCombo(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
        let alternate = HotKeyCombo(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
        XCTAssertNil(manager.currentCombo(for: .snip))
        guard manager.register(.snip, combo: combo) else {
            // Carbon registration can be unavailable in headless/sandboxed sessions.
            XCTAssertNil(manager.currentCombo(for: .snip))
            return
        }
        XCTAssertEqual(manager.currentCombo(for: .snip), combo)
        XCTAssertTrue(manager.register(.snip, combo: combo), "Re-registering the same combo is a no-op")
        XCTAssertTrue(manager.register(.snip, combo: alternate), "Re-binding action updates its combo")
        XCTAssertEqual(manager.currentCombo(for: .snip), alternate)

        manager.unregister(.snip)
        XCTAssertNil(manager.currentCombo(for: .snip))

        manager.registerDefaults()
        manager.unregisterAll()
        for action in CCXHotKeyAction.allCases {
            XCTAssertNil(manager.currentCombo(for: action))
        }
    }

    func testDispatchInvokesCallbackOnlyForRegisteredActions() {
        let manager = GlobalHotKeyManager()
        var received: [CCXHotKeyAction] = []
        manager.onAction = { received.append($0) }
        let combo = HotKeyCombo(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
        let registered = manager.register(.snip, combo: combo)

        // Find this manager's token by probing dispatch with every plausible token.
        for token in 1...UInt(64) {
            GlobalHotKeyManager.dispatch(token: token, carbonID: CCXHotKeyAction.snip.carbonID)
            GlobalHotKeyManager.dispatch(token: token, carbonID: 99)
        }
        XCTAssertEqual(received, registered ? [.snip] : [])
        manager.unregisterAll()
    }
}

@MainActor
final class PermissionManagerTests: XCTestCase {
    func testCurrentStatusDoesNotPrompt() {
        let status = PermissionManager.currentStatus()
        XCTAssertEqual(status, CCXPermissionStatus(screenRecording: status.screenRecording,
                                                   accessibility: status.accessibility))
        XCTAssertEqual(PermissionManager.requestAccessibility(prompt: false), status.accessibility)
    }
}

@MainActor
final class ClipboardStoreTests: XCTestCase {
    func testHistoryIsNewestFirstAndCapped() {
        let store = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard())
        let image = makeTestImage(width: 1, height: 1) { _, _ in (0, 0, 0, 255) }
        for i in 0..<5 {
            store.recordSnip(image: image, scale: 2, screenRect: CGRect(x: i, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(store.history.count, 3)
        XCTAssertEqual(store.history.map(\.screenRect.minX), [4, 3, 2])
        XCTAssertEqual(store.history.first?.scale, 2)
        XCTAssertEqual(Set(store.history.map(\.id)).count, 3)
        store.clearHistory()
        XCTAssertTrue(store.history.isEmpty)
    }

    func testDefaultHistoryCap() {
        XCTAssertEqual(ClipboardStore().maxHistoryCount, 20)
    }

    func testCopyImageRoundTripPreservesPixelsAndScale() {
        let pasteboard = InMemoryClipboardPasteboard()
        let store = ClipboardStore(pasteboard: pasteboard)
        let image = makeTestImage(width: 8, height: 4) { x, _ in (x == 0 ? 255 : 0, 10, 20, 255) }
        store.copyImage(image, scale: 2)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        guard case let .image(read, scale)? = store.readPinPayload() else {
            return XCTFail("Expected image payload")
        }
        XCTAssertEqual(read.width, 8)
        XCTAssertEqual(read.height, 4)
        XCTAssertEqual(scale, 2)
        XCTAssertEqual(CCXColorSample.samplePixel(from: read, pixelX: 0, pixelY: 0)?.red, 255)
    }

    func testReadPinPayloadPrefersHexColorThenText() {
        let pasteboard = InMemoryClipboardPasteboard()
        let store = ClipboardStore(pasteboard: pasteboard)
        store.copyText("  #00FF7f ")
        guard case let .color(color)? = store.readPinPayload() else { return XCTFail("Expected color") }
        XCTAssertEqual(color, CCXColorSample(red: 0, green: 255, blue: 127))

        store.copyText("  hello pin \n")
        guard case let .text(text)? = store.readPinPayload() else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "hello pin")

        store.copyText("   \n ")
        XCTAssertNil(store.readPinPayload())

        pasteboard.clearContents()
        XCTAssertNil(store.readPinPayload())
    }

    func testReadPinPayloadFromImageFileURL() throws {
        let pasteboard = InMemoryClipboardPasteboard()
        let store = ClipboardStore(pasteboard: pasteboard)
        let image = makeTestImage(width: 5, height: 3) { _, _ in (11, 22, 33, 255) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccx-url-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.savePNG(image, to: url)
        pasteboard.imageFileURLs = [url]

        guard case let .image(read, scale)? = store.readPinPayload() else {
            return XCTFail("Expected image payload from file URL")
        }
        XCTAssertEqual(read.width, 5)
        XCTAssertEqual(read.height, 3)
        XCTAssertEqual(scale, 1)
    }

    func testSavePNG() throws {
        let store = ClipboardStore(pasteboard: InMemoryClipboardPasteboard())
        let image = makeTestImage(width: 3, height: 2) { _, _ in (9, 8, 7, 255) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccx-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.savePNG(image, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let decoded = ClipboardStore.decode(data)
        XCTAssertEqual(decoded?.0.width, 3)
        XCTAssertEqual(decoded?.1, 1)

        let badURL = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.png")
        XCTAssertThrowsError(try store.savePNG(image, to: badURL))
    }
}
