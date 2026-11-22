import AppKit
import CCXAnnotate

/// Action commands triggered from the floating snip toolbar.
enum SnipToolbarAction: Sendable {
    case undo, redo, pin, copy, save, cancel
}

/// Two-tier Liquid Glass floating toolbar for selecting annotation tools, styles,
/// undo/redo history, and final capture actions.
@MainActor
final class SnipActionToolbar: NSView {
    static let primaryHeight: CGFloat = 40
    static let styleBarHeight: CGFloat = 34
    static let barGap: CGFloat = 6
    static let preferredSize = CGSize(width: 488, height: primaryHeight)
    static let expandedSize = CGSize(width: 488, height: primaryHeight + barGap + styleBarHeight)

    var onAction: ((SnipToolbarAction) -> Void)?
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onStyleChanged: ((AnnotationStyle) -> Void)?

    private struct RenderedState: Equatable {
        let activeTool: AnnotationTool
        let styleTool: AnnotationTool
        let style: AnnotationStyle
        let showStyleBar: Bool
        let canUndo: Bool
        let canRedo: Bool
    }

    private var activeTool: AnnotationTool = .select
    private var currentStyle = AnnotationStyle()
    private var isStyleBarVisible = false
    private var lastRenderedState: RenderedState?

    private let primarySurface: NSView
    private let styleSurface: NSView

    private var toolButtons: [AnnotationTool: ToolToggleButton] = [:]
    private var undoButton: ToolbarIconButton!
    private var redoButton: ToolbarIconButton!

    private let colorsStack = NSStackView()
    private let mosaicModeStack = NSStackView()
    private var colorButtons: [AnnotationColor: ColorSwatchButton] = [:]
    private var mosaicModeButtons: [MosaicMode: ModePillButton] = [:]
    private var sizeButtons: [StrokePreset: SizeDotButton] = [:]

    override init(frame frameRect: NSRect) {
        let primaryContent = NSView(frame: .zero)
        let styleContent = NSView(frame: .zero)
        self.primarySurface = Self.makeGlassSurface(contentView: primaryContent, cornerRadius: 12)
        self.styleSurface = Self.makeGlassSurface(contentView: styleContent, cornerRadius: 10)
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        setUpPrimaryBar(in: primaryContent)
        setUpStyleBar(in: styleContent)

        primarySurface.translatesAutoresizingMaskIntoConstraints = false
        styleSurface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(primarySurface)
        addSubview(styleSurface)

        NSLayoutConstraint.activate([
            primarySurface.topAnchor.constraint(equalTo: topAnchor),
            primarySurface.centerXAnchor.constraint(equalTo: centerXAnchor),
            primarySurface.widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            primarySurface.heightAnchor.constraint(equalToConstant: Self.primaryHeight),

            styleSurface.topAnchor.constraint(equalTo: primarySurface.bottomAnchor, constant: Self.barGap),
            styleSurface.centerXAnchor.constraint(equalTo: centerXAnchor),
            styleSurface.heightAnchor.constraint(equalToConstant: Self.styleBarHeight),
        ])

        update(activeTool: .select, style: AnnotationStyle(), showStyleBar: false, canUndo: false, canRedo: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard hitsInteractiveArea(local) else { return nil }
        return super.hitTest(point)
    }

    /// Whether a point in toolbar-local coordinates falls on either visible pill surface.
    func hitsInteractiveArea(_ localPoint: CGPoint) -> Bool {
        if primarySurface.frame.contains(localPoint) { return true }
        if !styleSurface.isHidden, styleSurface.frame.contains(localPoint) { return true }
        return false
    }

    func update(
        activeTool: AnnotationTool,
        styleTool: AnnotationTool? = nil,
        style: AnnotationStyle,
        showStyleBar: Bool,
        canUndo: Bool,
        canRedo: Bool
    ) {
        let effectiveStyleTool = styleTool ?? activeTool
        let nextState = RenderedState(
            activeTool: activeTool,
            styleTool: effectiveStyleTool,
            style: style,
            showStyleBar: showStyleBar,
            canUndo: canUndo,
            canRedo: canRedo
        )
        guard nextState != lastRenderedState else { return }
        lastRenderedState = nextState

        self.activeTool = activeTool
        self.currentStyle = style
        self.isStyleBarVisible = showStyleBar

        for (tool, button) in toolButtons {
            button.isSelectedTool = (tool == activeTool)
        }

        undoButton.isActionAvailable = canUndo
        redoButton.isActionAvailable = canRedo

        styleSurface.isHidden = !showStyleBar
        if showStyleBar {
            let showMosaic = effectiveStyleTool == .mosaic
            colorsStack.isHidden = showMosaic
            mosaicModeStack.isHidden = !showMosaic
            for (color, button) in colorButtons {
                button.isChosen = (color == style.color)
            }
            for (mode, button) in mosaicModeButtons {
                button.isChosen = (mode == style.mosaicMode)
            }
            for (preset, button) in sizeButtons {
                button.isChosen = (preset == style.size)
            }
        }
    }

    // MARK: - Setup

    private func setUpPrimaryBar(in container: NSView) {
        var views: [NSView] = []

        for tool in AnnotationTool.drawingTools {
            let tip = tool.shortcutHint.map { "\(tool.displayName) (\($0))" } ?? tool.displayName
            let button = ToolToggleButton(tool: tool, symbol: tool.symbolName, tooltip: tip)
            button.target = self
            button.action = #selector(toolPressed(_:))
            toolButtons[tool] = button
            views.append(button)
        }

        views.append(Self.makeDivider())

        let undo = ToolbarIconButton(
            symbol: "arrow.uturn.backward",
            tooltip: "Undo (⌘Z)",
            tint: .white,
            width: 28
        ) { [weak self] in
            self?.onAction?(.undo)
        }
        let redo = ToolbarIconButton(
            symbol: "arrow.uturn.forward",
            tooltip: "Redo (⇧⌘Z)",
            tint: .white,
            width: 28
        ) { [weak self] in
            self?.onAction?(.redo)
        }
        undoButton = undo
        redoButton = redo
        views.append(undo)
        views.append(redo)

        views.append(Self.makeDivider())

        views.append(ToolbarIconButton(symbol: "pin", tooltip: "Pin (Return)", tint: .systemGreen, width: 32) { [weak self] in
            self?.onAction?(.pin)
        })
        views.append(ToolbarIconButton(symbol: "doc.on.doc", tooltip: "Copy (⌘C)", tint: .white, width: 32) { [weak self] in
            self?.onAction?(.copy)
        })
        views.append(ToolbarIconButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", tint: .white, width: 32) { [weak self] in
            self?.onAction?(.save)
        })
        views.append(ToolbarIconButton(symbol: "xmark", tooltip: "Cancel (Esc)", tint: .systemRed, width: 32) { [weak self] in
            self?.onAction?(.cancel)
        })

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func setUpStyleBar(in container: NSView) {
        colorsStack.orientation = .horizontal
        colorsStack.alignment = .centerY
        colorsStack.spacing = 4
        for color in AnnotationColor.palette {
            let button = ColorSwatchButton(color: color)
            button.target = self
            button.action = #selector(colorPressed(_:))
            colorButtons[color] = button
            colorsStack.addArrangedSubview(button)
        }

        mosaicModeStack.orientation = .horizontal
        mosaicModeStack.alignment = .centerY
        mosaicModeStack.spacing = 4
        for mode in MosaicMode.allCases {
            let button = ModePillButton(mode: mode)
            button.target = self
            button.action = #selector(mosaicModePressed(_:))
            mosaicModeButtons[mode] = button
            mosaicModeStack.addArrangedSubview(button)
        }

        let sizesStack = NSStackView()
        sizesStack.orientation = .horizontal
        sizesStack.alignment = .centerY
        sizesStack.spacing = 2
        for preset in StrokePreset.allCases {
            let button = SizeDotButton(preset: preset)
            button.target = self
            button.action = #selector(sizePressed(_:))
            sizeButtons[preset] = button
            sizesStack.addArrangedSubview(button)
        }

        let stack = NSStackView(views: [
            colorsStack,
            mosaicModeStack,
            Self.makeDivider(),
            sizesStack,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func toolPressed(_ sender: NSButton) {
        guard let tool = (sender as? ToolToggleButton)?.tool else { return }
        onToolSelected?(tool)
    }

    @objc private func colorPressed(_ sender: NSButton) {
        guard let color = (sender as? ColorSwatchButton)?.annotationColor else { return }
        var updated = currentStyle
        updated.color = color
        onStyleChanged?(updated)
    }

    @objc private func mosaicModePressed(_ sender: NSButton) {
        guard let mode = (sender as? ModePillButton)?.mosaicMode else { return }
        var updated = currentStyle
        updated.mosaicMode = mode
        onStyleChanged?(updated)
    }

    @objc private func sizePressed(_ sender: NSButton) {
        guard let preset = (sender as? SizeDotButton)?.preset else { return }
        var updated = currentStyle
        updated.size = preset
        onStyleChanged?(updated)
    }

    // MARK: - Placement & Chrome Helpers

    /// Anchors the toolbar below the selection (right-aligned), else above, else inside; clamped to `bounds`.
    static func frame(for selection: CGRect, in bounds: CGRect, topInset: CGFloat) -> CGRect {
        frame(for: selection, in: bounds, topInset: topInset, showsStyleBar: false)
    }

    static func frame(
        for selection: CGRect,
        in bounds: CGRect,
        topInset: CGFloat,
        showsStyleBar: Bool
    ) -> CGRect {
        let size = showsStyleBar ? expandedSize : preferredSize
        let gap: CGFloat = 8
        let usableMaxY = bounds.maxY - topInset
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.minY - gap - size.height)
        if origin.y < bounds.minY {
            origin.y = selection.maxY + gap
            if origin.y + size.height > usableMaxY {
                origin.y = selection.minY + gap
            }
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), usableMaxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    private static func makeGlassSurface(contentView: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = contentView
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: effect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    private static func makeDivider() -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(line)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalToConstant: 9),
            wrapper.heightAnchor.constraint(equalToConstant: 20),
            line.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 18),
        ])
        return wrapper
    }
}

// MARK: - Toolbar Button Controls

private class HoverButton: NSButton {
    var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateVisuals()
        }
    }
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    func updateVisuals() {}
}

private final class ToolToggleButton: HoverButton {
    let tool: AnnotationTool
    var isSelectedTool = false {
        didSet {
            guard oldValue != isSelectedTool else { return }
            updateVisuals()
        }
    }

    init(tool: AnnotationTool, symbol: String, tooltip: String) {
        self.tool = tool
        super.init(frame: .zero)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        self.image = image
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        updateVisuals()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateVisuals() {
        if isSelectedTool {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
            contentTintColor = .white
        } else if isHovering {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            contentTintColor = .white
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = NSColor.white.withAlphaComponent(0.86)
        }
    }
}

private final class ToolbarIconButton: HoverButton {
    private let baseTint: NSColor
    private let handler: () -> Void
    var isActionAvailable = true {
        didSet {
            guard oldValue != isActionAvailable else { return }
            isEnabled = isActionAvailable
            updateVisuals()
        }
    }

    init(symbol: String, tooltip: String, tint: NSColor, width: CGFloat, action: @escaping () -> Void) {
        self.baseTint = tint
        self.handler = action
        super.init(frame: .zero)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        self.image = image
        self.target = self
        self.action = #selector(tapped)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        updateVisuals()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tapped() {
        handler()
    }

    override func updateVisuals() {
        contentTintColor = baseTint
        alphaValue = isActionAvailable ? 1 : 0.32
        layer?.backgroundColor = (isHovering && isActionAvailable)
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
    }
}

private final class ColorSwatchButton: HoverButton {
    let annotationColor: AnnotationColor
    var isChosen = false {
        didSet {
            guard oldValue != isChosen else { return }
            needsDisplay = true
        }
    }

    init(color: AnnotationColor) {
        self.annotationColor = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        toolTip = color.hex
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let fillRect = bounds.insetBy(dx: 4, dy: 4)
        annotationColor.nsColor.setFill()
        NSBezierPath(ovalIn: fillRect).fill()

        if annotationColor == .white || annotationColor == .charcoal {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let subtle = NSBezierPath(ovalIn: fillRect.insetBy(dx: 0.5, dy: 0.5))
            subtle.lineWidth = 0.8
            subtle.stroke()
        }

        if isChosen {
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.6
            ring.stroke()
        } else if isHovering {
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.2
            ring.stroke()
        }
    }
}

private final class SizeDotButton: HoverButton {
    let preset: StrokePreset
    var isChosen = false {
        didSet {
            guard oldValue != isChosen else { return }
            needsDisplay = true
        }
    }

    init(preset: StrokePreset) {
        self.preset = preset
        super.init(frame: .zero)
        title = ""
        isBordered = false
        toolTip = "Size \(preset.label)"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen || isHovering {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            (isChosen ? NSColor.white.withAlphaComponent(0.22) : NSColor.white.withAlphaComponent(0.11)).setFill()
            bg.fill()
        }

        let diameter: CGFloat = switch preset {
        case .small: 6
        case .medium: 9.5
        case .large: 13
        }
        let dotRect = CGRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        (isChosen ? NSColor.white : NSColor.white.withAlphaComponent(0.8)).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

private final class ModePillButton: HoverButton {
    let mosaicMode: MosaicMode
    var isChosen = false {
        didSet {
            guard oldValue != isChosen else { return }
            updateVisuals()
        }
    }

    init(mode: MosaicMode) {
        self.mosaicMode = mode
        super.init(frame: .zero)
        title = mode.label
        font = .systemFont(ofSize: 11.5, weight: .semibold)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        updateVisuals()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateVisuals() {
        let color: NSColor = isChosen ? .white : NSColor.white.withAlphaComponent(0.75)
        attributedTitle = NSAttributedString(
            string: mosaicMode.label,
            attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: color]
        )
        if isChosen {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.88).cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
