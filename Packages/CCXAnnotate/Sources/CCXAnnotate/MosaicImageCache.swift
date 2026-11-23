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
        let strength: Int
    }

    private static let maxCachedVariants = 8
    private static let rgbaBitmapInfo: UInt32 =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    private static let frostedVeilColor = CIColor(red: 0.557, green: 0.600, blue: 0.659, alpha: 0.08)

    private static let sharedCIContext: CIContext = {
        // Prefer Metal GPU context; CPU fallbacks handle headless sandboxes where createCGImage returns nil.
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    public let baseImage: CGImage
    private lazy var ciSource = CIImage(cgImage: baseImage)
    private lazy var rgbColorSpace: CGColorSpace = Self.resolvedRGBColorSpace(for: baseImage)
    private var cache: [CacheKey: CGImage] = [:]
    private var accessOrder: [CacheKey] = []

    public init(baseImage: CGImage) {
        self.baseImage = baseImage
    }

    public func filteredImage(mode: MosaicMode, size: StrokeSize, backingScale: CGFloat) -> CGImage? {
        guard baseImage.width > 0, baseImage.height > 0 else { return nil }
        let strength = mode == .pixelate ? Int(size.mosaicBlockSize.rounded()) : Int(size.blurRadius.rounded())
        let key = CacheKey(mode: mode, strength: strength)
        if let cached = cache[key] {
            touchCacheKey(key)
            return cached
        }

        let scale = max(backingScale, 1)
        let result: CGImage?
        switch mode {
        case .pixelate:
            let blockPixels = max(4, Int((size.mosaicBlockSize * scale).rounded()))
            result = pixelatedImage(blockPixels: blockPixels)
        case .blur:
            let radius = size.blurRadius * scale
            result = blurredImage(radius: radius)
        }

        if let result {
            cache[key] = result
            touchCacheKey(key)
            while cache.count > Self.maxCachedVariants, let evicted = accessOrder.first {
                accessOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
        return result
    }

    private func touchCacheKey(_ key: CacheKey) {
        if let existingIndex = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: existingIndex)
        }
        accessOrder.append(key)
    }

    private static func resolvedRGBColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func renderRGBA8Buffer(width: Int, height: Int, bytesPerRow: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        let rendered = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: rgbColorSpace,
                      bitmapInfo: Self.rgbaBitmapInfo
                  )
            else {
                return false
            }
            context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? bytes : nil
    }

    private func pixelatedImage(blockPixels: Int) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        let srcBytesPerRow = width * 4
        guard var srcBytes = renderRGBA8Buffer(width: width, height: height, bytesPerRow: srcBytesPerRow) else {
            return nil
        }

        let gridWidth = max(1, Int(ceil(Double(width) / Double(blockPixels))))
        let gridHeight = max(1, Int(ceil(Double(height) / Double(blockPixels))))
        let gridBytesPerRow = gridWidth * 4
        var gridBytes = [UInt8](repeating: 0, count: gridHeight * gridBytesPerRow)

        let scaleError: vImage_Error = srcBytes.withUnsafeMutableBytes { srcRaw in
            gridBytes.withUnsafeMutableBytes { gridRaw in
                guard let srcBase = srcRaw.baseAddress, let gridBase = gridRaw.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var srcBuffer = vImage_Buffer(
                    data: srcBase,
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
                guard rawAlpha > 0 else { continue }

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

                gridBytes[offset] = UInt8((r * alpha * 255.0).rounded())
                gridBytes[offset + 1] = UInt8((g * alpha * 255.0).rounded())
                gridBytes[offset + 2] = UInt8((b * alpha * 255.0).rounded())
            }
        }

        let gridCGImage: CGImage? = gridBytes.withUnsafeMutableBytes { gridRaw in
            guard let gridBase = gridRaw.baseAddress,
                  let gridContext = CGContext(
                      data: gridBase,
                      width: gridWidth,
                      height: gridHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: gridBytesPerRow,
                      space: rgbColorSpace,
                      bitmapInfo: Self.rgbaBitmapInfo
                  )
            else {
                return nil
            }
            return gridContext.makeImage()
        }
        guard let gridCGImage else { return nil }

        guard let outContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: srcBytesPerRow,
            space: rgbColorSpace,
            bitmapInfo: Self.rgbaBitmapInfo
        ) else {
            return nil
        }

        outContext.interpolationQuality = .none
        let scaledWidth = CGFloat(gridWidth * blockPixels)
        let scaledHeight = CGFloat(gridHeight * blockPixels)
        // Align row 0 of the grid with the top edge (y = height in bottom-left CG coordinates).
        let targetRect = CGRect(
            x: 0,
            y: CGFloat(height) - scaledHeight,
            width: scaledWidth,
            height: scaledHeight
        )
        outContext.draw(gridCGImage, in: targetRect)
        return outContext.makeImage()
    }

    private func blurredImage(radius: CGFloat) -> CGImage? {
        if let gpuImage = gpuBlurredImage(radius: radius) {
            return gpuImage
        }
        return cpuBlurredImage(radius: radius)
    }

    private func gpuBlurredImage(radius: CGFloat) -> CGImage? {
        let extent = ciSource.extent
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(ciSource.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return nil }

        let saturated: CIImage
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(blurred, forKey: kCIInputImageKey)
            colorControls.setValue(1.12, forKey: kCIInputSaturationKey)
            saturated = colorControls.outputImage?.cropped(to: extent) ?? blurred
        } else {
            saturated = blurred
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

        return Self.sharedCIContext.createCGImage(composited, from: extent)
    }

    private func cpuBlurredImage(radius: CGFloat) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        let bytesPerRow = width * 4
        guard var srcBytes = renderRGBA8Buffer(width: width, height: height, bytesPerRow: bytesPerRow) else {
            return nil
        }

        var dstBytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        let minDim = min(width, height)
        let maxOddKernel = minDim % 2 == 1 ? minDim : max(1, minDim - 1)
        let desiredOdd = max(3, Int((radius * 1.2).rounded()) | 1)
        let kernel = UInt32(max(1, min(maxOddKernel, desiredOdd)))

        let convolveError: vImage_Error = srcBytes.withUnsafeMutableBytes { srcRaw in
            dstBytes.withUnsafeMutableBytes { dstRaw in
                guard let srcBase = srcRaw.baseAddress, let dstBase = dstRaw.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var srcBuffer = vImage_Buffer(
                    data: srcBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                var dstBuffer = vImage_Buffer(
                    data: dstBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
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
        }
        guard convolveError == kvImageNoError else { return nil }

        return dstBytes.withUnsafeMutableBytes { dstRaw in
            guard let dstBase = dstRaw.baseAddress,
                  let outContext = CGContext(
                      data: dstBase,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: rgbColorSpace,
                      bitmapInfo: Self.rgbaBitmapInfo
                  )
            else {
                return nil
            }
            let veilCG = CGColor(srgbRed: 0.557, green: 0.600, blue: 0.659, alpha: 0.08)
            outContext.setFillColor(veilCG)
            outContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return outContext.makeImage()
        }
    }
}
