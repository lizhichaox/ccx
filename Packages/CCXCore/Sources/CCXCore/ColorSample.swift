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
    /// Works for any source pixel format, bit depth, or color space by drawing the
    /// single pixel into a 1x1 RGBA8 sRGB bitmap (color-managed conversion). Returns
    /// `nil` when the coordinates fall outside the image.
    public static func samplePixel(from image: CGImage, pixelX: Int, pixelY: Int) -> CCXColorSample? {
        guard pixelX >= 0, pixelY >= 0, pixelX < image.width, pixelY < image.height else { return nil }
        guard let pixelImage = image.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }

        let alpha = pixel[3]
        func unpremultiply(_ value: UInt8) -> UInt8 {
            guard alpha > 0, alpha < 255 else { return alpha == 0 ? 0 : value }
            return UInt8(min(255, (Double(value) * 255 / Double(alpha)).rounded()))
        }
        return CCXColorSample(
            red: unpremultiply(pixel[0]),
            green: unpremultiply(pixel[1]),
            blue: unpremultiply(pixel[2]),
            alpha: alpha,
            colorSpaceName: "sRGB"
        )
    }
}
