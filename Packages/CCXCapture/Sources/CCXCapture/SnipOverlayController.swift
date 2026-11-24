import AppKit
import CCXAnnotate
import CCXCore

/// Borderless, non-activating overlay panel that can still become key for keyboard shortcuts.
final class SnipOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Owns one `SnipOverlayPanel` per display for the duration of a snip session.
@MainActor
final class SnipOverlayController {
    private let snapshots: [DisplaySnapshot]
    private let detector: SmartElementDetector
    private let selectionMode: SnipSelectionMode
    private let initialStyle: AnnotationStyle
    private let previousSelections: [CGDirectDisplayID: CGRect]
    private let onStyleUpdated: ((AnnotationStyle) -> Void)?
    private let onSelectionCommitted: ((CGDirectDisplayID, CGRect) -> Void)?
    private let onRequestScrollCapture: ((ScrollCaptureRequest) -> Void)?
    private let onFinish: (SnipOutcome) -> Void
    private var panels: [SnipOverlayPanel] = []
    private var views: [SnipOverlayView] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var isFinished = false

    init(
        snapshots: [DisplaySnapshot],
        detector: SmartElementDetector,
        selectionMode: SnipSelectionMode = .snip,
        initialStyle: AnnotationStyle = AnnotationStyle(),
        previousSelections: [CGDirectDisplayID: CGRect] = [:],
        onStyleUpdated: ((AnnotationStyle) -> Void)? = nil,
        onSelectionCommitted: ((CGDirectDisplayID, CGRect) -> Void)? = nil,
        onRequestScrollCapture: ((ScrollCaptureRequest) -> Void)? = nil,
        onFinish: @escaping (SnipOutcome) -> Void
    ) {
        self.snapshots = snapshots
        self.detector = detector
        self.selectionMode = selectionMode
        self.initialStyle = initialStyle
        self.previousSelections = previousSelections
        self.onStyleUpdated = onStyleUpdated
        self.onSelectionCommitted = onSelectionCommitted
        self.onRequestScrollCapture = onRequestScrollCapture
        self.onFinish = onFinish
    }

    func show() {
        let screensByID = Dictionary(
            NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return nil
                }
                return (CGDirectDisplayID(number.uint32Value), screen)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let mouse = NSEvent.mouseLocation
        let activeIndex = Self.matchingSnapshotIndex(for: mouse, in: snapshots.map(\.screenFrame))
        var keyPanel: SnipOverlayPanel?

        for (index, snapshot) in snapshots.enumerated() {
            let screen = screensByID[snapshot.displayID]
            let topInset = screen?.safeAreaInsets.top ?? 0
            let panel = SnipOverlayPanel(
                contentRect: snapshot.screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            Self.configurePanel(panel, frame: snapshot.screenFrame)

            let view = SnipOverlayView(
                snapshot: snapshot,
                topInset: topInset,
                selectionMode: selectionMode,
                initialStyle: initialStyle,
                previousSelectionRect: previousSelections[snapshot.displayID]
            )
            view.hoverRectProvider = { [weak self] global in self?.detector.windowRect(at: global) }
            view.shouldQueryElementRect = { [weak self] global in
                self?.detector.shouldRequestElementRect(at: global) ?? false
            }
            view.elementRectRequester = { [weak self, weak view] global in
                guard let self, let view else { return }
                let epoch = view.axEpoch
                self.detector.requestElementRect(at: global) { rect, point, isOverlay in
                    view.applyRefinedElementRect(
                        rect,
                        forGlobalPoint: point,
                        isOverlayElement: isOverlay,
                        epoch: epoch
                    )
                }
            }
            view.cancelElementRectRequests = { [weak self] in
                self?.detector.cancelPendingRequests()
            }
            view.onStyleUpdated = { [weak self] style in
                self?.onStyleUpdated?(style)
            }
            view.onHoverActive = { [weak self, weak view] in
                guard let self, let view else { return }
                for other in self.views where other !== view && other.machine.isHovering {
                    other.clearHover()
                }
            }
            view.hasSiblingSelection = { [weak self, weak view] in
                guard let self, let view else { return false }
                return self.views.contains { $0 !== view && !$0.machine.isHovering }
            }
            view.onBeginInteraction = { [weak self, weak view] in
                guard let self, let view else { return }
                for other in self.views where other !== view { other.resetSelection() }
            }
            view.shouldBecomeKeyOnHover = { [weak self] in
                guard let self else { return true }
                return !self.views.contains { !$0.machine.isHovering }
            }
            view.onFinish = { [weak self, weak view] action in
                guard let self, let view else { return }
                self.finish(action, from: view)
            }
            panel.contentView = view
            panel.initialFirstResponder = view
            panel.makeFirstResponder(view)
            panels.append(panel)
            views.append(view)
            if index == activeIndex { keyPanel = panel }
        }

        for (index, view) in views.enumerated() {
            view.primeWithMouseLocation(mouse, allowClosedEdge: index == activeIndex)
        }
        for panel in panels { panel.orderFrontRegardless() }
        let key = keyPanel ?? panels.first
        key?.makeKeyAndOrderFront(nil)
        if let key, let view = key.contentView {
            key.makeFirstResponder(view)
            (view as? SnipOverlayView)?.invalidateCursor()
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func handleScreenParametersChanged() {
        guard !isFinished else { return }
        close()
        onFinish(.cancelled)
    }

    /// Finds the display index containing `globalPoint`, preferring strict half-open containment
    /// and falling back to inclusive edges so top Menu Bar / right-edge points still match.
    nonisolated static func matchingSnapshotIndex(for globalPoint: CGPoint, in frames: [CGRect]) -> Int? {
        if let strict = frames.firstIndex(where: { $0.contains(globalPoint) }) {
            return strict
        }
        return frames.firstIndex { frame in
            globalPoint.x >= frame.minX && globalPoint.x <= frame.maxX &&
            globalPoint.y >= frame.minY && globalPoint.y <= frame.maxY
        }
    }

    static func configurePanel(_ panel: SnipOverlayPanel, frame: CGRect) {
        // Setting `isFloatingPanel` resets `level` to `.floating`, so assign `.screenSaver` afterward.
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.setFrame(frame, display: false)
    }

    /// Tears down all panels without reporting an outcome.
    func close() {
        isFinished = true
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        detector.cancelPendingRequests()
        NSCursor.arrow.set()
        for view in views {
            view.tearDown()
            view.onFinish = nil
            view.onBeginInteraction = nil
            view.onHoverActive = nil
            view.hasSiblingSelection = nil
            view.shouldBecomeKeyOnHover = nil
            view.hoverRectProvider = nil
            view.shouldQueryElementRect = nil
            view.elementRectRequester = nil
            view.cancelElementRectRequests = nil
            view.onStyleUpdated = nil
        }
        for panel in panels {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panels.removeAll()
        views.removeAll()
    }

    private func finish(_ action: OverlayAction, from view: SnipOverlayView) {
        guard !isFinished else { return }
        func renderResult(for rect: CGRect) -> SnipResult? {
            let result = Self.makeResult(
                localRect: rect,
                snapshot: view.snapshot,
                document: view.annotations,
                mosaicCache: view.mosaicCache
            )
            if result != nil {
                onSelectionCommitted?(view.snapshot.displayID, rect)
            }
            return result
        }
        let outcome: SnipOutcome
        switch action {
        case let .pin(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.pin) ?? .failed("Could not render selected region")
        case let .copy(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.copy) ?? .failed("Could not render selected region")
        case let .save(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.save) ?? .failed("Could not render selected region")
        case let .quickSave(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.quickSave) ?? .failed("Could not render selected region")
        case let .scroll(rect):
            let initialResult = Self.makeResult(localRect: rect, snapshot: view.snapshot)
            if initialResult != nil {
                onSelectionCommitted?(view.snapshot.displayID, rect)
            }
            close()
            if let initialResult, let onRequestScrollCapture {
                let request = ScrollCaptureRequest(
                    displayID: view.snapshot.displayID,
                    displayFrame: view.snapshot.screenFrame,
                    localRect: rect,
                    screenRect: initialResult.screenRect,
                    scale: initialResult.scale,
                    initialImage: initialResult.image
                )
                onRequestScrollCapture(request)
            } else {
                onFinish(.failed("Could not render selected region"))
            }
            return
        case let .ocr(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.ocr) ?? .failed("Could not render selected region")
        case let .record(rect):
            let standardized = rect.standardized
            let localBounds = CGRect(origin: .zero, size: view.snapshot.screenFrame.size)
            let clipped = standardized.intersection(localBounds)
            let effectiveLocal = (!clipped.isNull && clipped.width >= 1 && clipped.height >= 1) ? clipped : standardized
            let scale = view.snapshot.screenFrame.width > 0
                ? CGFloat(view.snapshot.image.width) / view.snapshot.screenFrame.width
                : view.snapshot.backingScaleFactor
            let screenRect = effectiveLocal.offsetBy(dx: view.snapshot.screenFrame.minX, dy: view.snapshot.screenFrame.minY)
            onSelectionCommitted?(view.snapshot.displayID, effectiveLocal)
            outcome = .record(RecordRegionRequest(
                displayID: view.snapshot.displayID,
                displayFrame: view.snapshot.screenFrame,
                localRect: effectiveLocal,
                screenRect: screenRect,
                scale: scale
            ))
        case let .copyColor(sample, format):
            outcome = .copiedColor(sample, format)
        case .cancel:
            outcome = .cancelled
        }
        close()
        onFinish(outcome)
    }

    /// Crops the exact backing pixels for a view-local AppKit rect from a display snapshot.
    nonisolated static func makeResult(localRect: CGRect, snapshot: DisplaySnapshot) -> SnipResult? {
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixelRect = CoordinateConverter.appKitLocalRectToImagePixelRect(
            localRect,
            screenSize: snapshot.screenFrame.size,
            imageSize: imageSize
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1, let cropped = snapshot.image.cropping(to: pixelRect) else {
            return nil
        }
        let scale = snapshot.screenFrame.width > 0 ? imageSize.width / snapshot.screenFrame.width : snapshot.backingScaleFactor
        let screenRect = localRect.offsetBy(dx: snapshot.screenFrame.minX, dy: snapshot.screenFrame.minY)
        return SnipResult(image: cropped, scale: scale, screenRect: screenRect)
    }

    /// Crops the exact backing pixels and bakes any committed annotations at full Retina resolution.
    static func makeResult(
        localRect: CGRect,
        snapshot: DisplaySnapshot,
        document: AnnotationDocument?,
        mosaicCache: MosaicImageCache?
    ) -> SnipResult? {
        guard let document, !document.items.isEmpty else {
            return makeResult(localRect: localRect, snapshot: snapshot)
        }
        let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
        let pixelRect = CoordinateConverter.appKitLocalRectToImagePixelRect(
            localRect,
            screenSize: snapshot.screenFrame.size,
            imageSize: imageSize
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        guard let baked = AnnotationRenderer.bake(
            baseImage: snapshot.image,
            localSelectionRect: localRect,
            pixelCropRect: pixelRect,
            screenSize: snapshot.screenFrame.size,
            document: document,
            mosaicCache: mosaicCache
        ) else {
            return nil
        }
        let scale = snapshot.screenFrame.width > 0 ? imageSize.width / snapshot.screenFrame.width : snapshot.backingScaleFactor
        let screenRect = localRect.offsetBy(dx: snapshot.screenFrame.minX, dy: snapshot.screenFrame.minY)
        return SnipResult(image: baked, scale: scale, screenRect: screenRect)
    }
}
