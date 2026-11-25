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
}
