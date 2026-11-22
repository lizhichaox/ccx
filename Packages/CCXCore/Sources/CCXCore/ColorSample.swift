import AppKit
import CoreGraphics
import Foundation

/// Text representations offered by the color picker.
public enum ColorFormat: String, CaseIterable, Sendable, Codable {
    case hex
    case rgb
    case hsl

    /// The format that follows this one when cycling (HEX -> RGB -> HSL -> HEX).
    public var next: ColorFormat {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// Short human-readable label.
    public var displayName: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        }
    }
}

/// An 8-bit-per-channel color sampled from the screen (or parsed from text).
public struct CCXColorSample: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8
    /// Name of the color space the channel values are expressed in (e.g. `"sRGB"`).
    public let colorSpaceName: String

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255, colorSpaceName: String = "sRGB") {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.colorSpaceName = colorSpaceName
    }

    /// Uppercase `#RRGGBB` (alpha is omitted).
    public var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// CSS-style `rgb(r, g, b)`.
    public var rgbString: String {
        "rgb(\(red), \(green), \(blue))"
    }

    /// CSS-style `hsl(h, s%, l%)` with integer components.
    public var hslString: String {
        let (h, s, l) = hslComponents
        return "hsl(\(h), \(s)%, \(l)%)"
    }

    /// Hue in degrees `0..<360`, saturation and lightness in percent `0...100`.
    public var hslComponents: (hue: Int, saturation: Int, lightness: Int) {
        let r = Double(red) / 255
        let g = Double(green) / 255
        let b = Double(blue) / 255
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let lightness = (maxC + minC) / 2

        var hue = 0.0
        var saturation = 0.0
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            switch maxC {
            case r: hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = 60 * ((b - r) / delta + 2)
            default: hue = 60 * ((r - g) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        let h = Int(hue.rounded()) % 360
        return (h, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }

    /// An `NSColor` in the sample's color space (Display P3 when tagged as such, sRGB otherwise).
    public var nsColor: NSColor {
        let r = CGFloat(red) / 255
        let g = CGFloat(green) / 255
        let b = CGFloat(blue) / 255
        let a = CGFloat(alpha) / 255
        if colorSpaceName == "Display P3" {
            return NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public func formatted(as format: ColorFormat) -> String {
        switch format {
        case .hex: hexString
        case .rgb: rgbString
        case .hsl: hslString
        }
    }

    /// Parses `#RRGGBB`, `#RRGGBBAA`, `RRGGBB`, `RRGGBBAA`, `0xRRGGBB`, and the short
    /// forms `#RGB` / `#RGBA` (short forms require a `#` or `0x` prefix so ordinary words
    /// such as "add" are not mistaken for colors). Surrounding whitespace is ignored.
    public static func parseHex(_ string: String) -> CCXColorSample? {
        var body = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        var hasPrefix = false
        if body.hasPrefix("#") {
            body = body.dropFirst()
            hasPrefix = true
        } else if body.hasPrefix("0x") || body.hasPrefix("0X") {
            body = body.dropFirst(2)
            hasPrefix = true
        }

        let scalars = Array(body.unicodeScalars)
        guard !scalars.isEmpty, scalars.allSatisfy(isASCIIHexDigit) else { return nil }

        var digits: [UInt8] = scalars.compactMap { UInt8(String($0), radix: 16) }
        switch digits.count {
        case 3, 4:
            guard hasPrefix else { return nil }
            digits = digits.flatMap { [$0, $0] }
        case 6, 8:
            break
        default:
            return nil
        }

        func byte(_ index: Int) -> UInt8 { digits[index] << 4 | digits[index + 1] }
        let alpha: UInt8 = digits.count == 8 ? byte(6) : 255
        return CCXColorSample(red: byte(0), green: byte(2), blue: byte(4), alpha: alpha)
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."f", "A"..."F": true
        default: false
        }
    }

    /// Samples one pixel of `image` at pixel coordinates with a top-left origin.
    ///
    /// Uses a zero-allocation direct byte read when the image is 8-bit sRGB RGBA/BGRA,
    /// falling back to a reusable color-managed 1x1 sRGB `CGContext` for wide-gamut or
    /// other pixel formats. Returns `nil` when the coordinates fall outside the image.
    public static func samplePixel(from image: CGImage, pixelX: Int, pixelY: Int) -> CCXColorSample? {
        guard pixelX >= 0, pixelY >= 0, pixelX < image.width, pixelY < image.height else { return nil }

        if let direct = sampleDirectSRGBPixel(from: image, pixelX: pixelX, pixelY: pixelY) {
            return direct
        }

        guard let pixelImage = image.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)),
              let (r, g, b, alpha) = SampleContextCache.shared.sample(pixelImage: pixelImage)
        else { return nil }

        return makeUnpremultipliedSample(r: r, g: g, b: b, alpha: alpha)
    }

    private static func sampleDirectSRGBPixel(from image: CGImage, pixelX: Int, pixelY: Int) -> CCXColorSample? {
        guard image.bitsPerComponent == 8,
              image.bitsPerPixel == 32,
              image.colorSpace?.name == CGColorSpace.sRGB
        else { return nil }

        let byteOrder = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        let alphaInfo = image.alphaInfo

        let isRGBA = (byteOrder.rawValue == 0 || byteOrder == .byteOrder32Big)
            && (alphaInfo == .last || alphaInfo == .premultipliedLast || alphaInfo == .noneSkipLast)
        let isBGRA = (byteOrder == .byteOrder32Little)
            && (alphaInfo == .first || alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst)
        guard isRGBA || isBGRA else { return nil }

        guard let provider = image.dataProvider,
              let cfData = provider.data,
              let ptr = CFDataGetBytePtr(cfData)
        else { return nil }

        let offset = pixelY * image.bytesPerRow + pixelX * 4
        guard offset >= 0, offset + 4 <= CFDataGetLength(cfData) else { return nil }

        let b0 = ptr[offset]
        let b1 = ptr[offset + 1]
        let b2 = ptr[offset + 2]
        let b3 = ptr[offset + 3]

        let rawR = isRGBA ? b0 : b2
        let rawG = b1
        let rawB = isRGBA ? b2 : b0
        let alpha: UInt8 = (alphaInfo == .noneSkipLast || alphaInfo == .noneSkipFirst) ? 255 : b3

        let isPremultiplied = (alphaInfo == .premultipliedLast || alphaInfo == .premultipliedFirst)
        if isPremultiplied {
            return makeUnpremultipliedSample(r: rawR, g: rawG, b: rawB, alpha: alpha)
        }
        return CCXColorSample(red: rawR, green: rawG, blue: rawB, alpha: alpha, colorSpaceName: "sRGB")
    }

    private static func makeUnpremultipliedSample(r: UInt8, g: UInt8, b: UInt8, alpha: UInt8) -> CCXColorSample {
        func unpremultiply(_ value: UInt8) -> UInt8 {
            guard alpha > 0, alpha < 255 else { return alpha == 0 ? 0 : value }
            return UInt8(min(255, (Double(value) * 255 / Double(alpha)).rounded()))
        }
        return CCXColorSample(
            red: unpremultiply(r),
            green: unpremultiply(g),
            blue: unpremultiply(b),
            alpha: alpha,
            colorSpaceName: "sRGB"
        )
    }
}

private final class SampleContextCache: @unchecked Sendable {
    static let shared = SampleContextCache()

    private let lock = NSLock()
    private let pixelBytes: UnsafeMutablePointer<UInt8>
    private let context: CGContext?

    private init() {
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        bytes.initialize(repeating: 0, count: 4)
        self.pixelBytes = bytes
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        self.context = CGContext(
            data: bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    deinit {
        pixelBytes.deallocate()
    }

    func sample(pixelImage: CGImage) -> (UInt8, UInt8, UInt8, UInt8)? {
        lock.lock()
        defer { lock.unlock() }
        guard let context else { return nil }
        pixelBytes.initialize(repeating: 0, count: 4)
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixelBytes[0], pixelBytes[1], pixelBytes[2], pixelBytes[3])
    }
}
