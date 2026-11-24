import AppKit
import CCXAnnotate
import CCXCore

/// Hosts `AnnotationActionToolbar` as a non-activating floating child panel attached to a `PinPanel`.
@MainActor
final class PinToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(frame: CGRect, toolbar: AnnotationActionToolbar) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        toolbar.frame = CGRect(origin: .zero, size: frame.size)
        toolbar.autoresizingMask = [.width, .height]
        contentView = toolbar
    }
}

/// Manages live non-destructive annotation editing, inline text entry, mosaic caching, and the
/// floating `AnnotationActionToolbar` attached to an `.image` `PinPanel`.
@MainActor
final class PinAnnotationController: NSObject, NSTextFieldDelegate {
    enum MouseDownOutcome {
        case handled
        case passThroughDragPin
        case doubleClickedEmptyToCommit
    }

    private enum DragInteraction {
        case none
        case drawing(AnnotationTool, origin: CGPoint)
        case movingAnnotation(initial: AnnotationItem, startPoint: CGPoint, didPushUndo: Bool)
        case resizingAnnotation(initial: AnnotationItem, handle: AnnotationHandle, didPushUndo: Bool)
    }

    let document = AnnotationDocument()
    private(set) var baseImage: CGImage
    private(set) var isToolbarVisible = false
    private(set) var activeTool: AnnotationTool = .select
    var currentStyle: AnnotationStyle

    var onStyleUpdated: ((AnnotationStyle) -> Void)?
    var onNeedRedraw: (() -> Void)?
    var onShowHUD: ((String) -> Void)?
    var onToolbarAction: ((AnnotationToolbarAction) -> Void)?

    private var mosaicCache: MosaicImageCache?
    private var sessionEntrySnapshot: (items: [AnnotationItem], selectedID: UUID?)?
    private var toolbarPanel: PinToolbarPanel?
    private var toolbarView: AnnotationActionToolbar?
    private var customToolbarOffsetFromTopLeft: CGSize?

    private weak var hostPanel: PinPanel?
    private weak var hostContentView: NSView?

    private var activeDrag: DragInteraction = .none
    private var lastMouseCanvasPoint: CGPoint?
    private var lastCursor: NSCursor?

    private var inlineEditor: NSTextField?
    private var editingTextOrigin: CGPoint?
    private var editingOriginalItem: AnnotationItem?
    private var preEditStyle: AnnotationStyle?
    private var isEndingInlineEdit = false

    private var scrollUndoActive = false
    private var scrollUndoItemID: UUID?
    private var lastScrollUndoTimestamp: TimeInterval = 0

    private var isSliderEditingSize = false
    private var sliderUndoRecorded = false
    private var sliderUndoItemID: UUID?

    internal private(set) var bakeCountForTesting = 0

    var isEditingText: Bool { inlineEditor != nil }
    var hasSelectedAnnotation: Bool { document.selectedItem != nil }
    var toolbarPanelForTesting: NSPanel? { toolbarPanel }
    var toolbarViewForTesting: AnnotationActionToolbar? { toolbarView }
    var inlineEditorForTesting: NSTextField? { inlineEditor }

    init(baseImage: CGImage, initialStyle: AnnotationStyle) {
        self.baseImage = baseImage
        self.currentStyle = initialStyle
        super.init()
    }

    // MARK: - Session Lifecycle

    func replaceBaseImage(_ newBaseImage: CGImage) {
        baseImage = newBaseImage
        mosaicCache = nil
        document.clear()
        activeDrag = .none
    }

    func openToolbar(on panel: PinPanel, in contentView: NSView, initialStyle: AnnotationStyle) {
        hostPanel = panel
        hostContentView = contentView
        currentStyle = initialStyle
        activeTool = .select
        activeDrag = .none
        customToolbarOffsetFromTopLeft = nil
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
        sessionEntrySnapshot = (items: document.items, selectedID: document.selectedID)
        isToolbarVisible = true

        let toolbar = AnnotationActionToolbar(preset: .pin)
        toolbar.useScreenCoordinatesForDrag = true
        toolbar.onAction = { [weak self, weak panel] action in
            self?.handleToolbar(action, on: panel)
        }
        toolbar.onToolSelected = { [weak self, weak panel] tool in
            self?.selectOrToggleTool(tool, on: panel)
        }
        toolbar.onStyleChanged = { [weak self, weak panel] style in
            self?.applyStyle(style, on: panel)
        }
        toolbar.onSizeChanged = { [weak self, weak panel] size in
            self?.handleToolbarSizeChanged(size, on: panel)
        }
        toolbar.onSizeEditingStateChanged = { [weak self] editing in
            self?.handleSliderSizeEditingStateChanged(editing)
        }
        toolbar.onDragMoved = { [weak self, weak panel] topLeft in
            guard let self, let panel else { return }
            self.moveToolbar(toProposedTopLeft: topLeft, relativeTo: panel)
        }
        toolbar.onResetPosition = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.customToolbarOffsetFromTopLeft = nil
            self.repositionToolbar(for: panel)
        }

        let visible = Self.visibleFrame(for: panel)
        let initialFrame = AnnotationActionToolbar.frame(
            for: panel.frame,
            in: visible,
            topInset: 0,
            showsStyleBar: false,
            preset: .pin
        )
        let floating = PinToolbarPanel(frame: initialFrame, toolbar: toolbar)
        toolbarView = toolbar
        toolbarPanel = floating

        panel.addChildWindow(floating, ordered: .above)
        floating.orderFrontRegardless()
        syncToolbar(on: panel)
        repositionToolbar(for: panel)
    }

    func closeToolbar(on panel: PinPanel, commit: Bool) -> CGImage? {
        if isEditingText {
            if commit, let hostContentView {
                commitInlineTextEditor(in: hostContentView, baseSize: panel.baseSize, on: panel)
            } else {
                cancelInlineTextEditor(in: hostContentView)
            }
        }

        let didMutate = sessionEntrySnapshot.map { $0.items != document.items } ?? !document.items.isEmpty
        if !commit, let snapshot = sessionEntrySnapshot {
            document.replaceAll(items: snapshot.items, selectedID: snapshot.selectedID)
        }
        sessionEntrySnapshot = nil
        isToolbarVisible = false
        activeTool = .select
        activeDrag = .none
        document.draft = nil
        lastMouseCanvasPoint = nil
        lastCursor = nil
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
        document.selectedID = nil

        detachAndCloseToolbarPanel(from: panel)
        NSCursor.arrow.set()

        let result: CGImage? = (commit && didMutate) ? bakedImage(baseSize: panel.baseSize) : nil
        mosaicCache = nil
        onNeedRedraw?()
        return result
    }

    /// Lightweight teardown when the owning `PinPanel` is closing (no wasted full-res bake).
    func teardownForClose(on panel: PinPanel) {
        if isEditingText {
            cancelInlineTextEditor(in: hostContentView)
        }
        sessionEntrySnapshot = nil
        isToolbarVisible = false
        activeTool = .select
        activeDrag = .none
        document.draft = nil
        document.selectedID = nil
        lastMouseCanvasPoint = nil
        lastCursor = nil
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
        detachAndCloseToolbarPanel(from: panel)
        mosaicCache = nil
        hostPanel = nil
        hostContentView = nil
        onStyleUpdated = nil
        onNeedRedraw = nil
        onShowHUD = nil
        onToolbarAction = nil
        NSCursor.arrow.set()
    }

    private func detachAndCloseToolbarPanel(from panel: PinPanel) {
        if let toolbar = toolbarView {
            toolbar.onAction = nil
            toolbar.onToolSelected = nil
            toolbar.onStyleChanged = nil
            toolbar.onSizeChanged = nil
            toolbar.onSizeEditingStateChanged = nil
            toolbar.onDragMoved = nil
            toolbar.onResetPosition = nil
        }
        if let floating = toolbarPanel {
            if panel.childWindows?.contains(floating) == true {
                panel.removeChildWindow(floating)
            }
            floating.close()
        }
        toolbarPanel = nil
        toolbarView = nil
        customToolbarOffsetFromTopLeft = nil
    }

    func handleParentWindowDidMove(for panel: PinPanel) {
        guard isToolbarVisible, !(toolbarView?.isDragging ?? false) else { return }
        repositionToolbar(for: panel)
    }

    func handleParentFrameDidChange(for panel: PinPanel) {
        guard isToolbarVisible else { return }
        repositionToolbar(for: panel)
        if let field = inlineEditor, let hostContentView {
            syncInlineEditorAppearance(field, in: hostContentView, baseSize: panel.baseSize)
        }
    }

    func handleParentWindowDidResignKey(for panel: PinPanel) {
        guard isToolbarVisible else { return }
        if case .none = activeDrag {
            return
        }
        activeDrag = .none
        if document.draft != nil {
            document.draft = nil
            onNeedRedraw?()
        }
    }

    func repositionToolbar(for panel: PinPanel) {
        guard isToolbarVisible, let floating = toolbarPanel, let toolbar = toolbarView else { return }
        syncToolbar(on: panel)
        let showStyleBar = shouldShowStyleBar
        let size = showStyleBar
            ? AnnotationActionToolbar.expandedSize(for: .pin)
            : AnnotationActionToolbar.preferredSize(for: .pin)
        let visible = Self.visibleFrame(for: panel)

        let nextFrame: CGRect
        if let offset = customToolbarOffsetFromTopLeft {
            let anchor = CGPoint(x: panel.frame.minX + offset.width, y: panel.frame.maxY + offset.height)
            nextFrame = AnnotationActionToolbar.clampedFrame(
                anchoredAtTopLeft: anchor,
                size: size,
                in: visible,
                topInset: 0
            )
        } else {
            nextFrame = AnnotationActionToolbar.frame(
                for: panel.frame,
                in: visible,
                topInset: 0,
                showsStyleBar: showStyleBar,
                preset: .pin
            )
        }

        if floating.frame != nextFrame {
            floating.setFrame(nextFrame, display: true)
            toolbar.frame = CGRect(origin: .zero, size: nextFrame.size)
            toolbar.layoutSubtreeIfNeeded()
        }
    }

    private func moveToolbar(toProposedTopLeft topLeft: CGPoint, relativeTo panel: PinPanel) {
        guard isToolbarVisible, let floating = toolbarPanel, let toolbar = toolbarView else { return }
        let size = toolbar.isStyleBarVisible
            ? AnnotationActionToolbar.expandedSize(for: .pin)
            : AnnotationActionToolbar.preferredSize(for: .pin)
        let proposedRect = CGRect(
            x: topLeft.x,
            y: topLeft.y - size.height,
            width: size.width,
            height: size.height
        )
        let visible = Self.visibleFrame(for: proposedRect) ?? Self.visibleFrame(for: panel)
        let clamped = AnnotationActionToolbar.clampedFrame(
            anchoredAtTopLeft: topLeft,
            size: size,
            in: visible,
            topInset: 0
        )
        customToolbarOffsetFromTopLeft = CGSize(
            width: clamped.minX - panel.frame.minX,
            height: clamped.maxY - panel.frame.maxY
        )
        floating.setFrame(clamped, display: true)
    }

    // MARK: - Rendering & Baking

    func drawLiveAnnotations(in context: CGContext, dirtyRect: CGRect? = nil, baseSize: CGSize) {
        guard baseSize.width.isFinite, baseSize.height.isFinite, baseSize.width > 0, baseSize.height > 0 else { return }
        let canvasBounds = CGRect(origin: .zero, size: baseSize)
        let cullPadding: CGFloat = 48
        context.saveGState()
        context.clip(to: canvasBounds)

        for item in document.items where item.id != editingOriginalItem?.id {
            if let dirtyRect, !item.boundingBox.insetBy(dx: -cullPadding, dy: -cullPadding).intersects(dirtyRect) {
                continue
            }
            AnnotationRenderer.draw(item, in: context, screenBounds: canvasBounds) { [self] mode, size in
                ensureMosaicCache().filteredImage(mode: mode, size: size, backingScale: backingScale(for: baseSize))
            }
        }
        if let draft = document.draft {
            AnnotationRenderer.draw(draft, in: context, screenBounds: canvasBounds) { [self] mode, size in
                ensureMosaicCache().filteredImage(mode: mode, size: size, backingScale: backingScale(for: baseSize))
            }
        }
        for item in document.items where item.id != editingOriginalItem?.id && item.id != document.selectedID {
            if case let .mosaic(raw, _) = item.kind {
                if let dirtyRect, !item.boundingBox.insetBy(dx: -cullPadding, dy: -cullPadding).intersects(dirtyRect) {
                    continue
                }
                AnnotationRenderer.drawMosaicGuide(for: raw, isDraft: false, in: context)
            }
        }
        if let draft = document.draft, case let .mosaic(raw, _) = draft.kind {
            AnnotationRenderer.drawMosaicGuide(for: raw, isDraft: true, in: context)
        }
        context.restoreGState()

        if let selected = document.selectedItem, selected.id != editingOriginalItem?.id {
            let shouldDrawChrome = dirtyRect.map {
                selected.boundingBox.insetBy(dx: -cullPadding, dy: -cullPadding).intersects($0)
            } ?? true
            if shouldDrawChrome {
                AnnotationRenderer.drawSelectionChrome(for: selected, in: context)
            }
        }
    }

    func bakedImage(baseSize: CGSize) -> CGImage {
        if isEditingText, let hostContentView {
            commitInlineTextEditor(in: hostContentView, baseSize: baseSize, on: hostPanel)
        }
        guard !document.items.isEmpty else { return baseImage }
        bakeCountForTesting += 1
        let hasMosaic = document.items.contains {
            if case .mosaic = $0.kind { return true }
            return false
        }
        return AnnotationRenderer.bake(
            baseImage: baseImage,
            localSelectionRect: CGRect(origin: .zero, size: baseSize),
            pixelCropRect: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height),
            screenSize: baseSize,
            document: document,
            mosaicCache: hasMosaic ? ensureMosaicCache() : nil
        ) ?? baseImage
    }

    // MARK: - Mouse Interactions

    func handleMouseDown(
        at viewPoint: CGPoint,
        clickCount: Int,
        in contentView: NSView,
        panel: PinPanel
    ) -> MouseDownOutcome {
        // Clear any orphaned drag/draft left by a lost mouseUp.
        if case .none = activeDrag {} else {
            activeDrag = .none
            document.draft = nil
        }

        let baseSize = panel.baseSize
        let canvasBounds = CGRect(origin: .zero, size: baseSize)
        let canvasPoint = toCanvas(viewPoint, in: contentView.bounds, baseSize: baseSize)
        lastMouseCanvasPoint = canvasPoint

        if inlineEditor != nil {
            commitInlineTextEditor(in: contentView, baseSize: baseSize, on: panel)
            activeDrag = .none
            onNeedRedraw?()
            repositionToolbar(for: panel)
            return .handled
        }

        let handleRadius = hitTolerance(in: contentView.bounds, baseSize: baseSize)
        if let selected = document.selectedItem,
           let handle = selected.hitTestHandle(at: canvasPoint, radius: handleRadius) {
            activeDrag = .resizingAnnotation(initial: selected, handle: handle, didPushUndo: false)
            onNeedRedraw?()
            updateCursor(at: viewPoint, in: contentView.bounds, baseSize: baseSize)
            return .handled
        }

        if let hit = hitEditableAnnotation(at: canvasPoint, tolerance: handleRadius) {
            setSelectedAnnotationID(hit.id, on: panel)
            if activeTool == .select || hit.kind.tool == activeTool {
                currentStyle = hit.style
                onStyleUpdated?(hit.style)
            }
            if clickCount >= 2, case let .text(origin, content) = hit.kind {
                activeDrag = .none
                beginInlineTextEditor(
                    at: origin,
                    existing: hit,
                    initialText: content,
                    canvasBounds: canvasBounds,
                    in: contentView,
                    panel: panel
                )
                return .handled
            }
            activeDrag = .movingAnnotation(initial: hit, startPoint: canvasPoint, didPushUndo: false)
            onNeedRedraw?()
            repositionToolbar(for: panel)
            updateCursor(at: viewPoint, in: contentView.bounds, baseSize: baseSize)
            return .handled
        }

        setSelectedAnnotationID(nil, on: panel)
        if activeTool == .select {
            activeDrag = .none
            if clickCount >= 2 {
                return .doubleClickedEmptyToCommit
            }
            onNeedRedraw?()
            repositionToolbar(for: panel)
            return .passThroughDragPin
        }

        switch activeTool {
        case .select:
            break
        case .counter:
            let badge = AnnotationItem(
                kind: .counter(center: canvasPoint, number: document.nextCounterNumber),
                style: currentStyle
            )
            document.commit(badge)
            activeDrag = .none
        case .text:
            activeDrag = .none
            let startOrigin = CGPoint(
                x: min(max(canvasPoint.x, canvasBounds.minX + 4), max(canvasBounds.minX + 4, canvasBounds.maxX - 84)),
                y: min(max(canvasPoint.y + currentStyle.size.fontSize * 0.55, canvasBounds.minY + currentStyle.size.fontSize * 1.4), canvasBounds.maxY - 4)
            )
            beginInlineTextEditor(
                at: startOrigin,
                existing: nil,
                initialText: "",
                canvasBounds: canvasBounds,
                in: contentView,
                panel: panel
            )
            return .handled
        case .rectangle, .ellipse, .mosaic:
            let kind: AnnotationKind = switch activeTool {
            case .rectangle: .rectangle(CGRect(origin: canvasPoint, size: .zero))
            case .ellipse: .ellipse(CGRect(origin: canvasPoint, size: .zero))
            default: .mosaic(CGRect(origin: canvasPoint, size: .zero), currentStyle.mosaicMode)
            }
            document.draft = AnnotationItem(kind: kind, style: currentStyle)
            activeDrag = .drawing(activeTool, origin: canvasPoint)
        case .arrow:
            document.draft = AnnotationItem(kind: .arrow(start: canvasPoint, end: canvasPoint), style: currentStyle)
            activeDrag = .drawing(.arrow, origin: canvasPoint)
        case .pen:
            document.draft = AnnotationItem(kind: .pen([canvasPoint]), style: currentStyle)
            activeDrag = .drawing(.pen, origin: canvasPoint)
        case .highlighter:
            document.draft = AnnotationItem(kind: .highlighter([canvasPoint]), style: currentStyle)
            activeDrag = .drawing(.highlighter, origin: canvasPoint)
        }

        onNeedRedraw?()
        repositionToolbar(for: panel)
        updateCursor(at: viewPoint, in: contentView.bounds, baseSize: baseSize)
        return .handled
    }

    func handleMouseDragged(
        at viewPoint: CGPoint,
        constrain: Bool,
        in contentView: NSView,
        panel: PinPanel
    ) {
        let baseSize = panel.baseSize
        let canvasBounds = CGRect(origin: .zero, size: baseSize)
        let canvasPoint = toCanvas(viewPoint, in: contentView.bounds, baseSize: baseSize)
        lastMouseCanvasPoint = canvasPoint

        switch activeDrag {
        case .none:
            return
        case let .drawing(tool, origin):
            updateDraft(tool: tool, origin: origin, current: canvasPoint, constrain: constrain)
        case let .movingAnnotation(initial, startPoint, didPushUndo):
            let rawDelta = CGSize(width: canvasPoint.x - startPoint.x, height: canvasPoint.y - startPoint.y)
            let delta = Self.clampedTranslation(for: initial.boundingBox, desired: rawDelta, within: canvasBounds)
            if !didPushUndo && hypot(delta.width, delta.height) >= 1 {
                document.beginMutationSnapshot()
                activeDrag = .movingAnnotation(initial: initial, startPoint: startPoint, didPushUndo: true)
            }
            if case let .movingAnnotation(_, _, pushed) = activeDrag, pushed {
                document.replaceItem(initial.translated(by: delta), recordUndo: false)
            }
        case let .resizingAnnotation(initial, handle, didPushUndo):
            if !didPushUndo {
                document.beginMutationSnapshot()
                activeDrag = .resizingAnnotation(initial: initial, handle: handle, didPushUndo: true)
            }
            let updated = initial.resized(handle: handle, to: canvasPoint, constrain: constrain, within: canvasBounds)
            document.replaceItem(updated, recordUndo: false)
        }

        onNeedRedraw?()
        updateCursor(at: viewPoint, in: contentView.bounds, baseSize: baseSize)
    }

    func handleMouseUp(at viewPoint: CGPoint, in contentView: NSView, panel: PinPanel) {
        let canvasPoint = toCanvas(viewPoint, in: contentView.bounds, baseSize: panel.baseSize)
        lastMouseCanvasPoint = canvasPoint

        if case let .drawing(tool, _) = activeDrag {
            if let draft = document.draft, Self.isMeaningfulDraft(draft, tool: tool) {
                document.commit(draft)
            } else {
                document.draft = nil
            }
        }

        activeDrag = .none
        onNeedRedraw?()
        repositionToolbar(for: panel)
        updateCursor(at: viewPoint, in: contentView.bounds, baseSize: panel.baseSize)
    }

    func handleMouseMoved(at viewPoint: CGPoint, in contentView: NSView, baseSize: CGSize) {
        lastMouseCanvasPoint = toCanvas(viewPoint, in: contentView.bounds, baseSize: baseSize)
        updateCursor(at: viewPoint, in: contentView.bounds, baseSize: baseSize)
    }

    func handleMouseExited() {
        lastMouseCanvasPoint = nil
        lastCursor = nil
        NSCursor.arrow.set()
    }

    /// Returns `true` when right-click closed an editor or exited an active drawing tool;
    /// returns `false` when in `.select` tool so the pin's context menu can appear.
    func handleRightMouseDown(on panel: PinPanel) -> Bool {
        if isEditingText {
            cancelInlineTextEditor(in: hostContentView)
            onNeedRedraw?()
            repositionToolbar(for: panel)
            return true
        }
        if activeTool.isDrawingTool {
            setActiveTool(.select, on: panel)
            return true
        }
        return false
    }

    // MARK: - Scroll Thickness & Keyboard

    @discardableResult
    func handleScrollThickness(_ event: NSEvent, on panel: PinPanel) -> Bool {
        guard shouldShowStyleBar else { return false }
        if case .none = activeDrag {} else { return false }
        // Consume trackpad momentum so leftover inertia never falls through to PinPanel zoom.
        guard event.momentumPhase.isEmpty else { return true }

        if event.phase.contains(.began) {
            resetScrollUndoCoalescing()
        }
        let isGestureEnd = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        defer {
            if isGestureEnd {
                resetScrollUndoCoalescing()
            }
        }
        let deltaY = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        guard deltaY.isFinite, deltaX.isFinite, abs(deltaY) >= abs(deltaX), deltaY != 0 else {
            return true
        }

        let upDelta = event.isDirectionInvertedFromDevice ? -deltaY : deltaY
        let progressDelta: CGFloat = event.hasPreciseScrollingDeltas
            ? upDelta * 0.004
            : (upDelta > 0 ? 1 : -1) * 0.06

        let baseSize = document.selectedItem?.style.size ?? currentStyle.size
        let nextSize = baseSize.adjusted(byProgressDelta: progressDelta)

        let targetID = document.selectedID
        let timedOut = event.phase.isEmpty && (!scrollUndoActive || (event.timestamp - lastScrollUndoTimestamp) >= 0.45)
        let selectionChanged = targetID != scrollUndoItemID
        let shouldRecordUndo = !isGestureEnd
            && !isEditingText
            && targetID != nil
            && (!scrollUndoActive || timedOut || selectionChanged)
            && nextSize != baseSize

        let mutated = applyStrokeSize(nextSize, recordUndo: shouldRecordUndo, showHUD: true, on: panel)
        if !isGestureEnd, let targetID, mutated {
            scrollUndoActive = true
            scrollUndoItemID = targetID
            lastScrollUndoTimestamp = event.timestamp
        } else if !isGestureEnd, targetID == nil {
            lastScrollUndoTimestamp = event.timestamp
        }
        return true
    }

    @discardableResult
    func duplicateSelectedAnnotation(on panel: PinPanel) -> Bool {
        guard !isEditingText, let item = document.selectedItem else { return false }
        let copy = duplicateAnnotation(item, within: CGRect(origin: .zero, size: panel.baseSize))
        document.commit(copy)
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
        onNeedRedraw?()
        repositionToolbar(for: panel)
        return true
    }

    func handleKeyDown(_ event: NSEvent, on panel: PinPanel) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if isEditingText {
            if event.keyCode == 53 {
                cancelInlineTextEditor(in: hostContentView)
                onNeedRedraw?()
                repositionToolbar(for: panel)
                return true
            }
            return false
        }

        if event.keyCode == 53 { // Escape: cancel session edits, keep pin open
            onToolbarAction?(.cancel)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter: commit & hide toolbar
            onToolbarAction?(.done)
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
            if document.deleteSelected() {
                resetScrollUndoCoalescing()
                resetSliderUndoCoalescing()
                onNeedRedraw?()
                repositionToolbar(for: panel)
                return true
            }
        }

        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        if let selected = document.selectedItem, (123...126).contains(event.keyCode) {
            let desired: CGSize = switch event.keyCode {
            case 123: CGSize(width: -step, height: 0)
            case 124: CGSize(width: step, height: 0)
            case 125: CGSize(width: 0, height: -step)
            case 126: CGSize(width: 0, height: step)
            default: .zero
            }
            let canvasBounds = CGRect(origin: .zero, size: panel.baseSize)
            let clamped = Self.clampedTranslation(for: selected.boundingBox, desired: desired, within: canvasBounds)
            if clamped.width != 0 || clamped.height != 0 {
                document.replaceItem(selected.translated(by: clamped), recordUndo: true)
                onNeedRedraw?()
            }
            return true
        }

        if flags == .command {
            if chars == "z" {
                performUndo(on: panel)
                return true
            }
            if chars == "d", duplicateSelectedAnnotation(on: panel) {
                return true
            }
        }
        if flags == [.command, .shift], chars == "z" {
            performRedo(on: panel)
            return true
        }

        if flags.isEmpty {
            if chars == "v" {
                setActiveTool(.select, on: panel)
                return true
            }
            if chars == "t" {
                onToolbarAction?(.ocr)
                return true
            }
            if let tool = AnnotationTool.forNumberKey(chars) {
                selectOrToggleTool(tool, on: panel)
                return true
            }
        }

        return false
    }

    func performUndo(on panel: PinPanel? = nil) {
        if let hostContentView {
            commitInlineTextEditor(in: hostContentView, baseSize: panel?.baseSize ?? hostPanel?.baseSize ?? .zero, on: panel ?? hostPanel)
        }
        guard document.undo() else { return }
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
        onNeedRedraw?()
        if let resolved = panel ?? hostPanel {
            repositionToolbar(for: resolved)
        }
    }

    func performRedo(on panel: PinPanel? = nil) {
        if let hostContentView {
            commitInlineTextEditor(in: hostContentView, baseSize: panel?.baseSize ?? hostPanel?.baseSize ?? .zero, on: panel ?? hostPanel)
        }
        guard document.redo() else { return }
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
        onNeedRedraw?()
        if let resolved = panel ?? hostPanel {
            repositionToolbar(for: resolved)
        }
    }

    // MARK: - Inline Text Editor

    func controlTextDidChange(_ obj: Notification) {
        guard let field = inlineEditor, let hostContentView, let hostPanel else { return }
        syncInlineEditorAppearance(field, in: hostContentView, baseSize: hostPanel.baseSize)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isEndingInlineEdit, inlineEditor != nil, let hostContentView, let hostPanel else { return }
        commitInlineTextEditor(in: hostContentView, baseSize: hostPanel.baseSize, on: hostPanel)
        repositionToolbar(for: hostPanel)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let mods = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if mods.contains(.shift) || mods.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                if let field = inlineEditor, let hostContentView, let hostPanel {
                    syncInlineEditorAppearance(field, in: hostContentView, baseSize: hostPanel.baseSize)
                }
                return true
            }
            if let hostContentView, let hostPanel {
                commitInlineTextEditor(in: hostContentView, baseSize: hostPanel.baseSize, on: hostPanel)
                repositionToolbar(for: hostPanel)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineTextEditor(in: hostContentView)
            onNeedRedraw?()
            if let hostPanel { repositionToolbar(for: hostPanel) }
            return true
        }
        return false
    }

    private func beginInlineTextEditor(
        at origin: CGPoint,
        existing: AnnotationItem?,
        initialText: String,
        canvasBounds: CGRect,
        in contentView: NSView,
        panel: PinPanel
    ) {
        cancelInlineTextEditor(in: contentView)
        preEditStyle = currentStyle
        let style = existing?.style ?? currentStyle
        currentStyle = style
        onStyleUpdated?(style)

        let zoomY = (canvasBounds.height > 0 && contentView.bounds.height.isFinite)
            ? contentView.bounds.height / canvasBounds.height
            : 1
        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.38)
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.font = NSFont.systemFont(ofSize: max(6, style.size.fontSize * zoomY), weight: .bold)
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
        contentView.addSubview(field)
        syncInlineEditorAppearance(field, in: contentView, baseSize: canvasBounds.size)

        panel.makeKey()
        panel.makeFirstResponder(field)
        syncInlineEditorAppearance(field, in: contentView, baseSize: canvasBounds.size)
        onNeedRedraw?()
        repositionToolbar(for: panel)
    }

    private func syncInlineEditorAppearance(_ field: NSTextField, in contentView: NSView, baseSize: CGSize) {
        guard let origin = editingTextOrigin,
              baseSize.width.isFinite, baseSize.height.isFinite,
              baseSize.width > 0, baseSize.height > 0,
              contentView.bounds.width.isFinite, contentView.bounds.height.isFinite
        else { return }
        let zoomX = contentView.bounds.width / baseSize.width
        let zoomY = contentView.bounds.height / baseSize.height
        let textForMeasure = field.stringValue.hasSuffix("\n")
            ? field.stringValue + " "
            : field.stringValue
        let box = AnnotationItem.textBoundingBox(
            origin: origin,
            content: textForMeasure,
            fontSize: currentStyle.size.fontSize
        )
        let availableWidth = max(24, baseSize.width - origin.x)
        let minWidth = min(88, availableWidth)
        let canvasWidth = min(max(box.width + 12, minWidth), availableWidth)

        let availableHeight = max(18, origin.y)
        let minHeight = min(ceil(currentStyle.size.fontSize * 1.45), availableHeight)
        let canvasHeight = min(max(box.height + 6, minHeight), availableHeight)

        let viewX = min(max(origin.x * zoomX, 0), max(0, contentView.bounds.width - canvasWidth * zoomX))
        let viewY = min(max((origin.y - canvasHeight) * zoomY, 0), max(0, contentView.bounds.height - canvasHeight * zoomY))
        let scaledFont = NSFont.systemFont(ofSize: max(6, currentStyle.size.fontSize * zoomY), weight: .bold)
        let textColor = currentStyle.color.nsColor
        let luminance = 0.299 * currentStyle.color.r + 0.587 * currentStyle.color.g + 0.114 * currentStyle.color.b
        let backdropColor = luminance < 0.2
            ? NSColor.white.withAlphaComponent(0.76)
            : NSColor.black.withAlphaComponent(0.38)

        field.font = scaledFont
        field.textColor = textColor
        field.backgroundColor = backdropColor
        field.frame = CGRect(x: viewX, y: viewY, width: canvasWidth * zoomX, height: canvasHeight * zoomY)

        if let editor = field.currentEditor() as? NSTextView {
            editor.font = scaledFont
            editor.textColor = textColor
            editor.insertionPointColor = textColor
            var typing = editor.typingAttributes
            typing[.font] = scaledFont
            typing[.foregroundColor] = textColor
            editor.typingAttributes = typing
            if let storage = editor.textStorage, storage.length > 0 {
                storage.addAttributes(
                    [.font: scaledFont, .foregroundColor: textColor],
                    range: NSRange(location: 0, length: storage.length)
                )
            }
        }
    }

    private func commitInlineTextEditor(in contentView: NSView, baseSize: CGSize, on panel: PinPanel?) {
        guard let field = inlineEditor else { return }
        isEndingInlineEdit = true
        defer { isEndingInlineEdit = false }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = editingTextOrigin
        let existing = editingOriginalItem

        field.delegate = nil
        field.removeFromSuperview()
        inlineEditor = nil
        editingTextOrigin = nil
        editingOriginalItem = nil
        preEditStyle = nil

        if let existing {
            if trimmed.isEmpty {
                document.selectedID = existing.id
                document.deleteSelected()
            } else if let origin {
                var updated = existing
                updated.kind = .text(origin: origin, content: field.stringValue)
                updated.style = currentStyle
                if updated != existing {
                    document.replaceItem(updated, recordUndo: true)
                }
                document.selectedID = updated.id
            }
        } else if !trimmed.isEmpty, let origin {
            let item = AnnotationItem(kind: .text(origin: origin, content: field.stringValue), style: currentStyle)
            document.commit(item)
        }

        panel?.makeFirstResponder(contentView)
        onNeedRedraw?()
    }

    private func cancelInlineTextEditor(in contentView: NSView?) {
        guard let field = inlineEditor else { return }
        isEndingInlineEdit = true
        defer { isEndingInlineEdit = false }

        field.delegate = nil
        field.removeFromSuperview()
        inlineEditor = nil
        editingTextOrigin = nil
        editingOriginalItem = nil
        if let restored = preEditStyle {
            currentStyle = restored
            onStyleUpdated?(restored)
        }
        preEditStyle = nil
        if let contentView {
            hostPanel?.makeFirstResponder(contentView)
        }
    }

    // MARK: - Private Tool & Style Helpers

    private var shouldShowStyleBar: Bool {
        activeTool.showsStyleBar || document.selectedItem != nil || isEditingText
    }

    private func ensureMosaicCache() -> MosaicImageCache {
        if let mosaicCache { return mosaicCache }
        let created = MosaicImageCache(baseImage: baseImage)
        mosaicCache = created
        return created
    }

    private func backingScale(for baseSize: CGSize) -> CGFloat {
        guard baseSize.width.isFinite, baseSize.width > 0 else { return 1 }
        return max(1, CGFloat(baseImage.width) / baseSize.width)
    }

    private func handleToolbar(_ action: AnnotationToolbarAction, on panel: PinPanel?) {
        switch action {
        case .undo:
            performUndo(on: panel)
        case .redo:
            performRedo(on: panel)
        case .scroll, .record, .pin:
            break
        case .ocr, .done, .copy, .save, .cancel:
            onToolbarAction?(action)
        }
    }

    private func syncToolbar(on panel: PinPanel?) {
        guard let toolbar = toolbarView else { return }
        let selectedItem = document.selectedItem
        let effectiveStyleTool = isEditingText ? .text : (selectedItem?.kind.tool ?? activeTool)
        let effectiveStyle = isEditingText ? currentStyle : (selectedItem?.style ?? currentStyle)
        toolbar.update(
            activeTool: activeTool,
            styleTool: effectiveStyleTool,
            style: effectiveStyle,
            showStyleBar: shouldShowStyleBar,
            canUndo: document.canUndo,
            canRedo: document.canRedo
        )
    }

    private func selectOrToggleTool(_ tool: AnnotationTool, on panel: PinPanel?) {
        if let hostContentView, isEditingText {
            commitInlineTextEditor(in: hostContentView, baseSize: panel?.baseSize ?? .zero, on: panel)
        }
        let target: AnnotationTool = (tool != .select && activeTool == tool) ? .select : tool
        setActiveTool(target, on: panel)
    }

    private func setActiveTool(_ tool: AnnotationTool, on panel: PinPanel?) {
        guard activeTool != tool else { return }
        activeTool = tool
        if tool.isDrawingTool {
            document.selectedID = nil
        }
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
        onNeedRedraw?()
        if let panel {
            repositionToolbar(for: panel)
            if let hostContentView, let last = lastMouseCanvasPoint {
                let viewPt = toView(last, in: hostContentView.bounds, baseSize: panel.baseSize)
                updateCursor(at: viewPt, in: hostContentView.bounds, baseSize: panel.baseSize)
            }
        }
    }

    private func applyStyle(_ style: AnnotationStyle, on panel: PinPanel?) {
        resetScrollUndoCoalescing()
        currentStyle = style
        onStyleUpdated?(style)
        if let field = inlineEditor, let hostContentView, let resolvedPanel = panel ?? hostPanel {
            syncInlineEditorAppearance(field, in: hostContentView, baseSize: resolvedPanel.baseSize)
        } else {
            document.updateSelectedStyle { $0 = style }
        }
        onNeedRedraw?()
        if let panel {
            repositionToolbar(for: panel)
        }
    }

    private func handleSliderSizeEditingStateChanged(_ editing: Bool) {
        if editing {
            resetScrollUndoCoalescing()
            isSliderEditingSize = true
            sliderUndoRecorded = false
            sliderUndoItemID = document.selectedID
        } else {
            resetSliderUndoCoalescing()
        }
    }

    private func handleToolbarSizeChanged(_ size: StrokeSize, on panel: PinPanel?) {
        if isSliderEditingSize {
            let targetID = document.selectedID
            let shouldRecordUndo = !isEditingText
                && targetID != nil
                && (!sliderUndoRecorded || sliderUndoItemID != targetID)
            let mutated = applyStrokeSize(size, recordUndo: shouldRecordUndo, showHUD: false, on: panel)
            if shouldRecordUndo, mutated {
                sliderUndoRecorded = true
                sliderUndoItemID = targetID
            }
        } else {
            applyStrokeSize(size, recordUndo: !isEditingText, showHUD: false, on: panel)
        }
    }

    @discardableResult
    private func applyStrokeSize(
        _ size: StrokeSize,
        recordUndo: Bool,
        showHUD: Bool,
        on panel: PinPanel?
    ) -> Bool {
        currentStyle.size = size
        onStyleUpdated?(currentStyle)

        let mutatedSelected: Bool
        if let field = inlineEditor, let hostContentView, let resolvedPanel = panel ?? hostPanel {
            syncInlineEditorAppearance(field, in: hostContentView, baseSize: resolvedPanel.baseSize)
            mutatedSelected = false
        } else {
            mutatedSelected = document.updateSelectedStyle(recordUndo: recordUndo) { $0.size = size }
        }

        if showHUD {
            let selectedItem = document.selectedItem
            let effectiveTool = isEditingText ? .text : (selectedItem?.kind.tool ?? activeTool)
            let effectiveStyle = isEditingText ? currentStyle : (selectedItem?.style ?? currentStyle)
            onShowHUD?(effectiveTool.formattedSizeHUDLabel(for: size, mosaicMode: effectiveStyle.mosaicMode))
        }

        onNeedRedraw?()
        if let panel {
            syncToolbar(on: panel)
        }
        return mutatedSelected
    }

    private func setSelectedAnnotationID(_ id: UUID?, on panel: PinPanel?) {
        guard document.selectedID != id else { return }
        document.selectedID = id
        resetScrollUndoCoalescing()
        resetSliderUndoCoalescing()
    }

    private func resetScrollUndoCoalescing() {
        scrollUndoActive = false
        scrollUndoItemID = nil
        lastScrollUndoTimestamp = 0
    }

    private func resetSliderUndoCoalescing() {
        isSliderEditingSize = false
        sliderUndoRecorded = false
        sliderUndoItemID = nil
    }

    private func hitEditableAnnotation(at point: CGPoint, tolerance: CGFloat) -> AnnotationItem? {
        switch activeTool {
        case .select:
            return document.items.reversed().first { $0.hitTest(point: point, tolerance: tolerance) }
        case .pen, .highlighter:
            return nil
        case .rectangle, .ellipse, .arrow, .mosaic, .text, .counter:
            if let selected = document.selectedItem, selected.hitTest(point: point, tolerance: tolerance) {
                return selected
            }
            return document.items.reversed().first {
                $0.kind.tool == activeTool && $0.hitTest(point: point, tolerance: tolerance)
            }
        }
    }

    private func updateDraft(tool: AnnotationTool, origin: CGPoint, current: CGPoint, constrain: Bool) {
        guard var draft = document.draft else { return }
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
            draft.kind = .arrow(start: origin, end: AnnotationItem.constrainedEnd(from: origin, to: current, snapAngle: constrain))
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
        document.draft = draft
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

    private func duplicateAnnotation(_ item: AnnotationItem, within canvasBounds: CGRect) -> AnnotationItem {
        let primary = Self.clampedTranslation(for: item.boundingBox, desired: CGSize(width: 14, height: -14), within: canvasBounds)
        let delta: CGSize = (abs(primary.width) >= 1 || abs(primary.height) >= 1)
            ? primary
            : Self.clampedTranslation(for: item.boundingBox, desired: CGSize(width: -14, height: 14), within: canvasBounds)
        let shifted = item.translated(by: delta)
        if case let .counter(center, _) = shifted.kind {
            return AnnotationItem(kind: .counter(center: center, number: document.nextCounterNumber), style: shifted.style)
        }
        return AnnotationItem(kind: shifted.kind, style: shifted.style)
    }

    private static func clampedTranslation(for box: CGRect, desired: CGSize, within boundsRect: CGRect) -> CGSize {
        guard PinLayout.isFiniteRect(box), PinLayout.isFiniteRect(boundsRect),
              desired.width.isFinite, desired.height.isFinite
        else { return .zero }
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

    private func toCanvas(_ viewPoint: CGPoint, in bounds: CGRect, baseSize: CGSize) -> CGPoint {
        guard baseSize.width.isFinite, baseSize.height.isFinite, baseSize.width > 0, baseSize.height > 0 else {
            return .zero
        }
        guard viewPoint.x.isFinite, viewPoint.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite
        else { return .zero }
        let sx = bounds.width > 0 ? baseSize.width / bounds.width : 1
        let sy = bounds.height > 0 ? baseSize.height / bounds.height : 1
        return CGPoint(
            x: min(max(viewPoint.x * sx, 0), baseSize.width),
            y: min(max(viewPoint.y * sy, 0), baseSize.height)
        )
    }

    private func toView(_ canvasPoint: CGPoint, in bounds: CGRect, baseSize: CGSize) -> CGPoint {
        guard canvasPoint.x.isFinite, canvasPoint.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              baseSize.width.isFinite, baseSize.height.isFinite
        else { return .zero }
        let vx = baseSize.width > 0 ? bounds.width / baseSize.width : 1
        let vy = baseSize.height > 0 ? bounds.height / baseSize.height : 1
        return CGPoint(x: canvasPoint.x * vx, y: canvasPoint.y * vy)
    }

    private func hitTolerance(in bounds: CGRect, baseSize: CGSize) -> CGFloat {
        guard bounds.width.isFinite, bounds.width > 0, baseSize.width.isFinite, baseSize.width > 0 else { return 8 }
        let scale = baseSize.width / bounds.width
        return max(4, min(20, 8 * scale))
    }

    private func updateCursor(at viewPoint: CGPoint, in bounds: CGRect, baseSize: CGSize) {
        guard isToolbarVisible else { return }
        if isEditingText, let editor = inlineEditor, editor.frame.contains(viewPoint) {
            setCursor(.iBeam)
            return
        }
        let canvasPoint = toCanvas(viewPoint, in: bounds, baseSize: baseSize)
        let tolerance = hitTolerance(in: bounds, baseSize: baseSize)

        let desired: NSCursor
        switch activeDrag {
        case .movingAnnotation:
            desired = .closedHand
        case let .resizingAnnotation(_, handle, _):
            desired = Self.cursor(for: handle)
        case .drawing:
            desired = .crosshair
        case .none:
            if let selected = document.selectedItem, let handle = selected.hitTestHandle(at: canvasPoint, radius: tolerance) {
                desired = Self.cursor(for: handle)
            } else if hitEditableAnnotation(at: canvasPoint, tolerance: tolerance) != nil {
                desired = .openHand
            } else if activeTool == .text {
                desired = .iBeam
            } else if activeTool.isDrawingTool {
                desired = .crosshair
            } else {
                desired = .arrow
            }
        }
        setCursor(desired)
    }

    private func setCursor(_ cursor: NSCursor) {
        guard lastCursor !== cursor || NSCursor.current != cursor else { return }
        lastCursor = cursor
        cursor.set()
    }

    private static func cursor(for handle: AnnotationHandle) -> NSCursor {
        let position: NSCursor.FrameResizePosition? = switch handle {
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
        return position.map { NSCursor.frameResize(position: $0, directions: .all) } ?? .crosshair
    }

    private static func visibleFrame(for panel: PinPanel) -> CGRect {
        visibleFrame(for: panel.frame)
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func visibleFrame(for rect: CGRect) -> CGRect? {
        let screens = NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        return PinLayout.bestScreenFrame(for: rect, in: screens)
    }
}
