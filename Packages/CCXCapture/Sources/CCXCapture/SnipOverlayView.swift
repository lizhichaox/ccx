import AppKit
import CCXAnnotate
import CCXCore
import QuartzCore

/// What an overlay view asks its controller to do when the session ends.
enum OverlayAction: Equatable {
    case pin(CGRect)
    case copy(CGRect)
    case save(CGRect)
    case copyColor(CCXColorSample, ColorFormat)
    case cancel
}

/// Full-screen snip overlay for one display: frozen image, dim mask, selection chrome,
/// live annotation canvas, pixel magnifier, and floating two-tier toolbar.
/// Coordinates are view-local AppKit points.
@MainActor
final class SnipOverlayView: NSView, NSTextFieldDelegate {
    let snapshot: DisplaySnapshot
    private(set) var machine: SelectionStateMachine
    let annotations = AnnotationDocument()
    let mosaicCache: MosaicImageCache
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
        case crosshair, openHand, closedHand, arrow, iBeam, resize(ResizeHandle)
    }

    private enum DragInteraction {
        case none
        case selectionMachine
        case drawing(AnnotationTool, origin: CGPoint)
        case movingAnnotation(initial: AnnotationItem, startPoint: CGPoint, didPushUndo: Bool)
        case resizingAnnotation(initial: AnnotationItem, handle: AnnotationHandle, didPushUndo: Bool)
    }

    private var colorFormat: ColorFormat = .hex
    private var lastMousePoint: CGPoint?
    private var currentSample: CCXColorSample?
    private var isShiftDown = false

    private(set) var activeTool: AnnotationTool = .select
    private(set) var currentStyle = AnnotationStyle()
    private var activeDrag: DragInteraction = .none

    private var inlineEditor: NSTextField?
    private var editingTextOrigin: CGPoint?
    private var editingOriginalItem: AnnotationItem?

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
    private let annotationView: AnnotationCanvasView
    private let sizeLabel = NonInteractiveLabel(labelWithString: "")
    private let magnifier = PixelMagnifierView(frame: CGRect(origin: .zero, size: PixelMagnifierView.preferredSize))
    private let toolbar = SnipActionToolbar(frame: CGRect(origin: .zero, size: SnipActionToolbar.preferredSize))
    private var trackingArea: NSTrackingArea?

    init(snapshot: DisplaySnapshot, topInset: CGFloat) {
        self.snapshot = snapshot
        self.topInset = topInset
        let localBounds = CGRect(origin: .zero, size: snapshot.screenFrame.size)
        self.machine = SelectionStateMachine(bounds: localBounds)
        let cache = MosaicImageCache(baseImage: snapshot.image)
        self.mosaicCache = cache
        self.annotationView = AnnotationCanvasView(
            frame: localBounds,
            document: annotations,
            mosaicCache: cache,
            backingScale: snapshot.backingScaleFactor
        )
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
        annotationView.backingScale = scale
    }

    private func setUpSubviews() {
        annotationView.autoresizingMask = [.width, .height]
        annotationView.layer?.zPosition = 1.5
        addSubview(annotationView)

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
        toolbar.onToolSelected = { [weak self] tool in self?.selectOrToggleTool(tool) }
        toolbar.onStyleChanged = { [weak self] style in self?.applyStyle(style) }
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

    // MARK: - External & Programmatic Control

    /// Resets to hovering (used when the user starts interacting on another screen).
    func resetSelection() {
        cancelInlineTextEditor()
        annotations.clear()
        activeTool = .select
        activeDrag = .none
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

    func setActiveTool(_ tool: AnnotationTool) {
        commitInlineTextEditor()
        activeTool = tool
        if tool != .select {
            annotations.selectedID = nil
        }
        refresh()
    }

    func selectOrToggleTool(_ tool: AnnotationTool) {
        if activeTool == tool {
            setActiveTool(.select)
        } else {
            setActiveTool(tool)
        }
    }

    func applyStyle(_ style: AnnotationStyle) {
        currentStyle = style
        if let editor = inlineEditor {
            editor.textColor = style.color.nsColor
            editor.font = NSFont.systemFont(ofSize: style.size.fontSize, weight: .bold)
            resizeInlineEditor(editor)
        }
        if annotations.updateSelectedStyle({ $0 = style }) {
            annotationView.needsDisplay = true
        }
        refresh()
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

        if inlineEditor != nil {
            commitInlineTextEditor()
            activeDrag = .none
            refresh()
            return
        }

        if machine.isHovering {
            if let current = machine.highlightedRect, !current.contains(point) {
                machine.updateHover(detectedRect: lastTier1LocalRect ?? bounds)
            }
            lastRefinedLocalRect = nil
            lastAXQueryPoint = nil
            onBeginInteraction?()
            activeDrag = .selectionMachine
            machine.mouseDown(at: point)
            refresh()
            return
        }

        guard let selection = selectedRect else {
            activeDrag = .selectionMachine
            machine.mouseDown(at: point)
            refresh()
            return
        }

        handleSelectedMouseDown(at: point, clickCount: event.clickCount, selection: selection)
    }

    private func handleSelectedMouseDown(at point: CGPoint, clickCount: Int, selection: CGRect) {
        if activeTool == .select {
            if let selected = annotations.selectedItem,
               let handle = selected.hitTestHandle(at: point) {
                activeDrag = .resizingAnnotation(initial: selected, handle: handle, didPushUndo: false)
                refresh()
                return
            }

            if SelectionStateMachine.hitTestHandle(at: point, rect: selection, radius: machine.handleHitRadius) != nil {
                annotations.selectedID = nil
                activeDrag = .selectionMachine
                machine.mouseDown(at: point)
                refresh()
                return
            }

            if let hit = annotations.hitTestItem(at: point) {
                annotations.selectedID = hit.id
                currentStyle = hit.style
                if clickCount >= 2, case let .text(origin, content) = hit.kind {
                    activeDrag = .none
                    beginInlineTextEditor(at: origin, existing: hit, initialText: content, in: selection)
                    return
                }
                activeDrag = .movingAnnotation(initial: hit, startPoint: point, didPushUndo: false)
                refresh()
                return
            }

            annotations.selectedID = nil
            if clickCount >= 2, selection.contains(point) {
                finish(.copy(selection))
                return
            }
            activeDrag = .selectionMachine
            machine.mouseDown(at: point)
            refresh()
            return
        }

        // Drawing tool active: crop handles stay directly resizable; clicks inside draw cleanly.
        if SelectionStateMachine.hitTestHandle(at: point, rect: selection, radius: machine.handleHitRadius) != nil {
            annotations.selectedID = nil
            activeDrag = .selectionMachine
            machine.mouseDown(at: point)
            refresh()
            return
        }

        guard selection.contains(point) else {
            annotations.selectedID = nil
            activeDrag = .none
            refresh()
            return
        }

        annotations.selectedID = nil
        switch activeTool {
        case .select:
            break
        case .counter:
            let badge = AnnotationItem(
                kind: .counter(center: point, number: annotations.nextCounterNumber),
                style: currentStyle
            )
            annotations.commit(badge)
            activeDrag = .none
            annotationView.needsDisplay = true
        case .text:
            activeDrag = .none
            let startOrigin = CGPoint(
                x: min(max(point.x, selection.minX + 4), max(selection.minX + 4, selection.maxX - 84)),
                y: min(max(point.y + currentStyle.size.fontSize * 0.55, selection.minY + currentStyle.size.fontSize * 1.4), selection.maxY - 4)
            )
            beginInlineTextEditor(at: startOrigin, existing: nil, initialText: "", in: selection)
            return
        case .rectangle, .ellipse, .mosaic:
            let kind: AnnotationKind = switch activeTool {
            case .rectangle: .rectangle(CGRect(origin: point, size: .zero))
            case .ellipse: .ellipse(CGRect(origin: point, size: .zero))
            default: .mosaic(CGRect(origin: point, size: .zero), currentStyle.mosaicMode)
            }
            annotations.draft = AnnotationItem(kind: kind, style: currentStyle)
            activeDrag = .drawing(activeTool, origin: point)
        case .arrow:
            annotations.draft = AnnotationItem(kind: .arrow(start: point, end: point), style: currentStyle)
            activeDrag = .drawing(.arrow, origin: point)
        case .pen:
            annotations.draft = AnnotationItem(kind: .pen([point]), style: currentStyle)
            activeDrag = .drawing(.pen, origin: point)
        case .highlighter:
            annotations.draft = AnnotationItem(kind: .highlighter([point]), style: currentStyle)
            activeDrag = .drawing(.highlighter, origin: point)
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        let constrain = event.modifierFlags.contains(.shift)

        switch activeDrag {
        case .none:
            break
        case .selectionMachine:
            machine.mouseDragged(to: point)
        case let .drawing(tool, origin):
            let clamped = clampToSelection(point)
            updateDraft(tool: tool, origin: origin, current: clamped, constrain: constrain)
            annotationView.needsDisplay = true
        case let .movingAnnotation(initial, startPoint, didPushUndo):
            let delta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            if !didPushUndo && hypot(delta.width, delta.height) >= 1 {
                annotations.beginMutationSnapshot()
                activeDrag = .movingAnnotation(initial: initial, startPoint: startPoint, didPushUndo: true)
            }
            if case let .movingAnnotation(_, _, pushed) = activeDrag, pushed {
                annotations.replaceItem(initial.translated(by: delta), recordUndo: false)
                annotationView.needsDisplay = true
            }
        case let .resizingAnnotation(initial, handle, didPushUndo):
            if !didPushUndo {
                annotations.beginMutationSnapshot()
                activeDrag = .resizingAnnotation(initial: initial, handle: handle, didPushUndo: true)
            }
            let clamped = clampToSelection(point)
            annotations.replaceItem(initial.resized(handle: handle, to: clamped, constrain: constrain), recordUndo: false)
            annotationView.needsDisplay = true
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point

        switch activeDrag {
        case .none:
            break
        case .selectionMachine:
            machine.mouseUp(at: point)
        case let .drawing(tool, _):
            if let draft = annotations.draft, Self.isMeaningfulDraft(draft, tool: tool) {
                annotations.commit(draft)
            } else {
                annotations.draft = nil
            }
            annotationView.needsDisplay = true
        case .movingAnnotation, .resizingAnnotation:
            annotationView.needsDisplay = true
        }

        activeDrag = .none
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelInlineTextEditor()
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

    private func clampToSelection(_ point: CGPoint) -> CGPoint {
        guard let rect = selectedRect else { return point }
        return CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func updateDraft(tool: AnnotationTool, origin: CGPoint, current: CGPoint, constrain: Bool) {
        guard var draft = annotations.draft else { return }
        switch tool {
        case .rectangle:
            draft.kind = .rectangle(AnnotationItem.constrainedRect(from: origin, to: current, square: constrain))
        case .ellipse:
            draft.kind = .ellipse(AnnotationItem.constrainedRect(from: origin, to: current, square: constrain))
        case .mosaic:
            draft.kind = .mosaic(
                AnnotationItem.constrainedRect(from: origin, to: current, square: constrain),
                currentStyle.mosaicMode
            )
        case .arrow:
            let end = AnnotationItem.constrainedEnd(from: origin, to: current, snapAngle: constrain)
            draft.kind = .arrow(start: origin, end: end)
        case .pen:
            if case let .pen(points) = draft.kind {
                draft.kind = .pen(AnnotationItem.appendPoint(current, to: points))
            }
        case .highlighter:
            if case let .highlighter(points) = draft.kind {
                draft.kind = .highlighter(AnnotationItem.appendPoint(current, to: points))
            }
        case .select, .text, .counter:
            break
        }
        annotations.draft = draft
    }

    private static func isMeaningfulDraft(_ item: AnnotationItem, tool: AnnotationTool) -> Bool {
        switch item.kind {
        case let .rectangle(r), let .ellipse(r), let .mosaic(r, _):
            let s = r.standardized
            return s.width >= 3 && s.height >= 3
        case let .arrow(start, end):
            return hypot(end.x - start.x, end.y - start.y) >= 4
        case let .pen(pts), let .highlighter(pts):
            guard let first = pts.first, let last = pts.last else { return false }
            return pts.count >= 2 && (pts.count > 2 || hypot(last.x - first.x, last.y - first.y) >= 2)
        case .text, .counter:
            return tool == .text || tool == .counter
        }
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

    // MARK: - Inline Text Editor

    private var isEditingText: Bool { inlineEditor != nil }

    private func beginInlineTextEditor(
        at origin: CGPoint,
        existing: AnnotationItem?,
        initialText: String,
        in selection: CGRect
    ) {
        cancelInlineTextEditor()
        let style = existing?.style ?? currentStyle
        currentStyle = style

        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.38)
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.font = NSFont.systemFont(ofSize: style.size.fontSize, weight: .bold)
        field.textColor = style.color.nsColor
        field.stringValue = initialText
        field.placeholderString = "Text"
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        field.layer?.zPosition = 25

        editingTextOrigin = origin
        editingOriginalItem = existing
        inlineEditor = field
        annotationView.editingTextItemID = existing?.id
        annotationView.needsDisplay = true

        addSubview(field)
        resizeInlineEditor(field, clampedTo: selection)
        window?.makeFirstResponder(field)
        refresh()
    }

    private func resizeInlineEditor(_ field: NSTextField, clampedTo selectionRect: CGRect? = nil) {
        guard let origin = editingTextOrigin else { return }
        let selection = selectionRect ?? self.selectedRect ?? bounds
        let box = AnnotationItem.textBoundingBox(
            origin: origin,
            content: field.stringValue,
            fontSize: currentStyle.size.fontSize
        )
        let width = min(max(box.width + 12, 88), max(88, selection.maxX - origin.x))
        let height = min(max(box.height + 6, ceil(currentStyle.size.fontSize * 1.45)), max(28, origin.y - selection.minY))
        field.frame = CGRect(x: origin.x, y: origin.y - height, width: width, height: height)
    }

    private func commitInlineTextEditor() {
        guard let field = inlineEditor else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = editingTextOrigin
        let existing = editingOriginalItem

        field.removeFromSuperview()
        inlineEditor = nil
        editingTextOrigin = nil
        editingOriginalItem = nil
        annotationView.editingTextItemID = nil

        if let existing {
            if trimmed.isEmpty {
                annotations.selectedID = existing.id
                annotations.deleteSelected()
            } else if let origin {
                var updated = existing
                updated.kind = .text(origin: origin, content: field.stringValue)
                updated.style = currentStyle
                annotations.replaceItem(updated, recordUndo: true)
                annotations.selectedID = updated.id
            }
        } else if !trimmed.isEmpty, let origin {
            let item = AnnotationItem(kind: .text(origin: origin, content: field.stringValue), style: currentStyle)
            annotations.commit(item)
        }

        window?.makeFirstResponder(self)
        annotationView.needsDisplay = true
        refresh()
    }

    private func cancelInlineTextEditor() {
        guard let field = inlineEditor else { return }
        field.removeFromSuperview()
        inlineEditor = nil
        editingTextOrigin = nil
        editingOriginalItem = nil
        annotationView.editingTextItemID = nil
        window?.makeFirstResponder(self)
        annotationView.needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = inlineEditor else { return }
        resizeInlineEditor(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let mods = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if mods.contains(.shift) || mods.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                if let field = inlineEditor { resizeInlineEditor(field) }
                return true
            }
            commitInlineTextEditor()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineTextEditor()
            refresh()
            return true
        }
        return false
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
        let char = event.charactersIgnoringModifiers?.lowercased()

        if isEditingText {
            if flags == .command && char == "w" {
                cancelInlineTextEditor()
                onFinish?(.cancel)
                return true
            }
            return false
        }

        if flags == [.command, .shift], char == "z", selectedRect != nil {
            if annotations.redo() {
                annotationView.needsDisplay = true
                refresh()
            }
            return true
        }

        guard flags == .command else { return false }

        switch char {
        case "c":
            if let rect = selectedRect {
                finish(.copy(rect))
                return true
            } else if let sample = currentSample {
                onFinish?(.copyColor(sample, colorFormat))
                return true
            }
            return false
        case "s":
            if let rect = selectedRect {
                finish(.save(rect))
                return true
            }
            return false
        case "z":
            if selectedRect != nil {
                if annotations.undo() {
                    annotationView.needsDisplay = true
                    refresh()
                }
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
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if isEditingText {
            if event.keyCode == 53 {
                cancelInlineTextEditor()
                refresh()
                return
            }
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 53: // Escape
            onFinish?(.cancel)
            return
        case 36, 76: // Return, keypad Enter
            if let rect = selectedRect { finish(.pin(rect)) }
            return
        case 51, 117: // Delete, Forward Delete
            if selectedRect != nil, annotations.deleteSelected() {
                annotationView.needsDisplay = true
                refresh()
                return
            }
        case 123: nudge(dx: -1, dy: 0); return
        case 124: nudge(dx: 1, dy: 0); return
        case 125: nudge(dx: 0, dy: -1); return
        case 126: nudge(dx: 0, dy: 1); return
        default: break
        }

        if handleCommandKeyEquivalent(with: event) {
            return
        }

        if flags.isEmpty, selectedRect != nil {
            if characters == "v" {
                setActiveTool(.select)
                return
            }
            if let tool = AnnotationTool.forNumberKey(characters) {
                selectOrToggleTool(tool)
                return
            }
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
        switch action {
        case .undo:
            commitInlineTextEditor()
            if annotations.undo() {
                annotationView.needsDisplay = true
                refresh()
            }
        case .redo:
            commitInlineTextEditor()
            if annotations.redo() {
                annotationView.needsDisplay = true
                refresh()
            }
        case .pin:
            if let rect = selectedRect { finish(.pin(rect)) }
        case .copy:
            if let rect = selectedRect { finish(.copy(rect)) }
        case .save:
            if let rect = selectedRect { finish(.save(rect)) }
        case .cancel:
            cancelInlineTextEditor()
            onFinish?(.cancel)
        }
    }

    private func finish(_ action: OverlayAction) {
        commitInlineTextEditor()
        onFinish?(action)
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
            annotationView.clipRect = machine.selectionRect
            if let rect = handlesRect {
                let handles = CGMutablePath()
                for center in SelectionStateMachine.handlePoints(for: rect).values {
                    handles.addRect(CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                }
                handleLayer.path = handles
            } else {
                handleLayer.path = nil
            }
            annotationView.needsDisplay = true
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
        currentSample = CCXColorSample.samplePixel(from: image, pixelX: pixelX, pixelY: pixelY)
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
        let selectedItem = annotations.selectedItem
        let showStyleBar = activeTool.showsStyleBar || selectedItem != nil || isEditingText
        let effectiveStyleTool = selectedItem?.kind.tool ?? (isEditingText ? .text : activeTool)
        let effectiveStyle = selectedItem?.style ?? currentStyle

        toolbar.update(
            activeTool: activeTool,
            styleTool: effectiveStyleTool,
            style: effectiveStyle,
            showStyleBar: showStyleBar,
            canUndo: annotations.canUndo,
            canRedo: annotations.canRedo
        )

        let nextFrame = SnipActionToolbar.frame(
            for: rect,
            in: bounds,
            topInset: topInset,
            showsStyleBar: showStyleBar
        )
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
            let toolbarPoint = toolbar.convert(point, from: self)
            if !toolbar.isHidden && toolbar.hitsInteractiveArea(toolbarPoint) {
                kind = .arrow
                cursor = .arrow
            } else if activeTool.isDrawingTool && rect.contains(point) {
                if activeTool == .text {
                    kind = .iBeam
                    cursor = .iBeam
                } else {
                    kind = .crosshair
                    cursor = .crosshair
                }
            } else if let selected = annotations.selectedItem, selected.hitTestHandle(at: point) != nil {
                kind = .crosshair
                cursor = .crosshair
            } else if let handle = SelectionStateMachine.hitTestHandle(at: point, rect: rect, radius: machine.handleHitRadius) {
                kind = .resize(handle)
                cursor = Self.cursor(for: handle)
            } else if annotations.hitTestItem(at: point) != nil {
                kind = .openHand
                cursor = .openHand
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
