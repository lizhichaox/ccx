import CoreGraphics
import Foundation

/// Selection corners in visual screen orientation (`top` = AppKit `maxY`, `bottom` = AppKit `minY`).
public struct WindowCornerSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let topLeft = WindowCornerSet(rawValue: 1 << 0)
    public static let topRight = WindowCornerSet(rawValue: 1 << 1)
    public static let bottomLeft = WindowCornerSet(rawValue: 1 << 2)
    public static let bottomRight = WindowCornerSet(rawValue: 1 << 3)
    public static let all: WindowCornerSet = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

/// Measured per-corner continuous corner radii (in points) for live overlay preview rendering.
public struct AdaptiveCornerRadii: Equatable, Sendable {
    public var topLeft: CGFloat
    public var topRight: CGFloat
    public var bottomLeft: CGFloat
    public var bottomRight: CGFloat

    public static let zero = AdaptiveCornerRadii(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0)

    public init(topLeft: CGFloat = 0, topRight: CGFloat = 0, bottomLeft: CGFloat = 0, bottomRight: CGFloat = 0) {
        self.topLeft = topLeft.isFinite ? max(0, topLeft) : 0
        self.topRight = topRight.isFinite ? max(0, topRight) : 0
        self.bottomLeft = bottomLeft.isFinite ? max(0, bottomLeft) : 0
        self.bottomRight = bottomRight.isFinite ? max(0, bottomRight) : 0
    }

    public var isAllZero: Bool {
        topLeft <= 0 && topRight <= 0 && bottomLeft <= 0 && bottomRight <= 0
    }

    func inset(by delta: CGFloat) -> AdaptiveCornerRadii {
        guard delta.isFinite, delta > 0 else { return self }
        return AdaptiveCornerRadii(
            topLeft: topLeft > 0 ? max(0, topLeft - delta) : 0,
            topRight: topRight > 0 ? max(0, topRight - delta) : 0,
            bottomLeft: bottomLeft > 0 ? max(0, bottomLeft - delta) : 0,
            bottomRight: bottomRight > 0 ? max(0, bottomRight - delta) : 0
        )
    }
}

/// Output of `WindowCornerMaskExtractor`: an exact per-pixel grayscale alpha mask (255 = opaque,
/// 0 = transparent exterior) plus measured approximate corner radii for live overlay preview.
public struct ExtractedWindowCornerMask: Sendable {
    /// 8-bit grayscale mask image matching `outputPixelSize` (row 0 = visual top).
    public let maskImage: CGImage
    /// Measured per-corner radii in points (0 for square or ineligible corners).
    public let cornerRadii: AdaptiveCornerRadii
    /// Subset of `eligibleCorners` that actually contained transparent exterior pixels.
    public let maskedCorners: WindowCornerSet
}

/// Isolated window silhouette captured via ScreenCaptureKit (`desktopIndependentWindow`).
struct CapturedWindowSilhouette: Sendable {
    let image: CGImage
    /// Window content size in points at the instant ScreenCaptureKit captured `image`.
    let contentSize: CGSize
    /// Backing pixel scale (`pixels / point`) of `image`.
    let pointPixelScale: CGFloat
}

/// Extracts exterior-only window corner alpha masks from an isolated ScreenCaptureKit window
/// capture and applies them onto WYSIWYG frozen display crops.
///
/// Key invariants:
/// - Never fabricates synthetic radii for square/fullscreen windows or interior sub-elements.
/// - Only pixels connected to an eligible outer corner are made transparent; all interior pixels
///   are forced opaque (`255`) so translucent Liquid Glass / Terminal windows stay 100% WYSIWYG.
/// - Preserves exact WindowServer anti-aliased boundary alpha along each rounded corner curve.
public enum WindowCornerMaskExtractor {
    /// Maximum corner patch side in points (covers radii up to ~47pt continuous / 72pt circular).
    static let maxCornerPatchPoints: CGFloat = 72
    /// Alpha threshold below which the corner pixel is treated as genuinely exterior transparent.
    static let exteriorCornerAlphaThreshold: UInt8 = 8
    /// Size mismatch tolerance (in points) guarding against windows resized mid-snip.
    static let windowSizeMatchTolerance: CGFloat = 1.0

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let grayColorSpace = CGColorSpaceCreateDeviceGray()
    private static let rgbaBitmapInfo: UInt32 =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var flag: WindowCornerSet {
            switch self {
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
        }
    }

    private struct CornerPatchResult {
        let maskValues: [UInt8]
        let width: Int
        let height: Int
        let measuredRadiusPoints: CGFloat
    }

    /// Extracts an exterior-only grayscale alpha mask and per-corner radii for `selectionRect`.
    ///
    /// Returns `nil` when `eligibleCorners` is empty, when `windowImage` fails the `<= 1pt`
    /// size/aspect guard against `windowFrame`, or when every eligible corner is opaque (square).
    public nonisolated static func extractMask(
        windowImage: CGImage,
        windowFrame: CGRect,
        selectionRect: CGRect,
        eligibleCorners: WindowCornerSet,
        outputPixelSize: (width: Int, height: Int),
        displayScale: CGFloat
    ) -> ExtractedWindowCornerMask? {
        guard !eligibleCorners.isEmpty else { return nil }
        let outW = outputPixelSize.width
        let outH = outputPixelSize.height
        guard outW >= 8, outH >= 8,
              windowImage.width >= 4, windowImage.height >= 4,
              isFinitePositiveRect(windowFrame),
              isFinitePositiveRect(selectionRect),
              displayScale.isFinite, displayScale > 0
        else { return nil }

        // Guard against a window resizing between initial freeze and silhouette capture.
        let imageWidthPoints = CGFloat(windowImage.width) / displayScale
        let imageHeightPoints = CGFloat(windowImage.height) / displayScale
        guard abs(imageWidthPoints - windowFrame.width) <= windowSizeMatchTolerance,
              abs(imageHeightPoints - windowFrame.height) <= windowSizeMatchTolerance
        else { return nil }

        // Ensure `selectionRect` lies inside `windowFrame` (within 1pt rounding tolerance).
        let expandedWindow = windowFrame.insetBy(dx: -windowSizeMatchTolerance, dy: -windowSizeMatchTolerance)
        guard expandedWindow.contains(selectionRect) else { return nil }

        let scaleX = CGFloat(windowImage.width) / windowFrame.width
        let scaleY = CGFloat(windowImage.height) / windowFrame.height
        let outScaleX = CGFloat(outW) / selectionRect.width
        let outScaleY = CGFloat(outH) / selectionRect.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0,
              outScaleX.isFinite, outScaleY.isFinite, outScaleX > 0, outScaleY > 0
        else { return nil }

        // Map AppKit global `selectionRect` (bottom-left origin) into `windowImage` pixel coordinates
        // (top-left origin: row 0 = visual top of `windowFrame`).
        let rawCropX = ((selectionRect.minX - windowFrame.minX) * scaleX).rounded()
        let rawCropTopY = ((windowFrame.maxY - selectionRect.maxY) * scaleY).rounded()
        let rawCropW = (selectionRect.width * scaleX).rounded()
        let rawCropH = (selectionRect.height * scaleY).rounded()

        let imgBounds = CGRect(x: 0, y: 0, width: windowImage.width, height: windowImage.height)
        let selectionInWindowPx = CGRect(x: rawCropX, y: rawCropTopY, width: rawCropW, height: rawCropH)
            .intersection(imgBounds)
            .integral
        guard !selectionInWindowPx.isNull,
              selectionInWindowPx.width >= 8,
              selectionInWindowPx.height >= 8
        else { return nil }

        // Cap patch size to half of source and output dimensions so the 4 corner patches never overlap.
        // When source silhouette DPI differs from output display DPI (e.g. a window straddling 2x/1x
        // monitors), compute source and destination patch sizes from the same point span and resample.
        let needsResample = abs(scaleX - outScaleX) > 0.02 || abs(scaleY - outScaleY) > 0.02
        let srcPatchW: Int
        let srcPatchH: Int
        let dstPatchW: Int
        let dstPatchH: Int
        if needsResample {
            let patchPointsX = min(
                maxCornerPatchPoints,
                selectionRect.width * 0.5,
                selectionInWindowPx.width / (2 * scaleX),
                CGFloat(outW / 2) / outScaleX
            )
            let patchPointsY = min(
                maxCornerPatchPoints,
                selectionRect.height * 0.5,
                selectionInWindowPx.height / (2 * scaleY),
                CGFloat(outH / 2) / outScaleY
            )
            guard patchPointsX.isFinite, patchPointsY.isFinite, patchPointsX > 0, patchPointsY > 0 else {
                return nil
            }
            srcPatchW = min(max(4, Int((patchPointsX * scaleX).rounded())), Int(selectionInWindowPx.width) / 2)
            srcPatchH = min(max(4, Int((patchPointsY * scaleY).rounded())), Int(selectionInWindowPx.height) / 2)
            dstPatchW = min(max(4, Int((patchPointsX * outScaleX).rounded())), outW / 2)
            dstPatchH = min(max(4, Int((patchPointsY * outScaleY).rounded())), outH / 2)
        } else {
            let maxPatchX = max(4, Int((maxCornerPatchPoints * scaleX).rounded()))
            let maxPatchY = max(4, Int((maxCornerPatchPoints * scaleY).rounded()))
            srcPatchW = min(maxPatchX, outW / 2, Int(selectionInWindowPx.width) / 2)
            srcPatchH = min(maxPatchY, outH / 2, Int(selectionInWindowPx.height) / 2)
            dstPatchW = srcPatchW
            dstPatchH = srcPatchH
        }
        guard srcPatchW >= 4, srcPatchH >= 4, dstPatchW >= 4, dstPatchH >= 4 else { return nil }

        var patches: [Corner: CornerPatchResult] = [:]
        var maskedCorners: WindowCornerSet = []
        var radii = AdaptiveCornerRadii.zero

        for corner in Corner.allCases where eligibleCorners.contains(corner.flag) {
            let sourcePatchRect = cornerRect(
                for: corner,
                inside: selectionInWindowPx,
                patchWidth: srcPatchW,
                patchHeight: srcPatchH
            )
            guard let alphaBuffer = rasterizeAlphaPatch(from: windowImage, cropRect: sourcePatchRect, width: srcPatchW, height: srcPatchH),
                  let extracted = extractExteriorCornerMask(
                      alphaBytes: alphaBuffer,
                      width: srcPatchW,
                      height: srcPatchH,
                      corner: corner,
                      scaleX: scaleX,
                      scaleY: scaleY
                  )
            else { continue }

            let finalPatch: CornerPatchResult
            if needsResample && (extracted.width != dstPatchW || extracted.height != dstPatchH) {
                guard let resampledBytes = resampleGrayscalePatch(
                    extracted.maskValues,
                    sourceWidth: extracted.width,
                    sourceHeight: extracted.height,
                    targetWidth: dstPatchW,
                    targetHeight: dstPatchH
                ) else { continue }
                finalPatch = CornerPatchResult(
                    maskValues: resampledBytes,
                    width: dstPatchW,
                    height: dstPatchH,
                    measuredRadiusPoints: extracted.measuredRadiusPoints
                )
            } else {
                finalPatch = extracted
            }

            patches[corner] = finalPatch
            maskedCorners.insert(corner.flag)
            switch corner {
            case .topLeft: radii.topLeft = finalPatch.measuredRadiusPoints
            case .topRight: radii.topRight = finalPatch.measuredRadiusPoints
            case .bottomLeft: radii.bottomLeft = finalPatch.measuredRadiusPoints
            case .bottomRight: radii.bottomRight = finalPatch.measuredRadiusPoints
            }
        }

        guard !maskedCorners.isEmpty else { return nil }

        // Build the full-size 8-bit grayscale mask initialized to opaque (255), then stamp only
        // the extracted corner patches at their exact top-down coordinates (row 0 = visual top).
        let (pixelCount, overflow) = outW.multipliedReportingOverflow(by: outH)
        guard !overflow, pixelCount > 0, pixelCount <= 150_000_000 else { return nil }

        var fullMask = [UInt8](repeating: 255, count: pixelCount)
        for (corner, patch) in patches {
            let originX: Int
            let originY: Int
            switch corner {
            case .topLeft:
                originX = 0
                originY = 0
            case .topRight:
                originX = outW - patch.width
                originY = 0
            case .bottomLeft:
                originX = 0
                originY = outH - patch.height
            case .bottomRight:
                originX = outW - patch.width
                originY = outH - patch.height
            }

            for py in 0..<patch.height {
                let dstRow = (originY + py) * outW + originX
                let srcRow = py * patch.width
                for px in 0..<patch.width {
                    fullMask[dstRow + px] = patch.maskValues[srcRow + px]
                }
            }
        }

        guard let maskImage = makeGrayscaleMaskImage(bytes: &fullMask, width: outW, height: outH) else {
            return nil
        }

        return ExtractedWindowCornerMask(
            maskImage: maskImage,
            cornerRadii: radii,
            maskedCorners: maskedCorners
        )
    }

    /// Lightweight helper that extracts only the measured per-corner radii (without allocating
    /// a full-resolution mask image) for live `SnipOverlayView` preview feedback.
    public nonisolated static func extractCornerRadii(
        windowImage: CGImage,
        windowFrame: CGRect,
        selectionRect: CGRect,
        eligibleCorners: WindowCornerSet,
        displayScale: CGFloat
    ) -> AdaptiveCornerRadii {
        guard !eligibleCorners.isEmpty,
              windowImage.width >= 4, windowImage.height >= 4,
              isFinitePositiveRect(windowFrame),
              isFinitePositiveRect(selectionRect),
              displayScale.isFinite, displayScale > 0
        else { return .zero }

        let imageWidthPoints = CGFloat(windowImage.width) / displayScale
        let imageHeightPoints = CGFloat(windowImage.height) / displayScale
        guard abs(imageWidthPoints - windowFrame.width) <= windowSizeMatchTolerance,
              abs(imageHeightPoints - windowFrame.height) <= windowSizeMatchTolerance
        else { return .zero }

        let expandedWindow = windowFrame.insetBy(dx: -windowSizeMatchTolerance, dy: -windowSizeMatchTolerance)
        guard expandedWindow.contains(selectionRect) else { return .zero }

        let scaleX = CGFloat(windowImage.width) / windowFrame.width
        let scaleY = CGFloat(windowImage.height) / windowFrame.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return .zero }

        let rawCropX = ((selectionRect.minX - windowFrame.minX) * scaleX).rounded()
        let rawCropTopY = ((windowFrame.maxY - selectionRect.maxY) * scaleY).rounded()
        let rawCropW = (selectionRect.width * scaleX).rounded()
        let rawCropH = (selectionRect.height * scaleY).rounded()

        let imgBounds = CGRect(x: 0, y: 0, width: windowImage.width, height: windowImage.height)
        let selectionInWindowPx = CGRect(x: rawCropX, y: rawCropTopY, width: rawCropW, height: rawCropH)
            .intersection(imgBounds)
            .integral
        guard !selectionInWindowPx.isNull,
              selectionInWindowPx.width >= 8,
              selectionInWindowPx.height >= 8
        else { return .zero }

        let maxPatchX = max(4, Int((maxCornerPatchPoints * scaleX).rounded()))
        let maxPatchY = max(4, Int((maxCornerPatchPoints * scaleY).rounded()))
        let patchW = min(maxPatchX, Int(selectionInWindowPx.width) / 2)
        let patchH = min(maxPatchY, Int(selectionInWindowPx.height) / 2)
        guard patchW >= 4, patchH >= 4 else { return .zero }

        var radii = AdaptiveCornerRadii.zero
        for corner in Corner.allCases where eligibleCorners.contains(corner.flag) {
            let sourcePatchRect = cornerRect(
                for: corner,
                inside: selectionInWindowPx,
                patchWidth: patchW,
                patchHeight: patchH
            )
            guard let alphaBuffer = rasterizeAlphaPatch(from: windowImage, cropRect: sourcePatchRect, width: patchW, height: patchH),
                  let extracted = extractExteriorCornerMask(
                      alphaBytes: alphaBuffer,
                      width: patchW,
                      height: patchH,
                      corner: corner,
                      scaleX: scaleX,
                      scaleY: scaleY
                  )
            else { continue }

            switch corner {
            case .topLeft: radii.topLeft = extracted.measuredRadiusPoints
            case .topRight: radii.topRight = extracted.measuredRadiusPoints
            case .bottomLeft: radii.bottomLeft = extracted.measuredRadiusPoints
            case .bottomRight: radii.bottomRight = extracted.measuredRadiusPoints
            }
        }
        return radii
    }

    /// Clips `image` by grayscale `mask` (`255` = opaque, `0` = transparent) with matching
    /// top-left orientation (row 0 of `mask` aligns with visual top of `image`).
    public nonisolated static func applyMask(_ mask: CGImage, to image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, mask.width == width, mask.height == height else {
            return image
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount > 0, pixelCount <= 150_000_000 else {
            return image
        }

        guard let context = makeOutputRGBAContext(width: width, height: height, matching: image) else {
            return image
        }
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(fullRect)
        context.clip(to: fullRect, mask: mask)
        context.draw(image, in: fullRect)
        return context.makeImage() ?? image
    }

    /// Builds a per-corner rounded rectangle `CGPath` in non-flipped AppKit coordinates
    /// (`rect.maxY` = visual top, `rect.minY` = visual bottom).
    public nonisolated static func makeRoundedRectPath(rect: CGRect, radii: AdaptiveCornerRadii) -> CGPath {
        guard isFinitePositiveRect(rect) else {
            return CGMutablePath()
        }
        guard !radii.isAllZero else {
            return CGPath(rect: rect, transform: nil)
        }

        // Clamp radii so opposing corners on any edge never exceed the edge's length.
        var tl = radii.topLeft
        var tr = radii.topRight
        var bl = radii.bottomLeft
        var br = radii.bottomRight

        let maxDim = min(rect.width, rect.height) * 0.5
        tl = min(tl, maxDim)
        tr = min(tr, maxDim)
        bl = min(bl, maxDim)
        br = min(br, maxDim)

        if tl + tr > rect.width, tl + tr > 0 {
            let s = rect.width / (tl + tr)
            tl *= s
            tr *= s
        }
        if bl + br > rect.width, bl + br > 0 {
            let s = rect.width / (bl + br)
            bl *= s
            br *= s
        }
        if tl + bl > rect.height, tl + bl > 0 {
            let s = rect.height / (tl + bl)
            tl *= s
            bl *= s
        }
        if tr + br > rect.height, tr + br > 0 {
            let s = rect.height / (tr + br)
            tr *= s
            br *= s
        }

        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX + bl, y: minY))

        // Bottom edge -> Bottom-Right corner
        if br > 0 {
            path.addLine(to: CGPoint(x: maxX - br, y: minY))
            path.addArc(
                tangent1End: CGPoint(x: maxX, y: minY),
                tangent2End: CGPoint(x: maxX, y: minY + br),
                radius: br
            )
        } else {
            path.addLine(to: CGPoint(x: maxX, y: minY))
        }

        // Right edge -> Top-Right corner (AppKit maxY = visual top)
        if tr > 0 {
            path.addLine(to: CGPoint(x: maxX, y: maxY - tr))
            path.addArc(
                tangent1End: CGPoint(x: maxX, y: maxY),
                tangent2End: CGPoint(x: maxX - tr, y: maxY),
                radius: tr
            )
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        }

        // Top edge -> Top-Left corner
        if tl > 0 {
            path.addLine(to: CGPoint(x: minX + tl, y: maxY))
            path.addArc(
                tangent1End: CGPoint(x: minX, y: maxY),
                tangent2End: CGPoint(x: minX, y: maxY - tl),
                radius: tl
            )
        } else {
            path.addLine(to: CGPoint(x: minX, y: maxY))
        }

        // Left edge -> Bottom-Left corner
        if bl > 0 {
            path.addLine(to: CGPoint(x: minX, y: minY + bl))
            path.addArc(
                tangent1End: CGPoint(x: minX, y: minY),
                tangent2End: CGPoint(x: minX + bl, y: minY),
                radius: bl
            )
        } else {
            path.addLine(to: CGPoint(x: minX, y: minY))
        }

        path.closeSubpath()
        return path
    }

    // MARK: - Private Corner Patch Extraction

    private nonisolated static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }

    private nonisolated static func cornerRect(
        for corner: Corner,
        inside selectionPx: CGRect,
        patchWidth: Int,
        patchHeight: Int
    ) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft:
            x = selectionPx.minX
            y = selectionPx.minY
        case .topRight:
            x = selectionPx.maxX - CGFloat(patchWidth)
            y = selectionPx.minY
        case .bottomLeft:
            x = selectionPx.minX
            y = selectionPx.maxY - CGFloat(patchHeight)
        case .bottomRight:
            x = selectionPx.maxX - CGFloat(patchWidth)
            y = selectionPx.maxY - CGFloat(patchHeight)
        }
        return CGRect(x: x, y: y, width: CGFloat(patchWidth), height: CGFloat(patchHeight))
    }

    private nonisolated static func rasterizeAlphaPatch(
        from image: CGImage,
        cropRect: CGRect,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        guard width > 0, height > 0, let cropped = image.cropping(to: cropRect) else {
            return nil
        }
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)
        let ok = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: sRGBColorSpace,
                      bitmapInfo: rgbaBitmapInfo
                  )
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        var alphas = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let srcRow = y * bytesPerRow
            let dstRow = y * width
            for x in 0..<width {
                alphas[dstRow + x] = rgba[srcRow + x * 4 + 3]
            }
        }
        return alphas
    }

    /// Extracts an exterior-only mask for a single corner patch (`width × height`, row 0 = visual top).
    ///
    /// Uses a two-tier flood-fill seeded strictly from the outer corner pixel:
    /// 1. Primary BFS through pixels below `interiorFloor - 6`, capturing both exterior `alpha == 0`
    ///    and the full anti-aliased curve tangent (including Apple's continuous squircle tail) while
    ///    normalizing anti-aliased edge coverage against `interiorAlpha` and forcing all interior
    ///    pixels to `255`.
    /// 2. Safety fallback: if the primary BFS ever reaches the patch's innermost pixel (e.g. due to
    ///    a highly uneven translucent interior), falls back to strict exterior BFS (`alpha < 8`) plus
    ///    a 1px anti-aliased neighbor ring so window interiors can never be eroded.
    private nonisolated static func extractExteriorCornerMask(
        alphaBytes: [UInt8],
        width: Int,
        height: Int,
        corner: Corner,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CornerPatchResult? {
        let count = width * height
        guard alphaBytes.count == count, width >= 4, height >= 4 else { return nil }

        let cornerX: Int
        let cornerY: Int
        let innerX: Int
        let innerY: Int
        let stepX: Int
        let stepY: Int
        switch corner {
        case .topLeft:
            cornerX = 0; cornerY = 0; innerX = width - 1; innerY = height - 1; stepX = 1; stepY = 1
        case .topRight:
            cornerX = width - 1; cornerY = 0; innerX = 0; innerY = height - 1; stepX = -1; stepY = 1
        case .bottomLeft:
            cornerX = 0; cornerY = height - 1; innerX = width - 1; innerY = 0; stepX = 1; stepY = -1
        case .bottomRight:
            cornerX = width - 1; cornerY = height - 1; innerX = 0; innerY = 0; stepX = -1; stepY = -1
        }

        let startIndex = cornerY * width + cornerX
        // Square or opaque corner: zero transparent exterior pixels -> skip masking.
        guard alphaBytes[startIndex] < exteriorCornerAlphaThreshold else {
            return nil
        }

        // Estimate interior opacity from the inner corner quadrant (safely inside any rounded curve).
        let sampleSpanX = max(2, width / 3)
        let sampleSpanY = max(2, height / 3)
        var interiorSamples: [UInt8] = []
        interiorSamples.reserveCapacity(sampleSpanX * sampleSpanY)
        for dy in 0..<sampleSpanY {
            let y = innerY - stepY * dy
            let row = y * width
            for dx in 0..<sampleSpanX {
                let x = innerX - stepX * dx
                let a = alphaBytes[row + x]
                if a >= 16 {
                    interiorSamples.append(a)
                }
            }
        }
        guard !interiorSamples.isEmpty else {
            // Completely empty/transparent patch (not a solid window corner).
            return nil
        }
        interiorSamples.sort()
        let interiorFloor = interiorSamples[interiorSamples.count / 10]
        let interiorMedian = interiorSamples[interiorSamples.count / 2]
        guard interiorFloor >= 16, interiorMedian >= 16 else { return nil }

        // Helper performing 4-connected BFS from `startIndex` over pixels with `alpha <= maxAlpha`.
        func floodFill(maxAlpha: UInt8) -> [Bool] {
            var visited = [Bool](repeating: false, count: count)
            guard alphaBytes[startIndex] <= maxAlpha else { return visited }
            var queue: [Int] = []
            queue.reserveCapacity(count / 4)
            visited[startIndex] = true
            queue.append(startIndex)
            var head = 0
            while head < queue.count {
                let idx = queue[head]
                head += 1
                let x = idx % width
                let y = idx / width

                if x > 0 {
                    let n = idx - 1
                    if !visited[n], alphaBytes[n] <= maxAlpha {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if x + 1 < width {
                    let n = idx + 1
                    if !visited[n], alphaBytes[n] <= maxAlpha {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if y > 0 {
                    let n = idx - width
                    if !visited[n], alphaBytes[n] <= maxAlpha {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if y + 1 < height {
                    let n = idx + width
                    if !visited[n], alphaBytes[n] <= maxAlpha {
                        visited[n] = true
                        queue.append(n)
                    }
                }
            }
            return visited
        }

        // Returns `true` if a flood-fill reached either inner patch boundary (`x == innerX` or `y == innerY`),
        // which signals either flooding into a translucent titlebar/sidebar next to an opaque body or an
        // exterior transparent strip (e.g. NSPopover chevron / letterbox bar) that would create a 72pt seam.
        func touchesInnerBoundary(_ visited: [Bool]) -> Bool {
            let innerRowOffset = innerY * width
            for x in 0..<width where visited[innerRowOffset + x] {
                return true
            }
            for y in 0..<height where visited[y * width + innerX] {
                return true
            }
            return false
        }

        var maskValues = [UInt8](repeating: 255, count: count)
        let primaryCeiling = UInt8(max(Int(exteriorCornerAlphaThreshold) - 1, Int(interiorFloor) - 6))
        let primaryVisited = floodFill(maxAlpha: primaryCeiling)

        if !touchesInnerBoundary(primaryVisited) {
            // Primary BFS cleanly isolated the exterior + full anti-aliased curve tangent.
            let denom = Double(interiorMedian)
            for idx in 0..<count where primaryVisited[idx] {
                let raw = alphaBytes[idx]
                if raw < exteriorCornerAlphaThreshold {
                    maskValues[idx] = 0
                } else {
                    let normalized = Int((Double(raw) * 255.0 / denom).rounded())
                    maskValues[idx] = UInt8(min(max(normalized, 0), 255))
                }
            }
        } else {
            // Fallback for translucent titlebars/sidebars or uneven interiors: strict exterior BFS (`< 8`)
            // plus a 1px 8-connected anti-aliased ring. If even strict exterior reaches an inner patch
            // boundary (e.g. NSPopover chevron strip or letterboxed frame), skip masking this corner.
            let strictVisited = floodFill(maxAlpha: exteriorCornerAlphaThreshold - 1)
            guard !touchesInnerBoundary(strictVisited) else { return nil }

            let denom = Double(interiorMedian)
            for idx in 0..<count {
                if strictVisited[idx] {
                    maskValues[idx] = 0
                } else {
                    let x = idx % width
                    let y = idx / width
                    var touchesExterior = false
                    outer: for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) {
                            if strictVisited[ny * width + nx] {
                                touchesExterior = true
                                break outer
                            }
                        }
                    }
                    if touchesExterior {
                        let raw = alphaBytes[idx]
                        let normalized = Int((Double(raw) * 255.0 / denom).rounded())
                        maskValues[idx] = UInt8(min(max(normalized, 0), 255))
                    }
                }
            }
        }

        // Measure approximate continuous corner radius along the 45° diagonal from the corner.
        // At 45°, both circular and Apple continuous squircle corners cross at d ≈ R * (1 - 1/sqrt(2)).
        let maxDiag = min(width, height)
        var diagCrossing: CGFloat = 0
        for d in 0..<maxDiag {
            let x = cornerX + stepX * d
            let y = cornerY + stepY * d
            let a = maskValues[y * width + x]
            if a >= 128 {
                if d == 0 {
                    diagCrossing = 0
                } else {
                    let prevA = CGFloat(maskValues[(cornerY + stepY * (d - 1)) * width + (cornerX + stepX * (d - 1))])
                    let currA = CGFloat(a)
                    let fraction = currA > prevA ? (128.0 - prevA) / (currA - prevA) : 0.5
                    diagCrossing = CGFloat(d - 1) + min(max(fraction, 0), 1)
                }
                break
            }
            if d == maxDiag - 1 {
                diagCrossing = CGFloat(maxDiag)
            }
        }
        let avgScale = (scaleX + scaleY) * 0.5
        let diagPoints = diagCrossing / max(avgScale, 1)
        let diagonalFactor: CGFloat = 1.0 - sqrt(0.5) // ≈ 0.2928932
        let measuredRadius = diagPoints > 0.25 ? (diagPoints / diagonalFactor) : 0

        return CornerPatchResult(
            maskValues: maskValues,
            width: width,
            height: height,
            measuredRadiusPoints: measuredRadius
        )
    }

    private nonisolated static func resampleGrayscalePatch(
        _ sourceBytes: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        guard sourceWidth > 0, sourceHeight > 0,
              targetWidth > 0, targetHeight > 0,
              sourceBytes.count == sourceWidth * sourceHeight
        else { return nil }
        var mutableSource = sourceBytes
        guard let sourceImage = makeGrayscaleMaskImage(
            bytes: &mutableSource,
            width: sourceWidth,
            height: sourceHeight
        ) else {
            return nil
        }
        var targetBytes = [UInt8](repeating: 255, count: targetWidth * targetHeight)
        let ok = targetBytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: targetWidth,
                      height: targetHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: targetWidth,
                      space: grayColorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .high
            ctx.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        return ok ? targetBytes : nil
    }

    private nonisolated static func makeGrayscaleMaskImage(
        bytes: inout [UInt8],
        width: Int,
        height: Int
    ) -> CGImage? {
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: grayColorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return nil }
            return ctx.makeImage()
        }
    }

    private nonisolated static func makeOutputRGBAContext(
        width: Int,
        height: Int,
        matching image: CGImage
    ) -> CGContext? {
        let space = resolvedOutputRGBColorSpace(for: image)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        ) {
            return ctx
        }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGBColorSpace,
            bitmapInfo: bitmapInfo
        )
    }

    private nonisolated static func resolvedOutputRGBColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb {
            if space.supportsOutput && !CGColorSpaceUsesExtendedRange(space) && !CGColorSpaceUsesITUR_2100TF(space) {
                return space
            }
            if let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) {
                return displayP3
            }
        }
        return sRGBColorSpace
    }
}
