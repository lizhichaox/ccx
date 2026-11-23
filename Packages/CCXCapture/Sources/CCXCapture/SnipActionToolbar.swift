import AppKit
import CCXAnnotate

/// Action commands triggered from the floating snip toolbar.
enum SnipToolbarAction: Sendable {
    case undo, redo, scroll, ocr, pin, copy, save, cancel
}

/// Two-tier Liquid Glass floating toolbar for selecting annotation tools, styles,
/// undo/redo history, and final capture actions.
@MainActor
final class SnipActionToolbar: NSView {
    static let primaryHeight: CGFloat = 40
    static let styleBarHeight: CGFloat = 34
    static let barGap: CGFloat = 6
    static let toolbarWidth: CGFloat = 568
    static let preferredSize = CGSize(width: toolbarWidth, height: primaryHeight)
    static let expandedSize = CGSize(width: toolbarWidth, height: primaryHeight + barGap + styleBarHeight)

    var onAction: ((SnipToolbarAction) -> Void)?
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onStyleChanged: ((AnnotationStyle) -> Void)?
    var onSizeChanged: ((StrokeSize) -> Void)?
    var onSizeEditingStateChanged: ((Bool) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragStateChanged: ((Bool, CGPoint) -> Void)?
    var onResetPosition: (() -> Void)?

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
    private(set) var isStyleBarVisible = false
    private(set) var isDragging = false
    private var dragDidMove = false
    private var dragStartInSuperview: CGPoint = .zero
    private var dragInitialTopLeft: CGPoint = .zero
    private var lastRenderedState: RenderedState?

    private let primarySurface: NSView
    private let styleSurface: NSView

    private var dragHandle: ToolbarDragHandleView!
    var dragHandleView: NSView { dragHandle }
    private var toolButtons: [AnnotationTool: ToolToggleButton] = [:]
    private var undoButton: ToolbarIconButton!
    private var redoButton: ToolbarIconButton!

    private let colorsStack = NSStackView()
    private let mosaicModeStack = NSStackView()
    private var colorButtons: [AnnotationColor: ColorSwatchButton] = [:]
    private var mosaicModeButtons: [MosaicMode: ModePillButton] = [:]
    private let sizeSlider = StrokeSizeSlider()
    var sizeSliderView: NSView { sizeSlider }

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

    override func mouseDown(with event: NSEvent) {
        beginDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        endDrag(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard hitsInteractiveArea(local) else { return nil }
        let hit = super.hitTest(point)
        if hit === dragHandle {
            return dragHandle
        }
        if hit === sizeSlider || hit?.isDescendant(of: sizeSlider) == true {
            return sizeSlider
        }
        if let button = hit as? NSButton, button.isEnabled {
            return button
        }
        return self
    }

    /// Whether a point in toolbar-local coordinates falls on either visible pill surface.
    func hitsInteractiveArea(_ localPoint: CGPoint) -> Bool {
        if primarySurface.frame.contains(localPoint) { return true }
        if !styleSurface.isHidden, styleSurface.frame.contains(localPoint) { return true }
        return false
    }

    /// Whether a point in toolbar-local coordinates hits the drag grip or pill background
    /// rather than an enabled control button.
    func hitsDragRegion(_ localPoint: CGPoint) -> Bool {
        guard !isHidden, hitsInteractiveArea(localPoint) else { return false }
        let pointInSuperview = superview.map { convert(localPoint, to: $0) }
            ?? CGPoint(x: frame.minX + localPoint.x, y: frame.minY + localPoint.y)
        let hit = hitTest(pointInSuperview)
        return hit === self || hit === dragHandle
    }

    private func superviewPoint(for event: NSEvent) -> CGPoint {
        superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    }

    private func beginDrag(with event: NSEvent) {
        if event.clickCount >= 2 {
            isDragging = false
            dragDidMove = false
            dragHandle.isDragging = false
            onResetPosition?()
            return
        }
        let point = superviewPoint(for: event)
        isDragging = true
        dragDidMove = false
        dragStartInSuperview = point
        dragInitialTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
        dragHandle.isDragging = true
        onDragStateChanged?(true, point)
    }

    private func continueDrag(with event: NSEvent) {
        guard isDragging else { return }
        let point = superviewPoint(for: event)
        let dx = point.x - dragStartInSuperview.x
        let dy = point.y - dragStartInSuperview.y
        if !dragDidMove {
            guard hypot(dx, dy) >= 1 else { return }
            dragDidMove = true
        }
        onDragMoved?(CGPoint(x: dragInitialTopLeft.x + dx, y: dragInitialTopLeft.y + dy))
    }

    private func endDrag(with event: NSEvent) {
        guard isDragging else { return }
        let point = superviewPoint(for: event)
        isDragging = false
        dragDidMove = false
        dragHandle.isDragging = false
        onDragStateChanged?(false, point)
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
            sizeSlider.size = style.size
            sizeSlider.previewColor = effectiveStyleTool.usesColor ? style.color : nil
        }
    }

    // MARK: - Setup

    private func setUpPrimaryBar(in container: NSView) {
        var views: [NSView] = []

        let handle = ToolbarDragHandleView()
        handle.onMouseDown = { [weak self] event in self?.beginDrag(with: event) }
        handle.onMouseDragged = { [weak self] event in self?.continueDrag(with: event) }
        handle.onMouseUp = { [weak self] event in self?.endDrag(with: event) }
        dragHandle = handle
        views.append(handle)

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

        views.append(ToolbarIconButton(
            symbol: "rectangle.expand.vertical",
            fallbackSymbol: "arrow.up.arrow.down",
            tooltip: "Scroll Capture (L)",
            tint: .systemMint,
            width: 30
        ) { [weak self] in
            self?.onAction?(.scroll)
        })
        views.append(ToolbarIconButton(symbol: "text.viewfinder", tooltip: "Copy Text (OCR) (T)", tint: .systemCyan, width: 30) { [weak self] in
            self?.onAction?(.ocr)
        })
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
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8)
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

        sizeSlider.onSizeChanged = { [weak self] newSize in
            self?.onSizeChanged?(newSize)
        }
        sizeSlider.onEditingStateChanged = { [weak self] editing in
            self?.onSizeEditingStateChanged?(editing)
        }

        let stack = NSStackView(views: [
            colorsStack,
            mosaicModeStack,
            Self.makeDivider(),
            sizeSlider,
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

    // MARK: - Placement & Chrome Helpers

    /// Anchors the toolbar centered horizontally below the selection, else above, else inside; clamped to `bounds`.
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
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, usableMaxY - size.height)
        var origin = CGPoint(
            x: (selection.midX - size.width / 2).rounded(),
            y: selection.minY - gap - size.height
        )
        if origin.y < bounds.minY {
            origin.y = selection.maxY + gap
            if origin.y + size.height > usableMaxY {
                origin.y = selection.minY + gap
            }
        }
        origin.x = min(max(origin.x, bounds.minX), maxX)
        origin.y = min(max(origin.y, bounds.minY), maxY)
        return CGRect(origin: origin, size: size)
    }

    /// Clamps a user-positioned toolbar anchored by its top-left corner (`minX`, `maxY`) so
    /// expanding/collapsing the lower style bar keeps the primary bar visually stationary.
    static func clampedFrame(
        anchoredAtTopLeft topLeft: CGPoint,
        size: CGSize,
        in bounds: CGRect,
        topInset: CGFloat
    ) -> CGRect {
        let usableMaxY = bounds.maxY - topInset
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, usableMaxY - size.height)
        let x = min(max(topLeft.x, bounds.minX), maxX)
        let y = min(max(topLeft.y - size.height, bounds.minY), maxY)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
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

    init(
        symbol: String,
        fallbackSymbol: String? = nil,
        tooltip: String,
        tint: NSColor,
        width: CGFloat,
        action: @escaping () -> Void
    ) {
        self.baseTint = tint
        self.handler = action
        super.init(frame: .zero)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? fallbackSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: tooltip) }
            ?? NSImage()
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

private final class StrokeSizeSlider: NSView {
    private static let trackMinX: CGFloat = 8
    private static let trackMaxX: CGFloat = 92
    private static let previewCenterX: CGFloat = 107

    var onSizeChanged: ((StrokeSize) -> Void)?
    var onEditingStateChanged: ((Bool) -> Void)?

    var size: StrokeSize = .medium {
        didSet {
            guard oldValue != size else { return }
            updateTooltip()
            needsDisplay = true
        }
    }

    var previewColor: AnnotationColor? {
        didSet {
            guard oldValue != previewColor else { return }
            needsDisplay = true
        }
    }

    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            needsDisplay = true
        }
    }

    private var isDragging = false {
        didSet {
            guard oldValue != isDragging else { return }
            needsDisplay = true
        }
    }

    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 118),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        updateTooltip()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        onEditingStateChanged?(true)
        let nextSize = StrokeSize(progress: progress(for: event))
        size = nextSize
        onSizeChanged?(nextSize)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let nextSize = StrokeSize(progress: progress(for: event))
        if nextSize != size {
            size = nextSize
            onSizeChanged?(nextSize)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onEditingStateChanged?(false)
    }

    private func progress(for event: NSEvent) -> CGFloat {
        let local = convert(event.locationInWindow, from: nil)
        let span = Self.trackMaxX - Self.trackMinX
        guard span > 0 else { return 0.41 }
        return min(max((local.x - Self.trackMinX) / span, 0), 1)
    }

    private func updateTooltip() {
        toolTip = "Stroke Size: \(size.formattedLineWidth) pt (drag or scroll up/down)"
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        let leftX = Self.trackMinX
        let rightX = Self.trackMaxX
        let leftRadius: CGFloat = 1.5
        let rightRadius: CGFloat = 3.2
        let knobX = leftX + (rightX - leftX) * size.progress

        // Tapered capsule track communicating thinner -> thicker left-to-right.
        let trackPath = NSBezierPath()
        trackPath.appendArc(
            withCenter: CGPoint(x: leftX, y: midY),
            radius: leftRadius,
            startAngle: 90,
            endAngle: 270
        )
        trackPath.appendArc(
            withCenter: CGPoint(x: rightX, y: midY),
            radius: rightRadius,
            startAngle: -90,
            endAngle: 90
        )
        trackPath.close()

        NSColor.white.withAlphaComponent(isHovering || isDragging ? 0.28 : 0.22).setFill()
        trackPath.fill()

        if size.progress > 0, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            trackPath.addClip()
            NSColor.white.withAlphaComponent(0.78).setFill()
            CGRect(x: 0, y: 0, width: knobX, height: bounds.height).fill()
            context.restoreGState()
        }

        // Draggable white circular knob.
        let knobDiameter: CGFloat = isDragging ? 13 : 12
        let knobRect = CGRect(
            x: knobX - knobDiameter / 2,
            y: midY - knobDiameter / 2,
            width: knobDiameter,
            height: knobDiameter
        )
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -0.5),
                blur: 2,
                color: CGColor(gray: 0, alpha: 0.4)
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect).fill()
            context.restoreGState()
        } else {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect).fill()
        }
        NSColor.black.withAlphaComponent(0.22).setStroke()
        let knobBorder = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.4, dy: 0.4))
        knobBorder.lineWidth = 0.8
        knobBorder.stroke()

        // Live thickness preview dot scaling from 4pt to 14pt.
        let dotDiameter = 4 + 10 * size.progress
        let dotRect = CGRect(
            x: Self.previewCenterX - dotDiameter / 2,
            y: midY - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        let dotColor = previewColor?.nsColor ?? .white
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        if previewColor == nil || previewColor == .white || previewColor == .charcoal {
            let borderColor: NSColor = previewColor == .charcoal
                ? NSColor.white.withAlphaComponent(0.4)
                : NSColor.black.withAlphaComponent(0.22)
            borderColor.setStroke()
            let dotStroke = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.4, dy: 0.4))
            dotStroke.lineWidth = 0.8
            dotStroke.stroke()
        }
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

private final class ToolbarDragHandleView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            needsDisplay = true
        }
    }

    var isDragging = false {
        didSet {
            guard oldValue != isDragging else { return }
            needsDisplay = true
        }
    }

    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = "Drag to move toolbar (double-click to reset)"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDragging || isHovering {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6)
            let alpha: CGFloat = isDragging ? 0.18 : 0.12
            NSColor.white.withAlphaComponent(alpha).setFill()
            bg.fill()
        }

        let dotAlpha: CGFloat = isDragging ? 0.95 : (isHovering ? 0.75 : 0.38)
        NSColor.white.withAlphaComponent(dotAlpha).setFill()

        let dotDiameter: CGFloat = 2.4
        let radius = dotDiameter / 2
        let horizontalSpacing: CGFloat = 4.4
        let verticalSpacing: CGFloat = 4.8

        for col in 0..<2 {
            let cx = bounds.midX + (CGFloat(col) - 0.5) * horizontalSpacing
            for row in 0..<3 {
                let cy = bounds.midY + (CGFloat(row) - 1) * verticalSpacing
                let dotRect = CGRect(x: cx - radius, y: cy - radius, width: dotDiameter, height: dotDiameter)
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }
}
