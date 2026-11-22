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

    private static let axGapBridgeMargin: CGFloat = 24
    private static let axRequeryDistance: CGFloat = 2

    private enum CursorKind: Equatable {
        case crosshair, openHand, closedHand, arrow, resize(ResizeHandle)
    }

    private var colorFormat: ColorFormat = .hex
    private var lastMousePoint: CGPoint?
    private var currentSample: CPXColorSample?
    private var isShiftDown = false

    private var lastTier1LocalRect: CGRect?
    private var lastRefinedLocalRect: CGRect?
    private var lastAXQueryPoint: CGPoint?

    private var renderedHighlightValid = false
    private var renderedHighlightRect: CGRect?
    private var renderedIsHovering = true
    private var renderedHandlesRect: CGRect?
    private var lastCursorKind: CursorKind?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let sizeLabel = NonInteractiveLabel(labelWithString: "")
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
        imageLayer.zPosition = 0
        root.addSublayer(imageLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimLayer.frame = bounds
        dimLayer.zPosition = 1
        root.addSublayer(dimLayer)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.systemBlue.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.frame = bounds
        borderLayer.zPosition = 2
        root.addSublayer(borderLayer)

        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor.systemBlue.cgColor
        handleLayer.lineWidth = 1
        handleLayer.frame = bounds
        handleLayer.zPosition = 3
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
        sizeLabel.layer?.zPosition = 10
        sizeLabel.isHidden = true
        addSubview(sizeLabel)

        magnifier.isHidden = true
        magnifier.layer?.zPosition = 20
        addSubview(magnifier)

        toolbar.isHidden = true
        toolbar.wantsLayer = true
        toolbar.layer?.zPosition = 30
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
        lastTier1LocalRect = nil
        lastRefinedLocalRect = nil
        lastAXQueryPoint = nil
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

    /// Applies a Tier 2 (AX) element rect (or `nil` when no sub-element matched) while hovering.
    func applyRefinedElementRect(_ globalRect: CGRect?, forGlobalPoint globalPoint: CGPoint) {
        guard machine.isHovering, let current = lastMousePoint else { return }
        if let globalRect {
            let localRect = globalRect.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
            guard localRect.contains(current) else { return }
            if let tier1 = lastTier1LocalRect {
                guard tier1.insetBy(dx: -2, dy: -2).contains(localRect) else { return }
            }
            let clamped = localRect.standardized.intersection(bounds)
            guard !clamped.isNull, !clamped.isEmpty else { return }
            if rectsNearlyEqual(localRect, lastRefinedLocalRect) &&
               rectsNearlyEqual(clamped, machine.highlightedRect) {
                return
            }
            lastRefinedLocalRect = localRect
            machine.updateHover(detectedRect: localRect)
            refresh()
        } else {
            // Never discard a valid refined element if a transient AX lookup at this cursor position returns nil.
            if let refined = lastRefinedLocalRect, refined.contains(current) {
                return
            }
            if lastRefinedLocalRect != nil {
                lastRefinedLocalRect = nil
                machine.updateHover(detectedRect: lastTier1LocalRect ?? bounds)
                refresh()
            }
        }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        if (shouldBecomeKeyOnHover?() ?? true) && window?.isKeyWindow == false {
            window?.makeKey()
        }
        lastCursorKind = nil
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(local) else { return }
        lastMousePoint = nil
        lastAXQueryPoint = nil
        lastCursorKind = nil
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
        if machine.isHovering {
            // If clicking while holding a neighboring refined rect across a small gap, fall back to the window rect.
            if let current = machine.highlightedRect, !current.contains(point) {
                machine.updateHover(detectedRect: lastTier1LocalRect ?? bounds)
            }
            lastRefinedLocalRect = nil
            lastAXQueryPoint = nil
            onBeginInteraction?()
        }
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
            let tier1Local = hoverRectProvider?(global).map {
                $0.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
            }
            let sameWindow = rectsNearlyEqual(tier1Local, lastTier1LocalRect)
            lastTier1LocalRect = tier1Local

            if !sameWindow {
                lastRefinedLocalRect = nil
                lastAXQueryPoint = nil
                machine.updateHover(detectedRect: tier1Local ?? bounds)
            } else if let refined = lastRefinedLocalRect {
                if refined.contains(point) {
                    machine.updateHover(detectedRect: refined)
                } else if tier1Local != nil,
                          refined.insetBy(dx: -Self.axGapBridgeMargin, dy: -Self.axGapBridgeMargin).contains(point) {
                    // Hold the previous AX rect briefly across small gaps until Tier 2 resolves the next element or nil.
                    machine.updateHover(detectedRect: refined)
                } else {
                    lastRefinedLocalRect = nil
                    machine.updateHover(detectedRect: tier1Local ?? bounds)
                }
            } else {
                machine.updateHover(detectedRect: tier1Local ?? bounds)
            }

            if tier1Local != nil && shouldRequestAX(at: point) {
                lastAXQueryPoint = point
                elementRectRequester?(global)
            }
        }
        refresh()
    }

    private func rectsNearlyEqual(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(a), .some(b)):
            return abs(a.minX - b.minX) < 0.5 &&
                   abs(a.minY - b.minY) < 0.5 &&
                   abs(a.width - b.width) < 0.5 &&
                   abs(a.height - b.height) < 0.5
        default:
            return false
        }
    }

    private func shouldRequestAX(at point: CGPoint) -> Bool {
        guard let prev = lastAXQueryPoint else { return true }
        return hypot(point.x - prev.x, point.y - prev.y) >= Self.axRequeryDistance
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
        case "w":
            onFinish?(.cancel)
            return true
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
        let isHovering = machine.isHovering
        if !renderedHighlightValid ||
           !rectsNearlyEqual(highlight, renderedHighlightRect) ||
           isHovering != renderedIsHovering {
            renderedHighlightValid = true
            renderedHighlightRect = highlight
            renderedIsHovering = isHovering

            let dimPath = CGMutablePath()
            dimPath.addRect(bounds)
            if let highlight { dimPath.addRect(highlight) }
            dimLayer.path = dimPath

            if let highlight {
                borderLayer.path = CGPath(rect: highlight.insetBy(dx: 0.75, dy: 0.75), transform: nil)
                borderLayer.strokeColor = (isHovering ? NSColor.systemCyan : NSColor.systemBlue).cgColor
            } else {
                borderLayer.path = nil
            }

            updateSizeLabel(for: highlight)
        }

        let showsHandles: Bool
        switch machine.state {
        case .selected, .moving, .resizing: showsHandles = true
        case .hovering, .dragging: showsHandles = false
        }
        let handlesRect: CGRect? = showsHandles ? machine.selectionRect : nil
        if !rectsNearlyEqual(handlesRect, renderedHandlesRect) {
            renderedHandlesRect = handlesRect
            if let rect = handlesRect {
                let handles = CGMutablePath()
                for center in SelectionStateMachine.handlePoints(for: rect).values {
                    handles.addRect(CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                }
                handleLayer.path = handles
            } else {
                handleLayer.path = nil
            }
        }

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
        let nextFrame = SnipActionToolbar.frame(for: rect, in: bounds, topInset: topInset)
        if toolbar.isHidden || toolbar.frame != nextFrame {
            toolbar.frame = nextFrame
        }
        toolbar.isHidden = false
    }

    private func updateCursor() {
        guard let point = lastMousePoint else { return }
        let kind: CursorKind
        let cursor: NSCursor
        switch machine.state {
        case .hovering, .dragging:
            kind = .crosshair
            cursor = .crosshair
        case .moving:
            kind = .closedHand
            cursor = .closedHand
        case let .resizing(_, handle, _):
            kind = .resize(handle)
            cursor = Self.cursor(for: handle)
        case let .selected(rect):
            if toolbar.frame.contains(point) {
                kind = .arrow
                cursor = .arrow
            } else if let handle = SelectionStateMachine.hitTestHandle(at: point, rect: rect, radius: machine.handleHitRadius) {
                kind = .resize(handle)
                cursor = Self.cursor(for: handle)
            } else if rect.contains(point) {
                kind = .openHand
                cursor = .openHand
            } else {
                kind = .crosshair
                cursor = .crosshair
            }
        }
        guard kind != lastCursorKind else { return }
        lastCursorKind = kind
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

private final class NonInteractiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
