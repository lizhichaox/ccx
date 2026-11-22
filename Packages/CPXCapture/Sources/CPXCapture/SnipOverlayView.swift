import AppKit
import CPXCore
import QuartzCore

/// What an overlay view asks its controller to do when the session ends.
enum OverlayAction: Equatable {
    case pin(CGRect)
    case copy(CGRect)
    case save(CGRect)
    case copyColor(CPXColorSample, ColorFormat)
    case cancel
}

/// Full-screen snip overlay for one display: frozen image, dim mask, selection chrome,
/// pixel magnifier, and floating action toolbar. Coordinates are view-local AppKit points.
@MainActor
final class SnipOverlayView: NSView {
    let snapshot: DisplaySnapshot
    private(set) var machine: SelectionStateMachine
    private let topInset: CGFloat

    /// Tier 1 hover lookup: global AppKit point -> global window rect.
    var hoverRectProvider: ((CGPoint) -> CGRect?)?
    /// Tier 2 AX request for a global AppKit point; results come back via `applyRefinedElementRect`.
    var elementRectRequester: ((CGPoint) -> Void)?
    /// Called when this view starts a new interaction (so sibling screens can reset).
    var onBeginInteraction: (() -> Void)?
    /// Returns whether hovering into this view should transfer key focus (false when a sibling has a selection).
    var shouldBecomeKeyOnHover: (() -> Bool)?
    /// Called once when the user finishes the session from this view.
    var onFinish: ((OverlayAction) -> Void)?

    private var colorFormat: ColorFormat = .hex
    private var lastMousePoint: CGPoint?
    private var currentSample: CPXColorSample?
    private var isShiftDown = false

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let magnifier = PixelMagnifierView(frame: CGRect(origin: .zero, size: PixelMagnifierView.preferredSize))
    private let toolbar = SnipActionToolbar(frame: CGRect(origin: .zero, size: SnipActionToolbar.preferredSize))
    private var trackingArea: NSTrackingArea?

    init(snapshot: DisplaySnapshot, topInset: CGFloat) {
        self.snapshot = snapshot
        self.topInset = topInset
        let localBounds = CGRect(origin: .zero, size: snapshot.screenFrame.size)
        self.machine = SelectionStateMachine(bounds: localBounds)
        super.init(frame: localBounds)
        wantsLayer = true
        setUpLayers()
        setUpSubviews()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    // MARK: - Setup

    private func setUpLayers() {
        guard let root = layer else { return }
        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.frame = bounds
        root.addSublayer(imageLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimLayer.frame = bounds
        root.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.systemBlue.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.frame = bounds
        root.addSublayer(borderLayer)

        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor.systemBlue.cgColor
        handleLayer.lineWidth = 1
        handleLayer.frame = bounds
        root.addSublayer(handleLayer)

        updateLayerContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContentsScale()
    }

    private func updateLayerContentsScale() {
        let scale = window?.backingScaleFactor ?? snapshot.backingScaleFactor
        layer?.contentsScale = scale
        imageLayer.contentsScale = scale
        dimLayer.contentsScale = scale
        borderLayer.contentsScale = scale
        handleLayer.contentsScale = scale
    }

    private func setUpSubviews() {
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        sizeLabel.textColor = .white
        sizeLabel.drawsBackground = true
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        sizeLabel.wantsLayer = true
        sizeLabel.layer?.cornerRadius = 4
        sizeLabel.layer?.masksToBounds = true
        sizeLabel.isHidden = true
        addSubview(sizeLabel)

        magnifier.isHidden = true
        addSubview(magnifier)

        toolbar.isHidden = true
        toolbar.onAction = { [weak self] action in self?.handleToolbar(action) }
        addSubview(toolbar)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - External control

    /// Resets to hovering (used when the user starts interacting on another screen).
    func resetSelection() {
        machine.reset()
        refresh()
    }

    /// Seeds hover detection and the magnifier at the current mouse location.
    func primeWithMouseLocation(_ globalPoint: CGPoint) {
        let local = toLocal(globalPoint)
        guard bounds.contains(local) else {
            lastMousePoint = nil
            refresh()
            return
        }
        handleHover(at: local)
    }

    /// Applies a Tier 2 (AX) element rect if the cursor is still hovering near the queried point.
    func applyRefinedElementRect(_ globalRect: CGRect, forGlobalPoint globalPoint: CGPoint) {
        guard machine.isHovering, let current = lastMousePoint else { return }
        let local = toLocal(globalPoint)
        guard abs(local.x - current.x) < 8, abs(local.y - current.y) < 8 else { return }
        let localRect = globalRect.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
        guard localRect.contains(current) else { return }
        machine.updateHover(detectedRect: localRect)
        refresh()
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        if shouldBecomeKeyOnHover?() ?? true {
            window?.makeKey()
        }
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        lastMousePoint = nil
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        if event.clickCount >= 2, let rect = machine.selectionRect, machine.isSelected, rect.contains(point) {
            onFinish?(.copy(rect))
            return
        }
        if machine.isHovering { onBeginInteraction?() }
        machine.mouseDown(at: point)
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        machine.mouseDragged(to: point)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        machine.mouseUp(at: point)
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(.cancel)
    }

    private func handleHover(at point: CGPoint) {
        lastMousePoint = point
        if machine.isHovering {
            let global = toGlobal(point)
            let detected = hoverRectProvider?(global).map {
                $0.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
            }
            machine.updateHover(detectedRect: detected ?? bounds)
            elementRectRequester?(global)
        }
        refresh()
    }

    // MARK: - Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleCommandKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleCommandKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags == .command else { return false }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            if let rect = selectedRect {
                onFinish?(.copy(rect))
                return true
            } else if let sample = currentSample {
                onFinish?(.copyColor(sample, colorFormat))
                return true
            }
            return false
        case "s":
            if let rect = selectedRect {
                onFinish?(.save(rect))
                return true
            }
            return false
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53: // Escape
            onFinish?(.cancel)
            return
        case 36, 76: // Return, keypad Enter
            if let rect = selectedRect { onFinish?(.pin(rect)) }
            return
        case 123: nudge(dx: -1, dy: 0); return
        case 124: nudge(dx: 1, dy: 0); return
        case 125: nudge(dx: 0, dy: -1); return
        case 126: nudge(dx: 0, dy: 1); return
        default: break
        }

        if handleCommandKeyEquivalent(with: event) {
            return
        }
        if !flags.contains(.command) && characters == "c" {
            if !magnifier.isHidden, let sample = currentSample {
                onFinish?(.copyColor(sample, colorFormat))
            }
        } else {
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if shift && !isShiftDown {
            colorFormat = colorFormat.next
            refresh()
        }
        isShiftDown = shift
    }

    private var selectedRect: CGRect? {
        if case let .selected(rect) = machine.state { return rect }
        return nil
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        if machine.nudge(dx: dx, dy: dy) { refresh() }
    }

    private func handleToolbar(_ action: SnipToolbarAction) {
        guard let rect = selectedRect else {
            if action == .cancel { onFinish?(.cancel) }
            return
        }
        switch action {
        case .pin: onFinish?(.pin(rect))
        case .copy: onFinish?(.copy(rect))
        case .save: onFinish?(.save(rect))
        case .cancel: onFinish?(.cancel)
        }
    }

    // MARK: - Rendering

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let highlight = machine.highlightedRect
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        if let highlight { dimPath.addRect(highlight) }
        dimLayer.path = dimPath

        if let highlight {
            borderLayer.path = CGPath(rect: highlight.insetBy(dx: 0.75, dy: 0.75), transform: nil)
            borderLayer.strokeColor = (machine.isHovering ? NSColor.systemCyan : NSColor.systemBlue).cgColor
        } else {
            borderLayer.path = nil
        }

        let showsHandles: Bool
        switch machine.state {
        case .selected, .moving, .resizing: showsHandles = true
        case .hovering, .dragging: showsHandles = false
        }
        if showsHandles, let rect = machine.selectionRect {
            let handles = CGMutablePath()
            for center in SelectionStateMachine.handlePoints(for: rect).values {
                handles.addRect(CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
            }
            handleLayer.path = handles
        } else {
            handleLayer.path = nil
        }

        updateSizeLabel(for: highlight)
        updateMagnifier(highlight: highlight)
        updateToolbar()
        updateCursor()
    }

    private var pixelScale: CGSize {
        CGSize(
            width: CGFloat(snapshot.image.width) / max(bounds.width, 1),
            height: CGFloat(snapshot.image.height) / max(bounds.height, 1)
        )
    }

    private func sizeText(for rect: CGRect?) -> String {
        guard let rect else { return "" }
        let scale = pixelScale
        let width = Int((rect.width * scale.width).rounded())
        let height = Int((rect.height * scale.height).rounded())
        return "\(width) × \(height)"
    }

    private func updateSizeLabel(for rect: CGRect?) {
        guard let rect, !machine.isHovering || rect != bounds else {
            sizeLabel.isHidden = true
            return
        }
        sizeLabel.stringValue = " \(sizeText(for: rect)) "
        sizeLabel.sizeToFit()
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 4)
        if origin.y + sizeLabel.frame.height > bounds.maxY - topInset {
            origin.y = rect.maxY - sizeLabel.frame.height - 4
        }
        origin.x = min(max(origin.x, 0), bounds.maxX - sizeLabel.frame.width)
        sizeLabel.setFrameOrigin(origin)
        sizeLabel.isHidden = false
    }

    private func updateMagnifier(highlight: CGRect?) {
        let visibleState: Bool
        switch machine.state {
        case .hovering, .dragging, .resizing: visibleState = true
        case .selected, .moving: visibleState = false
        }
        guard visibleState, let point = lastMousePoint, bounds.contains(point) else {
            magnifier.isHidden = true
            currentSample = nil
            return
        }
        let image = snapshot.image
        let scale = pixelScale
        let pixelX = min(max(Int((point.x * scale.width).rounded(.down)), 0), image.width - 1)
        let pixelY = min(max(Int(((bounds.height - point.y) * scale.height).rounded(.down)), 0), image.height - 1)
        currentSample = CPXColorSample.samplePixel(from: image, pixelX: pixelX, pixelY: pixelY)
        magnifier.update(
            image: image,
            pixelX: pixelX,
            pixelY: pixelY,
            sample: currentSample,
            format: colorFormat,
            sizeText: sizeText(for: highlight)
        )
        magnifier.frame = PixelMagnifierView.frame(near: point, in: bounds, topInset: topInset)
        magnifier.isHidden = false
    }

    private func updateToolbar() {
        guard let rect = selectedRect else {
            toolbar.isHidden = true
            return
        }
        toolbar.frame = SnipActionToolbar.frame(for: rect, in: bounds, topInset: topInset)
        toolbar.isHidden = false
    }

    private func updateCursor() {
        guard let point = lastMousePoint else { return }
        let cursor: NSCursor
        switch machine.state {
        case .hovering, .dragging:
            cursor = .crosshair
        case .moving:
            cursor = .closedHand
        case let .resizing(_, handle, _):
            cursor = Self.cursor(for: handle)
        case let .selected(rect):
            if toolbar.frame.contains(point) {
                cursor = .arrow
            } else if let handle = SelectionStateMachine.hitTestHandle(at: point, rect: rect, radius: machine.handleHitRadius) {
                cursor = Self.cursor(for: handle)
            } else if rect.contains(point) {
                cursor = .openHand
            } else {
                cursor = .crosshair
            }
        }
        cursor.set()
    }

    private static func cursor(for handle: ResizeHandle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    // MARK: - Coordinates

    private func toGlobal(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + snapshot.screenFrame.minX, y: local.y + snapshot.screenFrame.minY)
    }

    private func toLocal(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - snapshot.screenFrame.minX, y: global.y - snapshot.screenFrame.minY)
    }
}
