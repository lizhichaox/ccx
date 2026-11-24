import AppKit
import CCXAnnotate
import CCXCore
import QuartzCore

/// What an overlay view asks its controller to do when the session ends.
enum OverlayAction: Equatable {
    case pin(CGRect)
    case copy(CGRect)
    case save(CGRect)
    case quickSave(CGRect)
    case scroll(CGRect)
    case record(CGRect)
    case ocr(CGRect)
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
    private let selectionMode: SnipSelectionMode
    private let previousSelectionRect: CGRect?

    /// Tier 1 hover lookup: global AppKit point -> global window rect.
    var hoverRectProvider: ((CGPoint) -> CGRect?)?
    /// Returns whether Tier 2 AX element refinement should be queried at a global AppKit point.
    var shouldQueryElementRect: ((CGPoint) -> Bool)?
    /// Tier 2 AX request for a global AppKit point; results come back via `applyRefinedElementRect`.
    var elementRectRequester: ((CGPoint) -> Void)?
    /// Cancels any pending Tier 2 AX element queries when hover moves to a non-AX target or ends.
    var cancelElementRectRequests: (() -> Void)?
    /// Called when this view receives hover input so hovering sibling displays clear stale highlights.
    var onHoverActive: (() -> Void)?
    /// Returns whether any sibling display currently holds an active selection.
    var hasSiblingSelection: (() -> Bool)?
    /// Called when this view starts a new interaction (so sibling screens can reset).
    var onBeginInteraction: (() -> Void)?
    /// Returns whether hovering into this view should transfer key focus (false when a sibling has a selection).
    var shouldBecomeKeyOnHover: (() -> Bool)?
    /// Called once when the user finishes the session from this view.
    var onFinish: ((OverlayAction) -> Void)?
    /// Called whenever the active annotation style changes so the next session restores it.
    var onStyleUpdated: ((AnnotationStyle) -> Void)?

    private static let axGapBridgeMargin: CGFloat = 24
    private static let axRequeryDistance: CGFloat = 2

    private enum CursorKind: Equatable {
        case crosshair, openHand, closedHand, arrow, iBeam, resize(ResizeHandle), annotationResize(AnnotationHandle)
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
    private var lastSampledPixel: (x: Int, y: Int)?
    private var currentSample: CCXColorSample?
    private var isShiftDown = false
    private var isSpaceDown = false
    private var lastSizeLabelText: String?
    private var cachedHighlightSizeText = ""

    private(set) var activeTool: AnnotationTool = .select
    private(set) var currentStyle = AnnotationStyle()
    private var activeDrag: DragInteraction = .none
    private var isSliderEditingSize = false
    private var sliderUndoRecorded = false
    private var sliderUndoItemID: UUID?
    private var scrollUndoActive = false
    private var scrollUndoItemID: UUID?
    private var lastScrollUndoTimestamp: TimeInterval = 0

    private var inlineEditor: NSTextField?
    private var editingTextOrigin: CGPoint?
    private var editingOriginalItem: AnnotationItem?
    private var editingOriginalStyle: AnnotationStyle?

    private var lastTier1LocalRect: CGRect?
    private var lastRefinedLocalRect: CGRect?
    private var lastRefinedIsOverlayElement = false
    private var lastAXQueryPoint: CGPoint?
    private var hasInFlightAXQuery = false
    /// Monotonic epoch incremented on window changes, hover exits, and interaction starts to drop stale AX replies.
    private(set) var axEpoch: UInt64 = 0

    private var renderedHighlightValid = false
    private var renderedHighlightRect: CGRect?
    private var renderedIsHovering = true
    private var renderedHandlesRect: CGRect?
    private var hasRenderedAnnotations = false
    private var lastCursorKind: CursorKind?

    private let pixelSampler = SnapshotPixelSampler()
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let annotationView: AnnotationCanvasView
    private let sizeLabel = NonInteractiveLabel(labelWithString: "")
    private let magnifier = PixelMagnifierView(frame: CGRect(origin: .zero, size: PixelMagnifierView.preferredSize))
    private let sizeHUD = StrokeSizeHUDView(frame: .zero)
    let toolbar = SnipActionToolbar(frame: CGRect(origin: .zero, size: SnipActionToolbar.preferredSize))
    private(set) var customToolbarTopLeft: CGPoint?
    private var trackingArea: NSTrackingArea?

    var sizeLabelFrame: CGRect { sizeLabel.frame }
    var isSizeLabelHidden: Bool { sizeLabel.isHidden }
    var isMagnifierHidden: Bool { magnifier.isHidden }
    var isSizeHUDHidden: Bool { sizeHUD.isHidden }
    var sizeHUDText: String { sizeHUD.displayText }
    var sizeHUDFrame: CGRect { sizeHUD.frame }
    var borderLayerPath: CGPath? { borderLayer.path }
    var isEditingTextForTesting: Bool { isEditingText }
    var inlineEditorFrameForTesting: CGRect? { inlineEditor?.frame }
    var inlineEditorFieldForTesting: NSTextField? { inlineEditor }
    var magnifierViewForTesting: PixelMagnifierView { magnifier }

    init(
        snapshot: DisplaySnapshot,
        topInset: CGFloat,
        selectionMode: SnipSelectionMode = .snip,
        initialStyle: AnnotationStyle = AnnotationStyle(),
        previousSelectionRect: CGRect? = nil,
        initialShiftDown: Bool = NSEvent.modifierFlags.contains(.shift)
    ) {
        self.snapshot = snapshot
        self.topInset = topInset
        self.selectionMode = selectionMode
        self.currentStyle = initialStyle
        self.previousSelectionRect = previousSelectionRect
        self.isShiftDown = initialShiftDown
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

        sizeHUD.isHidden = true
        sizeHUD.wantsLayer = true
        sizeHUD.layer?.zPosition = 28
        addSubview(sizeHUD)

        toolbar.isHidden = true
        toolbar.wantsLayer = true
        toolbar.layer?.zPosition = 30
        toolbar.onAction = { [weak self] action in self?.handleToolbar(action) }
        toolbar.onToolSelected = { [weak self] tool in self?.selectOrToggleTool(tool) }
        toolbar.onStyleChanged = { [weak self] style in self?.applyStyle(style) }
        toolbar.onSizeChanged = { [weak self] size in self?.handleToolbarSizeChanged(size) }
        toolbar.onSizeEditingStateChanged = { [weak self] editing in self?.handleSliderSizeEditingStateChanged(editing) }
        toolbar.onDragMoved = { [weak self] topLeft in self?.moveToolbar(toProposedTopLeft: topLeft) }
        toolbar.onDragStateChanged = { [weak self] dragging, point in
            self?.handleToolbarDragStateChanged(isDragging: dragging, at: point)
        }
        toolbar.onResetPosition = { [weak self] in self?.resetToolbarPosition() }
        addSubview(toolbar)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        invalidateCursor()
    }

    /// Forces a fresh cursor application once the non-activating overlay panel is visible and key.
    func invalidateCursor() {
        lastCursorKind = nil
        updateCursor()
    }

    // MARK: - External & Programmatic Control

    /// Releases all snapshot references, mosaic caches, active editors, timers, and callbacks.
    func tearDown() {
        cancelInlineTextEditor()
        sizeHUD.hideImmediately()
        toolbar.cancelDragging()
        toolbar.onAction = nil
        toolbar.onToolSelected = nil
        toolbar.onStyleChanged = nil
        toolbar.onSizeChanged = nil
        toolbar.onSizeEditingStateChanged = nil
        toolbar.onDragMoved = nil
        toolbar.onDragStateChanged = nil
        toolbar.onResetPosition = nil
        bumpAXEpoch(cancelPending: true)
        annotations.clear()
        mosaicCache.clear()
        magnifier.clear()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        dimLayer.path = nil
        borderLayer.path = nil
        handleLayer.path = nil
        CATransaction.commit()
    }

    /// Resets to hovering (used when the user starts interacting on another screen).
    func resetSelection() {
        cancelInlineTextEditor()
        toolbar.cancelDragging()
        let hadAnnotations = !annotations.items.isEmpty || annotations.draft != nil || hasRenderedAnnotations
        annotations.clear()
        if hadAnnotations {
            annotationView.invalidateActiveRegion()
            hasRenderedAnnotations = false
        }
        bumpAXEpoch(cancelPending: hasInFlightAXQuery)
        activeTool = .select
        activeDrag = .none
        isSliderEditingSize = false
        sliderUndoRecorded = false
        sliderUndoItemID = nil
        resetScrollUndoCoalescing()
        sizeHUD.hideImmediately()
        customToolbarTopLeft = nil
        lastMousePoint = nil
        lastTier1LocalRect = nil
        lastRefinedLocalRect = nil
        lastRefinedIsOverlayElement = false
        lastAXQueryPoint = nil
        lastSampledPixel = nil
        lastCursorKind = nil
        isSpaceDown = false
        lastSizeLabelText = nil
        machine.reset()
        refresh()
    }

    /// Clears hover highlights, magnifier, and AX state when the cursor leaves this display.
    func clearHover() {
        bumpAXEpoch(cancelPending: hasInFlightAXQuery)
        lastMousePoint = nil
        lastTier1LocalRect = nil
        lastRefinedLocalRect = nil
        lastRefinedIsOverlayElement = false
        lastAXQueryPoint = nil
        lastSampledPixel = nil
        lastCursorKind = nil
        if machine.isHovering {
            machine.updateHover(detectedRect: nil)
        }
        refresh()
    }

    /// Seeds hover detection and the magnifier at the current mouse location.
    func primeWithMouseLocation(_ globalPoint: CGPoint, allowClosedEdge: Bool = true) {
        let local = toLocal(globalPoint)
        guard containsPoint(local, allowClosedEdge: allowClosedEdge) else {
            clearHover()
            return
        }
        handleHover(at: clampedLocalPoint(local))
    }

    /// Applies a Tier 2 (AX) element rect (or `nil` when no sub-element matched) while hovering.
    func applyRefinedElementRect(
        _ globalRect: CGRect?,
        forGlobalPoint globalPoint: CGPoint,
        isOverlayElement: Bool = false,
        epoch: UInt64? = nil
    ) {
        if let epoch, epoch != axEpoch { return }
        guard machine.isHovering, let current = lastMousePoint else { return }

        let localQueryPoint = toLocal(globalPoint)
        if let lastQuery = lastAXQueryPoint,
           hypot(localQueryPoint.x - lastQuery.x, localQueryPoint.y - lastQuery.y) < 0.5 {
            hasInFlightAXQuery = false
        }

        if let globalRect {
            let localRect = globalRect.standardized.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
            guard localRect.insetBy(dx: -1, dy: -1).contains(current) else { return }
            if isOverlayElement {
                if let shouldQuery = shouldQueryElementRect, !shouldQuery(toGlobal(current)) {
                    return
                }
            } else if let tier1 = lastTier1LocalRect {
                guard tier1.insetBy(dx: -2, dy: -2).contains(localRect) else { return }
            }

            // Prevent a stale outer container queried outside the active refined element from
            // bouncing the highlight back out once the cursor is already inside the smaller element.
            if let existing = lastRefinedLocalRect,
               existing.contains(current),
               !existing.contains(localQueryPoint),
               localRect.insetBy(dx: -1, dy: -1).contains(existing),
               !rectsNearlyEqual(localRect, existing) {
                return
            }

            let clamped = localRect.intersection(bounds)
            guard !clamped.isNull, !clamped.isEmpty else { return }
            if rectsNearlyEqual(localRect, lastRefinedLocalRect) &&
               lastRefinedIsOverlayElement == isOverlayElement &&
               rectsNearlyEqual(clamped, machine.highlightedRect) {
                return
            }
            lastRefinedLocalRect = localRect
            lastRefinedIsOverlayElement = isOverlayElement
            machine.updateHover(detectedRect: localRect)
            refresh()
        } else {
            if let refined = lastRefinedLocalRect, refined.contains(current) {
                return
            }
            // Drop stale `nil` replies from an earlier gap point after a newer AX query has moved on.
            let referencePoint = lastAXQueryPoint ?? current
            if hypot(localQueryPoint.x - referencePoint.x, localQueryPoint.y - referencePoint.y) > Self.axRequeryDistance {
                return
            }
            if lastRefinedLocalRect != nil {
                lastRefinedLocalRect = nil
                lastRefinedIsOverlayElement = false
                machine.updateHover(detectedRect: lastTier1LocalRect ?? bounds)
                refresh()
            }
        }
    }

    private static func unionRect(_ lhs: CGRect?, _ rhs: CGRect?) -> CGRect? {
        switch (lhs, rhs) {
        case let (.some(a), .some(b)): a.union(b)
        case let (.some(a), .none): a
        case let (.none, .some(b)): b
        case (.none, .none): nil
        }
    }

    private func setSelectedAnnotationID(_ id: UUID?) {
        guard annotations.selectedID != id else { return }
        resetScrollUndoCoalescing()
        let oldBox = annotations.selectedItem?.boundingBox
        annotations.selectedID = id
        let newBox = annotations.selectedItem?.boundingBox
        invalidateAnnotations(rect: Self.unionRect(oldBox, newBox))
    }

    private func hitEditableAnnotation(at point: CGPoint) -> AnnotationItem? {
        switch activeTool {
        case .select:
            return annotations.hitTestItem(at: point)
        case .pen, .highlighter:
            return nil
        case .rectangle, .ellipse, .arrow, .mosaic, .text, .counter:
            if let selected = annotations.selectedItem, selected.hitTest(point: point) {
                return selected
            }
            return annotations.items.reversed().first {
                $0.kind.tool == activeTool && $0.hitTest(point: point)
            }
        }
    }

    func setActiveTool(_ tool: AnnotationTool) {
        commitInlineTextEditor()
        resetScrollUndoCoalescing()
        activeTool = tool
        if tool != .select {
            setSelectedAnnotationID(nil)
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
        resetScrollUndoCoalescing()
        currentStyle = style
        onStyleUpdated?(style)
        if let editor = inlineEditor {
            applyStyleToInlineEditor(editor, style: style)
            resizeInlineEditor(editor)
        } else {
            let oldBox = annotations.selectedItem?.boundingBox
            if annotations.updateSelectedStyle({ $0 = style }) {
                let newBox = annotations.selectedItem?.boundingBox
                invalidateAnnotations(rect: Self.unionRect(oldBox, newBox))
            }
        }
        refresh()
    }

    private func applyStyleToInlineEditor(_ editor: NSTextField, style: AnnotationStyle) {
        let font = NSFont.systemFont(ofSize: style.size.fontSize, weight: .bold)
        let color = style.color.nsColor
        let luminance = 0.299 * style.color.r + 0.587 * style.color.g + 0.114 * style.color.b
        let isDarkInk = luminance < 0.2
        editor.appearance = NSAppearance(named: isDarkInk ? .aqua : .darkAqua)
        editor.backgroundColor = isDarkInk
            ? NSColor.white.withAlphaComponent(0.76)
            : NSColor.black.withAlphaComponent(0.38)
        editor.textColor = color
        editor.font = font
        if let fieldEditor = editor.currentEditor() as? NSTextView {
            fieldEditor.textColor = color
            fieldEditor.font = font
            fieldEditor.insertionPointColor = color
            var typing = fieldEditor.typingAttributes
            typing[.foregroundColor] = color
            typing[.font] = font
            fieldEditor.typingAttributes = typing
        }
    }

    private func handleSliderSizeEditingStateChanged(_ editing: Bool) {
        if editing {
            resetScrollUndoCoalescing()
            isSliderEditingSize = true
            sliderUndoRecorded = false
            sliderUndoItemID = annotations.selectedID
        } else {
            isSliderEditingSize = false
            sliderUndoRecorded = false
            sliderUndoItemID = nil
        }
    }

    private func handleToolbarSizeChanged(_ size: StrokeSize) {
        if isSliderEditingSize {
            let targetID = annotations.selectedID
            let shouldRecordUndo = targetID != nil && (!sliderUndoRecorded || sliderUndoItemID != targetID)
            let mutated = applyStrokeSize(size, recordUndo: shouldRecordUndo, showHUD: false)
            if shouldRecordUndo, mutated {
                sliderUndoRecorded = true
                sliderUndoItemID = targetID
            }
        } else {
            applyStrokeSize(size, recordUndo: true, showHUD: false)
        }
    }

    @discardableResult
    func applyStrokeSize(_ size: StrokeSize, recordUndo: Bool, showHUD: Bool) -> Bool {
        currentStyle.size = size
        onStyleUpdated?(currentStyle)

        var mutatedSelected = false
        if let editor = inlineEditor {
            applyStyleToInlineEditor(editor, style: currentStyle)
            resizeInlineEditor(editor)
        } else {
            let oldSelectedBox = annotations.selectedItem?.boundingBox
            if annotations.updateSelectedStyle(recordUndo: recordUndo, { $0.size = size }) {
                mutatedSelected = true
                let newSelectedBox = annotations.selectedItem?.boundingBox
                invalidateAnnotations(rect: Self.unionRect(oldSelectedBox, newSelectedBox))
            }
        }

        if var draft = annotations.draft {
            let oldDraftBox = draft.boundingBox
            draft.style.size = size
            annotations.draft = draft
            invalidateAnnotations(rect: Self.unionRect(oldDraftBox, draft.boundingBox))
        }

        refresh()

        if showHUD {
            let selectedItem = annotations.selectedItem
            let effectiveTool = selectedItem?.kind.tool ?? (isEditingText ? .text : activeTool)
            let effectiveStyle = selectedItem?.style ?? currentStyle
            sizeHUD.show(
                size: size,
                tool: effectiveTool,
                mosaicMode: effectiveStyle.mosaicMode,
                color: effectiveTool.usesColor ? effectiveStyle.color : nil,
                near: lastMousePoint,
                toolbarFrame: toolbar.isHidden ? nil : toolbar.frame,
                in: bounds,
                topInset: topInset
            )
        }
        return mutatedSelected
    }

    private func resetScrollUndoCoalescing() {
        scrollUndoActive = false
        scrollUndoItemID = nil
        lastScrollUndoTimestamp = 0
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        if (shouldBecomeKeyOnHover?() ?? true) && window?.isKeyWindow == false {
            window?.makeKey()
            if !isEditingText {
                window?.makeFirstResponder(self)
            }
        }
        lastCursorKind = nil
        handleHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if window != nil {
            if containsPoint(toLocal(NSEvent.mouseLocation), allowClosedEdge: true) {
                return
            }
        } else {
            let local = convert(event.locationInWindow, from: nil)
            guard !containsPoint(local, allowClosedEdge: true) else { return }
        }
        if machine.isHovering {
            clearHover()
        } else {
            lastMousePoint = nil
            lastAXQueryPoint = nil
            lastCursorKind = nil
            refresh()
        }
    }

    override func mouseDown(with event: NSEvent) {
        resetScrollUndoCoalescing()
        sizeHUD.hideImmediately()
        window?.makeKey()
        if !isEditingText {
            window?.makeFirstResponder(self)
        }
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point

        if inlineEditor != nil {
            commitInlineTextEditor()
            activeDrag = .none
            refresh()
            return
        }

        if machine.isHovering {
            if machine.highlightedRect == nil ||
               !(machine.highlightedRect?.insetBy(dx: -1, dy: -1).contains(point) ?? false) {
                let tier1Local = hoverRectProvider?(toGlobal(point)).map {
                    $0.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
                }
                lastTier1LocalRect = tier1Local
                machine.updateHover(detectedRect: tier1Local ?? bounds)
            }
            bumpAXEpoch(cancelPending: hasInFlightAXQuery)
            lastRefinedLocalRect = nil
            lastRefinedIsOverlayElement = false
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
        // Selected annotation resize handles take precedence even while a drawing tool remains active.
        if let selected = annotations.selectedItem,
           let handle = selected.hitTestHandle(at: point, radius: 8) {
            activeDrag = .resizingAnnotation(initial: selected, handle: handle, didPushUndo: false)
            refresh()
            return
        }

        if SelectionStateMachine.hitTestHandle(at: point, rect: selection, radius: machine.handleHitRadius) != nil {
            setSelectedAnnotationID(nil)
            activeDrag = .selectionMachine
            machine.mouseDown(at: point)
            refresh()
            return
        }

        if activeTool == .select {
            if selection.insetBy(dx: -4, dy: -4).contains(point),
               let hit = hitEditableAnnotation(at: point) {
                setSelectedAnnotationID(hit.id)
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

            setSelectedAnnotationID(nil)
            if clickCount >= 2, selection.contains(point) {
                finish(.copy(selection))
                return
            }
            activeDrag = .selectionMachine
            machine.mouseDown(at: point)
            refresh()
            return
        }

        guard selection.contains(point) else {
            setSelectedAnnotationID(nil)
            activeDrag = .none
            refresh()
            return
        }

        if let hit = hitEditableAnnotation(at: point) {
            setSelectedAnnotationID(hit.id)
            if hit.kind.tool == activeTool {
                currentStyle = hit.style
            }
            if clickCount >= 2, case let .text(origin, content) = hit.kind {
                activeDrag = .none
                beginInlineTextEditor(at: origin, existing: hit, initialText: content, in: selection)
                return
            }
            activeDrag = .movingAnnotation(initial: hit, startPoint: point, didPushUndo: false)
            refresh()
            return
        }

        setSelectedAnnotationID(nil)
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
            invalidateAnnotations(rect: badge.boundingBox)
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
            machine.mouseDragged(to: point, constrainSquare: constrain, moveOrigin: isSpaceDown)
        case let .drawing(tool, origin):
            let clamped = clampToSelection(point)
            updateDraft(tool: tool, origin: origin, current: clamped, constrain: constrain)
            invalidateAnnotations(rect: annotations.draft?.boundingBox)
        case let .movingAnnotation(initial, startPoint, didPushUndo):
            let rawDelta = CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y)
            let delta = selectedRect.map {
                Self.clampedTranslation(for: initial.boundingBox, desired: rawDelta, within: $0)
            } ?? rawDelta
            if !didPushUndo && hypot(delta.width, delta.height) >= 1 {
                annotations.beginMutationSnapshot()
                activeDrag = .movingAnnotation(initial: initial, startPoint: startPoint, didPushUndo: true)
            }
            if case let .movingAnnotation(_, _, pushed) = activeDrag, pushed {
                let updated = initial.translated(by: delta)
                annotations.replaceItem(updated, recordUndo: false)
                invalidateAnnotations(rect: updated.boundingBox)
            }
        case let .resizingAnnotation(initial, handle, didPushUndo):
            if !didPushUndo {
                annotations.beginMutationSnapshot()
                activeDrag = .resizingAnnotation(initial: initial, handle: handle, didPushUndo: true)
            }
            let clamped = clampToSelection(point)
            let updated = initial.resized(handle: handle, to: clamped, constrain: constrain, within: selectedRect)
            annotations.replaceItem(updated, recordUndo: false)
            invalidateAnnotations(rect: updated.boundingBox)
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
            if selectionMode == .record, let rect = selectedRect {
                activeDrag = .none
                isSpaceDown = false
                finish(.record(rect))
                return
            }
        case let .drawing(tool, _):
            let rect = annotations.draft?.boundingBox
            if let draft = annotations.draft, Self.isMeaningfulDraft(draft, tool: tool) {
                annotations.commit(draft)
            } else {
                annotations.draft = nil
            }
            invalidateAnnotations(rect: rect)
        case .movingAnnotation, .resizingAnnotation:
            invalidateAnnotations(rect: annotations.selectedItem?.boundingBox)
        }

        activeDrag = .none
        isSpaceDown = false
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        if isEditingText {
            cancelInlineTextEditor()
            refresh()
            return
        }
        if !machine.isHovering {
            if activeTool.isDrawingTool {
                setActiveTool(.select)
                return
            }
            window?.makeKey()
            window?.makeFirstResponder(self)
            let local = convert(event.locationInWindow, from: nil)
            resetSelection()
            primeWithMouseLocation(toGlobal(local))
            return
        }
        if hasSiblingSelection?() == true {
            onBeginInteraction?()
            window?.makeKey()
            window?.makeFirstResponder(self)
            let local = convert(event.locationInWindow, from: nil)
            primeWithMouseLocation(toGlobal(local))
            return
        }
        onFinish?(.cancel)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.window == nil || event.window === window {
            let local = convert(event.locationInWindow, from: nil)
            if containsPoint(local, allowClosedEdge: true) {
                lastMousePoint = local
            }
        }
        let handled = handleScrollThickness(
            deltaY: event.scrollingDeltaY,
            deltaX: event.scrollingDeltaX,
            isPrecise: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            timestamp: event.timestamp
        )
        if !handled {
            super.scrollWheel(with: event)
        }
    }

    @discardableResult
    func handleScrollThickness(
        deltaY: CGFloat,
        deltaX: CGFloat = 0,
        isPrecise: Bool = true,
        isDirectionInverted: Bool = false,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = [],
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard selectedRect != nil else { return false }
        guard activeTool.showsStyleBar || annotations.selectedItem != nil || isEditingText else {
            return false
        }
        switch activeDrag {
        case .selectionMachine, .movingAnnotation, .resizingAnnotation:
            return false
        case .none, .drawing:
            break
        }
        guard momentumPhase.isEmpty else { return false }

        if phase.contains(.began) {
            resetScrollUndoCoalescing()
        }
        let isGestureEnd = phase.contains(.ended) || phase.contains(.cancelled)
        defer {
            if isGestureEnd {
                resetScrollUndoCoalescing()
            }
        }
        guard abs(deltaY) >= abs(deltaX), deltaY != 0 else {
            return isGestureEnd
        }

        // Physical upward scroll thickens and downward scroll thins regardless of Natural Scrolling.
        let upDelta = isDirectionInverted ? -deltaY : deltaY
        let progressDelta: CGFloat = isPrecise
            ? upDelta * 0.004
            : (upDelta > 0 ? 1 : -1) * 0.06

        let baseSize = annotations.selectedItem?.style.size ?? currentStyle.size
        let nextSize = baseSize.adjusted(byProgressDelta: progressDelta)

        let targetID = annotations.selectedID
        let timedOut = phase.isEmpty && (!scrollUndoActive || (timestamp - lastScrollUndoTimestamp) >= 0.45)
        let selectionChanged = targetID != scrollUndoItemID
        let shouldRecordUndo = !isGestureEnd
            && targetID != nil
            && (!scrollUndoActive || timedOut || selectionChanged)
            && nextSize != baseSize

        let mutated = applyStrokeSize(nextSize, recordUndo: shouldRecordUndo, showHUD: true)
        if !isGestureEnd, let targetID, mutated {
            scrollUndoActive = true
            scrollUndoItemID = targetID
            lastScrollUndoTimestamp = timestamp
        } else if !isGestureEnd, targetID == nil {
            lastScrollUndoTimestamp = timestamp
        }
        return true
    }

    private func handleHover(at point: CGPoint) {
        lastMousePoint = point
        guard machine.isHovering else {
            updateCursor()
            return
        }
        onHoverActive?()
        if (shouldBecomeKeyOnHover?() ?? true) && window?.isKeyWindow == false {
            window?.makeKey()
            if !isEditingText {
                window?.makeFirstResponder(self)
            }
        }

        let global = toGlobal(point)
        let tier1Local = hoverRectProvider?(global).map {
            $0.offsetBy(dx: -snapshot.screenFrame.minX, dy: -snapshot.screenFrame.minY)
        }
        let canRequestAX = shouldQueryElementRect?(global) ?? (tier1Local != nil)
        let sameWindow = rectsNearlyEqual(tier1Local, lastTier1LocalRect)
        lastTier1LocalRect = tier1Local

        var forceAXRequery = false
        if !canRequestAX {
            bumpAXEpoch(cancelPending: hasInFlightAXQuery)
            lastRefinedLocalRect = nil
            lastRefinedIsOverlayElement = false
            lastAXQueryPoint = nil
            machine.updateHover(detectedRect: tier1Local ?? bounds)
        } else if !sameWindow {
            if lastRefinedIsOverlayElement,
               let refined = lastRefinedLocalRect,
               refined.contains(point) {
                // Keep a fallback overlay card stable when crossing an underlying window boundary
                // and immediately re-verify via AX rather than flashing the window behind it.
                machine.updateHover(detectedRect: refined)
                forceAXRequery = true
            } else {
                bumpAXEpoch(cancelPending: hasInFlightAXQuery)
                lastRefinedLocalRect = nil
                lastRefinedIsOverlayElement = false
                lastAXQueryPoint = nil
                machine.updateHover(detectedRect: tier1Local ?? bounds)
            }
        } else if let refined = lastRefinedLocalRect {
            if refined.contains(point) {
                machine.updateHover(detectedRect: refined)
            } else {
                let canBridgeGap = (tier1Local != nil || lastRefinedIsOverlayElement) &&
                    refined.insetBy(dx: -Self.axGapBridgeMargin, dy: -Self.axGapBridgeMargin).contains(point)
                if canBridgeGap {
                    machine.updateHover(detectedRect: refined)
                    // Stepping across the element edge by < axRequeryDistance must still trigger AX
                    // so the stale element does not remain pinned in the gap bridge indefinitely.
                    if let prevQuery = lastAXQueryPoint, refined.contains(prevQuery) {
                        forceAXRequery = true
                    }
                } else {
                    lastRefinedLocalRect = nil
                    lastRefinedIsOverlayElement = false
                    machine.updateHover(detectedRect: tier1Local ?? bounds)
                    forceAXRequery = true
                }
            }
        } else {
            machine.updateHover(detectedRect: tier1Local ?? bounds)
        }

        if canRequestAX && (forceAXRequery || shouldRequestAX(at: point)) {
            lastAXQueryPoint = point
            hasInFlightAXQuery = true
            elementRectRequester?(global)
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
        let selectionBounds = selectedRect
        switch tool {
        case .rectangle:
            draft.kind = .rectangle(AnnotationItem.constrainedRect(from: origin, to: current, square: constrain, within: selectionBounds))
        case .ellipse:
            draft.kind = .ellipse(AnnotationItem.constrainedRect(from: origin, to: current, square: constrain, within: selectionBounds))
        case .mosaic:
            draft.kind = .mosaic(
                AnnotationItem.constrainedRect(from: origin, to: current, square: constrain, within: selectionBounds),
                currentStyle.mosaicMode
            )
        case .arrow:
            let end = AnnotationItem.constrainedEnd(from: origin, to: current, snapAngle: constrain, within: selectionBounds)
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

    private func bumpAXEpoch(cancelPending: Bool) {
        axEpoch &+= 1
        if cancelPending {
            hasInFlightAXQuery = false
            cancelElementRectRequests?()
        }
    }

    private func rectsNearlyEqual(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(a), .some(b)):
            return abs(a.minX - b.minX) < 0.25 &&
                   abs(a.minY - b.minY) < 0.25 &&
                   abs(a.width - b.width) < 0.25 &&
                   abs(a.height - b.height) < 0.25
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
        field.appearance = NSAppearance(named: .darkAqua)
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
        editingOriginalStyle = style
        inlineEditor = field
        annotationView.editingTextItemID = existing?.id
        invalidateAnnotationCanvas()

        addSubview(field)
        resizeInlineEditor(field, clampedTo: selection)
        window?.makeFirstResponder(field)
        applyStyleToInlineEditor(field, style: style)
        refresh()
    }

    private func resizeInlineEditor(_ field: NSTextField, clampedTo selectionRect: CGRect? = nil) {
        guard let origin = editingTextOrigin else { return }
        let selection = selectionRect ?? self.selectedRect ?? bounds
        let liveText = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let maxAvailableWidth = max(24, selection.maxX - origin.x)
        let measureWidth = max(24, maxAvailableWidth - 12)
        let box = AnnotationItem.textBoundingBox(
            origin: origin,
            content: liveText,
            fontSize: currentStyle.size.fontSize,
            maxWidth: measureWidth
        )
        let desiredMinWidth = min(88, max(24, bounds.maxX - origin.x))
        let maxAllowedWidth = max(desiredMinWidth, min(maxAvailableWidth, bounds.maxX - origin.x))
        let width = min(max(box.width + 12, desiredMinWidth), maxAllowedWidth)
        let minHeight = ceil(currentStyle.size.fontSize * 1.45)
        let maxHeight = max(minHeight, max(28, origin.y - selection.minY))
        let height = min(max(box.height + 6, minHeight), maxHeight)
        let frameX = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - width))
        let frameY = min(max(origin.y - height, bounds.minY), max(bounds.minY, bounds.maxY - height))
        field.frame = CGRect(x: frameX, y: frameY, width: width, height: height)
    }

    private func commitInlineTextEditor() {
        guard let field = inlineEditor else { return }
        let liveText = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let trimmed = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = editingTextOrigin
        let existing = editingOriginalItem

        inlineEditor = nil
        editingTextOrigin = nil
        editingOriginalItem = nil
        editingOriginalStyle = nil
        annotationView.editingTextItemID = nil
        field.delegate = nil
        field.removeFromSuperview()

        if let existing {
            if trimmed.isEmpty {
                annotations.selectedID = existing.id
                annotations.deleteSelected()
            } else if let origin {
                var updated = existing
                updated.kind = .text(origin: origin, content: liveText)
                updated.style = currentStyle
                annotations.replaceItem(updated, recordUndo: true)
                annotations.selectedID = updated.id
            }
        } else if !trimmed.isEmpty, let origin {
            let item = AnnotationItem(kind: .text(origin: origin, content: liveText), style: currentStyle)
            annotations.commit(item)
        }

        window?.makeFirstResponder(self)
        invalidateAnnotationCanvas()
        refresh()
    }

    private func cancelInlineTextEditor() {
        guard let field = inlineEditor else { return }
        let originalStyle = editingOriginalStyle
        let wasEditingExisting = editingOriginalItem != nil
        inlineEditor = nil
        editingTextOrigin = nil
        editingOriginalItem = nil
        editingOriginalStyle = nil
        annotationView.editingTextItemID = nil
        field.delegate = nil
        field.removeFromSuperview()
        if wasEditingExisting, let originalStyle {
            currentStyle = originalStyle
        }
        window?.makeFirstResponder(self)
        invalidateAnnotationCanvas()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = inlineEditor else { return }
        resizeInlineEditor(field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard inlineEditor != nil else { return }
        commitInlineTextEditor()
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

    override func cancelOperation(_ sender: Any?) {
        if isEditingText {
            cancelInlineTextEditor()
            refresh()
            return
        }
        onFinish?(.cancel)
    }

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
                resetScrollUndoCoalescing()
                invalidateAnnotationCanvas()
                refresh()
            }
            return true
        }

        if flags == [.command, .shift], char == "s", let rect = selectedRect {
            finish(.quickSave(rect))
            return true
        }

        guard flags == .command else { return false }

        switch char {
        case "a":
            if machine.isHovering {
                bumpAXEpoch(cancelPending: hasInFlightAXQuery)
                onBeginInteraction?()
                machine.select(bounds)
                lastRefinedLocalRect = nil
                lastRefinedIsOverlayElement = false
                lastAXQueryPoint = nil
                if selectionMode == .record {
                    finish(.record(bounds))
                    return true
                }
                refresh()
                return true
            }
            return false
        case "c":
            if let rect = selectedRect {
                finish(.copy(rect))
                return true
            } else if machine.isHovering, let sample = currentSample {
                onFinish?(.copyColor(sample, colorFormat))
                return true
            }
            return false
        case "d":
            if let rect = selectedRect, let item = annotations.selectedItem {
                let oldBox = item.boundingBox
                let copy = duplicateAnnotation(item, within: rect)
                annotations.commit(copy)
                invalidateAnnotations(rect: Self.unionRect(oldBox, copy.boundingBox))
                refresh()
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
                    resetScrollUndoCoalescing()
                    invalidateAnnotationCanvas()
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

        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        let resizeEdges = flags.contains(.option) && selectedRect != nil && annotations.selectedItem == nil
        switch event.keyCode {
        case 53: // Escape
            onFinish?(.cancel)
            return
        case 49: // Space (moves in-flight selection origin while dragging)
            if case .dragging = machine.state {
                isSpaceDown = true
            }
            return
        case 36, 76: // Return, keypad Enter
            if let rect = selectedRect { finish(.pin(rect)) }
            return
        case 51, 117: // Delete, Forward Delete
            if selectedRect != nil, annotations.deleteSelected() {
                resetScrollUndoCoalescing()
                invalidateAnnotationCanvas()
                refresh()
                return
            }
        case 123:
            if resizeEdges { resizeSelection(dw: -step, dh: 0) } else { nudgeSelectionOrAnnotation(dx: -step, dy: 0) }
            return
        case 124:
            if resizeEdges { resizeSelection(dw: step, dh: 0) } else { nudgeSelectionOrAnnotation(dx: step, dy: 0) }
            return
        case 125:
            if resizeEdges { resizeSelection(dw: 0, dh: -step) } else { nudgeSelectionOrAnnotation(dx: 0, dy: -step) }
            return
        case 126:
            if resizeEdges { resizeSelection(dw: 0, dh: step) } else { nudgeSelectionOrAnnotation(dx: 0, dy: step) }
            return
        default: break
        }

        if handleCommandKeyEquivalent(with: event) {
            return
        }

        if flags.isEmpty, machine.isHovering, characters == "r",
           let prev = previousSelectionRect?.intersection(bounds),
           !prev.isNull, prev.width >= 2, prev.height >= 2 {
            bumpAXEpoch(cancelPending: hasInFlightAXQuery)
            onBeginInteraction?()
            machine.select(prev)
            lastRefinedLocalRect = nil
            lastRefinedIsOverlayElement = false
            lastAXQueryPoint = nil
            if selectionMode == .record {
                finish(.record(prev))
                return
            }
            refresh()
            return
        }

        if flags.isEmpty, let rect = selectedRect {
            if characters == "l" {
                finish(.scroll(rect))
                return
            }
            if characters == "r" {
                finish(.record(rect))
                return
            }
            if characters == "t" {
                finish(.ocr(rect))
                return
            }
            if characters == "v" {
                setActiveTool(.select)
                return
            }
            if let tool = AnnotationTool.forNumberKey(characters) {
                selectOrToggleTool(tool)
                return
            }
        }

        if (flags.isEmpty || flags == .shift) && characters == "c" {
            if machine.isHovering, !magnifier.isHidden, let sample = currentSample {
                onFinish?(.copyColor(sample, colorFormat))
            }
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceDown = false
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let changed = shift != isShiftDown
        if shift && !isShiftDown && machine.isHovering {
            colorFormat = colorFormat.next
            isShiftDown = shift
            refresh()
            return
        }
        isShiftDown = shift
        guard changed, let point = lastMousePoint else { return }
        switch activeDrag {
        case .selectionMachine:
            switch machine.state {
            case .dragging, .resizing:
                machine.mouseDragged(to: point, constrainSquare: shift, moveOrigin: isSpaceDown)
                refresh()
            case .hovering, .selected, .moving:
                break
            }
        case let .drawing(tool, origin):
            let clamped = clampToSelection(point)
            updateDraft(tool: tool, origin: origin, current: clamped, constrain: shift)
            invalidateAnnotations(rect: annotations.draft?.boundingBox)
            refresh()
        case let .resizingAnnotation(initial, handle, didPushUndo):
            if didPushUndo {
                let clamped = clampToSelection(point)
                let updated = initial.resized(handle: handle, to: clamped, constrain: shift, within: selectedRect)
                annotations.replaceItem(updated, recordUndo: false)
                invalidateAnnotations(rect: updated.boundingBox)
                refresh()
            }
        case .none, .movingAnnotation:
            break
        }
    }

    private var selectedRect: CGRect? {
        if case let .selected(rect) = machine.state { return rect }
        return nil
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        if machine.nudge(dx: dx, dy: dy) { refresh() }
    }

    private func resizeSelection(dw: CGFloat, dh: CGFloat) {
        if machine.resizeBy(dw: dw, dh: dh) { refresh() }
    }

    private func nudgeSelectionOrAnnotation(dx: CGFloat, dy: CGFloat) {
        if let selection = selectedRect, let selected = annotations.selectedItem {
            let oldBox = selected.boundingBox
            let clamped = Self.clampedTranslation(for: oldBox, desired: CGSize(width: dx, height: dy), within: selection)
            guard clamped.width != 0 || clamped.height != 0 else { return }
            let moved = selected.translated(by: clamped)
            annotations.replaceItem(moved, recordUndo: true)
            invalidateAnnotations(rect: oldBox.union(moved.boundingBox))
            refresh()
        } else {
            nudge(dx: dx, dy: dy)
        }
    }

    private func duplicateAnnotation(_ item: AnnotationItem, within selection: CGRect) -> AnnotationItem {
        let primary = Self.clampedTranslation(for: item.boundingBox, desired: CGSize(width: 14, height: -14), within: selection)
        let delta: CGSize
        if abs(primary.width) >= 1 || abs(primary.height) >= 1 {
            delta = primary
        } else {
            delta = Self.clampedTranslation(for: item.boundingBox, desired: CGSize(width: -14, height: 14), within: selection)
        }
        let shifted = item.translated(by: delta)
        let kind: AnnotationKind
        if case let .counter(center, _) = shifted.kind {
            kind = .counter(center: center, number: annotations.nextCounterNumber)
        } else {
            kind = shifted.kind
        }
        return AnnotationItem(kind: kind, style: shifted.style)
    }

    private static func clampedTranslation(for box: CGRect, desired: CGSize, within boundsRect: CGRect) -> CGSize {
        let dx: CGFloat = if box.width <= boundsRect.width {
            min(max(box.minX + desired.width, boundsRect.minX), boundsRect.maxX - box.width) - box.minX
        } else {
            desired.width
        }
        let dy: CGFloat = if box.height <= boundsRect.height {
            min(max(box.minY + desired.height, boundsRect.minY), boundsRect.maxY - box.height) - box.minY
        } else {
            desired.height
        }
        return CGSize(width: dx, height: dy)
    }

    private func handleToolbar(_ action: SnipToolbarAction) {
        switch action {
        case .undo:
            commitInlineTextEditor()
            if annotations.undo() {
                resetScrollUndoCoalescing()
                invalidateAnnotationCanvas()
                refresh()
            }
        case .redo:
            commitInlineTextEditor()
            if annotations.redo() {
                resetScrollUndoCoalescing()
                invalidateAnnotationCanvas()
                refresh()
            }
        case .scroll:
            if let rect = selectedRect { finish(.scroll(rect)) }
        case .record:
            if let rect = selectedRect { finish(.record(rect)) }
        case .ocr:
            if let rect = selectedRect { finish(.ocr(rect)) }
        case .pin:
            if let rect = selectedRect { finish(.pin(rect)) }
        case .done:
            break
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

    private var hasAnnotationContent: Bool {
        !annotations.items.isEmpty || annotations.draft != nil || isEditingText
    }

    private func invalidateAnnotations(rect: CGRect?) {
        hasRenderedAnnotations = true
        annotationView.invalidate(rect: rect)
    }

    private func invalidateAnnotationCanvas() {
        let hasContent = hasAnnotationContent
        if hasContent || hasRenderedAnnotations {
            annotationView.invalidateActiveRegion()
            hasRenderedAnnotations = hasContent
        }
    }

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
                let insetX = min(0.75, highlight.width / 2)
                let insetY = min(0.75, highlight.height / 2)
                let borderRect = highlight.insetBy(dx: insetX, dy: insetY)
                borderLayer.path = borderRect.isNull ? nil : CGPath(rect: borderRect, transform: nil)
                borderLayer.strokeColor = (isHovering ? NSColor.systemCyan : NSColor.systemBlue).cgColor
            } else {
                borderLayer.path = nil
            }

            cachedHighlightSizeText = sizeText(for: highlight)
            updateSizeLabel(for: highlight, sizeText: cachedHighlightSizeText)
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
                for handle in ResizeHandle.allCases {
                    let center = SelectionStateMachine.handlePoint(handle, for: rect)
                    handles.addRect(CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                }
                handleLayer.path = handles
            } else {
                handleLayer.path = nil
            }
            invalidateAnnotationCanvas()
        }

        updateMagnifier()
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
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixelRect = CoordinateConverter.appKitLocalRectToImagePixelRect(
            rect,
            screenSize: bounds.size,
            imageSize: imageSize
        )
        return "\(Int(pixelRect.width)) × \(Int(pixelRect.height))"
    }

    private func updateSizeLabel(for rect: CGRect?, sizeText: String) {
        guard let rect, !machine.isHovering || rect != bounds else {
            if !sizeLabel.isHidden { sizeLabel.isHidden = true }
            return
        }
        let formatted = " \(sizeText) "
        if formatted != lastSizeLabelText {
            lastSizeLabelText = formatted
            sizeLabel.stringValue = formatted
            sizeLabel.sizeToFit()
        }
        let usableMaxY = max(bounds.minY, bounds.maxY - topInset)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 4)
        if origin.y + sizeLabel.frame.height > usableMaxY {
            let insideTopY = min(rect.maxY, usableMaxY) - sizeLabel.frame.height - 4
            if insideTopY >= rect.minY {
                origin.y = insideTopY
            } else {
                origin.y = rect.minY - sizeLabel.frame.height - 4
            }
        }
        let maxOriginX = max(bounds.minX, bounds.maxX - sizeLabel.frame.width)
        let maxOriginY = max(bounds.minY, usableMaxY - sizeLabel.frame.height)
        origin.x = min(max(origin.x, bounds.minX), maxOriginX)
        origin.y = min(max(origin.y, bounds.minY), maxOriginY)
        sizeLabel.setFrameOrigin(origin)
        if sizeLabel.isHidden { sizeLabel.isHidden = false }
    }

    private func updateMagnifier() {
        let visibleState: Bool
        switch machine.state {
        case .hovering, .dragging, .resizing: visibleState = true
        case .selected, .moving: visibleState = false
        }
        guard visibleState, let point = lastMousePoint, containsPoint(point, allowClosedEdge: true) else {
            if !magnifier.isHidden { magnifier.isHidden = true }
            currentSample = nil
            lastSampledPixel = nil
            return
        }
        let image = snapshot.image
        guard image.width > 0, image.height > 0, point.x.isFinite, point.y.isFinite else {
            if !magnifier.isHidden { magnifier.isHidden = true }
            currentSample = nil
            lastSampledPixel = nil
            return
        }
        let scale = pixelScale
        let rawPixelX = (point.x * scale.width).rounded(.down)
        let rawPixelY = ((bounds.height - point.y) * scale.height).rounded(.down)
        guard rawPixelX.isFinite, rawPixelY.isFinite else { return }
        let pixelX = min(max(Int(rawPixelX), 0), image.width - 1)
        let pixelY = min(max(Int(rawPixelY), 0), image.height - 1)
        if lastSampledPixel?.x != pixelX || lastSampledPixel?.y != pixelY {
            lastSampledPixel = (pixelX, pixelY)
            currentSample = pixelSampler.samplePixel(from: image, pixelX: pixelX, pixelY: pixelY)
        }
        magnifier.update(
            image: image,
            pixelX: pixelX,
            pixelY: pixelY,
            sample: currentSample,
            format: colorFormat,
            sizeText: cachedHighlightSizeText
        )
        let nextFrame = PixelMagnifierView.frame(near: point, in: bounds, topInset: topInset)
        if magnifier.frame != nextFrame {
            magnifier.frame = nextFrame
        }
        if magnifier.isHidden {
            magnifier.isHidden = false
        }
    }

    private func moveToolbar(toProposedTopLeft topLeft: CGPoint) {
        guard selectedRect != nil else { return }
        let size = toolbar.isStyleBarVisible ? SnipActionToolbar.expandedSize : SnipActionToolbar.preferredSize
        let clamped = SnipActionToolbar.clampedFrame(
            anchoredAtTopLeft: topLeft,
            size: size,
            in: bounds,
            topInset: topInset
        )
        customToolbarTopLeft = CGPoint(x: clamped.minX, y: clamped.maxY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toolbar.frame = clamped
        CATransaction.commit()
    }

    private func handleToolbarDragStateChanged(isDragging: Bool, at point: CGPoint) {
        lastMousePoint = point
        if !isDragging {
            lastCursorKind = nil
        }
        updateCursor()
    }

    private func resetToolbarPosition() {
        customToolbarTopLeft = nil
        lastCursorKind = nil
        updateToolbar()
        updateCursor()
    }

    private func updateToolbar() {
        guard let rect = selectedRect else {
            switch machine.state {
            case .hovering:
                customToolbarTopLeft = nil
            case .dragging:
                if machine.selectionRect != nil {
                    customToolbarTopLeft = nil
                }
            case .selected, .moving, .resizing:
                break
            }
            if !toolbar.isHidden { toolbar.isHidden = true }
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

        let size = showStyleBar ? SnipActionToolbar.expandedSize : SnipActionToolbar.preferredSize
        let nextFrame: CGRect
        if let anchor = customToolbarTopLeft {
            nextFrame = SnipActionToolbar.clampedFrame(
                anchoredAtTopLeft: anchor,
                size: size,
                in: bounds,
                topInset: topInset
            )
        } else {
            nextFrame = SnipActionToolbar.frame(
                for: rect,
                in: bounds,
                topInset: topInset,
                showsStyleBar: showStyleBar
            )
        }
        if toolbar.isHidden || toolbar.frame != nextFrame {
            toolbar.frame = nextFrame
        }
        toolbar.isHidden = false
    }

    private func updateCursor() {
        guard let point = lastMousePoint else {
            if machine.isHovering {
                applyCursor(.crosshair, cursor: .crosshair)
            }
            return
        }
        if isEditingText, let editor = inlineEditor, editor.frame.contains(point) {
            applyCursor(.iBeam, cursor: .iBeam)
            return
        }
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
            if case .movingAnnotation = activeDrag {
                kind = .closedHand
                cursor = .closedHand
            } else if case let .resizingAnnotation(_, handle, _) = activeDrag {
                kind = .annotationResize(handle)
                cursor = Self.cursor(for: handle)
            } else if !toolbar.isHidden && toolbar.isDragging {
                kind = .closedHand
                cursor = .closedHand
            } else if !toolbar.isHidden && toolbar.hitsInteractiveArea(toolbarPoint) {
                if toolbar.hitsDragRegion(toolbarPoint) {
                    kind = .openHand
                    cursor = .openHand
                } else {
                    kind = .arrow
                    cursor = .arrow
                }
            } else if let selected = annotations.selectedItem, let handle = selected.hitTestHandle(at: point, radius: 8) {
                kind = .annotationResize(handle)
                cursor = Self.cursor(for: handle)
            } else if let handle = SelectionStateMachine.hitTestHandle(at: point, rect: rect, radius: machine.handleHitRadius) {
                kind = .resize(handle)
                cursor = Self.cursor(for: handle)
            } else if rect.contains(point), hitEditableAnnotation(at: point) != nil {
                kind = .openHand
                cursor = .openHand
            } else if activeTool.isDrawingTool && rect.contains(point) {
                if activeTool == .text {
                    kind = .iBeam
                    cursor = .iBeam
                } else {
                    kind = .crosshair
                    cursor = .crosshair
                }
            } else if rect.contains(point) {
                kind = .openHand
                cursor = .openHand
            } else {
                kind = .crosshair
                cursor = .crosshair
            }
        }
        applyCursor(kind, cursor: cursor)
    }

    private func applyCursor(_ kind: CursorKind, cursor: NSCursor) {
        guard kind != lastCursorKind || NSCursor.current != cursor else { return }
        lastCursorKind = kind
        cursor.set()
    }

    private static func cursor(for handle: AnnotationHandle) -> NSCursor {
        let mapped: ResizeHandle? = switch handle {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        case .start, .end: nil
        }
        return mapped.map(cursor(for:)) ?? .crosshair
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

    private func containsPoint(_ local: CGPoint, allowClosedEdge: Bool) -> Bool {
        if bounds.contains(local) { return true }
        guard allowClosedEdge else { return false }
        return local.x >= bounds.minX && local.x <= bounds.maxX &&
               local.y >= bounds.minY && local.y <= bounds.maxY
    }

    private func clampedLocalPoint(_ local: CGPoint) -> CGPoint {
        let maxX = max(bounds.minX, bounds.maxX - 0.001)
        let maxY = max(bounds.minY, bounds.maxY - 0.001)
        return CGPoint(
            x: min(max(local.x, bounds.minX), maxX),
            y: min(max(local.y, bounds.minY), maxY)
        )
    }

    private func toGlobal(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + snapshot.screenFrame.minX, y: local.y + snapshot.screenFrame.minY)
    }

    private func toLocal(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - snapshot.screenFrame.minX, y: global.y - snapshot.screenFrame.minY)
    }
}

/// Reusable 1×1 sRGB pixel sampler that avoids copying the full display framebuffer via `CGDataProviderCopyData`
/// at 120Hz while remaining color-managed across sRGB, Display P3, and IOSurface-backed snapshots.
@MainActor
private final class SnapshotPixelSampler {
    private let context: CGContext?

    init() {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    func samplePixel(from image: CGImage, pixelX: Int, pixelY: Int) -> CCXColorSample? {
        guard pixelX >= 0, pixelY >= 0, pixelX < image.width, pixelY < image.height,
              let context,
              let rawData = context.data,
              let patch = image.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1))
        else { return nil }

        let pixelBytes = rawData.assumingMemoryBound(to: UInt8.self)
        pixelBytes.initialize(repeating: 0, count: 4)
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = pixelBytes[0]
        let g = pixelBytes[1]
        let b = pixelBytes[2]
        let alpha = pixelBytes[3]
        func unpremultiply(_ value: UInt8) -> UInt8 {
            guard alpha > 0, alpha < 255 else { return alpha == 0 ? 0 : value }
            return UInt8(min(255, (Double(value) * 255 / Double(alpha)).rounded()))
        }
        return CCXColorSample(
            red: unpremultiply(r),
            green: unpremultiply(g),
            blue: unpremultiply(b),
            alpha: alpha,
            colorSpaceName: "sRGB"
        )
    }
}

private final class NonInteractiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class StrokeSizeHUDView: NSView {
    private static let hudHeight: CGFloat = 28
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    private var size: StrokeSize = .medium
    private var dotColor: AnnotationColor?
    private(set) var displayText = ""
    private var hideTask: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    func hideImmediately() {
        hideTask?.cancel()
        hideTask = nil
        isHidden = true
    }

    func show(
        size: StrokeSize,
        tool: AnnotationTool,
        mosaicMode: MosaicMode,
        color: AnnotationColor?,
        near mousePoint: CGPoint?,
        toolbarFrame: CGRect?,
        in bounds: CGRect,
        topInset: CGFloat
    ) {
        self.size = size
        self.dotColor = color
        self.displayText = Self.labelText(for: size, tool: tool, mosaicMode: mosaicMode)

        let textSize = (displayText as NSString).size(withAttributes: [.font: Self.labelFont])
        let width = max(68, ceil(textSize.width) + 38)
        let hudSize = CGSize(width: width, height: Self.hudHeight)
        let usableMaxY = max(bounds.minY + hudSize.height + 6, bounds.maxY - topInset)

        var origin: CGPoint
        if let point = mousePoint,
           bounds.contains(point),
           !(toolbarFrame?.insetBy(dx: -8, dy: -8).contains(point) ?? false) {
            origin = CGPoint(x: point.x + 16, y: point.y + 18)
        } else if let toolbarFrame {
            origin = CGPoint(x: toolbarFrame.midX - hudSize.width / 2, y: toolbarFrame.maxY + 8)
            if origin.y + hudSize.height > usableMaxY - 6 {
                origin.y = toolbarFrame.minY - hudSize.height - 8
            }
        } else {
            origin = CGPoint(x: bounds.midX - hudSize.width / 2, y: bounds.midY - hudSize.height / 2)
        }

        let maxX = max(bounds.minX + 6, bounds.maxX - hudSize.width - 6)
        let maxY = max(bounds.minY + 6, usableMaxY - hudSize.height - 6)
        origin.x = min(max(origin.x, bounds.minX + 6), maxX)
        origin.y = min(max(origin.y, bounds.minY + 6), maxY)

        frame = CGRect(origin: origin, size: hudSize)
        isHidden = false
        needsDisplay = true

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.isHidden = true
        }
    }

    static func labelText(for size: StrokeSize, tool: AnnotationTool, mosaicMode: MosaicMode) -> String {
        tool.formattedSizeHUDLabel(for: size, mosaicMode: mosaicMode)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bgRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.76).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()

        let midY = bounds.midY
        let dotDiameter = 4 + 9 * size.progress
        let dotRect = CGRect(
            x: 15 - dotDiameter / 2,
            y: midY - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        (dotColor?.nsColor ?? .white).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        if dotColor == nil || dotColor == .white || dotColor == .charcoal {
            let strokeColor: NSColor = dotColor == .charcoal
                ? NSColor.white.withAlphaComponent(0.4)
                : NSColor.black.withAlphaComponent(0.22)
            strokeColor.setStroke()
            let dotStroke = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.4, dy: 0.4))
            dotStroke.lineWidth = 0.8
            dotStroke.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.white,
        ]
        let text = displayText as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: 27, y: midY - textSize.height / 2), withAttributes: attrs)
    }
}
