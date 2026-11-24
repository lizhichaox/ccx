import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
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

    func testNonFiniteAndExtremeInputsNeverTrap() {
        let nanRect = CGRect(x: CGFloat.nan, y: 10, width: 100, height: 100)
        let infSize = CGSize(width: CGFloat.infinity, height: 100)
        let hugeRect = CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        XCTAssertEqual(CoordinateConverter.primaryScreenHeight(screens: [.null, .infinite, nanRect]), 0)
        XCTAssertEqual(CoordinateConverter.quartzToAppKit(.null, primaryScreenHeight: 1000), .zero)
        XCTAssertEqual(CoordinateConverter.quartzToAppKit(.infinite, primaryScreenHeight: 1000), .zero)
        XCTAssertEqual(CoordinateConverter.quartzToAppKit(nanRect, primaryScreenHeight: 1000), .zero)
        XCTAssertEqual(CoordinateConverter.appKitToQuartz(CGRect(x: 0, y: 0, width: 10, height: 10), primaryScreenHeight: .nan), .zero)
        XCTAssertEqual(CoordinateConverter.appKitToQuartz(CGPoint(x: CGFloat.nan, y: 10), primaryScreenHeight: 1000), .zero)
        XCTAssertEqual(CoordinateConverter.appKitToQuartz(CGPoint(x: 10, y: 10), primaryScreenHeight: .infinity), .zero)

        XCTAssertEqual(
            CoordinateConverter.appKitLocalRectToImagePixelRect(.null, screenSize: CGSize(width: 100, height: 100), imageSize: CGSize(width: 200, height: 200)),
            .zero
        )
        XCTAssertEqual(
            CoordinateConverter.appKitLocalRectToImagePixelRect(CGRect(x: 0, y: 0, width: 10, height: 10), screenSize: infSize, imageSize: CGSize(width: 200, height: 200)),
            .zero
        )
        XCTAssertEqual(
            CoordinateConverter.appKitLocalRectToImagePixelRect(CGRect(x: 0, y: 0, width: 10, height: 10), screenSize: CGSize(width: 100, height: 100), imageSize: infSize),
            .zero
        )

        for degenerate in [CGRect.null, CGRect.infinite, nanRect] {
            let snapped = CoordinateConverter.snapToEvenPixels(degenerate)
            XCTAssertEqual(snapped, CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let hugeSnapped = CoordinateConverter.snapToEvenPixels(hugeRect)
        XCTAssertTrue(hugeSnapped.width.isFinite && hugeSnapped.height.isFinite)
        XCTAssertEqual(Int(hugeSnapped.width) % 2, 0)
        XCTAssertEqual(Int(hugeSnapped.height) % 2, 0)
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

        // Multi-MB non-color text must be rejected immediately in O(1) without allocating a copy.
        let huge = String(repeating: "A", count: 2_000_000)
        XCTAssertNil(CCXColorSample.parseHex(huge))
        let hugePadded = "   " + huge + "\n"
        XCTAssertNil(CCXColorSample.parseHex(hugePadded))
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

    func testSamplePixelMatchesFastPathAndWideGamutFallback() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let p3Ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                              space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        p3Ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        p3Ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let p3Sample = CCXColorSample.samplePixel(from: p3Ctx.makeImage()!, pixelX: 1, pixelY: 1)
        XCTAssertEqual(p3Sample?.green, 255)
        XCTAssertEqual(p3Sample?.alpha, 255)

        let srgbCtx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        srgbCtx.setFillColor(CGColor(srgbRed: 12 / 255, green: 34 / 255, blue: 56 / 255, alpha: 1))
        srgbCtx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(CCXColorSample.samplePixel(from: srgbCtx.makeImage()!, pixelX: 2, pixelY: 3),
                       CCXColorSample(red: 12, green: 34, blue: 56, alpha: 255))
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
        XCTAssertEqual(HotKeyCombo(keyCode: UInt32(kVK_ANSI_Keypad0), carbonModifiers: UInt32(cmdKey)).displayString, "⌘Num 0")
        XCTAssertEqual(HotKeyCombo(keyCode: UInt32(kVK_ANSI_KeypadEnter), carbonModifiers: 0).displayString, "⌤")
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
        XCTAssertFalse(manager.isRegistered(.snip))
    }

    func testModifierMaskingAndInstanceCleanupOnDeinit() {
        let baselineCount = GlobalHotKeyManager.registeredInstanceCountForTesting()
        do {
            let manager = GlobalHotKeyManager()
            XCTAssertEqual(GlobalHotKeyManager.registeredInstanceCountForTesting(), baselineCount + 1)
            XCTAssertFalse(manager.isRegistered(.snip))
            let comboWithStrayBits = HotKeyCombo(
                keyCode: UInt32(kVK_F19),
                carbonModifiers: UInt32(controlKey | optionKey | shiftKey | alphaLock)
            )
            if manager.register(.snip, combo: comboWithStrayBits) {
                XCTAssertTrue(manager.isRegistered(.snip))
                XCTAssertEqual(manager.lastRegistrationStatus[.snip], noErr)
                XCTAssertEqual(
                    manager.currentCombo(for: .snip),
                    HotKeyCombo(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
                )
            }
            manager.unregisterAll()
            XCTAssertFalse(manager.isRegistered(.snip))
        }
        XCTAssertEqual(GlobalHotKeyManager.registeredInstanceCountForTesting(), baselineCount)
    }
}

@MainActor
final class PermissionManagerTests: XCTestCase {
    func testCurrentStatusDoesNotPrompt() {
        PermissionManager.resetScreenRecordingOverrideForTesting()
        defer { PermissionManager.resetScreenRecordingOverrideForTesting() }

        let status = PermissionManager.currentStatus()
        XCTAssertEqual(status, CCXPermissionStatus(screenRecording: status.screenRecording,
                                                   accessibility: status.accessibility,
                                                   microphone: status.microphone))
        XCTAssertEqual(PermissionManager.requestAccessibility(prompt: false), status.accessibility)
    }

    func testTriStateScreenRecordingOverrideHandlesBothGrantAndRevocation() {
        PermissionManager.resetScreenRecordingOverrideForTesting()
        defer { PermissionManager.resetScreenRecordingOverrideForTesting() }

        PermissionManager.setScreenRecordingVerified(true)
        XCTAssertTrue(PermissionManager.currentStatus().screenRecording)

        // Revocation (false) must override even if CGPreflightScreenCaptureAccess() stays stale true.
        PermissionManager.setScreenRecordingVerified(false)
        XCTAssertFalse(PermissionManager.currentStatus().screenRecording)
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

    func testTIFFCompressionAndDecodeRoundTrip() {
        let img = makeTestImage(width: 24, height: 12) { _, _ in (12, 34, 56, 255) }
        let tiffData = ClipboardStore.encode(img, type: .tiff, scale: 2)
        XCTAssertNotNil(tiffData)
        if let tiffData {
            let decoded = ClipboardStore.decode(tiffData)
            XCTAssertEqual(decoded?.0.width, 24)
            XCTAssertEqual(decoded?.0.height, 12)
            XCTAssertEqual(decoded?.1, 2)
            XCTAssertEqual(CCXColorSample.samplePixel(from: decoded!.0, pixelX: 4, pixelY: 4)?.red, 12)
        }
    }

    func testPeekPinBadgeAvoidsDecodeAndCachesByChangeCount() {
        let pb = InMemoryClipboardPasteboard()
        let store = ClipboardStore(pasteboard: pb)
        XCTAssertEqual(store.peekPinBadge(), .empty)
        CCXL10n.withLanguageForTesting(.en) {
            XCTAssertEqual(store.peekPinBadge().displayText, "Empty")
        }
        CCXL10n.withLanguageForTesting(.zhHans) {
            XCTAssertEqual(store.peekPinBadge().displayText, "空")
        }

        store.copyText("#112233")
        XCTAssertEqual(store.peekPinBadge(), .color(CCXColorSample(red: 0x11, green: 0x22, blue: 0x33)))
        XCTAssertEqual(store.peekPinBadge().displayText, "#112233")

        store.copyText("note")
        XCTAssertEqual(store.peekPinBadge(), .text)
        CCXL10n.withLanguageForTesting(.en) {
            XCTAssertEqual(store.peekPinBadge().displayText, "Text")
        }
        CCXL10n.withLanguageForTesting(.zhHans) {
            XCTAssertEqual(store.peekPinBadge().displayText, "文本")
        }

        // Undecodable placeholder bytes still classify as .image without triggering ImageIO decode.
        pb.writeData([(.png, Data([0x01, 0x02, 0x03]))])
        XCTAssertEqual(store.peekPinBadge(), .image)
        CCXL10n.withLanguageForTesting(.en) {
            XCTAssertEqual(store.peekPinBadge().displayText, "Image")
        }
        CCXL10n.withLanguageForTesting(.zhHans) {
            XCTAssertEqual(store.peekPinBadge().displayText, "图片")
        }
    }

    func testClearHistoryAndClipboardClearsHistoryImageTextFileURLAndBadge() throws {
        let pb = InMemoryClipboardPasteboard()
        let store = ClipboardStore(pasteboard: pb)
        let image = makeTestImage(width: 6, height: 4) { _, _ in (200, 100, 50, 255) }
        store.recordSnip(image: image, scale: 2, screenRect: CGRect(x: 10, y: 20, width: 3, height: 2))
        store.copyImage(image, scale: 2)

        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.peekPinBadge(), .image)
        XCTAssertNotNil(store.readPinPayload())

        store.clearHistoryAndClipboard()
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.peekPinBadge(), .empty)
        XCTAssertNil(store.readPinPayload())
        XCTAssertNil(pb.data(forType: .png))
        XCTAssertNil(pb.data(forType: .tiff))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccx-clear-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.savePNG(image, to: url)
        store.copyFileURL(url)
        XCTAssertEqual(store.peekPinBadge(), .image)
        XCTAssertNotNil(store.readPinPayload())

        store.clearClipboard()
        XCTAssertEqual(store.peekPinBadge(), .empty)
        XCTAssertNil(store.readPinPayload())
        XCTAssertTrue(pb.readImageFileURLs().isEmpty)

        store.copyText("secret")
        XCTAssertEqual(store.peekPinBadge(), .text)
        store.clearClipboard()
        XCTAssertEqual(store.peekPinBadge(), .empty)
        XCTAssertNil(store.readPinPayload())
    }

    func testImageFingerprintMatchesAcrossPNGRoundTripAndDistinguishesDifferentImages() throws {
        let pb = InMemoryClipboardPasteboard()
        let store = ClipboardStore(pasteboard: pb)
        let redStripe = makeTestImage(width: 40, height: 30) { x, _ in
            x < 20 ? (255, 40, 40, 255) : (40, 40, 255, 255)
        }
        let greenStripe = makeTestImage(width: 40, height: 30) { x, _ in
            x < 20 ? (40, 220, 80, 255) : (240, 200, 40, 255)
        }
        let differentSize = makeTestImage(width: 44, height: 30) { x, _ in
            x < 20 ? (255, 40, 40, 255) : (40, 40, 255, 255)
        }

        let fpRed = ImageFingerprint(image: redStripe)
        let fpGreen = ImageFingerprint(image: greenStripe)
        let fpDiffSize = ImageFingerprint(image: differentSize)

        let pngData = try XCTUnwrap(ClipboardStore.encode(redStripe, type: .png, scale: 2))
        let decodedRed = try XCTUnwrap(ClipboardStore.decode(pngData)).0
        let fpDecodedRed = ImageFingerprint(image: decodedRed)

        XCTAssertTrue(fpRed.matches(fpDecodedRed))
        XCTAssertFalse(fpRed.matches(fpGreen))
        XCTAssertFalse(fpRed.matches(fpDiffSize))

        let entry = store.recordSnip(image: redStripe, scale: 2, screenRect: .zero)
        XCTAssertFalse(store.hasClipboardChangedSinceLatestSnip)
        store.copyText("copied after snip")
        XCTAssertTrue(store.hasClipboardChangedSinceLatestSnip)
        store.copyImage(redStripe, scale: 2, historyEntryID: entry?.id)
        XCTAssertEqual(store.cachedClipboardIdentityIfKnown(), entry?.pinIdentity)
    }

    func testHistoryPersistsAcrossRestartsPrunesEvictedAndDeletesOnClear() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-history-persist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let img1 = makeTestImage(width: 8, height: 6) { _, _ in (220, 20, 20, 255) }
        let img2 = makeTestImage(width: 8, height: 6) { _, _ in (20, 220, 20, 255) }
        let img3 = makeTestImage(width: 8, height: 6) { _, _ in (20, 20, 220, 255) }
        let img4 = makeTestImage(width: 10, height: 8) { _, _ in (240, 200, 40, 255) }

        let store1 = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        let s1 = try XCTUnwrap(store1.recordSnip(image: img1, scale: 2, screenRect: CGRect(x: 1, y: 1, width: 4, height: 3)))
        let _ = try XCTUnwrap(store1.recordSnip(image: img2, scale: 2, screenRect: CGRect(x: 2, y: 2, width: 4, height: 3)))
        let s3 = try XCTUnwrap(store1.recordSnip(image: img3, scale: 2, screenRect: CGRect(x: 3, y: 3, width: 4, height: 3)))
        let s4 = try XCTUnwrap(store1.recordSnip(image: img4, scale: 2, screenRect: CGRect(x: 4, y: 4, width: 5, height: 4)))
        let s2ID = store1.history[2].id
        store1.flushPendingPersistence()

        let files1 = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertTrue(files1.contains("index.json"))
        let pngs1 = files1.filter { $0.hasSuffix(".png") }
        XCTAssertEqual(pngs1.count, 3)
        XCTAssertFalse(pngs1.contains("\(s1.id.uuidString).png"))

        // Reload in a fresh ClipboardStore (simulating app restart).
        let store2 = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        try await waitUntil { store2.history.count == 3 }
        XCTAssertEqual(store2.history.map(\.id), [s4.id, s3.id, s2ID])
        XCTAssertEqual(store2.history.first?.scale, 2)
        XCTAssertEqual(store2.history.first?.screenRect, CGRect(x: 4, y: 4, width: 5, height: 4))
        XCTAssertTrue(store2.history.first?.fingerprint.matches(s4.fingerprint) == true)

        // Clear removes memory + disk files + clipboard.
        store2.clearHistoryAndClipboard()
        store2.flushPendingPersistence()
        XCTAssertTrue(store2.history.isEmpty)
        let filesAfterClear = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(filesAfterClear.isEmpty)

        // Fresh restart after Clear stays empty.
        let store3 = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        store3.flushPendingPersistence()
        await Task.yield()
        XCTAssertTrue(store3.history.isEmpty)

        // Race safety: clearing immediately after launch before async load delivers must win.
        let seedStore = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        seedStore.recordSnip(image: img4, scale: 2, screenRect: .zero)
        seedStore.flushPendingPersistence()

        let store4 = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        store4.clearHistory()
        store4.flushPendingPersistence()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store4.history.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for async persistence load")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testSnipHistoryEntryThumbnailDownsamplesLargeImages() {
        let small = makeTestImage(width: 8, height: 8) { _, _ in (1, 2, 3, 255) }
        let smallEntry = SnipHistoryEntry(image: small, scale: 2, screenRect: .zero)
        XCTAssertEqual(smallEntry.thumbnail.width, 8)

        let large = makeTestImage(width: 600, height: 300) { _, _ in (1, 2, 3, 255) }
        let largeEntry = SnipHistoryEntry(image: large, scale: 2, screenRect: .zero)
        XCTAssertEqual(largeEntry.thumbnail.width, 160)
        XCTAssertEqual(largeEntry.thumbnail.height, 80)

        let tall = makeTestImage(width: 800, height: 8000) { _, y in
            y < 1000 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        let tallEntry = SnipHistoryEntry(image: tall, scale: 2, screenRect: .zero)
        XCTAssertEqual(tallEntry.thumbnail.width, 80)
        XCTAssertEqual(tallEntry.thumbnail.height, 160)
        XCTAssertGreaterThan(CCXColorSample.samplePixel(from: tallEntry.thumbnail, pixelX: 10, pixelY: 10)?.red ?? 0, 200)
    }

    func testPersistenceEnforcesPrivatePermissions0700And0600() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-perms-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        let img = makeTestImage(width: 8, height: 6) { _, _ in (120, 80, 40, 255) }
        let entry = try XCTUnwrap(store.recordSnip(image: img, scale: 2, screenRect: CGRect(x: 0, y: 0, width: 4, height: 3)))
        store.flushPendingPersistence()

        var dirStat = stat()
        XCTAssertEqual(Darwin.lstat(dir.path, &dirStat), 0)
        XCTAssertEqual(dirStat.st_mode & 0o777, 0o700)

        let pngPath = dir.appendingPathComponent("\(entry.id.uuidString).png").path
        var pngStat = stat()
        XCTAssertEqual(Darwin.lstat(pngPath, &pngStat), 0)
        XCTAssertEqual(pngStat.st_mode & 0o777, 0o600)

        let indexPath = dir.appendingPathComponent("index.json").path
        var idxStat = stat()
        XCTAssertEqual(Darwin.lstat(indexPath, &idxStat), 0)
        XCTAssertEqual(idxStat.st_mode & 0o777, 0o600)
    }

    func testPersistenceRejectsSymlinkDirectoryAndSymlinkFiles() async throws {
        let realTargetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-sym-target-\(UUID().uuidString)", isDirectory: true)
        let symlinkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-sym-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: realTargetDir, withIntermediateDirectories: true)
        let sentinel = realTargetDir.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realTargetDir)
        defer {
            try? FileManager.default.removeItem(at: symlinkDir)
            try? FileManager.default.removeItem(at: realTargetDir)
        }

        let store = ClipboardStore(maxHistoryCount: 3, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: symlinkDir)
        let img = makeTestImage(width: 4, height: 4) { _, _ in (10, 20, 30, 255) }
        store.recordSnip(image: img, scale: 1, screenRect: .zero)
        store.flushPendingPersistence()
        // Save through a symlinked directory must be refused.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realTargetDir.path), ["sentinel.txt"])

        // Clear through a symlinked directory must NOT delete files in the target directory.
        store.clearHistory()
        store.flushPendingPersistence()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testPersistenceRecoversFromCorruptJSONCorruptPNGAndNonFiniteMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Corrupt index.json self-heals and cleans orphaned PNGs.
        let orphanPNG = dir.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x00, 0x01, 0x02]).write(to: orphanPNG)
        try Data("{not valid json".utf8).write(to: dir.appendingPathComponent("index.json"))

        let store1 = ClipboardStore(maxHistoryCount: 5, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        store1.flushPendingPersistence()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store1.history.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)

        // 2. Valid PNG paired with out-of-range scale and negative-size rect sanitizes cleanly;
        //    corrupt PNG entry is skipped and pruned.
        let goodID = UUID()
        let badID = UUID()
        let goodImg = makeTestImage(width: 8, height: 8) { _, _ in (50, 100, 150, 255) }
        let goodData = try XCTUnwrap(ClipboardStore.encodePNG(goodImg, scale: 2))
        try goodData.write(to: dir.appendingPathComponent("\(goodID.uuidString).png"))
        try Data("corrupt-png".utf8).write(to: dir.appendingPathComponent("\(badID.uuidString).png"))

        let badMetaRecords = [
            SnipHistoryManifestRecord(id: goodID, timestamp: Date(), scale: -5, screenRect: CGRect(x: 0, y: 0, width: -10, height: 20)),
            SnipHistoryManifestRecord(id: badID, timestamp: Date(), scale: 2, screenRect: .zero),
        ]
        try JSONEncoder().encode(badMetaRecords).write(to: dir.appendingPathComponent("index.json"))

        let store2 = ClipboardStore(maxHistoryCount: 5, pasteboard: InMemoryClipboardPasteboard(), historyDirectoryURL: dir)
        try await waitUntil { store2.history.count == 1 }
        store2.flushPendingPersistence()
        XCTAssertEqual(store2.history.first?.id, goodID)
        XCTAssertEqual(store2.history.first?.scale, 1)
        XCTAssertEqual(store2.history.first?.screenRect, .zero)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(badID.uuidString).png").path))
    }

    func testHistoryMemoryBudgetEvictsOldestEntriesAndKeepsAtLeastOne() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-mem-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Each 100x100 RGBA image is 40,000 bytes; 90,000-byte budget fits at most 2 images.
        let img1 = makeTestImage(width: 100, height: 100) { _, _ in (255, 0, 0, 255) }
        let img2 = makeTestImage(width: 100, height: 100) { _, _ in (0, 255, 0, 255) }
        let img3 = makeTestImage(width: 100, height: 100) { _, _ in (0, 0, 255, 255) }

        let store = ClipboardStore(
            maxHistoryCount: 10,
            pasteboard: InMemoryClipboardPasteboard(),
            historyDirectoryURL: dir,
            maxHistoryMemoryBytes: 90_000
        )
        _ = store.recordSnip(image: img1, scale: 1, screenRect: .zero)
        let e2 = try XCTUnwrap(store.recordSnip(image: img2, scale: 1, screenRect: .zero))
        let e3 = try XCTUnwrap(store.recordSnip(image: img3, scale: 1, screenRect: .zero))
        XCTAssertEqual(store.history.map(\.id), [e3.id, e2.id])
        store.flushPendingPersistence()

        // Reloading with an even smaller 10,000-byte budget still retains the single newest entry.
        let tightStore = ClipboardStore(
            maxHistoryCount: 10,
            pasteboard: InMemoryClipboardPasteboard(),
            historyDirectoryURL: dir,
            maxHistoryMemoryBytes: 10_000
        )
        try await waitUntil { tightStore.history.count == 1 }
        XCTAssertEqual(tightStore.history.map(\.id), [e3.id])
    }

    func testDecodeRejectsDecompressionBombAndNonRegularFiles() throws {
        // Minimal PNG signature + IHDR declaring 50,000 x 50,000 pixels (exceeds maxDecodeDimension & maxDecodePixels).
        var fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Chunk length 13
        fakePNG.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        // Chunk type "IHDR"
        fakePNG.append(contentsOf: [0x49, 0x48, 0x44, 0x52])
        // Width = 50000 (0x0000C350), Height = 50000 (0x0000C350)
        fakePNG.append(contentsOf: [0x00, 0x00, 0xC3, 0x50, 0x00, 0x00, 0xC3, 0x50])
        // Bit depth 8, color type 6 (RGBA), compression 0, filter 0, interlace 0
        fakePNG.append(contentsOf: [0x08, 0x06, 0x00, 0x00, 0x00])
        // Placeholder CRC
        fakePNG.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(ClipboardStore.decode(fakePNG))
        XCTAssertNil(ClipboardStore.decode(Data()))

        // Directory and FIFO must be rejected immediately without blocking.
        let dirURL = FileManager.default.temporaryDirectory
        XCTAssertNil(ClipboardStore.decodeImageFile(at: dirURL))

        let fifoURL = FileManager.default.temporaryDirectory.appendingPathComponent("ccx-fifo-\(UUID().uuidString)")
        defer { _ = Darwin.unlink(fifoURL.path) }
        if Darwin.mkfifo(fifoURL.path, 0o600) == 0 {
            XCTAssertNil(ClipboardStore.decodeImageFile(at: fifoURL))
        }
    }

    func testHasPasteboardContentForNonImageFileURLsAndLocalizedErrorDescriptions() {
        let pb = InMemoryClipboardPasteboard()
        let store = ClipboardStore(pasteboard: pb)
        XCTAssertFalse(store.hasPasteboardContent)

        let mp4URL = URL(fileURLWithPath: "/tmp/recording.mp4")
        let beforeCount = pb.changeCount
        store.copyFileURL(mp4URL)
        XCTAssertEqual(pb.changeCount, beforeCount + 1)
        XCTAssertEqual(store.peekPinBadge(), .empty)
        XCTAssertTrue(store.hasPasteboardContent)

        store.clearClipboard()
        XCTAssertFalse(store.hasPasteboardContent)

        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                XCTAssertFalse((ClipboardStoreError.encodingFailed.errorDescription ?? "").isEmpty)
                XCTAssertFalse((ClipboardStoreError.writeFailed.errorDescription ?? "").isEmpty)
            }
        }
    }

    func testLazyTIFFDataProviderInvalidationPreventsSettingData() {
        let provider = LazyTIFFDataProvider {
            Data([0x49, 0x49, 0x2A, 0x00])
        }
        provider.invalidate()
        XCTAssertTrue(provider.invalidated)

        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: .tiff)
        XCTAssertNil(item.data(forType: .tiff))
    }

    func testAtomicSavePNGPreservesExistingFileOnWriteFailure() throws {
        let store = ClipboardStore(pasteboard: InMemoryClipboardPasteboard())
        let img = makeTestImage(width: 4, height: 4) { _, _ in (10, 20, 30, 255) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-atomic-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let targetURL = dir.appendingPathComponent("existing.png")
        let sentinel = Data("original-bytes".utf8)
        try sentinel.write(to: targetURL)

        // Writing to a subdirectory path that is actually a file must fail while preserving targetURL.
        let invalidSubPath = targetURL.appendingPathComponent("nested.png")
        XCTAssertThrowsError(try store.savePNG(img, to: invalidSubPath))
        XCTAssertEqual(try Data(contentsOf: targetURL), sentinel)
    }

    func testWritePNGDataAtomicallyRejectsSymlinkDestinationWithoutModifyingTarget() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccx-atomic-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let targetURL = dir.appendingPathComponent("victim.txt")
        let sentinel = Data("untouched-target-content".utf8)
        try sentinel.write(to: targetURL)

        let symlinkURL = dir.appendingPathComponent("export.png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let img = makeTestImage(width: 4, height: 4) { _, _ in (200, 100, 50, 255) }
        let pngData = try XCTUnwrap(ClipboardStore.encodePNG(img, scale: 1))

        XCTAssertThrowsError(try ClipboardStore.writePNGDataAtomically(pngData, to: symlinkURL)) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), sentinel)

        // Trailing slash on symlink path must also be inspected via lstat and rejected.
        let symlinkWithTrailingSlash = URL(fileURLWithPath: symlinkURL.path + "/", isDirectory: true)
        XCTAssertThrowsError(try ClipboardStore.writePNGDataAtomically(pngData, to: symlinkWithTrailingSlash)) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), sentinel)

        // Verify the symlink itself was not replaced by a regular file.
        var st = stat()
        XCTAssertEqual(Darwin.lstat(symlinkURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK)
    }
}

final class TextRecognizerTests: XCTestCase {
    @MainActor
    func testRecognizeTextRespectsPreCancelledTask() async {
        let image = makeTestImage(width: 16, height: 16) { _, _ in (255, 255, 255, 255) }
        let task = Task<String, Error> {
            try await TextRecognizer.recognizeText(in: image)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError for cancelled OCR task")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError, got: \(error)")
        }
    }

    @MainActor
    func testRecognizeHighContrastBannerText() async throws {
        let width = 360
        let height = 100
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 44, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        ("CCX 2026" as NSString).draw(at: CGPoint(x: 32, y: 26), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let image = ctx.makeImage()!
        let text: String
        do {
            text = try await TextRecognizer.recognizeText(in: image)
        } catch {
            if error.localizedDescription.contains("CVPixelBuffer") {
                throw XCTSkip("Vision CVPixelBuffer allocation is unavailable in sandboxed test shells")
            }
            throw error
        }
        XCTAssertTrue(text.contains("CCX"), "Expected OCR text containing CCX, got: \(text)")
    }
}
