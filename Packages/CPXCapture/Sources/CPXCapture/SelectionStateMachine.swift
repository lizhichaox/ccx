import CoreGraphics

/// One of the eight resize handles around a selection (AppKit coordinates: `top` is `maxY`).
public enum ResizeHandle: CaseIterable, Sendable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesMinY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var movesMaxY: Bool { self == .topLeft || self == .top || self == .topRight }

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

    public init(bounds: CGRect) {
        self.bounds = bounds
        self.state = .hovering(detectedRect: nil)
    }

    // MARK: - Derived values

    /// The user's selection (live while dragging, moving, or resizing), or `nil` while hovering.
    public var selectionRect: CGRect? {
        switch state {
        case .hovering: return nil
        case let .dragging(origin, current): return Self.rect(from: origin, to: current)
        case let .selected(rect), let .moving(rect, _), let .resizing(rect, _, _): return rect
        }
    }

    /// The rectangle to highlight: the selection, or the detected element while hovering.
    public var highlightedRect: CGRect? {
        if case let .hovering(detected) = state { return detected }
        return selectionRect
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
            state = .dragging(origin: point, current: point)
        case let .selected(rect):
            if let handle = Self.hitTestHandle(at: point, rect: rect, radius: handleHitRadius) {
                state = .resizing(rect: rect, handle: handle, startPoint: point)
            } else if rect.contains(point) {
                state = .moving(rect: rect, startPoint: point)
            } else {
                pendingDetectedRect = nil
                previousSelection = rect
                state = .dragging(origin: point, current: point)
            }
        case .dragging, .moving, .resizing:
            break
        }
    }

    public mutating func mouseDragged(to rawPoint: CGPoint) {
        let point = Self.clampedPoint(rawPoint, in: bounds)
        switch state {
        case let .dragging(origin, _):
            state = .dragging(origin: origin, current: point)
        case let .moving(rect, startPoint):
            let moved = Self.clampedOffset(rect, dx: point.x - startPoint.x, dy: point.y - startPoint.y, in: bounds)
            // Advance the anchor only by the applied delta so the grab offset stays stable at edges.
            let applied = CGPoint(x: startPoint.x + (moved.minX - rect.minX), y: startPoint.y + (moved.minY - rect.minY))
            state = .moving(rect: moved, startPoint: applied)
        case let .resizing(rect, handle, _):
            let (newRect, newHandle) = Self.resize(rect, handle: handle, to: point)
            state = .resizing(rect: newRect, handle: newHandle, startPoint: point)
        case .hovering, .selected:
            break
        }
    }

    public mutating func mouseUp(at rawPoint: CGPoint) {
        let point = Self.clampedPoint(rawPoint, in: bounds)
        switch state {
        case let .dragging(origin, _):
            let isClick = abs(point.x - origin.x) < clickThreshold && abs(point.y - origin.y) < clickThreshold
            if isClick {
                if let previous = previousSelection {
                    state = .selected(rect: previous)
                } else {
                    state = .selected(rect: pendingDetectedRect ?? bounds)
                }
            } else {
                let rect = Self.rect(from: origin, to: point)
                state = .selected(rect: Self.enforceMinimumSize(rect, in: bounds))
            }
            pendingDetectedRect = nil
            previousSelection = nil
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

    /// Selects an explicit rectangle (clamped to bounds).
    public mutating func select(_ rect: CGRect) {
        guard let clamped = Self.clampedRect(rect, in: bounds) else { return }
        state = .selected(rect: clamped)
    }

    /// Returns to the hovering state, discarding any selection.
    public mutating func reset() {
        pendingDetectedRect = nil
        previousSelection = nil
        state = .hovering(detectedRect: nil)
    }

    // MARK: - Geometry helpers

    /// Centers of the eight resize handles of `rect`.
    public static func handlePoints(for rect: CGRect) -> [ResizeHandle: CGPoint] {
        [
            .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .top: CGPoint(x: rect.midX, y: rect.maxY),
            .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .right: CGPoint(x: rect.maxX, y: rect.midY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
            .bottom: CGPoint(x: rect.midX, y: rect.minY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            .left: CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    /// Returns the handle under `point`, preferring corners over edges.
    public static func hitTestHandle(at point: CGPoint, rect: CGRect, radius: CGFloat) -> ResizeHandle? {
        let points = handlePoints(for: rect)
        let order: [ResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        for handle in order {
            guard let center = points[handle] else { continue }
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
