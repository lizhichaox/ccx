import AppKit
import CCXCore
import CoreGraphics
import Foundation
import os

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
        case .select: CCXL10n.text("Select / Move", zh: "选择 / 移动")
        case .rectangle: CCXL10n.text("Rectangle", zh: "矩形")
        case .ellipse: CCXL10n.text("Ellipse", zh: "椭圆")
        case .arrow: CCXL10n.text("Arrow", zh: "箭头")
        case .pen: CCXL10n.text("Freehand Pen", zh: "画笔")
        case .highlighter: CCXL10n.text("Highlighter", zh: "荧光笔")
        case .mosaic: CCXL10n.text("Mosaic / Blur", zh: "马赛克 / 模糊")
        case .text: CCXL10n.text("Text", zh: "文字")
        case .counter: CCXL10n.text("Step Counter", zh: "序号")
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

    public func formattedSizeHUDLabel(for size: StrokeSize, mosaicMode: MosaicMode) -> String {
        switch self {
        case .select, .rectangle, .ellipse, .arrow, .pen:
            return "\(size.formattedLineWidth) pt"
        case .highlighter:
            let halves = Int((size.highlighterWidth * 2).rounded())
            let widthText = halves.isMultiple(of: 2) ? "\(halves / 2)" : "\(halves / 2).5"
            return "\(widthText) pt"
        case .text:
            return "\(Int(size.fontSize.rounded())) pt"
        case .counter:
            return "\(Int(size.counterDiameter.rounded())) px"
        case .mosaic:
            switch mosaicMode {
            case .pixelate:
                let block = Int(size.mosaicBlockSize.rounded())
                return CCXL10n.text("Mosaic \(block)", zh: "马赛克 \(block)")
            case .blur:
                let radius = Int(size.blurRadius.rounded())
                return CCXL10n.text("Blur \(radius)", zh: "模糊 \(radius)")
            }
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

/// Continuous annotation thickness control ranging smoothly from minimum (`0`) to maximum (`1`),
/// with `.small`, `.medium`, and `.large` reference anchors.
public struct StrokeSize: Equatable, Hashable, Sendable {
    public static let minLineWidth: CGFloat = 1.5
    public static let maxLineWidth: CGFloat = 12.0
    private static let lineWidthExponent: CGFloat = 1.6

    private let permille: Int

    public var progress: CGFloat { CGFloat(permille) / 1000 }

    public static let minimum = StrokeSize(progress: 0)
    public static let maximum = StrokeSize(progress: 1)
    public static let small = StrokeSize(progress: 0.23)
    public static let medium = StrokeSize(progress: 0.41)
    public static let large = StrokeSize(progress: 0.63)
    public static let presets: [StrokeSize] = [.small, .medium, .large]

    public init(progress: CGFloat) {
        let safe = progress.isFinite ? progress : 0.41
        let clamped = min(max(safe, 0), 1)
        self.permille = Int((clamped * 1000).rounded())
    }

    public init(lineWidth: CGFloat) {
        let safe = lineWidth.isFinite ? lineWidth : 4.0
        let clamped = min(max(safe, Self.minLineWidth), Self.maxLineWidth)
        let normalized = (clamped - Self.minLineWidth) / (Self.maxLineWidth - Self.minLineWidth)
        self.init(progress: pow(normalized, 1 / Self.lineWidthExponent))
    }

    public func adjusted(byProgressDelta delta: CGFloat) -> StrokeSize {
        guard delta.isFinite else { return self }
        return StrokeSize(progress: progress + delta)
    }

    public var lineWidth: CGFloat {
        let raw = Self.minLineWidth + (Self.maxLineWidth - Self.minLineWidth) * pow(progress, Self.lineWidthExponent)
        return (raw * 10).rounded() / 10
    }

    public var formattedLineWidth: String {
        let tenths = Int((lineWidth * 10).rounded())
        if tenths.isMultiple(of: 10) {
            return "\(tenths / 10)"
        }
        return "\(tenths / 10).\(tenths % 10)"
    }

    public var highlighterWidth: CGFloat {
        ((8 + 38 * pow(progress, 1.15)) * 2).rounded() / 2
    }

    public var fontSize: CGFloat {
        (11 + 35 * pow(progress, 1.35)).rounded()
    }

    public var mosaicBlockSize: CGFloat {
        CGFloat(max(4, min(24, Int(((4 + 20 * pow(progress, 1.3)) / 2).rounded()) * 2)))
    }

    public var blurRadius: CGFloat {
        CGFloat(max(6, min(32, Int(((6 + 26 * pow(progress, 1.15)) / 2).rounded()) * 2)))
    }

    public var mosaicRadius: CGFloat { mosaicBlockSize }

    public var counterDiameter: CGFloat {
        (18 + 34 * pow(progress, 1.15)).rounded()
    }
}

/// Visual filter modes supported by the privacy redaction tool.
public enum MosaicMode: String, CaseIterable, Sendable {
    case pixelate
    case blur

    public var label: String {
        switch self {
        case .pixelate: CCXL10n.text("Mosaic", zh: "马赛克")
        case .blur: CCXL10n.text("Blur", zh: "模糊")
        }
    }
}

/// Visual attributes applied to an annotation item.
public struct AnnotationStyle: Equatable, Sendable {
    public var color: AnnotationColor
    public var size: StrokeSize
    public var mosaicMode: MosaicMode

    public init(
        color: AnnotationColor = .red,
        size: StrokeSize = .medium,
        mosaicMode: MosaicMode = .pixelate
    ) {
        self.color = color
        self.size = size
        self.mosaicMode = mosaicMode
    }
}

/// Interactive resize/endpoint handles on a selected annotation.
public enum AnnotationHandle: Equatable, Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
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

    private static let handleHitOrder: [AnnotationHandle] = [
        .topLeft, .topRight, .bottomRight, .bottomLeft,
        .top, .right, .bottom, .left,
        .start, .end,
    ]

    public var handlePoints: [AnnotationHandle: CGPoint] {
        switch kind {
        case let .rectangle(raw), let .ellipse(raw), let .mosaic(raw, _):
            let rect = raw.standardized
            var points: [AnnotationHandle: CGPoint] = [
                .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
                .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
                .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
                .bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            ]
            if rect.width >= 16 {
                points[.top] = CGPoint(x: rect.midX, y: rect.maxY)
                points[.bottom] = CGPoint(x: rect.midX, y: rect.minY)
            }
            if rect.height >= 16 {
                points[.left] = CGPoint(x: rect.minX, y: rect.midY)
                points[.right] = CGPoint(x: rect.maxX, y: rect.midY)
            }
            return points
        case let .arrow(start, end):
            return [.start: start, .end: end]
        case .pen, .highlighter, .text, .counter:
            return [:]
        }
    }

    public func hitTestHandle(at point: CGPoint, radius: CGFloat = 7) -> AnnotationHandle? {
        guard point.x.isFinite, point.y.isFinite, radius.isFinite, radius >= 0 else { return nil }
        let points = handlePoints
        for handle in Self.handleHitOrder {
            guard let center = points[handle] else { continue }
            if abs(point.x - center.x) <= radius && abs(point.y - center.y) <= radius {
                return handle
            }
        }
        return nil
    }

    public func hitTest(point: CGPoint, tolerance: CGFloat = 8) -> Bool {
        guard point.x.isFinite, point.y.isFinite, tolerance.isFinite, tolerance >= 0 else { return false }
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
        guard delta.width.isFinite, delta.height.isFinite else { return self }
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
        resized(handle: handle, to: point, constrain: constrain, within: nil)
    }

    public func resized(handle: AnnotationHandle, to point: CGPoint, constrain: Bool, within bounds: CGRect?) -> AnnotationItem {
        guard point.x.isFinite, point.y.isFinite else { return self }
        let safeBounds = Self.sanitizedBounds(bounds)
        var copy = self
        switch kind {
        case let .rectangle(raw):
            copy.kind = .rectangle(Self.resizedRect(raw, handle: handle, to: point, constrain: constrain, within: safeBounds))
        case let .ellipse(raw):
            copy.kind = .ellipse(Self.resizedRect(raw, handle: handle, to: point, constrain: constrain, within: safeBounds))
        case let .mosaic(raw, mode):
            copy.kind = .mosaic(Self.resizedRect(raw, handle: handle, to: point, constrain: constrain, within: safeBounds), mode)
        case let .arrow(start, end):
            switch handle {
            case .start:
                copy.kind = .arrow(
                    start: Self.constrainedEnd(from: end, to: point, snapAngle: constrain, within: safeBounds),
                    end: end
                )
            case .end:
                copy.kind = .arrow(
                    start: start,
                    end: Self.constrainedEnd(from: start, to: point, snapAngle: constrain, within: safeBounds)
                )
            default:
                break
            }
        case .pen, .highlighter, .text, .counter:
            break
        }
        return copy
    }

    // MARK: - Geometry Helpers

    /// Resizes `rawRect` from `handle` toward `point`, supporting corner, single-edge, optional 1:1
    /// square constraint, optional container `bounds` clamping, and a non-collapsing `minimumSize`.
    public static func resizedRect(
        _ rawRect: CGRect,
        handle: AnnotationHandle,
        to point: CGPoint,
        constrain: Bool,
        within bounds: CGRect? = nil,
        minimumSize: CGFloat = 4
    ) -> CGRect {
        guard Self.isFiniteRect(rawRect) else { return .zero }
        let rect = rawRect.standardized
        guard point.x.isFinite, point.y.isFinite else { return rect }
        let safeMin = minimumSize.isFinite ? max(1, minimumSize) : 4
        let safeBounds = Self.sanitizedBounds(bounds)
        let minBoundX = safeBounds?.minX
        let maxBoundX = safeBounds?.maxX
        let minBoundY = safeBounds?.minY
        let maxBoundY = safeBounds?.maxY

        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            guard let anchor = oppositeCorner(of: rect, for: handle) else { return rect }
            if constrain {
                let targetX = safeBounds.map { min(max(point.x, $0.minX), $0.maxX) } ?? point.x
                let targetY = safeBounds.map { min(max(point.y, $0.minY), $0.maxY) } ?? point.y
                let dx = targetX - anchor.x
                let dy = targetY - anchor.y
                let signX: CGFloat = dx >= 0 ? 1 : -1
                let signY: CGFloat = dy >= 0 ? 1 : -1
                let rawSide = max(abs(dx), abs(dy))
                let side: CGFloat
                if let safeBounds {
                    let availX = dx >= 0 ? max(0, safeBounds.maxX - anchor.x) : max(0, anchor.x - safeBounds.minX)
                    let availY = dy >= 0 ? max(0, safeBounds.maxY - anchor.y) : max(0, anchor.y - safeBounds.minY)
                    let maxSide = min(availX, availY)
                    let effectiveMin = min(safeMin, maxSide)
                    side = min(max(rawSide, effectiveMin), maxSide)
                } else {
                    side = max(rawSide, safeMin)
                }
                let end = CGPoint(x: anchor.x + signX * side, y: anchor.y + signY * side)
                return CGRect(
                    x: min(anchor.x, end.x),
                    y: min(anchor.y, end.y),
                    width: abs(end.x - anchor.x),
                    height: abs(end.y - anchor.y)
                )
            }
            let (x, width) = axisInterval(anchor: anchor.x, target: point.x, minimumSize: safeMin, minBound: minBoundX, maxBound: maxBoundX)
            let (y, height) = axisInterval(anchor: anchor.y, target: point.y, minimumSize: safeMin, minBound: minBoundY, maxBound: maxBoundY)
            return CGRect(x: x, y: y, width: width, height: height)

        case .top:
            let (y, height) = axisInterval(anchor: rect.minY, target: point.y, minimumSize: safeMin, minBound: minBoundY, maxBound: maxBoundY)
            return CGRect(x: rect.minX, y: y, width: rect.width, height: height)

        case .bottom:
            let (y, height) = axisInterval(anchor: rect.maxY, target: point.y, minimumSize: safeMin, minBound: minBoundY, maxBound: maxBoundY)
            return CGRect(x: rect.minX, y: y, width: rect.width, height: height)

        case .right:
            let (x, width) = axisInterval(anchor: rect.minX, target: point.x, minimumSize: safeMin, minBound: minBoundX, maxBound: maxBoundX)
            return CGRect(x: x, y: rect.minY, width: width, height: rect.height)

        case .left:
            let (x, width) = axisInterval(anchor: rect.maxX, target: point.x, minimumSize: safeMin, minBound: minBoundX, maxBound: maxBoundX)
            return CGRect(x: x, y: rect.minY, width: width, height: rect.height)

        case .start, .end:
            return rect
        }
    }

    private static func axisInterval(
        anchor: CGFloat,
        target: CGFloat,
        minimumSize: CGFloat,
        minBound: CGFloat?,
        maxBound: CGFloat?
    ) -> (origin: CGFloat, length: CGFloat) {
        let clampedTarget: CGFloat = if let minBound, let maxBound {
            min(max(target, minBound), maxBound)
        } else {
            target
        }
        let effectiveMin: CGFloat = if let minBound, let maxBound {
            min(minimumSize, max(1, maxBound - minBound))
        } else {
            minimumSize
        }
        let delta = clampedTarget - anchor
        if delta >= 0 {
            var start = anchor
            var end = anchor + max(delta, effectiveMin)
            if let maxBound, end > maxBound {
                end = maxBound
                start = min(start, maxBound - effectiveMin)
                if let minBound { start = max(start, minBound) }
            }
            return (start, max(0, end - start))
        } else {
            var start = anchor + min(delta, -effectiveMin)
            var end = anchor
            if let minBound, start < minBound {
                start = minBound
                end = max(end, minBound + effectiveMin)
                if let maxBound { end = min(end, maxBound) }
            }
            return (start, max(0, end - start))
        }
    }

    /// Normalized rectangle spanned from `origin` to `current`, optionally constrained to a 1:1 square.
    public static func constrainedRect(from origin: CGPoint, to current: CGPoint, square: Bool) -> CGRect {
        constrainedRect(from: origin, to: current, square: square, within: nil)
    }

    /// Normalized rectangle spanned from `origin` to `current`, optionally constrained to a 1:1 square
    /// and clamped to stay inside `bounds`.
    public static func constrainedRect(
        from origin: CGPoint,
        to current: CGPoint,
        square: Bool,
        within bounds: CGRect?
    ) -> CGRect {
        guard origin.x.isFinite, origin.y.isFinite, current.x.isFinite, current.y.isFinite else {
            return .zero
        }
        let safeBounds = Self.sanitizedBounds(bounds)
        let clampedOrigin = safeBounds.map { Self.clampPoint(origin, to: $0) } ?? origin
        let clampedCurrent = safeBounds.map { Self.clampPoint(current, to: $0) } ?? current

        var target = clampedCurrent
        if square {
            let dx = clampedCurrent.x - clampedOrigin.x
            let dy = clampedCurrent.y - clampedOrigin.y
            let signX: CGFloat = dx >= 0 ? 1 : -1
            let signY: CGFloat = dy >= 0 ? 1 : -1
            let rawSide = max(abs(dx), abs(dy))
            let side: CGFloat
            if let safeBounds {
                let availX = dx >= 0 ? max(0, safeBounds.maxX - clampedOrigin.x) : max(0, clampedOrigin.x - safeBounds.minX)
                let availY = dy >= 0 ? max(0, safeBounds.maxY - clampedOrigin.y) : max(0, clampedOrigin.y - safeBounds.minY)
                side = min(rawSide, min(availX, availY))
            } else {
                side = rawSide
            }
            target = CGPoint(
                x: clampedOrigin.x + signX * side,
                y: clampedOrigin.y + signY * side
            )
        }
        return CGRect(
            x: min(clampedOrigin.x, target.x),
            y: min(clampedOrigin.y, target.y),
            width: abs(target.x - clampedOrigin.x),
            height: abs(target.y - clampedOrigin.y)
        )
    }

    /// Snaps `end` onto 15° increments around `start` when `snapAngle` is enabled.
    public static func constrainedEnd(
        from start: CGPoint,
        to end: CGPoint,
        snapAngle: Bool,
        stepDegrees: CGFloat = 15
    ) -> CGPoint {
        constrainedEnd(from: start, to: end, snapAngle: snapAngle, stepDegrees: stepDegrees, within: nil)
    }

    /// Snaps `end` onto `stepDegrees` increments around `start` when `snapAngle` is enabled,
    /// clipping the snapped ray so the returned point stays within `bounds`.
    public static func constrainedEnd(
        from start: CGPoint,
        to end: CGPoint,
        snapAngle: Bool,
        stepDegrees: CGFloat = 15,
        within bounds: CGRect?
    ) -> CGPoint {
        guard start.x.isFinite, start.y.isFinite else { return .zero }
        guard end.x.isFinite, end.y.isFinite else { return start }
        let safeBounds = Self.sanitizedBounds(bounds)
        let clampedEnd = safeBounds.map { Self.clampPoint(end, to: $0) } ?? end
        guard snapAngle, stepDegrees.isFinite, stepDegrees > 0 else { return clampedEnd }

        let dx = clampedEnd.x - start.x
        let dy = clampedEnd.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return clampedEnd }
        let stepRad = stepDegrees * .pi / 180
        let angle = (atan2(dy, dx) / stepRad).rounded() * stepRad
        let dirX = cos(angle)
        let dirY = sin(angle)

        var clippedLength = length
        if let safeBounds {
            let clampedStart = Self.clampPoint(start, to: safeBounds)
            if abs(dirX) > 1e-9 {
                let boundX = dirX > 0 ? safeBounds.maxX : safeBounds.minX
                let maxTX = (boundX - clampedStart.x) / dirX
                clippedLength = min(clippedLength, max(0, maxTX))
            }
            if abs(dirY) > 1e-9 {
                let boundY = dirY > 0 ? safeBounds.maxY : safeBounds.minY
                let maxTY = (boundY - clampedStart.y) / dirY
                clippedLength = min(clippedLength, max(0, maxTY))
            }
            let candidate = CGPoint(
                x: clampedStart.x + dirX * clippedLength,
                y: clampedStart.y + dirY * clippedLength
            )
            return Self.clampPoint(candidate, to: safeBounds)
        }
        return CGPoint(x: start.x + dirX * clippedLength, y: start.y + dirY * clippedLength)
    }

    /// Appends `point` to a polyline only when it moved at least `minDistance` points from the tail.
    public static func appendPoint(_ point: CGPoint, to points: [CGPoint], minDistance: CGFloat = 2.5) -> [CGPoint] {
        guard point.x.isFinite, point.y.isFinite else { return points }
        let safeDist = minDistance.isFinite ? max(0, minDistance) : 2.5
        guard let last = points.last else { return [point] }
        guard hypot(point.x - last.x, point.y - last.y) >= safeDist else { return points }
        return points + [point]
    }

    /// Text attributes shared between the inline text editor and Canvas/CoreGraphics renderer.
    public static func textAttributes(color: AnnotationColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let safeFontSize = fontSize.isFinite ? max(1, fontSize) : 14
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: safeFontSize, weight: .bold),
            .foregroundColor: color.nsColor,
            .paragraphStyle: paragraph,
        ]
    }

    private struct TextMeasureKey: Hashable, Sendable {
        let content: String
        let fontTenths: Int
        let maxWidthPoints: Int
    }

    private struct TextMeasureCacheState: Sendable {
        var sizes: [TextMeasureKey: CGSize] = [:]
        var order: [TextMeasureKey] = []
    }

    private static let maxTextMeasureCacheEntries = 64
    private static let textMeasureCache = OSAllocatedUnfairLock(initialState: TextMeasureCacheState())

    /// Computes AppKit bottom-left bounds for `content` anchored at top-left `origin`.
    public static func textBoundingBox(
        origin: CGPoint,
        content: String,
        fontSize: CGFloat,
        maxWidth: CGFloat = 640
    ) -> CGRect {
        let safeOrigin = (origin.x.isFinite && origin.y.isFinite) ? origin : .zero
        let safeFontSize = fontSize.isFinite ? max(1, min(fontSize, 256)) : 14
        let safeMaxWidth = maxWidth.isFinite ? max(24, min(maxWidth, 4096)) : 640

        let baseMeasured = content.isEmpty ? "Ag" : content
        // `NSAttributedString.boundingRect` ignores a trailing newline; append a space so Shift+Enter
        // immediately expands the box height to show the new empty line.
        let measured = baseMeasured.hasSuffix("\n") ? (baseMeasured + " ") : baseMeasured
        let key = TextMeasureKey(
            content: measured,
            fontTenths: Int((safeFontSize * 10).rounded()),
            maxWidthPoints: Int(safeMaxWidth.rounded())
        )

        let size: CGSize
        if let cached = textMeasureCache.withLock({ $0.sizes[key] }) {
            size = cached
        } else {
            let attributed = NSAttributedString(
                string: measured,
                attributes: textAttributes(color: .white, fontSize: safeFontSize)
            )
            let measuredBounds = attributed.boundingRect(
                with: CGSize(width: safeMaxWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let width = max(24, ceil(measuredBounds.width) + 6)
            let height = max(ceil(safeFontSize * 1.35), ceil(measuredBounds.height) + 4)
            let computed = CGSize(width: width, height: height)
            textMeasureCache.withLock { state in
                if state.sizes[key] == nil {
                    state.order.append(key)
                }
                state.sizes[key] = computed
                while state.order.count > maxTextMeasureCacheEntries {
                    let evicted = state.order.removeFirst()
                    state.sizes.removeValue(forKey: evicted)
                }
            }
            size = computed
        }

        return CGRect(x: safeOrigin.x, y: safeOrigin.y - size.height, width: size.width, height: size.height)
    }

    private static func isFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite &&
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite
    }

    private static func sanitizedBounds(_ bounds: CGRect?) -> CGRect? {
        guard let bounds, isFiniteRect(bounds) else { return nil }
        let standardized = bounds.standardized
        guard standardized.width >= 0, standardized.height >= 0 else { return nil }
        return standardized
    }

    private static func clampPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func oppositeCorner(of rect: CGRect, for handle: AnnotationHandle) -> CGPoint? {
        switch handle {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .topRight: CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .top, .right, .bottom, .left, .start, .end: nil
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
