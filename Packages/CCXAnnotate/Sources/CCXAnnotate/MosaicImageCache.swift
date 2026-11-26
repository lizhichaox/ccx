import Accelerate
import CoreGraphics
import CoreImage
import Metal

/// Lazy cache of full-display pixelated / blurred variants of the frozen screenshot.
///
/// Generating once per `(mode, strength)` keeps live dragging of mosaic/blur rectangles responsive at 120 Hz.
@MainActor
public final class MosaicImageCache {
    private struct CacheKey: Hashable {
        let mode: MosaicMode
        let pixelStrength: Int
    }

    public static let defaultMaxCachedBytes = 128 * 1024 * 1024
    private static let maxCachedVariants = 4
    private static let maxPixelCount = 120_000_000
    private static let maxBaseRGBACacheBytes = 64 * 1024 * 1024
    private static let maxBackingScale: CGFloat = 16
    private static let maxBlurRadiusPixels: CGFloat = 256
    private static let rgbaBitmapInfo: UInt32 =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    private static let frostedVeilColor = CIColor(red: 0.557, green: 0.600, blue: 0.659, alpha: 0.08)

    private nonisolated static let sharedCIContext: CIContext = {
        // Prefer Metal GPU context; CPU fallbacks handle headless sandboxes where createCGImage returns nil.
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    public let baseImage: CGImage
    private let maxCachedBytes: Int
    private var ciSourceStorage: CIImage?
    private lazy var rgbColorSpace: CGColorSpace = Self.resolvedRGBColorSpace(for: baseImage)
    private var cachedBaseRGBA: [UInt8]?
    private var cachedHasTransparency: Bool?
    private nonisolated(unsafe) var didUseGPUContext = false
    internal private(set) var baseRasterizationCount = 0
    internal var cachedVariantCount: Int { cache.count }
    internal var cachedByteCount: Int { totalCachedBytes }
    internal var residentByteCount: Int { totalCachedBytes + (cachedBaseRGBA?.count ?? 0) }
    private var cache: [CacheKey: CGImage] = [:]
    private var variantBytes: [CacheKey: Int] = [:]
    private var totalCachedBytes = 0
    private var accessOrder: [CacheKey] = []

    public init(baseImage: CGImage, maxCachedBytes: Int = MosaicImageCache.defaultMaxCachedBytes) {
        self.baseImage = baseImage
        self.maxCachedBytes = max(1, maxCachedBytes)
    }

    deinit {
        if didUseGPUContext {
            Self.sharedCIContext.clearCaches()
        }
    }

    private func ensureCISource() -> CIImage {
        if let existing = ciSourceStorage {
            return existing
        }
        let created = CIImage(cgImage: baseImage)
        ciSourceStorage = created
        return created
    }

    /// Releases all cached filtered variants, the rasterized RGBA scratch buffer, and pooled GPU intermediates.
    public func clear() {
        cache.removeAll()
        variantBytes.removeAll()
        accessOrder.removeAll()
        totalCachedBytes = 0
        cachedBaseRGBA = nil
        ciSourceStorage = nil
        if didUseGPUContext {
            Self.sharedCIContext.clearCaches()
            didUseGPUContext = false
        }
    }

    public func filteredImage(mode: MosaicMode, size: StrokeSize, backingScale: CGFloat) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0 else { return nil }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixelCount <= Self.maxPixelCount else { return nil }

        let rawScale = backingScale.isFinite ? backingScale : 1
        let scale = min(max(rawScale, 1), Self.maxBackingScale)
        let maxBlock = max(4, max(width, height))
        let blockPixels = min(maxBlock, max(4, Int((size.mosaicBlockSize * scale).rounded())))
        let blurRadius = min(Self.maxBlurRadiusPixels, max(1, size.blurRadius * scale))
        let pixelStrength = mode == .pixelate ? blockPixels : max(1, Int(blurRadius.rounded()))
        let key = CacheKey(mode: mode, pixelStrength: pixelStrength)
        if let cached = cache[key] {
            touchCacheKey(key)
            return cached
        }

        let result: CGImage?
        switch mode {
        case .pixelate:
            result = pixelatedImage(blockPixels: blockPixels)
        case .blur:
            result = blurredImage(radius: blurRadius)
        }

        if let result {
            let bytes = Self.estimatedByteSize(of: result)
            cache[key] = result
            variantBytes[key] = bytes
            totalCachedBytes += bytes
            touchCacheKey(key)
            evictIfNeeded()
        }
        return result
    }

    private func evictIfNeeded() {
        let baseBytes = cachedBaseRGBA?.count ?? 0
        while (cache.count > Self.maxCachedVariants || (cache.count > 1 && (totalCachedBytes + baseBytes) > maxCachedBytes)),
              let evicted = accessOrder.first {
            accessOrder.removeFirst()
            cache.removeValue(forKey: evicted)
            if let removedBytes = variantBytes.removeValue(forKey: evicted) {
                totalCachedBytes = max(0, totalCachedBytes - removedBytes)
            }
        }
    }

    private static func estimatedByteSize(of image: CGImage) -> Int {
        let (pixels, pOverflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !pOverflow else { return Int.max / 4 }
        let (bytes, bOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return bOverflow ? Int.max / 4 : bytes
    }

    private static func checkedRGBA8Dimensions(width: Int, height: Int) -> (bytesPerRow: Int, byteCount: Int)? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixels <= maxPixelCount else { return nil }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else { return nil }
        let (byteCount, countOverflow) = height.multipliedReportingOverflow(by: bytesPerRow)
        guard !countOverflow else { return nil }
        return (bytesPerRow, byteCount)
    }

    private func touchCacheKey(_ key: CacheKey) {
        if let existingIndex = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: existingIndex)
        }
        accessOrder.append(key)
    }

    private static func resolvedRGBColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb {
            if space.supportsOutput && !CGColorSpaceUsesExtendedRange(space) && !CGColorSpaceUsesITUR_2100TF(space) {
                return space
            }
            if let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) {
                return displayP3
            }
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func renderRGBA8Buffer(width: Int, height: Int, bytesPerRow: Int, byteCount: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let rendered = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = makeRGBA8Context(data: baseAddress, width: width, height: height, bytesPerRow: bytesPerRow)
            else {
                return false
            }
            context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? bytes : nil
    }

    private func makeRGBA8Context(data: UnsafeMutableRawPointer?, width: Int, height: Int, bytesPerRow: Int) -> CGContext? {
        if let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: rgbColorSpace,
            bitmapInfo: Self.rgbaBitmapInfo
        ) {
            return ctx
        }
        let srgbFallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: srgbFallback,
            bitmapInfo: Self.rgbaBitmapInfo
        )
    }

    private func ensureBaseRGBABuffer() -> [UInt8]? {
        if let cachedBaseRGBA {
            return cachedBaseRGBA
        }
        let width = baseImage.width
        let height = baseImage.height
        guard let dims = Self.checkedRGBA8Dimensions(width: width, height: height) else {
            return nil
        }
        guard let rendered = renderRGBA8Buffer(
            width: width,
            height: height,
            bytesPerRow: dims.bytesPerRow,
            byteCount: dims.byteCount
        ) else {
            return nil
        }
        baseRasterizationCount += 1
        let baseCacheLimit = min(Self.maxBaseRGBACacheBytes, maxCachedBytes / 2)
        if dims.byteCount <= baseCacheLimit {
            cachedBaseRGBA = rendered
        }
        return rendered
    }

    private static func mayHaveTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            return true
        @unknown default:
            return true
        }
    }

    private func bufferHasTransparency(_ rgbaBytes: [UInt8]) -> Bool {
        if let cachedHasTransparency {
            return cachedHasTransparency
        }
        guard Self.mayHaveTransparency(baseImage) else {
            cachedHasTransparency = false
            return false
        }
        let width = baseImage.width
        let height = baseImage.height
        let bytesPerRow = width * 4
        let cornerOffsets = [
            3,
            (width - 1) * 4 + 3,
            (height - 1) * bytesPerRow + 3,
            (height - 1) * bytesPerRow + (width - 1) * 4 + 3,
        ]
        for offset in cornerOffsets where offset < rgbaBytes.count {
            if rgbaBytes[offset] < 255 {
                cachedHasTransparency = true
                return true
            }
        }
        let found = rgbaBytes.withUnsafeBytes { raw -> Bool in
            let pixelCount = raw.count / 4
            guard pixelCount > 0 else { return false }
            // Big-endian RGBA8 stores alpha in byte[3], which maps to `UInt32(bigEndian: 0x0000_00FF)` on any host endianness.
            let alphaMask = UInt32(bigEndian: 0x0000_00FF)
            let simdMask = SIMD16<UInt32>(repeating: alphaMask)
            var acc = simdMask
            let limit = pixelCount - (pixelCount % 16)
            var i = 0
            while i < limit {
                let chunk = raw.loadUnaligned(fromByteOffset: i * 4, as: SIMD16<UInt32>.self)
                acc &= chunk
                i += 16
                if (i & 1023) == 0 && acc != simdMask {
                    return true
                }
            }
            if acc != simdMask {
                return true
            }
            while i < pixelCount {
                let px = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                if (px & alphaMask) != alphaMask {
                    return true
                }
                i += 1
            }
            return false
        }
        cachedHasTransparency = found
        return found
    }

    private func pixelatedImage(blockPixels: Int) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard let srcDims = Self.checkedRGBA8Dimensions(width: width, height: height),
              let srcBytes = ensureBaseRGBABuffer()
        else {
            return nil
        }
        let srcBytesPerRow = srcDims.bytesPerRow
        let preserveAlpha = bufferHasTransparency(srcBytes)

        let gridWidth = max(1, Int(ceil(Double(width) / Double(blockPixels))))
        let gridHeight = max(1, Int(ceil(Double(height) / Double(blockPixels))))
        guard let gridDims = Self.checkedRGBA8Dimensions(width: gridWidth, height: gridHeight) else {
            return nil
        }
        let gridBytesPerRow = gridDims.bytesPerRow
        var gridBytes = [UInt8](repeating: 0, count: gridDims.byteCount)

        let scaleError: vImage_Error = srcBytes.withUnsafeBytes { srcRaw in
            gridBytes.withUnsafeMutableBytes { gridRaw in
                guard let srcBase = srcRaw.baseAddress, let gridBase = gridRaw.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var srcBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcBase),
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: srcBytesPerRow
                )
                var gridBuffer = vImage_Buffer(
                    data: gridBase,
                    height: vImagePixelCount(gridHeight),
                    width: vImagePixelCount(gridWidth),
                    rowBytes: gridBytesPerRow
                )
                return vImageScale_ARGB8888(
                    &srcBuffer,
                    &gridBuffer,
                    nil,
                    vImage_Flags(kvImageHighQualityResampling)
                )
            }
        }
        guard scaleError == kvImageNoError else { return nil }

        // Emphasize faint averaged strokes on light UI backgrounds and add subtle checkerboard contrast
        // so mosaic tiles remain clearly readable without blowing out light grays toward white.
        for row in 0..<gridHeight {
            for col in 0..<gridWidth {
                let offset = row * gridBytesPerRow + col * 4
                let rawAlpha = gridBytes[offset + 3]
                guard rawAlpha > 0 else {
                    // Resampling can round sparse coverage down to zero. Keep the tile opaque
                    // until destination-in restores the original per-pixel alpha.
                    Self.writeOpaqueFallback(into: &gridBytes, at: offset)
                    continue
                }

                let alpha = Float(rawAlpha) / 255.0
                var r = min(1.0, (Float(gridBytes[offset]) / 255.0) / alpha)
                var g = min(1.0, (Float(gridBytes[offset + 1]) / 255.0) / alpha)
                var b = min(1.0, (Float(gridBytes[offset + 2]) / 255.0) / alpha)

                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                if luma > 0.65 && luma < 0.995 {
                    r = pow(r, 1.35)
                    g = pow(g, 1.35)
                    b = pow(b, 1.35)
                }

                let shift: Float = ((col + row) & 1) == 0 ? 0.015 : -0.045
                r = min(max(r + shift, 0.0), 1.0)
                g = min(max(g + shift, 0.0), 1.0)
                b = min(max(b + shift, 0.0), 1.0)

                // When masking by `baseImage`'s alpha below, emit opaque normalized tile colors so
                // blocks straddling transparent rounded corners never bleed unredacted interior pixels
                // or double-attenuate semi-transparent regions.
                let outAlpha: Float = preserveAlpha ? 1.0 : alpha
                gridBytes[offset] = UInt8((r * outAlpha * 255.0).rounded())
                gridBytes[offset + 1] = UInt8((g * outAlpha * 255.0).rounded())
                gridBytes[offset + 2] = UInt8((b * outAlpha * 255.0).rounded())
                if preserveAlpha {
                    gridBytes[offset + 3] = 255
                }
            }
        }

        let gridCGImage: CGImage? = gridBytes.withUnsafeMutableBytes { gridRaw in
            guard let gridBase = gridRaw.baseAddress,
                  let gridContext = makeRGBA8Context(
                      data: gridBase,
                      width: gridWidth,
                      height: gridHeight,
                      bytesPerRow: gridBytesPerRow
                  )
            else {
                return nil
            }
            return gridContext.makeImage()
        }
        guard let gridCGImage else { return nil }

        guard let outContext = makeRGBA8Context(
            data: nil,
            width: width,
            height: height,
            bytesPerRow: srcBytesPerRow
        ) else {
            return nil
        }

        outContext.interpolationQuality = .none
        let scaledWidth = CGFloat(gridWidth) * CGFloat(blockPixels)
        let scaledHeight = CGFloat(gridHeight) * CGFloat(blockPixels)
        // Align row 0 of the grid with the top edge (y = height in bottom-left CG coordinates).
        let targetRect = CGRect(
            x: 0,
            y: CGFloat(height) - scaledHeight,
            width: scaledWidth,
            height: scaledHeight
        )
        outContext.draw(gridCGImage, in: targetRect)
        if preserveAlpha {
            outContext.setBlendMode(.destinationIn)
            outContext.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return outContext.makeImage()
    }

    private func blurredImage(radius: CGFloat) -> CGImage? {
        if let gpuImage = gpuBlurredImage(radius: radius) {
            return gpuImage
        }
        return cpuBlurredImage(radius: radius)
    }

    internal func gpuBlurCIImage(radius: CGFloat) -> CIImage? {
        guard radius.isFinite, radius > 0 else { return nil }
        let safeRadius = min(max(radius, 0.5), Self.maxBlurRadiusPixels)
        let ciSource = ensureCISource()
        let extent = ciSource.extent
        let preserveAlpha = cachedHasTransparency ?? Self.mayHaveTransparency(baseImage)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(ciSource.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(safeRadius, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return nil }

        // Normalize premultiplied blur alpha before saturation and frosted veil so interior pixels
        // near transparent rounded corners retain full opacity and avoid dark halos; final output
        // is masked strictly back to `ciSource`'s alpha via `CISourceInCompositing`.
        let normalizedBlur: CIImage = preserveAlpha
            ? blurred.unpremultiplyingAlpha().settingAlphaOne(in: extent)
            : blurred

        let saturated: CIImage
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(normalizedBlur, forKey: kCIInputImageKey)
            colorControls.setValue(1.12, forKey: kCIInputSaturationKey)
            saturated = colorControls.outputImage?.cropped(to: extent) ?? normalizedBlur
        } else {
            saturated = normalizedBlur
        }

        let composited: CIImage
        if let sourceOver = CIFilter(name: "CISourceOverCompositing") {
            let veil = CIImage(color: Self.frostedVeilColor).cropped(to: extent)
            sourceOver.setValue(veil, forKey: kCIInputImageKey)
            sourceOver.setValue(saturated, forKey: kCIInputBackgroundImageKey)
            composited = sourceOver.outputImage?.cropped(to: extent) ?? saturated
        } else {
            composited = saturated
        }

        if preserveAlpha, let sourceIn = CIFilter(name: "CISourceInCompositing") {
            sourceIn.setValue(composited, forKey: kCIInputImageKey)
            sourceIn.setValue(ciSource, forKey: kCIInputBackgroundImageKey)
            return sourceIn.outputImage?.cropped(to: extent) ?? composited
        }
        return composited
    }

    internal func gpuBlurredImage(radius: CGFloat) -> CGImage? {
        guard let masked = gpuBlurCIImage(radius: radius) else { return nil }
        let extent = ensureCISource().extent
        didUseGPUContext = true
        return Self.sharedCIContext.createCGImage(masked, from: extent, format: .RGBA8, colorSpace: rgbColorSpace)
            ?? Self.sharedCIContext.createCGImage(masked, from: extent)
    }

    internal func cpuBlurredImage(radius: CGFloat) -> CGImage? {
        guard radius.isFinite, radius > 0 else { return nil }
        let safeRadius = min(max(radius, 1), Self.maxBlurRadiusPixels)
        let width = baseImage.width
        let height = baseImage.height
        guard let dims = Self.checkedRGBA8Dimensions(width: width, height: height),
              let srcBytes = ensureBaseRGBABuffer()
        else {
            return nil
        }
        let srcBytesPerRow = dims.bytesPerRow
        let preserveAlpha = bufferHasTransparency(srcBytes)

        // Allocate the CGContext-owned destination directly so `outContext.makeImage()` transfers
        // ownership without copying a second full-resolution bitmap.
        guard let outContext = makeRGBA8Context(
            data: nil,
            width: width,
            height: height,
            bytesPerRow: srcBytesPerRow
        ), let dstBase = outContext.data else {
            return nil
        }
        let dstBytesPerRow = outContext.bytesPerRow
        guard dstBytesPerRow >= srcBytesPerRow else { return nil }

        let minDim = min(width, height)
        let maxOddKernel = minDim % 2 == 1 ? minDim : max(1, minDim - 1)
        let desiredOdd = max(3, Int((safeRadius * 1.2).rounded()) | 1)
        let kernel = UInt32(max(1, min(maxOddKernel, desiredOdd)))

        let convolveError: vImage_Error = srcBytes.withUnsafeBytes { srcRaw in
            guard let srcBase = srcRaw.baseAddress else {
                return kvImageNullPointerArgument
            }
            var srcBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: srcBase),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: srcBytesPerRow
            )
            var dstBuffer = vImage_Buffer(
                data: dstBase,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: dstBytesPerRow
            )
            var unusedBackground: [UInt8] = [0, 0, 0, 0]
            return vImageTentConvolve_ARGB8888(
                &srcBuffer,
                &dstBuffer,
                nil,
                0,
                0,
                kernel,
                kernel,
                &unusedBackground,
                vImage_Flags(kvImageEdgeExtend)
            )
        }
        guard convolveError == kvImageNoError else { return nil }

        if preserveAlpha {
            let dstPtr = dstBase.assumingMemoryBound(to: UInt8.self)
            srcBytes.withUnsafeBufferPointer { srcPtr in
                guard let srcBase = srcPtr.baseAddress else { return }
                for row in 0..<height {
                    let srcRow = row * srcBytesPerRow
                    let dstRow = row * dstBytesPerRow
                    for col in 0..<width {
                        let colOff = col * 4
                        let srcA = srcBase[srcRow + colOff + 3]
                        let dstOff = dstRow + colOff
                        guard srcA > 0 else {
                            dstPtr[dstOff] = 0
                            dstPtr[dstOff + 1] = 0
                            dstPtr[dstOff + 2] = 0
                            dstPtr[dstOff + 3] = 0
                            continue
                        }
                        let dstA = dstPtr[dstOff + 3]
                        if dstA == 0 {
                            dstPtr[dstOff] = 46
                            dstPtr[dstOff + 1] = 46
                            dstPtr[dstOff + 2] = 51
                            dstPtr[dstOff + 3] = 255
                        } else if dstA < 255 {
                            let inv = 255.0 / Float(dstA)
                            dstPtr[dstOff] = UInt8(min(255, Int((Float(dstPtr[dstOff]) * inv).rounded())))
                            dstPtr[dstOff + 1] = UInt8(min(255, Int((Float(dstPtr[dstOff + 1]) * inv).rounded())))
                            dstPtr[dstOff + 2] = UInt8(min(255, Int((Float(dstPtr[dstOff + 2]) * inv).rounded())))
                            dstPtr[dstOff + 3] = 255
                        }
                    }
                }
            }
        }

        let veilCG = CGColor(srgbRed: 0.557, green: 0.600, blue: 0.659, alpha: 0.08)
        outContext.setFillColor(veilCG)
        outContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if preserveAlpha {
            outContext.setBlendMode(.destinationIn)
            outContext.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return outContext.makeImage()
    }

    private static func writeOpaqueFallback(into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = 46
        bytes[offset + 1] = 46
        bytes[offset + 2] = 51
        bytes[offset + 3] = 255
    }
}
