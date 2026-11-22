import AppKit
import CoreGraphics
import Testing
@testable import CPXAnnotate

@Suite("CPXAnnotate")
@MainActor
struct CPXAnnotateTests {
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

        let textItem = AnnotationItem(kind: .text(origin: CGPoint(x: 40, y: 120), content: "Hello CPX"), style: AnnotationStyle())
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
}
