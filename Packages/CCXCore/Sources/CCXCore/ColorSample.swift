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
        let clampedSaturation = min(max(saturation, 0), 1)
        let clampedLightness = min(max(lightness, 0), 1)
        return (h, Int((clampedSaturation * 100).rounded()), Int((clampedLightness * 100).rounded()))
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
        // Trim surrounding whitespace/newlines lazily on a slice so multi-MB clipboard strings
        // are rejected in O(1) without allocating a trimmed copy or scalar array.
        var start = string.startIndex
        var end = string.endIndex
        while start < end, string[start].isWhitespace || string[start].isNewline {
            string.formIndex(after: &start)
        }
        while end > start {
            let prev = string.index(before: end)
            if string[prev].isWhitespace || string[prev].isNewline {
                end = prev
            } else {
                break
            }
        }
        guard start < end else { return nil }

        var body = string[start..<end]
        // Longest valid representation is "0xRRGGBBAA" (10 ASCII bytes).
        guard body.utf8.count <= 10 else { return nil }

        var hasPrefix = false
        if body.hasPrefix("#") {
            body = body.dropFirst()
            hasPrefix = true
        } else if body.hasPrefix("0x") || body.hasPrefix("0X") {
            body = body.dropFirst(2)
            hasPrefix = true
        }

        let utf8 = body.utf8
        let count = utf8.count
        switch count {
        case 3, 4:
            guard hasPrefix else { return nil }
        case 6, 8:
            break
        default:
            return nil
        }

        var nibbles = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var idx = 0
        for byte in utf8 {
            guard let nibble = asciiHexValue(byte) else { return nil }
            withUnsafeMutableBytes(of: &nibbles) { ptr in
                ptr[idx] = nibble
            }
            idx += 1
        }

        if count == 3 || count == 4 {
            let r = (nibbles.0 << 4) | nibbles.0
            let g = (nibbles.1 << 4) | nibbles.1
            let b = (nibbles.2 << 4) | nibbles.2
            let a: UInt8 = count == 4 ? ((nibbles.3 << 4) | nibbles.3) : 255
            return CCXColorSample(red: r, green: g, blue: b, alpha: a)
        } else {
            let r = (nibbles.0 << 4) | nibbles.1
            let g = (nibbles.2 << 4) | nibbles.3
            let b = (nibbles.4 << 4) | nibbles.5
            let a: UInt8 = count == 8 ? ((nibbles.6 << 4) | nibbles.7) : 255
            return CCXColorSample(red: r, green: g, blue: b, alpha: a)
        }
    }

    private static func asciiHexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48           // '0'...'9'
        case 65...70: byte - 65 + 10      // 'A'...'F'
        case 97...102: byte - 97 + 10     // 'a'...'f'
        default: nil
        }
    }

    /// Samples one pixel of `image` at pixel coordinates with a top-left origin.
    ///
    /// Crops a 1x1 sub-image and draws into a reusable color-managed 1x1 sRGB `CGContext`,
    /// avoiding whole-framebuffer copies (`CGDataProviderCopyData`) while supporting sRGB,
    /// Display P3, HDR, BGRA, 16-bit, and grayscale images. Returns `nil` when the
    /// coordinates fall outside the image.
    public static func samplePixel(from image: CGImage, pixelX: Int, pixelY: Int) -> CCXColorSample? {
        guard pixelX >= 0, pixelY >= 0, pixelX < image.width, pixelY < image.height else { return nil }

        guard let pixelImage = image.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)),
              let (r, g, b, alpha) = SampleContextCache.shared.sample(pixelImage: pixelImage)
        else { return nil }

        return makeUnpremultipliedSample(r: r, g: g, b: b, alpha: alpha)
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
    private let context: CGContext?

    private init() {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            self.context = nil
            return
        }
        // Pass `data: nil` so CoreGraphics manages the 4-byte buffer lifetime cleanly.
        self.context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    func sample(pixelImage: CGImage) -> (UInt8, UInt8, UInt8, UInt8)? {
        lock.lock()
        defer { lock.unlock() }
        guard let context,
              let rawData = context.data
        else { return nil }
        let bytes = rawData.assumingMemoryBound(to: UInt8.self)
        bytes[0] = 0
        bytes[1] = 0
        bytes[2] = 0
        bytes[3] = 0
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
