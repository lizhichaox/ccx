import AppKit
import CCXAnnotate
import CCXCore
import os
import ScreenCaptureKit

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
    private static let silhouetteCommitTimeoutNanoseconds: UInt64 = 120_000_000
    private static let maxCachedSilhouettes = 8

    private let snapshots: [DisplaySnapshot]
    private let detector: SmartElementDetector
    private let shareableWindows: [CGWindowID: UncheckedSendableBox<SCWindow>]
    private let silhouetteProvider: (@Sendable (CGWindowID, CGFloat) async -> CapturedWindowSilhouette?)?
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
    private var silhouetteTasks: [CGWindowID: Task<CapturedWindowSilhouette?, Never>] = [:]
    private var resolvedSilhouettes: [CGWindowID: CapturedWindowSilhouette?] = [:]
    private var resolvedSilhouetteOrder: [CGWindowID] = []
    private var previewUpdateTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var finishTask: Task<Void, Never>?
    private var isFinishing = false
    private var isClosed = false

    init(
        snapshots: [DisplaySnapshot],
        detector: SmartElementDetector,
        shareableWindows: [CGWindowID: UncheckedSendableBox<SCWindow>] = [:],
        silhouetteProvider: (@Sendable (CGWindowID, CGFloat) async -> CapturedWindowSilhouette?)? = nil,
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
        self.shareableWindows = shareableWindows
        self.silhouetteProvider = silhouetteProvider
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
            view.onSelectionChanged = { [weak self, weak view] localRect in
                guard let self, let view else { return }
                self.handleSelectionChanged(localRect, on: view)
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
        guard !isClosed, !isFinishing else { return }
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

    /// Wires a view directly to this controller without ordering screen-covering panels on screen.
    internal func attachViewForTesting(_ view: SnipOverlayView) {
        view.hoverRectProvider = { [weak self] global in self?.detector.windowRect(at: global) }
        view.onSelectionChanged = { [weak self, weak view] localRect in
            guard let self, let view else { return }
            self.handleSelectionChanged(localRect, on: view)
        }
        view.onFinish = { [weak self, weak view] action in
            guard let self, let view else { return }
            self.finish(action, from: view)
        }
        views.append(view)
    }

    /// Tears down all panels without reporting an outcome.
    func close() {
        isClosed = true
        isFinishing = true
        finishTask?.cancel()
        finishTask = nil
        for task in previewUpdateTasks.values { task.cancel() }
        previewUpdateTasks.removeAll()
        for task in silhouetteTasks.values { task.cancel() }
        silhouetteTasks.removeAll()
        resolvedSilhouettes.removeAll()
        resolvedSilhouetteOrder.removeAll()

        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        detector.cancelPendingRequests()
        NSCursor.arrow.set()
        for view in views {
            view.tearDown()
            view.onFinish = nil
            view.onSelectionChanged = nil
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

    // MARK: - Adaptive Window-Corner Silhouette Prefetch

    private func hasSilhouetteSource(for windowID: CGWindowID) -> Bool {
        resolvedSilhouettes.keys.contains(windowID)
            || silhouetteTasks[windowID] != nil
            || shareableWindows[windowID] != nil
            || silhouetteProvider != nil
    }

    private struct SilhouetteWaitState: Sendable {
        var continuation: CheckedContinuation<CapturedWindowSilhouette?, Never>?
        var timerTask: Task<Void, Never>?
        var waitTask: Task<Void, Never>?
        var isResolved = false
    }

    private func cacheResolvedSilhouette(_ silhouette: CapturedWindowSilhouette?, for windowID: CGWindowID) {
        resolvedSilhouettes[windowID] = silhouette
        resolvedSilhouetteOrder.removeAll { $0 == windowID }
        resolvedSilhouetteOrder.append(windowID)
        while resolvedSilhouetteOrder.count > Self.maxCachedSilhouettes {
            let evicted = resolvedSilhouetteOrder.removeFirst()
            resolvedSilhouettes.removeValue(forKey: evicted)
        }
    }

    private func expectedQuartzFrame(for appKitFrame: CGRect) -> CGRect? {
        let primaryHeight = detector.cachedPrimaryScreenHeight
        guard primaryHeight > 0 else { return nil }
        return CoordinateConverter.appKitToQuartz(appKitFrame, primaryScreenHeight: primaryHeight)
    }

    private func ensureSilhouetteTask(
        for windowID: CGWindowID,
        expectedAppKitFrame: CGRect,
        scale: CGFloat
    ) -> Task<CapturedWindowSilhouette?, Never>? {
        if let existing = silhouetteTasks[windowID] {
            return existing
        }
        let provider = silhouetteProvider
        let windowBox = shareableWindows[windowID]
        guard provider != nil || windowBox != nil else { return nil }
        let expectedQuartz = expectedQuartzFrame(for: expectedAppKitFrame)

        let task = Task<CapturedWindowSilhouette?, Never>(priority: .userInitiated) {
            let result: CapturedWindowSilhouette?
            if let provider {
                result = await provider(windowID, scale)
            } else if let windowBox {
                result = await ScreenSnapshotEngine.captureWindowSilhouetteWithMetadata(
                    window: windowBox.value,
                    scale: scale,
                    expectedQuartzFrame: expectedQuartz
                )
            } else {
                result = nil
            }
            return result
        }
        silhouetteTasks[windowID] = task
        Task { @MainActor [weak self] in
            let silhouette = await task.value
            guard let self, !self.isClosed, self.silhouetteTasks[windowID] == task else { return }
            self.silhouetteTasks.removeValue(forKey: windowID)
            self.cacheResolvedSilhouette(silhouette, for: windowID)
        }
        return task
    }

    private func handleSelectionChanged(_ localRect: CGRect?, on view: SnipOverlayView) {
        let viewKey = ObjectIdentifier(view)
        previewUpdateTasks[viewKey]?.cancel()
        previewUpdateTasks[viewKey] = nil

        guard selectionMode == .snip,
              !isClosed,
              !isFinishing,
              let localRect
        else { return }

        let globalRect = localRect.offsetBy(
            dx: view.snapshot.screenFrame.minX,
            dy: view.snapshot.screenFrame.minY
        )
        guard let target = detector.matchingWindowCornerTarget(for: globalRect) else { return }
        let windowID = target.window.windowID
        guard hasSilhouetteSource(for: windowID) else { return }

        // Fast synchronous path when this window's silhouette is already cached in the session.
        if let cached = resolvedSilhouettes[windowID] {
            resolvedSilhouetteOrder.removeAll { $0 == windowID }
            resolvedSilhouetteOrder.append(windowID)
            if let silhouette = cached,
               Self.silhouetteMatchesTarget(silhouette, target: target) {
                let radii = WindowCornerMaskExtractor.extractCornerRadii(
                    windowImage: silhouette.image,
                    windowFrame: target.backingWindowFrame,
                    selectionRect: globalRect,
                    eligibleCorners: target.eligibleCorners,
                    displayScale: silhouette.pointPixelScale
                )
                view.setAdaptiveCornerRadii(radii, forLocalRect: localRect)
            }
            return
        }

        guard let task = ensureSilhouetteTask(
            for: windowID,
            expectedAppKitFrame: target.backingWindowFrame,
            scale: view.snapshot.backingScaleFactor
        ) else {
            return
        }
        previewUpdateTasks[viewKey] = Task { @MainActor [weak self, weak view] in
            let silhouette = await task.value
            guard let self, let view, !self.isClosed, !self.isFinishing, !Task.isCancelled else { return }
            guard let silhouette,
                  Self.silhouetteMatchesTarget(silhouette, target: target)
            else { return }
            let radii = await Task.detached(priority: .userInitiated) {
                WindowCornerMaskExtractor.extractCornerRadii(
                    windowImage: silhouette.image,
                    windowFrame: target.backingWindowFrame,
                    selectionRect: globalRect,
                    eligibleCorners: target.eligibleCorners,
                    displayScale: silhouette.pointPixelScale
                )
            }.value
            guard !self.isClosed, !self.isFinishing, !Task.isCancelled else { return }
            view.setAdaptiveCornerRadii(radii, forLocalRect: localRect)
        }
    }

    private nonisolated static func silhouetteMatchesTarget(
        _ silhouette: CapturedWindowSilhouette,
        target: WindowCornerTarget
    ) -> Bool {
        abs(silhouette.contentSize.width - target.backingWindowFrame.width) <= WindowCornerMaskExtractor.windowSizeMatchTolerance
            && abs(silhouette.contentSize.height - target.backingWindowFrame.height) <= WindowCornerMaskExtractor.windowSizeMatchTolerance
    }

    /// Awaits an unstructured silhouette fetch with a hard wall-clock timeout and cancellation support
    /// so a stalled ScreenCaptureKit call never delays commit and closing cancels immediately.
    internal nonisolated static func awaitSilhouette(
        _ task: Task<CapturedWindowSilhouette?, Never>,
        timeoutNanoseconds: UInt64
    ) async -> CapturedWindowSilhouette? {
        if Task.isCancelled { return nil }
        let state = OSAllocatedUnfairLock(initialState: SilhouetteWaitState())

        @Sendable func resolve(_ value: CapturedWindowSilhouette?) {
            let pending = state.withLock { s -> (CheckedContinuation<CapturedWindowSilhouette?, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
                guard !s.isResolved else { return (nil, nil, nil) }
                s.isResolved = true
                let cont = s.continuation
                let timer = s.timerTask
                let wait = s.waitTask
                s.continuation = nil
                s.timerTask = nil
                s.waitTask = nil
                return (cont, timer, wait)
            }
            pending.1?.cancel()
            pending.2?.cancel()
            pending.0?.resume(returning: value)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = state.withLock { s -> Bool in
                    guard !s.isResolved else { return true }
                    s.continuation = continuation
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume(returning: nil)
                    return
                }

                let timerTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    resolve(nil)
                }
                let waitTask = Task {
                    let value = await task.value
                    resolve(value)
                }
                let tasksToCancel = state.withLock { s -> (Task<Void, Never>?, Task<Void, Never>?) in
                    if s.isResolved {
                        return (timerTask, waitTask)
                    }
                    s.timerTask = timerTask
                    s.waitTask = waitTask
                    return (nil, nil)
                }
                tasksToCancel.0?.cancel()
                tasksToCancel.1?.cancel()
            }
        } onCancel: {
            resolve(nil)
        }
    }

    private func completeImageExport(
        rect: CGRect,
        from view: SnipOverlayView,
        cornerTarget: WindowCornerTarget?,
        silhouette: CapturedWindowSilhouette?,
        renderError: String,
        buildOutcome: @MainActor (SnipResult) -> SnipOutcome
    ) {
        // The window may have changed after the preview cached a valid silhouette.
        let currentSilhouette: CapturedWindowSilhouette?
        if let silhouette, let cornerTarget, silhouetteProvider == nil {
            if let expected = expectedQuartzFrame(for: cornerTarget.backingWindowFrame),
               let live = ScreenSnapshotEngine.liveQuartzWindowBounds(for: cornerTarget.window.windowID),
               ScreenSnapshotEngine.windowBoundsMatch(live, expected) {
                currentSilhouette = silhouette
            } else {
                currentSilhouette = nil
            }
        } else {
            currentSilhouette = silhouette
        }
        let result = Self.makeResult(
            localRect: rect,
            snapshot: view.snapshot,
            document: view.annotations,
            mosaicCache: view.mosaicCache,
            cornerTarget: cornerTarget,
            windowSilhouette: currentSilhouette
        )
        if result != nil {
            onSelectionCommitted?(view.snapshot.displayID, rect)
        }
        let outcome = result.map(buildOutcome) ?? .failed(renderError)
        close()
        onFinish(outcome)
    }

    private func finish(_ action: OverlayAction, from view: SnipOverlayView) {
        guard !isClosed, !isFinishing else { return }

        let renderError = CCXL10n.text("Could not render selected region", zh: "无法渲染选区图像")

        func finishImageExport(rect: CGRect, buildOutcome: @escaping @MainActor (SnipResult) -> SnipOutcome) {
            let globalRect = rect.offsetBy(
                dx: view.snapshot.screenFrame.minX,
                dy: view.snapshot.screenFrame.minY
            )
            let cornerTarget = detector.matchingWindowCornerTarget(for: globalRect)

            guard let cornerTarget, hasSilhouetteSource(for: cornerTarget.window.windowID) else {
                completeImageExport(
                    rect: rect,
                    from: view,
                    cornerTarget: cornerTarget,
                    silhouette: nil,
                    renderError: renderError,
                    buildOutcome: buildOutcome
                )
                return
            }

            let windowID = cornerTarget.window.windowID
            if let cached = resolvedSilhouettes[windowID] {
                completeImageExport(
                    rect: rect,
                    from: view,
                    cornerTarget: cornerTarget,
                    silhouette: cached,
                    renderError: renderError,
                    buildOutcome: buildOutcome
                )
                return
            }

            guard let task = ensureSilhouetteTask(
                for: windowID,
                expectedAppKitFrame: cornerTarget.backingWindowFrame,
                scale: view.snapshot.backingScaleFactor
            ) else {
                completeImageExport(
                    rect: rect,
                    from: view,
                    cornerTarget: cornerTarget,
                    silhouette: nil,
                    renderError: renderError,
                    buildOutcome: buildOutcome
                )
                return
            }

            // Hide overlay panels immediately while awaiting the in-flight silhouette (bounded by 120ms).
            isFinishing = true
            for panel in panels { panel.orderOut(nil) }
            finishTask = Task { @MainActor [weak self, weak view] in
                let silhouette = await Self.awaitSilhouette(
                    task,
                    timeoutNanoseconds: Self.silhouetteCommitTimeoutNanoseconds
                )
                guard let self, let view, !self.isClosed, !Task.isCancelled else { return }
                self.finishTask = nil
                self.completeImageExport(
                    rect: rect,
                    from: view,
                    cornerTarget: cornerTarget,
                    silhouette: silhouette,
                    renderError: renderError,
                    buildOutcome: buildOutcome
                )
            }
        }

        switch action {
        case let .pin(rect):
            finishImageExport(rect: rect, buildOutcome: SnipOutcome.pin)
            return
        case let .copy(rect):
            finishImageExport(rect: rect, buildOutcome: SnipOutcome.copy)
            return
        case let .save(rect):
            finishImageExport(rect: rect, buildOutcome: SnipOutcome.save)
            return
        case let .quickSave(rect):
            finishImageExport(rect: rect, buildOutcome: SnipOutcome.quickSave)
            return
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
                onFinish(.failed(renderError))
            }
            return
        case let .ocr(rect):
            let result = Self.makeResult(
                localRect: rect,
                snapshot: view.snapshot,
                document: view.annotations,
                mosaicCache: view.mosaicCache
            )
            if result != nil {
                onSelectionCommitted?(view.snapshot.displayID, rect)
            }
            let outcome = result.map(SnipOutcome.ocr) ?? .failed(renderError)
            close()
            onFinish(outcome)
            return
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
            close()
            onFinish(.record(RecordRegionRequest(
                displayID: view.snapshot.displayID,
                displayFrame: view.snapshot.screenFrame,
                localRect: effectiveLocal,
                screenRect: screenRect,
                scale: scale
            )))
            return
        case let .copyColor(sample, format):
            close()
            onFinish(.copiedColor(sample, format))
            return
        case .cancel:
            close()
            onFinish(.cancelled)
            return
        }
    }

    /// Crops the exact backing pixels for a view-local AppKit rect from a display snapshot.
    nonisolated static func makeResult(
        localRect: CGRect,
        snapshot: DisplaySnapshot,
        cornerTarget: WindowCornerTarget? = nil,
        windowSilhouette: CapturedWindowSilhouette? = nil,
        cornerMask: CGImage? = nil
    ) -> SnipResult? {
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
        let finalImage = applyAdaptiveCornerMaskIfNeeded(
            to: cropped,
            globalRect: screenRect,
            cornerTarget: cornerTarget,
            windowSilhouette: windowSilhouette,
            cornerMask: cornerMask
        )
        return SnipResult(image: finalImage, scale: scale, screenRect: screenRect)
    }

    /// Crops the exact backing pixels, bakes any committed annotations at full Retina resolution,
    /// and applies any resolved adaptive window-corner mask after baking so annotations crossing
    /// rounded corners are cleanly clipped too.
    static func makeResult(
        localRect: CGRect,
        snapshot: DisplaySnapshot,
        document: AnnotationDocument?,
        mosaicCache: MosaicImageCache?,
        cornerTarget: WindowCornerTarget? = nil,
        windowSilhouette: CapturedWindowSilhouette? = nil,
        cornerMask: CGImage? = nil
    ) -> SnipResult? {
        guard let document, !document.items.isEmpty else {
            return makeResult(
                localRect: localRect,
                snapshot: snapshot,
                cornerTarget: cornerTarget,
                windowSilhouette: windowSilhouette,
                cornerMask: cornerMask
            )
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
        let finalImage = applyAdaptiveCornerMaskIfNeeded(
            to: baked,
            globalRect: screenRect,
            cornerTarget: cornerTarget,
            windowSilhouette: windowSilhouette,
            cornerMask: cornerMask
        )
        return SnipResult(image: finalImage, scale: scale, screenRect: screenRect)
    }

    private nonisolated static func applyAdaptiveCornerMaskIfNeeded(
        to image: CGImage,
        globalRect: CGRect,
        cornerTarget: WindowCornerTarget?,
        windowSilhouette: CapturedWindowSilhouette?,
        cornerMask: CGImage?
    ) -> CGImage {
        if let cornerMask {
            return WindowCornerMaskExtractor.applyMask(cornerMask, to: image)
        }
        guard let cornerTarget,
              let windowSilhouette,
              silhouetteMatchesTarget(windowSilhouette, target: cornerTarget),
              let extracted = WindowCornerMaskExtractor.extractMask(
                  windowImage: windowSilhouette.image,
                  windowFrame: cornerTarget.backingWindowFrame,
                  selectionRect: globalRect,
                  eligibleCorners: cornerTarget.eligibleCorners,
                  outputPixelSize: (width: image.width, height: image.height),
                  displayScale: windowSilhouette.pointPixelScale
              )
        else {
            return image
        }
        return WindowCornerMaskExtractor.applyMask(extracted.maskImage, to: image)
    }
}
