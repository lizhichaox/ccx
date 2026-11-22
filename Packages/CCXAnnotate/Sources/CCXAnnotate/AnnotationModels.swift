import AppKit
import CoreGraphics
import Foundation

/// Interactive annotation modes available inside the snip canvas.
public enum AnnotationTool: String, CaseIterable, Sendable {
    case select
    case rectangle
    case ellipse
    case arrow
    case pen
    case highlighter
    case mosaic
    case text
    case counter

    /// Drawing tools exposed directly in the floating annotation toolbar (keyboard 1-8).
    public static let drawingTools: [AnnotationTool] = [
        .rectangle, .ellipse, .arrow, .pen, .highlighter, .mosaic, .text, .counter,
    ]

    public var isDrawingTool: Bool { self != .select }
    public var showsStyleBar: Bool { isDrawingTool }
    public var usesColor: Bool { self != .select && self != .mosaic }
    public var usesMosaicMode: Bool { self == .mosaic }

    public var symbolName: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .mosaic: "checkerboard.rectangle"
        case .text: "textformat"
        case .counter: "number.circle"
        }
    }

    public var displayName: String {
        switch self {
        case .select: "Select / Move"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .pen: "Freehand Pen"
        case .highlighter: "Highlighter"
        case .mosaic: "Mosaic / Blur"
        case .text: "Text"
        case .counter: "Step Counter"
        }
    }

    public var shortcutHint: String? {
        switch self {
        case .select: "V"
        case .rectangle: "1"
        case .ellipse: "2"
        case .arrow: "3"
        case .pen: "4"
        case .highlighter: "5"
        case .mosaic: "6"
        case .text: "7"
        case .counter: "8"
        }
    }

    public static func forNumberKey(_ character: String) -> AnnotationTool? {
        switch character {
        case "1": .rectangle
        case "2": .ellipse
        case "3": .arrow
        case "4": .pen
        case "5": .highlighter
        case "6": .mosaic
        case "7": .text
        case "8": .counter
        default: nil
        }
    }
}

/// Curated annotation palette designed to stay crisp over light and dark UI captures.
public struct AnnotationColor: Equatable, Hashable, Sendable {
    public let r: CGFloat
    public let g: CGFloat
    public let b: CGFloat
    public let hex: String

    public init(r: CGFloat, g: CGFloat, b: CGFloat, hex: String) {
        self.r = r
        self.g = g
        self.b = b
        self.hex = hex
    }

    public static let red = AnnotationColor(r: 1.00, g: 0.231, b: 0.188, hex: "#FF3B30")
    public static let orange = AnnotationColor(r: 1.00, g: 0.584, b: 0.000, hex: "#FF9500")
    public static let yellow = AnnotationColor(r: 1.00, g: 0.800, b: 0.000, hex: "#FFCC00")
    public static let green = AnnotationColor(r: 0.204, g: 0.780, b: 0.349, hex: "#34C759")
    public static let blue = AnnotationColor(r: 0.000, g: 0.478, b: 1.000, hex: "#007AFF")
    public static let white = AnnotationColor(r: 1.00, g: 1.000, b: 1.000, hex: "#FFFFFF")
    public static let charcoal = AnnotationColor(r: 0.110, g: 0.110, b: 0.118, hex: "#1C1C1E")

    public static let palette: [AnnotationColor] = [
        .red, .orange, .yellow, .green, .blue, .white, .charcoal,
    ]

    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// Relative luminance for picking contrasting badge label text on bright fills.
    public var isLightColor: Bool {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.72
    }
}

/// Three calibrated size presets shared by strokes, highlighter, mosaic, text, and counters.
public enum StrokePreset: Int, CaseIterable, Sendable {
    case small = 0
    case medium = 1
    case large = 2

    public var label: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    public var lineWidth: CGFloat {
        switch self {
        case .small: 2.5
        case .medium: 4.0
        case .large: 6.5
        }
    }

    public var highlighterWidth: CGFloat {
        switch self {
        case .small: 14
        case .medium: 22
        case .large: 32
        }
    }

    public var fontSize: CGFloat {
        switch self {
        case .small: 15
        case .medium: 21
        case .large: 30
        }
    }

    public var mosaicRadius: CGFloat {
        switch self {
        case .small: 10
        case .medium: 18
        case .large: 28
        }
    }

    public var counterDiameter: CGFloat {
        switch self {
        case .small: 24
        case .medium: 30
        case .large: 38
        }
    }
}

/// Visual filter modes supported by the privacy redaction tool.
public enum MosaicMode: String, CaseIterable, Sendable {
    case pixelate
    case blur

    public var label: String {
        switch self {
        case .pixelate: "Mosaic"
        case .blur: "Blur"
        }
    }
}

/// Visual attributes applied to an annotation item.
public struct AnnotationStyle: Equatable, Sendable {
    public var color: AnnotationColor
    public var size: StrokePreset
    public var mosaicMode: MosaicMode

    public init(
        color: AnnotationColor = .red,
        size: StrokePreset = .medium,
        mosaicMode: MosaicMode = .pixelate
    ) {
        self.color = color
        self.size = size
        self.mosaicMode = mosaicMode
    }
}

/// Interactive resize/endpoint handles on a selected annotation.
public enum AnnotationHandle: Equatable, Hashable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft
    case start, end
}

/// Geometric representation of one annotation in view-local AppKit coordinates (bottom-left origin).
public enum AnnotationKind: Equatable, Sendable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case arrow(start: CGPoint, end: CGPoint)
    case pen([CGPoint])
    case highlighter([CGPoint])
    case mosaic(CGRect, MosaicMode)
    /// `origin` is the top-left corner of the text block in AppKit coordinates so extra lines grow downward.
    case text(origin: CGPoint, content: String)
    case counter(center: CGPoint, number: Int)

    public var tool: AnnotationTool {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .pen: .pen
        case .highlighter: .highlighter
        case .mosaic: .mosaic
        case .text: .text
        case .counter: .counter
        }
    }
}

/// A single non-destructive annotation item stored in `AnnotationDocument`.
public struct AnnotationItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: AnnotationKind
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), kind: AnnotationKind, style: AnnotationStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    public var boundingBox: CGRect {
        switch kind {
        case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect, _):
            return rect.standardized
        case let .arrow(start, end):
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        case let .pen(points), let .highlighter(points):
            return Self.polylineBounds(points)
        case let .text(origin, content):
            return Self.textBoundingBox(origin: origin, content: content, fontSize: style.size.fontSize)
        case let .counter(center, _):
            let r = style.size.counterDiameter / 2
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
    }

    public var handlePoints: [AnnotationHandle: CGPoint] {
        switch kind {
        case let .rectangle(raw), let .ellipse(raw), let .mosaic(raw, _):
            let rect = raw.standardized
            return [
                .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
                .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
                .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
                .bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            ]
        case let .arrow(start, end):
            return [.start: start, .end: end]
        case .pen, .highlighter, .text, .counter:
            return [:]
        }
    }

    public func hitTestHandle(at point: CGPoint, radius: CGFloat = 7) -> AnnotationHandle? {
        for (handle, center) in handlePoints {
            if abs(point.x - center.x) <= radius && abs(point.y - center.y) <= radius {
                return handle
            }
        }
        return nil
    }

    public func hitTest(point: CGPoint, tolerance: CGFloat = 8) -> Bool {
        switch kind {
        case let .rectangle(raw):
            let rect = raw.standardized
            let pad = tolerance + style.size.lineWidth / 2
            guard rect.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
            if rect.width > pad * 3 && rect.height > pad * 3 {
                return !rect.insetBy(dx: pad, dy: pad).contains(point)
            }
            return true

        case let .ellipse(raw):
            let rect = raw.standardized
            let rx = max(rect.width / 2, 1)
            let ry = max(rect.height / 2, 1)
            let pad = tolerance + style.size.lineWidth / 2
            let d = hypot((point.x - rect.midX) / rx, (point.y - rect.midY) / ry)
            let band = pad / min(rx, ry)
            if min(rx, ry) <= pad * 1.5 {
                return d <= 1 + band
            }
            return abs(d - 1) <= band

        case let .arrow(start, end):
            let pad = tolerance + style.size.lineWidth / 2
            let headPad = max(pad, max(14, style.size.lineWidth * 4.2) * 0.65)
            guard boundingBox.insetBy(dx: -headPad, dy: -headPad).contains(point) else { return false }
            if Self.distanceToSegment(point, start, end) <= pad { return true }
            let headRadius = max(14, style.size.lineWidth * 4.2) * 0.65
            return hypot(point.x - end.x, point.y - end.y) <= headRadius

        case let .pen(points):
            let pad = tolerance + style.size.lineWidth / 2
            guard boundingBox.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
            return Self.hitTestPolyline(points, point: point, threshold: pad)

        case let .highlighter(points):
            let pad = tolerance + style.size.highlighterWidth / 2
            guard boundingBox.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
            return Self.hitTestPolyline(points, point: point, threshold: pad)

        case let .mosaic(raw, _):
            return raw.standardized.insetBy(dx: -4, dy: -4).contains(point)

        case .text:
            return boundingBox.insetBy(dx: -6, dy: -4).contains(point)

        case let .counter(center, _):
            let r = style.size.counterDiameter / 2 + 4
            return hypot(point.x - center.x, point.y - center.y) <= r
        }
    }

    public func translated(by delta: CGSize) -> AnnotationItem {
        var copy = self
        switch kind {
        case let .rectangle(rect):
            copy.kind = .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .ellipse(rect):
            copy.kind = .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height))
        case let .arrow(start, end):
            copy.kind = .arrow(
                start: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
                end: CGPoint(x: end.x + delta.width, y: end.y + delta.height)
            )
        case let .pen(points):
            copy.kind = .pen(points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) })
        case let .highlighter(points):
            copy.kind = .highlighter(points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) })
        case let .mosaic(rect, mode):
            copy.kind = .mosaic(rect.offsetBy(dx: delta.width, dy: delta.height), mode)
        case let .text(origin, content):
            copy.kind = .text(
                origin: CGPoint(x: origin.x + delta.width, y: origin.y + delta.height),
                content: content
            )
        case let .counter(center, number):
            copy.kind = .counter(
                center: CGPoint(x: center.x + delta.width, y: center.y + delta.height),
                number: number
            )
        }
        return copy
    }

    public func resized(handle: AnnotationHandle, to point: CGPoint, constrain: Bool) -> AnnotationItem {
        var copy = self
        switch kind {
        case let .rectangle(raw):
            if let anchor = Self.oppositeCorner(of: raw.standardized, for: handle) {
                copy.kind = .rectangle(Self.constrainedRect(from: anchor, to: point, square: constrain))
            }
        case let .ellipse(raw):
            if let anchor = Self.oppositeCorner(of: raw.standardized, for: handle) {
                copy.kind = .ellipse(Self.constrainedRect(from: anchor, to: point, square: constrain))
            }
        case let .mosaic(raw, mode):
            if let anchor = Self.oppositeCorner(of: raw.standardized, for: handle) {
                copy.kind = .mosaic(Self.constrainedRect(from: anchor, to: point, square: constrain), mode)
            }
        case let .arrow(start, end):
            switch handle {
            case .start:
                copy.kind = .arrow(start: Self.constrainedEnd(from: end, to: point, snapAngle: constrain), end: end)
            case .end:
                copy.kind = .arrow(start: start, end: Self.constrainedEnd(from: start, to: point, snapAngle: constrain))
            default:
                break
            }
        case .pen, .highlighter, .text, .counter:
            break
        }
        return copy
    }

    // MARK: - Geometry Helpers

    /// Normalized rectangle spanned from `origin` to `current`, optionally constrained to a 1:1 square.
    public static func constrainedRect(from origin: CGPoint, to current: CGPoint, square: Bool) -> CGRect {
        var target = current
        if square {
            let dx = current.x - origin.x
            let dy = current.y - origin.y
            let side = max(abs(dx), abs(dy))
            target = CGPoint(
                x: origin.x + (dx >= 0 ? side : -side),
                y: origin.y + (dy >= 0 ? side : -side)
            )
        }
        return CGRect(
            x: min(origin.x, target.x),
            y: min(origin.y, target.y),
            width: abs(target.x - origin.x),
            height: abs(target.y - origin.y)
        )
    }

    /// Snaps `end` onto 15° increments around `start` when `snapAngle` is enabled.
    public static func constrainedEnd(
        from start: CGPoint,
        to end: CGPoint,
        snapAngle: Bool,
        stepDegrees: CGFloat = 15
    ) -> CGPoint {
        guard snapAngle else { return end }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let stepRad = stepDegrees * .pi / 180
        let angle = (atan2(dy, dx) / stepRad).rounded() * stepRad
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// Appends `point` to a polyline only when it moved at least `minDistance` points from the tail.
    public static func appendPoint(_ point: CGPoint, to points: [CGPoint], minDistance: CGFloat = 2.5) -> [CGPoint] {
        guard let last = points.last else { return [point] }
        guard hypot(point.x - last.x, point.y - last.y) >= minDistance else { return points }
        return points + [point]
    }

    /// Text attributes shared between the inline text editor and Canvas/CoreGraphics renderer.
    public static func textAttributes(color: AnnotationColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: color.nsColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// Computes AppKit bottom-left bounds for `content` anchored at top-left `origin`.
    public static func textBoundingBox(origin: CGPoint, content: String, fontSize: CGFloat) -> CGRect {
        let measured = content.isEmpty ? "Ag" : content
        let attributed = NSAttributedString(string: measured, attributes: textAttributes(color: .white, fontSize: fontSize))
        let measuredBounds = attributed.boundingRect(
            with: CGSize(width: 640, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = max(24, ceil(measuredBounds.width) + 6)
        let height = max(ceil(fontSize * 1.35), ceil(measuredBounds.height) + 4)
        return CGRect(x: origin.x, y: origin.y - height, width: width, height: height)
    }

    private static func oppositeCorner(of rect: CGRect, for handle: AnnotationHandle) -> CGPoint? {
        switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .topRight: CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .start, .end: nil
        }
    }

    private static func polylineBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func hitTestPolyline(_ points: [CGPoint], point: CGPoint, threshold: CGFloat) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 {
            return hypot(point.x - first.x, point.y - first.y) <= threshold
        }
        for i in 0..<(points.count - 1) {
            if distanceToSegment(point, points[i], points[i + 1]) <= threshold {
                return true
            }
        }
        return false
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lenSq = abx * abx + aby * aby
        guard lenSq > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq, 0), 1)
        let projX = a.x + t * abx
        let projY = a.y + t * aby
        return hypot(p.x - projX, p.y - projY)
    }
}
