import AppKit
import CCXCore

/// Always-on-top, non-activating floating window showing one pinned image, text, or color.
///
/// Interactions: drag to move, scroll to zoom (0.1x-10x, around the cursor),
/// Ctrl+scroll to change opacity, double-click to toggle a 72x72 thumbnail,
/// Esc to close, Cmd+C to copy, Cmd+S to save, right-click for the context menu.
public final class PinPanel: NSPanel {
    public let content: PinContent
    public private(set) var state: PinState
    /// Unrotated, unzoomed content size in points.
    public let baseSize: CGSize

    var onClose: ((PinPanel) -> Void)?
    var onCopy: ((PinPanel) -> Void)?
    var onSave: ((PinPanel) -> Void)?
    var onRecognizeText: ((PinPanel) -> Void)?
    var onHideAll: (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onStateChanged: ((PinPanel) -> Void)?

    private let pinView: PinContentView
    private var didClose = false

    /// - Parameters:
    ///   - frame: Initial window frame in AppKit global coordinates.
    public init(content: PinContent, frame: CGRect, state: PinState = PinState()) {
        self.content = content
        self.state = state
        self.baseSize = PinLayout.baseSize(for: content)
        self.pinView = PinContentView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        title = "CCX Pin"

        pinView.panel = self
        pinView.autoresizingMask = [.width, .height]
        contentView = pinView
        applyState(from: nil, resizeKeeping: nil)
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    // MARK: - State

    /// Replaces the whole state, resizing around `anchor` (screen point; defaults to the
    /// frame's top-left corner).
    public func updateState(_ newState: PinState, anchor: CGPoint? = nil) {
        guard newState != state else { return }
        let previous = state
        state = newState
        applyState(from: previous, resizeKeeping: anchor ?? CGPoint(x: frame.minX, y: frame.maxY))
    }

    private func mutateState(anchor: CGPoint? = nil, _ change: (inout PinState) -> Void) {
        var newState = state
        change(&newState)
        updateState(newState, anchor: anchor)
    }

    private func applyState(from previous: PinState?, resizeKeeping anchor: CGPoint?) {
        alphaValue = state.opacity
        hasShadow = state.showsShadow
        ignoresMouseEvents = state.isClickThrough

        if let anchor {
            let size = PinLayout.frameSize(baseSize: baseSize, state: state)
            if size != frame.size {
                setFrame(PinLayout.resizedFrame(frame, to: size, keeping: anchor), display: true)
            }
        }

        let needsContentRedraw = previous == nil
            || previous?.isThumbnail != state.isThumbnail
            || previous?.showsBorder != state.showsBorder
            || previous?.isClickThrough != state.isClickThrough
            || previous?.rotationDegrees != state.rotationDegrees
            || previous?.isFlippedHorizontally != state.isFlippedHorizontally
            || previous?.isFlippedVertically != state.isFlippedVertically
            || previous?.zoom != state.zoom
        if needsContentRedraw {
            pinView.needsDisplay = true
        }

        let needsShadowInvalidation = previous == nil
            || previous?.showsShadow != state.showsShadow
            || previous?.isThumbnail != state.isThumbnail
            || previous?.isQuarterTurned != state.isQuarterTurned
        if needsShadowInvalidation {
            invalidateShadow()
        }

        if let previous {
            if state.isThumbnail {
                pinView.hideHUD()
            } else if abs(previous.zoom - state.zoom) > 0.0001 {
                pinView.showHUD("\(Int((state.zoom * 100).rounded()))%")
            } else if abs(previous.opacity - state.opacity) > 0.0001 {
                pinView.showHUD("Opacity \(Int((state.opacity * 100).rounded()))%")
            }
        }

        if previous?.isClickThrough != state.isClickThrough {
            onStateChanged?(self)
        }
    }

    var frameCenter: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    var frameTopLeft: CGPoint { CGPoint(x: frame.minX, y: frame.maxY) }

    public func setZoom(_ zoom: CGFloat, around anchor: CGPoint? = nil) {
        mutateState(anchor: anchor ?? frameCenter) { $0.setZoom(zoom) }
    }

    public func setOpacity(_ opacity: CGFloat) {
        mutateState { $0.setOpacity(opacity) }
    }

    public func rotateClockwise() {
        mutateState(anchor: frameCenter) { $0.rotateClockwise() }
    }

    public func rotateCounterClockwise() {
        mutateState(anchor: frameCenter) { $0.rotateCounterClockwise() }
    }

    public func toggleFlipHorizontal() {
        mutateState(anchor: frameCenter) { $0.toggleFlipHorizontal() }
    }

    public func toggleFlipVertical() {
        mutateState(anchor: frameCenter) { $0.toggleFlipVertical() }
    }

    public func setShowsBorder(_ shows: Bool) {
        mutateState { $0.showsBorder = shows }
    }

    public func setShowsShadow(_ shows: Bool) {
        mutateState { $0.showsShadow = shows }
    }

    public func setClickThrough(_ enabled: Bool) {
        mutateState { $0.isClickThrough = enabled }
    }

    /// Collapses to / restores from the 72x72 thumbnail, keeping the top-left corner fixed.
    public func toggleThumbnail() {
        mutateState(anchor: frameTopLeft) { $0.toggleThumbnail() }
    }

    // MARK: - Events

    override public func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.modifierFlags.contains(.control) {
            let step = event.hasPreciseScrollingDeltas ? delta * 0.005 : (delta > 0 ? 0.05 : -0.05)
            mutateState { $0.adjustOpacity(by: step) }
        } else if !state.isThumbnail {
            let factor = event.hasPreciseScrollingDeltas ? exp(delta * 0.01) : (delta > 0 ? 1.1 : 1 / 1.1)
            mutateState(anchor: NSEvent.mouseLocation) { $0.multiplyZoom(by: factor) }
        }
    }

    override public func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
            return
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
            switch char {
            case "r":
                if flags.contains(.shift) { rotateCounterClockwise() } else { rotateClockwise() }
                return
            case "h":
                toggleFlipHorizontal()
                return
            case "v":
                toggleFlipVertical()
                return
            case "0":
                setZoom(1)
                return
            case "=", "+":
                if !state.isThumbnail { mutateState(anchor: frameCenter) { $0.multiplyZoom(by: 1.1) } }
                return
            case "-":
                if !state.isThumbnail { mutateState(anchor: frameCenter) { $0.multiplyZoom(by: 1 / 1.1) } }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override public func cancelOperation(_ sender: Any?) {
        close()
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c": copyPin(nil); return true
            case "s": savePin(nil); return true
            case "w": close(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override public func close() {
        super.close()
        guard !didClose else { return }
        didClose = true
        onClose?(self)
    }

    // MARK: - Context menu

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Pin")
        menu.autoenablesItems = false
        menu.addItem(menuItem("Copy", #selector(copyPin(_:)), key: "c"))
        if case .image = content {
            menu.addItem(menuItem("Copy Text (OCR)", #selector(recognizeTextFromMenu(_:))))
        }
        menu.addItem(menuItem("Save PNG", #selector(savePin(_:)), key: "s"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Reset Zoom (100%)", #selector(resetZoom(_:))))
        menu.addItem(menuItem("Rotate 90°", #selector(rotate90(_:))))
        let flipH = menuItem("Flip Horizontal", #selector(flipHorizontalFromMenu(_:)))
        flipH.state = state.isFlippedHorizontally ? .on : .off
        menu.addItem(flipH)
        let flipV = menuItem("Flip Vertical", #selector(flipVerticalFromMenu(_:)))
        flipV.state = state.isFlippedVertically ? .on : .off
        menu.addItem(flipV)

        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(title: "Opacity")
        for percent in [100, 80, 60, 40, 20] {
            let item = menuItem("\(percent)%", #selector(setOpacityFromMenu(_:)), tag: percent)
            item.state = abs(state.opacity * 100 - CGFloat(percent)) < 1 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        let clickThrough = menuItem("Toggle Click-Through", #selector(toggleClickThroughFromMenu(_:)))
        clickThrough.state = state.isClickThrough ? .on : .off
        menu.addItem(clickThrough)
        let thumbnail = menuItem("Toggle Thumbnail", #selector(toggleThumbnailFromMenu(_:)))
        thumbnail.state = state.isThumbnail ? .on : .off
        menu.addItem(thumbnail)
        let showBorder = menuItem("Show Border", #selector(toggleBorderFromMenu(_:)))
        showBorder.state = state.showsBorder ? .on : .off
        menu.addItem(showBorder)
        let showShadow = menuItem("Show Shadow", #selector(toggleShadowFromMenu(_:)))
        showShadow.state = state.showsShadow ? .on : .off
        menu.addItem(showShadow)
        menu.addItem(.separator())
        menu.addItem(menuItem("Close Pin", #selector(closePin(_:)), key: "w"))
        menu.addItem(menuItem("Hide All Pins", #selector(hideAllPins(_:))))
        menu.addItem(menuItem("Close All Pins", #selector(closeAllPins(_:))))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        return item
    }

    @objc func copyPin(_ sender: Any?) { onCopy?(self) }
    @objc func recognizeTextFromMenu(_ sender: Any?) { onRecognizeText?(self) }
    @objc func savePin(_ sender: Any?) { onSave?(self) }
    @objc func resetZoom(_ sender: Any?) { setZoom(1) }
    @objc func rotate90(_ sender: Any?) { rotateClockwise() }
    @objc func flipHorizontalFromMenu(_ sender: Any?) { toggleFlipHorizontal() }
    @objc func flipVerticalFromMenu(_ sender: Any?) { toggleFlipVertical() }
    @objc func setOpacityFromMenu(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc func toggleClickThroughFromMenu(_ sender: Any?) { setClickThrough(!state.isClickThrough) }
    @objc func toggleThumbnailFromMenu(_ sender: Any?) { toggleThumbnail() }
    @objc func toggleBorderFromMenu(_ sender: Any?) { setShowsBorder(!state.showsBorder) }
    @objc func toggleShadowFromMenu(_ sender: Any?) { setShowsShadow(!state.showsShadow) }
    @objc func closePin(_ sender: Any?) { close() }
    @objc func hideAllPins(_ sender: Any?) { onHideAll?() }
    @objc func closeAllPins(_ sender: Any?) { onCloseAll?() }

    /// Image used for copy/save/OCR: the original pixels (transformed) or a rendered card.
    public func exportImage() -> CGImage? {
        PinRenderer.exportImage(
            for: content,
            rotationDegrees: state.rotationDegrees,
            flipHorizontal: state.isFlippedHorizontally,
            flipVertical: state.isFlippedVertically
        )
    }

    /// Pixels per point of `exportImage()`.
    public var exportScale: CGFloat {
        if case let .image(_, scale) = content { return scale > 0 ? scale : 1 }
        return 2
    }
}

/// Content view that draws the pin, transient zoom/opacity HUD, and routes mouse interactions.
final class PinContentView: NSView {
    weak var panel: PinPanel?

    private let hudView = PinHUDView()
    private var hudHideTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hudView.isHidden = true
        addSubview(hudView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        if !hudView.isHidden {
            positionHUD()
        }
    }

    func showHUD(_ text: String) {
        hudHideTask?.cancel()
        hudView.setText(text)
        guard bounds.width >= 56 && bounds.height >= 28 else {
            hudView.isHidden = true
            return
        }
        positionHUD()
        hudView.alphaValue = 1
        hudView.isHidden = false
        hudHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.hudView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.hudView.alphaValue <= 0.01 else { return }
                    self.hudView.isHidden = true
                }
            }
        }
    }

    func hideHUD() {
        hudHideTask?.cancel()
        hudHideTask = nil
        hudView.isHidden = true
    }

    private func positionHUD() {
        let size = hudView.intrinsicContentSize
        hudView.frame = CGRect(
            x: (bounds.midX - size.width / 2).rounded(),
            y: (bounds.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        panel?.makeKey()
        if event.clickCount == 2 {
            panel?.toggleThumbnail()
            return
        }
        window?.performDrag(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            panel?.close()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        panel?.makeContextMenu()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let panel, let context = NSGraphicsContext.current?.cgContext else { return }
        let state = panel.state
        context.clear(bounds)

        let outline: NSBezierPath
        if state.isThumbnail {
            outline = NSBezierPath(
                roundedRect: bounds,
                xRadius: PinLayout.thumbnailCornerRadius,
                yRadius: PinLayout.thumbnailCornerRadius
            )
            drawThumbnail(panel: panel, clip: outline, context: context)
        } else {
            outline = NSBezierPath(rect: bounds)
            drawFull(panel: panel, context: context)
        }

        if state.isClickThrough {
            let inset: CGFloat = 1.5
            let ring = state.isThumbnail
                ? NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                               xRadius: PinLayout.thumbnailCornerRadius - inset,
                               yRadius: PinLayout.thumbnailCornerRadius - inset)
                : NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            ring.lineWidth = 3
            NSColor.systemCyan.withAlphaComponent(0.9).setStroke()
            ring.stroke()
        } else if state.showsBorder {
            let border = state.isThumbnail
                ? NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: PinLayout.thumbnailCornerRadius - 0.5,
                               yRadius: PinLayout.thumbnailCornerRadius - 0.5)
                : NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            NSColor(white: 0.5, alpha: 0.55).setStroke()
            border.stroke()
        }
        _ = outline
    }

    private func drawFull(panel: PinPanel, context: CGContext) {
        let state = panel.state
        let base = panel.baseSize
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if state.isFlippedHorizontally || state.isFlippedVertically {
            context.scaleBy(
                x: state.isFlippedHorizontally ? -1 : 1,
                y: state.isFlippedVertically ? -1 : 1
            )
        }
        context.rotate(by: -CGFloat(state.rotationDegrees) * .pi / 180)
        let unrotated = state.isQuarterTurned
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        context.scaleBy(x: unrotated.width / base.width, y: unrotated.height / base.height)
        let rect = CGRect(x: -base.width / 2, y: -base.height / 2, width: base.width, height: base.height)
        PinRenderer.draw(panel.content, in: rect, zoom: state.zoom, context: context)
        context.restoreGState()
    }

    private func drawThumbnail(panel: PinPanel, clip: NSBezierPath, context: CGContext) {
        context.saveGState()
        clip.addClip()
        let state = panel.state
        let base = state.isQuarterTurned
            ? CGSize(width: panel.baseSize.height, height: panel.baseSize.width)
            : panel.baseSize
        // Aspect-fill the thumbnail square.
        let fill = max(bounds.width / base.width, bounds.height / base.height)
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if state.isFlippedHorizontally || state.isFlippedVertically {
            context.scaleBy(
                x: state.isFlippedHorizontally ? -1 : 1,
                y: state.isFlippedVertically ? -1 : 1
            )
        }
        context.rotate(by: -CGFloat(state.rotationDegrees) * .pi / 180)
        context.scaleBy(x: fill, y: fill)
        let rect = CGRect(
            x: -panel.baseSize.width / 2, y: -panel.baseSize.height / 2,
            width: panel.baseSize.width, height: panel.baseSize.height
        )
        if case let .color(color) = panel.content {
            context.restoreGState()
            context.saveGState()
            clip.addClip()
            color.nsColor.setFill()
            bounds.fill()
        } else {
            PinRenderer.draw(panel.content, in: rect, zoom: fill, context: context)
        }
        context.restoreGState()
    }
}

private final class PinHUDView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        layer?.cornerRadius = 11
        layer?.masksToBounds = true

        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: ceil(labelSize.width) + 18, height: 22)
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame = CGRect(
            x: ((bounds.width - label.frame.width) / 2).rounded(),
            y: ((bounds.height - label.frame.height) / 2).rounded(),
            width: label.frame.width,
            height: label.frame.height
        )
    }
}
