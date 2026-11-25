import AppKit
import CCXAnnotate
import CCXCore
import CoreGraphics
import Testing
@testable import CCXCapture

@Suite("WindowCornerMaskExtractor")
@MainActor
struct WindowCornerMaskExtractorTests {
    // MARK: - Helpers

    /// Creates a synthetic isolated window `CGImage` in top-down display space with exact per-corner
    /// circular/rounded transparency and configurable interior opacity (to test translucent windows).
    private func makeWindowImage(
        widthPoints: CGFloat,
        heightPoints: CGFloat,
        scale: CGFloat = 2,
        radii: AdaptiveCornerRadii,
        interiorAlpha: CGFloat = 1.0,
        fillRGB: (CGFloat, CGFloat, CGFloat) = (0.2, 0.45, 0.85)
    ) throws -> CGImage {
        let w = Int((widthPoints * scale).rounded())
        let h = Int((heightPoints * scale).rounded())
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let fullRect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.clear(fullRect)
        ctx.setShouldAntialias(true)

        let scaledRadii = AdaptiveCornerRadii(
            topLeft: radii.topLeft * scale,
            topRight: radii.topRight * scale,
            bottomLeft: radii.bottomLeft * scale,
            bottomRight: radii.bottomRight * scale
        )
        let path = WindowCornerMaskExtractor.makeRoundedRectPath(rect: fullRect, radii: scaledRadii)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(
            colorSpace: cs,
            components: [fillRGB.0, fillRGB.1, fillRGB.2, interiorAlpha]
        )!)
        ctx.fillPath()
        return try #require(ctx.makeImage())
    }

    /// Creates an opaque solid-color `CGImage` of exact pixel dimensions.
    private func makeSolidOpaqueImage(
        pixelWidth: Int,
        pixelHeight: Int,
        rgb: (CGFloat, CGFloat, CGFloat) = (1.0, 0.0, 0.0)
    ) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [rgb.0, rgb.1, rgb.2, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return try #require(ctx.makeImage())
    }

    /// Rasterizes `image` into top-down RGBA8 bytes (`y = 0` is visual top, `y = height - 1` is visual bottom).
    private func rasterizeRGBA(_ image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let w = image.width
        let h = image.height
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: h * bpr)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: bpr,
                      space: cs,
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        try #require(ok)
        return (bytes, w, h)
    }

    private func pixel(_ rgba: (bytes: [UInt8], width: Int, height: Int), x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let idx = (y * rgba.width + x) * 4
        return (rgba.bytes[idx], rgba.bytes[idx + 1], rgba.bytes[idx + 2], rgba.bytes[idx + 3])
    }

    // MARK: - Core Mask Extraction Tests

    @Test func fullRoundedWindowMasksAllFourCornersAndForcesTranslucentInteriorOpaque() throws {
        let frame = CGRect(x: 100, y: 120, width: 320, height: 220)
        let scale: CGFloat = 2

        // 1. Standard opaque rounded window (r = 16pt)
        let opaqueWin = try makeWindowImage(
            widthPoints: frame.width,
            heightPoints: frame.height,
            scale: scale,
            radii: AdaptiveCornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16),
            interiorAlpha: 1.0
        )
        let extracted = try #require(WindowCornerMaskExtractor.extractMask(
            windowImage: opaqueWin,
            windowFrame: frame,
            selectionRect: frame,
            eligibleCorners: .all,
            outputPixelSize: (width: opaqueWin.width, height: opaqueWin.height),
            displayScale: scale
        ))
        #expect(extracted.maskedCorners == .all)
        #expect(abs(extracted.cornerRadii.topLeft - 16) <= 1.5)
        #expect(abs(extracted.cornerRadii.topRight - 16) <= 1.5)
        #expect(abs(extracted.cornerRadii.bottomLeft - 16) <= 1.5)
        #expect(abs(extracted.cornerRadii.bottomRight - 16) <= 1.5)

        let frozen = try makeSolidOpaqueImage(pixelWidth: opaqueWin.width, pixelHeight: opaqueWin.height)
        let masked = WindowCornerMaskExtractor.applyMask(extracted.maskImage, to: frozen)
        let rgba = try rasterizeRGBA(masked)
        #expect(pixel(rgba, x: 0, y: 0).a == 0)
        #expect(pixel(rgba, x: rgba.width - 1, y: 0).a == 0)
        #expect(pixel(rgba, x: 0, y: rgba.height - 1).a == 0)
        #expect(pixel(rgba, x: rgba.width - 1, y: rgba.height - 1).a == 0)
        #expect(pixel(rgba, x: rgba.width / 2, y: rgba.height / 2).a == 255)
        #expect(pixel(rgba, x: rgba.width / 2, y: rgba.height / 2).r == 255)

        // 2. 50%-translucent window (interior alpha = 128, r = 12pt) — interior MUST stay 255 WYSIWYG!
        let translucentWin = try makeWindowImage(
            widthPoints: frame.width,
            heightPoints: frame.height,
            scale: scale,
            radii: AdaptiveCornerRadii(topLeft: 12, topRight: 12, bottomLeft: 12, bottomRight: 12),
            interiorAlpha: 0.5
        )
        let translucentExtracted = try #require(WindowCornerMaskExtractor.extractMask(
            windowImage: translucentWin,
            windowFrame: frame,
            selectionRect: frame,
            eligibleCorners: .all,
            outputPixelSize: (width: translucentWin.width, height: translucentWin.height),
            displayScale: scale
        ))
        #expect(translucentExtracted.maskedCorners == .all)
        #expect(abs(translucentExtracted.cornerRadii.topLeft - 12) <= 1.5)

        let maskedTranslucent = WindowCornerMaskExtractor.applyMask(translucentExtracted.maskImage, to: frozen)
        let trRGBA = try rasterizeRGBA(maskedTranslucent)
        #expect(pixel(trRGBA, x: 0, y: 0).a == 0)
        #expect(pixel(trRGBA, x: trRGBA.width - 1, y: 0).a == 0)
        #expect(pixel(trRGBA, x: 0, y: trRGBA.height - 1).a == 0)
        #expect(pixel(trRGBA, x: trRGBA.width - 1, y: trRGBA.height - 1).a == 0)
        // Interior pixels right inside the rounded corner AND at center must remain fully opaque (255).
        #expect(pixel(trRGBA, x: 30, y: 30).a == 255)
        #expect(pixel(trRGBA, x: trRGBA.width / 2, y: trRGBA.height / 2).a == 255)
    }

    @Test func squareWindowReturnsNilMaskWithZeroFalseRounding() throws {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let squareImg = try makeSolidOpaqueImage(pixelWidth: 600, pixelHeight: 400)

        let mask = WindowCornerMaskExtractor.extractMask(
            windowImage: squareImg,
            windowFrame: frame,
            selectionRect: frame,
            eligibleCorners: .all,
            outputPixelSize: (width: 600, height: 400),
            displayScale: 2
        )
        #expect(mask == nil)

        let radii = WindowCornerMaskExtractor.extractCornerRadii(
            windowImage: squareImg,
            windowFrame: frame,
            selectionRect: frame,
            eligibleCorners: .all,
            displayScale: 2
        )
        #expect(radii == .zero)
    }

    @Test func asymmetricTopRoundedBottomSquarePreservesNonFlippedOrientation() throws {
        let frame = CGRect(x: 50, y: 80, width: 260, height: 180)
        let scale: CGFloat = 2
        let winImg = try makeWindowImage(
            widthPoints: frame.width,
            heightPoints: frame.height,
            scale: scale,
            radii: AdaptiveCornerRadii(topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0)
        )

        let extracted = try #require(WindowCornerMaskExtractor.extractMask(
            windowImage: winImg,
            windowFrame: frame,
            selectionRect: frame,
            eligibleCorners: .all,
            outputPixelSize: (width: winImg.width, height: winImg.height),
            displayScale: scale
        ))
        #expect(extracted.maskedCorners == [.topLeft, .topRight])
        #expect(abs(extracted.cornerRadii.topLeft - 20) <= 1.5)
        #expect(abs(extracted.cornerRadii.topRight - 20) <= 1.5)
        #expect(extracted.cornerRadii.bottomLeft == 0)
        #expect(extracted.cornerRadii.bottomRight == 0)

        let opaque = try makeSolidOpaqueImage(pixelWidth: winImg.width, pixelHeight: winImg.height)
        let masked = WindowCornerMaskExtractor.applyMask(extracted.maskImage, to: opaque)
        let rgba = try rasterizeRGBA(masked)
        // Row 0 = visual TOP (rounded -> transparent corners); Row h-1 = visual BOTTOM (square -> opaque).
        #expect(pixel(rgba, x: 0, y: 0).a == 0)
        #expect(pixel(rgba, x: rgba.width - 1, y: 0).a == 0)
        #expect(pixel(rgba, x: 0, y: rgba.height - 1).a == 255)
        #expect(pixel(rgba, x: rgba.width - 1, y: rgba.height - 1).a == 255)
    }

    @Test func applyMaskTopLeftOnlyClipsOnlyTopLeftCornerWithoutVerticalFlip() throws {
        let frame = CGRect(x: 0, y: 0, width: 120, height: 80)
        let scale: CGFloat = 2
        let tlOnlyWin = try makeWindowImage(
            widthPoints: frame.width,
            heightPoints: frame.height,
            scale: scale,
            radii: AdaptiveCornerRadii(topLeft: 18, topRight: 0, bottomLeft: 0, bottomRight: 0)
        )
        let extracted = try #require(WindowCornerMaskExtractor.extractMask(
            windowImage: tlOnlyWin,
            windowFrame: frame,
            selectionRect: frame,
            eligibleCorners: [.topLeft],
            outputPixelSize: (width: 240, height: 160),
            displayScale: scale
        ))
        #expect(extracted.maskedCorners == [.topLeft])

        let red = try makeSolidOpaqueImage(pixelWidth: 240, pixelHeight: 160, rgb: (1, 0, 0))
        let result = WindowCornerMaskExtractor.applyMask(extracted.maskImage, to: red)
        let rgba = try rasterizeRGBA(result)

        #expect(pixel(rgba, x: 0, y: 0).a == 0)
        #expect(pixel(rgba, x: 0, y: 0).r == 0)
        #expect(pixel(rgba, x: 239, y: 0).a == 255)
        #expect(pixel(rgba, x: 239, y: 0).r == 255)
        #expect(pixel(rgba, x: 0, y: 159).a == 255)
        #expect(pixel(rgba, x: 0, y: 159).r == 255)
        #expect(pixel(rgba, x: 239, y: 159).a == 255)
        #expect(pixel(rgba, x: 239, y: 159).r == 255)
        #expect(pixel(rgba, x: 120, y: 80).a == 255)
    }

    @Test func partialCornerAlignedCropMasksOnlyAlignedOuterCornersAndLeavesCutEdgesSquare() throws {
        let windowFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let window = DetectedWindow(windowID: 42, ownerPID: 10, ownerName: "Finder", layer: 0, frame: windowFrame)

        // Selection trims the bottom half off (AppKit maxY = 400 matches top; minY = 250 cuts interior).
        let topHalf = CGRect(x: 100, y: 250, width: 400, height: 150)
        let target = try #require(SmartElementDetector.matchingWindowCornerTarget(for: topHalf, in: [window]))
        #expect(target.window.windowID == 42)
        #expect(target.eligibleCorners == [.topLeft, .topRight])

        let winImg = try makeWindowImage(
            widthPoints: windowFrame.width,
            heightPoints: windowFrame.height,
            scale: 2,
            radii: AdaptiveCornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16)
        )
        let extracted = try #require(WindowCornerMaskExtractor.extractMask(
            windowImage: winImg,
            windowFrame: target.backingWindowFrame,
            selectionRect: topHalf,
            eligibleCorners: target.eligibleCorners,
            outputPixelSize: (width: 800, height: 300),
            displayScale: 2
        ))
        #expect(extracted.maskedCorners == [.topLeft, .topRight])
        #expect(extracted.cornerRadii.topLeft > 12)
        #expect(extracted.cornerRadii.topRight > 12)
        #expect(extracted.cornerRadii.bottomLeft == 0)
        #expect(extracted.cornerRadii.bottomRight == 0)

        let cropImg = try makeSolidOpaqueImage(pixelWidth: 800, pixelHeight: 300)
        let masked = WindowCornerMaskExtractor.applyMask(extracted.maskImage, to: cropImg)
        let rgba = try rasterizeRGBA(masked)
        #expect(pixel(rgba, x: 0, y: 0).a == 0)
        #expect(pixel(rgba, x: 799, y: 0).a == 0)
        #expect(pixel(rgba, x: 0, y: 299).a == 255)
        #expect(pixel(rgba, x: 799, y: 299).a == 255)

        // Arbitrary interior selection touches no window corner -> nil target (100% square).
        let interior = CGRect(x: 140, y: 140, width: 200, height: 150)
        #expect(SmartElementDetector.matchingWindowCornerTarget(for: interior, in: [window]) == nil)
    }

    @Test func higherZWindowOccludingCornerKeepsOccludedCornerSquareAndUnobstructedCornersRounded() throws {
        // Front window overlaps ONLY the top-right corner of the back window (AppKit maxX=500, maxY=400).
        let front = DetectedWindow(
            windowID: 101,
            ownerPID: 20,
            ownerName: "FrontApp",
            layer: 0,
            frame: CGRect(x: 450, y: 340, width: 220, height: 140)
        )
        let backFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let back = DetectedWindow(
            windowID: 102,
            ownerPID: 30,
            ownerName: "BackApp",
            layer: 0,
            frame: backFrame
        )

        let target = try #require(SmartElementDetector.matchingWindowCornerTarget(
            for: backFrame,
            in: [front, back]
        ))
        #expect(target.window.windowID == 102)
        #expect(target.eligibleCorners == [.topLeft, .bottomLeft, .bottomRight])
        #expect(!target.eligibleCorners.contains(.topRight))

        let backImg = try makeWindowImage(
            widthPoints: backFrame.width,
            heightPoints: backFrame.height,
            scale: 2,
            radii: AdaptiveCornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16)
        )
        let extracted = try #require(WindowCornerMaskExtractor.extractMask(
            windowImage: backImg,
            windowFrame: target.backingWindowFrame,
            selectionRect: backFrame,
            eligibleCorners: target.eligibleCorners,
            outputPixelSize: (width: 800, height: 600),
            displayScale: 2
        ))
        #expect(extracted.maskedCorners == [.topLeft, .bottomLeft, .bottomRight])

        let crop = try makeSolidOpaqueImage(pixelWidth: 800, pixelHeight: 600)
        let masked = WindowCornerMaskExtractor.applyMask(extracted.maskImage, to: crop)
        let rgba = try rasterizeRGBA(masked)
        #expect(pixel(rgba, x: 0, y: 0).a == 0)       // TL unobstructed -> rounded
        #expect(pixel(rgba, x: 799, y: 0).a == 255)   // TR occluded -> stays square!
        #expect(pixel(rgba, x: 0, y: 599).a == 0)     // BL unobstructed -> rounded
        #expect(pixel(rgba, x: 799, y: 599).a == 0)   // BR unobstructed -> rounded
    }

    @Test func compositeOverlayCardCropsBackingOverlaySilhouetteToCardCorners() throws {
        let overlayFrame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let cardFrame = CGRect(x: 240, y: 260, width: 320, height: 100)
        let overlayWindow = DetectedWindow(
            windowID: 777,
            ownerPID: 1127,
            ownerName: "Notification Center",
            layer: 23,
            frame: overlayFrame
        )
        let merged = SmartElementDetector.mergingOverlayCards(
            regularWindows: [],
            overlays: [OverlayWindowEntry(window: overlayWindow, zOrderIndex: 0)],
            cardsByWindowID: [777: [cardFrame]]
        )
        let target = try #require(SmartElementDetector.matchingWindowCornerTarget(
            for: cardFrame,
            in: merged.windows
        ))
        #expect(target.isCompositeOverlayCard)
        #expect(target.backingWindowFrame == overlayFrame)
        #expect(target.eligibleCorners == .all)

        // Render a transparent 600x400 overlay containing a rounded 320x100 card at `cardFrame`.
        let scale: CGFloat = 2
        let w = Int(overlayFrame.width * scale)
        let h = Int(overlayFrame.height * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let scaledCard = CGRect(
            x: cardFrame.minX * scale,
            y: cardFrame.minY * scale,
            width: cardFrame.width * scale,
            height: cardFrame.height * scale
        )
        let cardPath = WindowCornerMaskExtractor.makeRoundedRectPath(
            rect: scaledCard,
            radii: AdaptiveCornerRadii(topLeft: 18 * scale, topRight: 18 * scale, bottomLeft: 18 * scale, bottomRight: 18 * scale)
        )
        ctx.addPath(cardPath)
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.95, 0.95, 0.98, 0.92])!)
        ctx.fillPath()
        let overlaySilhouette = try #require(ctx.makeImage())

        let extracted = try #require(WindowCornerMaskExtractor.extractMask(
            windowImage: overlaySilhouette,
            windowFrame: target.backingWindowFrame,
            selectionRect: cardFrame,
            eligibleCorners: target.eligibleCorners,
            outputPixelSize: (width: Int(cardFrame.width * scale), height: Int(cardFrame.height * scale)),
            displayScale: scale
        ))
        #expect(extracted.maskedCorners == .all)
        #expect(abs(extracted.cornerRadii.topLeft - 18) <= 1.5)
    }

    @Test func resizedWindowFrameMismatchGuardReturnsNil() throws {
        let originalFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
        // Simulate window resized to 430x300 mid-snip (30pt > 1pt tolerance).
        let resizedImg = try makeWindowImage(
            widthPoints: 430,
            heightPoints: 300,
            scale: 2,
            radii: AdaptiveCornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16)
        )

        #expect(WindowCornerMaskExtractor.extractMask(
            windowImage: resizedImg,
            windowFrame: originalFrame,
            selectionRect: originalFrame,
            eligibleCorners: .all,
            outputPixelSize: (width: 800, height: 600),
            displayScale: 2
        ) == nil)

        #expect(WindowCornerMaskExtractor.extractCornerRadii(
            windowImage: resizedImg,
            windowFrame: originalFrame,
            selectionRect: originalFrame,
            eligibleCorners: .all,
            displayScale: 2
        ) == .zero)
    }

    // MARK: - Overlay Integration & Baking Tests

    @Test func makeResultAppliesAdaptiveCornerMaskWithAndWithoutAnnotations() throws {
        let screenSize = CGSize(width: 400, height: 300)
        let displayImage = try makeSolidOpaqueImage(pixelWidth: 800, pixelHeight: 600, rgb: (0.15, 0.35, 0.75))
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(origin: .zero, size: screenSize),
            backingScaleFactor: 2,
            image: displayImage
        )
        let selectionRect = CGRect(x: 40, y: 30, width: 300, height: 220)
        let win = DetectedWindow(windowID: 55, ownerPID: 1, ownerName: "Demo", layer: 0, frame: selectionRect)
        let target = try #require(SmartElementDetector.matchingWindowCornerTarget(for: selectionRect, in: [win]))
        let winImg = try makeWindowImage(
            widthPoints: selectionRect.width,
            heightPoints: selectionRect.height,
            scale: 2,
            radii: AdaptiveCornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16)
        )
        let silhouette = CapturedWindowSilhouette(image: winImg, contentSize: selectionRect.size, pointPixelScale: 2)

        // 1. Without annotations
        let plainResult = try #require(SnipOverlayController.makeResult(
            localRect: selectionRect,
            snapshot: snapshot,
            document: AnnotationDocument(),
            mosaicCache: nil,
            cornerTarget: target,
            windowSilhouette: silhouette
        ))
        let plainRGBA = try rasterizeRGBA(plainResult.image)
        #expect(pixel(plainRGBA, x: 0, y: 0).a == 0)
        #expect(pixel(plainRGBA, x: plainRGBA.width - 1, y: plainRGBA.height - 1).a == 0)
        #expect(pixel(plainRGBA, x: plainRGBA.width / 2, y: plainRGBA.height / 2).a == 255)

        // 2. With a rectangle annotation drawn right along the outer selection boundary —
        //    rounded corners MUST still be cleanly clipped after baking!
        let doc = AnnotationDocument()
        doc.commit(AnnotationItem(kind: .rectangle(selectionRect), style: AnnotationStyle(color: .red, size: .large)))
        let annotatedResult = try #require(SnipOverlayController.makeResult(
            localRect: selectionRect,
            snapshot: snapshot,
            document: doc,
            mosaicCache: nil,
            cornerTarget: target,
            windowSilhouette: silhouette
        ))
        let annRGBA = try rasterizeRGBA(annotatedResult.image)
        #expect(pixel(annRGBA, x: 0, y: 0).a == 0)
        #expect(pixel(annRGBA, x: annRGBA.width - 1, y: 0).a == 0)
        #expect(pixel(annRGBA, x: 0, y: annRGBA.height - 1).a == 0)
        #expect(pixel(annRGBA, x: annRGBA.width - 1, y: annRGBA.height - 1).a == 0)
        // Top-center edge (away from corners) still carries the red rectangle stroke.
        let topMid = pixel(annRGBA, x: annRGBA.width / 2, y: 1)
        #expect(topMid.a == 255)
        #expect(topMid.r > 200)
    }

    @Test func snipOverlayViewLiveAdaptiveCornerRadiiUpdateStaleDropAndReset() throws {
        let size = CGSize(width: 400, height: 300)
        let img = try makeSolidOpaqueImage(pixelWidth: 800, pixelHeight: 600, rgb: (0.2, 0.3, 0.4))
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(origin: .zero, size: size),
            backingScaleFactor: 2,
            image: img
        )
        let view = SnipOverlayView(snapshot: snapshot, topInset: 0)
        let winRect = CGRect(x: 40, y: 40, width: 260, height: 180)
        view.hoverRectProvider = { _ in winRect }
        var selectionCallbacks: [CGRect?] = []
        view.onSelectionChanged = { selectionCallbacks.append($0) }

        // Hovering must NEVER fire `onSelectionChanged`.
        let hoverMove = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 150, y: 150), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        view.mouseMoved(with: hoverMove)
        #expect(selectionCallbacks.isEmpty)
        #expect(view.adaptiveCornerRadii == .zero)

        // Click-to-select a detected window rect.
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        view.mouseDown(with: down)
        view.mouseUp(with: up)

        #expect(selectionCallbacks.last == winRect)
        #expect(view.adaptiveCornerRadii == .zero)

        // Stale async response for a mismatched rect is dropped.
        let radii = AdaptiveCornerRadii(topLeft: 16, topRight: 16, bottomLeft: 0, bottomRight: 0)
        view.setAdaptiveCornerRadii(radii, forLocalRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(view.adaptiveCornerRadii == .zero)

        // Matching rect updates live preview radii and shapes the border path's top corners (leaving bottom square).
        view.setAdaptiveCornerRadii(radii, forLocalRect: winRect)
        #expect(view.adaptiveCornerRadii == radii)
        let borderPath = try #require(view.borderLayerPath)
        // Just inside the top-left corner cut (outside the r=16 arc) should NOT be contained in the rounded path,
        // while just inside the square bottom-left corner SHOULD be contained.
        #expect(!borderPath.contains(CGPoint(x: winRect.minX + 2, y: winRect.maxY - 2)))
        #expect(borderPath.contains(CGPoint(x: winRect.minX + 2, y: winRect.minY + 2)))

        // Nudging selection off the window resets `adaptiveCornerRadii` back to `.zero` immediately.
        let rightArrow = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124
        ))
        view.keyDown(with: rightArrow)
        #expect(view.adaptiveCornerRadii == .zero)
        let resetPath = try #require(view.borderLayerPath)
        let nudgedRect = winRect.offsetBy(dx: 1, dy: 0)
        #expect(resetPath.contains(CGPoint(x: nudgedRect.minX + 2, y: nudgedRect.maxY - 2)))
    }

    @Test func overlayControllerLazilyPrefetchesCachesAndMasksCopyWhileSkippingOCRAndTimingOutCleanly() async throws {
        let size = CGSize(width: 400, height: 300)
        let displayImage = try makeSolidOpaqueImage(pixelWidth: 800, pixelHeight: 600, rgb: (0.2, 0.5, 0.8))
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(origin: .zero, size: size),
            backingScaleFactor: 2,
            image: displayImage
        )
        let winRect = CGRect(x: 40, y: 40, width: 260, height: 180)
        let win = DetectedWindow(windowID: 88, ownerPID: 10, ownerName: "App", layer: 0, frame: winRect)
        let winSilhouetteImg = try makeWindowImage(
            widthPoints: winRect.width,
            heightPoints: winRect.height,
            scale: 2,
            radii: AdaptiveCornerRadii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16)
        )
        let silhouette = CapturedWindowSilhouette(image: winSilhouetteImg, contentSize: winRect.size, pointPixelScale: 2)

        // 1. Lazy prefetch on selection lock (never during hover), live preview update, and cached copy export.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let fetchCounter = Counter()
        let detector = SmartElementDetector(enableAccessibility: false)
        detector.setDetectedStateForTesting(regularWindows: [win], windows: [win], fallbackOverlayWindows: [])

        var outcome: SnipOutcome?
        let controller = SnipOverlayController(
            snapshots: [snapshot],
            detector: detector,
            silhouetteProvider: { wid, _ in
                fetchCounter.increment()
                guard wid == 88 else { return nil }
                return silhouette
            },
            onFinish: { outcome = $0 }
        )
        let view = SnipOverlayView(snapshot: snapshot, topInset: 0)
        controller.attachViewForTesting(view)

        let hoverMove = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        view.mouseMoved(with: hoverMove)
        #expect(fetchCounter.count == 0)

        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        view.mouseDown(with: down)
        view.mouseUp(with: up)

        for _ in 0..<50 where view.adaptiveCornerRadii.isAllZero {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(fetchCounter.count == 1)
        #expect(abs(view.adaptiveCornerRadii.topLeft - 16) <= 1.5)

        // Commit Copy (Cmd+C) — uses cached silhouette synchronously without re-fetching.
        let cmdC = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        #expect(view.performKeyEquivalent(with: cmdC))
        #expect(fetchCounter.count == 1)
        guard case let .copy(copyResult) = outcome else {
            Issue.record("Expected .copy outcome, got \(String(describing: outcome))")
            return
        }
        let copyRGBA = try rasterizeRGBA(copyResult.image)
        #expect(pixel(copyRGBA, x: 0, y: 0).a == 0)
        #expect(pixel(copyRGBA, x: copyRGBA.width - 1, y: copyRGBA.height - 1).a == 0)
        #expect(pixel(copyRGBA, x: copyRGBA.width / 2, y: copyRGBA.height / 2).a == 255)

        // 2. OCR action skips corner masking completely (returns opaque square crop).
        let ocrCounter = Counter()
        var ocrOutcome: SnipOutcome?
        let ocrController = SnipOverlayController(
            snapshots: [snapshot],
            detector: detector,
            silhouetteProvider: { _, _ in
                ocrCounter.increment()
                try? await Task.sleep(for: .milliseconds(50))
                return silhouette
            },
            onFinish: { ocrOutcome = $0 }
        )
        let ocrView = SnipOverlayView(snapshot: snapshot, topInset: 0)
        ocrController.attachViewForTesting(ocrView)
        ocrView.mouseMoved(with: hoverMove)
        ocrView.mouseDown(with: down)
        ocrView.mouseUp(with: up)
        let keyT = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17
        ))
        ocrView.keyDown(with: keyT)
        guard case let .ocr(ocrResult) = ocrOutcome else {
            Issue.record("Expected .ocr outcome, got \(String(describing: ocrOutcome))")
            return
        }
        let ocrRGBA = try rasterizeRGBA(ocrResult.image)
        #expect(pixel(ocrRGBA, x: 0, y: 0).a == 255)

        // 3. Slow silhouette provider exceeding commit timeout falls back cleanly to square output.
        var timeoutOutcome: SnipOutcome?
        let slowController = SnipOverlayController(
            snapshots: [snapshot],
            detector: detector,
            silhouetteProvider: { _, _ in
                try? await Task.sleep(for: .seconds(2))
                return silhouette
            },
            onFinish: { timeoutOutcome = $0 }
        )
        let slowView = SnipOverlayView(snapshot: snapshot, topInset: 0)
        slowController.attachViewForTesting(slowView)
        slowView.mouseMoved(with: hoverMove)
        slowView.mouseDown(with: down)
        slowView.mouseUp(with: up)
        #expect(slowView.performKeyEquivalent(with: cmdC))
        for _ in 0..<80 where timeoutOutcome == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case let .copy(fallbackResult) = timeoutOutcome else {
            Issue.record("Expected .copy timeout fallback outcome, got \(String(describing: timeoutOutcome))")
            return
        }
        let fallbackRGBA = try rasterizeRGBA(fallbackResult.image)
        #expect(pixel(fallbackRGBA, x: 0, y: 0).a == 255)
    }
}
