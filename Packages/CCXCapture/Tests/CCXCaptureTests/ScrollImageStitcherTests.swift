import CoreGraphics
import Foundation
import Testing
@testable import CCXCapture

@Suite("ScrollImageStitcher")
struct ScrollImageStitcherTests {
    /// Generates a deterministic full-document image with rich high-contrast horizontal and vertical texture
    /// per row, optional sticky top/bottom bars, optional blank region, and optional right-margin scrollbar.
    private func renderSyntheticDocument(
        width: Int,
        height: Int,
        stickyTop: Int = 0,
        stickyBottom: Int = 0,
        blankRange: Range<Int>? = nil
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let inBlank = blankRange?.contains(y) ?? false
            for x in 0..<width {
                let idx = (y * width + x) * 4
                if inBlank {
                    bytes[idx] = 248
                    bytes[idx + 1] = 248
                    bytes[idx + 2] = 248
                    bytes[idx + 3] = 255
                    continue
                }
                // Deterministic pseudo-random textured pattern unique to doc row `y`.
                let block = y / 18
                let stripe = (x / 11 + y / 7 + (block * 7)) % 5
                let r: UInt8
                let g: UInt8
                let b: UInt8
                if stripe == 0 && x % 19 < 11 {
                    r = UInt8((y * 37 + x * 13) & 0xFF)
                    g = UInt8((y * 53 + block * 29) & 0xFF)
                    b = UInt8((y * 97 + x * 7) & 0xFF)
                } else {
                    let base = UInt8(180 + ((y * 3 + x) % 60))
                    r = base
                    g = base &- UInt8((y % 13) * 3)
                    b = 240
                }
                bytes[idx] = b
                bytes[idx + 1] = g
                bytes[idx + 2] = r
                bytes[idx + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    /// Extracts one viewport slice `[scrollY, scrollY + viewportHeight)` optionally compositing
    /// textured static navbar/footer chrome and an independent scrollbar in the right margin.
    private func renderViewport(
        from document: CGImage,
        scrollY: Int,
        viewportHeight: Int,
        stickyHeader: [UInt8]? = nil,
        stickyTop: Int = 0,
        stickyFooter: [UInt8]? = nil,
        stickyBottom: Int = 0,
        scrollbarThumbY: Int? = nil
    ) throws -> CGImage {
        let width = document.width
        let cropped = try #require(document.cropping(to: CGRect(x: 0, y: scrollY, width: width, height: viewportHeight)))
        guard let buf = ScrollFrameBuffer(cgImage: cropped) else {
            throw NSError(domain: "ScrollTest", code: 1)
        }
        var data = [UInt8](buf.bgraData)
        let bytesPerRow = buf.bytesPerRow

        if let stickyHeader, stickyTop > 0 {
            let count = stickyTop * bytesPerRow
            data.replaceSubrange(0..<count, with: stickyHeader.prefix(count))
        }
        if let stickyFooter, stickyBottom > 0 {
            let start = (viewportHeight - stickyBottom) * bytesPerRow
            let count = stickyBottom * bytesPerRow
            data.replaceSubrange(start..<(start + count), with: stickyFooter.prefix(count))
        }
        if let thumbY = scrollbarThumbY {
            let barXStart = max(0, width - 10)
            let barXEnd = max(barXStart, width - 3)
            for y in max(0, thumbY)..<min(viewportHeight, thumbY + 42) {
                for x in barXStart..<barXEnd {
                    let i = y * bytesPerRow + x * 4
                    data[i] = 90
                    data[i + 1] = 90
                    data[i + 2] = 95
                    data[i + 3] = 255
                }
            }
        }

        let provider = try #require(CGDataProvider(data: Data(data) as CFData))
        return try #require(CGImage(
            width: width,
            height: viewportHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeTexturedBarBytes(width: Int, height: Int, seed: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let cell = ((x / 10) + (y / 4) + seed) % 2 == 0
                bytes[i] = cell ? 45 : 225
                bytes[i + 1] = cell ? 185 : 65
                bytes[i + 2] = cell ? 235 : 30
                bytes[i + 3] = 255
            }
        }
        return bytes
    }

    private func maxPixelChannelDiff(_ a: CGImage, _ b: CGImage, ignoringRightMargin: Int = 0) throws -> Int {
        #expect(a.width == b.width)
        #expect(a.height == b.height)
        let bufA = try #require(ScrollFrameBuffer(cgImage: a))
        let bufB = try #require(ScrollFrameBuffer(cgImage: b))
        var maxDiff = 0
        let inspectWidth = max(1, a.width - ignoringRightMargin)
        bufA.bgraData.withUnsafeBytes { rawA in
            bufB.bgraData.withUnsafeBytes { rawB in
                let ptrA = rawA.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ptrB = rawB.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<a.height {
                    let rowBase = y * bufA.bytesPerRow
                    for x in 0..<inspectWidth {
                        let px = rowBase + x * 4
                        maxDiff = max(maxDiff, abs(Int(ptrA[px]) - Int(ptrB[px])))
                        maxDiff = max(maxDiff, abs(Int(ptrA[px + 1]) - Int(ptrB[px + 1])))
                        maxDiff = max(maxDiff, abs(Int(ptrA[px + 2]) - Int(ptrB[px + 2])))
                    }
                }
            }
        }
        return maxDiff
    }

    @Test func stitchesPureVerticalScrollSequencePixelExactly() throws {
        let width = 320
        let viewportH = 300
        let shifts = [0, 85, 210, 345, 510]
        let docHeight = shifts.last! + viewportH
        let doc = try renderSyntheticDocument(width: width, height: docHeight)

        let stitcher = ScrollImageStitcher(scale: 2)
        for offset in shifts {
            let frameImg = try renderViewport(from: doc, scrollY: offset, viewportHeight: viewportH)
            let frame = try #require(ScrollFrameBuffer(cgImage: frameImg))
            let accepted = stitcher.append(frame)
            #expect(accepted)
        }

        #expect(stitcher.stitchedFrameCount == shifts.count)
        #expect(stitcher.totalStitchedHeight == docHeight)
        let final = try #require(stitcher.buildFinalImage())
        #expect(final.width == width)
        #expect(final.height == docHeight)
        #expect(try maxPixelChannelDiff(final, doc) == 0)
    }

    @Test func ignoresDuplicateAndUpwardScrollFrames() throws {
        let width = 300
        let viewportH = 260
        let doc = try renderSyntheticDocument(width: width, height: 800)

        let stitcher = ScrollImageStitcher(scale: 2)
        let f0 = try #require(ScrollFrameBuffer(cgImage: try renderViewport(from: doc, scrollY: 0, viewportHeight: viewportH)))
        let f1 = try #require(ScrollFrameBuffer(cgImage: try renderViewport(from: doc, scrollY: 120, viewportHeight: viewportH)))
        let fUp = try #require(ScrollFrameBuffer(cgImage: try renderViewport(from: doc, scrollY: 60, viewportHeight: viewportH)))
        let f2 = try #require(ScrollFrameBuffer(cgImage: try renderViewport(from: doc, scrollY: 230, viewportHeight: viewportH)))

        #expect(stitcher.append(f0))
        #expect(stitcher.append(f1))
        // Identical duplicate frame -> ignored.
        #expect(stitcher.append(f1) == false)
        // Upward scroll -> ignored (does not corrupt frontier).
        #expect(stitcher.append(fUp) == false)
        // Resuming downward continues seamlessly from f1.
        #expect(stitcher.append(f2))

        let expectedHeight = viewportH + 230
        #expect(stitcher.stitchedFrameCount == 3)
        #expect(stitcher.totalStitchedHeight == expectedHeight)
        let final = try #require(stitcher.buildFinalImage())
        let expectedDoc = try #require(doc.cropping(to: CGRect(x: 0, y: 0, width: width, height: expectedHeight)))
        #expect(try maxPixelChannelDiff(final, expectedDoc) == 0)
    }

    @Test func handlesStickyHeaderAndStickyFooterWithoutDuplication() throws {
        let width = 360
        let viewportH = 360
        let stickyTop = 48
        let stickyBottom = 40
        let headerBytes = makeTexturedBarBytes(width: width, height: stickyTop, seed: 3)
        let footerBytes = makeTexturedBarBytes(width: width, height: stickyBottom, seed: 11)
        let doc = try renderSyntheticDocument(width: width, height: 1100)

        let stitcher = ScrollImageStitcher(scale: 2)
        let offsets = [0, 90, 210, 320]
        for offset in offsets {
            let img = try renderViewport(
                from: doc,
                scrollY: offset,
                viewportHeight: viewportH,
                stickyHeader: headerBytes,
                stickyTop: stickyTop,
                stickyFooter: footerBytes,
                stickyBottom: stickyBottom
            )
            let buf = try #require(ScrollFrameBuffer(cgImage: img))
            #expect(stitcher.append(buf))
        }

        #expect(stitcher.detectedStickyTop >= stickyTop)
        #expect(stitcher.detectedStickyBottom >= stickyBottom)
        let expectedTotalHeight = viewportH + offsets.last!
        #expect(stitcher.totalStitchedHeight == expectedTotalHeight)
        let final = try #require(stitcher.buildFinalImage())
        #expect(final.height == expectedTotalHeight)
    }

    @Test func handlesMovingScrollbarInRightMargin() throws {
        let width = 360
        let viewportH = 300
        let shifts = [0, 75, 165, 255]
        let thumbPositions = [10, 65, 130, 195]
        let docHeight = shifts.last! + viewportH
        let doc = try renderSyntheticDocument(width: width, height: docHeight)

        let stitcher = ScrollImageStitcher(scale: 2)
        for (offset, thumbY) in zip(shifts, thumbPositions) {
            let img = try renderViewport(
                from: doc,
                scrollY: offset,
                viewportHeight: viewportH,
                scrollbarThumbY: thumbY
            )
            let buf = try #require(ScrollFrameBuffer(cgImage: img))
            #expect(stitcher.append(buf))
        }

        #expect(stitcher.totalStitchedHeight == docHeight)
        let final = try #require(stitcher.buildFinalImage())
        #expect(try maxPixelChannelDiff(final, doc, ignoringRightMargin: 36) == 0)
    }

    @Test func handlesBlankGapAndEnforcesMaxHeightCap() throws {
        let width = 320
        let viewportH = 300
        let doc = try renderSyntheticDocument(width: width, height: 1000, blankRange: 140..<280)

        let stitcher = ScrollImageStitcher(scale: 2, maxTotalHeight: 520)
        // Step across the blank gap using textured regions outside 140..<280.
        for offset in [0, 95, 185, 310] {
            let img = try renderViewport(from: doc, scrollY: offset, viewportHeight: viewportH)
            let buf = try #require(ScrollFrameBuffer(cgImage: img))
            stitcher.append(buf)
        }

        #expect(stitcher.isAtHeightLimit)
        #expect(stitcher.totalStitchedHeight == 520)
        let final = try #require(stitcher.buildFinalImage())
        #expect(final.height == 520)
    }

    @Test func buildsCompactPreviewImageWithinBounds() throws {
        let width = 400
        let viewportH = 300
        let doc = try renderSyntheticDocument(width: width, height: 1500)
        let stitcher = ScrollImageStitcher(scale: 2)
        for offset in stride(from: 0, through: 900, by: 150) {
            let img = try renderViewport(from: doc, scrollY: offset, viewportHeight: viewportH)
            stitcher.append(try #require(ScrollFrameBuffer(cgImage: img)))
        }
        let preview = try #require(stitcher.buildPreviewImage(maxWidth: 180, maxHeight: 520))
        #expect(preview.width <= 180)
        #expect(preview.height <= 520)
    }
}
