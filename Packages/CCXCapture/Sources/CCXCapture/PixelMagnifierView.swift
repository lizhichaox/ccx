import AppKit
import CCXCore

/// Nearest-neighbor pixel magnifier with live color readout (HEX / RGB / HSL).
@MainActor
final class PixelMagnifierView: NSView {
    /// Number of image pixels shown per side (odd so there is a center pixel).
    static let gridPixels = 11
    static let cellSize: CGFloat = 14
    static let infoHeight: CGFloat = 58
    static var gridSide: CGFloat { CGFloat(gridPixels) * cellSize }
    static var preferredSize: CGSize { CGSize(width: gridSide, height: gridSide + infoHeight) }

    private var gridImage: CGImage?
    /// Offset (in cells) of `gridImage` inside the grid when cropped at image edges.
    private var gridOffset = CGPoint.zero
    private var sample: CCXColorSample?
    private var format: ColorFormat = .hex
    private var positionText = ""
    private var sizeText = ""
    private var lastPixelX: Int?
    private var lastPixelY: Int?
    private var lastFormat: ColorFormat?
    private var lastSizeText: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Pass mouse events straight through to the overlay view so moving past the loupe never triggers exit/enter churn.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Updates the magnifier around image pixel (`pixelX`, `pixelY`) (top-left origin).
    func update(
        image: CGImage,
        pixelX: Int,
        pixelY: Int,
        sample: CCXColorSample?,
        format: ColorFormat,
        sizeText: String
    ) {
        if gridImage != nil &&
           lastPixelX == pixelX &&
           lastPixelY == pixelY &&
           lastFormat == format &&
           lastSizeText == sizeText {
            return
        }
        lastPixelX = pixelX
        lastPixelY = pixelY
        lastFormat = format
        lastSizeText = sizeText

        let half = Self.gridPixels / 2
        let wanted = CGRect(x: pixelX - half, y: pixelY - half, width: Self.gridPixels, height: Self.gridPixels)
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let visible = wanted.intersection(imageRect)
        if visible.isNull || visible.isEmpty {
            gridImage = nil
        } else {
            gridImage = image.cropping(to: visible)
            gridOffset = CGPoint(x: visible.minX - wanted.minX, y: visible.minY - wanted.minY)
        }
        self.sample = sample
        self.format = format
        self.positionText = "(\(pixelX), \(pixelY))"
        self.sizeText = sizeText
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = Self.gridSide
        let cell = Self.cellSize
        let gridOrigin = CGPoint(x: 0, y: bounds.height - side)

        NSColor(white: 0.08, alpha: 0.92).setFill()
        bounds.fill()

        // Pixel grid (nearest-neighbor). Image rows run top-down; AppKit y runs bottom-up.
        if let gridImage {
            context.saveGState()
            context.interpolationQuality = .none
            let drawRect = CGRect(
                x: gridOrigin.x + gridOffset.x * cell,
                y: gridOrigin.y + side - (gridOffset.y + CGFloat(gridImage.height)) * cell,
                width: CGFloat(gridImage.width) * cell,
                height: CGFloat(gridImage.height) * cell
            )
            context.draw(gridImage, in: drawRect)
            context.restoreGState()
        }

        // Faint grid lines.
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(0.5)
        for index in 1..<Self.gridPixels {
            let offset = CGFloat(index) * cell
            context.move(to: CGPoint(x: gridOrigin.x + offset, y: gridOrigin.y))
            context.addLine(to: CGPoint(x: gridOrigin.x + offset, y: gridOrigin.y + side))
            context.move(to: CGPoint(x: gridOrigin.x, y: gridOrigin.y + offset))
            context.addLine(to: CGPoint(x: gridOrigin.x + side, y: gridOrigin.y + offset))
        }
        context.strokePath()

        // Center crosshair band + center pixel outline.
        let center = CGFloat(Self.gridPixels / 2) * cell
        context.setFillColor(NSColor.systemCyan.withAlphaComponent(0.22).cgColor)
        context.fill(CGRect(x: gridOrigin.x + center, y: gridOrigin.y, width: cell, height: side))
        context.fill(CGRect(x: gridOrigin.x, y: gridOrigin.y + center, width: side, height: cell))
        let centerRect = CGRect(x: gridOrigin.x + center, y: gridOrigin.y + center, width: cell, height: cell)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(2)
        context.stroke(centerRect.insetBy(dx: 1, dy: 1))
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(centerRect.insetBy(dx: 0.5, dy: 0.5))
        context.restoreGState()

        // Info area.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let lineHeight: CGFloat = 16
        let infoTop = gridOrigin.y - 4
        (positionText as NSString).draw(at: CGPoint(x: 6, y: infoTop - lineHeight), withAttributes: attributes)
        (sizeText as NSString).draw(at: CGPoint(x: 6, y: infoTop - 2 * lineHeight), withAttributes: attributes)

        let swatch = CGRect(x: 6, y: infoTop - 3 * lineHeight + 2, width: 12, height: 12)
        if let sample {
            sample.nsColor.setFill()
            NSBezierPath(rect: swatch).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: swatch).stroke()
            let text = sample.formatted(as: format)
            (text as NSString).draw(at: CGPoint(x: swatch.maxX + 5, y: swatch.minY - 1), withAttributes: attributes)
        }
    }

    /// Chooses a frame near `cursor` that stays inside `bounds` and below the top safe-area inset (Notch).
    static func frame(near cursor: CGPoint, in bounds: CGRect, topInset: CGFloat) -> CGRect {
        let size = preferredSize
        let gap: CGFloat = 20
        let usable = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - topInset)
        var origin = CGPoint(x: cursor.x + gap, y: cursor.y - gap - size.height)
        if origin.x + size.width > usable.maxX { origin.x = cursor.x - gap - size.width }
        if origin.y < usable.minY { origin.y = cursor.y + gap }
        origin.x = min(max(origin.x, usable.minX), usable.maxX - size.width)
        origin.y = min(max(origin.y, usable.minY), usable.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}
