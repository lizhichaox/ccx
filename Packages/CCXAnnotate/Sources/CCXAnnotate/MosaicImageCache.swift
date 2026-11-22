import CoreGraphics
import CoreImage
import Metal

/// Lazy GPU-accelerated cache of full-display pixelated / blurred variants of the frozen screenshot.
///
/// Generating once per `(mode, size)` keeps live dragging of mosaic/blur rectangles locked at 120 Hz.
@MainActor
public final class MosaicImageCache {
    private struct CacheKey: Hashable {
        let mode: MosaicMode
        let preset: StrokePreset
    }

    private static let sharedCIContext: CIContext = {
        // Prefer Metal 4/GPU context; fall back cleanly to software CIContext in headless sandboxes.
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    public let baseImage: CGImage
    private lazy var ciSource = CIImage(cgImage: baseImage)
    private var cache: [CacheKey: CGImage] = [:]

    public init(baseImage: CGImage) {
        self.baseImage = baseImage
    }

    public func filteredImage(mode: MosaicMode, preset: StrokePreset, backingScale: CGFloat) -> CGImage? {
        let key = CacheKey(mode: mode, preset: preset)
        if let cached = cache[key] { return cached }

        let scale = max(backingScale, 1)
        let extent = ciSource.extent
        let output: CIImage?

        switch mode {
        case .pixelate:
            let pixelSize = preset.mosaicRadius * scale
            let filter = CIFilter(name: "CIPixellate")
            filter?.setValue(ciSource, forKey: kCIInputImageKey)
            filter?.setValue(pixelSize, forKey: kCIInputScaleKey)
            filter?.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
            output = filter?.outputImage?.cropped(to: extent)

        case .blur:
            let blurRadius = preset.mosaicRadius * scale * 0.75
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(ciSource.clampedToExtent(), forKey: kCIInputImageKey)
            filter?.setValue(blurRadius, forKey: kCIInputRadiusKey)
            output = filter?.outputImage?.cropped(to: extent)
        }

        guard let output, let cgImage = Self.sharedCIContext.createCGImage(output, from: extent) else {
            return nil
        }
        cache[key] = cgImage
        return cgImage
    }
}
