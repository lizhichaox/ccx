import CoreGraphics
import CCXAnnotate
import CCXCore
import Testing
@testable import CCXCapture

@Suite("Snapshot cropping")
struct CropTests {
    /// 200x100 px image of a 100x50 pt screen (2x). The top half is red, the bottom half blue.
    private func makeSnapshot() throws -> DisplaySnapshot {
        let context = try #require(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 50)) // CG bottom = image bottom
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
        let image = try #require(context.makeImage())
        return DisplaySnapshot(
            displayID: 1,
            screenFrame: CGRect(x: -100, y: 200, width: 100, height: 50),
            backingScaleFactor: 2,
            image: image
        )
    }

    @Test func cropsExactBackingPixels() throws {
        let snapshot = try makeSnapshot()
        let topResult = try #require(SnipOverlayController.makeResult(localRect: CGRect(x: 10, y: 30, width: 20, height: 10), snapshot: snapshot))
        #expect(topResult.image.width == 40)
        #expect(topResult.image.height == 20)
        #expect(topResult.scale == 2)
        #expect(topResult.screenRect == CGRect(x: -90, y: 230, width: 20, height: 10))
        let topPixel = try #require(CCXColorSample.samplePixel(from: topResult.image, pixelX: 5, pixelY: 5))
        #expect(topPixel.red == 255 && topPixel.green == 0 && topPixel.blue == 0)

        let bottomResult = try #require(SnipOverlayController.makeResult(localRect: CGRect(x: 10, y: 5, width: 20, height: 10), snapshot: snapshot))
        let bottomPixel = try #require(CCXColorSample.samplePixel(from: bottomResult.image, pixelX: 5, pixelY: 5))
        #expect(bottomPixel.red == 0 && bottomPixel.green == 0 && bottomPixel.blue == 255)
    }

    @Test func degenerateRectYieldsNil() throws {
        let snapshot = try makeSnapshot()
        #expect(SnipOverlayController.makeResult(localRect: CGRect(x: 500, y: 500, width: 10, height: 10), snapshot: snapshot) == nil)
    }

    @Test @MainActor func bakesAnnotationsIntoFinalCropAtRetinaScale() throws {
        let snapshot = try makeSnapshot()
        let document = AnnotationDocument()
        document.commit(AnnotationItem(
            kind: .rectangle(CGRect(x: 10, y: 30, width: 20, height: 10)),
            style: AnnotationStyle(color: .green, size: .large)
        ))
        let result = try #require(SnipOverlayController.makeResult(
            localRect: CGRect(x: 10, y: 30, width: 20, height: 10),
            snapshot: snapshot,
            document: document,
            mosaicCache: nil
        ))
        #expect(result.image.width == 40 && result.image.height == 20)
        // Top-left border of selection should contain green pixels from the annotation instead of pure red.
        let borderPixel = try #require(CCXColorSample.samplePixel(from: result.image, pixelX: 0, pixelY: 10))
        #expect(borderPixel.green > 150)
    }

    @Test func smallCropDetachesFromFullDisplaySnapshotBufferAndPreservesPixels() throws {
        let snapshot = try makeSnapshot()
        let smallResult = try #require(SnipOverlayController.makeResult(
            localRect: CGRect(x: 10, y: 30, width: 20, height: 10),
            snapshot: snapshot
        ))
        // Detached crop must not share the full display snapshot's underlying CGDataProvider buffer.
        #expect(smallResult.image.dataProvider !== snapshot.image.dataProvider)
        #expect(smallResult.image.bytesPerRow < snapshot.image.bytesPerRow)
        let sampled = try #require(CCXColorSample.samplePixel(from: smallResult.image, pixelX: 5, pixelY: 5))
        #expect(sampled.red == 255 && sampled.green == 0 && sampled.blue == 0)

        // Forced detach (used for ScrollCaptureRequest.initialImage) detaches even full-screen selections.
        let fullDetached = try #require(SnipOverlayController.makeResult(
            localRect: CGRect(x: 0, y: 0, width: 100, height: 50),
            snapshot: snapshot,
            detachFromSnapshot: true
        ))
        #expect(fullDetached.image.dataProvider !== snapshot.image.dataProvider)
        #expect(fullDetached.image.width == 200 && fullDetached.image.height == 100)
        let topPx = try #require(CCXColorSample.samplePixel(from: fullDetached.image, pixelX: 10, pixelY: 10))
        let bottomPx = try #require(CCXColorSample.samplePixel(from: fullDetached.image, pixelX: 10, pixelY: 90))
        #expect(topPx.red == 255 && bottomPx.blue == 255)

        // ScreenSnapshotEngine clampedPixelDimension guards huge finite CGFloat values without trapping.
        #expect(ScreenSnapshotEngine.clampedPixelDimension(1e30, minimum: 1) == 16_384)
        #expect(ScreenSnapshotEngine.clampedPixelDimension(1e30, minimum: 2) == 16_384)
        #expect(ScreenSnapshotEngine.clampedPixelDimension(.nan, minimum: 1) == nil)
        #expect(ScreenSnapshotEngine.clampedPixelDimension(.infinity, minimum: 1) == nil)
        #expect(ScreenSnapshotEngine.clampedPixelDimension(1, minimum: 2) == nil)
    }
}
