import AppKit
import CCXAnnotate
import CCXCore

/// Always-on-top, non-activating floating window showing one pinned image, text, or color.
///
/// Interactions: drag to move, scroll to zoom (0.1x-10x, around the cursor),
/// Ctrl+scroll to change opacity, double-click an image pin to toggle its annotation toolbar
/// (or restore from a 72x72 thumbnail), Esc to close, Cmd+C to copy, Cmd+S to save,
/// right-click for the context menu.
public final class PinPanel: NSPanel, NSWindowDelegate {
    public private(set) var content: PinContent
    public private(set) var contentIdentity: PinContentIdentity
    public private(set) var state: PinState
    /// Unrotated, unzoomed content size in points.
    public private(set) var baseSize: CGSize

    var onClose: ((PinPanel) -> Void)?
    var onCopy: ((PinPanel) -> Void)?
    var onSave: ((PinPanel) -> Void)?
    var onQuickSave: ((PinPanel) -> Void)?
    var onDuplicate: ((PinPanel) -> Void)?
    var onCopyFormattedColor: ((PinPanel, ColorFormat) -> Void)?
    var onRecognizeText: ((PinPanel) -> Void)?
    var onHideAll: (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onUnlockAllClickThrough: (() -> Void)?
    var clickThroughCountProvider: (() -> Int)?
    var onStateChanged: ((PinPanel) -> Void)?
    var onToolbarWillOpen: ((PinPanel) -> Void)?
    var onAnnotationStyleChanged: ((AnnotationStyle) -> Void)?

    public var isToolbarVisible: Bool { annotationController?.isToolbarVisible ?? false }
    public var canShowAnnotationToolbar: Bool {
        if case .image = content { return true }
        return false
    }
    public var currentAnnotationStyle: AnnotationStyle {
        get { annotationController?.currentStyle ?? pendingAnnotationStyle }
        set {
            pendingAnnotationStyle = newValue
            annotationController?.currentStyle = newValue
        }
    }

    internal var toolbarPanelForTesting: NSPanel? { annotationController?.toolbarPanelForTesting }
    internal var toolbarViewForTesting: AnnotationActionToolbar? { annotationController?.toolbarViewForTesting }
    internal var annotationDocumentForTesting: AnnotationDocument? { annotationController?.document }
    internal var inlineEditorForTesting: NSTextField? { annotationController?.inlineEditorForTesting }
    internal var annotationBakeCountForTesting: Int { annotationController?.bakeCountForTesting ?? 0 }
    internal var hasAnnotationControllerForTesting: Bool { annotationController != nil }
    internal var activeAnnotationToolForTesting: AnnotationTool? { annotationController?.activeTool }
    internal var hoverToolbarButtonForTesting: NSButton? { pinView.hoverToolbarButton }
    internal var borderLayerForTesting: CALayer { pinView.borderLayerForTesting }
    internal var annotationOverlayViewForTesting: NSView { pinView.annotationOverlayViewForTesting }
    internal var hasTransparentCornersForTesting: Bool { pinView.hasTransparentCornersForTesting }
    internal private(set) var shadowInvalidationCountForTesting = 0

    override public func invalidateShadow() {
        shadowInvalidationCountForTesting += 1
        super.invalidateShadow()
    }

    private let pinView: PinContentView
    private var annotationController: PinAnnotationController?
    private var pendingAnnotationStyle = AnnotationStyle()
    private let originalHistoryEntryID: UUID?
    private var isApplyingFrameProgrammatically = false
    private var didClose = false

    /// - Parameters:
    ///   - frame: Initial window frame in AppKit global coordinates.
    public init(
        content: PinContent,
        frame: CGRect,
        state: PinState = PinState(),
        contentIdentity: PinContentIdentity? = nil
    ) {
        let resolvedIdentity = contentIdentity ?? content.defaultIdentity
        self.content = content
        self.contentIdentity = resolvedIdentity
        if case let .image(_, historyID) = resolvedIdentity {
            self.originalHistoryEntryID = historyID
        } else {
            self.originalHistoryEntryID = nil
        }
        self.state = state
        self.baseSize = PinLayout.baseSize(for: content)
        let safeFrame = PinLayout.isFiniteRect(frame)
            ? CGRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: max(1, frame.width),
                height: max(1, frame.height)
            )
            : CGRect(origin: .zero, size: PinLayout.frameSize(baseSize: self.baseSize, state: state))
        self.pinView = PinContentView(frame: CGRect(origin: .zero, size: safeFrame.size))
        super.init(
            contentRect: safeFrame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        title = CCXL10n.text("CCX Pin", zh: "CCX 贴图")
        delegate = self

        pinView.panel = self
        pinView.autoresizingMask = [.width, .height]
        contentView = pinView
        applyState(from: nil, resizeKeeping: nil)
    }

    override public var canBecomeKey: Bool { !state.isClickThrough }
    override public var canBecomeMain: Bool { false }

    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

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
        if state.isClickThrough && isKeyWindow {
            resignKey()
        }

        if let anchor {
            let size = PinLayout.frameSize(baseSize: baseSize, state: state)
            if size != frame.size {
                var target = PinLayout.resizedFrame(frame, to: size, keeping: anchor)
                if previous != nil {
                    target = PinLayout.clampedOriginToScreens(target, screens: NSScreen.screens.map(\.visibleFrame))
                }
                isApplyingFrameProgrammatically = true
                setFrame(target, display: false)
                isApplyingFrameProgrammatically = false
                annotationController?.handleParentFrameDidChange(for: self)
            }
        }

        if state.isThumbnail || state.isClickThrough {
            pinView.cancelPendingDragAndClicks()
        }
        if previous == nil
            || previous?.isThumbnail != state.isThumbnail
            || previous?.isClickThrough != state.isClickThrough {
            pinView.updateTrackingAreas()
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
            pinView.syncVisualState()
            if pinView.usesDirectDrawing {
                pinView.needsDisplay = true
            }
            if activeAnnotationController != nil {
                pinView.invalidateAnnotations()
            }
        }

        let needsShadowInvalidation = previous == nil
            || previous?.showsShadow != state.showsShadow
            || previous?.showsBorder != state.showsBorder
            || previous?.isThumbnail != state.isThumbnail
            || previous?.isClickThrough != state.isClickThrough
            || previous?.rotationDegrees != state.rotationDegrees
            || previous?.isFlippedHorizontally != state.isFlippedHorizontally
            || previous?.isFlippedVertically != state.isFlippedVertically
            || previous?.zoom != state.zoom
        if needsShadowInvalidation {
            invalidateShadow()
        }

        if let previous {
            if state.isThumbnail {
                pinView.hideHUD()
            } else if previous.isClickThrough != state.isClickThrough {
                pinView.showHUD(
                    state.isClickThrough
                        ? CCXL10n.text("Click-Through", zh: "鼠标穿透")
                        : CCXL10n.text("Interactive", zh: "已解除穿透")
                )
            } else if abs(previous.zoom - state.zoom) > 0.0001 {
                pinView.showHUD("\(Int((state.zoom * 100).rounded()))%")
            } else if abs(previous.opacity - state.opacity) > 0.0001 {
                let pct = Int((state.opacity * 100).rounded())
                pinView.showHUD(CCXL10n.text("Opacity \(pct)%", zh: "不透明度 \(pct)%"))
            } else if previous.rotationDegrees != state.rotationDegrees {
                pinView.showHUD("\(state.rotationDegrees)°")
            } else if previous.isFlippedHorizontally != state.isFlippedHorizontally {
                pinView.showHUD(
                    state.isFlippedHorizontally
                        ? CCXL10n.text("Flipped H", zh: "水平翻转")
                        : CCXL10n.text("Unflipped H", zh: "取消水平翻转")
                )
            } else if previous.isFlippedVertically != state.isFlippedVertically {
                pinView.showHUD(
                    state.isFlippedVertically
                        ? CCXL10n.text("Flipped V", zh: "垂直翻转")
                        : CCXL10n.text("Unflipped V", zh: "取消垂直翻转")
                )
            }
        }

        if previous?.isClickThrough != state.isClickThrough {
            onStateChanged?(self)
        }
    }

    public func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrameProgrammatically else { return }
        annotationController?.handleParentWindowDidMove(for: self)
    }

    public func windowDidResignKey(_ notification: Notification) {
        pinView.cancelPendingDragAndClicks()
        annotationController?.handleParentWindowDidResignKey(for: self)
    }

    public func windowWillClose(_ notification: Notification) {
        finalizeCloseCleanup()
    }

    internal func repositionAnnotationToolbarIfVisible() {
        annotationController?.handleParentFrameDidChange(for: self)
    }

    var frameCenter: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    var frameTopLeft: CGPoint { CGPoint(x: frame.minX, y: frame.maxY) }

    /// Shows the two-tier Liquid Glass annotation toolbar attached to an `.image` pin.
    public func showAnnotationToolbar(initialTool: AnnotationTool = .select) {
        guard case let .image(image, scale) = content,
              !state.isThumbnail,
              !state.isClickThrough,
              !isToolbarVisible
        else { return }

        pinView.cancelPendingDragAndClicks()
        onToolbarWillOpen?(self)

        var workingBaseImage = image
        let hasVisualTransform = state.rotationDegrees != 0 || state.isFlippedHorizontally || state.isFlippedVertically
        if hasVisualTransform {
            guard let flattened = PinLayout.transformedImage(
                image,
                clockwiseDegrees: state.rotationDegrees,
                flipHorizontal: state.isFlippedHorizontally,
                flipVertical: state.isFlippedVertically
            ) else {
                flashHUD(CCXL10n.text("Cannot Annotate", zh: "无法标注"))
                return
            }
            workingBaseImage = flattened
            content = .image(flattened, scale: scale)
            baseSize = PinLayout.baseSize(for: content)
            contentIdentity = .image(ImageFingerprint(image: flattened), historyEntryID: originalHistoryEntryID)
            state.rotationDegrees = 0
            state.isFlippedHorizontally = false
            state.isFlippedVertically = false
            annotationController?.replaceBaseImage(flattened)
        }

        let controller: PinAnnotationController
        if let existing = annotationController {
            controller = existing
        } else {
            let created = PinAnnotationController(baseImage: workingBaseImage, initialStyle: pendingAnnotationStyle)
            annotationController = created
            controller = created
        }

        controller.onStyleUpdated = { [weak self] style in
            guard let self else { return }
            self.pendingAnnotationStyle = style
            self.onAnnotationStyleChanged?(style)
        }
        controller.onNeedRedraw = { [weak self] in
            self?.pinView.invalidateAnnotations()
        }
        controller.onShowHUD = { [weak self] text in
            self?.flashHUD(text)
        }
        controller.onToolbarAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .ocr: self.recognizeTextFromMenu(nil)
            case .copy: self.copyPin(nil)
            case .save: self.savePin(nil)
            case .done: self.closeToolbar(commit: true)
            case .cancel: self.closeToolbar(commit: false)
            case .undo, .redo, .scroll, .record, .pin: break
            }
        }

        acceptsMouseMovedEvents = true
        controller.openToolbar(on: self, in: pinView, initialStyle: pendingAnnotationStyle, initialTool: initialTool)
        makeKey()
        makeFirstResponder(pinView)
        pinView.updateTrackingAreas()
        pinView.syncVisualState()
        pinView.invalidateAnnotations()
        invalidateShadow()
    }

    /// Closes the annotation toolbar, either baking committed annotations or rolling back session edits.
    public func closeToolbar(commit: Bool) {
        guard isToolbarVisible, let controller = annotationController else { return }
        pinView.cancelPendingDragAndClicks()
        if commit {
            if let baked = controller.closeToolbar(on: self, commit: true) {
                content = .image(baked, scale: exportScale)
                contentIdentity = .image(ImageFingerprint(image: baked), historyEntryID: originalHistoryEntryID)
            }
        } else {
            _ = controller.closeToolbar(on: self, commit: false)
        }
        acceptsMouseMovedEvents = false
        makeFirstResponder(pinView)
        pinView.updateTrackingAreas()
        pinView.syncVisualState()
        pinView.invalidateAnnotations()
        invalidateShadow()
    }

    public func setZoom(_ zoom: CGFloat, around anchor: CGPoint? = nil) {
        mutateState(anchor: anchor ?? frameCenter) { $0.setZoom(zoom) }
    }

    public func setOpacity(_ opacity: CGFloat) {
        mutateState { $0.setOpacity(opacity) }
    }

    public func rotateClockwise() {
        if isToolbarVisible { closeToolbar(commit: true) }
        mutateState(anchor: frameCenter) { $0.rotateClockwise() }
    }

    public func rotateCounterClockwise() {
        if isToolbarVisible { closeToolbar(commit: true) }
        mutateState(anchor: frameCenter) { $0.rotateCounterClockwise() }
    }

    public func toggleFlipHorizontal() {
        if isToolbarVisible { closeToolbar(commit: true) }
        mutateState(anchor: frameCenter) { $0.toggleFlipHorizontal() }
    }

    public func toggleFlipVertical() {
        if isToolbarVisible { closeToolbar(commit: true) }
        mutateState(anchor: frameCenter) { $0.toggleFlipVertical() }
    }

    public func setShowsBorder(_ shows: Bool) {
        mutateState { $0.showsBorder = shows }
    }

    public func setShowsShadow(_ shows: Bool) {
        mutateState { $0.showsShadow = shows }
    }

    public func setClickThrough(_ enabled: Bool) {
        if enabled && isToolbarVisible { closeToolbar(commit: true) }
        mutateState { $0.isClickThrough = enabled }
    }

    /// Collapses to / restores from the 72x72 thumbnail, keeping the top-left corner fixed.
    public func toggleThumbnail() {
        if isToolbarVisible { closeToolbar(commit: true) }
        mutateState(anchor: frameTopLeft) { $0.toggleThumbnail() }
    }

    /// Resets zoom, opacity, rotation, flip, and thumbnail mode back to defaults.
    public func resetAllTransforms() {
        if isToolbarVisible { closeToolbar(commit: true) }
        mutateState(anchor: frameCenter) { $0.resetAll() }
        pinView.showHUD(CCXL10n.text("Reset", zh: "已重置"))
    }

    /// Displays a transient centered HUD pill over the pin (no-op in compact thumbnail mode).
    public func flashHUD(_ text: String) {
        guard !state.isThumbnail else { return }
        pinView.showHUD(text)
    }

    internal var lastHUDTextForTesting: String? { pinView.lastHUDText }

    // MARK: - Events

    override public func magnify(with event: NSEvent) {
        guard !state.isThumbnail, event.magnification.isFinite, event.magnification != 0 else { return }
        let factor = min(max(1 + event.magnification, 0.2), 5.0)
        let anchor = PinLayout.clampedPoint(NSEvent.mouseLocation, to: frame)
        mutateState(anchor: anchor) { $0.multiplyZoom(by: factor) }
    }

    override public func scrollWheel(with event: NSEvent) {
        if let controller = annotationController,
           controller.isToolbarVisible,
           !event.modifierFlags.contains(.control),
           controller.handleScrollThickness(event, on: self) {
            return
        }
        guard event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY
        let deltaX = event.scrollingDeltaX
        guard delta.isFinite, deltaX.isFinite, abs(delta) >= abs(deltaX), delta != 0 else { return }
        let clampedDelta = min(max(delta, -120), 120)
        if event.modifierFlags.contains(.control) {
            let step = event.hasPreciseScrollingDeltas ? clampedDelta * 0.005 : (clampedDelta > 0 ? 0.05 : -0.05)
            mutateState { $0.adjustOpacity(by: step) }
        } else if !state.isThumbnail {
            let factor = event.hasPreciseScrollingDeltas ? exp(clampedDelta * 0.01) : (clampedDelta > 0 ? 1.1 : 1 / 1.1)
            let anchor = PinLayout.clampedPoint(NSEvent.mouseLocation, to: frame)
            mutateState(anchor: anchor) { $0.multiplyZoom(by: factor) }
        }
    }

    override public func keyDown(with event: NSEvent) {
        if let controller = annotationController, controller.isToolbarVisible {
            if controller.handleKeyDown(event, on: self) {
                return
            }
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Escape
            close()
            return
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        let nudgeStep: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: nudgeFrame(dx: -nudgeStep, dy: 0); return
        case 124: nudgeFrame(dx: nudgeStep, dy: 0); return
        case 125: nudgeFrame(dx: 0, dy: -nudgeStep); return
        case 126: nudgeFrame(dx: 0, dy: nudgeStep); return
        default: break
        }

        let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
            if !flags.contains(.shift), canShowAnnotationToolbar, !state.isThumbnail {
                if char == "e" || char == " " || event.keyCode == 49 {
                    showAnnotationToolbar()
                    return
                }
                if char == "t" {
                    recognizeTextFromMenu(nil)
                    return
                }
                if let tool = AnnotationTool.forNumberKey(char) {
                    showAnnotationToolbar(initialTool: tool)
                    return
                }
            }
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
            case "0", ")":
                if flags.contains(.shift) {
                    resetAllTransforms()
                } else {
                    setZoom(1)
                }
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

    private func nudgeFrame(dx: CGFloat, dy: CGFloat) {
        let candidate = frame.offsetBy(dx: dx, dy: dy)
        let clamped = PinLayout.clampedOriginToScreens(candidate, screens: NSScreen.screens.map(\.visibleFrame))
        setFrameOrigin(clamped.origin)
    }

    override public func cancelOperation(_ sender: Any?) {
        if let controller = annotationController, controller.isToolbarVisible {
            if controller.isEditingText {
                _ = controller.handleRightMouseDown(on: self)
                return
            }
            closeToolbar(commit: false)
            return
        }
        close()
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()

        if let controller = annotationController, controller.isToolbarVisible, controller.isEditingText {
            // Accessory app has no main Edit menu, so forward standard editing shortcuts explicitly.
            if flags == .command, let key {
                switch key {
                case "a":
                    NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
                    return true
                case "c":
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                    return true
                case "v":
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
                    return true
                case "x":
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
                    return true
                case "z":
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
                    return true
                default:
                    break
                }
            }
            if flags == [.command, .shift], key == "z" {
                NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        if let controller = annotationController, controller.isToolbarVisible {
            if flags == .command, key == "z" {
                controller.performUndo(on: self)
                return true
            }
            if flags == [.command, .shift], key == "z" {
                controller.performRedo(on: self)
                return true
            }
            if flags == .command, key == "d" {
                if controller.duplicateSelectedAnnotation(on: self) {
                    return true
                }
                return super.performKeyEquivalent(with: event)
            }
        }
        if flags == [.command, .shift], key == "s" {
            quickSavePin(nil)
            return true
        }
        if flags == [.command, .shift], key == "0" || key == ")" {
            resetAllTransforms()
            return true
        }
        if flags == .command, let key {
            switch key {
            case "c": copyPin(nil); return true
            case "d": duplicatePin(nil); return true
            case "s": savePin(nil); return true
            case "w": close(); return true
            case "0":
                if !state.isThumbnail { setZoom(1) }
                return true
            case "=", "+":
                if !state.isThumbnail { mutateState(anchor: frameCenter) { $0.multiplyZoom(by: 1.1) } }
                return true
            case "-":
                if !state.isThumbnail { mutateState(anchor: frameCenter) { $0.multiplyZoom(by: 1 / 1.1) } }
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override public func close() {
        let closeHandler = prepareCloseTeardown()
        super.close()
        closeHandler?(self)
    }

    private func finalizeCloseCleanup() {
        let closeHandler = prepareCloseTeardown()
        closeHandler?(self)
    }

    private func prepareCloseTeardown() -> ((PinPanel) -> Void)? {
        guard !didClose else { return nil }
        didClose = true
        if let controller = annotationController {
            controller.teardownForClose(on: self)
            annotationController = nil
        }
        acceptsMouseMovedEvents = false
        pinView.hideHUD()
        pinView.resetInteractionState()
        pinView.clearTrackingAreas()

        let closeHandler = onClose
        onClose = nil
        onCopy = nil
        onSave = nil
        onQuickSave = nil
        onDuplicate = nil
        onCopyFormattedColor = nil
        onRecognizeText = nil
        onHideAll = nil
        onCloseAll = nil
        onUnlockAllClickThrough = nil
        clickThroughCountProvider = nil
        onStateChanged = nil
        onToolbarWillOpen = nil
        onAnnotationStyleChanged = nil
        return closeHandler
    }

    // MARK: - Context menu

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: CCXL10n.text("Pin", zh: "贴图"))
        menu.autoenablesItems = false
        if canShowAnnotationToolbar {
            let toolbarItem = menuItem(
                isToolbarVisible
                    ? CCXL10n.text("Hide Toolbar", zh: "收起工具栏")
                    : CCXL10n.text("Show Toolbar", zh: "显示工具栏"),
                #selector(toggleAnnotationToolbarFromMenu(_:)),
                key: "e"
            )
            toolbarItem.keyEquivalentModifierMask = []
            toolbarItem.image = NSImage(
                systemSymbolName: isToolbarVisible ? "checkmark.circle" : "pencil.tip.crop.circle",
                accessibilityDescription: nil
            )
            menu.addItem(toolbarItem)
            menu.addItem(.separator())
        }
        menu.addItem(menuItem(CCXL10n.text("Copy", zh: "拷贝"), #selector(copyPin(_:)), key: "c"))
        switch content {
        case .image:
            menu.addItem(menuItem(CCXL10n.text("Copy Text (OCR)", zh: "识别文字 (OCR)"), #selector(recognizeTextFromMenu(_:))))
        case .color:
            menu.addItem(menuItem(CCXL10n.text("Copy HEX", zh: "拷贝 HEX"), #selector(copyHexColor(_:))))
            menu.addItem(menuItem(CCXL10n.text("Copy RGB", zh: "拷贝 RGB"), #selector(copyRGBColor(_:))))
            menu.addItem(menuItem(CCXL10n.text("Copy HSL", zh: "拷贝 HSL"), #selector(copyHSLColor(_:))))
        case .text:
            break
        }
        menu.addItem(menuItem(CCXL10n.text("Save PNG", zh: "保存 PNG"), #selector(savePin(_:)), key: "s"))
        let quickSave = menuItem(CCXL10n.text("Quick Save PNG", zh: "快速保存 PNG"), #selector(quickSavePin(_:)), key: "s")
        quickSave.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(quickSave)
        menu.addItem(menuItem(CCXL10n.text("Duplicate", zh: "创建副本"), #selector(duplicatePin(_:)), key: "d"))
        menu.addItem(.separator())

        let resetZoomItem = menuItem(CCXL10n.text("Reset Zoom (100%)", zh: "实际大小 (100%)"), #selector(resetZoom(_:)), key: "0")
        resetZoomItem.isEnabled = !state.isThumbnail
        menu.addItem(resetZoomItem)

        let rotateCW = menuItem(CCXL10n.text("Rotate 90°", zh: "顺时针旋转 90°"), #selector(rotate90(_:)), key: "r")
        rotateCW.keyEquivalentModifierMask = []
        rotateCW.isEnabled = !state.isThumbnail
        menu.addItem(rotateCW)

        let rotateCCW = menuItem(CCXL10n.text("Rotate 90° CCW", zh: "逆时针旋转 90°"), #selector(rotate270(_:)), key: "r")
        rotateCCW.keyEquivalentModifierMask = [.shift]
        rotateCCW.isEnabled = !state.isThumbnail
        menu.addItem(rotateCCW)

        let flipH = menuItem(CCXL10n.text("Flip Horizontal", zh: "水平翻转"), #selector(flipHorizontalFromMenu(_:)), key: "h")
        flipH.keyEquivalentModifierMask = []
        flipH.state = state.isFlippedHorizontally ? .on : .off
        flipH.isEnabled = !state.isThumbnail
        menu.addItem(flipH)

        let flipV = menuItem(CCXL10n.text("Flip Vertical", zh: "垂直翻转"), #selector(flipVerticalFromMenu(_:)), key: "v")
        flipV.keyEquivalentModifierMask = []
        flipV.state = state.isFlippedVertically ? .on : .off
        flipV.isEnabled = !state.isThumbnail
        menu.addItem(flipV)

        let resetAll = menuItem(CCXL10n.text("Reset All Transforms", zh: "重置全部变换"), #selector(resetAllFromMenu(_:)), key: "0")
        resetAll.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(resetAll)

        let opacityTitle = CCXL10n.text("Opacity", zh: "不透明度")
        let opacityItem = NSMenuItem(title: opacityTitle, action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(title: opacityTitle)
        for percent in [100, 80, 60, 40, 20] {
            let item = menuItem("\(percent)%", #selector(setOpacityFromMenu(_:)), tag: percent)
            item.state = abs(state.opacity * 100 - CGFloat(percent)) < 1 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        let clickThrough = menuItem(CCXL10n.text("Toggle Click-Through", zh: "鼠标穿透"), #selector(toggleClickThroughFromMenu(_:)))
        clickThrough.state = state.isClickThrough ? .on : .off
        menu.addItem(clickThrough)
        let thumbnail = menuItem(CCXL10n.text("Toggle Thumbnail", zh: "缩略图模式"), #selector(toggleThumbnailFromMenu(_:)))
        thumbnail.state = state.isThumbnail ? .on : .off
        menu.addItem(thumbnail)
        let showBorder = menuItem(CCXL10n.text("Show Border", zh: "显示边框"), #selector(toggleBorderFromMenu(_:)))
        showBorder.state = state.showsBorder ? .on : .off
        menu.addItem(showBorder)
        let showShadow = menuItem(CCXL10n.text("Show Shadow", zh: "显示阴影"), #selector(toggleShadowFromMenu(_:)))
        showShadow.state = state.showsShadow ? .on : .off
        menu.addItem(showShadow)
        menu.addItem(.separator())
        menu.addItem(menuItem(CCXL10n.text("Close Pin", zh: "关闭贴图"), #selector(closePin(_:)), key: "w"))
        let clickThroughCount = clickThroughCountProvider?() ?? 0
        if clickThroughCount > 0 {
            menu.addItem(menuItem(
                CCXL10n.text("Unlock Click-Through Pins (\(clickThroughCount))", zh: "解除全部穿透 (\(clickThroughCount))"),
                #selector(unlockAllClickThroughPins(_:))
            ))
        }
        menu.addItem(menuItem(CCXL10n.text("Hide All Pins", zh: "隐藏全部贴图"), #selector(hideAllPins(_:))))
        menu.addItem(menuItem(CCXL10n.text("Close All Pins", zh: "关闭全部贴图"), #selector(closeAllPins(_:))))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        return item
    }

    @objc func copyPin(_ sender: Any?) { onCopy?(self) }
    @objc func copyHexColor(_ sender: Any?) { onCopyFormattedColor?(self, .hex) }
    @objc func copyRGBColor(_ sender: Any?) { onCopyFormattedColor?(self, .rgb) }
    @objc func copyHSLColor(_ sender: Any?) { onCopyFormattedColor?(self, .hsl) }
    @objc func recognizeTextFromMenu(_ sender: Any?) { onRecognizeText?(self) }
    @objc func savePin(_ sender: Any?) { onSave?(self) }
    @objc func quickSavePin(_ sender: Any?) { onQuickSave?(self) }
    @objc func duplicatePin(_ sender: Any?) { onDuplicate?(self) }
    @objc func toggleAnnotationToolbarFromMenu(_ sender: Any?) {
        if isToolbarVisible {
            closeToolbar(commit: true)
        } else {
            if state.isThumbnail {
                toggleThumbnail()
            }
            showAnnotationToolbar()
        }
    }
    @objc func resetZoom(_ sender: Any?) { setZoom(1) }
    @objc func rotate90(_ sender: Any?) { rotateClockwise() }
    @objc func rotate270(_ sender: Any?) { rotateCounterClockwise() }
    @objc func flipHorizontalFromMenu(_ sender: Any?) { toggleFlipHorizontal() }
    @objc func flipVerticalFromMenu(_ sender: Any?) { toggleFlipVertical() }
    @objc func resetAllFromMenu(_ sender: Any?) { resetAllTransforms() }
    @objc func setOpacityFromMenu(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc func toggleClickThroughFromMenu(_ sender: Any?) { setClickThrough(!state.isClickThrough) }
    @objc func toggleThumbnailFromMenu(_ sender: Any?) { toggleThumbnail() }
    @objc func toggleBorderFromMenu(_ sender: Any?) { setShowsBorder(!state.showsBorder) }
    @objc func toggleShadowFromMenu(_ sender: Any?) { setShowsShadow(!state.showsShadow) }
    @objc func closePin(_ sender: Any?) { close() }
    @objc func unlockAllClickThroughPins(_ sender: Any?) { onUnlockAllClickThrough?() }
    @objc func hideAllPins(_ sender: Any?) { onHideAll?() }
    @objc func closeAllPins(_ sender: Any?) { onCloseAll?() }

    /// Image used for copy/save/OCR: the original pixels (transformed) or a rendered card.
    public func exportImage() -> CGImage? {
        if let controller = annotationController, controller.isToolbarVisible {
            return controller.bakedImage(baseSize: baseSize)
        }
        return PinRenderer.exportImage(
            for: content,
            rotationDegrees: state.rotationDegrees,
            flipHorizontal: state.isFlippedHorizontally,
            flipVertical: state.isFlippedVertically,
            appearance: effectiveAppearance
        )
    }

    /// Pixels per point of `exportImage()`.
    public var exportScale: CGFloat {
        if case let .image(_, scale) = content { return PinLayout.sanitizedScale(scale) }
        return 2
    }

    fileprivate var activeAnnotationController: PinAnnotationController? {
        guard let controller = annotationController, controller.isToolbarVisible else { return nil }
        return controller
    }
}

/// Transparent overlay drawing only live annotations on top of the GPU-composited base image.
private final class PinAnnotationOverlayView: NSView {
    weak var panel: PinPanel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 20
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let panel,
              let controller = panel.activeAnnotationController,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let base = panel.baseSize
        guard base.width.isFinite, base.height.isFinite, base.width > 0, base.height > 0,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0
        else { return }

        let sx = bounds.width / base.width
        let sy = bounds.height / base.height
        let dirtyCanvas = CGRect(
            x: dirtyRect.minX / sx,
            y: dirtyRect.minY / sy,
            width: dirtyRect.width / sx,
            height: dirtyRect.height / sy
        )
        context.saveGState()
        context.scaleBy(x: sx, y: sy)
        controller.drawLiveAnnotations(in: context, dirtyRect: dirtyCanvas, baseSize: base)
        context.restoreGState()
    }
}

/// Content view that renders images via GPU `CALayer`, live annotations via an overlay subview,
/// cards via cached CoreGraphics drawing, transient HUD, and routes mouse interactions.
final class PinContentView: NSView {
    private struct PendingWindowDrag {
        let startScreenPoint: CGPoint
        let initialOrigin: CGPoint
        var didStartMoving: Bool
    }

    private struct PrimaryClickRecord {
        let timestamp: TimeInterval
        let screenPoint: CGPoint
    }

    weak var panel: PinPanel?
    var mouseLocationProvider: () -> CGPoint = { NSEvent.mouseLocation }
    var hoverToolbarButton: NSButton { hoverToolbarControl }
    var borderLayerForTesting: CALayer { borderLayer }
    var annotationOverlayViewForTesting: NSView { annotationOverlayView }
    var hasTransparentCornersForTesting: Bool { cachedCornerAnalysis.hasTransparentCorners }

    private let imageContainerLayer = CALayer()
    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private let annotationOverlayView = PinAnnotationOverlayView(frame: .zero)
    private let hoverToolbarControl = PinHoverToolbarButton(frame: CGRect(
        x: 0,
        y: 0,
        width: PinHoverToolbarButton.diameter,
        height: PinHoverToolbarButton.diameter
    ))
    private let hudView = PinHUDView()

    private var hudHideTask: Task<Void, Never>?
    private var hudGeneration: UInt64 = 0
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var pendingWindowDrag: PendingWindowDrag?
    private var lastPrimaryClick: PrimaryClickRecord?
    private var lastDoubleClickActionTimestamp: TimeInterval = 0
    private var cachedTextKey: String?
    private var cachedAttributedText: NSAttributedString?
    private var cachedCornerAnalysisImage: CGImage?
    private var cachedCornerAnalysis: PinLayout.CornerAnalysis = .square
    private(set) var lastHUDText: String?

    var usesDirectDrawing: Bool {
        guard let panel else { return false }
        if case .image = panel.content { return false }
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        imageContainerLayer.masksToBounds = true
        imageContainerLayer.zPosition = 0
        imageContainerLayer.addSublayer(imageLayer)
        layer?.addSublayer(imageContainerLayer)

        annotationOverlayView.autoresizingMask = [.width, .height]
        annotationOverlayView.isHidden = true
        addSubview(annotationOverlayView)

        borderLayer.backgroundColor = NSColor.clear.cgColor
        borderLayer.zPosition = 30
        layer?.addSublayer(borderLayer)

        hoverToolbarControl.isHidden = true
        hoverToolbarControl.target = self
        hoverToolbarControl.action = #selector(handleHoverToolbarButtonClick(_:))
        addSubview(hoverToolbarControl)

        hudView.isHidden = true
        hudView.layer?.zPosition = 50
        hudView.setAccessibilityElement(false)
        addSubview(hudView)

        setAccessibilityElement(true)
        setAccessibilityHelp(
            CCXL10n.text(
                "Drag to move, scroll to zoom, double-click to annotate, right-click for options",
                zh: "拖动移动，滚轮缩放，双击标注，右键打开选项"
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hideHUD()
            resetInteractionState()
            clearTrackingAreas()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cachedTextKey = nil
        cachedAttributedText = nil
        syncVisualState()
        if usesDirectDrawing {
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        annotationOverlayView.frame = bounds
        syncVisualState()
        positionHoverToolbarButton()
        updateHoverToolbarButtonVisibility()
        if !hudView.isHidden {
            positionHUD()
        }
    }

    func invalidateAnnotations() {
        guard let panel else { return }
        annotationOverlayView.panel = panel
        let showOverlay = panel.activeAnnotationController != nil
        annotationOverlayView.isHidden = !showOverlay
        if showOverlay {
            annotationOverlayView.frame = bounds
            annotationOverlayView.needsDisplay = true
        }
    }

    private func cornerAnalysis(for image: CGImage?) -> PinLayout.CornerAnalysis {
        guard let image else {
            cachedCornerAnalysisImage = nil
            cachedCornerAnalysis = .square
            return .square
        }
        if let cached = cachedCornerAnalysisImage, cached === image {
            return cachedCornerAnalysis
        }
        let analyzed = PinLayout.analyzeCorners(of: image)
        cachedCornerAnalysisImage = image
        cachedCornerAnalysis = analyzed
        return analyzed
    }

    func syncVisualState() {
        guard let panel else { return }
        let state = panel.state
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let isAnnotating = panel.activeAnnotationController != nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        imageContainerLayer.frame = bounds
        imageContainerLayer.cornerRadius = state.isThumbnail ? PinLayout.thumbnailCornerRadius : 0
        imageContainerLayer.cornerCurve = .continuous
        imageContainerLayer.masksToBounds = true

        let displayImage: CGImage? = if let controller = panel.activeAnnotationController {
            controller.baseImage
        } else if case let .image(image, _) = panel.content {
            image
        } else {
            nil
        }

        let corners = cornerAnalysis(for: displayImage)
        let hasTransparentCorners = corners.hasTransparentCorners

        if let cgImage = displayImage {
            imageContainerLayer.isHidden = false
            imageLayer.contents = cgImage
            imageLayer.contentsScale = scale
            imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

            let rad = -CGFloat(state.rotationDegrees) * .pi / 180
            let sx: CGFloat = state.isFlippedHorizontally ? -1 : 1
            let sy: CGFloat = state.isFlippedVertically ? -1 : 1
            let affine = CGAffineTransform(rotationAngle: rad)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            imageLayer.transform = CATransform3DMakeAffineTransform(affine)

            if state.isThumbnail {
                let base = state.isQuarterTurned
                    ? CGSize(width: panel.baseSize.height, height: panel.baseSize.width)
                    : panel.baseSize
                if base.width > 0, base.height > 0 {
                    let fill = max(bounds.width / base.width, bounds.height / base.height)
                    imageLayer.bounds = CGRect(
                        origin: .zero,
                        size: CGSize(width: panel.baseSize.width * fill, height: panel.baseSize.height * fill)
                    )
                } else {
                    imageLayer.bounds = bounds
                }
                imageLayer.magnificationFilter = .linear
                imageLayer.minificationFilter = .trilinear
            } else {
                let unrotated = state.isQuarterTurned
                    ? CGSize(width: bounds.height, height: bounds.width)
                    : bounds.size
                imageLayer.bounds = CGRect(origin: .zero, size: unrotated)
                imageLayer.magnificationFilter = abs(state.zoom - 1) < 0.001 ? .nearest : .linear
                imageLayer.minificationFilter = abs(state.zoom - 1) < 0.001 ? .nearest : .trilinear
            }
        } else {
            imageContainerLayer.isHidden = true
            imageLayer.contents = nil
        }

        borderLayer.frame = bounds
        borderLayer.cornerCurve = .continuous
        if state.isThumbnail {
            borderLayer.cornerRadius = PinLayout.thumbnailCornerRadius
            borderLayer.maskedCorners = PinLayout.CornerAlphaMask.all.caCornerMask
        } else if hasTransparentCorners, let cgImage = displayImage {
            // Follow the image's transparent exterior corners so click-through and annotation outlines
            // never paint a harsh square box around rounded captures.
            let transformedCorners = corners.transparentCorners.transformed(
                clockwiseDegrees: state.rotationDegrees,
                flipHorizontal: state.isFlippedHorizontally,
                flipVertical: state.isFlippedVertically
            )
            let maxRadius = min(bounds.width, bounds.height) / 2
            let resolvedRadius: CGFloat
            if let radiusPixels = corners.estimatedCornerRadiusPixels {
                let displayedPixelW = state.isQuarterTurned ? CGFloat(cgImage.height) : CGFloat(cgImage.width)
                let displayedPixelH = state.isQuarterTurned ? CGFloat(cgImage.width) : CGFloat(cgImage.height)
                let pointsPerPixel = (displayedPixelW > 0 && displayedPixelH > 0)
                    ? min(bounds.width / displayedPixelW, bounds.height / displayedPixelH)
                    : 0
                resolvedRadius = min(max(0, radiusPixels * pointsPerPixel), maxRadius)
            } else {
                resolvedRadius = min(PinLayout.thumbnailCornerRadius, maxRadius)
            }
            borderLayer.cornerRadius = resolvedRadius
            borderLayer.maskedCorners = transformedCorners.caCornerMask
        } else {
            borderLayer.cornerRadius = 0
            borderLayer.maskedCorners = PinLayout.CornerAlphaMask.all.caCornerMask
        }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            if state.isClickThrough {
                borderLayer.borderWidth = 3
                borderLayer.borderColor = NSColor.systemCyan.withAlphaComponent(0.9).cgColor
            } else if isAnnotating {
                borderLayer.borderWidth = 1.5
                borderLayer.borderColor = NSColor.systemBlue.withAlphaComponent(0.92).cgColor
            } else if state.showsBorder && (state.isThumbnail || !hasTransparentCorners) {
                // Suppress the resting 1pt rectangular border on transparent-corner images so
                // WindowServer casts a crisp shadow matching the true rounded alpha silhouette.
                borderLayer.borderWidth = 1
                borderLayer.borderColor = NSColor(white: 0.5, alpha: 0.55).cgColor
            } else {
                borderLayer.borderWidth = 0
                borderLayer.borderColor = nil
            }
        }
        borderLayer.isHidden = borderLayer.borderWidth <= 0

        annotationOverlayView.panel = panel
        annotationOverlayView.isHidden = !isAnnotating

        CATransaction.commit()
        hoverToolbarControl.updateLocalization()
        positionHoverToolbarButton()
        updateHoverToolbarButtonVisibility()
        updateAccessibility(for: panel)
    }

    private func updateAccessibility(for panel: PinPanel) {
        let baseLabel: String
        switch panel.content {
        case .image:
            setAccessibilityRole(.image)
            baseLabel = CCXL10n.text("Pinned image", zh: "贴图图片")
        case let .text(text):
            setAccessibilityRole(.staticText)
            let preview = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
            baseLabel = preview.isEmpty
                ? CCXL10n.text("Pinned text", zh: "贴图文本")
                : CCXL10n.text("Pinned text: \(preview)", zh: "贴图文本：\(preview)")
        case let .color(sample):
            setAccessibilityRole(.colorWell)
            baseLabel = CCXL10n.text("Pinned color \(sample.hexString)", zh: "贴图颜色 \(sample.hexString)")
        }
        var qualifiers: [String] = []
        if panel.state.isClickThrough { qualifiers.append(CCXL10n.text("click-through", zh: "鼠标穿透")) }
        if panel.state.isThumbnail { qualifiers.append(CCXL10n.text("thumbnail", zh: "缩略图")) }
        if panel.activeAnnotationController != nil { qualifiers.append(CCXL10n.text("annotating", zh: "标注中")) }
        let separator = CCXL10n.text(", ", zh: "，")
        let fullLabel = qualifiers.isEmpty ? baseLabel : "\(baseLabel)\(separator)\(qualifiers.joined(separator: separator))"
        if accessibilityLabel() != fullLabel {
            setAccessibilityLabel(fullLabel)
        }
    }

    func showHUD(_ text: String) {
        hudGeneration &+= 1
        let expectedGeneration = hudGeneration
        hudHideTask?.cancel()
        hudHideTask = nil
        hudView.layer?.removeAllAnimations()
        hudView.setText(text)
        guard bounds.width >= 56 && bounds.height >= 28 else {
            hudView.isHidden = true
            return
        }
        lastHUDText = text
        positionHUD()
        hudView.alphaValue = 1
        hudView.isHidden = false
        hudHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.hudGeneration == expectedGeneration else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.hudView.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.hudView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.hudGeneration == expectedGeneration,
                          self.hudView.alphaValue <= 0.01
                    else { return }
                    self.hudView.isHidden = true
                }
            }
        }
    }

    func hideHUD() {
        hudGeneration &+= 1
        hudHideTask?.cancel()
        hudHideTask = nil
        lastHUDText = nil
        hudView.layer?.removeAllAnimations()
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

    func cancelPendingDragAndClicks() {
        pendingWindowDrag = nil
        lastPrimaryClick = nil
        updateHoverToolbarButtonVisibility()
    }

    func resetInteractionState() {
        pendingWindowDrag = nil
        lastPrimaryClick = nil
        lastDoubleClickActionTimestamp = 0
        isPointerInside = false
        hoverToolbarControl.isHidden = true
        cachedCornerAnalysisImage = nil
        cachedCornerAnalysis = .square
    }

    private var canShowHoverToolbarButton: Bool {
        guard let panel,
              panel.canShowAnnotationToolbar,
              !panel.state.isThumbnail,
              !panel.state.isClickThrough,
              !panel.isToolbarVisible,
              pendingWindowDrag?.didStartMoving != true,
              bounds.width >= 84,
              bounds.height >= 52
        else { return false }
        return true
    }

    private func positionHoverToolbarButton() {
        let size = PinHoverToolbarButton.diameter
        let inset = PinHoverToolbarButton.edgeInset
        hoverToolbarControl.frame = CGRect(
            x: (bounds.maxX - inset - size).rounded(),
            y: inset,
            width: size,
            height: size
        )
    }

    private func updateHoverToolbarButtonVisibility() {
        let shouldShow = isPointerInside && canShowHoverToolbarButton
        hoverToolbarControl.isHidden = !shouldShow
        if shouldShow {
            positionHoverToolbarButton()
        }
    }

    @objc private func handleHoverToolbarButtonClick(_ sender: Any?) {
        cancelPendingDragAndClicks()
        panel?.showAnnotationToolbar()
    }

    func clearTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        clearTrackingAreas()
        guard let panel,
              panel.canShowAnnotationToolbar,
              !panel.state.isThumbnail,
              !panel.state.isClickThrough
        else {
            isPointerInside = false
            updateHoverToolbarButtonVisibility()
            return
        }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if panel.activeAnnotationController != nil {
            options.insert(.mouseMoved)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        updateHoverToolbarButtonVisibility()
    }

    private func isDoubleClickEvent(_ event: NSEvent, atScreenPoint screenPoint: CGPoint) -> Bool {
        if event.clickCount >= 2 {
            // Prevent an accidental 3rd rapid click right after a double-click action from bouncing back.
            if event.clickCount == 3,
               event.timestamp > 0,
               lastDoubleClickActionTimestamp > 0 {
                let sinceAction = event.timestamp - lastDoubleClickActionTimestamp
                if sinceAction > 0 && sinceAction <= NSEvent.doubleClickInterval {
                    return false
                }
            }
            return true
        }
        guard event.timestamp > 0,
              let last = lastPrimaryClick,
              last.timestamp > 0
        else { return false }
        let delta = event.timestamp - last.timestamp
        guard delta > 0 && delta <= NSEvent.doubleClickInterval else { return false }
        let distance = hypot(screenPoint.x - last.screenPoint.x, screenPoint.y - last.screenPoint.y)
        return distance <= 6
    }

    private func consumeDoubleClick(timestamp: TimeInterval) {
        lastPrimaryClick = nil
        pendingWindowDrag = nil
        lastDoubleClickActionTimestamp = timestamp > 0 ? timestamp : 0
    }

    private func recordPrimaryClick(atScreenPoint screenPoint: CGPoint, timestamp: TimeInterval) {
        if timestamp > 0 {
            lastPrimaryClick = PrimaryClickRecord(timestamp: timestamp, screenPoint: screenPoint)
        } else {
            lastPrimaryClick = nil
        }
    }

    private func beginPendingWindowDrag(for panel: PinPanel) {
        pendingWindowDrag = PendingWindowDrag(
            startScreenPoint: mouseLocationProvider(),
            initialOrigin: panel.frame.origin,
            didStartMoving: false
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        pendingWindowDrag = nil
        panel.makeKey()

        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        let isDoubleClick = isDoubleClickEvent(event, atScreenPoint: screenPoint)

        if let controller = panel.activeAnnotationController {
            let effectiveClickCount = isDoubleClick ? max(event.clickCount, 2) : 1
            let point = convert(event.locationInWindow, from: nil)
            switch controller.handleMouseDown(at: point, clickCount: effectiveClickCount, in: self, panel: panel) {
            case .handled:
                if isDoubleClick {
                    consumeDoubleClick(timestamp: event.timestamp)
                } else {
                    lastPrimaryClick = nil
                }
                return
            case .doubleClickedEmptyToCommit:
                consumeDoubleClick(timestamp: event.timestamp)
                panel.closeToolbar(commit: true)
                return
            case .passThroughDragPin:
                if isDoubleClick {
                    consumeDoubleClick(timestamp: event.timestamp)
                    panel.closeToolbar(commit: true)
                    return
                }
                recordPrimaryClick(atScreenPoint: screenPoint, timestamp: event.timestamp)
                beginPendingWindowDrag(for: panel)
                return
            }
        }

        if isDoubleClick {
            consumeDoubleClick(timestamp: event.timestamp)
            if panel.state.isThumbnail {
                panel.toggleThumbnail()
            } else if panel.canShowAnnotationToolbar {
                panel.showAnnotationToolbar()
            } else {
                panel.toggleThumbnail()
            }
            return
        }

        recordPrimaryClick(atScreenPoint: screenPoint, timestamp: event.timestamp)
        beginPendingWindowDrag(for: panel)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel else {
            super.mouseDragged(with: event)
            return
        }
        if var drag = pendingWindowDrag {
            let screenNow = mouseLocationProvider()
            let dx = screenNow.x - drag.startScreenPoint.x
            let dy = screenNow.y - drag.startScreenPoint.y
            guard dx.isFinite, dy.isFinite else { return }
            if !drag.didStartMoving {
                guard hypot(dx, dy) >= 3.0 else { return }
                drag.didStartMoving = true
                lastPrimaryClick = nil
                pendingWindowDrag = drag
                updateHoverToolbarButtonVisibility()
            }
            panel.setFrameOrigin(CGPoint(x: drag.initialOrigin.x + dx, y: drag.initialOrigin.y + dy))
            return
        }
        guard let controller = panel.activeAnnotationController else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        controller.handleMouseDragged(at: point, constrain: event.modifierFlags.contains(.shift), in: self, panel: panel)
    }

    override func mouseUp(with event: NSEvent) {
        guard let panel else {
            super.mouseUp(with: event)
            return
        }
        if let drag = pendingWindowDrag {
            pendingWindowDrag = nil
            if drag.didStartMoving {
                let screens = NSScreen.screens.map(\.visibleFrame)
                if !screens.isEmpty {
                    let clamped = PinLayout.clampedOriginToScreens(panel.frame, screens: screens)
                    if clamped.origin != panel.frame.origin {
                        panel.setFrameOrigin(clamped.origin)
                    }
                }
                if isPointerInside {
                    let point = convert(event.locationInWindow, from: nil)
                    isPointerInside = bounds.contains(point)
                }
                updateHoverToolbarButtonVisibility()
            }
            return
        }
        guard let controller = panel.activeAnnotationController else {
            super.mouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        controller.handleMouseUp(at: point, in: self, panel: panel)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let panel, let controller = panel.activeAnnotationController else {
            super.mouseMoved(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        controller.handleMouseMoved(at: point, in: self, baseSize: panel.baseSize)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateHoverToolbarButtonVisibility()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateHoverToolbarButtonVisibility()
        panel?.activeAnnotationController?.handleMouseExited()
        super.mouseExited(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingDragAndClicks()
        if let panel, let controller = panel.activeAnnotationController, controller.handleRightMouseDown(on: panel) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        panel?.makeContextMenu()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let panel, usesDirectDrawing, let context = NSGraphicsContext.current?.cgContext else { return }
        let state = panel.state
        context.clear(bounds)

        if state.isThumbnail {
            let outline = NSBezierPath(
                roundedRect: bounds,
                xRadius: PinLayout.thumbnailCornerRadius,
                yRadius: PinLayout.thumbnailCornerRadius
            )
            drawThumbnail(panel: panel, clip: outline, context: context)
        } else {
            drawFull(panel: panel, context: context)
        }
    }

    private func attributedText(for text: String) -> NSAttributedString {
        if let cached = cachedAttributedText, cachedTextKey == text {
            return cached
        }
        let built = NSAttributedString(
            string: PinLayout.displayText(for: text),
            attributes: PinLayout.textAttributes()
        )
        cachedTextKey = text
        cachedAttributedText = built
        return built
    }

    private func drawFull(panel: PinPanel, context: CGContext) {
        let state = panel.state
        let base = panel.baseSize
        guard base.width.isFinite, base.height.isFinite, base.width > 0, base.height > 0 else { return }
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
        let cachedText: NSAttributedString? = if case let .text(string) = panel.content {
            attributedText(for: string)
        } else {
            nil
        }
        PinRenderer.draw(panel.content, in: rect, zoom: state.zoom, context: context, cachedAttributedText: cachedText)
        context.restoreGState()
    }

    private func drawThumbnail(panel: PinPanel, clip: NSBezierPath, context: CGContext) {
        context.saveGState()
        clip.addClip()
        let state = panel.state
        let base = state.isQuarterTurned
            ? CGSize(width: panel.baseSize.height, height: panel.baseSize.width)
            : panel.baseSize
        guard base.width.isFinite, base.height.isFinite, base.width > 0, base.height > 0 else {
            context.restoreGState()
            return
        }
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
            let cachedText: NSAttributedString? = if case let .text(string) = panel.content {
                attributedText(for: string)
            } else {
                nil
            }
            PinRenderer.draw(panel.content, in: rect, zoom: fill, context: context, cachedAttributedText: cachedText)
        }
        context.restoreGState()
    }
}

private final class PinHoverToolbarButton: NSButton {
    static let diameter: CGFloat = 26
    static let edgeInset: CGFloat = 8

    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            updateChrome()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        focusRingType = .none
        (cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown

        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        layer?.masksToBounds = false
        layer?.borderWidth = 0.75
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.30
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.zPosition = 45

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        symbol?.isTemplate = true
        image = symbol
        contentTintColor = NSColor.white.withAlphaComponent(0.95)

        updateLocalization()
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                isHovered = false
            }
        }
    }

    func updateLocalization() {
        toolTip = CCXL10n.text("Show Toolbar (E / Double-click)", zh: "显示工具栏 (E / 双击)")
        setAccessibilityLabel(CCXL10n.text("Show Toolbar", zh: "显示工具栏"))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let hoverArea {
            removeTrackingArea(hoverArea)
            self.hoverArea = nil
            isHovered = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
            self.hoverArea = nil
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        super.mouseExited(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateChrome()
    }

    private func updateChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(white: 0.11, alpha: isHovered ? 0.88 : 0.72).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(isHovered ? 0.42 : 0.26).cgColor
        }
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
