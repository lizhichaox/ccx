import AppKit
import CoreGraphics
import Testing
@testable import CCXAnnotate

@Suite("CCXAnnotate")
@MainActor
struct CCXAnnotateTests {
    private func samplePixel(in image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let cropped = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (rgba[0], rgba[1], rgba[2])
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

        // Sweep more than 8 distinct mosaic strengths to exercise bounded LRU eviction.
        for i in 0...12 {
            let size = StrokeSize(progress: CGFloat(i) / 12.0)
            #expect(cache.filteredImage(mode: .pixelate, size: size, backingScale: 2) != nil)
            #expect(cache.filteredImage(mode: .blur, size: size, backingScale: 2) != nil)
        }
    }
}
