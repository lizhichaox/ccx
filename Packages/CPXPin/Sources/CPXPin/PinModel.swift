import CoreGraphics
import CPXCore
import Foundation

/// What a pin displays.
public enum PinContent: Sendable {
    /// A bitmap with its pixels-per-point scale (2 for Retina captures).
    case image(CGImage, scale: CGFloat)
    case text(String)
    case color(CPXColorSample)
}

/// Mutable presentation state of a pin. All setters clamp to valid ranges.
public struct PinState: Equatable, Sendable {
    public static let zoomRange: ClosedRange<CGFloat> = 0.1...10.0
    public static let opacityRange: ClosedRange<CGFloat> = 0.1...1.0

    public var zoom: CGFloat = 1.0 {
        didSet { zoom = Self.clamp(zoom, to: Self.zoomRange, fallback: 1.0) }
    }

    public var opacity: CGFloat = 1.0 {
        didSet { opacity = Self.clamp(opacity, to: Self.opacityRange, fallback: 1.0) }
    }

    /// Clockwise rotation in degrees, normalized to `0..<360`.
    public var rotationDegrees: Int = 0 {
        didSet { rotationDegrees = Self.normalize(rotationDegrees) }
    }

    public var isClickThrough: Bool = false
    public var isThumbnail: Bool = false
    public var showsBorder: Bool = true
    public var showsShadow: Bool = true

    public init(
        zoom: CGFloat = 1.0,
        opacity: CGFloat = 1.0,
        rotationDegrees: Int = 0,
        isClickThrough: Bool = false,
        isThumbnail: Bool = false,
        showsBorder: Bool = true,
        showsShadow: Bool = true
    ) {
        self.zoom = Self.clamp(zoom, to: Self.zoomRange, fallback: 1.0)
        self.opacity = Self.clamp(opacity, to: Self.opacityRange, fallback: 1.0)
        self.rotationDegrees = Self.normalize(rotationDegrees)
        self.isClickThrough = isClickThrough
        self.isThumbnail = isThumbnail
        self.showsBorder = showsBorder
        self.showsShadow = showsShadow
    }

    public mutating func setZoom(_ value: CGFloat) { zoom = value }

    /// Multiplies the zoom by `factor` (e.g. `1.1` per scroll notch).
    public mutating func multiplyZoom(by factor: CGFloat) { zoom *= factor }

    public mutating func resetZoom() { zoom = 1.0 }

    public mutating func setOpacity(_ value: CGFloat) { opacity = value }

    public mutating func adjustOpacity(by delta: CGFloat) { opacity += delta }

    public mutating func rotate(byDegrees degrees: Int) { rotationDegrees += degrees }

    public mutating func rotateClockwise() { rotate(byDegrees: 90) }

    public mutating func toggleClickThrough() { isClickThrough.toggle() }

    public mutating func toggleThumbnail() { isThumbnail.toggle() }

    /// `true` when the rotation swaps width and height (90 or 270 degrees).
    public var isQuarterTurned: Bool { rotationDegrees % 180 == 90 }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalize(_ degrees: Int) -> Int {
        let value = degrees % 360
        return value < 0 ? value + 360 : value
    }
}
