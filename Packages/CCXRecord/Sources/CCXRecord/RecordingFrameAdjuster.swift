import CoreGraphics

/// One of the eight resize handles around a recording frame (AppKit coordinates: `top` is `maxY`).
public enum RecordingResizeHandle: CaseIterable, Sendable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesMinY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var movesMaxY: Bool { self == .topLeft || self == .top || self == .topRight }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        case .top, .right, .bottom, .left: false
        }
    }

    /// Returns the matching handle after flipping across horizontal and/or vertical axes.
    func flipped(horizontally: Bool, vertically: Bool) -> RecordingResizeHandle {
        var minX = movesMinX
        var maxX = movesMaxX
        var minY = movesMinY
        var maxY = movesMaxY
        if horizontally { swap(&minX, &maxX) }
        if vertically { swap(&minY, &maxY) }
        switch (minX, maxX, minY, maxY) {
        case (true, _, _, true): return .topLeft
        case (_, true, _, true): return .topRight
        case (true, _, true, _): return .bottomLeft
        case (_, true, true, _): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .bottom
        default: return .top
        }
    }
}

/// Hit-test classification for a point inside the display-local recording coordinate space.
public enum RecordingFrameHitTarget: Equatable, Sendable {
    case handle(RecordingResizeHandle)
    case interior
    case outside
}

/// Active pointer manipulation state for adjusting the pre-recording selection frame.
public enum RecordingFrameInteraction: Equatable, Sendable {
    case idle
    case moving(rect: CGRect, startPoint: CGPoint)
    case resizing(rect: CGRect, handle: RecordingResizeHandle)
    case redrawing(origin: CGPoint, current: CGPoint, previousRect: CGRect, didExceedThreshold: Bool)
}

/// Pure geometry and interaction state machine for resizing, moving, redrawing, and nudging
/// a screen recording frame in display-local AppKit coordinates (bottom-left origin).
public struct RecordingFrameAdjuster: Sendable {
    public let bounds: CGRect
    public private(set) var rect: CGRect
    public private(set) var interaction: RecordingFrameInteraction = .idle
    public var handleHitRadius: CGFloat = 8
    public var edgeHitBand: CGFloat = 6
    public var clickThreshold: CGFloat = 3
    public var minimumSide: CGFloat = 16

    public init(bounds: CGRect, initialRect: CGRect) {
        let normalizedBounds = Self.sanitizeBounds(bounds)
        self.bounds = normalizedBounds
        self.rect = normalizedBounds
        self.rect = enforceMinimumSize(Self.sanitizeRect(initialRect, fallback: normalizedBounds))
    }

    public var isInteracting: Bool {
        interaction != .idle
    }

    public var isRedrawing: Bool {
        if case .redrawing = interaction { return true }
        return false
    }

    /// Live selection rectangle while moving, resizing, or redrawing past `clickThreshold`.
    public var activeRect: CGRect {
        switch interaction {
        case .idle:
            return rect
        case let .moving(liveRect, _), let .resizing(liveRect, _):
            return liveRect
        case let .redrawing(origin, current, previousRect, didExceedThreshold):
            return didExceedThreshold ? Self.rect(from: origin, to: current) : previousRect
        }
    }

    // MARK: - Hit Testing

    private static let cornerOrder: [RecordingResizeHandle] = [
        .topLeft, .topRight, .bottomRight, .bottomLeft,
    ]
    private static let edgeMidpointOrder: [RecordingResizeHandle] = [
        .top, .right, .bottom, .left,
    ]

    /// Classifies a display-local point with priority: corners -> edge midpoints -> edge bands -> interior -> outside.
    ///
    /// On small rects, inward handle/edge reach is bounded proportionally so a central interior region
    /// remains grabbable for dragging, while outward reach keeps full `handleHitRadius`/`edgeHitBand`.
    public func hitTarget(at point: CGPoint) -> RecordingFrameHitTarget {
        guard Self.isFinitePoint(point) else { return .outside }

        let inwardHandleX = min(handleHitRadius, max(2, rect.width * 0.25))
        let inwardHandleY = min(handleHitRadius, max(2, rect.height * 0.25))
        let inwardEdgeX = min(edgeHitBand, max(1.5, rect.width * 0.20))
        let inwardEdgeY = min(edgeHitBand, max(1.5, rect.height * 0.20))

        func hitsHandle(_ handle: RecordingResizeHandle) -> Bool {
            let center = Self.handlePoint(handle, for: rect)
            let leftReach = handle.movesMinX ? handleHitRadius : (handle.movesMaxX ? inwardHandleX : inwardHandleX)
            let rightReach = handle.movesMaxX ? handleHitRadius : (handle.movesMinX ? inwardHandleX : inwardHandleX)
            let bottomReach = handle.movesMinY ? handleHitRadius : (handle.movesMaxY ? inwardHandleY : inwardHandleY)
            let topReach = handle.movesMaxY ? handleHitRadius : (handle.movesMinY ? inwardHandleY : inwardHandleY)
            return point.x >= center.x - leftReach &&
                point.x <= center.x + rightReach &&
                point.y >= center.y - bottomReach &&
                point.y <= center.y + topReach
        }

        for handle in Self.cornerOrder where hitsHandle(handle) {
            return .handle(handle)
        }
        for handle in Self.edgeMidpointOrder where hitsHandle(handle) {
            return .handle(handle)
        }

        if point.y >= rect.maxY - inwardEdgeY &&
           point.y <= rect.maxY + edgeHitBand &&
           point.x >= rect.minX - edgeHitBand &&
           point.x <= rect.maxX + edgeHitBand {
            return .handle(.top)
        }
        if point.y >= rect.minY - edgeHitBand &&
           point.y <= rect.minY + inwardEdgeY &&
           point.x >= rect.minX - edgeHitBand &&
           point.x <= rect.maxX + edgeHitBand {
            return .handle(.bottom)
        }
        if point.x >= rect.minX - edgeHitBand &&
           point.x <= rect.minX + inwardEdgeX &&
           point.y >= rect.minY - edgeHitBand &&
           point.y <= rect.maxY + edgeHitBand {
            return .handle(.left)
        }
        if point.x >= rect.maxX - inwardEdgeX &&
           point.x <= rect.maxX + edgeHitBand &&
           point.y >= rect.minY - edgeHitBand &&
           point.y <= rect.maxY + edgeHitBand {
            return .handle(.right)
        }

        if rect.contains(point) {
            return .interior
        }
        return .outside
    }

    // MARK: - Pointer Events

    public mutating func mouseDown(at rawPoint: CGPoint) {
        guard case .idle = interaction, Self.isFinitePoint(rawPoint) else { return }
        let point = Self.clampedPoint(rawPoint, in: bounds)
        switch hitTarget(at: point) {
        case let .handle(handle):
            interaction = .resizing(rect: rect, handle: handle)
        case .interior:
            interaction = .moving(rect: rect, startPoint: point)
        case .outside:
            interaction = .redrawing(origin: point, current: point, previousRect: rect, didExceedThreshold: false)
        }
    }

    public mutating func mouseDragged(
        to rawPoint: CGPoint,
        constrainSquare: Bool = false,
        moveOrigin: Bool = false
    ) {
        guard Self.isFinitePoint(rawPoint) else { return }
        let point = Self.clampedPoint(rawPoint, in: bounds)
        switch interaction {
        case .idle:
            break

        case let .moving(liveRect, startPoint):
            let moved = Self.clampedOffset(
                liveRect,
                dx: point.x - startPoint.x,
                dy: point.y - startPoint.y,
                in: bounds
            )
            // Advance anchor by the clamped delta so grab offsets remain stable at display edges.
            let appliedAnchor = CGPoint(
                x: startPoint.x + (moved.minX - liveRect.minX),
                y: startPoint.y + (moved.minY - liveRect.minY)
            )
            interaction = .moving(rect: moved, startPoint: appliedAnchor)

        case let .resizing(liveRect, handle):
            let target: CGPoint
            if constrainSquare && handle.isCorner {
                let anchor = CGPoint(
                    x: handle.movesMinX ? liveRect.maxX : liveRect.minX,
                    y: handle.movesMinY ? liveRect.maxY : liveRect.minY
                )
                target = Self.squareConstrainedPoint(from: anchor, to: point, in: bounds)
            } else {
                target = point
            }
            let (resizedRect, updatedHandle) = Self.resize(liveRect, handle: handle, to: target)
            interaction = .resizing(rect: resizedRect, handle: updatedHandle)

        case let .redrawing(origin, current, previousRect, didExceedThreshold):
            if !didExceedThreshold {
                guard abs(point.x - origin.x) >= clickThreshold || abs(point.y - origin.y) >= clickThreshold else {
                    return
                }
            }
            if moveOrigin && current != origin {
                let spanRect = Self.rect(from: origin, to: current)
                let moved = Self.clampedOffset(
                    spanRect,
                    dx: point.x - current.x,
                    dy: point.y - current.y,
                    in: bounds
                )
                let appliedDx = moved.minX - spanRect.minX
                let appliedDy = moved.minY - spanRect.minY
                interaction = .redrawing(
                    origin: CGPoint(x: origin.x + appliedDx, y: origin.y + appliedDy),
                    current: CGPoint(x: current.x + appliedDx, y: current.y + appliedDy),
                    previousRect: previousRect,
                    didExceedThreshold: true
                )
            } else if constrainSquare {
                let constrained = Self.squareConstrainedPoint(from: origin, to: point, in: bounds)
                interaction = .redrawing(
                    origin: origin,
                    current: constrained,
                    previousRect: previousRect,
                    didExceedThreshold: true
                )
            } else {
                interaction = .redrawing(
                    origin: origin,
                    current: point,
                    previousRect: previousRect,
                    didExceedThreshold: true
                )
            }
        }
    }

    public mutating func mouseUp(at rawPoint: CGPoint) {
        let point = Self.isFinitePoint(rawPoint)
            ? Self.clampedPoint(rawPoint, in: bounds)
            : CGPoint(x: rect.midX, y: rect.midY)
        switch interaction {
        case .idle:
            break
        case let .moving(liveRect, _), let .resizing(liveRect, _):
            rect = enforceMinimumSize(liveRect)
            interaction = .idle
        case let .redrawing(origin, current, previousRect, didExceedThreshold):
            let isClick = !didExceedThreshold &&
                abs(point.x - origin.x) < clickThreshold &&
                abs(point.y - origin.y) < clickThreshold
            if isClick {
                rect = previousRect
            } else {
                let finalPoint = didExceedThreshold ? current : point
                rect = enforceMinimumSize(Self.rect(from: origin, to: finalPoint))
            }
            interaction = .idle
        }
    }

    /// Aborts any in-progress pointer interaction without modifying the committed `rect`.
    public mutating func cancelInteraction() {
        interaction = .idle
    }

    // MARK: - Keyboard & Programmatic Adjustments

    /// Moves the selection by `dx`/`dy` points, clamped to `bounds`.
    @discardableResult
    public mutating func nudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard !isInteracting, dx.isFinite, dy.isFinite else { return false }
        rect = Self.clampedOffset(rect, dx: dx, dy: dy, in: bounds)
        return true
    }

    /// Expands or shrinks the selection by `dw`/`dh` points anchored at its top-left corner,
    /// shifting the opposite edge inward only when necessary to fit inside `bounds`.
    @discardableResult
    public mutating func resizeBy(dw: CGFloat, dh: CGFloat) -> Bool {
        guard !isInteracting, dw.isFinite, dh.isFinite else { return false }
        let minW = min(minimumSide, max(1, bounds.width))
        let minH = min(minimumSide, max(1, bounds.height))
        let maxW = max(1, bounds.width)
        let maxH = max(1, bounds.height)
        let newWidth = min(max(rect.width + dw, minW), maxW)
        let newHeight = min(max(rect.height + dh, minH), maxH)
        let newX = min(max(bounds.minX, rect.minX), max(bounds.minX, bounds.maxX - newWidth))
        let newY = max(bounds.minY, rect.maxY - newHeight)
        let resized = CGRect(
            x: newX,
            y: min(newY, max(bounds.minY, bounds.maxY - newHeight)),
            width: newWidth,
            height: newHeight
        )
        rect = Self.clampedOffset(resized, dx: 0, dy: 0, in: bounds)
        return true
    }

    /// Expands the selection to the entire display bounds.
    @discardableResult
    public mutating func selectAll() -> Bool {
        guard !isInteracting else { return false }
        rect = enforceMinimumSize(bounds)
        return true
    }

    /// Replaces the rectangle directly (clamped to bounds and minimum size) and resets any drag.
    public mutating func setRect(_ newRect: CGRect) {
        interaction = .idle
        rect = enforceMinimumSize(Self.sanitizeRect(newRect, fallback: rect))
    }

    // MARK: - Geometry Helpers

    private static func isFinitePoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite &&
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite
    }

    private static func sanitizeBounds(_ rect: CGRect) -> CGRect {
        guard isFiniteRect(rect) else { return .zero }
        let std = rect.standardized
        return CGRect(x: std.minX, y: std.minY, width: max(0, std.width), height: max(0, std.height))
    }

    private static func sanitizeRect(_ rect: CGRect, fallback: CGRect) -> CGRect {
        guard isFiniteRect(rect) else { return fallback }
        return rect.standardized
    }

    /// Center of a resize handle on `rect` in display-local coordinates.
    public static func handlePoint(_ handle: RecordingResizeHandle, for rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func enforceMinimumSize(_ candidate: CGRect) -> CGRect {
        let minW = min(minimumSide, max(1, bounds.width))
        let minH = min(minimumSide, max(1, bounds.height))
        var normalized = candidate.standardized
        normalized.size.width = min(max(normalized.width, minW), max(1, bounds.width))
        normalized.size.height = min(max(normalized.height, minH), max(1, bounds.height))
        return Self.clampedOffset(normalized, dx: 0, dy: 0, in: bounds)
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private static func clampedPoint(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func clampedOffset(_ rect: CGRect, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: dx, dy: dy)
        if moved.width > bounds.width { moved.size.width = bounds.width }
        if moved.height > bounds.height { moved.size.height = bounds.height }
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    private static func squareConstrainedPoint(from origin: CGPoint, to point: CGPoint, in bounds: CGRect) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let signX: CGFloat = dx >= 0 ? 1 : -1
        let signY: CGFloat = dy >= 0 ? 1 : -1
        let maxAvailX = dx >= 0 ? (bounds.maxX - origin.x) : (origin.x - bounds.minX)
        let maxAvailY = dy >= 0 ? (bounds.maxY - origin.y) : (origin.y - bounds.minY)
        let maxSide = max(0, min(maxAvailX, maxAvailY))
        let side = min(max(abs(dx), abs(dy)), maxSide)
        return CGPoint(x: origin.x + signX * side, y: origin.y + signY * side)
    }

    private static func resize(_ rect: CGRect, handle: RecordingResizeHandle, to point: CGPoint) -> (CGRect, RecordingResizeHandle) {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY
        if handle.movesMinX { minX = point.x }
        if handle.movesMaxX { maxX = point.x }
        if handle.movesMinY { minY = point.y }
        if handle.movesMaxY { maxY = point.y }
        let flipH = minX > maxX
        let flipV = minY > maxY
        let newRect = CGRect(
            x: min(minX, maxX),
            y: min(minY, maxY),
            width: abs(maxX - minX),
            height: abs(maxY - minY)
        )
        return (newRect, handle.flipped(horizontally: flipH, vertically: flipV))
    }
}
