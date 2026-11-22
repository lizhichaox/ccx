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

    @Test func handlesFixedLeftSidebarRightTOCAndRoundedCornersWithoutArtifacts() throws {
        let width = 480
        let viewportH = 380
        let leftWidth = 84
        let rightWidth = 72
        let topBarH = 44
        let footerH = 36
        let cornerSize = 14
        let shifts = [0, 85, 175, 270]
        let docHeight = shifts.last! + viewportH
        let centerDoc = try renderSyntheticDocument(width: width, height: docHeight, blankRange: 170..<220)
        let centerBuf = try #require(ScrollFrameBuffer(cgImage: centerDoc))

        // Build clean fixed chrome bytes.
        let topBytes = makeTexturedBarBytes(width: width, height: topBarH, seed: 5)
        let footerBytes = makeTexturedBarBytes(width: width, height: footerH, seed: 9)

        func makeViewportFrame(offset: Int, stepIndex: Int) throws -> CGImage {
            var bytes = [UInt8](repeating: 255, count: width * viewportH * 4)
            let rowBytes = width * 4

            centerBuf.bgraData.withUnsafeBytes { raw in
                let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<viewportH {
                    let srcRow = (offset + y) * centerBuf.bytesPerRow
                    let dstRow = y * rowBytes
                    for x in leftWidth..<(width - rightWidth) {
                        let sPx = srcRow + x * 4
                        let dPx = dstRow + x * 4
                        bytes[dPx] = src[sPx]
                        bytes[dPx + 1] = src[sPx + 1]
                        bytes[dPx + 2] = src[sPx + 2]
                        bytes[dPx + 3] = 255
                    }
                }
            }

            // Left sidebar (#F5F6F8 = BGR 248, 246, 245) + textured nav pills + 1px #D0D4DA divider at x=83.
            for y in 0..<viewportH {
                let row = y * rowBytes
                let inNavPill = (y % 28 >= 8 && y % 28 < 18) && y >= topBarH && y < viewportH - footerH
                for x in 0..<leftWidth {
                    let px = row + x * 4
                    if x == leftWidth - 1 {
                        bytes[px] = 218; bytes[px + 1] = 212; bytes[px + 2] = 208; bytes[px + 3] = 255
                    } else if inNavPill && x >= 14 && x < 68 {
                        let ink: UInt8 = ((x / 5 + y / 3) % 2 == 0) ? 70 : 190
                        bytes[px] = ink; bytes[px + 1] = ink; bytes[px + 2] = ink; bytes[px + 3] = 255
                    } else {
                        bytes[px] = 248; bytes[px + 1] = 246; bytes[px + 2] = 245; bytes[px + 3] = 255
                    }
                }
            }

            // Right TOC sidebar (#FFFFFF background + 1px divider + static items + subtle moving ScrollSpy pill).
            let tocStart = width - rightWidth
            let spyBandY = 92 + stepIndex * 18
            for y in 0..<viewportH {
                let row = y * rowBytes
                let inTocItem = (y >= topBarH + 16 && y <= 230) && (y % 20 >= 6 && y % 20 < 13)
                let inSpy = (y >= spyBandY && y < spyBandY + 12)
                for x in tocStart..<width {
                    let px = row + x * 4
                    if x == tocStart {
                        bytes[px] = 224; bytes[px + 1] = 220; bytes[px + 2] = 216; bytes[px + 3] = 255
                    } else if inSpy && x >= tocStart + 8 && x < tocStart + 11 {
                        bytes[px] = 16; bytes[px + 1] = 16; bytes[px + 2] = 16; bytes[px + 3] = 255
                    } else if inTocItem && x >= tocStart + 14 && x < width - 26 {
                        let ink: UInt8 = ((x / 4 + y / 2) % 2 == 0) ? 85 : 215
                        bytes[px] = ink; bytes[px + 1] = ink; bytes[px + 2] = ink; bytes[px + 3] = 255
                    } else {
                        bytes[px] = 255; bytes[px + 1] = 255; bytes[px + 2] = 255; bytes[px + 3] = 255
                    }
                }
            }

            // Static textured top navbar and bottom footer.
            bytes.replaceSubrange(0..<(topBarH * rowBytes), with: topBytes)
            let footerStartByte = (viewportH - footerH) * rowBytes
            bytes.replaceSubrange(footerStartByte..<(viewportH * rowBytes), with: footerBytes)

            // Moving right-edge overlay scrollbar.
            let thumbY = 60 + stepIndex * 50
            for y in thumbY..<min(viewportH - footerH, thumbY + 42) {
                for x in (width - 8)..<width {
                    let px = y * rowBytes + x * 4
                    bytes[px] = 80; bytes[px + 1] = 80; bytes[px + 2] = 80; bytes[px + 3] = 255
                }
            }

            // Rounded black bottom window corners stamped at bottom-left and bottom-right.
            for dy in 0..<cornerSize {
                let y = viewportH - cornerSize + dy
                for dx in 0...dy {
                    let bl = y * rowBytes + dx * 4
                    bytes[bl] = 0; bytes[bl + 1] = 0; bytes[bl + 2] = 0; bytes[bl + 3] = 255
                    let br = y * rowBytes + (width - 1 - dx) * 4
                    bytes[br] = 0; bytes[br + 1] = 0; bytes[br + 2] = 0; bytes[br + 3] = 255
                }
            }

            let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
            return try #require(CGImage(
                width: width,
                height: viewportH,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ))
        }

        let stitcher = ScrollImageStitcher(scale: 2)
        for (idx, offset) in shifts.enumerated() {
            let frameImg = try makeViewportFrame(offset: offset, stepIndex: idx)
            #expect(stitcher.append(try #require(ScrollFrameBuffer(cgImage: frameImg))))
        }

        #expect((76...94).contains(stitcher.detectedStickyLeft))
        #expect((64...88).contains(stitcher.detectedStickyRight))
        #expect(stitcher.detectedStickyTop >= topBarH)
        #expect(stitcher.detectedStickyBottom >= footerH)
        #expect(stitcher.totalStitchedHeight == docHeight)

        let final = try #require(stitcher.buildFinalImage())
        let finalBuf = try #require(ScrollFrameBuffer(cgImage: final))

        // Verify center scrolling columns match `centerDoc` pixel-for-pixel across `[topBarH, docHeight - footerH)`.
        finalBuf.bgraData.withUnsafeBytes { fRaw in
            centerBuf.bgraData.withUnsafeBytes { cRaw in
                let fPtr = fRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let cPtr = cRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in topBarH..<(docHeight - footerH - 12) {
                    let fRow = y * finalBuf.bytesPerRow
                    let cRow = y * centerBuf.bytesPerRow
                    for x in (leftWidth + 8)..<(width - rightWidth - 8) {
                        let fp = fRow + x * 4
                        let cp = cRow + x * 4
                        #expect(fPtr[fp] == cPtr[cp])
                        #expect(fPtr[fp + 1] == cPtr[cp + 1])
                        #expect(fPtr[fp + 2] == cPtr[cp + 2])
                    }
                }

                // Verify extended left sidebar (rows 380 ..< docHeight - 48) is clean #F5F6F8 background
                // with preserved 1px #D0D4DA divider at x=83, and zero black corner notches in seams.
                for y in viewportH..<(docHeight - 48) {
                    let row = y * finalBuf.bytesPerRow
                    for x in 12..<76 {
                        let px = row + x * 4
                        #expect(fPtr[px] == 248 && fPtr[px + 1] == 246 && fPtr[px + 2] == 245)
                    }
                    let divPx = row + (leftWidth - 1) * 4
                    #expect(fPtr[divPx] == 218 && fPtr[divPx + 1] == 212 && fPtr[divPx + 2] == 208)

                    let blCheck = row + 2 * 4
                    #expect(fPtr[blCheck] > 200)
                    let brCheck = row + (width - 2) * 4
                    #expect(fPtr[brCheck] > 200)
                }
            }
        }
    }

    @Test func handlesRoundedWindowCornersWithoutStickyFooter() throws {
        let width = 360
        let viewportH = 320
        let cornerSize = 16
        let shifts = [0, 90, 185, 280]
        let docHeight = shifts.last! + viewportH
        let doc = try renderSyntheticDocument(width: width, height: docHeight)
        let docBuf = try #require(ScrollFrameBuffer(cgImage: doc))

        let stitcher = ScrollImageStitcher(scale: 2)
        for offset in shifts {
            let cropped = try #require(doc.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewportH)))
            let buf = try #require(ScrollFrameBuffer(cgImage: cropped))
            var data = [UInt8](buf.bgraData)
            let rowBytes = buf.bytesPerRow
            for dy in 0..<cornerSize {
                let y = viewportH - cornerSize + dy
                for dx in 0...dy {
                    let bl = y * rowBytes + dx * 4
                    data[bl] = 0; data[bl + 1] = 0; data[bl + 2] = 0; data[bl + 3] = 255
                    let br = y * rowBytes + (width - 1 - dx) * 4
                    data[br] = 0; data[br + 1] = 0; data[br + 2] = 0; data[br + 3] = 255
                }
            }
            let provider = try #require(CGDataProvider(data: Data(data) as CFData))
            let img = try #require(CGImage(
                width: width,
                height: viewportH,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ))
            #expect(stitcher.append(try #require(ScrollFrameBuffer(cgImage: img))))
        }

        #expect(stitcher.detectedStickyBottom == 0)
        #expect(stitcher.totalStitchedHeight == docHeight)
        let final = try #require(stitcher.buildFinalImage())
        let finalBuf = try #require(ScrollFrameBuffer(cgImage: final))

        // Interior center matches ground truth cleanly, and no black corner notches exist above the final 48px.
        finalBuf.bgraData.withUnsafeBytes { fRaw in
            docBuf.bgraData.withUnsafeBytes { dRaw in
                let fPtr = fRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let dPtr = dRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<(docHeight - 48) {
                    let fRow = y * finalBuf.bytesPerRow
                    let dRow = y * docBuf.bytesPerRow
                    for x in 24..<(width - 24) {
                        let fp = fRow + x * 4
                        let dp = dRow + x * 4
                        #expect(fPtr[fp] == dPtr[dp] && fPtr[fp + 1] == dPtr[dp + 1] && fPtr[fp + 2] == dPtr[dp + 2])
                    }
                    // Extreme bottom-left/bottom-right pixels in intermediate seams must not be stamped black (0,0,0).
                    let edgeL = fRow + 1 * 4
                    let edgeR = fRow + (width - 2) * 4
                    let nonBlackL = fPtr[edgeL] > 10 || fPtr[edgeL + 1] > 10 || fPtr[edgeL + 2] > 10
                    let nonBlackR = fPtr[edgeR] > 10 || fPtr[edgeR + 1] > 10 || fPtr[edgeR + 2] > 10
                    #expect(nonBlackL)
                    #expect(nonBlackR)
                }
            }
        }
    }
}
