import AppKit
import CCXCore
import CoreGraphics
import Testing
@testable import CCXAnnotate

@Suite("CCXAnnotate")
@MainActor
struct CCXAnnotateTests {
    private func samplePixel(in image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let rgba = try sampleRGBA(in: image, x: x, y: y)
        return (rgba.r, rgba.g, rgba.b)
    }

    private func sampleRGBA(in image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cropped = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setBlendMode(.copy)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (rgba[0], rgba[1], rgba[2], rgba[3])
    }

    @Test func documentUndoRedoCounterAndStyleMutations() {
        let doc = AnnotationDocument()
        #expect(doc.isEmpty)
        #expect(!doc.canUndo)
        #expect(doc.nextCounterNumber == 1)

        let rectItem = AnnotationItem(kind: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 40)), style: AnnotationStyle())
        doc.commit(rectItem)
        #expect(!doc.isEmpty)
        #expect(doc.canUndo)
        #expect(doc.selectedID == rectItem.id)

        let counter1 = AnnotationItem(kind: .counter(center: CGPoint(x: 80, y: 80), number: doc.nextCounterNumber), style: AnnotationStyle())
        doc.commit(counter1)
        #expect(doc.nextCounterNumber == 2)

        #expect(doc.updateSelectedStyle { $0.color = .blue })
        #expect(doc.selectedItem?.style.color == .blue)

        #expect(doc.undo())
        #expect(doc.selectedItem?.style.color == .red)

        #expect(doc.undo())
        #expect(doc.items.count == 1)
        #expect(doc.canRedo)

        // New edit invalidates redo stack.
        doc.commit(AnnotationItem(kind: .ellipse(CGRect(x: 30, y: 30, width: 40, height: 20)), style: AnnotationStyle()))
        #expect(!doc.canRedo)

        #expect(doc.deleteSelected())
        #expect(doc.items.count == 1)
    }

    @Test func geometryConstraintsHitTestingAndResizing() {
        let square = AnnotationItem.constrainedRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 130, y: 180), square: true)
        #expect(square == CGRect(x: 100, y: 100, width: 80, height: 80))

        let snapped = AnnotationItem.constrainedEnd(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 99, y: 3), snapAngle: true)
        #expect(abs(snapped.y) < 0.01)

        let points = AnnotationItem.appendPoint(CGPoint(x: 1, y: 1), to: [CGPoint(x: 0, y: 0)], minDistance: 2.5)
        #expect(points.count == 1)
        let extended = AnnotationItem.appendPoint(CGPoint(x: 4, y: 0), to: points, minDistance: 2.5)
        #expect(extended.count == 2)

        let rectItem = AnnotationItem(kind: .rectangle(CGRect(x: 20, y: 20, width: 100, height: 80)), style: AnnotationStyle())
        #expect(rectItem.hitTest(point: CGPoint(x: 20, y: 60)))
        #expect(!rectItem.hitTest(point: CGPoint(x: 70, y: 60)))
        #expect(rectItem.hitTestHandle(at: CGPoint(x: 120, y: 100)) == .topRight)

        let resized = rectItem.resized(handle: .topRight, to: CGPoint(x: 150, y: 120), constrain: false)
        #expect(resized.boundingBox == CGRect(x: 20, y: 20, width: 130, height: 100))

        let textItem = AnnotationItem(kind: .text(origin: CGPoint(x: 40, y: 120), content: "Hello CCX"), style: AnnotationStyle())
        let box = textItem.boundingBox
        #expect(box.minX == 40 && box.maxY == 120)
        #expect(textItem.hitTest(point: CGPoint(x: box.midX, y: box.midY)))
    }

    @Test func gpuMosaicCacheAndBakeRenderIntoRetinaImage() throws {
        // Build a 200x100px (100x50pt @ 2x) striped base image so pixelation alters the left half cleanly.
        let width = 200
        let height = 100
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        for x in stride(from: 0, to: 100, by: 4) {
            ctx.fill(CGRect(x: x, y: 0, width: 2, height: height))
        }
        let baseImage = try #require(ctx.makeImage())
        let cache = MosaicImageCache(baseImage: baseImage)
        let doc = AnnotationDocument()

        // Left mosaic region (AppKit points: 10..40 x 10..40 -> pixels 20..80) + right solid blue rectangle border.
        doc.commit(AnnotationItem(
            kind: .mosaic(CGRect(x: 10, y: 10, width: 30, height: 30), .pixelate),
            style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .pixelate)
        ))
        doc.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 60, y: 10, width: 30, height: 30)),
            style: AnnotationStyle(color: .blue, size: .large)
        ))

        let baked = try #require(AnnotationRenderer.bake(
            baseImage: baseImage,
            localSelectionRect: CGRect(x: 0, y: 0, width: 100, height: 50),
            pixelCropRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            screenSize: CGSize(width: 100, height: 50),
            document: doc,
            mosaicCache: cache
        ))
        #expect(baked.width == 200 && baked.height == 100)

        // Blue border at local point (60, 25) -> pixel x = 120, y = 50 should contain strong blue.
        let borderPixel = try samplePixel(in: baked, x: 120, y: 50)
        #expect(borderPixel.b > 200 && borderPixel.r < 40)

        // Mosaic block at pixel x = 40, y = 50 should smooth away pure white (255,255,255) & dark (26,51,77) stripes.
        let mosaicPixel = try samplePixel(in: baked, x: 40, y: 50)
        #expect(mosaicPixel.r > 40 && mosaicPixel.r < 240)

        // Untouched corner pixel x = 190, y = 10 remains original background.
        let untouched = try samplePixel(in: baked, x: 190, y: 10)
        #expect(abs(Int(untouched.r) - 26) <= 2 && abs(Int(untouched.b) - 77) <= 2)
    }

    @Test func aabbEarlyRejectsFarPointsOnPolylinesAndArrows() {
        let pen = AnnotationItem(
            kind: .pen([CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 10)]),
            style: AnnotationStyle()
        )
        #expect(pen.hitTest(point: CGPoint(x: 50, y: 10)))
        #expect(!pen.hitTest(point: CGPoint(x: 200, y: 10)))
        #expect(!pen.hitTest(point: CGPoint(x: 50, y: 50)))

        let arrow = AnnotationItem(
            kind: .arrow(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 120, y: 20)),
            style: AnnotationStyle()
        )
        #expect(arrow.hitTest(point: CGPoint(x: 120, y: 20)))
        #expect(!arrow.hitTest(point: CGPoint(x: 250, y: 20)))
    }

    @Test func eightHandleGenerationEdgeResizingBoundsConstraintAndMinimumSize() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let box = AnnotationItem(
            kind: .mosaic(CGRect(x: 40, y: 40, width: 100, height: 60), .pixelate),
            style: AnnotationStyle()
        )
        let handles = box.handlePoints
        #expect(handles.count == 8)
        #expect(handles[.top] == CGPoint(x: 90, y: 100))
        #expect(handles[.bottom] == CGPoint(x: 90, y: 40))
        #expect(handles[.left] == CGPoint(x: 40, y: 70))
        #expect(handles[.right] == CGPoint(x: 140, y: 70))

        // Tiny rects (< 16pt) omit midpoint handles to prevent overlapping corners; corners win hit-test priority.
        let tiny = AnnotationItem(kind: .rectangle(CGRect(x: 10, y: 10, width: 12, height: 12)), style: AnnotationStyle())
        #expect(tiny.handlePoints.count == 4)
        #expect(tiny.hitTestHandle(at: CGPoint(x: 16, y: 22), radius: 7) == .topLeft)

        // Single-edge resizing moves only the dragged edge while preserving perpendicular edges.
        let rightResized = box.resized(handle: .right, to: CGPoint(x: 180, y: 90), constrain: false, within: bounds)
        #expect(rightResized.boundingBox == CGRect(x: 40, y: 40, width: 140, height: 60))

        let topResized = box.resized(handle: .top, to: CGPoint(x: 10, y: 130), constrain: false, within: bounds)
        #expect(topResized.boundingBox == CGRect(x: 40, y: 40, width: 100, height: 90))

        let leftResized = box.resized(handle: .left, to: CGPoint(x: 25, y: 0), constrain: false, within: bounds)
        #expect(leftResized.boundingBox == CGRect(x: 25, y: 40, width: 115, height: 60))

        let bottomResized = box.resized(handle: .bottom, to: CGPoint(x: 0, y: 20), constrain: false, within: bounds)
        #expect(bottomResized.boundingBox == CGRect(x: 40, y: 20, width: 100, height: 80))

        // Minimum size (>= 4pt) is enforced for rectangle, ellipse, and mosaic.
        let collapsedMosaic = box.resized(handle: .topRight, to: CGPoint(x: 41, y: 41), constrain: false, within: bounds)
        #expect(collapsedMosaic.boundingBox == CGRect(x: 40, y: 40, width: 4, height: 4))

        let ellipse = AnnotationItem(kind: .ellipse(CGRect(x: 40, y: 40, width: 60, height: 40)), style: AnnotationStyle())
        let collapsedEllipse = ellipse.resized(handle: .left, to: CGPoint(x: 99, y: 50), constrain: false, within: bounds)
        #expect(collapsedEllipse.boundingBox == CGRect(x: 96, y: 40, width: 4, height: 40))

        // Square-constrained corner resize respects enclosing `bounds`.
        let rectItem = AnnotationItem(kind: .rectangle(CGRect(x: 180, y: 40, width: 80, height: 60)), style: AnnotationStyle())
        let squareClamped = rectItem.resized(handle: .topRight, to: CGPoint(x: 295, y: 195), constrain: true, within: bounds)
        #expect(bounds.contains(squareClamped.boundingBox))
        #expect(abs(squareClamped.boundingBox.width - squareClamped.boundingBox.height) < 0.01)
        #expect(squareClamped.boundingBox == CGRect(x: 180, y: 40, width: 120, height: 120))
    }

    @Test func documentSyncsMosaicModeOnSelectedStyleUpdateAndUndo() {
        let doc = AnnotationDocument()
        let mosaic = AnnotationItem(
            kind: .mosaic(CGRect(x: 10, y: 10, width: 80, height: 40), .pixelate),
            style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .pixelate)
        )
        doc.commit(mosaic)

        #expect(doc.updateSelectedStyle { $0.mosaicMode = .blur })
        guard case let .mosaic(rectAfter, modeAfter)? = doc.selectedItem?.kind else {
            Issue.record("Expected mosaic item after style update")
            return
        }
        #expect(rectAfter == CGRect(x: 10, y: 10, width: 80, height: 40))
        #expect(modeAfter == .blur)
        #expect(doc.selectedItem?.style.mosaicMode == .blur)

        #expect(doc.undo())
        guard case let .mosaic(_, modeUndone)? = doc.selectedItem?.kind else {
            Issue.record("Expected mosaic item after undo")
            return
        }
        #expect(modeUndone == .pixelate)
        #expect(doc.selectedItem?.style.mosaicMode == .pixelate)
    }

    @Test func areaAveragedMosaicAltersThinDarkStrokesOnWhiteAndBlurWorksAcrossPresets() throws {
        // White background with thin 2px dark vertical strokes spaced 16px apart (where naive
        // point-sampled pixellate often hits pure white and erases text strokes).
        let width = 160
        let height = 80
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1)
        for x in stride(from: 6, to: width, by: 16) {
            ctx.fill(CGRect(x: x, y: 10, width: 2, height: height - 20))
        }
        let baseImage = try #require(ctx.makeImage())
        let cache = MosaicImageCache(baseImage: baseImage)

        // Check white-gap pixel x = 14, y = 40 -> area-averaged mosaic must darken pure white (255 -> < 245).
        let pixelated = try #require(cache.filteredImage(mode: .pixelate, size: .medium, backingScale: 2))
        #expect(pixelated.width == width && pixelated.height == height)
        var nonWhiteCount = 0
        for x in stride(from: 20, to: 140, by: 4) {
            let p = try samplePixel(in: pixelated, x: x, y: 40)
            if p.r < 248 { nonWhiteCount += 1 }
        }
        #expect(nonWhiteCount >= 20)

        for size in StrokeSize.presets {
            let blurred = try #require(cache.filteredImage(mode: .blur, size: size, backingScale: 2))
            #expect(blurred.width == width && blurred.height == height)
            let onStroke = try samplePixel(in: blurred, x: 22, y: 40)
            #expect(onStroke.r > 40 && onStroke.r < 252)
        }
    }

    @Test func strokeSizeContinuousRangePresetsClampingAndRoundTrip() {
        #expect(StrokeSize.small.lineWidth == 2.5)
        #expect(StrokeSize.medium.lineWidth == 4.0)
        #expect(StrokeSize.large.lineWidth == 6.5)
        #expect(StrokeSize.minimum.lineWidth == 1.5)
        #expect(StrokeSize.maximum.lineWidth == 12.0)

        #expect(StrokeSize(progress: -0.5) == .minimum)
        #expect(StrokeSize(progress: 1.8) == .maximum)
        #expect(StrokeSize(progress: .nan) == .medium)
        #expect(StrokeSize.minimum.adjusted(byProgressDelta: -0.2) == .minimum)
        #expect(StrokeSize.maximum.adjusted(byProgressDelta: 0.2) == .maximum)

        #expect(StrokeSize(lineWidth: 1.5) == .minimum)
        #expect(StrokeSize(lineWidth: 12.0) == .maximum)
        #expect(abs(StrokeSize(lineWidth: 6.5).lineWidth - 6.5) < 0.05)

        #expect(StrokeSize.minimum.formattedLineWidth == "1.5")
        #expect(StrokeSize.small.formattedLineWidth == "2.5")
        #expect(StrokeSize.medium.formattedLineWidth == "4")
        #expect(StrokeSize.maximum.formattedLineWidth == "12")

        var prevLine = StrokeSize.minimum.lineWidth
        var prevHighlight = StrokeSize.minimum.highlighterWidth
        var prevFont = StrokeSize.minimum.fontSize
        var prevCounter = StrokeSize.minimum.counterDiameter
        var prevMosaic = StrokeSize.minimum.mosaicBlockSize
        var prevBlur = StrokeSize.minimum.blurRadius

        for step in stride(from: 0.0, through: 1.0, by: 0.02) {
            let size = StrokeSize(progress: step)
            #expect(size.lineWidth >= prevLine)
            #expect(size.highlighterWidth >= prevHighlight)
            #expect(size.fontSize >= prevFont)
            #expect(size.counterDiameter >= prevCounter)
            #expect(size.mosaicBlockSize >= prevMosaic)
            #expect(size.blurRadius >= prevBlur)
            prevLine = size.lineWidth
            prevHighlight = size.highlighterWidth
            prevFont = size.fontSize
            prevCounter = size.counterDiameter
            prevMosaic = size.mosaicBlockSize
            prevBlur = size.blurRadius
        }
    }

    @Test func documentCoalescesStyleMutationsWhenRecordUndoFalse() {
        let doc = AnnotationDocument()
        let rect = AnnotationItem(
            kind: .rectangle(CGRect(x: 10, y: 10, width: 80, height: 50)),
            style: AnnotationStyle(color: .red, size: .medium)
        )
        doc.commit(rect)

        #expect(doc.updateSelectedStyle(recordUndo: true) { $0.size = .large })
        #expect(doc.updateSelectedStyle(recordUndo: false) { $0.size = StrokeSize(progress: 0.8) })
        #expect(doc.updateSelectedStyle(recordUndo: false) { $0.size = .maximum })
        #expect(doc.selectedItem?.style.size == .maximum)

        #expect(doc.undo())
        #expect(doc.selectedItem?.style.size == .medium)

        #expect(doc.redo())
        #expect(doc.selectedItem?.style.size == .maximum)
    }

    @Test func mosaicCacheBoundedLRUEvictionAcrossStrokeSizes() throws {
        let ctx = try #require(CGContext(
            data: nil,
            width: 80,
            height: 60,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        ctx.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 10, y: 10, width: 6, height: 40))
        let baseImage = try #require(ctx.makeImage())
        let cache = MosaicImageCache(baseImage: baseImage)

        for size in [StrokeSize.minimum, .small, .medium, .large, .maximum] {
            #expect(cache.filteredImage(mode: .pixelate, size: size, backingScale: 2) != nil)
            #expect(cache.filteredImage(mode: .blur, size: size, backingScale: 2) != nil)
        }

        // Sweep distinct mosaic strengths to exercise cached base rasterization reuse and bounded LRU (cap 4).
        for i in 0...12 {
            let size = StrokeSize(progress: CGFloat(i) / 12.0)
            #expect(cache.filteredImage(mode: .pixelate, size: size, backingScale: 2) != nil)
            #expect(cache.filteredImage(mode: .blur, size: size, backingScale: 2) != nil)
        }
        #expect(cache.baseRasterizationCount == 1)
        #expect(cache.cachedVariantCount <= 4)
    }

    @Test func sharedToolbarPresetsSizeHUDLabelsAndDocumentReplaceAll() {
        for preset in [AnnotationToolbarPreset.snip, .pin] {
            let toolbar = AnnotationActionToolbar(preset: preset)
            toolbar.layoutSubtreeIfNeeded()
            let bounds = toolbar.primarySurfaceBounds
            let frames = toolbar.primaryControlFrames
            #expect(!frames.isEmpty)
            #expect(bounds.height == AnnotationActionToolbar.primaryHeight)
            #expect(bounds.width == AnnotationActionToolbar.preferredSize(for: preset).width)
            for frame in frames {
                #expect(frame.width > 0 && frame.height > 0)
                #expect(frame.minX >= -0.5 && frame.maxX <= bounds.width + 0.5)
                #expect(frame.minY >= -0.5 && frame.maxY <= bounds.height + 0.5)
            }
            for pair in zip(frames, frames.dropFirst()) {
                #expect(pair.0.maxX <= pair.1.minX + 0.5)
            }
        }

        CCXL10n.withLanguageForTesting(.en) {
            #expect(AnnotationTool.pen.formattedSizeHUDLabel(for: .medium, mosaicMode: .pixelate) == "4 pt")
            #expect(AnnotationTool.counter.formattedSizeHUDLabel(for: .minimum, mosaicMode: .pixelate) == "18 px")
            #expect(AnnotationTool.mosaic.formattedSizeHUDLabel(for: .medium, mosaicMode: .pixelate) == "Mosaic 10")
            #expect(AnnotationTool.mosaic.formattedSizeHUDLabel(for: .medium, mosaicMode: .blur) == "Blur 16")
        }

        let doc = AnnotationDocument()
        let first = AnnotationItem(kind: .rectangle(CGRect(x: 10, y: 10, width: 30, height: 20)), style: AnnotationStyle())
        let second = AnnotationItem(kind: .ellipse(CGRect(x: 40, y: 40, width: 20, height: 20)), style: AnnotationStyle())
        doc.commit(first)
        doc.commit(second)
        #expect(doc.canUndo)
        doc.replaceAll(items: [first], selectedID: first.id)
        #expect(doc.items == [first])
        #expect(doc.selectedID == first.id)
        #expect(!doc.canUndo)
        #expect(!doc.canRedo)
    }

    @Test func bakeHandlesExtendedRGBColorSpaceFractionalAlignmentOpaqueFallbackAndTinyRoundedRect() throws {
        // 1. Extended-range linear sRGB (16-bit float, HDR-style) must still bake annotations & mosaic redactions
        //    rather than silently returning the unredacted base image.
        let extendedCS = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let hdrCtx = try #require(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 32,
            bytesPerRow: 0,
            space: extendedCS,
            bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        hdrCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        hdrCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let hdrBase = try #require(hdrCtx.makeImage())

        let doc = AnnotationDocument()
        // Tiny 2x2 rectangle (< 4pt) must not assert/fail in CGPath(roundedRect:).
        doc.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 4, y: 4, width: 2, height: 2)),
            style: AnnotationStyle(color: .red, size: .small)
        ))
        // Mosaic item baked WITHOUT a mosaicCache must render an opaque dark fallback (never leaking white beneath).
        doc.commit(AnnotationItem(
            kind: .mosaic(CGRect(x: 20, y: 10, width: 40, height: 30), .pixelate),
            style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .pixelate)
        ))
        // Multi-digit step counter (123) must also render cleanly.
        doc.commit(AnnotationItem(
            kind: .counter(center: CGPoint(x: 80, y: 25), number: 123),
            style: AnnotationStyle(color: .blue, size: .medium)
        ))

        let bakedFallback = try #require(AnnotationRenderer.bake(
            baseImage: hdrBase,
            localSelectionRect: CGRect(x: 0, y: 0, width: 100, height: 50),
            pixelCropRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            screenSize: CGSize(width: 100, height: 50),
            document: doc,
            mosaicCache: nil
        ))
        // Pixel inside mosaic box (point (40, 25) -> pixel (80, 50)) must be dark opaque fallback (~46, not bleached > 100).
        let fallbackPx = try samplePixel(in: bakedFallback, x: 80, y: 50)
        #expect(fallbackPx.r < 70 && fallbackPx.g < 70 && fallbackPx.b < 75)

        // MosaicImageCache must also succeed on extended-range RGB images.
        let hdrCache = MosaicImageCache(baseImage: hdrBase)
        #expect(hdrCache.filteredImage(mode: .pixelate, size: .medium, backingScale: 2) != nil)
        #expect(hdrCache.filteredImage(mode: .blur, size: .medium, backingScale: 2) != nil)

        // 2. Clamped/out-of-bounds localSelectionRect aligns baked stroke to clamped pixelCropRect origin.
        let srgbCtx = try #require(CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        srgbCtx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        srgbCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let srgbBase = try #require(srgbCtx.makeImage())

        let alignDoc = AnnotationDocument()
        // Solid green box at x = 10..20, y = 10..20 (points) -> pixels x = 20..40, cgY = 20..40 (top-down y = 60..80).
        alignDoc.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 10, y: 10, width: 10, height: 10)),
            style: AnnotationStyle(color: .green, size: .large)
        ))
        // Pretend localSelectionRect extended to (-10, -5), while pixelCropRect was clamped to x=0, y=50, w=60, h=50.
        let alignedBaked = try #require(AnnotationRenderer.bake(
            baseImage: srgbBase,
            localSelectionRect: CGRect(x: -10, y: -5, width: 40, height: 30),
            pixelCropRect: CGRect(x: 0, y: 50, width: 60, height: 50),
            screenSize: CGSize(width: 100, height: 50),
            document: alignDoc,
            mosaicCache: nil
        ))
        // Left border of rectangle at point x=10, y=15 -> cropped pixel x=20, top-down y=20 (since crop starts at top-down y=50).
        let greenPx = try samplePixel(in: alignedBaked, x: 20, y: 20)
        #expect(greenPx.g > 150)
    }

    @Test func mosaicCacheScaleAwarenessByteBudgetAndClear() throws {
        let ctx = try #require(CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        for x in stride(from: 0, to: 100, by: 8) {
            ctx.fill(CGRect(x: x, y: 0, width: 4, height: 100))
        }
        let baseImage = try #require(ctx.makeImage())

        // Each 100x100 RGBA image is 40,000 bytes; setting budget to 50,000 caps cache to 1 variant.
        let budgeted = MosaicImageCache(baseImage: baseImage, maxCachedBytes: 50_000)
        let img1x = try #require(budgeted.filteredImage(mode: .pixelate, size: .medium, backingScale: 1))
        #expect(budgeted.cachedVariantCount == 1)
        let img2x = try #require(budgeted.filteredImage(mode: .pixelate, size: .medium, backingScale: 2))
        // Distinct scale produces a distinct entry and evicts 1x due to byte budget.
        #expect(img1x !== img2x)
        #expect(budgeted.cachedVariantCount == 1)
        #expect(budgeted.cachedByteCount <= 50_000)

        budgeted.clear()
        #expect(budgeted.cachedVariantCount == 0)
        #expect(budgeted.cachedByteCount == 0)
    }

    @Test func boundedGeometryTextWrappingNoOpReplaceAndToolbarPolish() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 150)

        // Bounded square drawing stays inside bounds even when cursor pulls past an edge.
        let boundedSquare = AnnotationItem.constrainedRect(
            from: CGPoint(x: 160, y: 120),
            to: CGPoint(x: 10, y: 145),
            square: true,
            within: bounds
        )
        #expect(bounds.contains(boundedSquare))
        #expect(abs(boundedSquare.width - boundedSquare.height) < 0.01)
        #expect(boundedSquare.width == 30)

        // Shift-snapped arrow endpoint resizing stays inside bounds.
        let arrow = AnnotationItem(
            kind: .arrow(start: CGPoint(x: 100, y: 130), end: CGPoint(x: 150, y: 130)),
            style: AnnotationStyle()
        )
        let resizedArrow = arrow.resized(handle: .end, to: CGPoint(x: 195, y: 148), constrain: true, within: bounds)
        if case let .arrow(_, end) = resizedArrow.kind {
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(end))
        } else {
            Issue.record("Expected arrow item")
        }

        // Non-finite inputs are ignored cleanly without NaN propagation.
        #expect(!arrow.hitTest(point: CGPoint(x: CGFloat.nan, y: 10)))
        #expect(arrow.hitTestHandle(at: CGPoint(x: CGFloat.infinity, y: 10)) == nil)
        #expect(arrow.translated(by: CGSize(width: CGFloat.nan, height: 5)) == arrow)
        #expect(arrow.resized(handle: .end, to: CGPoint(x: CGFloat.nan, y: 0), constrain: false, within: bounds) == arrow)

        // Text wrapping width & trailing newline height.
        let origin = CGPoint(x: 10, y: 200)
        let oneLine = AnnotationItem.textBoundingBox(origin: origin, content: "Hello world from CCX", fontSize: 18, maxWidth: 640)
        let wrapped = AnnotationItem.textBoundingBox(origin: origin, content: "Hello world from CCX", fontSize: 18, maxWidth: 80)
        #expect(wrapped.height > oneLine.height)
        let withTrailingNewline = AnnotationItem.textBoundingBox(origin: origin, content: "Line 1\n", fontSize: 18, maxWidth: 640)
        let withoutTrailingNewline = AnnotationItem.textBoundingBox(origin: origin, content: "Line 1", fontSize: 18, maxWidth: 640)
        #expect(withTrailingNewline.height > withoutTrailingNewline.height)

        // No-op replaceItem does not push a phantom undo snapshot.
        let doc = AnnotationDocument()
        let item = AnnotationItem(kind: .text(origin: origin, content: "Same"), style: AnnotationStyle())
        doc.commit(item)
        #expect(doc.replaceItem(item, recordUndo: true))
        #expect(doc.undo())
        #expect(doc.items.isEmpty) // Single undo reverted commit directly (no phantom snapshot).

        // Toolbar tooltip adapts to active tool & cancelDragging resets drag cleanly.
        CCXL10n.withLanguageForTesting(.en) {
            let toolbar = AnnotationActionToolbar(preset: .snip)
            toolbar.update(
                activeTool: .mosaic,
                style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .blur),
                showStyleBar: true,
                canUndo: false,
                canRedo: false
            )
            #expect(toolbar.sizeSliderToolTip?.hasPrefix("Blur ") == true)
            toolbar.update(
                activeTool: .counter,
                style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .pixelate),
                showStyleBar: true,
                canUndo: false,
                canRedo: false
            )
            #expect(toolbar.sizeSliderToolTip?.contains("px") == true)
            toolbar.cancelDragging()
            #expect(!toolbar.isDragging)
        }
    }

    @Test func localizedToolNamesHUDLabelsAndToolbarLayoutInBothLanguages() {
        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                for preset in [AnnotationToolbarPreset.snip, .pin] {
                    let toolbar = AnnotationActionToolbar(preset: preset)
                    toolbar.update(
                        activeTool: .mosaic,
                        style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .pixelate),
                        showStyleBar: true,
                        canUndo: true,
                        canRedo: true
                    )
                    toolbar.layoutSubtreeIfNeeded()
                    let bounds = toolbar.primarySurfaceBounds
                    let frames = toolbar.primaryControlFrames
                    #expect(!frames.isEmpty)
                    for frame in frames {
                        #expect(frame.minX >= -0.5 && frame.maxX <= bounds.width + 0.5)
                        #expect(frame.minY >= -0.5 && frame.maxY <= bounds.height + 0.5)
                    }
                    for pair in zip(frames, frames.dropFirst()) {
                        #expect(pair.0.maxX <= pair.1.minX + 0.5)
                    }
                }

                // Mode pills fit comfortably inside their 56pt fixed pill button width in both languages.
                let pillFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
                for mode in MosaicMode.allCases {
                    let measured = (mode.label as NSString).size(withAttributes: [.font: pillFont]).width
                    #expect(measured <= 48)
                }

                // All tool display names are non-empty and single-line.
                for tool in AnnotationTool.allCases {
                    #expect(!tool.displayName.isEmpty)
                    #expect(!tool.displayName.contains("\n"))
                }
            }
        }

        CCXL10n.withLanguageForTesting(.zhHans) {
            #expect(AnnotationTool.select.displayName == "选择 / 移动")
            #expect(AnnotationTool.rectangle.displayName == "矩形")
            #expect(AnnotationTool.ellipse.displayName == "椭圆")
            #expect(AnnotationTool.arrow.displayName == "箭头")
            #expect(AnnotationTool.pen.displayName == "画笔")
            #expect(AnnotationTool.highlighter.displayName == "荧光笔")
            #expect(AnnotationTool.mosaic.displayName == "马赛克 / 模糊")
            #expect(AnnotationTool.text.displayName == "文字")
            #expect(AnnotationTool.counter.displayName == "序号")
            #expect(MosaicMode.pixelate.label == "马赛克")
            #expect(MosaicMode.blur.label == "模糊")
            #expect(AnnotationTool.mosaic.formattedSizeHUDLabel(for: .medium, mosaicMode: .pixelate) == "马赛克 10")
            #expect(AnnotationTool.mosaic.formattedSizeHUDLabel(for: .medium, mosaicMode: .blur) == "模糊 16")

            let toolbar = AnnotationActionToolbar(preset: .snip)
            toolbar.update(
                activeTool: .mosaic,
                style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .blur),
                showStyleBar: true,
                canUndo: false,
                canRedo: false
            )
            #expect(toolbar.sizeSliderToolTip?.hasPrefix("模糊 ") == true)
            #expect(toolbar.dragHandleView.toolTip?.contains("拖动移动工具栏") == true)
        }
    }

    @Test func toolbarSavePrecedesCopyInSnipAndPinPresets() throws {
        let expectations: [(preset: AnnotationToolbarPreset, saveTooltip: String, actions: [AnnotationToolbarAction])] = [
            (.snip, "Save (⌘S)", [.undo, .redo, .scroll, .record, .ocr, .pin, .save, .copy, .cancel]),
            (.pin, "Save PNG (⌘S)", [.undo, .redo, .ocr, .save, .copy, .done, .cancel]),
        ]

        try CCXL10n.withLanguageForTesting(.en) {
            for (preset, expectedSaveTooltip, expectedActions) in expectations {
                let toolbar = AnnotationActionToolbar(preset: preset)
                toolbar.update(
                    activeTool: .select,
                    style: AnnotationStyle(),
                    showStyleBar: false,
                    canUndo: true,
                    canRedo: true
                )
                toolbar.layoutSubtreeIfNeeded()

                let arranged = toolbar.primaryStack.arrangedSubviews
                let saveIndex = try #require(arranged.firstIndex { ($0 as? NSButton)?.toolTip == expectedSaveTooltip })
                let copyIndex = try #require(arranged.firstIndex { ($0 as? NSButton)?.toolTip == "Copy (⌘C)" })
                #expect(saveIndex < copyIndex)
                #expect(copyIndex == saveIndex + 1)

                let saveButton = arranged[saveIndex]
                let copyButton = arranged[copyIndex]
                #expect(saveButton.frame.minX < copyButton.frame.minX)

                var triggeredActions: [AnnotationToolbarAction] = []
                toolbar.onAction = { triggeredActions.append($0) }
                for case let button as NSButton in arranged where button.isEnabled {
                    if let action = button.action {
                        _ = button.sendAction(action, to: button.target)
                    }
                }
                #expect(triggeredActions == expectedActions)
            }
        }
    }

    @Test func toolbarGlassSurfacesClipToContinuousRoundedCorners() throws {
        for preset in [AnnotationToolbarPreset.snip, .pin] {
            let toolbar = AnnotationActionToolbar(preset: preset)
            toolbar.update(
                activeTool: .pen,
                style: AnnotationStyle(),
                showStyleBar: true,
                canUndo: false,
                canRedo: false
            )
            toolbar.layoutSubtreeIfNeeded()

            let expectedSurfaces: [(surface: NSView, radius: CGFloat)] = [
                (toolbar.primarySurface, 12),
                (toolbar.styleSurface, 10),
            ]
            for (surface, expectedRadius) in expectedSurfaces {
                #expect(surface.wantsLayer)
                let layer = try #require(surface.layer)
                #expect(layer.masksToBounds)
                #expect(layer.cornerCurve == .continuous)
                #expect(layer.cornerRadius == expectedRadius)
                if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
                    #expect(glass.cornerRadius == expectedRadius)
                }
            }
        }
    }

    private func alphaHistogramAndDigest(
        of image: NSImage
    ) throws -> (nonZeroPixels: Int, midAlphaPixels: Int, opaquePixels: Int, digest: UInt64) {
        let width = 60
        let height = 60
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: 2, y: 2)
        let drawRect = CGRect(
            x: (30 - image.size.width) / 2,
            y: (30 - image.size.height) / 2,
            width: image.size.width,
            height: image.size.height
        )
        image.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()

        var nonZero = 0
        var midAlpha = 0
        var opaque = 0
        var fnv: UInt64 = 14_695_981_039_346_656_037
        for i in stride(from: 3, to: rgba.count, by: 4) {
            let alpha = rgba[i]
            if alpha > 20 { nonZero += 1 }
            if alpha >= 70 && alpha <= 190 { midAlpha += 1 }
            if alpha >= 235 { opaque += 1 }
            fnv ^= UInt64(alpha)
            fnv = fnv &* 1_099_511_628_211
        }
        return (nonZero, midAlpha, opaque, fnv)
    }

    @Test func penHighlighterAndTextIconsAreDistinctTemplateNonEmptyAndLocaleIndependentAcrossToolbar() throws {
        // Fallback symbol names stay clean and non-localized across `en` and `zh-Hans`.
        #expect(AnnotationTool.pen.symbolName == "scribble")
        #expect(AnnotationTool.highlighter.symbolName == "highlighter")
        #expect(AnnotationTool.text.symbolName != "textformat")
        #expect(AnnotationTool.text.symbolName != "text.cursor")
        #expect(AnnotationTool.text.symbolName != "character.cursor.ibeam")
        #expect(AnnotationTool.text.symbolName != "character.textbox")

        var renderedByTool: [AnnotationTool: (nonZeroPixels: Int, midAlphaPixels: Int, opaquePixels: Int, digest: UInt64)] = [:]
        for tool in [AnnotationTool.pen, .highlighter, .text] {
            let icon = tool.toolbarIconImage(accessibilityDescription: tool.displayName)
            #expect(icon.isTemplate)
            #expect(icon.size.width > 0 && icon.size.height > 0)
            let rendered = try alphaHistogramAndDigest(of: icon)
            #expect(rendered.nonZeroPixels > 20)
            renderedByTool[tool] = rendered
        }

        // Pen (open S-wave), Highlighter (chisel nib + translucent 4.2pt swath), and Text (`T|`)
        // must have distinct rendered silhouettes, with Highlighter preserving both its translucent
        // swath and opaque chisel nib ink.
        let penRendered = try #require(renderedByTool[.pen])
        let highlighterRendered = try #require(renderedByTool[.highlighter])
        let textRendered = try #require(renderedByTool[.text])
        #expect(penRendered.digest != highlighterRendered.digest)
        #expect(penRendered.digest != textRendered.digest)
        #expect(highlighterRendered.digest != textRendered.digest)
        #expect(highlighterRendered.midAlphaPixels > 80)
        #expect(highlighterRendered.opaquePixels > 40)

        // Every button icon in both toolbar presets must render non-empty template ink
        // identically in `en` and `zh-Hans` (no localized Chinese characters in the toolbar).
        let enLocale = Locale(identifier: "en")
        let zhLocale = Locale(identifier: "zh-Hans")
        for preset in [AnnotationToolbarPreset.snip, .pin] {
            let toolbar = AnnotationActionToolbar(preset: preset)
            toolbar.layoutSubtreeIfNeeded()
            for tool in AnnotationTool.drawingTools {
                let buttonImage = try #require(toolbar.toolButtonImage(for: tool))
                #expect(buttonImage.isTemplate)
                #expect(buttonImage.size.width > 0 && buttonImage.size.height > 0)
            }

            let penButtonImage = try #require(toolbar.toolButtonImage(for: .pen))
            let hlButtonImage = try #require(toolbar.toolButtonImage(for: .highlighter))
            #expect(try alphaHistogramAndDigest(of: penButtonImage).digest != alphaHistogramAndDigest(of: hlButtonImage).digest)

            let buttons = toolbar.primaryStack.arrangedSubviews.compactMap { $0 as? NSButton }
            #expect(!buttons.isEmpty)
            for button in buttons {
                #expect(button.frame.height == 30)
                let image = try #require(button.image)
                #expect(image.isTemplate)
                #expect(image.size.width > 0 && image.size.height > 0)
                let enRendered = try alphaHistogramAndDigest(of: image.withLocale(enLocale))
                let zhRendered = try alphaHistogramAndDigest(of: image.withLocale(zhLocale))
                #expect(enRendered.nonZeroPixels > 10)
                #expect(enRendered.digest == zhRendered.digest)
            }
        }
    }

    /// Creates an sRGB premultiplied RGBA image with optional rounded corners (specified in top-left image
    /// orientation so tests can verify vertical orientation explicitly).
    private func makeRoundedImage(
        width: Int,
        height: Int,
        topLeftRadius: CGFloat,
        topRightRadius: CGFloat,
        bottomLeftRadius: CGFloat,
        bottomRightRadius: CGFloat,
        drawContent: (CGContext) -> Void
    ) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // Build per-corner rounded path in CG bottom-left coordinates:
        // top edge is y = height, bottom edge is y = 0.
        let w = CGFloat(width)
        let h = CGFloat(height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bottomLeftRadius, y: 0))
        path.addLine(to: CGPoint(x: w - bottomRightRadius, y: 0))
        if bottomRightRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: bottomRightRadius), radius: bottomRightRadius)
        }
        path.addLine(to: CGPoint(x: w, y: h - topRightRadius))
        if topRightRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - topRightRadius, y: h), radius: topRightRadius)
        }
        path.addLine(to: CGPoint(x: topLeftRadius, y: h))
        if topLeftRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - topLeftRadius), radius: topLeftRadius)
        }
        path.addLine(to: CGPoint(x: 0, y: bottomLeftRadius))
        if bottomLeftRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: bottomLeftRadius, y: 0), radius: bottomLeftRadius)
        }
        path.closeSubpath()

        ctx.addPath(path)
        ctx.clip()
        drawContent(ctx)
        return try #require(ctx.makeImage())
    }

    @Test func vectorAnnotationsPaintOnTransparentCanvasesAndTranslucentChrome() throws {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        let padded = try makeRoundedImage(
            width: 120, height: 80,
            topLeftRadius: 0, topRightRadius: 0, bottomLeftRadius: 0, bottomRightRadius: 0
        ) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(bounds.insetBy(dx: 30, dy: 20))
        }
        let translucent = try makeRoundedImage(
            width: 120, height: 80,
            topLeftRadius: 20, topRightRadius: 20, bottomLeftRadius: 20, bottomRightRadius: 20
        ) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 0.65)
            context.fill(bounds)
        }

        let document = AnnotationDocument()
        document.commit(AnnotationItem(
            kind: .pen([CGPoint(x: 5, y: 8), CGPoint(x: 90, y: 8)]),
            style: AnnotationStyle(color: .red, size: .large)
        ))
        document.commit(AnnotationItem(kind: .rectangle(bounds), style: AnnotationStyle(color: .red, size: .maximum)))

        for image in [padded, translucent] {
            let baked = try #require(AnnotationRenderer.bake(
                baseImage: image, localSelectionRect: bounds, pixelCropRect: bounds,
                screenSize: bounds.size, document: document, mosaicCache: nil
            ))
            let stroke = try sampleRGBA(in: baked, x: 60, y: 71)
            #expect(stroke.a == 255 && stroke.r > 200)
            let corner = try sampleRGBA(in: baked, x: 1, y: 1)
            if image === translucent {
                #expect(corner.a == 0)
            } else {
                #expect(corner.a > 0)
            }
        }
    }

    @Test(arguments: [MosaicMode.blur, .pixelate])
    func bakedRedactionReplacesTranslucentAndAntialiasedPixels(mode: MosaicMode) throws {
        let width = 120
        let height = 80
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let image = try makeRoundedImage(
            width: width, height: height,
            topLeftRadius: 24, topRightRadius: 24, bottomLeftRadius: 24, bottomRightRadius: 24
        ) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 160.0 / 255)
            context.fill(bounds)
            context.setBlendMode(.copy)
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 160.0 / 255)
            context.fill(CGRect(x: 0, y: height / 2 - 1, width: width, height: 1))
        }

        let document = AnnotationDocument()
        document.commit(AnnotationItem(kind: .mosaic(bounds, mode), style: AnnotationStyle(size: .large, mosaicMode: mode)))
        let cache = MosaicImageCache(baseImage: image)
        let filtered = try #require(cache.filteredImage(mode: mode, size: .large, backingScale: 1))
        let baked = try #require(AnnotationRenderer.bake(
            baseImage: image, localSelectionRect: bounds, pixelCropRect: bounds,
            screenSize: bounds.size, document: document, mosaicCache: cache
        ))
        let fallback = try #require(AnnotationRenderer.bake(
            baseImage: image, localSelectionRect: bounds, pixelCropRect: bounds,
            screenSize: bounds.size, document: document, mosaicCache: nil
        ))

        let center = try sampleRGBA(in: baked, x: width / 2, y: height / 2)
        #expect(center.a == 160 && center.r < 60)
        var checkedEdge = false
        for y in 0..<24 {
            for x in 0..<24 {
                let original = try sampleRGBA(in: image, x: x, y: y)
                guard original.a > 30, original.a < 130 else { continue }
                let redacted = try sampleRGBA(in: baked, x: x, y: y)
                let expected = try sampleRGBA(in: filtered, x: x, y: y)
                #expect(redacted == expected)
                #expect(redacted.a == original.a)
                #expect(try sampleRGBA(in: fallback, x: x, y: y).a == original.a)
                checkedEdge = true
            }
        }
        #expect(checkedEdge)
        #expect(try sampleRGBA(in: baked, x: 0, y: 0).a == 0)
        #expect(try sampleRGBA(in: fallback, x: width / 2, y: height / 2).a == 160)
    }

    @Test func mosaicCachePreservesTransparentRoundedCornersInBlurAndPixelate() throws {
        let width = 200
        let height = 120
        let radius: CGFloat = 28

        // Striped interior so both blur and pixelate produce measurable interior changes.
        let rounded = try makeRoundedImage(
            width: width,
            height: height,
            topLeftRadius: radius,
            topRightRadius: radius,
            bottomLeftRadius: radius,
            bottomRightRadius: radius
        ) { ctx in
            ctx.setFillColor(red: 0.15, green: 0.25, blue: 0.45, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
            for x in stride(from: 0, to: width, by: 8) {
                ctx.fill(CGRect(x: x, y: 0, width: 4, height: height))
            }
        }

        let exteriorSamples = [
            (0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1),
            (3, 3), (width - 4, 3), (3, height - 4), (width - 4, height - 4),
        ]
        for (x, y) in exteriorSamples {
            let px = try sampleRGBA(in: rounded, x: x, y: y)
            #expect(px.a == 0)
        }

        let cache = MosaicImageCache(baseImage: rounded)
        let blurred = try #require(cache.filteredImage(mode: .blur, size: .medium, backingScale: 2))
        let cpuBlurred = try #require(cache.cpuBlurredImage(radius: StrokeSize.medium.blurRadius * 2))
        let pixelated = try #require(cache.filteredImage(mode: .pixelate, size: .medium, backingScale: 2))

        for filtered in [blurred, cpuBlurred, pixelated] {
            #expect(filtered.width == width && filtered.height == height)
            for (x, y) in exteriorSamples {
                let px = try sampleRGBA(in: filtered, x: x, y: y)
                #expect(px.a == 0 && px.r == 0 && px.g == 0 && px.b == 0)
            }
            // Interior center stays opaque and averages the dark/light stripes cleanly.
            let center = try sampleRGBA(in: filtered, x: width / 2, y: height / 2)
            #expect(center.a == 255)
            #expect(center.r > 60 && center.r < 225)
            // Interior pixel inside the rounded curve stays fully opaque (no translucent edge bleed).
            let nearCurve = try sampleRGBA(in: filtered, x: 34, y: 14)
            #expect(nearCurve.a == 255)
        }

        // Uniform mid-gray rounded image verifies normalized blur avoids dark halos near transparent corners.
        let midGrayRounded = try makeRoundedImage(
            width: width,
            height: height,
            topLeftRadius: radius,
            topRightRadius: radius,
            bottomLeftRadius: radius,
            bottomRightRadius: radius
        ) { ctx in
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let grayCache = MosaicImageCache(baseImage: midGrayRounded)
        // Verify the CoreImage GPU graph itself unpremultiplies blur and masks via `_srcIn` for alpha images.
        let alphaGraph = try #require(grayCache.gpuBlurCIImage(radius: StrokeSize.medium.blurRadius * 2)).debugDescription
        #expect(alphaGraph.contains("unpremultiply"))
        #expect(alphaGraph.contains("swizzle_rgb1"))
        #expect(alphaGraph.contains("_srcIn"))

        let grayBlur = try #require(grayCache.filteredImage(mode: .blur, size: .medium, backingScale: 2))
        let grayGPUBlur = grayCache.gpuBlurredImage(radius: StrokeSize.medium.blurRadius * 2)
        let grayCPUBlur = try #require(grayCache.cpuBlurredImage(radius: StrokeSize.medium.blurRadius * 2))
        var blurVariants = [grayBlur, grayCPUBlur]
        if let grayGPUBlur {
            blurVariants.append(grayGPUBlur)
        }
        for img in blurVariants {
            let corner = try sampleRGBA(in: img, x: 0, y: 0)
            #expect(corner.a == 0)
            // 4px inside the top-left rounded arc (circle center at (28, 28), (12, 12) has distance ~22.6 < 28).
            let nearEdge = try sampleRGBA(in: img, x: 12, y: 12)
            #expect(nearEdge.a == 255)
            #expect(nearEdge.r >= 118 && nearEdge.r <= 145)
        }

        // Asymmetric corner mask (only top-left rounded) verifies zero vertical flip in MosaicImageCache.
        let asymmetric = try makeRoundedImage(
            width: 160,
            height: 120,
            topLeftRadius: 28,
            topRightRadius: 0,
            bottomLeftRadius: 0,
            bottomRightRadius: 0
        ) { ctx in
            ctx.setFillColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        let asymCache = MosaicImageCache(baseImage: asymmetric)
        for img in [
            try #require(asymCache.filteredImage(mode: .blur, size: .medium, backingScale: 2)),
            try #require(asymCache.cpuBlurredImage(radius: StrokeSize.medium.blurRadius * 2)),
            try #require(asymCache.filteredImage(mode: .pixelate, size: .medium, backingScale: 2)),
        ] {
            #expect(try sampleRGBA(in: img, x: 0, y: 0).a == 0)
            #expect(try sampleRGBA(in: img, x: 159, y: 0).a == 255)
            #expect(try sampleRGBA(in: img, x: 0, y: 119).a == 255)
            #expect(try sampleRGBA(in: img, x: 159, y: 119).a == 255)
        }
    }

    @Test func bakePreservesTransparentRoundedCornersAsymmetricOrientationAndOpaqueImages() throws {
        let width = 200
        let height = 120
        let radius: CGFloat = 28

        // 1. Four transparent rounded corners + a semi-transparent interior patch surrounded by opaque pixels.
        let rounded = try makeRoundedImage(
            width: width,
            height: height,
            topLeftRadius: radius,
            topRightRadius: radius,
            bottomLeftRadius: radius,
            bottomRightRadius: radius
        ) { ctx in
            ctx.setFillColor(red: 0.12, green: 0.22, blue: 0.36, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Translucent interior patch at CG (140..170, 50..70) -> top-down x=140..170, y=50..70.
            ctx.setBlendMode(.copy)
            ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 160.0 / 255.0)
            ctx.fill(CGRect(x: 140, y: 50, width: 30, height: 20))
            ctx.setBlendMode(.normal)
        }
        #expect(AnnotationRenderer.hasTransparentExteriorCorners(rounded))

        // Capture untouched anti-aliased edge alpha along the top-left curve to confirm zero degradation.
        var aaSamplePoint: (x: Int, y: Int, alpha: UInt8)?
        for y in 0..<Int(radius) {
            for x in 0..<Int(radius) {
                let px = try sampleRGBA(in: rounded, x: x, y: y)
                if px.a > 40 && px.a < 210 {
                    aaSamplePoint = (x, y, px.a)
                    break
                }
            }
            if aaSamplePoint != nil { break }
        }
        let aaSample = try #require(aaSamplePoint)

        let doc = AnnotationDocument()
        // Edge-to-edge rectangle, corner-to-corner pen strokes, and full-width blur/pixelate mosaics.
        doc.commit(AnnotationItem(
            kind: .mosaic(CGRect(x: 0, y: 0, width: 50, height: 60), .blur),
            style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .blur)
        ))
        doc.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 60)),
            style: AnnotationStyle(color: .red, size: .maximum)
        ))
        doc.commit(AnnotationItem(
            kind: .pen([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 60)]),
            style: AnnotationStyle(color: .green, size: .large)
        ))
        doc.commit(AnnotationItem(
            kind: .pen([CGPoint(x: 0, y: 60), CGPoint(x: 100, y: 0)]),
            style: AnnotationStyle(color: .green, size: .large)
        ))

        let cache = MosaicImageCache(baseImage: rounded)
        let bakedWithCache = try #require(AnnotationRenderer.bake(
            baseImage: rounded,
            localSelectionRect: CGRect(x: 0, y: 0, width: 100, height: 60),
            pixelCropRect: CGRect(x: 0, y: 0, width: width, height: height),
            screenSize: CGSize(width: 100, height: 60),
            document: doc,
            mosaicCache: cache
        ))
        let bakedWithoutCache = try #require(AnnotationRenderer.bake(
            baseImage: rounded,
            localSelectionRect: CGRect(x: 0, y: 0, width: 100, height: 60),
            pixelCropRect: CGRect(x: 0, y: 0, width: width, height: height),
            screenSize: CGSize(width: 100, height: 60),
            document: doc,
            mosaicCache: nil
        ))

        let exteriorSamples = [
            (0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1),
            (3, 3), (width - 4, 3), (3, height - 4), (width - 4, height - 4),
        ]
        for baked in [bakedWithCache, bakedWithoutCache] {
            #expect(baked.width == width && baked.height == height)
            for (x, y) in exteriorSamples {
                let px = try sampleRGBA(in: baked, x: x, y: y)
                #expect(px.a == 0 && px.r == 0 && px.g == 0 && px.b == 0)
            }
            // Center of diagonal green pen intersection stays opaque green.
            let center = try sampleRGBA(in: baked, x: 100, y: 60)
            #expect(center.a == 255 && center.g > 160 && center.r < 90)
            // Untouched translucent interior patch keeps its original alpha (~160).
            let translucentInterior = try sampleRGBA(in: baked, x: 155, y: 60)
            #expect(abs(Int(translucentInterior.a) - 160) <= 1)
            // Anti-aliased edge preserves exact corner alpha without double-attenuation.
            let aaAfter = try sampleRGBA(in: baked, x: aaSample.x, y: aaSample.y)
            #expect(aaAfter.a == aaSample.alpha)
        }

        // Re-baking a second annotation pass onto an already-baked rounded image must not erode AA corners.
        let secondDoc = AnnotationDocument()
        secondDoc.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 35, y: 20, width: 30, height: 20)),
            style: AnnotationStyle(color: .blue, size: .medium)
        ))
        let reBaked = try #require(AnnotationRenderer.bake(
            baseImage: bakedWithCache,
            localSelectionRect: CGRect(x: 0, y: 0, width: 100, height: 60),
            pixelCropRect: CGRect(x: 0, y: 0, width: width, height: height),
            screenSize: CGSize(width: 100, height: 60),
            document: secondDoc,
            mosaicCache: nil
        ))
        #expect(try sampleRGBA(in: reBaked, x: 0, y: 0).a == 0)
        #expect(try sampleRGBA(in: reBaked, x: aaSample.x, y: aaSample.y).a == aaSample.alpha)

        // 2. Asymmetric corner mask (ONLY top-left rounded, other 3 square) guarantees zero vertical flip.
        let asymWidth = 160
        let asymHeight = 120
        let asymmetric = try makeRoundedImage(
            width: asymWidth,
            height: asymHeight,
            topLeftRadius: 28,
            topRightRadius: 0,
            bottomLeftRadius: 0,
            bottomRightRadius: 0
        ) { ctx in
            ctx.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: asymWidth, height: asymHeight))
        }
        #expect(AnnotationRenderer.hasTransparentExteriorCorners(asymmetric))

        let edgeDoc = AnnotationDocument()
        edgeDoc.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 0, y: 0, width: 80, height: 60)),
            style: AnnotationStyle(color: .red, size: .maximum)
        ))
        let asymBaked = try #require(AnnotationRenderer.bake(
            baseImage: asymmetric,
            localSelectionRect: CGRect(x: 0, y: 0, width: 80, height: 60),
            pixelCropRect: CGRect(x: 0, y: 0, width: asymWidth, height: asymHeight),
            screenSize: CGSize(width: 80, height: 60),
            document: edgeDoc,
            mosaicCache: nil
        ))

        let tl = try sampleRGBA(in: asymBaked, x: 0, y: 0)
        let tlInner = try sampleRGBA(in: asymBaked, x: 3, y: 3)
        let tr = try sampleRGBA(in: asymBaked, x: asymWidth - 1, y: 0)
        let bl = try sampleRGBA(in: asymBaked, x: 0, y: asymHeight - 1)
        let br = try sampleRGBA(in: asymBaked, x: asymWidth - 1, y: asymHeight - 1)

        #expect(tl.a == 0 && tl.r == 0 && tl.g == 0 && tl.b == 0)
        #expect(tlInner.a == 0 && tlInner.r == 0 && tlInner.g == 0 && tlInner.b == 0)
        #expect(tr.a == 255 && tr.r > 200 && tr.g < 80)
        #expect(bl.a == 255 && bl.r > 200 && bl.g < 80)
        #expect(br.a == 255 && br.r > 200 && br.g < 80)

        // 3. Standard opaque rectangular images (both RGBX noneSkipLast and opaque RGBA) behave identically.
        let rgbxCtx = try #require(CGContext(
            data: nil,
            width: 120,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        rgbxCtx.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        rgbxCtx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let opaqueRGBX = try #require(rgbxCtx.makeImage())
        #expect(!AnnotationRenderer.hasTransparentExteriorCorners(opaqueRGBX))

        // Opaque RGBX images take the fast CoreImage blur path without unpremultiply or `_srcIn` overhead.
        let opaqueCache = MosaicImageCache(baseImage: opaqueRGBX)
        let opaqueGraph = try #require(opaqueCache.gpuBlurCIImage(radius: StrokeSize.medium.blurRadius * 2)).debugDescription
        #expect(!opaqueGraph.contains("unpremultiply"))
        #expect(!opaqueGraph.contains("_srcIn"))

        let opaqueDoc = AnnotationDocument()
        opaqueDoc.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 0, y: 0, width: 60, height: 40)),
            style: AnnotationStyle(color: .red, size: .maximum)
        ))
        let opaqueBaked = try #require(AnnotationRenderer.bake(
            baseImage: opaqueRGBX,
            localSelectionRect: CGRect(x: 0, y: 0, width: 60, height: 40),
            pixelCropRect: CGRect(x: 0, y: 0, width: 120, height: 80),
            screenSize: CGSize(width: 60, height: 40),
            document: opaqueDoc,
            mosaicCache: opaqueCache
        ))
        for (x, y) in [(0, 0), (119, 0), (0, 79), (119, 79)] {
            let px = try sampleRGBA(in: opaqueBaked, x: x, y: y)
            #expect(px.a == 255 && px.r > 200)
        }

        // Standard opaque RGBA (premultipliedLast with all alpha == 255) also skips corner masking cleanly.
        let opaqueRGBACtx = try #require(CGContext(
            data: nil,
            width: 120,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        opaqueRGBACtx.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        opaqueRGBACtx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let opaqueRGBA = try #require(opaqueRGBACtx.makeImage())
        #expect(!AnnotationRenderer.hasTransparentExteriorCorners(opaqueRGBA))
        let opaqueRGBABaked = try #require(AnnotationRenderer.bake(
            baseImage: opaqueRGBA,
            localSelectionRect: CGRect(x: 0, y: 0, width: 60, height: 40),
            pixelCropRect: CGRect(x: 0, y: 0, width: 120, height: 80),
            screenSize: CGSize(width: 60, height: 40),
            document: opaqueDoc,
            mosaicCache: MosaicImageCache(baseImage: opaqueRGBA)
        ))
        for (x, y) in [(0, 0), (119, 0), (0, 79), (119, 79)] {
            let px = try sampleRGBA(in: opaqueRGBABaked, x: x, y: y)
            #expect(px.a == 255 && px.r > 200)
        }
    }

    @Test func finiteOverflowGuardsTextAndPolylineCapsAndCacheCeiling() throws {
        // 1. MosaicImageCache handles extreme/non-finite scale & radius safely without trapping,
        //    and honors resident byte ceiling (variants + cachedBaseRGBA) + clear().
        let width = 100
        let height = 100
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.25, green: 0.45, blue: 0.75, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        for x in stride(from: 0, to: width, by: 8) {
            ctx.fill(CGRect(x: x, y: 0, width: 3, height: height))
        }
        let opaqueRGBA = try #require(ctx.makeImage())

        // Tight budget (50 KB for a 40 KB image): residentByteCount must stay <= 50 KB across modes.
        let tightCache = MosaicImageCache(baseImage: opaqueRGBA, maxCachedBytes: 50_000)
        #expect(tightCache.filteredImage(mode: .pixelate, size: .medium, backingScale: 1e20) != nil)
        #expect(tightCache.filteredImage(mode: .blur, size: .large, backingScale: .infinity) != nil)
        #expect(tightCache.filteredImage(mode: .blur, size: .small, backingScale: .nan) != nil)
        #expect(tightCache.residentByteCount <= 50_000)

        // Direct radius guards on gpuBlurCIImage / cpuBlurredImage reject invalid values & clamp extreme ones.
        #expect(tightCache.gpuBlurCIImage(radius: .nan) == nil)
        #expect(tightCache.gpuBlurCIImage(radius: .infinity) == nil)
        #expect(tightCache.gpuBlurCIImage(radius: 0) == nil)
        #expect(tightCache.gpuBlurCIImage(radius: -4) == nil)
        #expect(tightCache.cpuBlurredImage(radius: .nan) == nil)
        #expect(tightCache.cpuBlurredImage(radius: .infinity) == nil)
        #expect(tightCache.cpuBlurredImage(radius: 0) == nil)
        #expect(tightCache.cpuBlurredImage(radius: 1e20) != nil)

        // After SIMD transparency scan on opaque RGBA, GPU blur skips unpremultiply/_srcIn stages cleanly.
        let fastOpaqueGraph = try #require(tightCache.gpuBlurCIImage(radius: 16)).debugDescription
        #expect(!fastOpaqueGraph.contains("unpremultiply"))
        #expect(!fastOpaqueGraph.contains("_srcIn"))

        // CPU blur zero-copy context path matches expected opaque RGBA output and clear() releases everything.
        let cpuBlurred = try #require(tightCache.cpuBlurredImage(radius: 12))
        #expect(cpuBlurred.width == width && cpuBlurred.height == height)
        let midPx = try sampleRGBA(in: cpuBlurred, x: 50, y: 50)
        #expect(midPx.a == 255)
        tightCache.clear()
        #expect(tightCache.cachedVariantCount == 0)
        #expect(tightCache.cachedByteCount == 0)
        #expect(tightCache.residentByteCount == 0)

        // 2. Vectorized transparency check detects a single semi-transparent interior pixel in an opaque RGBA image.
        ctx.setBlendMode(.copy)
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 128.0 / 255.0)
        ctx.fill(CGRect(x: 63, y: 47, width: 1, height: 1))
        let singleTranslucent = try #require(ctx.makeImage())
        let translucentCache = MosaicImageCache(baseImage: singleTranslucent)
        let transPixelated = try #require(translucentCache.filteredImage(mode: .pixelate, size: .small, backingScale: 1))
        #expect(try sampleRGBA(in: transPixelated, x: 63, y: height - 1 - 47).a == 128)
        let transGraph = try #require(translucentCache.gpuBlurCIImage(radius: 10)).debugDescription
        #expect(transGraph.contains("_srcIn"))

        // 3. Polyline point cap & in-place append behavior.
        var polyline: [CGPoint] = []
        #expect(AnnotationItem.appendPointInPlace(CGPoint(x: 0, y: 0), to: &polyline))
        #expect(!AnnotationItem.appendPointInPlace(CGPoint(x: 1, y: 1), to: &polyline, minDistance: 2.5))
        #expect(!AnnotationItem.appendPointInPlace(CGPoint(x: CGFloat.nan, y: 5), to: &polyline))
        #expect(polyline.count == 1)

        var capped = (0..<AnnotationItem.maxPolylinePoints).map { CGPoint(x: CGFloat($0 * 4), y: 0) }
        #expect(!AnnotationItem.appendPointInPlace(CGPoint(x: 999_999, y: 0), to: &capped))
        #expect(capped.count == AnnotationItem.maxPolylinePoints)
        #expect(AnnotationItem.appendPoint(CGPoint(x: 999_999, y: 0), to: capped).count == AnnotationItem.maxPolylinePoints)

        // 4. Text length cap & bounded text-measure static cache.
        AnnotationItem.clearTextMeasureCacheForTesting()
        let hugeText = String(repeating: "A", count: 100_000)
        #expect(AnnotationItem.boundedText(hugeText).count == AnnotationItem.maxTextLength)
        let hugeBox = AnnotationItem.textBoundingBox(origin: CGPoint(x: 10, y: 200), content: hugeText, fontSize: 16)
        #expect(hugeBox.width > 0 && hugeBox.height > 0)
        // Oversized strings (> 512 bytes) must not pin entries in static textMeasureCache.
        #expect(AnnotationItem.textMeasureCacheCountForTesting == 0)
        #expect(AnnotationItem.textMeasureCacheBytesForTesting == 0)

        for i in 0..<80 {
            _ = AnnotationItem.textBoundingBox(
                origin: CGPoint(x: 10, y: 100),
                content: "Label #\(i) " + String(repeating: "x", count: 240),
                fontSize: 16
            )
        }
        #expect(AnnotationItem.textMeasureCacheCountForTesting <= 64)
        #expect(AnnotationItem.textMeasureCacheBytesForTesting <= 16 * 1024)

        // 5. Renderer & toolbar finite guards (no traps on subnormal screenSize / non-finite rects / arrows / polylines).
        let doc = AnnotationDocument()
        doc.commit(AnnotationItem(kind: .rectangle(.null), style: AnnotationStyle()))
        doc.commit(AnnotationItem(kind: .arrow(start: CGPoint(x: CGFloat.infinity, y: 0), end: CGPoint(x: 10, y: 10)), style: AnnotationStyle()))
        doc.commit(AnnotationItem(kind: .pen([CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 20, y: 20)]), style: AnnotationStyle()))
        doc.commit(AnnotationItem(kind: .mosaic(CGRect(x: 5, y: 5, width: 20, height: 20), .pixelate), style: AnnotationStyle()))
        #expect(AnnotationRenderer.bake(
            baseImage: opaqueRGBA,
            localSelectionRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelCropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenSize: CGSize(width: 1e-300, height: 100),
            document: doc,
            mosaicCache: nil
        ) == nil)
        #expect(AnnotationRenderer.bake(
            baseImage: opaqueRGBA,
            localSelectionRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelCropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenSize: CGSize(width: 100, height: 100),
            document: doc,
            mosaicCache: nil
        ) != nil)

        let toolbarFrame = AnnotationActionToolbar.frame(
            for: .null,
            in: .infinite,
            topInset: .nan,
            showsStyleBar: true,
            preset: .pin
        )
        #expect(toolbarFrame.origin.x.isFinite && toolbarFrame.origin.y.isFinite)
        let clampedToolbarFrame = AnnotationActionToolbar.clampedFrame(
            anchoredAtTopLeft: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            size: CGSize(width: CGFloat.nan, height: -5),
            in: CGRect(x: 0, y: 0, width: 800, height: 600),
            topInset: .infinity
        )
        #expect(clampedToolbarFrame.origin.x.isFinite && clampedToolbarFrame.origin.y.isFinite)
        #expect(clampedToolbarFrame.width > 0 && clampedToolbarFrame.height > 0)
    }

    @Test func milestoneTooltipsPaletteSanitizationContinuousCornersAndLargeCounters() throws {
        func allSubviews(of root: NSView) -> [NSView] {
            root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
        }

        // 1. Bilingual tool tooltips, palette color display names, mosaic tooltips, accessibility labels, and continuous corners.
        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                for tool in AnnotationTool.allCases {
                    let tip = tool.toolbarTooltip
                    #expect(!tip.isEmpty)
                    #expect(!tip.contains("\n"))
                    #expect(tip.contains(tool.displayName))
                    if let shortcut = tool.shortcutHint {
                        #expect(tip.contains("(\(shortcut))"))
                    }
                }
                #expect(AnnotationTool.rectangle.toolbarTooltip.contains("⇧"))
                #expect(AnnotationTool.ellipse.toolbarTooltip.contains("⇧"))
                #expect(AnnotationTool.arrow.toolbarTooltip.contains("⇧"))
                #expect(AnnotationTool.mosaic.toolbarTooltip.contains("⇧"))
                #expect(AnnotationTool.text.toolbarTooltip.contains("⇧↩"))

                for color in AnnotationColor.palette {
                    #expect(!color.displayName.isEmpty)
                    #expect(!color.displayName.contains("\n"))
                }
                let customColor = AnnotationColor(r: 0.2, g: 0.3, b: 0.4, hex: "#334D66")
                #expect(customColor.displayName == "#334D66")

                for mode in MosaicMode.allCases {
                    #expect(!mode.tooltip.isEmpty)
                    #expect(!mode.tooltip.contains("\n"))
                }

                for preset in [AnnotationToolbarPreset.snip, .pin] {
                    let toolbar = AnnotationActionToolbar(preset: preset)
                    toolbar.update(
                        activeTool: .rectangle,
                        style: AnnotationStyle(color: .red, size: .medium, mosaicMode: .pixelate),
                        showStyleBar: true,
                        canUndo: true,
                        canRedo: true
                    )
                    toolbar.layoutSubtreeIfNeeded()

                    let primaryButtons = toolbar.primaryStack.arrangedSubviews.compactMap { $0 as? NSButton }
                    #expect(!primaryButtons.isEmpty)
                    for button in primaryButtons {
                        #expect(button.layer?.cornerCurve == .continuous)
                    }
                    #expect(toolbar.dragHandleView.layer?.cornerCurve == .continuous)

                    let toolTips = Set(primaryButtons.compactMap(\.toolTip))
                    for tool in AnnotationTool.drawingTools {
                        #expect(toolTips.contains(tool.toolbarTooltip))
                    }

                    let styleButtons = allSubviews(of: toolbar.styleSurface).compactMap { $0 as? NSButton }
                    let redSwatch = styleButtons.first { $0.toolTip?.contains(AnnotationColor.red.hex) == true }
                    #expect(redSwatch != nil)
                    #expect(redSwatch?.toolTip?.contains(AnnotationColor.red.displayName) == true)
                }
            }
        }

        CCXL10n.withLanguageForTesting(.en) {
            #expect(AnnotationColor.red.displayName == "Red")
            #expect(AnnotationColor.charcoal.displayName == "Charcoal")
        }
        CCXL10n.withLanguageForTesting(.zhHans) {
            #expect(AnnotationColor.red.displayName == "红色")
            #expect(AnnotationColor.charcoal.displayName == "炭黑")
        }

        // 2. AnnotationColor channel clamping & AnnotationDocument boundary sanitization.
        let clampedColor = AnnotationColor(r: .nan, g: -0.5, b: 2.5, hex: "#BAD")
        #expect(clampedColor.r == 0 && clampedColor.g == 0 && clampedColor.b == 1)

        let doc = AnnotationDocument()
        let hugeText = String(repeating: "Z", count: AnnotationItem.maxTextLength + 500)
        let hugePolyline = (0 ..< (AnnotationItem.maxPolylinePoints + 500)).map { CGPoint(x: CGFloat($0), y: 10) }
        let textItem = AnnotationItem(kind: .text(origin: CGPoint(x: 10, y: 20), content: hugeText), style: AnnotationStyle())
        let penItem = AnnotationItem(kind: .pen(hugePolyline), style: AnnotationStyle())
        doc.commit(textItem)
        doc.commit(penItem)

        if case let .text(_, storedText) = doc.items[0].kind {
            #expect(storedText.count == AnnotationItem.maxTextLength)
        } else {
            Issue.record("Expected sanitized text item")
        }
        if case let .pen(storedPoints) = doc.items[1].kind {
            #expect(storedPoints.count == AnnotationItem.maxPolylinePoints)
        } else {
            Issue.record("Expected sanitized pen item")
        }

        var replacedText = doc.items[0]
        replacedText.kind = .text(origin: CGPoint(x: 15, y: 25), content: hugeText)
        doc.replaceItem(replacedText, recordUndo: false)
        if case let .text(_, storedReplaced) = doc.items[0].kind {
            #expect(storedReplaced.count == AnnotationItem.maxTextLength)
        } else {
            Issue.record("Expected sanitized replaced text item")
        }

        // 3. Non-finite & overflow guards on boundingBox, handlePoints, hitTest, and translated.
        let overflowRectItem = AnnotationItem(
            kind: .rectangle(CGRect(x: 1e308, y: 0, width: 1e308, height: 10)),
            style: AnnotationStyle()
        )
        #expect(overflowRectItem.boundingBox == .zero)
        #expect(overflowRectItem.handlePoints.isEmpty)
        #expect(!overflowRectItem.hitTest(point: CGPoint(x: 10, y: 10)))

        let nanArrow = AnnotationItem(
            kind: .arrow(start: CGPoint(x: CGFloat.nan, y: 0), end: CGPoint(x: 20, y: 20)),
            style: AnnotationStyle()
        )
        #expect(nanArrow.boundingBox == .zero)
        #expect(nanArrow.handlePoints.isEmpty)
        #expect(!nanArrow.hitTest(point: CGPoint(x: 10, y: 10)))
        let finiteArrow = AnnotationItem(
            kind: .arrow(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 20, y: 20)),
            style: AnnotationStyle()
        )
        #expect(finiteArrow.translated(by: CGSize(width: CGFloat.nan, height: 5)) == finiteArrow)
        #expect(finiteArrow.translated(by: CGSize(width: 1e308, height: 1e308)).translated(by: CGSize(width: 1e308, height: 1e308)).boundingBox.origin.x.isFinite)

        let mixedPolyline = AnnotationItem(
            kind: .pen([CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 20)]),
            style: AnnotationStyle()
        )
        let polyBounds = mixedPolyline.boundingBox
        #expect(polyBounds.origin.x.isFinite && polyBounds.origin.y.isFinite && polyBounds.width > 0)
        #expect(!mixedPolyline.hitTest(point: CGPoint(x: CGFloat.nan, y: 10)))

        // 4. 4-digit counter & non-finite renderer draw guards produce clean output without trapping.
        let canvasBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ctx = try #require(CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let counter4 = AnnotationItem(kind: .counter(center: CGPoint(x: 50, y: 50), number: 1234), style: AnnotationStyle(color: .red, size: .medium))
        AnnotationRenderer.draw(counter4, in: ctx, screenBounds: canvasBounds, mosaicImage: nil)
        AnnotationRenderer.draw(overflowRectItem, in: ctx, screenBounds: canvasBounds, mosaicImage: nil)
        AnnotationRenderer.draw(
            AnnotationItem(kind: .mosaic(.infinite, .blur), style: AnnotationStyle()),
            in: ctx,
            screenBounds: canvasBounds,
            mosaicImage: nil
        )
        let rendered = try #require(ctx.makeImage())
        let centerPx = try sampleRGBA(in: rendered, x: 50, y: 50)
        #expect(centerPx.a == 255)
    }

    @Test func toolbarRightAlignsForWideSelectionsAndCentersForNarrowSelections() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let topInset: CGFloat = 32

        for preset in [AnnotationToolbarPreset.snip, .pin] {
            let width = AnnotationActionToolbar.preferredSize(for: preset).width

            // 1. Narrow selection stays horizontally centered (compact and expanded).
            let narrow = CGRect(x: 400, y: 400, width: width - 120, height: 200)
            let narrowCompact = AnnotationActionToolbar.frame(
                for: narrow,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            let narrowExpanded = AnnotationActionToolbar.frame(
                for: narrow,
                in: bounds,
                topInset: topInset,
                showsStyleBar: true,
                preset: preset
            )
            #expect(narrowCompact.midX == narrow.midX)
            #expect(narrowCompact.maxY <= narrow.minY)
            #expect(narrowExpanded.midX == narrow.midX)
            #expect(narrowExpanded.maxY <= narrow.minY)

            // 2. Exact width threshold matches both centered and right-aligned coordinates.
            let threshold = CGRect(x: 300, y: 400, width: width, height: 200)
            let thresholdFrame = AnnotationActionToolbar.frame(
                for: threshold,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(thresholdFrame.minX == threshold.minX && thresholdFrame.maxX == threshold.maxX)

            // 3. Wide selection right-aligns below, above, and when style bar is visible.
            let wideBelow = CGRect(x: 200, y: 400, width: width + 240, height: 200)
            let wideBelowFrame = AnnotationActionToolbar.frame(
                for: wideBelow,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            let wideExpandedFrame = AnnotationActionToolbar.frame(
                for: wideBelow,
                in: bounds,
                topInset: topInset,
                showsStyleBar: true,
                preset: preset
            )
            #expect(wideBelowFrame.maxX == wideBelow.maxX && wideBelowFrame.maxY <= wideBelow.minY)
            #expect(wideExpandedFrame.maxX == wideBelow.maxX && wideExpandedFrame.maxY <= wideBelow.minY)

            let wideAbove = CGRect(x: 200, y: 0, width: width + 240, height: 200)
            let wideAboveFrame = AnnotationActionToolbar.frame(
                for: wideAbove,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(wideAboveFrame.maxX == wideAbove.maxX && wideAboveFrame.minY >= wideAbove.maxY)

            // 4. Continuity across the threshold outside the selection.
            let atThreshold = AnnotationActionToolbar.frame(
                for: CGRect(x: 200, y: 400, width: width, height: 200),
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            let justOver = AnnotationActionToolbar.frame(
                for: CGRect(x: 200, y: 400, width: width + 1, height: 200),
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(justOver.minX - atThreshold.minX == 1)

            // 5. Full-screen / full-height wide selection falls back inside with an 8pt right inset.
            let fullScreen = AnnotationActionToolbar.frame(
                for: bounds,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(fullScreen.maxX == bounds.maxX - 8 && fullScreen.minY == bounds.minY + 8)

            let fullHeightWide = CGRect(x: 200, y: 0, width: width + 200, height: bounds.height)
            let fullHeightWideFrame = AnnotationActionToolbar.frame(
                for: fullHeightWide,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(fullHeightWideFrame.maxX == fullHeightWide.maxX - 8 && fullHeightWideFrame.minY == 8)

            // 6. Full-height narrow or slightly wider (<= width + 16) inside selection stays centered without overhanging left.
            let fullHeightNarrow = CGRect(x: 300, y: 0, width: width - 100, height: bounds.height)
            let fullHeightNarrowFrame = AnnotationActionToolbar.frame(
                for: fullHeightNarrow,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(fullHeightNarrowFrame.midX == fullHeightNarrow.midX && fullHeightNarrowFrame.minY == 8)

            let fullHeightSlightlyWider = CGRect(x: 300, y: 0, width: width + 8, height: bounds.height)
            let fullHeightSlightlyWiderFrame = AnnotationActionToolbar.frame(
                for: fullHeightSlightlyWider,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(fullHeightSlightlyWiderFrame.midX == fullHeightSlightlyWider.midX)
            #expect(fullHeightSlightlyWiderFrame.minX >= fullHeightSlightlyWider.minX)

            // 7. Continuity across the inside threshold (width + 16 -> width + 17).
            let insideThreshold = AnnotationActionToolbar.frame(
                for: CGRect(x: 200, y: 0, width: width + 16, height: bounds.height),
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            let insideJustOver = AnnotationActionToolbar.frame(
                for: CGRect(x: 200, y: 0, width: width + 17, height: bounds.height),
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(insideJustOver.minX - insideThreshold.minX == 1)

            // 8. Screen-edge clamping on right/left overflow and bounds narrower than toolbar.
            let overflowRight = CGRect(x: 1100, y: 400, width: width + 200, height: 200)
            let clampedRight = AnnotationActionToolbar.frame(
                for: overflowRight,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(clampedRight.maxX == bounds.maxX)

            let overflowLeft = CGRect(x: -500, y: 400, width: width + 100, height: 200)
            let clampedLeft = AnnotationActionToolbar.frame(
                for: overflowLeft,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                preset: preset
            )
            #expect(clampedLeft.minX == bounds.minX)

            let smallBounds = CGRect(x: 0, y: 0, width: width - 100, height: 400)
            let smallBoundsFrame = AnnotationActionToolbar.frame(
                for: CGRect(x: 10, y: 100, width: width - 120, height: 100),
                in: smallBounds,
                topInset: 0,
                showsStyleBar: false,
                preset: preset
            )
            #expect(smallBoundsFrame.minX == smallBounds.minX)
        }
    }

    @Test func mosaicCacheROICropCutsMemoryMovesCleanlyAndMatchesFullImageBake() throws {
        // Large 1600x1000 image (800x500pt @ 2x) with striped colored quadrants for strict spatial verification.
        let fullW = 1600
        let fullH = 1000
        let screenSize = CGSize(width: 800, height: 500)
        let ctx = try #require(CGContext(
            data: nil,
            width: fullW,
            height: fullH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.12, green: 0.20, blue: 0.48, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))
        // Upper-half (AppKit Y >= 250) bright orange-white vertical stripes; bottom-right green band.
        ctx.setFillColor(red: 0.96, green: 0.42, blue: 0.12, alpha: 1)
        for x in stride(from: 80, to: 500, by: 8) {
            ctx.fill(CGRect(x: x, y: 600, width: 4, height: 320))
        }
        ctx.setFillColor(red: 0.14, green: 0.78, blue: 0.35, alpha: 1)
        ctx.fill(CGRect(x: 1100, y: 80, width: 320, height: 220))
        let baseImage = try #require(ctx.makeImage())

        let roiCache = MosaicImageCache(baseImage: baseImage)
        let smallSelection = CGRect(x: 60, y: 320, width: 140, height: 110)
        roiCache.setActiveRegion(localRect: smallSelection, screenSize: screenSize)

        let pixSurface = try #require(roiCache.filteredSurface(mode: .pixelate, size: .medium, backingScale: 2))
        let blurSurface = try #require(roiCache.filteredSurface(mode: .blur, size: .medium, backingScale: 2))
        #expect(pixSurface.image.width < fullW / 2 && pixSurface.image.height < fullH / 2)
        #expect(blurSurface.image.width < fullW / 2 && blurSurface.image.height < fullH / 2)
        #expect(roiCache.baseRasterizationCount == 0)
        #expect(roiCache.cachedByteCount < (fullW * fullH * 4) / 2)

        // Small nudge inside padded margin keeps existing cached ROI without invalidating.
        let nudgedSelection = smallSelection.offsetBy(dx: 8, dy: 6)
        roiCache.setActiveRegion(localRect: nudgedSelection, screenSize: screenSize)
        #expect(roiCache.cachedVariantCount == 2)

        // Disjoint selection updates ROI cleanly to the bottom-right green zone.
        let farSelection = CGRect(x: 560, y: 50, width: 150, height: 100)
        roiCache.setActiveRegion(localRect: farSelection, screenSize: screenSize)
        #expect(roiCache.cachedVariantCount == 0)
        let farPix = try #require(roiCache.filteredSurface(mode: .pixelate, size: .medium, backingScale: 2))
        #expect(farPix.pixelOrigin.x > 600 && farPix.pixelOrigin.y > 400)

        // Compare ROI bake vs forced full-image bake pixel-for-pixel for both blur and pixelate.
        for mode in [MosaicMode.pixelate, .blur] {
            let doc = AnnotationDocument()
            let box = CGRect(x: 80, y: 330, width: 100, height: 80)
            doc.commit(AnnotationItem(
                kind: .mosaic(box, mode),
                style: AnnotationStyle(size: .medium, mosaicMode: mode)
            ))

            let roiBakeCache = MosaicImageCache(baseImage: baseImage)
            let selRect = CGRect(x: 60, y: 310, width: 160, height: 130)
            let alignedCrop = CGRect(x: 120, y: 120, width: 320, height: 260)

            let bakedROI = try #require(AnnotationRenderer.bake(
                baseImage: baseImage,
                localSelectionRect: selRect,
                pixelCropRect: alignedCrop,
                screenSize: screenSize,
                document: doc,
                mosaicCache: roiBakeCache
            ))

            let fullCache = MosaicImageCache(baseImage: baseImage)
            _ = fullCache.filteredImage(mode: mode, size: .medium, backingScale: 2)
            let contextFull = try #require(CGContext(
                data: nil,
                width: Int(alignedCrop.width),
                height: Int(alignedCrop.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let baseCropped = try #require(baseImage.cropping(to: alignedCrop))
            contextFull.draw(baseCropped, in: CGRect(origin: .zero, size: alignedCrop.size))
            let screenBounds = CGRect(origin: .zero, size: screenSize)
            contextFull.saveGState()
            contextFull.setBlendMode(.copy)
            contextFull.scaleBy(x: 2, y: 2)
            contextFull.translateBy(x: -alignedCrop.minX / 2, y: -(CGFloat(fullH) - alignedCrop.maxY) / 2)
            AnnotationRenderer.draw(doc.items[0], in: contextFull, screenBounds: screenBounds) { m, s in
                fullCache.filteredImage(mode: m, size: s, backingScale: 2)
            }
            contextFull.restoreGState()
            let bakedFull = try #require(contextFull.makeImage())

            var maxDiff = 0
            for py in stride(from: 20, to: 180, by: 8) {
                for px in stride(from: 50, to: 230, by: 8) {
                    let a = try sampleRGBA(in: bakedROI, x: px, y: py)
                    let b = try sampleRGBA(in: bakedFull, x: px, y: py)
                    maxDiff = max(
                        maxDiff,
                        abs(Int(a.r) - Int(b.r)),
                        abs(Int(a.g) - Int(b.g)),
                        abs(Int(a.b) - Int(b.b)),
                        abs(Int(a.a) - Int(b.a))
                    )
                }
            }
            #expect(maxDiff <= 3, "ROI bake diverged from full-image bake for \(mode) (maxDiff=\(maxDiff))")
        }
    }

    @Test @MainActor func brushCursorCacheAndLocalizedShortcutCheatSheetPresets() {
        let cache = BrushCursorCache()
        defer { cache.clear() }

        let pen1 = cache.cursor(diameter: 8.2, kind: .freehand)
        let pen2 = cache.cursor(diameter: 8.4, kind: .freehand)
        let mosaic1 = cache.cursor(diameter: 8.2, kind: .mosaic)
        #expect(pen1 === pen2, "Quantized freehand diameters should return identical cached NSCursor")
        #expect(pen1 !== mosaic1, "Freehand and mosaic cursors must not collide in cache")
        #expect(pen1.hotSpot.x > 0 && pen1.hotSpot.x == pen1.hotSpot.y)

        // Clamping extreme / non-finite diameters stays bounded and caps cache at maxCachedCursors.
        let tiny = cache.cursor(diameter: -10, kind: .freehand)
        let huge = cache.cursor(diameter: 500, kind: .mosaic)
        let nanCursor = cache.cursor(diameter: .nan, kind: .freehand)
        #expect(tiny === cache.cursor(diameter: BrushCursorCache.minimumDiameter, kind: .freehand))
        #expect(huge === cache.cursor(diameter: BrushCursorCache.maximumDiameter, kind: .mosaic))
        #expect(nanCursor.image.size.width > 0)

        for i in 1...40 {
            _ = cache.cursor(diameter: CGFloat(6 + i * 2), kind: .freehand)
        }
        #expect(cache.cachedCountForTesting() <= BrushCursorCache.maxCachedCursors)

        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                let snipHUD = ShortcutCheatSheetView(entries: ShortcutCheatSheetView.snipOverlayEntries)
                let pinHUD = ShortcutCheatSheetView(entries: ShortcutCheatSheetView.pinWindowEntries)
                #expect(!snipHUD.entries.isEmpty)
                #expect(!pinHUD.entries.isEmpty)
                #expect(pinHUD.entries.contains { $0.keys == "R / H / V" })
                #expect(snipHUD.hitTest(.zero) == nil)
                #expect(snipHUD.fittingSize.width >= 310)
                #expect(pinHUD.fittingSize.height > 120)
                for entry in snipHUD.entries + pinHUD.entries {
                    #expect(!entry.keys.isEmpty)
                    #expect(!entry.description.isEmpty)
                    #expect(!entry.description.contains("\n"))
                }
            }
        }
    }

    @Test func rendererUsesOpaqueFallbackForDisjointMosaicSurface() throws {
        func makeSolid(_ color: CGColor, size: Int) throws -> CGImage {
            let c = try #require(CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            c.setFillColor(color)
            c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            return try #require(c.makeImage())
        }

        let base = try makeSolid(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1), size: 200)
        let roiPatch = try makeSolid(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.1, alpha: 1), size: 40)
        let item = AnnotationItem(
            kind: .mosaic(CGRect(x: 10, y: 10, width: 50, height: 50), .pixelate),
            style: AnnotationStyle()
        )

        let ctx = try #require(CGContext(
            data: nil,
            width: 200,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 200 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: 200, height: 200))

        // Provide a surface whose ROI (x: 150..190) does not overlap the mosaic item (x: 10..60).
        let disjointSurface = MosaicFilteredSurface(
            image: roiPatch,
            pixelOrigin: CGPoint(x: 150, y: 150),
            fullImageSize: CGSize(width: 200, height: 200)
        )
        AnnotationRenderer.draw(
            item,
            in: ctx,
            screenBounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            mosaicSurface: { _, _ in disjointSurface }
        )

        let out = try #require(ctx.makeImage())
        // Pixel inside (30, 165) top-down (CGContext bottom-left y=35 -> pixel y=165) must be opaque fallback gray, not underlying blue.
        let pixel = try samplePixel(in: out, x: 30, y: 165)
        #expect(pixel.r < 90 && pixel.b < 90)
    }

    @Test func copyButtonCenterXOffsetMatchesLaidOutCopyButton() throws {
        try CCXL10n.withLanguageForTesting(.en) {
            for preset in [AnnotationToolbarPreset.snip, .pin] {
                let toolbar = AnnotationActionToolbar(preset: preset)
                toolbar.update(
                    activeTool: .select,
                    style: AnnotationStyle(),
                    showStyleBar: false,
                    canUndo: true,
                    canRedo: true
                )
                toolbar.layoutSubtreeIfNeeded()
                let copyButton = try #require(
                    toolbar.primaryStack.arrangedSubviews.first { ($0 as? NSButton)?.toolTip == "Copy (⌘C)" }
                )
                let frameInToolbar = copyButton.convert(copyButton.bounds, to: toolbar)
                #expect(abs(frameInToolbar.midX - AnnotationActionToolbar.copyButtonCenterXOffset(for: preset)) <= 2)
            }
        }
    }

    @Test func toolbarAnchorsNearPointerForCopyAcrossDirectionsAndInteriorFallback() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let topInset: CGFloat = 32
        let copyOffset = AnnotationActionToolbar.copyButtonCenterXOffset(for: .snip)

        // 1. Drag ending at bottom-right corner -> below selection with Copy centered at anchor.x.
        let lowerSelection = CGRect(x: 200, y: 300, width: 800, height: 300)
        let bottomRight = AnnotationActionToolbar.frame(
            for: lowerSelection,
            in: bounds,
            topInset: topInset,
            showsStyleBar: false,
            anchorPoint: CGPoint(x: 1000, y: 300)
        )
        #expect(bottomRight.maxY <= lowerSelection.minY)
        #expect(bottomRight.minX + copyOffset == 1000)

        // 2. Drag ending at top-right corner -> above selection with Copy centered at anchor.x.
        let midSelection = CGRect(x: 200, y: 400, width: 800, height: 300)
        let topRight = AnnotationActionToolbar.frame(
            for: midSelection,
            in: bounds,
            topInset: topInset,
            showsStyleBar: false,
            anchorPoint: CGPoint(x: 1000, y: 700)
        )
        #expect(topRight.minY >= midSelection.maxY)
        #expect(topRight.minX + copyOffset == 1000)

        // 3. Drag ending at top-left corner -> above selection clamped to minX == bounds.minX.
        let topLeft = AnnotationActionToolbar.frame(
            for: midSelection,
            in: bounds,
            topInset: topInset,
            showsStyleBar: false,
            anchorPoint: CGPoint(x: 200, y: 700)
        )
        #expect(topLeft.minY >= midSelection.maxY)
        #expect(topLeft.minX == bounds.minX)

        // 4. Drag ending at bottom-left corner -> below selection near anchor.x.
        let rightSelection = CGRect(x: 700, y: 300, width: 600, height: 300)
        let bottomLeft = AnnotationActionToolbar.frame(
            for: rightSelection,
            in: bounds,
            topInset: topInset,
            showsStyleBar: false,
            anchorPoint: CGPoint(x: 700, y: 300)
        )
        #expect(bottomLeft.maxY <= rightSelection.minY)
        #expect(bottomLeft.minX + copyOffset == 700)

        // 5. Tall bottom-edge selection with pointer at bottom-right stays inside near pointer instead of jumping 800pt up.
        let tallBottomSelection = CGRect(x: 200, y: 0, width: 800, height: 800)
        let tallBottom = AnnotationActionToolbar.frame(
            for: tallBottomSelection,
            in: bounds,
            topInset: topInset,
            showsStyleBar: false,
            anchorPoint: CGPoint(x: 1000, y: 0)
        )
        #expect(tallBottom.minY == 14)
        #expect(tallBottom.minX + copyOffset == 1000)

        // 6. Full-screen selection near center pointer places toolbar just below pointer and keeps primary top stationary when expanded.
        let centerCompact = AnnotationActionToolbar.frame(
            for: bounds,
            in: bounds,
            topInset: topInset,
            showsStyleBar: false,
            anchorPoint: CGPoint(x: 800, y: 500)
        )
        let centerExpanded = AnnotationActionToolbar.frame(
            for: bounds,
            in: bounds,
            topInset: topInset,
            showsStyleBar: true,
            anchorPoint: CGPoint(x: 800, y: 500)
        )
        #expect(centerCompact.maxY == 486)
        #expect(centerCompact.minX + copyOffset == 800)
        #expect(centerExpanded.maxY == 486)
        #expect(centerExpanded.minX + copyOffset == 800)
        #expect(centerExpanded.size == AnnotationActionToolbar.expandedSize(for: .snip))

        // 7. Non-finite anchorPoint falls back cleanly to finite in-bounds frame.
        for badAnchor in [CGPoint(x: CGFloat.nan, y: 500), CGPoint(x: 500, y: CGFloat.infinity)] {
            let safeFrame = AnnotationActionToolbar.frame(
                for: midSelection,
                in: bounds,
                topInset: topInset,
                showsStyleBar: false,
                anchorPoint: badAnchor
            )
            #expect(safeFrame.origin.x.isFinite && safeFrame.origin.y.isFinite)
            #expect(bounds.contains(safeFrame))
        }
    }
}
