import CoreGraphics
import CoreVideo
import Foundation

/// Canonical `32BGRA` (little-endian `[B, G, R, X]`) frame buffer with precomputed horizontal
/// row signatures and gradient energy for fast, low-allocation vertical scroll stitching.
public struct ScrollFrameBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bgraData: Data
    public let colorSpaceName: String?
    public let iccProfileData: Data?

    let marginLeft: Int
    let marginRight: Int
    let signatureWidth: Int
    /// Flattened `height * signatureWidth` 8-bit luma samples in top-down row order.
    let rowSignatures: [UInt8]
    /// Horizontal luma gradient energy per row across `signatureWidth` interior samples.
    let rowEnergy: [Int32]
    /// Combined horizontal + vertical luma contrast per row across interior samples.
    let rowContrast: [Int32]

    private static let signatureSampleLimit = 64

    /// Canonical bitmap info matching `kCVPixelFormatType_32BGRA` on Apple Silicon.
    nonisolated static var canonicalBitmapInfo: CGBitmapInfo {
        CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    }

    /// Initializes a canonical buffer directly from a ScreenCaptureKit `kCVPixelFormatType_32BGRA`
    /// `CVPixelBuffer`, releasing the read-only pixel buffer lock before returning.
    public init?(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width >= 4, height >= 8 else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }

        let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockResult == kCVReturnSuccess, let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstBytesPerRow = width * 4
        guard srcBytesPerRow >= dstBytesPerRow else { return nil }

        var data = Data(count: dstBytesPerRow * height)
        data.withUnsafeMutableBytes { dstRaw in
            guard let dstPtr = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
            if srcBytesPerRow == dstBytesPerRow {
                dstPtr.update(from: srcPtr, count: dstBytesPerRow * height)
            } else {
                for y in 0..<height {
                    dstPtr.advanced(by: y * dstBytesPerRow)
                        .update(from: srcPtr.advanced(by: y * srcBytesPerRow), count: dstBytesPerRow)
                }
            }
        }

        let attachedCS = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, nil)
        let cgCS: CGColorSpace? = attachedCS.flatMap { raw in
            CFGetTypeID(raw) == CGColorSpace.typeID ? unsafeDowncast(raw, to: CGColorSpace.self) : nil
        }

        self.init(
            width: width,
            height: height,
            bytesPerRow: dstBytesPerRow,
            bgraData: data,
            colorSpaceName: cgCS?.name as String?,
            iccProfileData: cgCS?.name == nil ? (cgCS?.copyICCData() as Data?) : nil
        )
    }

    /// Renders `cgImage` into the canonical `32BGRA` layout used at runtime by `SCStream`.
    public init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 4, height >= 8 else { return nil }

        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let sourceCS = cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!

        let rendered: Bool = data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress,
                  let context = CGContext(
                      data: ptr,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: sourceCS,
                      bitmapInfo: Self.canonicalBitmapInfo.rawValue
                  )
            else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        self.init(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bgraData: data,
            colorSpaceName: sourceCS.name as String?,
            iccProfileData: sourceCS.name == nil ? (sourceCS.copyICCData() as Data?) : nil
        )
    }

    private init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bgraData: Data,
        colorSpaceName: String?,
        iccProfileData: Data?
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bgraData = bgraData
        self.colorSpaceName = colorSpaceName
        self.iccProfileData = iccProfileData

        // Exclude window chrome/overlay scrollbars along edges when wide enough.
        let mLeft = width >= 120 ? min(24, width / 12) : 0
        let mRight = width >= 120 ? min(36, width / 8) : 0
        self.marginLeft = mLeft
        self.marginRight = mRight

        let interiorWidth = max(1, width - mLeft - mRight)
        let sigWidth = min(Self.signatureSampleLimit, interiorWidth)
        self.signatureWidth = sigWidth

        var sampleOffsets = [Int](repeating: 0, count: sigWidth)
        for i in 0..<sigWidth {
            let col = mLeft + (i * interiorWidth) / sigWidth
            sampleOffsets[i] = min(max(col, 0), width - 1) * 4
        }

        var signatures = [UInt8](repeating: 0, count: height * sigWidth)
        var horizEnergies = [Int32](repeating: 0, count: height)
        var combinedContrast = [Int32](repeating: 0, count: height)

        bgraData.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var prevRowFirstOffset = 0
            for y in 0..<height {
                let rowBase = y * bytesPerRow
                let sigBase = y * sigWidth
                var prevLuma = 0
                var hEnergy: Int32 = 0
                var vEnergy: Int32 = 0
                for i in 0..<sigWidth {
                    let px = rowBase + sampleOffsets[i]
                    let b = Int(ptr[px])
                    let g = Int(ptr[px + 1])
                    let r = Int(ptr[px + 2])
                    let luma = (77 * r + 150 * g + 29 * b) >> 8
                    let lumaByte = UInt8(clamping: luma)
                    signatures[sigBase + i] = lumaByte
                    if i > 0 {
                        hEnergy += Int32(abs(luma - prevLuma))
                    }
                    if y > 0 {
                        vEnergy += Int32(abs(luma - Int(signatures[prevRowFirstOffset + i])))
                    }
                    prevLuma = luma
                }
                horizEnergies[y] = hEnergy
                combinedContrast[y] = hEnergy + vEnergy
                prevRowFirstOffset = sigBase
            }
        }

        self.rowSignatures = signatures
        self.rowEnergy = horizEnergies
        self.rowContrast = combinedContrast
    }

    func resolvedColorSpace() -> CGColorSpace {
        if let colorSpaceName, let cs = CGColorSpace(name: colorSpaceName as CFString) {
            return cs
        }
        if let iccProfileData, let cs = CGColorSpace(iccData: iccProfileData as CFData) {
            return cs
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Creates a compact `CGImage` containing only rows `[yStart, yStart + sliceHeight)`.
    public func cropCGImage(yStart: Int, height sliceHeight: Int) -> CGImage? {
        guard sliceHeight > 0, yStart >= 0, yStart + sliceHeight <= height else { return nil }
        let byteStart = yStart * bytesPerRow
        let byteEnd = (yStart + sliceHeight) * bytesPerRow
        guard byteEnd <= bgraData.count else { return nil }
        let sliceData = bgraData.subdata(in: byteStart..<byteEnd)
        guard let provider = CGDataProvider(data: sliceData as CFData) else { return nil }
        return CGImage(
            width: width,
            height: sliceHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: resolvedColorSpace(),
            bitmapInfo: Self.canonicalBitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Verified downward vertical displacement (`dy > 0`) between two scroll frames.
public struct ScrollMatchResult: Equatable, Sendable {
    public let dy: Int
    public let mad: Double

    public init(dy: Int, mad: Double) {
        self.dy = dy
        self.mad = mad
    }
}

/// Static header/footer thickness detected across two frames.
public struct ScrollStickyBounds: Equatable, Sendable {
    public let stickyTop: Int
    public let stickyBottom: Int
    public let isIdenticalFrame: Bool

    public init(stickyTop: Int, stickyBottom: Int, isIdenticalFrame: Bool) {
        self.stickyTop = stickyTop
        self.stickyBottom = stickyBottom
        self.isIdenticalFrame = isIdenticalFrame
    }
}

/// Incremental, sticky-bar-aware vertical scroll stitcher storing only newly revealed strip slices.
public final class ScrollImageStitcher {
    public let maxTotalHeight: Int
    public let maxAllowedMAD: Double

    public private(set) var width: Int = 0
    public private(set) var scale: CGFloat
    public private(set) var stitchedFrameCount: Int = 0
    public private(set) var isAtHeightLimit: Bool = false
    public private(set) var detectedStickyTop: Int = 0
    public private(set) var detectedStickyBottom: Int = 0

    private var initialFrame: ScrollFrameBuffer?
    private var frontierFrame: ScrollFrameBuffer?
    private var committedSlices: [CGImage] = []
    private var currentSlicesHeight: Int = 0
    private var latestStickyFooter: CGImage?
    private var lockedFooterHeight: Int = 0

    public var totalStitchedHeight: Int {
        if committedSlices.isEmpty {
            return initialFrame?.height ?? 0
        }
        return currentSlicesHeight + (latestStickyFooter?.height ?? 0)
    }

    public init(
        scale: CGFloat = 2.0,
        maxTotalHeight: Int = 32_000,
        maxAllowedMAD: Double = 8.5
    ) {
        self.scale = max(1, scale)
        self.maxTotalHeight = max(128, maxTotalHeight)
        self.maxAllowedMAD = max(0.5, maxAllowedMAD)
    }

    public func seed(_ frame: ScrollFrameBuffer) {
        width = frame.width
        initialFrame = frame
        frontierFrame = frame
        committedSlices.removeAll()
        currentSlicesHeight = 0
        latestStickyFooter = nil
        detectedStickyTop = 0
        detectedStickyBottom = 0
        lockedFooterHeight = 0
        stitchedFrameCount = 1
        isAtHeightLimit = frame.height >= maxTotalHeight
    }

    /// Processes the next frame in sequence. Returns `true` when new content was appended.
    @discardableResult
    public func append(_ frame: ScrollFrameBuffer) -> Bool {
        guard !isAtHeightLimit else { return false }
        guard let frontier = frontierFrame else {
            seed(frame)
            return true
        }
        guard frame.width == frontier.width, frame.height == frontier.height else { return false }
        let frameHeight = frame.height

        let sticky = Self.detectStickyBounds(previous: frontier, current: frame)
        if sticky.isIdenticalFrame {
            return false
        }

        if committedSlices.isEmpty {
            let matchTop = sticky.stickyTop
            let matchBottom = frameHeight - sticky.stickyBottom
            guard let match = Self.estimateVerticalShift(
                previous: frontier,
                current: frame,
                dynamicTop: matchTop,
                dynamicBottom: matchBottom,
                maxAllowedMAD: maxAllowedMAD
            ) else {
                return false
            }

            detectedStickyTop = sticky.stickyTop
            detectedStickyBottom = sticky.stickyBottom
            lockedFooterHeight = sticky.stickyBottom

            let commitBottom = frameHeight - lockedFooterHeight
            let baseHeight = min(commitBottom, maxTotalHeight - lockedFooterHeight)
            guard baseHeight > 0, let baseSlice = frontier.cropCGImage(yStart: 0, height: baseHeight) else {
                return false
            }
            committedSlices.append(baseSlice)
            currentSlicesHeight = baseSlice.height

            let remaining = maxTotalHeight - currentSlicesHeight - lockedFooterHeight
            let allowedDy = min(match.dy, remaining)
            if allowedDy > 0,
               commitBottom - allowedDy >= detectedStickyTop,
               let nextSlice = frame.cropCGImage(yStart: commitBottom - allowedDy, height: allowedDy) {
                committedSlices.append(nextSlice)
                currentSlicesHeight += nextSlice.height
            }

            if lockedFooterHeight > 0 {
                latestStickyFooter = frame.cropCGImage(yStart: commitBottom, height: lockedFooterHeight)
            }
            frontierFrame = frame
            stitchedFrameCount += 1
            if totalStitchedHeight >= maxTotalHeight || allowedDy < match.dy {
                isAtHeightLimit = true
            }
            return true
        }

        // Handle sticky bars that lock into place mid-scroll during matching while keeping
        // the slice join boundary anchored at `lockedFooterHeight`.
        let matchTop = max(detectedStickyTop, sticky.stickyTop)
        let matchBottom = frameHeight - max(lockedFooterHeight, sticky.stickyBottom)
        guard let match = Self.estimateVerticalShift(
            previous: frontier,
            current: frame,
            dynamicTop: matchTop,
            dynamicBottom: matchBottom,
            maxAllowedMAD: maxAllowedMAD
        ) else {
            return false
        }

        let commitBottom = frameHeight - lockedFooterHeight
        let remaining = maxTotalHeight - currentSlicesHeight - lockedFooterHeight
        let allowedDy = min(match.dy, remaining)
        guard allowedDy > 0 else {
            isAtHeightLimit = true
            return false
        }

        let sliceStart = max(0, commitBottom - allowedDy)
        let sliceHeight = commitBottom - sliceStart
        guard sliceHeight > 0, let slice = frame.cropCGImage(yStart: sliceStart, height: sliceHeight) else {
            return false
        }
        committedSlices.append(slice)
        currentSlicesHeight += slice.height

        if lockedFooterHeight > 0,
           let footer = frame.cropCGImage(yStart: commitBottom, height: lockedFooterHeight) {
            latestStickyFooter = footer
        }

        frontierFrame = frame
        stitchedFrameCount += 1
        if totalStitchedHeight >= maxTotalHeight || allowedDy < match.dy {
            isAtHeightLimit = true
        }
        return true
    }

    /// Composites all committed slices into a single tall `CGImage` preserving full resolution.
    public func buildFinalImage() -> CGImage? {
        guard let initial = initialFrame else { return nil }
        if committedSlices.isEmpty {
            return initial.cropCGImage(yStart: 0, height: initial.height)
        }

        let totalHeight = totalStitchedHeight
        guard width > 0, totalHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: initial.resolvedColorSpace(),
            bitmapInfo: ScrollFrameBuffer.canonicalBitmapInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .none

        // CoreGraphics origin is bottom-left (`y = 0` at bottom of stitched output).
        var cursorTopFromImageTop = 0
        for slice in committedSlices {
            let cgY = totalHeight - cursorTopFromImageTop - slice.height
            context.draw(slice, in: CGRect(x: 0, y: cgY, width: width, height: slice.height))
            cursorTopFromImageTop += slice.height
        }
        if let footer = latestStickyFooter {
            context.draw(footer, in: CGRect(x: 0, y: 0, width: width, height: footer.height))
        }
        return context.makeImage()
    }

    /// Renders a lightweight live preview showing either the whole strip (when short) or the
    /// bottom-most trailing section so scrolling progress stays sharp in the HUD rail.
    public func buildPreviewImage(maxWidth: Int = 180, maxHeight: Int = 520) -> CGImage? {
        guard let initial = initialFrame else { return nil }
        let totalHeight = totalStitchedHeight
        guard width > 0, totalHeight > 0, maxWidth > 0, maxHeight > 0 else { return nil }

        let targetWidth = min(maxWidth, width)
        let scaleFactor = CGFloat(targetWidth) / CGFloat(width)
        let scaledFullHeight = CGFloat(totalHeight) * scaleFactor

        let visibleSourceStartY: Int
        let previewHeight: Int
        if scaledFullHeight <= CGFloat(maxHeight) {
            visibleSourceStartY = 0
            previewHeight = max(1, Int(scaledFullHeight.rounded()))
        } else {
            let sourceWindowHeight = max(1, Int((CGFloat(maxHeight) / scaleFactor).rounded(.up)))
            visibleSourceStartY = max(0, totalHeight - sourceWindowHeight)
            previewHeight = maxHeight
        }

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: previewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: initial.resolvedColorSpace(),
            bitmapInfo: ScrollFrameBuffer.canonicalBitmapInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .low

        if committedSlices.isEmpty {
            if let img = initial.cropCGImage(yStart: 0, height: initial.height) {
                let topInVisible = -visibleSourceStartY
                let cgY = CGFloat(previewHeight) - (CGFloat(topInVisible + img.height) * scaleFactor)
                context.draw(
                    img,
                    in: CGRect(x: 0, y: cgY, width: CGFloat(targetWidth), height: CGFloat(img.height) * scaleFactor)
                )
            }
            return context.makeImage()
        }

        var cursorTop = 0
        let visibleEnd = totalHeight
        for slice in committedSlices {
            let sliceEnd = cursorTop + slice.height
            if sliceEnd > visibleSourceStartY, cursorTop < visibleEnd {
                let topInVisible = cursorTop - visibleSourceStartY
                let cgY = CGFloat(previewHeight) - (CGFloat(topInVisible + slice.height) * scaleFactor)
                context.draw(
                    slice,
                    in: CGRect(x: 0, y: cgY, width: CGFloat(targetWidth), height: CGFloat(slice.height) * scaleFactor)
                )
            }
            cursorTop = sliceEnd
        }
        if let footer = latestStickyFooter {
            context.draw(
                footer,
                in: CGRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(footer.height) * scaleFactor)
            )
        }
        return context.makeImage()
    }

    // MARK: - Frame Comparison & Alignment

    /// Detects unchanged top/bottom textured chrome regions and near-identical frames.
    public static func detectStickyBounds(previous: ScrollFrameBuffer, current: ScrollFrameBuffer) -> ScrollStickyBounds {
        let height = previous.height
        let sigW = previous.signatureWidth
        guard height == current.height, sigW == current.signatureWidth, height > 0, sigW > 0 else {
            return ScrollStickyBounds(stickyTop: 0, stickyBottom: 0, isIdenticalFrame: false)
        }

        var rowDiffs = [Int](repeating: 0, count: height)
        var staticRows = 0
        previous.rowSignatures.withUnsafeBufferPointer { prevSig in
            current.rowSignatures.withUnsafeBufferPointer { currSig in
                for y in 0..<height {
                    let base = y * sigW
                    var diffSum = 0
                    for i in 0..<sigW {
                        diffSum += abs(Int(prevSig[base + i]) - Int(currSig[base + i]))
                    }
                    let meanDiff = diffSum / sigW
                    rowDiffs[y] = meanDiff
                    if meanDiff <= 2 {
                        staticRows += 1
                    }
                }
            }
        }

        if staticRows * 100 >= height * 98 {
            return ScrollStickyBounds(stickyTop: 0, stickyBottom: 0, isIdenticalFrame: true)
        }

        let maxSticky = min(height / 3, 240)
        var lastTexturedTop = 0
        if maxSticky > 0 {
            for y in 0..<maxSticky {
                guard rowDiffs[y] <= 3 else { break }
                if previous.rowEnergy[y] >= 120 {
                    lastTexturedTop = y + 1
                }
            }
        }
        var stickyTop = lastTexturedTop >= 12 ? min(lastTexturedTop + 2, maxSticky) : 0

        var firstTexturedBottom = height
        if maxSticky > 0 {
            for offset in 0..<maxSticky {
                let y = height - 1 - offset
                guard rowDiffs[y] <= 3 else { break }
                if previous.rowEnergy[y] >= 120 {
                    firstTexturedBottom = y
                }
            }
        }
        let rawBottom = height - firstTexturedBottom
        var stickyBottom = rawBottom >= 12 ? min(rawBottom + 2, maxSticky) : 0

        // Ensure a generous dynamic viewport remains for correlation matching.
        let minDynamic = max(64, height / 3)
        if height - stickyTop - stickyBottom < minDynamic {
            let excess = minDynamic - (height - stickyTop - stickyBottom)
            let trimTop = min(stickyTop, excess / 2)
            let trimBottom = min(stickyBottom, excess - trimTop)
            stickyTop -= trimTop
            stickyBottom -= trimBottom
        }

        return ScrollStickyBounds(stickyTop: stickyTop, stickyBottom: stickyBottom, isIdenticalFrame: false)
    }

    /// Estimates the downward scroll distance `dy > 0` between `previous` and `current`
    /// inside `[dynamicTop, dynamicBottom)` using a coarse luma scan + full-RGB overlap refinement.
    public static func estimateVerticalShift(
        previous: ScrollFrameBuffer,
        current: ScrollFrameBuffer,
        dynamicTop: Int,
        dynamicBottom: Int,
        maxAllowedMAD: Double = 8.5
    ) -> ScrollMatchResult? {
        let height = previous.height
        let sigW = previous.signatureWidth
        guard height == current.height,
              previous.width == current.width,
              sigW == current.signatureWidth,
              sigW > 0
        else { return nil }

        let topBound = max(0, dynamicTop)
        let bottomBound = min(height, dynamicBottom)
        let dynamicHeight = bottomBound - topBound
        guard dynamicHeight >= 48 else { return nil }

        let bandHeight = min(96, max(24, dynamicHeight / 4))
        let searchMinY = topBound + 8
        let searchMaxStart = bottomBound - bandHeight
        guard searchMaxStart >= searchMinY else { return nil }

        // Select the lowest textured anchor band in the dynamic viewport so large downward
        // jumps remain visible higher up in `current`. Fall back to highest contrast band.
        var anchorY: Int?
        var bestContrastY: Int?
        var bestContrastScore: Int64 = 0
        let requiredTexture = Int64(bandHeight) * 80
        let fallbackFloorY = topBound + dynamicHeight / 4

        var runningContrast: Int64 = 0
        for y in searchMinY..<(searchMinY + bandHeight) {
            runningContrast += Int64(previous.rowContrast[y])
        }
        if runningContrast >= requiredTexture {
            anchorY = searchMinY
        }
        if runningContrast > bestContrastScore, searchMinY >= fallbackFloorY {
            bestContrastScore = runningContrast
            bestContrastY = searchMinY
        }

        if searchMaxStart > searchMinY {
            for y in (searchMinY + 1)...searchMaxStart {
                runningContrast += Int64(previous.rowContrast[y + bandHeight - 1])
                runningContrast -= Int64(previous.rowContrast[y - 1])
                if runningContrast >= requiredTexture {
                    anchorY = y
                }
                if y >= fallbackFloorY && runningContrast > bestContrastScore {
                    bestContrastScore = runningContrast
                    bestContrastY = y
                }
            }
        }
        // Check full range fallback if lower 75% was completely blank.
        if anchorY == nil && bestContrastY == nil {
            var fullSum: Int64 = 0
            for y in topBound..<(topBound + bandHeight) {
                fullSum += Int64(previous.rowContrast[y])
            }
            if fullSum > bestContrastScore {
                bestContrastScore = fullSum
                bestContrastY = topBound
            }
            if searchMaxStart > topBound {
                for y in (topBound + 1)...searchMaxStart {
                    fullSum += Int64(previous.rowContrast[y + bandHeight - 1])
                    fullSum -= Int64(previous.rowContrast[y - 1])
                    if fullSum > bestContrastScore {
                        bestContrastScore = fullSum
                        bestContrastY = y
                    }
                }
            }
        }

        guard let chosenAnchorY = anchorY ?? bestContrastY,
              (anchorY != nil || bestContrastScore > 0) else {
            return nil
        }

        let minOverlap = min(32, max(16, dynamicHeight / 6))
        let maxShift = min(chosenAnchorY - topBound, dynamicHeight - minOverlap)
        guard maxShift >= 1 else { return nil }

        let coarseStep = maxShift > 320 ? 4 : 2
        let rowStep = bandHeight >= 32 ? 2 : 1
        let sampledBandRows = (bandHeight + rowStep - 1) / rowStep
        let earlyExitTotal = Int(Double(sampledBandRows * sigW) * (maxAllowedMAD * 2.5 + 4.0))

        struct Candidate {
            let dy: Int
            let score: Int
        }
        var coarseScores: [Candidate] = []
        coarseScores.reserveCapacity(maxShift / coarseStep + 2)

        previous.rowSignatures.withUnsafeBufferPointer { prevSig in
            current.rowSignatures.withUnsafeBufferPointer { currSig in
                var dy = 1
                while dy <= maxShift {
                    let prevStart = chosenAnchorY
                    let currStart = chosenAnchorY - dy
                    var diffSum = 0
                    var row = 0
                    while row < bandHeight {
                        let pBase = (prevStart + row) * sigW
                        let cBase = (currStart + row) * sigW
                        for i in 0..<sigW {
                            diffSum += abs(Int(prevSig[pBase + i]) - Int(currSig[cBase + i]))
                        }
                        if diffSum > earlyExitTotal { break }
                        row += rowStep
                    }
                    coarseScores.append(Candidate(dy: dy, score: diffSum))
                    dy += coarseStep
                }
            }
        }

        coarseScores.sort { $0.score < $1.score }
        var topCandidates: [Int] = []
        let minPeakSeparation = max(8, coarseStep * 2)
        for cand in coarseScores {
            if topCandidates.allSatisfy({ abs($0 - cand.dy) >= minPeakSeparation }) {
                topCandidates.append(cand.dy)
                if topCandidates.count >= 4 { break }
            }
        }
        if topCandidates.isEmpty {
            topCandidates.append(1)
        }

        // Evaluate fine exact integer shifts across full interior RGB over the entire overlap.
        let mLeft = previous.marginLeft
        let interiorWidth = max(1, previous.width - previous.marginLeft - previous.marginRight)
        let fineCols = min(96, interiorWidth)
        var colOffsets = [Int](repeating: 0, count: fineCols)
        for i in 0..<fineCols {
            let c = min(max(mLeft + (i * interiorWidth) / fineCols, 0), previous.width - 1)
            colOffsets[i] = c * 4
        }

        var testedDy = Set<Int>()
        var bestDy: Int?
        var bestMAD = Double.greatestFiniteMagnitude
        let prevRowBytes = previous.bytesPerRow
        let currRowBytes = current.bytesPerRow

        previous.bgraData.withUnsafeBytes { prevRaw in
            current.bgraData.withUnsafeBytes { currRaw in
                guard let prevPtr = prevRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let currPtr = currRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }

                for centerDy in topCandidates {
                    let lower = max(1, centerDy - coarseStep)
                    let upper = min(maxShift, centerDy + coarseStep)
                    for dy in lower...upper where testedDy.insert(dy).inserted {
                        let overlapRows = dynamicHeight - dy
                        guard overlapRows >= minOverlap else { continue }
                        let rowStride = max(1, overlapRows / 120)
                        var totalAbsDiff = 0
                        var sampleChannels = 0
                        var yOffset = 0
                        while yOffset < overlapRows {
                            let pRow = (topBound + dy + yOffset) * prevRowBytes
                            let cRow = (topBound + yOffset) * currRowBytes
                            for colByteOffset in colOffsets {
                                let pPx = pRow + colByteOffset
                                let cPx = cRow + colByteOffset
                                totalAbsDiff += abs(Int(prevPtr[pPx]) - Int(currPtr[cPx]))
                                totalAbsDiff += abs(Int(prevPtr[pPx + 1]) - Int(currPtr[cPx + 1]))
                                totalAbsDiff += abs(Int(prevPtr[pPx + 2]) - Int(currPtr[cPx + 2]))
                            }
                            sampleChannels += fineCols * 3
                            yOffset += rowStride
                        }
                        guard sampleChannels > 0 else { continue }
                        let mad = Double(totalAbsDiff) / Double(sampleChannels)
                        if mad < bestMAD {
                            bestMAD = mad
                            bestDy = dy
                        }
                    }
                }
            }
        }

        guard let finalDy = bestDy, finalDy >= 1, bestMAD <= maxAllowedMAD else {
            return nil
        }
        return ScrollMatchResult(dy: finalDy, mad: bestMAD)
    }
}
