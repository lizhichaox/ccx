import AppKit
import CCXCore
import QuartzCore

/// GPU-composited nearest-neighbor pixel magnifier with live color readout (HEX / RGB / HSL).
///
/// Uses a `CALayer` backed directly by the frozen display `CGImage` with `contentsRect` and
/// `.nearest` magnification filtering so 120 Hz hover tracking requires zero per-frame
/// `CGImage.cropping(to:)` allocations and zero software backing-store redraws.
@MainActor
final class PixelMagnifierView: NSView {
    /// Number of image pixels shown per side (odd so there is a center pixel).
    static let gridPixels = 11
    static let cellSize: CGFloat = 14
    static let infoHeight: CGFloat = 70
    static var gridSide: CGFloat { CGFloat(gridPixels) * cellSize }
    static var preferredSize: CGSize { CGSize(width: gridSide, height: gridSide + infoHeight) }

    private static let backgroundCGColor = NSColor(white: 0.08, alpha: 0.92).cgColor
    private static let gridLineCGColor = NSColor.black.withAlphaComponent(0.18).cgColor
    private static let crosshairTintCGColor = NSColor.systemCyan.withAlphaComponent(0.22).cgColor
    private static let swatchBorderCGColor = NSColor.white.withAlphaComponent(0.6).cgColor
    private static let infoFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    private static let hintFont = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)

    private static let gridLinesPath: CGPath = {
        let side = gridSide
        let cell = cellSize
        let path = CGMutablePath()
        for index in 1..<gridPixels {
            let offset = CGFloat(index) * cell
            path.move(to: CGPoint(x: offset, y: 0))
            path.addLine(to: CGPoint(x: offset, y: side))
            path.move(to: CGPoint(x: 0, y: offset))
            path.addLine(to: CGPoint(x: side, y: offset))
        }
        return path
    }()

    private static let crosshairPath: CGPath = {
        let side = gridSide
        let cell = cellSize
        let center = CGFloat(gridPixels / 2) * cell
        let path = CGMutablePath()
        path.addRect(CGRect(x: center, y: 0, width: cell, height: side))
        path.addRect(CGRect(x: 0, y: center, width: side, height: cell))
        return path
    }()

    private let gridContainerLayer = CALayer()
    private let pixelLayer = CALayer()
    private let gridLinesLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let centerOuterLayer = CAShapeLayer()
    private let centerInnerLayer = CAShapeLayer()
    private let swatchLayer = CALayer()

    private let positionLabel = MagnifierReadoutLabel(font: infoFont, color: .white)
    private let sizeLabel = MagnifierReadoutLabel(font: infoFont, color: .white)
    private let colorLabel = MagnifierReadoutLabel(font: infoFont, color: .white)
    private let hintLabel = MagnifierReadoutLabel(font: hintFont, color: NSColor.white.withAlphaComponent(0.55))

    private var boundImage: CGImage?
    private var sample: CCXColorSample?
    private var format: ColorFormat = .hex
    private var lastPixelX: Int?
    private var lastPixelY: Int?
    private var lastFormat: ColorFormat?
    private var lastSizeText: String?
    private var lastColorText = ""

    var pixelLayerContentsRect: CGRect { pixelLayer.contentsRect }
    var pixelLayerFrame: CGRect { pixelLayer.frame }
    var displayedPositionText: String { positionLabel.stringValue }
    var displayedSizeText: String { sizeLabel.stringValue }
    var displayedColorText: String { colorLabel.stringValue }
    var displayedHintText: String { hintLabel.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpLayers()
        setUpLabels()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Pass mouse events straight through to the overlay view so moving past the loupe never triggers exit/enter churn.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContentsScale()
    }

    private func setUpLayers() {
        guard let root = layer else { return }
        root.backgroundColor = Self.backgroundCGColor
        root.cornerRadius = 8
        root.masksToBounds = true
        root.borderWidth = 1
        root.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        let side = Self.gridSide
        let cell = Self.cellSize
        let gridOriginY = Self.infoHeight

        gridContainerLayer.frame = CGRect(x: 0, y: gridOriginY, width: side, height: side)
        gridContainerLayer.masksToBounds = true
        gridContainerLayer.backgroundColor = Self.backgroundCGColor
        root.addSublayer(gridContainerLayer)

        pixelLayer.contentsGravity = .resize
        pixelLayer.magnificationFilter = .nearest
        pixelLayer.minificationFilter = .nearest
        pixelLayer.isHidden = true
        gridContainerLayer.addSublayer(pixelLayer)

        gridLinesLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        gridLinesLayer.path = Self.gridLinesPath
        gridLinesLayer.strokeColor = Self.gridLineCGColor
        gridLinesLayer.fillColor = nil
        gridLinesLayer.lineWidth = 0.5
        gridContainerLayer.addSublayer(gridLinesLayer)

        crosshairLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        crosshairLayer.path = Self.crosshairPath
        crosshairLayer.fillColor = Self.crosshairTintCGColor
        crosshairLayer.strokeColor = nil
        gridContainerLayer.addSublayer(crosshairLayer)

        let center = CGFloat(Self.gridPixels / 2) * cell
        let centerRect = CGRect(x: center, y: center, width: cell, height: cell)

        centerOuterLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        centerOuterLayer.path = CGPath(rect: centerRect.insetBy(dx: 1, dy: 1), transform: nil)
        centerOuterLayer.fillColor = nil
        centerOuterLayer.strokeColor = NSColor.black.cgColor
        centerOuterLayer.lineWidth = 2
        gridContainerLayer.addSublayer(centerOuterLayer)

        centerInnerLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        centerInnerLayer.path = CGPath(rect: centerRect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        centerInnerLayer.fillColor = nil
        centerInnerLayer.strokeColor = NSColor.white.cgColor
        centerInnerLayer.lineWidth = 1
        gridContainerLayer.addSublayer(centerInnerLayer)

        let lineHeight: CGFloat = 16
        let infoTop = gridOriginY - 4
        swatchLayer.frame = CGRect(x: 6, y: infoTop - 3 * lineHeight + 2, width: 12, height: 12)
        swatchLayer.borderWidth = 1
        swatchLayer.borderColor = Self.swatchBorderCGColor
        swatchLayer.isHidden = true
        root.addSublayer(swatchLayer)

        updateLayerContentsScale()
    }

    private func setUpLabels() {
        let side = Self.gridSide
        let lineHeight: CGFloat = 16
        let infoTop = Self.infoHeight - 4

        positionLabel.frame = CGRect(x: 6, y: infoTop - lineHeight, width: side - 12, height: 15)
        sizeLabel.frame = CGRect(x: 6, y: infoTop - 2 * lineHeight, width: side - 12, height: 15)
        colorLabel.frame = CGRect(x: 23, y: infoTop - 3 * lineHeight + 1, width: side - 29, height: 15)
        hintLabel.frame = CGRect(x: 6, y: max(3, infoTop - 4 * lineHeight + 3), width: side - 12, height: 13)
        hintLabel.stringValue = CCXL10n.text("C copy · ⇧ format", zh: "C 拷贝 · ⇧ 格式")

        addSubview(positionLabel)
        addSubview(sizeLabel)
        addSubview(colorLabel)
        addSubview(hintLabel)
    }

    private func updateLayerContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        gridContainerLayer.contentsScale = scale
        pixelLayer.contentsScale = scale
        gridLinesLayer.contentsScale = scale
        crosshairLayer.contentsScale = scale
        centerOuterLayer.contentsScale = scale
        centerInnerLayer.contentsScale = scale
        swatchLayer.contentsScale = scale
    }

    /// Releases the display snapshot reference when the overlay closes.
    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pixelLayer.contents = nil
        pixelLayer.isHidden = true
        swatchLayer.isHidden = true
        CATransaction.commit()
        boundImage = nil
        sample = nil
        lastPixelX = nil
        lastPixelY = nil
        lastFormat = nil
        lastSizeText = nil
        lastColorText = ""
    }

    /// Updates the magnifier around image pixel (`pixelX`, `pixelY`) (top-left origin).
    func update(
        image: CGImage,
        pixelX: Int,
        pixelY: Int,
        sample: CCXColorSample?,
        format: ColorFormat,
        sizeText: String
    ) {
        let imageChanged = boundImage !== image
        let pixelChanged = imageChanged || lastPixelX != pixelX || lastPixelY != pixelY
        let sizeChanged = lastSizeText != sizeText
        let sampleOrFormatChanged = sample != self.sample || lastFormat != format
        if !pixelChanged && !sizeChanged && !sampleOrFormatChanged {
            return
        }

        lastPixelX = pixelX
        lastPixelY = pixelY
        lastFormat = format
        lastSizeText = sizeText
        self.sample = sample
        self.format = format

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if imageChanged {
            boundImage = image
            pixelLayer.contents = image
        }

        if pixelChanged {
            let imgW = image.width
            let imgH = image.height
            let half = Self.gridPixels / 2
            let wanted = CGRect(x: pixelX - half, y: pixelY - half, width: Self.gridPixels, height: Self.gridPixels)
            let imageRect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
            let visible = wanted.intersection(imageRect)
            if visible.isNull || visible.isEmpty || imgW <= 0 || imgH <= 0 {
                pixelLayer.isHidden = true
            } else {
                let cell = Self.cellSize
                let side = Self.gridSide
                let offsetX = visible.minX - wanted.minX
                let offsetY = visible.minY - wanted.minY
                pixelLayer.frame = CGRect(
                    x: offsetX * cell,
                    y: side - (offsetY + visible.height) * cell,
                    width: visible.width * cell,
                    height: visible.height * cell
                )
                // CALayer.contentsRect uses top-left normalized image coordinates (y = 0 at top of CGImage).
                pixelLayer.contentsRect = CGRect(
                    x: visible.minX / CGFloat(imgW),
                    y: visible.minY / CGFloat(imgH),
                    width: visible.width / CGFloat(imgW),
                    height: visible.height / CGFloat(imgH)
                )
                pixelLayer.isHidden = false
            }
            positionLabel.stringValue = "(\(pixelX), \(pixelY))"
        }

        if sizeChanged {
            sizeLabel.stringValue = sizeText
        }

        if sampleOrFormatChanged {
            if let sample {
                swatchLayer.backgroundColor = sample.nsColor.cgColor
                swatchLayer.isHidden = false
                let colorText = sample.formatted(as: format)
                if colorText != lastColorText {
                    lastColorText = colorText
                    colorLabel.stringValue = colorText
                }
            } else {
                swatchLayer.isHidden = true
                if !lastColorText.isEmpty {
                    lastColorText = ""
                    colorLabel.stringValue = ""
                }
            }
        }

        CATransaction.commit()
    }

    /// Chooses a frame near `cursor` that stays inside `bounds` and below the top safe-area inset (Notch).
    static func frame(near cursor: CGPoint, in bounds: CGRect, topInset: CGFloat) -> CGRect {
        let size = preferredSize
        guard !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite
        else {
            return CGRect(origin: .zero, size: size)
        }
        let safeTopInset = topInset.isFinite ? max(0, topInset) : 0
        let safeCursor = (cursor.x.isFinite && cursor.y.isFinite) ? cursor : bounds.origin
        let gap: CGFloat = 20
        let usableHeight = max(0, bounds.height - safeTopInset)
        let usable = CGRect(x: bounds.minX, y: bounds.minY, width: max(0, bounds.width), height: usableHeight)
        var origin = CGPoint(x: safeCursor.x + gap, y: safeCursor.y - gap - size.height)
        if origin.x + size.width > usable.maxX { origin.x = safeCursor.x - gap - size.width }
        if origin.y < usable.minY { origin.y = safeCursor.y + gap }
        let maxOriginX = max(usable.minX, usable.maxX - size.width)
        let maxOriginY = max(usable.minY, usable.maxY - size.height)
        origin.x = min(max(origin.x, usable.minX), maxOriginX)
        origin.y = min(max(origin.y, usable.minY), maxOriginY)
        return CGRect(origin: origin, size: size)
    }
}

private final class MagnifierReadoutLabel: NSTextField {
    init(font: NSFont, color: NSColor) {
        super.init(frame: .zero)
        self.font = font
        self.textColor = color
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
