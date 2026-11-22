import CoreGraphics
import CCXCore

/// A frozen, full-resolution image of a single display taken at the start of a snip session.
public struct DisplaySnapshot: Sendable {
    /// The Quartz display identifier (matches `NSScreen.deviceDescription["NSScreenNumber"]`).
    public let displayID: CGDirectDisplayID
    /// The display frame in AppKit global coordinates (points, bottom-left origin).
    public let screenFrame: CGRect
    /// The backing scale factor of the display (pixels per point).
    public let backingScaleFactor: CGFloat
    /// The captured display image in backing pixels.
    public let image: CGImage

    public init(displayID: CGDirectDisplayID, screenFrame: CGRect, backingScaleFactor: CGFloat, image: CGImage) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.backingScaleFactor = backingScaleFactor
        self.image = image
    }
}

/// The cropped result of a completed snip selection.
public struct SnipResult: Sendable {
    /// The cropped image in backing pixels.
    public let image: CGImage
    /// Pixels per point of `image` (e.g. `2.0` on Retina displays).
    public let scale: CGFloat
    /// The selected rectangle in AppKit global coordinates (points).
    public let screenRect: CGRect

    public init(image: CGImage, scale: CGFloat, screenRect: CGRect) {
        self.image = image
        self.scale = scale
        self.screenRect = screenRect
    }
}

/// The final outcome of a snip session.
public enum SnipOutcome: Sendable {
    case pin(SnipResult)
    case copy(SnipResult)
    case save(SnipResult)
    case copiedColor(CCXColorSample, ColorFormat)
    case permissionDenied
    case failed(String)
    case cancelled
}

/// Wraps a non-`Sendable` value so it can be handed to a child task that is the value's sole user.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
