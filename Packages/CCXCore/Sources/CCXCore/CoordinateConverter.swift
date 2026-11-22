import CoreGraphics
import Foundation

/// Coordinate transforms between the Quartz (CoreGraphics, top-left origin, y down)
/// and AppKit (bottom-left origin, y up) global screen spaces, plus helpers for
/// mapping screen points onto captured image pixels.
///
/// Both global spaces are anchored to the primary display (the one whose AppKit
/// frame origin is `(0, 0)`), so converting only requires the primary screen height.
public enum CoordinateConverter {
    /// Returns the height of the primary display given the AppKit frames of all screens
    /// (e.g. `NSScreen.screens.map(\.frame)`).
    ///
    /// The primary display is the screen whose AppKit origin is `(0, 0)`. Falls back to
    /// the first screen when no frame sits at the origin, and to `0` for an empty list.
    public static func primaryScreenHeight(screens: [CGRect]) -> CGFloat {
        if let primary = screens.first(where: { $0.origin == .zero }) {
            return primary.height
        }
        return screens.first?.height ?? 0
    }

    /// Converts a Quartz global rect (top-left origin) into an AppKit global rect
    /// (bottom-left origin).
    public static func quartzToAppKit(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts an AppKit global rect (bottom-left origin) into a Quartz global rect
    /// (top-left origin). The transform is its own inverse.
    public static func appKitToQuartz(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts an AppKit global point (bottom-left origin) into a Quartz global point
    /// (top-left origin).
    public static func appKitToQuartz(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Maps a rect expressed in AppKit coordinates *local to a screen* (origin at the
    /// screen's bottom-left corner, in points) onto the pixel grid of an image captured
    /// from that whole screen (origin at the image's top-left corner, in pixels).
    ///
    /// Edges are rounded to the nearest pixel and the result is clamped to the image
    /// bounds, so the returned rect is always integral and safe to pass to
    /// `CGImage.cropping(to:)`. Returns `.zero` for degenerate inputs.
    public static func appKitLocalRectToImagePixelRect(
        _ localRect: CGRect,
        screenSize: CGSize,
        imageSize: CGSize
    ) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0,
              imageSize.width > 0, imageSize.height > 0
        else { return .zero }

        let rect = localRect.standardized
        let scaleX = imageSize.width / screenSize.width
        let scaleY = imageSize.height / screenSize.height

        // Flip Y: AppKit local maxY corresponds to the top edge in image space.
        var minX = (rect.minX * scaleX).rounded()
        var maxX = (rect.maxX * scaleX).rounded()
        var minY = ((screenSize.height - rect.maxY) * scaleY).rounded()
        var maxY = ((screenSize.height - rect.minY) * scaleY).rounded()

        minX = min(max(minX, 0), imageSize.width)
        maxX = min(max(maxX, 0), imageSize.width)
        minY = min(max(minY, 0), imageSize.height)
        maxY = min(max(maxY, 0), imageSize.height)

        guard maxX > minX, maxY > minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Snaps a rect onto the integer grid with an even width and height (as required by
    /// H.264/HEVC encoders). The origin is rounded to the nearest integer and each
    /// dimension is rounded down to an even number, with a minimum of `2`.
    public static func snapToEvenPixels(_ rect: CGRect) -> CGRect {
        let rect = rect.standardized
        let x = rect.minX.rounded()
        let y = rect.minY.rounded()
        func even(_ value: CGFloat) -> CGFloat {
            let floored = Int(max(value.rounded(.down), 0))
            return CGFloat(max(floored - floored % 2, 2))
        }
        return CGRect(x: x, y: y, width: even(rect.width), height: even(rect.height))
    }
}
