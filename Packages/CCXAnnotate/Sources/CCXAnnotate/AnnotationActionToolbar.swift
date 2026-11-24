import AppKit
import CCXCore

/// Action commands triggered from the floating annotation toolbar.
public enum AnnotationToolbarAction: Sendable {
    case undo, redo, scroll, record, ocr, pin, done, copy, save, cancel
}

/// Visual/action layout preset for `AnnotationActionToolbar`.
public enum AnnotationToolbarPreset: Sendable {
    case snip
    case pin
}

/// Two-tier Liquid Glass floating toolbar for selecting annotation tools, styles,
/// undo/redo history, and final capture/pin actions.
@MainActor
public final class AnnotationActionToolbar: NSView {
    public static let primaryHeight: CGFloat = 40
    public static let styleBarHeight: CGFloat = 34
    public static let barGap: CGFloat = 6
    public static let snipToolbarWidth: CGFloat = 600
    public static let pinToolbarWidth: CGFloat = 536
    public static let toolbarWidth: CGFloat = snipToolbarWidth
    public static let preferredSize = CGSize(width: snipToolbarWidth, height: primaryHeight)
    public static let expandedSize = CGSize(width: snipToolbarWidth, height: primaryHeight + barGap + styleBarHeight)

    public static func preferredSize(for preset: AnnotationToolbarPreset) -> CGSize {
        let width = preset == .snip ? snipToolbarWidth : pinToolbarWidth
        return CGSize(width: width, height: primaryHeight)
    }

    public static func expandedSize(for preset: AnnotationToolbarPreset) -> CGSize {
        let width = preset == .snip ? snipToolbarWidth : pinToolbarWidth
        return CGSize(width: width, height: primaryHeight + barGap + styleBarHeight)
    }

    public let preset: AnnotationToolbarPreset
    /// Enable when the toolbar owns its own floating panel and drags should track screen coordinates.
    public var useScreenCoordinatesForDrag = false

    public var onAction: ((AnnotationToolbarAction) -> Void)?
    public var onToolSelected: ((AnnotationTool) -> Void)?
    public var onStyleChanged: ((AnnotationStyle) -> Void)?
    public var onSizeChanged: ((StrokeSize) -> Void)?
    public var onSizeEditingStateChanged: ((Bool) -> Void)?
    public var onDragMoved: ((CGPoint) -> Void)?
    public var onDragStateChanged: ((Bool, CGPoint) -> Void)?
    public var onResetPosition: (() -> Void)?

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
    public private(set) var isStyleBarVisible = false
    public private(set) var isDragging = false
    private var dragDidMove = false
    private var dragStartPoint: CGPoint = .zero
    private var dragInitialTopLeft: CGPoint = .zero
    private var lastRenderedState: RenderedState?

    private let primarySurface: NSView
    private let styleSurface: NSView
    internal let primaryStack = NSStackView()

    private let dragHandle = ToolbarDragHandleView()
    public var dragHandleView: NSView { dragHandle }
    private var toolButtons: [AnnotationTool: ToolToggleButton] = [:]
    private let undoButton: ToolbarIconButton
    private let redoButton: ToolbarIconButton

    private let colorsStack = NSStackView()
    private let mosaicModeStack = NSStackView()
    private var colorButtons: [AnnotationColor: ColorSwatchButton] = [:]
    private var mosaicModeButtons: [MosaicMode: ModePillButton] = [:]
    private let sizeSlider = StrokeSizeSlider()
    public var sizeSliderView: NSView { sizeSlider }
    internal var sizeSliderToolTip: String? { sizeSlider.toolTip }

    public var primarySurfaceBounds: CGRect { primarySurface.bounds }
    public var primaryControlFrames: [CGRect] {
        primaryStack.arrangedSubviews
            .filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: primarySurface) }
    }

    public init(frame frameRect: NSRect = .zero, preset: AnnotationToolbarPreset = .snip) {
        self.preset = preset
        let resolvedFrame = frameRect == .zero
            ? CGRect(origin: .zero, size: Self.preferredSize(for: preset))
            : frameRect
        let primaryContent = NSView(frame: .zero)
        let styleContent = NSView(frame: .zero)
        let blendingMode: NSVisualEffectView.BlendingMode = preset == .pin ? .behindWindow : .withinWindow
        self.primarySurface = Self.makeGlassSurface(
            contentView: primaryContent,
            cornerRadius: 12,
            blendingMode: blendingMode
        )
        self.styleSurface = Self.makeGlassSurface(
            contentView: styleContent,
            cornerRadius: 10,
            blendingMode: blendingMode
        )
        self.undoButton = ToolbarIconButton(
            symbol: "arrow.uturn.backward",
            tooltip: CCXL10n.text("Undo (⌘Z)", zh: "撤销 (⌘Z)"),
            tint: .white,
            width: 28
        )
        self.redoButton = ToolbarIconButton(
            symbol: "arrow.uturn.forward",
            tooltip: CCXL10n.text("Redo (⇧⌘Z)", zh: "重做 (⇧⌘Z)"),
            tint: .white,
            width: 28
        )
        super.init(frame: resolvedFrame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        setUpPrimaryBar(in: primaryContent)
        setUpStyleBar(in: styleContent)

        primarySurface.translatesAutoresizingMaskIntoConstraints = false
        styleSurface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(primarySurface)
        addSubview(styleSurface)

        let width = Self.preferredSize(for: preset).width
        NSLayoutConstraint.activate([
            primarySurface.topAnchor.constraint(equalTo: topAnchor),
            primarySurface.centerXAnchor.constraint(equalTo: centerXAnchor),
            primarySurface.widthAnchor.constraint(equalToConstant: width),
            primarySurface.heightAnchor.constraint(equalToConstant: Self.primaryHeight),

            styleSurface.topAnchor.constraint(equalTo: primarySurface.bottomAnchor, constant: Self.barGap),
            styleSurface.centerXAnchor.constraint(equalTo: centerXAnchor),
            styleSurface.heightAnchor.constraint(equalToConstant: Self.styleBarHeight),
        ])

        update(activeTool: .select, style: AnnotationStyle(), showStyleBar: false, canUndo: false, canRedo: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func mouseDown(with event: NSEvent) {
        beginDrag(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        continueDrag(with: event)
    }

    override public func mouseUp(with event: NSEvent) {
        endDrag(with: event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        if isDragging || sizeSlider.isDragging {
            cancelDragging()
            return
        }
        super.rightMouseDown(with: event)
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelDragging()
        }
    }

    override public func viewDidHide() {
        super.viewDidHide()
        cancelDragging()
    }

    /// Cancels any in-flight toolbar drag or stroke-size slider drag cleanly.
    public func cancelDragging() {
        if isDragging {
            isDragging = false
            dragDidMove = false
            dragHandle.isDragging = false
            onDragStateChanged?(false, dragStartPoint)
        }
        sizeSlider.cancelDragging()
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
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
    public func hitsInteractiveArea(_ localPoint: CGPoint) -> Bool {
        if primarySurface.frame.contains(localPoint) { return true }
        if !styleSurface.isHidden, styleSurface.frame.contains(localPoint) { return true }
        return false
    }

    /// Whether a point in toolbar-local coordinates hits the drag grip or pill background
    /// rather than an enabled control button.
    public func hitsDragRegion(_ localPoint: CGPoint) -> Bool {
        guard !isHidden, hitsInteractiveArea(localPoint) else { return false }
        let pointInSuperview = superview.map { convert(localPoint, to: $0) }
            ?? CGPoint(x: frame.minX + localPoint.x, y: frame.minY + localPoint.y)
        let hit = hitTest(pointInSuperview)
        return hit === self || hit === dragHandle
    }

    private func dragCoordinatePoint(for event: NSEvent) -> CGPoint {
        if useScreenCoordinatesForDrag {
            return NSEvent.mouseLocation
        }
        return superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    }

    private func beginDrag(with event: NSEvent) {
        if event.clickCount >= 2 {
            isDragging = false
            dragDidMove = false
            dragHandle.isDragging = false
            onResetPosition?()
            return
        }
        let point = dragCoordinatePoint(for: event)
        isDragging = true
        dragDidMove = false
        dragStartPoint = point
        if useScreenCoordinatesForDrag {
            dragInitialTopLeft = window.map { CGPoint(x: $0.frame.minX, y: $0.frame.maxY) } ?? .zero
        } else {
            dragInitialTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
        }
        dragHandle.isDragging = true
        onDragStateChanged?(true, point)
    }

    private func continueDrag(with event: NSEvent) {
        guard isDragging else { return }
        let point = dragCoordinatePoint(for: event)
        let dx = point.x - dragStartPoint.x
        let dy = point.y - dragStartPoint.y
        if !dragDidMove {
            guard hypot(dx, dy) >= 1 else { return }
            dragDidMove = true
        }
        onDragMoved?(CGPoint(x: dragInitialTopLeft.x + dx, y: dragInitialTopLeft.y + dy))
    }

    private func endDrag(with event: NSEvent) {
        guard isDragging else { return }
        let point = dragCoordinatePoint(for: event)
        isDragging = false
        dragDidMove = false
        dragHandle.isDragging = false
        onDragStateChanged?(false, point)
    }

    public func update(
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
            sizeSlider.update(
                size: style.size,
                tool: effectiveStyleTool,
                mosaicMode: style.mosaicMode,
                previewColor: effectiveStyleTool.usesColor ? style.color : nil
            )
        }
    }

    // MARK: - Setup

    private func setUpPrimaryBar(in container: NSView) {
        var views: [NSView] = []

        dragHandle.onMouseDown = { [weak self] event in self?.beginDrag(with: event) }
        dragHandle.onMouseDragged = { [weak self] event in self?.continueDrag(with: event) }
        dragHandle.onMouseUp = { [weak self] event in self?.endDrag(with: event) }
        views.append(dragHandle)

        for tool in AnnotationTool.drawingTools {
            let tip = tool.shortcutHint.map { "\(tool.displayName) (\($0))" } ?? tool.displayName
            let button = ToolToggleButton(tool: tool, symbol: tool.symbolName, tooltip: tip)
            button.target = self
            button.action = #selector(toolPressed(_:))
            toolButtons[tool] = button
            views.append(button)
        }

        views.append(Self.makeDivider())

        undoButton.onTap = { [weak self] in self?.onAction?(.undo) }
        redoButton.onTap = { [weak self] in self?.onAction?(.redo) }
        views.append(undoButton)
        views.append(redoButton)

        views.append(Self.makeDivider())

        switch preset {
        case .snip:
            views.append(ToolbarIconButton(
                symbol: "arrow.up.and.down.square",
                fallbackSymbol: "arrow.up.arrow.down",
                tooltip: CCXL10n.text("Scroll Capture (L)", zh: "滚动截屏 (L)"),
                tint: .systemMint,
                width: 30
            ) { [weak self] in
                self?.onAction?(.scroll)
            })
            views.append(ToolbarIconButton(
                symbol: "record.circle",
                tooltip: CCXL10n.text("Record Area (R)", zh: "录制区域 (R)"),
                tint: .systemRed,
                width: 30
            ) { [weak self] in
                self?.onAction?(.record)
            })
            views.append(ToolbarIconButton(symbol: "text.viewfinder", tooltip: CCXL10n.text("Copy Text (OCR) (T)", zh: "识别文字 (OCR) (T)"), tint: .systemCyan, width: 30) { [weak self] in
                self?.onAction?(.ocr)
            })
            views.append(ToolbarIconButton(symbol: "pin", tooltip: CCXL10n.text("Pin (Return)", zh: "贴图 (Return)"), tint: .systemGreen, width: 32) { [weak self] in
                self?.onAction?(.pin)
            })
            views.append(ToolbarIconButton(symbol: "square.and.arrow.down", tooltip: CCXL10n.text("Save (⌘S)", zh: "保存 (⌘S)"), tint: .white, width: 32) { [weak self] in
                self?.onAction?(.save)
            })
            views.append(ToolbarIconButton(symbol: "doc.on.doc", tooltip: CCXL10n.text("Copy (⌘C)", zh: "拷贝 (⌘C)"), tint: .white, width: 32) { [weak self] in
                self?.onAction?(.copy)
            })
            views.append(ToolbarIconButton(symbol: "xmark", tooltip: CCXL10n.text("Cancel (Esc)", zh: "取消 (Esc)"), tint: .systemRed, width: 32) { [weak self] in
                self?.onAction?(.cancel)
            })

        case .pin:
            views.append(ToolbarIconButton(symbol: "text.viewfinder", tooltip: CCXL10n.text("Copy Text (OCR) (T)", zh: "识别文字 (OCR) (T)"), tint: .systemCyan, width: 30) { [weak self] in
                self?.onAction?(.ocr)
            })
            views.append(ToolbarIconButton(symbol: "square.and.arrow.down", tooltip: CCXL10n.text("Save PNG (⌘S)", zh: "保存 PNG (⌘S)"), tint: .white, width: 32) { [weak self] in
                self?.onAction?(.save)
            })
            views.append(ToolbarIconButton(symbol: "doc.on.doc", tooltip: CCXL10n.text("Copy (⌘C)", zh: "拷贝 (⌘C)"), tint: .white, width: 32) { [weak self] in
                self?.onAction?(.copy)
            })
            views.append(ToolbarIconButton(symbol: "checkmark", tooltip: CCXL10n.text("Done (Return)", zh: "完成 (Return)"), tint: .systemGreen, width: 32) { [weak self] in
                self?.onAction?(.done)
            })
            views.append(ToolbarIconButton(symbol: "xmark", tooltip: CCXL10n.text("Cancel Edits (Esc)", zh: "取消编辑 (Esc)"), tint: .systemRed, width: 32) { [weak self] in
                self?.onAction?(.cancel)
            })
        }

        for view in views {
            primaryStack.addArrangedSubview(view)
        }
        primaryStack.orientation = .horizontal
        primaryStack.alignment = .centerY
        primaryStack.spacing = 2
        primaryStack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8)
        primaryStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(primaryStack)
        NSLayoutConstraint.activate([
            primaryStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            primaryStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            primaryStack.topAnchor.constraint(equalTo: container.topAnchor),
            primaryStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
    public static func frame(for selection: CGRect, in bounds: CGRect, topInset: CGFloat) -> CGRect {
        frame(for: selection, in: bounds, topInset: topInset, showsStyleBar: false, preset: .snip)
    }

    public static func frame(
        for selection: CGRect,
        in bounds: CGRect,
        topInset: CGFloat,
        showsStyleBar: Bool,
        preset: AnnotationToolbarPreset = .snip
    ) -> CGRect {
        let size = showsStyleBar ? expandedSize(for: preset) : preferredSize(for: preset)
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
    public static func clampedFrame(
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

    private static func makeGlassSurface(
        contentView: NSView,
        cornerRadius: CGFloat,
        blendingMode: NSVisualEffectView.BlendingMode
    ) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = contentView
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = blendingMode
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
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
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let rawImage = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        self.image = rawImage?.withSymbolConfiguration(config) ?? rawImage ?? NSImage()
        self.imageScaling = .scaleNone
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
    var onTap: (() -> Void)?
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
        action: (() -> Void)? = nil
    ) {
        self.baseTint = tint
        self.onTap = action
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let rawImage = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? fallbackSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: tooltip) }
        self.image = rawImage?.withSymbolConfiguration(config) ?? rawImage ?? NSImage()
        self.imageScaling = .scaleNone
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
        onTap?()
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
        setAccessibilityLabel(CCXL10n.text("Annotation Color \(color.hex)", zh: "标注颜色 \(color.hex)"))
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

    private var activeTool: AnnotationTool = .pen
    private var mosaicMode: MosaicMode = .pixelate

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

    private(set) var isDragging = false {
        didSet {
            guard oldValue != isDragging else { return }
            needsDisplay = true
        }
    }

    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.slider)
        setAccessibilityLabel(CCXL10n.text("Annotation Size", zh: "标注粗细"))
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 118),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        updateTooltip()
    }

    func update(size: StrokeSize, tool: AnnotationTool, mosaicMode: MosaicMode, previewColor: AnnotationColor?) {
        let metaChanged = self.activeTool != tool || self.mosaicMode != mosaicMode
        self.activeTool = tool
        self.mosaicMode = mosaicMode
        self.size = size
        self.previewColor = previewColor
        if metaChanged {
            updateTooltip()
        }
    }

    func cancelDragging() {
        guard isDragging else { return }
        isDragging = false
        onEditingStateChanged?(false)
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

    override func rightMouseDown(with event: NSEvent) {
        if isDragging {
            cancelDragging()
            return
        }
        super.rightMouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelDragging()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelDragging()
    }

    private func progress(for event: NSEvent) -> CGFloat {
        let local = convert(event.locationInWindow, from: nil)
        let span = Self.trackMaxX - Self.trackMinX
        guard span > 0 else { return 0.41 }
        return min(max((local.x - Self.trackMinX) / span, 0), 1)
    }

    private func updateTooltip() {
        let label = activeTool.formattedSizeHUDLabel(for: size, mosaicMode: mosaicMode)
        toolTip = CCXL10n.text("\(label) (drag or scroll up/down)", zh: "\(label)（拖动或上下滚动调整）")
        setAccessibilityValue(label)
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        let leftX = Self.trackMinX
        let rightX = Self.trackMaxX
        let leftRadius: CGFloat = 1.5
        let rightRadius: CGFloat = 3.2
        let knobX = leftX + (rightX - leftX) * size.progress

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
        toolTip = CCXL10n.text("Drag to move toolbar (double-click to reset)", zh: "拖动移动工具栏（双击重置位置）")
        setAccessibilityLabel(CCXL10n.text("Move Annotation Toolbar", zh: "移动标注工具栏"))
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
