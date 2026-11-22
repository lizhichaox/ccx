import AppKit
import CCXAnnotate
import CCXCore

/// Borderless, non-activating overlay panel that can still become key for keyboard shortcuts.
final class SnipOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns one `SnipOverlayPanel` per display for the duration of a snip session.
@MainActor
final class SnipOverlayController {
    private let snapshots: [DisplaySnapshot]
    private let detector: SmartElementDetector
    private let initialStyle: AnnotationStyle
    private let previousSelections: [CGDirectDisplayID: CGRect]
    private let onStyleUpdated: ((AnnotationStyle) -> Void)?
    private let onSelectionCommitted: ((CGDirectDisplayID, CGRect) -> Void)?
    private let onRequestScrollCapture: ((ScrollCaptureRequest) -> Void)?
    private let onFinish: (SnipOutcome) -> Void
    private var panels: [SnipOverlayPanel] = []
    private var views: [SnipOverlayView] = []
    private var isFinished = false

    init(
        snapshots: [DisplaySnapshot],
        detector: SmartElementDetector,
        initialStyle: AnnotationStyle = AnnotationStyle(),
        previousSelections: [CGDirectDisplayID: CGRect] = [:],
        onStyleUpdated: ((AnnotationStyle) -> Void)? = nil,
        onSelectionCommitted: ((CGDirectDisplayID, CGRect) -> Void)? = nil,
        onRequestScrollCapture: ((ScrollCaptureRequest) -> Void)? = nil,
        onFinish: @escaping (SnipOutcome) -> Void
    ) {
        self.snapshots = snapshots
        self.detector = detector
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
        var keyPanel: SnipOverlayPanel?

        for snapshot in snapshots {
            let screen = screensByID[snapshot.displayID]
            let topInset = screen?.safeAreaInsets.top ?? 0
            let panel = SnipOverlayPanel(
                contentRect: snapshot.screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.animationBehavior = .none
            panel.setFrame(snapshot.screenFrame, display: false)

            let view = SnipOverlayView(
                snapshot: snapshot,
                topInset: topInset,
                initialStyle: initialStyle,
                previousSelectionRect: previousSelections[snapshot.displayID]
            )
            view.hoverRectProvider = { [weak self] global in self?.detector.windowRect(at: global) }
            view.elementRectRequester = { [weak self, weak view] global in
                self?.detector.requestElementRect(at: global) { rect, point in
                    view?.applyRefinedElementRect(rect, forGlobalPoint: point)
                }
            }
            view.onStyleUpdated = { [weak self] style in
                self?.onStyleUpdated?(style)
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
            panels.append(panel)
            views.append(view)
            if snapshot.screenFrame.contains(mouse) { keyPanel = panel }
        }

        for view in views { view.primeWithMouseLocation(mouse) }
        NSApp.activate()
        for panel in panels { panel.orderFrontRegardless() }
        let key = keyPanel ?? panels.first
        key?.makeKeyAndOrderFront(nil)
        if let key, let view = key.contentView { key.makeFirstResponder(view) }
    }

    /// Tears down all panels without reporting an outcome.
    func close() {
        isFinished = true
        detector.cancelPendingRequests()
        NSCursor.arrow.set()
        for panel in panels { panel.orderOut(nil) }
        for view in views {
            view.onFinish = nil
            view.onBeginInteraction = nil
            view.shouldBecomeKeyOnHover = nil
            view.hoverRectProvider = nil
            view.elementRectRequester = nil
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
            outcome = renderResult(for: rect).map(SnipOutcome.pin) ?? .cancelled
        case let .copy(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.copy) ?? .cancelled
        case let .save(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.save) ?? .cancelled
        case let .quickSave(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.quickSave) ?? .cancelled
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
                onFinish(.cancelled)
            }
            return
        case let .ocr(rect):
            outcome = renderResult(for: rect).map(SnipOutcome.ocr) ?? .cancelled
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
