import CoreGraphics
import Foundation

/// Resolution-normalized sRGB visual fingerprint used to identify matching images across
/// capture history, clipboard round-trips, and active floating pins.
public struct ImageFingerprint: Equatable, Sendable {
    private static let sampleSide = 48
    private static let channelTolerance = 2
    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    public let pixelWidth: Int
    public let pixelHeight: Int
    private let rgbaSamples: [UInt8]

    public init(image: CGImage) {
        self.pixelWidth = image.width
        self.pixelHeight = image.height
        self.rgbaSamples = Self.computeSamples(from: image)
    }

    /// Returns `true` when both images have identical pixel dimensions and every normalized
    /// sRGB channel sample matches within `<= 2` levels (absorbing PNG/colorspace rounding).
    public func matches(_ other: ImageFingerprint) -> Bool {
        guard pixelWidth == other.pixelWidth,
              pixelHeight == other.pixelHeight,
              !rgbaSamples.isEmpty,
              rgbaSamples.count == other.rgbaSamples.count
        else { return false }

        for idx in 0..<rgbaSamples.count {
            if abs(Int(rgbaSamples[idx]) - Int(other.rgbaSamples[idx])) > Self.channelTolerance {
                return false
            }
        }
        return true
    }

    private static func computeSamples(from image: CGImage) -> [UInt8] {
        guard image.width > 0, image.height > 0, let colorSpace = sRGBColorSpace else { return [] }
        let side = sampleSide
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: side * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = buffer.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.clear(CGRect(x: 0, y: 0, width: side, height: side))
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? buffer : []
    }
}

/// Content identity used to prevent duplicate on-screen pins for the same image, text, or color.
public enum PinContentIdentity: Equatable, Sendable {
    case image(ImageFingerprint, historyEntryID: UUID? = nil)
    case text(String)
    case color(CCXColorSample)

    public func matches(_ other: PinContentIdentity) -> Bool {
        switch (self, other) {
        case let (.image(lhsFP, lhsID), .image(rhsFP, rhsID)):
            if let lhsID, let rhsID, lhsID == rhsID {
                return true
            }
            return lhsFP.matches(rhsFP)
        case let (.text(lhs), .text(rhs)):
            return lhs == rhs
        case let (.color(lhs), .color(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}
