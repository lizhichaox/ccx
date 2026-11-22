import AppKit
import CPXCore

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
    private let onFinish: (SnipOutcome) -> Void
    private var panels: [SnipOverlayPanel] = []
    private var views: [SnipOverlayView] = []
    private var isFinished = false

    init(snapshots: [DisplaySnapshot], detector: SmartElementDetector, onFinish: @escaping (SnipOutcome) -> Void) {
        self.snapshots = snapshots
        self.detector = detector
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

            let view = SnipOverlayView(snapshot: snapshot, topInset: topInset)
            view.hoverRectProvider = { [weak self] global in self?.detector.windowRect(at: global) }
            view.elementRectRequester = { [weak self, weak view] global in
                self?.detector.requestElementRect(at: global) { rect, point in
                    view?.applyRefinedElementRect(rect, forGlobalPoint: point)
                }
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
                self.finish(action, from: view.snapshot)
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

    private func finish(_ action: OverlayAction, from snapshot: DisplaySnapshot) {
        guard !isFinished else { return }
        let outcome: SnipOutcome
        switch action {
        case let .pin(rect):
            outcome = Self.makeResult(localRect: rect, snapshot: snapshot).map(SnipOutcome.pin) ?? .cancelled
        case let .copy(rect):
            outcome = Self.makeResult(localRect: rect, snapshot: snapshot).map(SnipOutcome.copy) ?? .cancelled
        case let .save(rect):
            outcome = Self.makeResult(localRect: rect, snapshot: snapshot).map(SnipOutcome.save) ?? .cancelled
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
}
