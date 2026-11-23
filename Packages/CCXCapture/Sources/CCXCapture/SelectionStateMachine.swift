import CoreGraphics

/// One of the eight resize handles around a selection (AppKit coordinates: `top` is `maxY`).
public enum ResizeHandle: CaseIterable, Sendable, Hashable {
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

    /// Returns the handle that results from flipping across the horizontal and/or vertical axis.
    func flipped(horizontally: Bool, vertically: Bool) -> ResizeHandle {
        var minX = movesMinX, maxX = movesMaxX, minY = movesMinY, maxY = movesMaxY
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

/// The interaction state of a snip overlay.
public enum SelectionState: Equatable, Sendable {
    case hovering(detectedRect: CGRect?)
    case dragging(origin: CGPoint, current: CGPoint)
    case selected(rect: CGRect)
    case moving(rect: CGRect, startPoint: CGPoint)
    case resizing(rect: CGRect, handle: ResizeHandle, startPoint: CGPoint)
}

/// Pure, UI-independent selection logic for one overlay view.
///
/// All points and rectangles are in the overlay view's local AppKit coordinate space
/// (points, bottom-left origin) and are clamped to `bounds`.
public struct SelectionStateMachine: Sendable {
    public private(set) var state: SelectionState
    public let bounds: CGRect
    /// Distance (points) from a handle center that still counts as a handle hit.
    public var handleHitRadius: CGFloat = 6
    /// Movement (points) below which a mouse-down/up pair is treated as a click.
    public var clickThreshold: CGFloat = 3

    /// Detected rectangle captured at mouse-down while hovering (used for click-to-select).
    private var pendingDetectedRect: CGRect?
    /// Selection that was active before an outside click started a new drag.
    private var previousSelection: CGRect?
    /// Whether the current drag gesture has moved past `clickThreshold` at least once.
    private var didExceedClickThreshold = false

    public init(bounds: CGRect) {
        self.bounds = bounds
        self.state = .hovering(detectedRect: nil)
    }

    // MARK: - Derived values

    /// The user's selection (live while dragging past `clickThreshold`, moving, or resizing), or `nil` while hovering.
    public var selectionRect: CGRect? {
        switch state {
        case .hovering: return nil
        case let .dragging(origin, current):
            return didExceedClickThreshold ? Self.rect(from: origin, to: current) : nil
        case let .selected(rect), let .moving(rect, _), let .resizing(rect, _, _): return rect
        }
    }

    /// The rectangle to highlight: the selection, the pending click target before `clickThreshold`,
    /// or the detected element while hovering.
    public var highlightedRect: CGRect? {
        switch state {
        case let .hovering(detected):
            return detected
        case let .dragging(origin, current):
            if didExceedClickThreshold {
                return Self.rect(from: origin, to: current)
            }
            return pendingDetectedRect ?? previousSelection
        case let .selected(rect), let .moving(rect, _), let .resizing(rect, _, _):
            return rect
        }
    }

    public var isSelected: Bool {
        if case .selected = state { return true }
        return false
    }

    public var isHovering: Bool {
        if case .hovering = state { return true }
        return false
    }

    // MARK: - Events

    /// Updates the auto-detected element rectangle; ignored unless hovering.
    public mutating func updateHover(detectedRect: CGRect?) {
        guard case .hovering = state else { return }
        state = .hovering(detectedRect: detectedRect.flatMap { Self.clampedRect($0, in: bounds) })
    }

    public mutating func mouseDown(at rawPoint: CGPoint) {
        let point = Self.clampedPoint(rawPoint, in: bounds)
        switch state {
        case let .hovering(detected):
            pendingDetectedRect = detected
            previousSelection = nil
            didExceedClickThreshold = false
            state = .dragging(origin: point, current: point)
        case let .selected(rect):
            if let handle = Self.hitTestHandle(at: point, rect: rect, radius: handleHitRadius) {
                didExceedClickThreshold = false
                state = .resizing(rect: rect, handle: handle, startPoint: point)
            } else if rect.contains(point) {
                didExceedClickThreshold = false
                state = .moving(rect: rect, startPoint: point)
            } else {
                pendingDetectedRect = nil
                previousSelection = rect
                didExceedClickThreshold = false
                state = .dragging(origin: point, current: point)
            }
        case .dragging, .moving, .resizing:
            break
        }
    }

    public mutating func mouseDragged(
        to rawPoint: CGPoint,
        constrainSquare: Bool = false,
        moveOrigin: Bool = false
    ) {
        let point = Self.clampedPoint(rawPoint, in: bounds)
        switch state {
        case let .dragging(origin, current):
            if !didExceedClickThreshold {
                guard abs(point.x - origin.x) >= clickThreshold || abs(point.y - origin.y) >= clickThreshold else {
                    return
                }
                didExceedClickThreshold = true
            }
            if moveOrigin && current != origin {
                let activeRect = Self.rect(from: origin, to: current)
                let moved = Self.clampedOffset(
                    activeRect,
                    dx: point.x - current.x,
                    dy: point.y - current.y,
                    in: bounds
                )
                let appliedDx = moved.minX - activeRect.minX
                let appliedDy = moved.minY - activeRect.minY
                state = .dragging(
                    origin: CGPoint(x: origin.x + appliedDx, y: origin.y + appliedDy),
                    current: CGPoint(x: current.x + appliedDx, y: current.y + appliedDy)
                )
            } else if constrainSquare {
                let constrained = Self.squareConstrainedPoint(from: origin, to: point, in: bounds)
                state = .dragging(origin: origin, current: constrained)
            } else {
                state = .dragging(origin: origin, current: point)
            }
        case let .moving(rect, startPoint):
            let moved = Self.clampedOffset(rect, dx: point.x - startPoint.x, dy: point.y - startPoint.y, in: bounds)
            // Advance the anchor only by the applied delta so the grab offset stays stable at edges.
            let applied = CGPoint(x: startPoint.x + (moved.minX - rect.minX), y: startPoint.y + (moved.minY - rect.minY))
            state = .moving(rect: moved, startPoint: applied)
        case let .resizing(rect, handle, _):
            let target: CGPoint
            if constrainSquare && handle.isCorner {
                let anchor = CGPoint(
                    x: handle.movesMinX ? rect.maxX : rect.minX,
                    y: handle.movesMinY ? rect.maxY : rect.minY
                )
                target = Self.squareConstrainedPoint(from: anchor, to: point, in: bounds)
            } else {
                target = point
            }
            let (newRect, newHandle) = Self.resize(rect, handle: handle, to: target)
            state = .resizing(rect: newRect, handle: newHandle, startPoint: target)
        case .hovering, .selected:
            break
        }
    }

    public mutating func mouseUp(at rawPoint: CGPoint) {
        let point = Self.clampedPoint(rawPoint, in: bounds)
        switch state {
        case let .dragging(origin, current):
            let isClick = !didExceedClickThreshold &&
                abs(point.x - origin.x) < clickThreshold &&
                abs(point.y - origin.y) < clickThreshold
            if isClick {
                if let previous = previousSelection {
                    state = .selected(rect: previous)
                } else {
                    state = .selected(rect: pendingDetectedRect ?? bounds)
                }
            } else {
                let finalPoint = didExceedClickThreshold ? current : point
                let rect = Self.rect(from: origin, to: finalPoint)
                state = .selected(rect: Self.enforceMinimumSize(rect, in: bounds))
            }
            pendingDetectedRect = nil
            previousSelection = nil
            didExceedClickThreshold = false
        case let .moving(rect, _), let .resizing(rect, _, _):
            state = .selected(rect: Self.enforceMinimumSize(rect, in: bounds))
        case .hovering, .selected:
            break
        }
    }

    /// Moves the selection by `dx`/`dy` points (arrow-key nudging). Returns `true` if handled.
    @discardableResult
    public mutating func nudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard case let .selected(rect) = state else { return false }
        state = .selected(rect: Self.clampedOffset(rect, dx: dx, dy: dy, in: bounds))
        return true
    }

    /// Expands or shrinks the selected rectangle by `dw`/`dh` points (anchored at top-left),
    /// clamped to `bounds` and minimum `1 × 1`. Returns `true` if handled.
    @discardableResult
    public mutating func resizeBy(dw: CGFloat, dh: CGFloat) -> Bool {
        guard case let .selected(rect) = state else { return false }
        let newWidth = min(max(rect.width + dw, 1), bounds.maxX - rect.minX)
        let newHeight = min(max(rect.height + dh, 1), bounds.height)
        let newY = max(bounds.minY, rect.maxY - newHeight)
        let resized = CGRect(
            x: rect.minX,
            y: min(newY, bounds.maxY - newHeight),
            width: newWidth,
            height: newHeight
        )
        state = .selected(rect: Self.clampedOffset(resized, dx: 0, dy: 0, in: bounds))
        return true
    }

    /// Selects an explicit rectangle (clamped to bounds).
    public mutating func select(_ rect: CGRect) {
        guard let clamped = Self.clampedRect(rect, in: bounds) else { return }
        pendingDetectedRect = nil
        previousSelection = nil
        didExceedClickThreshold = false
        state = .selected(rect: clamped)
    }

    /// Returns to the hovering state, discarding any selection.
    public mutating func reset() {
        pendingDetectedRect = nil
        previousSelection = nil
        didExceedClickThreshold = false
        state = .hovering(detectedRect: nil)
    }

    // MARK: - Geometry helpers

    private static let hitTestOrder: [ResizeHandle] = [
        .topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left,
    ]

    /// Center of a single resize handle of `rect` without allocating a dictionary.
    public static func handlePoint(_ handle: ResizeHandle, for rect: CGRect) -> CGPoint {
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

    /// Centers of the eight resize handles of `rect`.
    public static func handlePoints(for rect: CGRect) -> [ResizeHandle: CGPoint] {
        [
            .topLeft: handlePoint(.topLeft, for: rect),
            .top: handlePoint(.top, for: rect),
            .topRight: handlePoint(.topRight, for: rect),
            .right: handlePoint(.right, for: rect),
            .bottomRight: handlePoint(.bottomRight, for: rect),
            .bottom: handlePoint(.bottom, for: rect),
            .bottomLeft: handlePoint(.bottomLeft, for: rect),
            .left: handlePoint(.left, for: rect),
        ]
    }

    /// Returns the handle under `point`, preferring corners over edges.
    public static func hitTestHandle(at point: CGPoint, rect: CGRect, radius: CGFloat) -> ResizeHandle? {
        for handle in hitTestOrder {
            let center = handlePoint(handle, for: rect)
            if abs(point.x - center.x) <= radius && abs(point.y - center.y) <= radius {
                return handle
            }
        }
        return nil
    }

    /// Normalized rectangle spanned by two points.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func clampedPoint(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// Intersects `rect` with `bounds`; returns `nil` when they do not overlap.
    static func clampedRect(_ rect: CGRect, in bounds: CGRect) -> CGRect? {
        let clipped = rect.standardized.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    /// Offsets `rect` by `dx`/`dy`, keeping it fully inside `bounds`.
    static func clampedOffset(_ rect: CGRect, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: dx, dy: dy)
        if moved.width > bounds.width { moved.size.width = bounds.width }
        if moved.height > bounds.height { moved.size.height = bounds.height }
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    static func enforceMinimumSize(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = max(result.width, 1)
        result.size.height = max(result.height, 1)
        return clampedOffset(result, dx: 0, dy: 0, in: bounds)
    }

    /// Returns a 1:1 square-constrained target endpoint from `origin` toward `point`, clamped within `bounds`.
    static func squareConstrainedPoint(from origin: CGPoint, to point: CGPoint, in bounds: CGRect) -> CGPoint {
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

    /// Moves the edges controlled by `handle` to `point`, flipping the handle when an edge crosses its anchor.
    static func resize(_ rect: CGRect, handle: ResizeHandle, to point: CGPoint) -> (CGRect, ResizeHandle) {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesMinX { minX = point.x }
        if handle.movesMaxX { maxX = point.x }
        if handle.movesMinY { minY = point.y }
        if handle.movesMaxY { maxY = point.y }
        let flipH = minX > maxX
        let flipV = minY > maxY
        let newRect = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        return (newRect, handle.flipped(horizontally: flipH, vertically: flipV))
    }
}
