import AppKit
import CCXCore
import Foundation
import QuartzCore

/// Recording frame overlay panel: interactive on the target display during `.ready` so users can
/// resize, move, nudge, or redraw the frame, then shrinks to a click-through outset border during capture.
@MainActor
final class RecordingBorderPanel: NSPanel {
    var onRegionChanged: ((RecordingRegion) -> Void)?
    var onInteractionStateChanged: ((Bool) -> Void)?

    private let borderView: RecordingBorderView
    private(set) var isInteractive = true
    private var lockedForCapture = false

    var currentRegion: RecordingRegion { borderView.currentRegion }
    var isActivelyAdjusting: Bool { borderView.isActivelyAdjusting }
    var isRedrawing: Bool { borderView.isRedrawing }
    var borderContentView: NSView { borderView }
    var isSizeLabelHidden: Bool { borderView.isSizeLabelHidden }
    var sizeLabelText: String { borderView.sizeLabelText }
    var renderCountForTesting: Int { borderView.renderCount }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(region: RecordingRegion, topInset: CGFloat = 0, settings: RecordingSettings = RecordingSettings()) {
        self.borderView = RecordingBorderView(region: region, topInset: topInset, settings: settings)
        super.init(
            contentRect: region.displayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Set `isFloatingPanel` before `level` because toggling `isFloatingPanel` resets window level.
        isFloatingPanel = true
        level = .statusBar
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = borderView
        initialFirstResponder = borderView

        borderView.onRegionChanged = { [weak self] updated in
            self?.onRegionChanged?(updated)
        }
        borderView.onInteractionStateChanged = { [weak self] active in
            self?.onInteractionStateChanged?(active)
        }
        setFrame(region.displayFrame, display: true)
    }

    func update(phase: RecordingPhase, region: RecordingRegion, settings: RecordingSettings) {
        if case .ready = phase, !lockedForCapture {
            isInteractive = true
            ignoresMouseEvents = false
            if frame != region.displayFrame {
                setFrame(region.displayFrame, display: false)
            }
            borderView.applyInteractiveReady(region: region, settings: settings)
        } else {
            applyCaptureChrome(phase: phase, region: region)
        }
    }

    /// Switches to click-through capture bounds immediately before async permission prompts or stream start.
    func prepareForCapture(region: RecordingRegion) {
        lockedForCapture = true
        applyCaptureChrome(phase: .ready, region: region)
    }

    /// Re-syncs overlay bounds after a display resolution or arrangement change during `.ready`.
    func updateDisplayBounds(region: RecordingRegion, topInset: CGFloat, settings: RecordingSettings) {
        guard isInteractive, !lockedForCapture else { return }
        if frame != region.displayFrame {
            setFrame(region.displayFrame, display: false)
        }
        borderView.updateDisplayBounds(region: region, topInset: topInset, settings: settings)
    }

    /// Releases callbacks, tracking areas, and closes the panel cleanly.
    func tearDown() {
        onRegionChanged = nil
        onInteractionStateChanged = nil
        borderView.onRegionChanged = nil
        borderView.onInteractionStateChanged = nil
        borderView.tearDown()
        orderOut(nil)
        close()
    }

    func nudge(dx: CGFloat, dy: CGFloat) -> RecordingRegion? {
        guard isInteractive else { return nil }
        return borderView.nudge(dx: dx, dy: dy)
    }

    func resizeBy(dw: CGFloat, dh: CGFloat) -> RecordingRegion? {
        guard isInteractive else { return nil }
        return borderView.resizeBy(dw: dw, dh: dh)
    }

    func selectAll() -> RecordingRegion? {
        guard isInteractive else { return nil }
        return borderView.selectAll()
    }

    private func applyCaptureChrome(phase: RecordingPhase, region: RecordingRegion) {
        let wasInteractive = isInteractive
        isInteractive = false
        ignoresMouseEvents = true
        let outsetRect = region.screenRect.insetBy(dx: -4, dy: -4)
        if frame != outsetRect {
            setFrame(outsetRect, display: true)
        }
        borderView.applyCaptureChrome(phase: phase, region: region)
        if wasInteractive {
            NSCursor.arrow.set()
        }
    }
}

@MainActor
private final class RecordingBorderView: NSView {
    var onRegionChanged: ((RecordingRegion) -> Void)?
    var onInteractionStateChanged: ((Bool) -> Void)?

    private enum CursorKind: Equatable {
        case crosshair, openHand, closedHand, arrow, resize(RecordingResizeHandle)
    }

    private(set) var currentRegion: RecordingRegion
    private var adjuster: RecordingFrameAdjuster
    private var topInset: CGFloat
    private var settings: RecordingSettings
    private var phase: RecordingPhase = .ready
    private var isInteractive = true

    private var isSpaceDown = false
    private var lastMousePoint: CGPoint?
    private var lastCursorKind: CursorKind?
    private var lastSizeLabelText: String?
    private var trackingArea: NSTrackingArea?
    private(set) var renderCount = 0

    private let dimLayer = CAShapeLayer()
    private let contrastBorderLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let sizeLabel = NonInteractiveBorderLabel(labelWithString: "")

    var isActivelyAdjusting: Bool { isInteractive && adjuster.isInteracting }
    var isRedrawing: Bool { isInteractive && adjuster.isRedrawing }
    var isSizeLabelHidden: Bool { sizeLabel.isHidden }
    var sizeLabelText: String { sizeLabel.stringValue }

    init(region: RecordingRegion, topInset: CGFloat, settings: RecordingSettings) {
        self.topInset = topInset
        self.settings = settings
        let localBounds = CGRect(origin: .zero, size: region.displayFrame.size)
        let adjuster = RecordingFrameAdjuster(bounds: localBounds, initialRect: region.localRect)
        self.adjuster = adjuster
        self.currentRegion = region.updating(localRect: adjuster.rect)
        super.init(frame: localBounds)
        wantsLayer = true
        setUpLayers()
        setUpSizeLabel()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { isInteractive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isInteractive }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        syncLayerBounds()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayerContentsScale()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard isInteractive else {
            self.trackingArea = nil
            return
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func applyInteractiveReady(region: RecordingRegion, settings: RecordingSettings) {
        let oldInteractive = self.isInteractive
        let oldPhase = self.phase
        let oldSettings = self.settings
        let oldRegion = self.currentRegion

        self.isInteractive = true
        self.phase = .ready
        self.settings = settings
        var adjusterChanged = false
        if !adjuster.isInteracting && !rectsNearlyEqual(region.localRect, adjuster.rect) {
            adjuster.setRect(region.localRect)
            adjusterChanged = true
        }
        let updatedRegion = region.updating(localRect: adjuster.activeRect)
        self.currentRegion = updatedRegion
        if !oldInteractive || trackingArea == nil {
            updateTrackingAreas()
        }
        if !oldInteractive || oldPhase != .ready || oldSettings != settings || adjusterChanged || updatedRegion != oldRegion {
            render()
        }
    }

    func applyCaptureChrome(phase: RecordingPhase, region: RecordingRegion) {
        guard self.isInteractive || self.phase != phase || self.currentRegion != region else { return }
        self.adjuster.cancelInteraction()
        self.isInteractive = false
        self.isSpaceDown = false
        self.lastMousePoint = nil
        self.lastCursorKind = nil
        self.phase = phase
        self.currentRegion = region
        if trackingArea != nil {
            updateTrackingAreas()
        }
        render()
    }

    func updateDisplayBounds(region: RecordingRegion, topInset: CGFloat, settings: RecordingSettings) {
        guard isInteractive else { return }
        self.topInset = topInset
        self.settings = settings
        let localBounds = CGRect(origin: .zero, size: region.displayFrame.size)
        frame = localBounds
        let updatedAdjuster = RecordingFrameAdjuster(bounds: localBounds, initialRect: region.localRect)
        self.adjuster = updatedAdjuster
        self.currentRegion = region.updating(localRect: updatedAdjuster.rect)
        updateLayerContentsScale()
        render()
    }

    func tearDown() {
        adjuster.cancelInteraction()
        isInteractive = false
        isSpaceDown = false
        lastMousePoint = nil
        lastCursorKind = nil
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
    }

    func nudge(dx: CGFloat, dy: CGFloat) -> RecordingRegion? {
        guard isInteractive, adjuster.nudge(dx: dx, dy: dy) else { return nil }
        currentRegion = currentRegion.updating(localRect: adjuster.rect)
        render()
        updateCursor()
        return currentRegion
    }

    func resizeBy(dw: CGFloat, dh: CGFloat) -> RecordingRegion? {
        guard isInteractive, adjuster.resizeBy(dw: dw, dh: dh) else { return nil }
        currentRegion = currentRegion.updating(localRect: adjuster.rect)
        render()
        updateCursor()
        return currentRegion
    }

    func selectAll() -> RecordingRegion? {
        guard isInteractive, adjuster.selectAll() else { return nil }
        currentRegion = currentRegion.updating(localRect: adjuster.rect)
        render()
        updateCursor()
        return currentRegion
    }

    // MARK: - Mouse & Keyboard

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        lastCursorKind = nil
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive else { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        guard isInteractive, !adjuster.isInteracting else { return }
        lastMousePoint = nil
        lastCursorKind = nil
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractive else {
            super.cursorUpdate(with: event)
            return
        }
        lastCursorKind = nil
        updateCursor()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else {
            super.mouseDown(with: event)
            return
        }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        adjuster.mouseDown(at: point)
        render()
        updateCursor()
        if adjuster.isInteracting {
            onInteractionStateChanged?(true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive, adjuster.isInteracting else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        let previousActiveRect = adjuster.activeRect
        let constrain = event.modifierFlags.contains(.shift)
        adjuster.mouseDragged(to: point, constrainSquare: constrain, moveOrigin: isSpaceDown)
        let nextActiveRect = adjuster.activeRect
        let updated = currentRegion.updating(localRect: nextActiveRect)
        if updated != currentRegion {
            currentRegion = updated
            onRegionChanged?(updated)
        }
        if nextActiveRect != previousActiveRect {
            render()
        }
        updateCursor()
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive, adjuster.isInteracting else {
            super.mouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        adjuster.mouseUp(at: point)
        isSpaceDown = false
        let updated = currentRegion.updating(localRect: adjuster.rect)
        if updated != currentRegion {
            currentRegion = updated
            onRegionChanged?(updated)
        }
        render()
        updateCursor()
        onInteractionStateChanged?(false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && isInteractive && adjuster.isRedrawing {
            isSpaceDown = true
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceDown = false
            return
        }
        super.keyUp(with: event)
    }

    // MARK: - Layer Setup & Rendering

    private func setUpLayers() {
        guard let root = layer else { return }

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        dimLayer.zPosition = 1
        root.addSublayer(dimLayer)

        contrastBorderLayer.fillColor = nil
        contrastBorderLayer.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
        contrastBorderLayer.lineWidth = 3.0
        contrastBorderLayer.zPosition = 2
        root.addSublayer(contrastBorderLayer)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 2.0
        borderLayer.zPosition = 3
        root.addSublayer(borderLayer)

        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor.systemBlue.cgColor
        handleLayer.lineWidth = 1.5
        handleLayer.zPosition = 4
        root.addSublayer(handleLayer)

        syncLayerBounds()
        updateLayerContentsScale()
    }

    private func setUpSizeLabel() {
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        sizeLabel.textColor = .white
        sizeLabel.drawsBackground = true
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        sizeLabel.wantsLayer = true
        sizeLabel.layer?.cornerRadius = 4
        sizeLabel.layer?.masksToBounds = true
        sizeLabel.layer?.zPosition = 10
        sizeLabel.isHidden = true
        addSubview(sizeLabel)
    }

    private func syncLayerBounds() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        contrastBorderLayer.frame = bounds
        borderLayer.frame = bounds
        handleLayer.frame = bounds
        CATransaction.commit()
    }

    private func updateLayerContentsScale() {
        let scale = window?.backingScaleFactor ?? currentRegion.scale
        layer?.contentsScale = scale
        dimLayer.contentsScale = scale
        contrastBorderLayer.contentsScale = scale
        borderLayer.contentsScale = scale
        handleLayer.contentsScale = scale
    }

    private func render() {
        renderCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        syncLayerBounds()

        guard isInteractive else {
            dimLayer.isHidden = true
            dimLayer.path = nil
            contrastBorderLayer.isHidden = true
            contrastBorderLayer.path = nil
            handleLayer.isHidden = true
            handleLayer.path = nil
            sizeLabel.isHidden = true

            let strokeRect = bounds.insetBy(dx: 2, dy: 2)
            if !strokeRect.isNull, strokeRect.width > 0, strokeRect.height > 0 {
                let corner = max(0, min(5, strokeRect.width / 2, strokeRect.height / 2))
                borderLayer.path = CGPath(roundedRect: strokeRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            } else {
                borderLayer.path = nil
            }
            borderLayer.lineWidth = 2.5

            switch phase {
            case .ready:
                borderLayer.strokeColor = NSColor.systemBlue.cgColor
                borderLayer.lineDashPattern = [6, 4]
            case .recording:
                borderLayer.strokeColor = NSColor.systemRed.cgColor
                borderLayer.lineDashPattern = nil
            case .paused:
                borderLayer.strokeColor = NSColor.systemOrange.cgColor
                borderLayer.lineDashPattern = nil
            case .finalizing:
                borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
                borderLayer.lineDashPattern = nil
            case .completed:
                borderLayer.strokeColor = NSColor.systemGreen.cgColor
                borderLayer.lineDashPattern = nil
            }
            return
        }

        let rect = adjuster.activeRect
        dimLayer.isHidden = false
        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)
        dimPath.addRect(rect)
        dimLayer.path = dimPath

        let inset = min(1.0, min(rect.width, rect.height) / 2)
        let borderRect = rect.insetBy(dx: inset, dy: inset)
        let borderPath = borderRect.isNull ? nil : CGPath(rect: borderRect, transform: nil)

        contrastBorderLayer.isHidden = false
        contrastBorderLayer.path = borderPath

        borderLayer.path = borderPath
        borderLayer.strokeColor = NSColor.systemBlue.cgColor
        borderLayer.lineWidth = 2.0
        borderLayer.lineDashPattern = [6, 4]

        handleLayer.isHidden = false
        let handlesPath = CGMutablePath()
        let minCenterX = bounds.minX + 5
        let maxCenterX = max(minCenterX, bounds.maxX - 5)
        let minCenterY = bounds.minY + 5
        let maxCenterY = max(minCenterY, bounds.maxY - 5)
        for handle in RecordingResizeHandle.allCases {
            let rawCenter = RecordingFrameAdjuster.handlePoint(handle, for: rect)
            let cx = min(max(rawCenter.x, minCenterX), maxCenterX)
            let cy = min(max(rawCenter.y, minCenterY), maxCenterY)
            let handleRect = CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)
            handlesPath.addRoundedRect(in: handleRect, cornerWidth: 2, cornerHeight: 2)
        }
        handleLayer.path = handlesPath

        updateSizeLabel(for: rect)
    }

    private func updateSizeLabel(for rect: CGRect) {
        let liveRegion = currentRegion.updating(localRect: rect)
        let pixelSize = liveRegion.pixelSize(for: settings.format)
        let formatted = " \(Int(pixelSize.width)) × \(Int(pixelSize.height)) "
        if formatted != lastSizeLabelText {
            lastSizeLabelText = formatted
            sizeLabel.stringValue = formatted
            sizeLabel.sizeToFit()
        }

        let usableMaxY = max(bounds.minY, bounds.maxY - topInset)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + sizeLabel.frame.height > usableMaxY {
            let insideTopY = min(rect.maxY, usableMaxY) - sizeLabel.frame.height - 6
            if insideTopY >= rect.minY {
                origin.y = insideTopY
            } else {
                origin.y = rect.minY - sizeLabel.frame.height - 6
            }
        }
        let maxOriginX = max(bounds.minX + 4, bounds.maxX - sizeLabel.frame.width - 4)
        let maxOriginY = max(bounds.minY + 4, usableMaxY - sizeLabel.frame.height - 4)
        origin.x = min(max(origin.x, bounds.minX + 4), maxOriginX)
        origin.y = min(max(origin.y, bounds.minY + 4), maxOriginY)
        sizeLabel.setFrameOrigin(origin)
        if sizeLabel.isHidden { sizeLabel.isHidden = false }
    }

    private func updateCursor() {
        guard isInteractive else {
            applyCursor(.arrow, cursor: .arrow)
            return
        }
        let kind: CursorKind
        let cursor: NSCursor
        switch adjuster.interaction {
        case .moving:
            kind = .closedHand
            cursor = .closedHand
        case let .resizing(_, handle):
            kind = .resize(handle)
            cursor = Self.cursor(for: handle)
        case .redrawing:
            kind = .crosshair
            cursor = .crosshair
        case .idle:
            guard let point = lastMousePoint else { return }
            switch adjuster.hitTarget(at: point) {
            case let .handle(handle):
                kind = .resize(handle)
                cursor = Self.cursor(for: handle)
            case .interior:
                kind = .openHand
                cursor = .openHand
            case .outside:
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

    private static func cursor(for handle: RecordingResizeHandle) -> NSCursor {
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

    private func rectsNearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.25 &&
        abs(lhs.minY - rhs.minY) < 0.25 &&
        abs(lhs.width - rhs.width) < 0.25 &&
        abs(lhs.height - rhs.height) < 0.25
    }
}

private final class NonInteractiveBorderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Floating Liquid Glass control HUD shown below/above/inside the recorded region across
/// `ready`, `recording`, `paused`, `finalizing`, and `completed` phases.
@MainActor
final class RecordingControlPanel: NSPanel, NSWindowDelegate {
    private static let panelHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 14
    private static let controlHeight: CGFloat = 30

    var onSettingsChanged: ((RecordingSettings) -> Void)?
    var onStart: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onQuickSave: (() -> Void)?
    var onReveal: (() -> Void)?
    var onDiscard: (() -> Void)?

    private(set) var renderedPhase: RecordingPhase = .ready
    private(set) var hasCustomPosition = false
    private var isProgrammaticFrameUpdate = false
    private var lastRenderedSettings: RecordingSettings?
    private var lastRenderedTimerText = "00:00"
    private var settings: RecordingSettings
    private var captureRect: CGRect
    private var visibleFrame: CGRect

    private let contentContainer = ArrowCursorContainerView(frame: .zero)
    private let readyRow = NSStackView()
    private let recordingRow = NSStackView()
    private let finalizingRow = NSStackView()
    private let completedRow = NSStackView()
    private weak var activeRow: NSStackView?

    private let formatControl = FormatSegmentedControl()
    private let fpsPicker = FPSPickerControl()
    private let systemAudioButton = HUDIconToggleButton(
        activeSymbol: "speaker.wave.2.fill",
        inactiveSymbol: "speaker.slash",
        activeTint: .systemCyan
    )
    private let micButton = HUDIconToggleButton(
        activeSymbol: "mic.fill",
        inactiveSymbol: "mic.slash",
        activeTint: .systemGreen
    )
    private let cursorButton = HUDIconToggleButton(
        activeSymbol: "cursorarrow",
        inactiveSymbol: "cursorarrow",
        activeTint: .white
    )

    private let statusDot = NSView()
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let recordingBadgeLabel = NSTextField(labelWithString: "")
    private let pauseResumeButton = HUDIconToggleButton(
        activeSymbol: "pause.fill",
        inactiveSymbol: "pause.fill",
        activeTint: .white
    )

    private let spinner = NSProgressIndicator()
    private let finalizingLabel = NSTextField(labelWithString: CCXL10n.text("Finalizing...", zh: "正在生成…"))

    private let summaryLabel = NSTextField(labelWithString: "")

    var areAudioTogglesEnabled: Bool {
        systemAudioButton.isEnabled && micButton.isEnabled
    }

    var isReadyContainerVisible: Bool { activeRow === readyRow }
    var isRecordingContainerVisible: Bool { activeRow === recordingRow }
    var isFinalizingContainerVisible: Bool { activeRow === finalizingRow }
    var isCompletedContainerVisible: Bool { activeRow === completedRow }
    var timerText: String { timerLabel.stringValue }
    var summaryText: String { summaryLabel.stringValue }
    var isPopupMenuOpen: Bool { fpsPicker.isMenuOpen }
    var fpsBadgeText: String { fpsPicker.displayText }
    var recordingBadgeText: String { recordingBadgeLabel.stringValue }
    var availableFPSMenuOptions: [Int] { fpsPicker.currentOptions }
    var activeRowView: NSView? { activeRow }
    var contentContainerBounds: CGRect { contentContainer.bounds }
    var activeControlFramesInContent: [CGRect] {
        guard let activeRow else { return [] }
        return activeRow.arrangedSubviews
            .filter { !$0.isHidden }
            .map { $0.convert($0.bounds, to: contentContainer) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(captureRect: CGRect, visibleFrame: CGRect, settings: RecordingSettings) {
        self.captureRect = captureRect
        self.visibleFrame = visibleFrame
        self.settings = settings

        let initialSize = CGSize(width: 420, height: Self.panelHeight)
        let initialFrame = Self.frame(for: captureRect, size: initialSize, visibleFrame: visibleFrame)
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Keep the control HUD strictly above the full-display interactive border panel.
        isFloatingPanel = true
        level = .statusBarLevelPlusOne
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        delegate = self

        buildHierarchy()
        let surface = Self.makeGlassSurface(contentView: contentContainer, cornerRadius: Self.cornerRadius)
        surface.frame = CGRect(origin: .zero, size: initialSize)
        contentView = surface
        update(phase: .ready, settings: settings, elapsedSeconds: 0)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticFrameUpdate else { return }
        hasCustomPosition = true
    }

    func updateCaptureRect(_ newRect: CGRect) {
        captureRect = newRect
        hasCustomPosition = false
        resizeToFitActiveRow(recenter: true)
    }

    func updateVisibleFrame(_ newVisibleFrame: CGRect) {
        guard !newVisibleFrame.isNull, !newVisibleFrame.isInfinite,
              newVisibleFrame.width > 0, newVisibleFrame.height > 0
        else { return }
        visibleFrame = newVisibleFrame
        resizeToFitActiveRow(recenter: !hasCustomPosition)
    }

    /// Stops animations, clears delegate and callbacks, and closes the panel cleanly.
    func tearDown() {
        spinner.stopAnimation(nil)
        delegate = nil
        onSettingsChanged = nil
        onStart = nil
        onTogglePause = nil
        onStop = nil
        onCancel = nil
        onCopy = nil
        onSave = nil
        onQuickSave = nil
        onReveal = nil
        onDiscard = nil
        orderOut(nil)
        close()
    }

    func setTemporarilyHidden(_ hidden: Bool) {
        alphaValue = hidden ? 0 : 1
        ignoresMouseEvents = hidden
    }

    func updateElapsedSeconds(_ elapsedSeconds: TimeInterval) {
        guard renderedPhase == .recording || renderedPhase == .paused else { return }
        let formatted = RecordingResult.formatDuration(elapsedSeconds)
        guard formatted != lastRenderedTimerText else { return }
        let lengthChanged = formatted.count != lastRenderedTimerText.count
        lastRenderedTimerText = formatted
        timerLabel.stringValue = formatted
        if lengthChanged {
            resizeToFitActiveRow(recenter: false)
        }
    }

    func update(phase: RecordingPhase, settings: RecordingSettings, elapsedSeconds: TimeInterval) {
        self.settings = settings
        let phaseChanged = renderedPhase != phase
        if !phaseChanged, lastRenderedSettings == settings {
            switch phase {
            case .recording, .paused:
                updateElapsedSeconds(elapsedSeconds)
            case .ready, .finalizing, .completed:
                break
            }
            return
        }

        renderedPhase = phase
        lastRenderedSettings = settings

        switch phase {
        case .ready:
            mountActiveRow(readyRow)
            lastRenderedTimerText = "00:00"
            formatControl.selectedFormat = settings.format
            fpsPicker.update(format: settings.format, selectedFPS: settings.effectiveFPS)

            let supportsAudio = settings.format.supportsAudio
            systemAudioButton.isEnabled = supportsAudio
            systemAudioButton.isActive = settings.effectiveSystemAudio
            systemAudioButton.toolTip = supportsAudio
                ? (
                    settings.effectiveSystemAudio
                        ? CCXL10n.text("System Audio: On", zh: "系统音频：开启")
                        : CCXL10n.text("System Audio: Off", zh: "系统音频：关闭")
                )
                : CCXL10n.text("System Audio (MP4 / MOV only)", zh: "系统音频（仅支持 MP4 / MOV）")

            micButton.isEnabled = supportsAudio
            micButton.isActive = settings.effectiveMicrophone
            micButton.toolTip = supportsAudio
                ? (
                    settings.effectiveMicrophone
                        ? CCXL10n.text("Microphone: On", zh: "麦克风：开启")
                        : CCXL10n.text("Microphone: Off", zh: "麦克风：关闭")
                )
                : CCXL10n.text("Microphone (MP4 / MOV only)", zh: "麦克风（仅支持 MP4 / MOV）")

            cursorButton.isActive = settings.showsCursor
            cursorButton.toolTip = settings.showsCursor
                ? CCXL10n.text("Mouse Cursor: Shown", zh: "鼠标指针：显示")
                : CCXL10n.text("Mouse Cursor: Hidden", zh: "鼠标指针：隐藏")
            spinner.stopAnimation(nil)

        case .recording:
            mountActiveRow(recordingRow)
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            let formatted = RecordingResult.formatDuration(elapsedSeconds)
            lastRenderedTimerText = formatted
            timerLabel.stringValue = formatted
            recordingBadgeLabel.stringValue = badgeSummary(for: settings, paused: false)
            recordingBadgeLabel.textColor = NSColor.white.withAlphaComponent(0.76)
            pauseResumeButton.configure(
                symbol: "pause.fill",
                tint: .white,
                tooltip: CCXL10n.text("Pause (Space)", zh: "暂停 (Space)"),
                isActive: false
            )
            spinner.stopAnimation(nil)

        case .paused:
            mountActiveRow(recordingRow)
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            let formatted = RecordingResult.formatDuration(elapsedSeconds)
            lastRenderedTimerText = formatted
            timerLabel.stringValue = formatted
            recordingBadgeLabel.stringValue = badgeSummary(for: settings, paused: true)
            recordingBadgeLabel.textColor = NSColor.systemOrange
            pauseResumeButton.configure(
                symbol: "play.fill",
                tint: .systemCyan,
                tooltip: CCXL10n.text("Resume (Space)", zh: "继续 (Space)"),
                isActive: true
            )
            spinner.stopAnimation(nil)

        case .finalizing:
            mountActiveRow(finalizingRow)
            finalizingLabel.stringValue = settings.format == .gif
                ? CCXL10n.text("Encoding GIF...", zh: "正在生成 GIF…")
                : CCXL10n.text("Saving \(settings.format.label)...", zh: "正在保存 \(settings.format.label)…")
            spinner.startAnimation(nil)

        case .completed(let result):
            mountActiveRow(completedRow)
            summaryLabel.stringValue = "\(result.format.label) · \(result.formattedDuration) · \(result.formattedFileSize)"
            spinner.stopAnimation(nil)
        }

        resizeToFitActiveRow(recenter: phaseChanged)
    }

    // MARK: - Test & Control Helpers

    func selectFormat(_ format: RecordingFormat) {
        var updated = settings
        updated.format = format
        settings = updated
        onSettingsChanged?(updated)
    }

    func selectFPS(_ fps: Int) {
        var updated = settings
        updated.setFPS(fps)
        guard updated != settings else { return }
        settings = updated
        onSettingsChanged?(updated)
    }

    func toggleSystemAudio() {
        guard settings.format.supportsAudio else { return }
        var updated = settings
        updated.capturesSystemAudio.toggle()
        settings = updated
        onSettingsChanged?(updated)
    }

    func toggleMicrophone() {
        guard settings.format.supportsAudio else { return }
        var updated = settings
        updated.capturesMicrophone.toggle()
        settings = updated
        onSettingsChanged?(updated)
    }

    func toggleCursor() {
        var updated = settings
        updated.showsCursor.toggle()
        settings = updated
        onSettingsChanged?(updated)
    }

    private func badgeSummary(for settings: RecordingSettings, paused: Bool) -> String {
        if paused {
            return CCXL10n.text("\(settings.format.label) · Paused", zh: "\(settings.format.label) · 已暂停")
        }
        let fps = settings.effectiveFPS
        guard settings.format.supportsAudio else { return "GIF · \(fps)fps" }
        switch (settings.effectiveSystemAudio, settings.effectiveMicrophone) {
        case (true, true):
            return CCXL10n.text("\(settings.format.label) · \(fps)fps · Sys+Mic", zh: "\(settings.format.label) · \(fps)fps · 系统+麦")
        case (true, false):
            return CCXL10n.text("\(settings.format.label) · \(fps)fps · Audio", zh: "\(settings.format.label) · \(fps)fps · 音频")
        case (false, true):
            return CCXL10n.text("\(settings.format.label) · \(fps)fps · Mic", zh: "\(settings.format.label) · \(fps)fps · 麦克风")
        case (false, false):
            return CCXL10n.text("\(settings.format.label) · \(fps)fps · Mute", zh: "\(settings.format.label) · \(fps)fps · 静音")
        }
    }

    // MARK: - Layout & Construction

    private func buildHierarchy() {
        buildReadyRow()
        buildRecordingRow()
        buildFinalizingRow()
        buildCompletedRow()
    }

    private func mountActiveRow(_ row: NSStackView) {
        guard activeRow !== row else { return }
        activeRow?.removeFromSuperview()
        row.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        activeRow = row
    }

    private func resizeToFitActiveRow(recenter: Bool) {
        guard let activeRow else { return }
        activeRow.layoutSubtreeIfNeeded()
        let targetWidth = max(156, ceil(activeRow.fittingSize.width))
        let targetSize = CGSize(width: targetWidth, height: Self.panelHeight)
        let shouldRecenter = recenter && !hasCustomPosition
        let widthChanged = abs(frame.width - targetSize.width) >= 1
        let heightChanged = abs(frame.height - targetSize.height) >= 1
        guard shouldRecenter || widthChanged || heightChanged else { return }

        let nextFrame: CGRect
        if shouldRecenter {
            nextFrame = Self.frame(for: captureRect, size: targetSize, visibleFrame: visibleFrame)
        } else {
            let clampFrame = resolvedClampFrameForCustomPosition()
            let centeredX = (frame.midX - targetSize.width / 2).rounded()
            let maxX = max(clampFrame.minX + 8, clampFrame.maxX - targetSize.width - 8)
            let clampedX = min(max(centeredX, clampFrame.minX + 8), maxX)
            let maxY = max(clampFrame.minY + 6, clampFrame.maxY - targetSize.height - 6)
            let clampedY = min(max(frame.minY, clampFrame.minY + 6), maxY)
            nextFrame = CGRect(x: clampedX, y: clampedY, width: targetSize.width, height: targetSize.height)
        }
        isProgrammaticFrameUpdate = true
        setFrame(nextFrame, display: true)
        isProgrammaticFrameUpdate = false
        let boundsRect = CGRect(origin: .zero, size: targetSize)
        contentView?.frame = boundsRect
        contentContainer.frame = boundsRect
        contentView?.layoutSubtreeIfNeeded()
    }

    private func buildReadyRow() {
        readyRow.orientation = .horizontal
        readyRow.alignment = .centerY
        readyRow.spacing = 6
        readyRow.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

        formatControl.onSelectFormat = { [weak self] selected in
            self?.selectFormat(selected)
        }
        fpsPicker.onSelectFPS = { [weak self] fps in
            self?.selectFPS(fps)
        }

        systemAudioButton.onTap = { [weak self] in self?.toggleSystemAudio() }
        micButton.onTap = { [weak self] in self?.toggleMicrophone() }
        cursorButton.onTap = { [weak self] in self?.toggleCursor() }

        let audioTogglesStack = NSStackView(views: [systemAudioButton, micButton, cursorButton])
        audioTogglesStack.orientation = .horizontal
        audioTogglesStack.alignment = .centerY
        audioTogglesStack.spacing = 4
        audioTogglesStack.setHuggingPriority(.required, for: .horizontal)

        let startButton = PrimaryPillButton(
            symbol: "record.circle.fill",
            title: CCXL10n.text("Start", zh: "开始录制"),
            backgroundColor: .systemRed,
            tooltip: CCXL10n.text("Start Recording (Return / Space)", zh: "开始录制 (Return / Space)")
        ) { [weak self] in
            self?.onStart?()
        }
        let cancelButton = CloseIconButton(tooltip: CCXL10n.text("Cancel (Esc)", zh: "取消 (Esc)")) { [weak self] in
            self?.onCancel?()
        }

        readyRow.addArrangedSubview(formatControl)
        readyRow.addArrangedSubview(fpsPicker)
        readyRow.addArrangedSubview(Self.makeDivider())
        readyRow.addArrangedSubview(audioTogglesStack)
        readyRow.addArrangedSubview(Self.makeDivider())
        readyRow.addArrangedSubview(startButton)
        readyRow.addArrangedSubview(cancelButton)
    }

    private func buildRecordingRow() {
        recordingRow.orientation = .horizontal
        recordingRow.alignment = .centerY
        recordingRow.spacing = 6
        recordingRow.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        timerLabel.textColor = .white
        timerLabel.setContentHuggingPriority(.required, for: .horizontal)
        timerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        recordingBadgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        recordingBadgeLabel.textColor = NSColor.white.withAlphaComponent(0.76)
        recordingBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        recordingBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let infoStack = NSStackView(views: [timerLabel, recordingBadgeLabel])
        infoStack.orientation = .horizontal
        infoStack.alignment = .firstBaseline
        infoStack.spacing = 6
        infoStack.setHuggingPriority(.required, for: .horizontal)

        pauseResumeButton.onTap = { [weak self] in self?.onTogglePause?() }

        let stopButton = PrimaryPillButton(
            symbol: "stop.fill",
            title: CCXL10n.text("Stop", zh: "停止"),
            backgroundColor: .systemRed,
            tooltip: CCXL10n.text("Stop Recording (Return)", zh: "停止录制 (Return)")
        ) { [weak self] in
            self?.onStop?()
        }
        let discardButton = CloseIconButton(tooltip: CCXL10n.text("Cancel Recording (Esc)", zh: "取消录制 (Esc)")) { [weak self] in
            self?.onCancel?()
        }

        recordingRow.addArrangedSubview(statusDot)
        recordingRow.addArrangedSubview(infoStack)
        recordingRow.addArrangedSubview(Self.makeDivider())
        recordingRow.addArrangedSubview(pauseResumeButton)
        recordingRow.addArrangedSubview(stopButton)
        recordingRow.addArrangedSubview(discardButton)
    }

    private func resolvedClampFrameForCustomPosition() -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let matchingScreen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return matchingScreen.visibleFrame
        }
        if let currentScreen = screen {
            return currentScreen.visibleFrame
        }
        return visibleFrame
    }

    private func buildFinalizingRow() {
        finalizingRow.orientation = .horizontal
        finalizingRow.alignment = .centerY
        finalizingRow.spacing = 8
        finalizingRow.edgeInsets = NSEdgeInsets(top: 7, left: 16, bottom: 7, right: 10)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        finalizingLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        finalizingLabel.textColor = .white
        finalizingLabel.setContentHuggingPriority(.required, for: .horizontal)
        finalizingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let cancelButton = CloseIconButton(tooltip: CCXL10n.text("Cancel Finalizing", zh: "取消保存")) { [weak self] in
            self?.onCancel?()
        }

        finalizingRow.addArrangedSubview(spinner)
        finalizingRow.addArrangedSubview(finalizingLabel)
        finalizingRow.addArrangedSubview(cancelButton)
    }

    private func buildCompletedRow() {
        completedRow.orientation = .horizontal
        completedRow.alignment = .centerY
        completedRow.spacing = 6
        completedRow.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)

        let doneIcon = NSImageView()
        let doneConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        doneIcon.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: CCXL10n.text("Recorded", zh: "录制完成")
        )?
            .withSymbolConfiguration(doneConfig)
        doneIcon.contentTintColor = .systemGreen
        doneIcon.imageScaling = .scaleNone
        doneIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doneIcon.widthAnchor.constraint(equalToConstant: 16),
            doneIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        summaryLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        summaryLabel.textColor = .white
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let summaryStack = NSStackView(views: [doneIcon, summaryLabel])
        summaryStack.orientation = .horizontal
        summaryStack.alignment = .centerY
        summaryStack.spacing = 5
        summaryStack.setHuggingPriority(.required, for: .horizontal)

        let copyButton = HUDIconOnlyButton(symbol: "doc.on.doc", tooltip: CCXL10n.text("Copy File (⌘C)", zh: "拷贝文件 (⌘C)")) { [weak self] in
            self?.onCopy?()
        }
        let saveButton = HUDIconOnlyButton(symbol: "square.and.arrow.down", tooltip: CCXL10n.text("Save As (⌘S)", zh: "另存为 (⌘S)")) { [weak self] in
            self?.onSave?()
        }
        let revealButton = HUDIconOnlyButton(symbol: "folder", tooltip: CCXL10n.text("Save & Reveal in Finder", zh: "保存并在访达中显示")) { [weak self] in
            self?.onReveal?()
        }
        let actionsStack = NSStackView(views: [copyButton, saveButton, revealButton])
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 4
        actionsStack.setHuggingPriority(.required, for: .horizontal)

        let quickSaveButton = PrimaryPillButton(
            symbol: "arrow.down.circle.fill",
            title: CCXL10n.text("Quick Save", zh: "快速保存"),
            backgroundColor: .systemGreen,
            tooltip: CCXL10n.text("Quick Save (Return / ⇧⌘S)", zh: "快速保存 (Return / ⇧⌘S)")
        ) { [weak self] in
            self?.onQuickSave?()
        }
        let discardButton = CloseIconButton(tooltip: CCXL10n.text("Discard (Esc)", zh: "丢弃 (Esc)")) { [weak self] in
            self?.onDiscard?()
        }

        completedRow.addArrangedSubview(summaryStack)
        completedRow.addArrangedSubview(Self.makeDivider())
        completedRow.addArrangedSubview(actionsStack)
        completedRow.addArrangedSubview(quickSaveButton)
        completedRow.addArrangedSubview(discardButton)
    }

    static func frame(for captureRect: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let gap: CGFloat = 8
        var origin = CGPoint(x: (captureRect.midX - size.width / 2).rounded(), y: captureRect.minY - gap - size.height)
        if origin.y < visibleFrame.minY + 6 {
            let aboveY = captureRect.maxY + gap
            if aboveY + size.height <= visibleFrame.maxY - 6 {
                origin.y = aboveY
            } else {
                origin.y = visibleFrame.minY + 14
            }
        }
        let maxX = max(visibleFrame.minX + 8, visibleFrame.maxX - size.width - 8)
        let maxY = max(visibleFrame.minY + 6, visibleFrame.maxY - size.height - 6)
        origin.x = min(max(origin.x, visibleFrame.minX + 8), maxX)
        origin.y = min(max(origin.y, visibleFrame.minY + 6), maxY)
        return CGRect(origin: origin, size: size)
    }

    private static func makeGlassSurface(contentView: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            contentView.autoresizingMask = [.width, .height]
            glass.contentView = contentView
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
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
        wrapper.setContentHuggingPriority(.required, for: .horizontal)
        wrapper.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
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

// MARK: - HUD Button Controls

private class HUDHoverButton: NSButton {
    var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateAppearance()
        }
    }
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
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

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    func updateAppearance() {}
}

@MainActor
private final class FormatSegmentedControl: NSView {
    var onSelectFormat: ((RecordingFormat) -> Void)?

    var selectedFormat: RecordingFormat = .mp4 {
        didSet {
            for (format, button) in segmentButtons {
                button.isChosen = (format == selectedFormat)
            }
        }
    }

    private var segmentButtons: [RecordingFormat: FormatSegmentButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for format in RecordingFormat.allCases {
            let button = FormatSegmentButton(format: format) { [weak self] selected in
                self?.onSelectFormat?(selected)
            }
            segmentButtons[format] = button
            stack.addArrangedSubview(button)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class FormatSegmentButton: HUDHoverButton {
    private let format: RecordingFormat
    private let handler: (RecordingFormat) -> Void
    var isChosen = false {
        didSet {
            guard oldValue != isChosen else { return }
            updateAppearance()
        }
    }

    init(format: RecordingFormat, handler: @escaping (RecordingFormat) -> Void) {
        self.format = format
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = "\(format.label) (\(format.detailDescription))"
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 40),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { handler(format) }

    override func updateAppearance() {
        let textColor: NSColor = isChosen ? .white : NSColor.white.withAlphaComponent(0.72)
        attributedTitle = NSAttributedString(
            string: format.label,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: isChosen ? .bold : .semibold), .foregroundColor: textColor]
        )
        if isChosen {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.90).cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

@MainActor
private final class FPSPickerControl: NSView {
    var onSelectFPS: ((Int) -> Void)?

    private(set) var currentFormat: RecordingFormat = .mp4
    private(set) var selectedFPS: Int = RecordingFormat.mp4.targetFPS
    var currentOptions: [Int] { currentFormat.availableFPSOptions }
    var displayText: String { fpsLabel.stringValue }

    private let fpsLabel = NSTextField(labelWithString: "60 fps")
    private let chevronView = NSImageView()
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateAppearance()
        }
    }
    private(set) var isMenuOpen = false {
        didSet {
            guard oldValue != isMenuOpen else { return }
            updateAppearance()
        }
    }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        let frameRateTitle = CCXL10n.text("Frame Rate", zh: "帧率")
        toolTip = frameRateTitle
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(frameRateTitle)
        setAccessibilityValue("60 fps")

        fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        fpsLabel.textColor = .white
        fpsLabel.setContentHuggingPriority(.required, for: .horizontal)
        fpsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevronView.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: frameRateTitle)?
            .withSymbolConfiguration(chevronConfig)
        chevronView.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        chevronView.imageScaling = .scaleNone
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 14),
        ])

        let stack = NSStackView(views: [fpsLabel, chevronView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

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

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu(title: CCXL10n.text("Frame Rate", zh: "帧率"))
        menu.appearance = NSAppearance(named: .darkAqua)
        for fps in currentFormat.availableFPSOptions {
            let item = NSMenuItem(
                title: currentFormat.fpsOptionDescription(for: fps),
                action: #selector(fpsItemChosen(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = fps
            item.state = (fps == selectedFPS) ? .on : .off
            menu.addItem(item)
        }
        isMenuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
        isMenuOpen = false
    }

    @objc private func fpsItemChosen(_ sender: NSMenuItem) {
        guard let fps = sender.representedObject as? Int else { return }
        onSelectFPS?(fps)
    }

    func update(format: RecordingFormat, selectedFPS: Int) {
        self.currentFormat = format
        self.selectedFPS = selectedFPS
        fpsLabel.stringValue = "\(selectedFPS) fps"
        let desc = currentFormat.fpsOptionDescription(for: selectedFPS)
        toolTip = CCXL10n.text("Frame Rate: \(desc)", zh: "帧率：\(desc)")
        setAccessibilityValue(fpsLabel.stringValue)
        invalidateIntrinsicContentSize()
    }

    private func updateAppearance() {
        let bgAlpha: CGFloat = isMenuOpen ? 0.22 : (isHovering ? 0.16 : 0.08)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(bgAlpha).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(isMenuOpen || isHovering ? 0.20 : 0.10).cgColor
    }
}

private final class HUDIconToggleButton: HUDHoverButton {
    var onTap: (() -> Void)?
    private var activeSymbol: String
    private var inactiveSymbol: String
    private var activeTint: NSColor
    private var renderedSymbolName: String?

    var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            updateAppearance()
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            updateAppearance()
        }
    }

    init(activeSymbol: String, inactiveSymbol: String, activeTint: NSColor) {
        self.activeSymbol = activeSymbol
        self.inactiveSymbol = inactiveSymbol
        self.activeTint = activeTint
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 8
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(symbol: String, tint: NSColor, tooltip: String, isActive: Bool) {
        guard self.activeSymbol != symbol
            || self.inactiveSymbol != symbol
            || self.activeTint != tint
            || self.toolTip != tooltip
            || self.isActive != isActive
        else { return }
        self.activeSymbol = symbol
        self.inactiveSymbol = symbol
        self.activeTint = tint
        self.toolTip = tooltip
        if self.isActive != isActive {
            self.isActive = isActive
        } else {
            updateAppearance()
        }
    }

    @objc private func pressed() { onTap?() }

    override func updateAppearance() {
        let activeOn = isEnabled && isActive
        let symbolName = activeOn ? activeSymbol : inactiveSymbol
        if renderedSymbolName != symbolName {
            renderedSymbolName = symbolName
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
                .withSymbolConfiguration(config)
        }
        setAccessibilityLabel(toolTip)
        let fg: NSColor = activeOn ? activeTint : NSColor.white.withAlphaComponent(0.50)
        contentTintColor = fg
        alphaValue = isEnabled ? 1.0 : 0.30
        if activeOn {
            let baseAlpha: CGFloat = activeTint == .white ? (isHovering ? 0.24 : 0.18) : (isHovering ? 0.30 : 0.20)
            layer?.backgroundColor = activeTint.withAlphaComponent(baseAlpha).cgColor
        } else if isHovering && isEnabled {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        }
    }
}

private final class PrimaryPillButton: HUDHoverButton {
    private let handler: () -> Void
    private let pillColor: NSColor

    init(symbol: String, title: String, backgroundColor: NSColor, tooltip: String, handler: @escaping () -> Void) {
        self.pillColor = backgroundColor
        self.handler = handler
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        contentTintColor = .white
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 8
        toolTip = tooltip
        target = self
        action = #selector(pressed)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white]
        )
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: max(68, ceil(base.width) + 22), height: 30)
    }

    @objc private func pressed() { handler() }

    override func updateAppearance() {
        layer?.backgroundColor = pillColor.withAlphaComponent(isHovering ? 1.0 : 0.90).cgColor
    }
}

private final class HUDIconOnlyButton: HUDHoverButton {
    private let handler: () -> Void

    init(symbol: String, tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        contentTintColor = .white
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 8
        toolTip = tooltip
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { handler() }

    override func updateAppearance() {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isHovering ? 0.20 : 0.08).cgColor
    }
}

private final class CloseIconButton: HUDHoverButton {
    private let handler: () -> Void

    init(tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        contentTintColor = NSColor.white.withAlphaComponent(0.78)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 8
        toolTip = tooltip
        target = self
        action = #selector(pressed)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func pressed() { handler() }

    override func updateAppearance() {
        if isHovering {
            contentTintColor = .systemRed
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        } else {
            contentTintColor = NSColor.white.withAlphaComponent(0.78)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        }
    }
}

@MainActor
private final class ArrowCursorContainerView: NSView {
    private var cursorArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

private extension NSWindow.Level {
    static let statusBarLevelPlusOne = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}
