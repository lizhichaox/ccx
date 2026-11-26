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
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .mosaic: "checkerboard.rectangle"
        case .text: "t.square"
        case .counter: "number.circle"
        }
    }

    /// Returns the crisp template icon rendered in the floating annotation toolbar.
    ///
    /// `.pen`, `.highlighter`, and `.text` use custom locale-independent vector glyphs:
    /// - `.pen` renders an open freehand S-wave (matching the draw-output grammar of
    ///   `rectangle`, `circle`, and `arrow.up.right` with zero diagonal stick).
    /// - `.highlighter` renders a broad chisel nib over a thick 4.2pt translucent swath,
    ///   giving an unmistakably different silhouette from `.pen` at 14pt toolbar size.
    /// - `.text` renders `T` + an I-beam insertion cursor rather than Apple's `"textformat"`
    ///   / `"text.cursor"` SF Symbols, which localize into Chinese characters under `zh-Hans`.
    public func toolbarIconImage(accessibilityDescription: String? = nil) -> NSImage {
        switch self {
        case .pen:
            return Self.makeFreehandPenIcon(accessibilityDescription: accessibilityDescription)
        case .highlighter:
            return Self.makeHighlighterIcon(accessibilityDescription: accessibilityDescription)
        case .text:
            return Self.makeTextInputIcon(accessibilityDescription: accessibilityDescription)
        default:
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let raw = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
            let configured = raw?.withSymbolConfiguration(config) ?? raw ?? NSImage()
            configured.isTemplate = true
            return configured
        }
    }

    private static func makeFreehandPenIcon(accessibilityDescription: String?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()

            // Smooth horizontal-flowing S-wave matching the ~1.5pt optical weight of neighbor shapes.
            let wave = NSBezierPath()
            wave.lineWidth = 1.6
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.move(to: NSPoint(x: 1.9, y: 6.0))
            wave.curve(
                to: NSPoint(x: 9.0, y: 8.0),
                controlPoint1: NSPoint(x: 3.8, y: 12.5),
                controlPoint2: NSPoint(x: 6.8, y: 12.1)
            )
            wave.curve(
                to: NSPoint(x: 16.1, y: 10.0),
                controlPoint1: NSPoint(x: 11.2, y: 3.9),
                controlPoint2: NSPoint(x: 14.2, y: 3.5)
            )
            wave.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func makeHighlighterIcon(accessibilityDescription: String?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            // 1. Thick 4.2pt translucent chisel-cut highlight swath spanning the bottom.
            let swath = NSBezierPath()
            swath.move(to: NSPoint(x: 1.5, y: 1.8))
            swath.line(to: NSPoint(x: 14.7, y: 1.8))
            swath.line(to: NSPoint(x: 16.5, y: 6.0))
            swath.line(to: NSPoint(x: 3.3, y: 6.0))
            swath.close()
            NSColor.black.withAlphaComponent(0.46).setFill()
            swath.fill()

            swath.lineWidth = 0.85
            swath.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(0.32).setStroke()
            swath.stroke()

            // 2. Broad 38°-tilted chisel marker barrel with perpendicular collar seam touching y = 6.0.
            let collarL = NSPoint(x: 8.65, y: 10.35)
            let collarR = NSPoint(x: 11.80, y: 7.89)
            let dx: CGFloat = 0.616 * 4.5
            let dy: CGFloat = 0.788 * 4.5
            let topL = NSPoint(x: collarL.x + dx, y: collarL.y + dy)
            let topR = NSPoint(x: collarR.x + dx, y: collarR.y + dy)

            let barrel = NSBezierPath()
            barrel.move(to: collarL)
            barrel.line(to: topL)
            barrel.line(to: topR)
            barrel.line(to: collarR)
            barrel.close()
            barrel.lineWidth = 1.35
            barrel.lineJoinStyle = .round
            NSColor.black.setStroke()
            barrel.stroke()

            // Solid broad 3.4pt flat chisel nib wedge resting squarely on the swath top edge.
            let nib = NSBezierPath()
            nib.move(to: collarL)
            nib.line(to: collarR)
            nib.line(to: NSPoint(x: 10.65, y: 6.0))
            nib.line(to: NSPoint(x: 7.25, y: 6.0))
            nib.close()
            NSColor.black.setFill()
            nib.fill()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func makeTextInputIcon(accessibilityDescription: String?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()

            // Typographic "T" on the left (x: 2.25...10.25, y: 3.25...12.5).
            let letter = NSBezierPath()
            letter.lineWidth = 1.45
            letter.lineCapStyle = .round
            letter.lineJoinStyle = .round
            letter.move(to: NSPoint(x: 2.25, y: 11.35))
            letter.line(to: NSPoint(x: 2.25, y: 12.5))
            letter.line(to: NSPoint(x: 10.25, y: 12.5))
            letter.line(to: NSPoint(x: 10.25, y: 11.35))
            letter.move(to: NSPoint(x: 6.25, y: 12.5))
            letter.line(to: NSPoint(x: 6.25, y: 3.25))
            letter.move(to: NSPoint(x: 4.5, y: 3.25))
            letter.line(to: NSPoint(x: 8.0, y: 3.25))
            letter.stroke()

            // Vertical I-beam text-insertion cursor on the right (x: 14.25, y: 2.0...14.0).
            let cursor = NSBezierPath()
            cursor.lineWidth = 1.25
            cursor.lineCapStyle = .round
            cursor.lineJoinStyle = .round
            cursor.move(to: NSPoint(x: 14.25, y: 2.0))
            cursor.line(to: NSPoint(x: 14.25, y: 14.0))
            cursor.move(to: NSPoint(x: 12.5, y: 14.0))
            cursor.line(to: NSPoint(x: 16.0, y: 14.0))
            cursor.move(to: NSPoint(x: 12.5, y: 2.0))
            cursor.line(to: NSPoint(x: 16.0, y: 2.0))
            cursor.stroke()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
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

    /// Concise single-line localized tooltip combining tool name, shortcut key, and modifier hint.
    public var toolbarTooltip: String {
        switch self {
        case .select:
            return CCXL10n.text("Select / Move (V)", zh: "选择 / 移动 (V)")
        case .rectangle:
            return CCXL10n.text("Rectangle (1) · ⇧ Square", zh: "矩形 (1) · ⇧ 正方形")
        case .ellipse:
            return CCXL10n.text("Ellipse (2) · ⇧ Circle", zh: "椭圆 (2) · ⇧ 正圆")
        case .arrow:
            return CCXL10n.text("Arrow (3) · ⇧ 15° Snap", zh: "箭头 (3) · ⇧ 15° 对齐")
        case .pen:
            return CCXL10n.text("Freehand Pen (4)", zh: "画笔 (4)")
        case .highlighter:
            return CCXL10n.text("Highlighter (5)", zh: "荧光笔 (5)")
        case .mosaic:
            return CCXL10n.text("Mosaic / Blur (6) · ⇧ Square", zh: "马赛克 / 模糊 (6) · ⇧ 正方形")
        case .text:
            return CCXL10n.text("Text (7) · ⇧↩ New Line", zh: "文字 (7) · ⇧↩ 换行")
        case .counter:
            return CCXL10n.text("Step Counter (8)", zh: "序号 (8)")
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
        self.r = r.isFinite ? min(max(r, 0), 1) : 0
        self.g = g.isFinite ? min(max(g, 0), 1) : 0
        self.b = b.isFinite ? min(max(b, 0), 1) : 0
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

    /// Localized human-readable name for curated palette colors, falling back to `hex`.
    public var displayName: String {
        switch self {
        case .red: CCXL10n.text("Red", zh: "红色")
        case .orange: CCXL10n.text("Orange", zh: "橙色")
        case .yellow: CCXL10n.text("Yellow", zh: "黄色")
        case .green: CCXL10n.text("Green", zh: "绿色")
        case .blue: CCXL10n.text("Blue", zh: "蓝色")
        case .white: CCXL10n.text("White", zh: "白色")
        case .charcoal: CCXL10n.text("Charcoal", zh: "炭黑")
        default: hex
        }
    }

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

    public var tooltip: String {
        switch self {
        case .pixelate: CCXL10n.text("Pixelate redaction", zh: "马赛克打码")
        case .blur: CCXL10n.text("Gaussian blur redaction", zh: "高斯模糊打码")
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

    /// Upper safety bounds preventing unbounded memory/CPU growth from extreme freehand drags or pasted text.
    public static let maxPolylinePoints = 10_000
    public static let maxTextLength = 4_096

    /// Returns a copy whose text length and polyline point count are bounded within safety caps.
    /// Fast O(1) no-op when the item is already within limits.
    public func sanitized() -> AnnotationItem {
        switch kind {
        case let .pen(points) where points.count > Self.maxPolylinePoints:
            var copy = self
            copy.kind = .pen(Array(points.prefix(Self.maxPolylinePoints)))
            return copy
        case let .highlighter(points) where points.count > Self.maxPolylinePoints:
            var copy = self
            copy.kind = .highlighter(Array(points.prefix(Self.maxPolylinePoints)))
            return copy
        case let .text(origin, content) where content.utf8.count > Self.maxTextLength:
            let bounded = Self.boundedText(content)
            guard bounded != content else { return self }
            var copy = self
            copy.kind = .text(origin: origin, content: bounded)
            return copy
        default:
            return self
        }
    }

    public var boundingBox: CGRect {
        switch kind {
        case let .rectangle(rect), let .ellipse(rect), let .mosaic(rect, _):
            return Self.isFiniteRect(rect) ? rect.standardized : .zero
        case let .arrow(start, end):
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return .zero }
            let width = abs(end.x - start.x)
            let height = abs(end.y - start.y)
            guard width.isFinite, height.isFinite else { return .zero }
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: width,
                height: height
            )
        case let .pen(points), let .highlighter(points):
            return Self.polylineBounds(points)
        case let .text(origin, content):
            return Self.textBoundingBox(origin: origin, content: content, fontSize: style.size.fontSize)
        case let .counter(center, _):
            guard center.x.isFinite, center.y.isFinite else { return .zero }
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
            guard Self.isFiniteRect(raw) else { return [:] }
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
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return [:] }
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
            guard Self.isFiniteRect(raw) else { return false }
            let rect = raw.standardized
            let pad = tolerance + style.size.lineWidth / 2
            guard rect.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
            if rect.width > pad * 3 && rect.height > pad * 3 {
                return !rect.insetBy(dx: pad, dy: pad).contains(point)
            }
            return true

        case let .ellipse(raw):
            guard Self.isFiniteRect(raw) else { return false }
            let rect = raw.standardized
            let rx = max(rect.width / 2, 1)
            let ry = max(rect.height / 2, 1)
            let pad = tolerance + style.size.lineWidth / 2
            let d = hypot((point.x - rect.midX) / rx, (point.y - rect.midY) / ry)
            guard d.isFinite else { return false }
            let band = pad / min(rx, ry)
            if min(rx, ry) <= pad * 1.5 {
                return d <= 1 + band
            }
            return abs(d - 1) <= band

        case let .arrow(start, end):
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return false }
            let pad = tolerance + style.size.lineWidth / 2
            let headPad = max(pad, max(14, style.size.lineWidth * 4.2) * 0.65)
            let box = boundingBox
            guard Self.isFiniteRect(box), box.insetBy(dx: -headPad, dy: -headPad).contains(point) else { return false }
            if Self.distanceToSegment(point, start, end) <= pad { return true }
            let headRadius = max(14, style.size.lineWidth * 4.2) * 0.65
            return hypot(point.x - end.x, point.y - end.y) <= headRadius

        case let .pen(points):
            let pad = tolerance + style.size.lineWidth / 2
            let box = boundingBox
            guard !points.isEmpty, Self.isFiniteRect(box), box.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
            return Self.hitTestPolyline(points, point: point, threshold: pad)

        case let .highlighter(points):
            let pad = tolerance + style.size.highlighterWidth / 2
            let box = boundingBox
            guard !points.isEmpty, Self.isFiniteRect(box), box.insetBy(dx: -pad, dy: -pad).contains(point) else { return false }
            return Self.hitTestPolyline(points, point: point, threshold: pad)

        case let .mosaic(raw, _):
            guard Self.isFiniteRect(raw) else { return false }
            return raw.standardized.insetBy(dx: -4, dy: -4).contains(point)

        case let .text(origin, _):
            guard origin.x.isFinite, origin.y.isFinite else { return false }
            return boundingBox.insetBy(dx: -6, dy: -4).contains(point)

        case let .counter(center, _):
            guard center.x.isFinite, center.y.isFinite else { return false }
            let r = style.size.counterDiameter / 2 + 4
            return hypot(point.x - center.x, point.y - center.y) <= r
        }
    }

    public func translated(by delta: CGSize) -> AnnotationItem {
        guard delta.width.isFinite, delta.height.isFinite else { return self }
        var copy = self
        switch kind {
        case let .rectangle(rect):
            guard Self.isFiniteRect(rect) else { return self }
            let moved = rect.offsetBy(dx: delta.width, dy: delta.height)
            guard Self.isFiniteRect(moved) else { return self }
            copy.kind = .rectangle(moved)
        case let .ellipse(rect):
            guard Self.isFiniteRect(rect) else { return self }
            let moved = rect.offsetBy(dx: delta.width, dy: delta.height)
            guard Self.isFiniteRect(moved) else { return self }
            copy.kind = .ellipse(moved)
        case let .arrow(start, end):
            let nextStart = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
            let nextEnd = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
            guard nextStart.x.isFinite, nextStart.y.isFinite, nextEnd.x.isFinite, nextEnd.y.isFinite else { return self }
            copy.kind = .arrow(start: nextStart, end: nextEnd)
        case let .pen(points):
            let moved = points.compactMap { pt -> CGPoint? in
                let next = CGPoint(x: pt.x + delta.width, y: pt.y + delta.height)
                return (next.x.isFinite && next.y.isFinite) ? next : nil
            }
            guard moved.count == points.count else { return self }
            copy.kind = .pen(moved)
        case let .highlighter(points):
            let moved = points.compactMap { pt -> CGPoint? in
                let next = CGPoint(x: pt.x + delta.width, y: pt.y + delta.height)
                return (next.x.isFinite && next.y.isFinite) ? next : nil
            }
            guard moved.count == points.count else { return self }
            copy.kind = .highlighter(moved)
        case let .mosaic(rect, mode):
            guard Self.isFiniteRect(rect) else { return self }
            let moved = rect.offsetBy(dx: delta.width, dy: delta.height)
            guard Self.isFiniteRect(moved) else { return self }
            copy.kind = .mosaic(moved, mode)
        case let .text(origin, content):
            let nextOrigin = CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
            guard nextOrigin.x.isFinite, nextOrigin.y.isFinite else { return self }
            copy.kind = .text(origin: nextOrigin, content: content)
        case let .counter(center, number):
            let nextCenter = CGPoint(x: center.x + delta.width, y: center.y + delta.height)
            guard nextCenter.x.isFinite, nextCenter.y.isFinite else { return self }
            copy.kind = .counter(center: nextCenter, number: number)
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

    /// Appends `point` to a polyline only when it moved at least `minDistance` points from the tail
    /// and the polyline has not exceeded `maxPolylinePoints`.
    public static func appendPoint(_ point: CGPoint, to points: [CGPoint], minDistance: CGFloat = 2.5) -> [CGPoint] {
        var updated = points
        _ = appendPointInPlace(point, to: &updated, minDistance: minDistance)
        return updated
    }

    /// In-place amortized O(1) variant of `appendPoint` returning `true` when `point` was appended.
    @discardableResult
    public static func appendPointInPlace(_ point: CGPoint, to points: inout [CGPoint], minDistance: CGFloat = 2.5) -> Bool {
        guard point.x.isFinite, point.y.isFinite, points.count < Self.maxPolylinePoints else { return false }
        let safeDist = minDistance.isFinite ? max(0, minDistance) : 2.5
        guard let last = points.last else {
            points.append(point)
            return true
        }
        guard hypot(point.x - last.x, point.y - last.y) >= safeDist else { return false }
        points.append(point)
        return true
    }

    /// Caps annotation text length in O(maxTextLength) time without scanning full multi-MB strings.
    public static func boundedText(_ content: String) -> String {
        if content.utf8.count <= maxTextLength {
            return content
        }
        if let cutoff = content.index(content.startIndex, offsetBy: maxTextLength, limitedBy: content.endIndex),
           cutoff < content.endIndex {
            return String(content[..<cutoff])
        }
        return content
    }

    private nonisolated(unsafe) static let wordWrapParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return (style.copy() as? NSParagraphStyle) ?? style
    }()

    /// Text attributes shared between the inline text editor and Canvas/CoreGraphics renderer.
    public static func textAttributes(color: AnnotationColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let safeFontSize = fontSize.isFinite ? max(1, min(fontSize, 256)) : 14
        return [
            .font: NSFont.systemFont(ofSize: safeFontSize, weight: .bold),
            .foregroundColor: color.nsColor,
            .paragraphStyle: wordWrapParagraphStyle,
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
        var totalKeyBytes: Int = 0
    }

    private static let maxTextMeasureCacheEntries = 64
    private static let maxTextMeasureCacheKeyBytes = 512
    private static let maxTextMeasureCacheTotalBytes = 16 * 1024
    private static let textMeasureCache = OSAllocatedUnfairLock(initialState: TextMeasureCacheState())

    internal static var textMeasureCacheCountForTesting: Int {
        textMeasureCache.withLock { $0.sizes.count }
    }

    internal static var textMeasureCacheBytesForTesting: Int {
        textMeasureCache.withLock { $0.totalKeyBytes }
    }

    internal static func clearTextMeasureCacheForTesting() {
        textMeasureCache.withLock { state in
            state.sizes.removeAll()
            state.order.removeAll()
            state.totalKeyBytes = 0
        }
    }

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

        let bounded = boundedText(content)
        let baseMeasured = bounded.isEmpty ? "Ag" : bounded
        // `NSAttributedString.boundingRect` ignores a trailing newline; append a space so Shift+Enter
        // immediately expands the box height to show the new empty line.
        let measured = baseMeasured.hasSuffix("\n") ? (baseMeasured + " ") : baseMeasured
        let keyBytes = measured.utf8.count
        let shouldCache = keyBytes <= maxTextMeasureCacheKeyBytes
        let key = TextMeasureKey(
            content: measured,
            fontTenths: Int((safeFontSize * 10).rounded()),
            maxWidthPoints: Int(safeMaxWidth.rounded())
        )

        let size: CGSize
        if shouldCache, let cached = textMeasureCache.withLock({ state -> CGSize? in
            guard let found = state.sizes[key] else { return nil }
            if let idx = state.order.firstIndex(of: key), idx != state.order.count - 1 {
                state.order.remove(at: idx)
                state.order.append(key)
            }
            return found
        }) {
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
            if shouldCache {
                textMeasureCache.withLock { state in
                    if state.sizes[key] == nil {
                        state.order.append(key)
                        state.totalKeyBytes += keyBytes
                    } else if let idx = state.order.firstIndex(of: key) {
                        state.order.remove(at: idx)
                        state.order.append(key)
                    }
                    state.sizes[key] = computed
                    while (state.order.count > maxTextMeasureCacheEntries || state.totalKeyBytes > maxTextMeasureCacheTotalBytes),
                          !state.order.isEmpty {
                        let evicted = state.order.removeFirst()
                        if state.sizes.removeValue(forKey: evicted) != nil {
                            state.totalKeyBytes = max(0, state.totalKeyBytes - evicted.content.utf8.count)
                        }
                    }
                }
            }
            size = computed
        }

        return CGRect(x: safeOrigin.x, y: safeOrigin.y - size.height, width: size.width, height: size.height)
    }

    private static func isFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite &&
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite &&
            rect.maxX.isFinite && rect.maxY.isFinite
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
        var minX: CGFloat = .infinity
        var maxX: CGFloat = -.infinity
        var minY: CGFloat = .infinity
        var maxY: CGFloat = -.infinity
        var foundFinite = false
        for p in points where p.x.isFinite && p.y.isFinite {
            foundFinite = true
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        guard foundFinite else { return .zero }
        let width = maxX - minX
        let height = maxY - minY
        guard width.isFinite, height.isFinite else { return .zero }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private static func hitTestPolyline(_ points: [CGPoint], point: CGPoint, threshold: CGFloat) -> Bool {
        var previous: CGPoint?
        for current in points where current.x.isFinite && current.y.isFinite {
            if let prev = previous {
                if distanceToSegment(point, prev, current) <= threshold {
                    return true
                }
            } else if hypot(point.x - current.x, point.y - current.y) <= threshold {
                return true
            }
            previous = current
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
