import AppKit
import CCXCore
import OSLog
import QuartzCore

/// Region and initial snapshot handed from `SnipOverlayController` to begin a scroll capture.
public struct ScrollCaptureRequest: Sendable {
    public let displayID: CGDirectDisplayID
    public let displayFrame: CGRect
    public let localRect: CGRect
    public let screenRect: CGRect
    public let scale: CGFloat
    public let initialImage: CGImage

    public init(
        displayID: CGDirectDisplayID,
        displayFrame: CGRect,
        localRect: CGRect,
        screenRect: CGRect,
        scale: CGFloat,
        initialImage: CGImage
    ) {
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.localRect = localRect
        self.screenRect = screenRect
        self.scale = scale
        self.initialImage = initialImage
    }
}

/// Manages the live scrolling screenshot session: click-through border frame, Liquid Glass HUD,
/// optional side preview strip, `SCStream` stitching engine, and optional Auto-Scroll.
@MainActor
final class ScrollCaptureController {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "ScrollCaptureController")

    private enum FinishKind {
        case pin, copy, save, quickSave, ocr
    }

    private enum ScrollStatus: Equatable {
        case scrollDown
        case starting
        case autoScrolling
        case reachedBottom
        case maxHeight
        case needsAccessibility

        var displayText: String {
            switch self {
            case .scrollDown: CCXL10n.text("Scroll down", zh: "向下滚动")
            case .starting: CCXL10n.text("Starting...", zh: "正在启动…")
            case .autoScrolling: CCXL10n.text("Auto-scrolling", zh: "滚动中…")
            case .reachedBottom: CCXL10n.text("Reached bottom", zh: "已到底部")
            case .maxHeight: CCXL10n.text("Max height", zh: "已达最大高度")
            case .needsAccessibility: CCXL10n.text("Needs Accessibility", zh: "需要辅助功能")
            }
        }
    }

    private let request: ScrollCaptureRequest
    private let onFinish: (SnipOutcome) -> Void
    private let engine: ScrollCaptureEngine
    private let autoScroll = AutoScrollDriver()

    private var borderPanel: ScrollCaptureFramePanel?
    private var hudPanel: ScrollCaptureHUDPanel?
    private var previewPanel: ScrollCapturePreviewPanel?

    nonisolated(unsafe) private var localKeyMonitor: Any?
    nonisolated(unsafe) private var screenParametersObserver: NSObjectProtocol?

    private var isFinishing = false
    private var isClosed = false
    private var isStreamReady = false
    private var pendingAutoScrollStart = false
    private var reachedHeightLimit = false
    private var initialPixelHeight: Int
    private var status: ScrollStatus = .scrollDown

    init(request: ScrollCaptureRequest, onFinish: @escaping (SnipOutcome) -> Void) {
        self.request = request
        self.onFinish = onFinish
        self.initialPixelHeight = max(1, request.initialImage.height)
        self.engine = ScrollCaptureEngine(request: request, fallbackInitialImage: request.initialImage)
    }

    deinit {
        if let monitor = localKeyMonitor {
            let box = UncheckedSendableBox(monitor)
            if Thread.isMainThread {
                NSEvent.removeMonitor(box.value)
            } else {
                DispatchQueue.main.async {
                    NSEvent.removeMonitor(box.value)
                }
            }
        }
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        let visibleFrame = Self.visibleFrame(for: request.displayID, captureRect: request.screenRect)
        let border = ScrollCaptureFramePanel(captureRect: request.screenRect)
        let hud = ScrollCaptureHUDPanel(captureRect: request.screenRect, visibleFrame: visibleFrame)
        let preview = ScrollCapturePreviewPanel.makeIfRoom(
            captureRect: request.screenRect,
            visibleFrame: visibleFrame,
            scale: request.scale
        )

        hud.onToggleAutoScroll = { [weak self] in self?.toggleAutoScroll() }
        hud.onOCR = { [weak self] in self?.finish(kind: .ocr) }
        hud.onPin = { [weak self] in self?.finish(kind: .pin) }
        hud.onCopy = { [weak self] in self?.finish(kind: .copy) }
        hud.onSave = { [weak self] in self?.finish(kind: .save) }
        hud.onCancel = { [weak self] in self?.cancel() }

        self.borderPanel = border
        self.hudPanel = hud
        self.previewPanel = preview

        border.orderFrontRegardless()
        preview?.orderFrontRegardless()
        hud.makeKeyAndOrderFront(nil)

        hud.updateMetrics(
            width: request.initialImage.width,
            height: request.initialImage.height,
            status: status.displayText,
            accent: .active,
            isAutoScrolling: false
        )
        preview?.update(image: request.initialImage, heightRatio: 1.0)

        var excludedWindowIDs: Set<CGWindowID> = []
        for windowNumber in [border.windowNumber, hud.windowNumber, preview?.windowNumber ?? 0] where windowNumber > 0 {
            excludedWindowIDs.insert(CGWindowID(windowNumber))
        }

        wireCallbacks()
        installMonitors()
        installScreenParametersObserver()

        Task { @MainActor [weak self] in
            guard let self, !self.isClosed else { return }
            do {
                try await self.engine.start(excludingWindowIDs: excludedWindowIDs)
                guard !self.isClosed, !self.isFinishing else { return }
                self.isStreamReady = true
                if self.pendingAutoScrollStart {
                    self.pendingAutoScrollStart = false
                    self.startAutoScroll()
                }
            } catch {
                guard !self.isClosed else { return }
                Self.logger.error("Failed to start scroll capture: \(error.localizedDescription)")
                self.cancelWithError(error)
            }
        }
    }

    func cancel() {
        guard !isClosed else { return }
        tearDown(outcome: .cancelled)
    }

    private func cancelWithError(_ error: Error) {
        guard !isClosed else { return }
        if ScreenSnapshotEngine.isPermissionDeniedError(error) {
            PermissionManager.setScreenRecordingVerified(false)
            tearDown(outcome: .permissionDenied)
        } else {
            tearDown(outcome: .failed(ScreenSnapshotEngine.userFacingErrorMessage(for: error)))
        }
    }

    private func wireCallbacks() {
        engine.onProgress = { [weak self] progress in
            guard let self, !self.isClosed, !self.isFinishing else { return }
            if progress.frameCount == 1, progress.pixelHeight > 0 {
                self.initialPixelHeight = progress.pixelHeight
            }
            self.autoScroll.notifyHeightAdvanced(progress.pixelHeight)

            let accent: ScrollCaptureVisualAccent
            if progress.reachedLimit {
                self.reachedHeightLimit = true
                self.pendingAutoScrollStart = false
                self.autoScroll.stop()
                self.status = .maxHeight
                accent = .warning
            } else if self.autoScroll.isRunning {
                self.status = .autoScrolling
                accent = .autoScroll
            } else {
                // Recover cleanly from prior "Reached bottom" / "Needs Accessibility" warning once manual scroll advances.
                if progress.frameCount > 1 {
                    self.status = .scrollDown
                }
                accent = .active
            }

            self.borderPanel?.setAccent(accent)
            self.hudPanel?.updateMetrics(
                width: progress.pixelWidth,
                height: progress.pixelHeight,
                status: self.status.displayText,
                accent: accent,
                isAutoScrolling: self.autoScroll.isRunning
            )
            if let previewImage = progress.previewImage {
                let ratio = CGFloat(progress.pixelHeight) / CGFloat(self.initialPixelHeight)
                self.previewPanel?.update(image: previewImage, heightRatio: ratio)
            }
        }

        engine.onError = { [weak self] error in
            self?.cancelWithError(error)
        }

        autoScroll.onStateChanged = { [weak self] running in
            guard let self, !self.isClosed else { return }
            let accent: ScrollCaptureVisualAccent = running ? .autoScroll : .active
            if running {
                self.status = .autoScrolling
            } else if self.status == .autoScrolling || self.status == .starting {
                self.status = .scrollDown
            }
            self.borderPanel?.setAccent(accent)
            self.hudPanel?.updateAutoScroll(isRunning: running, status: self.status.displayText, accent: accent)
        }

        autoScroll.onReachedBottom = { [weak self] in
            guard let self, !self.isClosed else { return }
            self.status = .reachedBottom
            self.borderPanel?.setAccent(.warning)
            self.hudPanel?.updateAutoScroll(isRunning: false, status: self.status.displayText, accent: .warning)
        }

        autoScroll.onAccessibilityRequired = { [weak self] in
            guard let self, !self.isClosed else { return }
            self.status = .needsAccessibility
            self.borderPanel?.setAccent(.warning)
            self.hudPanel?.updateAutoScroll(isRunning: false, status: self.status.displayText, accent: .warning)
        }
    }

    private func toggleAutoScroll() {
        guard !isFinishing, !isClosed, !reachedHeightLimit else { return }
        if autoScroll.isRunning {
            pendingAutoScrollStart = false
            autoScroll.stop()
            return
        }
        guard isStreamReady else {
            pendingAutoScrollStart.toggle()
            if pendingAutoScrollStart {
                status = .starting
                borderPanel?.setAccent(.autoScroll)
                hudPanel?.updateAutoScroll(isRunning: true, status: status.displayText, accent: .autoScroll)
            } else {
                status = .scrollDown
                borderPanel?.setAccent(.active)
                hudPanel?.updateAutoScroll(isRunning: false, status: status.displayText, accent: .active)
            }
            return
        }
        startAutoScroll()
    }

    private func startAutoScroll() {
        let primaryHeight = CoordinateConverter.primaryScreenHeight(screens: NSScreen.screens.map(\.frame))
        let currentHeight = max(hudPanel?.lastHeightPixels ?? initialPixelHeight, initialPixelHeight)
        autoScroll.start(
            captureScreenRect: request.screenRect,
            primaryScreenHeight: primaryHeight,
            currentPixelHeight: currentHeight,
            avoiding: hudPanel?.frame
        )
    }

    private func finish(kind: FinishKind) {
        guard !isFinishing, !isClosed else { return }
        isFinishing = true
        pendingAutoScrollStart = false
        autoScroll.stop()
        removeMonitors()
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        previewPanel?.orderOut(nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await self.engine.finishAndBuildImage() ?? self.request.initialImage
            guard !self.isClosed else { return }
            let result = SnipResult(image: image, scale: self.request.scale, screenRect: self.request.screenRect)
            let outcome: SnipOutcome = switch kind {
            case .pin: .pin(result)
            case .copy: .copy(result)
            case .save: .save(result)
            case .quickSave: .quickSave(result)
            case .ocr: .ocr(result)
            }
            self.tearDown(outcome: outcome, cancelEngine: false)
        }
    }

    private func tearDown(outcome: SnipOutcome, cancelEngine: Bool = true) {
        guard !isClosed else { return }
        isClosed = true
        pendingAutoScrollStart = false
        autoScroll.stop()
        removeMonitors()
        removeScreenParametersObserver()
        if cancelEngine {
            engine.cancel()
        }
        hudPanel?.delegate = nil
        hudPanel?.onToggleAutoScroll = nil
        hudPanel?.onOCR = nil
        hudPanel?.onPin = nil
        hudPanel?.onCopy = nil
        hudPanel?.onSave = nil
        hudPanel?.onCancel = nil
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        previewPanel?.orderOut(nil)
        borderPanel?.close()
        hudPanel?.close()
        previewPanel?.close()
        borderPanel = nil
        hudPanel = nil
        previewPanel = nil
        onFinish(outcome)
    }

    private func ownedWindowNumbers() -> Set<Int> {
        var numbers: Set<Int> = []
        for panel in [borderPanel as NSPanel?, hudPanel, previewPanel] {
            if let num = panel?.windowNumber, num > 0 {
                numbers.insert(num)
            }
        }
        return numbers
    }

    internal nonisolated static func shouldHandleLocalKeyEvent(
        windowNumber: Int,
        ownedWindowNumbers: Set<Int>,
        isFieldEditorFirstResponder: Bool
    ) -> Bool {
        guard !isFieldEditorFirstResponder else { return false }
        return ownedWindowNumbers.contains(windowNumber)
    }

    private func installMonitors() {
        removeMonitors()

        // Shortcuts are strictly scoped to scroll-capture panels so keys in other foreground apps
        // or other CCX windows (Settings, Onboarding, Pins, inline text editors) are never hijacked.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let windowNumber = event.windowNumber
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, !self.isClosed, !self.isFinishing else { return false }
                let isFieldEditor = event.window?.firstResponder is NSTextView
                guard Self.shouldHandleLocalKeyEvent(
                    windowNumber: windowNumber,
                    ownedWindowNumbers: self.ownedWindowNumbers(),
                    isFieldEditorFirstResponder: isFieldEditor
                ) else {
                    return false
                }
                if keyCode == 53 && mods.isEmpty {
                    self.cancel()
                    return true
                }
                if keyCode == 49 && mods.isEmpty {
                    self.toggleAutoScroll()
                    return true
                }
                if (keyCode == 36 || keyCode == 76) && mods.isEmpty {
                    self.finish(kind: .pin)
                    return true
                }
                if mods.isEmpty && chars == "t" {
                    self.finish(kind: .ocr)
                    return true
                }
                if mods == [.command, .shift] && chars == "s" {
                    self.finish(kind: .quickSave)
                    return true
                }
                if mods == .command {
                    switch chars {
                    case "c":
                        self.finish(kind: .copy)
                        return true
                    case "s":
                        self.finish(kind: .save)
                        return true
                    case "w":
                        self.cancel()
                        return true
                    default:
                        break
                    }
                }
                return false
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func installScreenParametersObserver() {
        removeScreenParametersObserver()
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

    private func removeScreenParametersObserver() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    private func handleScreenParametersChanged() {
        guard !isClosed, !isFinishing else { return }
        let matchingScreen = NSScreen.screens.first { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(num.uint32Value) == request.displayID
        }
        guard let matchingScreen,
              abs(matchingScreen.frame.minX - request.displayFrame.minX) <= 1,
              abs(matchingScreen.frame.minY - request.displayFrame.minY) <= 1,
              abs(matchingScreen.frame.width - request.displayFrame.width) <= 1,
              abs(matchingScreen.frame.height - request.displayFrame.height) <= 1
        else {
            tearDown(outcome: .failed(CCXL10n.text(
                "Display configuration changed during scroll capture",
                zh: "滚动截屏期间显示器配置发生变化"
            )))
            return
        }
    }

    internal static func visibleFrame(
        for displayID: CGDirectDisplayID,
        captureRect: CGRect,
        screens: [(displayID: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect)]
    ) -> CGRect {
        if let exact = screens.first(where: { $0.displayID == displayID }) {
            return exact.visibleFrame
        }
        var bestScreen: (displayID: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect)?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(captureRect)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        if let bestScreen {
            return bestScreen.visibleFrame
        }
        return screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func visibleFrame(for displayID: CGDirectDisplayID, captureRect: CGRect) -> CGRect {
        let descriptors: [(displayID: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect)] = NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(num.uint32Value), screen.frame, screen.visibleFrame)
        }
        if descriptors.isEmpty {
            return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        return visibleFrame(for: displayID, captureRect: captureRect, screens: descriptors)
    }
}

// MARK: - Visual Styling & Auxiliary Panels

enum ScrollCaptureVisualAccent {
    case active
    case autoScroll
    case warning

    var nsColor: NSColor {
        switch self {
        case .active: .systemMint
        case .autoScroll: .systemCyan
        case .warning: .systemOrange
        }
    }
}

private final class ScrollCaptureFramePanel: NSPanel {
    private let frameView = ScrollBorderView()

    init(captureRect: CGRect) {
        let outsetRect = captureRect.insetBy(dx: -4, dy: -4)
        super.init(
            contentRect: outsetRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        ignoresMouseEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = frameView
        setFrame(outsetRect, display: true)
    }

    func setAccent(_ accent: ScrollCaptureVisualAccent) {
        frameView.accentColor = accent.nsColor
    }
}

private final class ScrollBorderView: NSView {
    var accentColor: NSColor = .systemMint {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let strokeRect = bounds.insetBy(dx: 2, dy: 2)
        let outerPath = NSBezierPath(roundedRect: strokeRect, xRadius: 5, yRadius: 5)
        outerPath.lineWidth = 2.5
        accentColor.setStroke()
        outerPath.stroke()
    }
}

@MainActor
internal final class ScrollCaptureHUDPanel: NSPanel, NSWindowDelegate {
    private static let panelHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 14
    private static let controlHeight: CGFloat = 30

    var onToggleAutoScroll: (() -> Void)?
    var onOCR: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var lastHeightPixels = 0

    var hudContentBounds: CGRect {
        innerContainer.bounds
    }

    var hudControlFrames: [CGRect] {
        controlViewsForTesting.map { view in
            view.convert(view.bounds, to: innerContainer)
        }
    }

    private let captureRect: CGRect
    private let visibleFrame: CGRect
    private var hasCustomPosition = false
    private var isProgrammaticFrameUpdate = false

    private let innerContainer = NSView()
    private let rootStack = NSStackView()
    private let dotView = NSView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let autoButton = ScrollAutoPillButton()
    private let divider = NSView()
    private var controlViewsForTesting: [NSView] = []

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(captureRect: CGRect, visibleFrame: CGRect) {
        self.captureRect = captureRect
        self.visibleFrame = visibleFrame

        let initialSize = CGSize(width: 360, height: Self.panelHeight)
        let initialFrame = CGRect(origin: visibleFrame.origin, size: initialSize)
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        delegate = self

        setUpControls()
        let surface = Self.makeGlassSurface(contentView: innerContainer, cornerRadius: Self.cornerRadius)
        contentView = surface

        let initialWidth = captureRect.width.isFinite ? max(1, Int(captureRect.width.rounded())) : 1
        let initialHeight = captureRect.height.isFinite ? max(1, Int(captureRect.height.rounded())) : 1
        sizeLabel.stringValue = "\(initialWidth) × \(initialHeight)"
        updateAutoScroll(isRunning: false, status: CCXL10n.text("Scroll down", zh: "向下滚动"), accent: .active)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticFrameUpdate else { return }
        hasCustomPosition = true
    }

    func updateMetrics(
        width: Int,
        height: Int,
        status: String,
        accent: ScrollCaptureVisualAccent,
        isAutoScrolling: Bool
    ) {
        lastHeightPixels = height
        sizeLabel.stringValue = "\(width) × \(height)"
        updateAutoScroll(isRunning: isAutoScrolling, status: status, accent: accent)
    }

    func updateAutoScroll(isRunning: Bool, status: String, accent: ScrollCaptureVisualAccent) {
        dotView.layer?.backgroundColor = accent.nsColor.cgColor
        statusLabel.stringValue = status
        let needsAXStatus = CCXL10n.text("Needs Accessibility", zh: "需要辅助功能")
        statusLabel.toolTip = (status == needsAXStatus || status == "Needs Accessibility")
            ? CCXL10n.text(
                "Enable Accessibility for CCX in System Settings to use Auto-Scroll, or scroll manually.",
                zh: "请在系统设置中为 CCX 开启辅助功能以使用自动滚动，或手动滚动。"
            )
            : nil
        switch accent {
        case .active:
            statusLabel.textColor = NSColor.white.withAlphaComponent(0.74)
        case .autoScroll:
            statusLabel.textColor = .systemCyan
        case .warning:
            statusLabel.textColor = .systemOrange
        }
        autoButton.setRunning(isRunning)
        resizeToFit()
    }

    private func resizeToFit() {
        innerContainer.layoutSubtreeIfNeeded()
        let fitting = rootStack.fittingSize
        let maxAllowedWidth = max(260, visibleFrame.width - 16)
        let targetWidth = min(maxAllowedWidth, ceil(max(fitting.width, 320)))
        let targetSize = CGSize(width: targetWidth, height: Self.panelHeight)
        let origin = desiredOrigin(for: targetSize)
        let targetFrame = CGRect(origin: origin, size: targetSize)

        guard targetFrame != frame else { return }
        isProgrammaticFrameUpdate = true
        setFrame(targetFrame, display: true)
        invalidateShadow()
        isProgrammaticFrameUpdate = false
        contentView?.frame = CGRect(origin: .zero, size: targetSize)
        innerContainer.frame = CGRect(origin: .zero, size: targetSize)
        innerContainer.layoutSubtreeIfNeeded()
    }

    private func desiredOrigin(for size: CGSize) -> CGPoint {
        let minX = visibleFrame.minX + 8
        let maxX = max(minX, visibleFrame.maxX - size.width - 8)
        let minY = visibleFrame.minY + 6
        let maxY = max(minY, visibleFrame.maxY - size.height - 6)

        if hasCustomPosition {
            let centeredX = frame.midX - size.width * 0.5
            return CGPoint(
                x: min(max(centeredX, minX), maxX),
                y: min(max(frame.minY, minY), maxY)
            )
        }

        let gap: CGFloat = 10
        var y = captureRect.minY - gap - size.height
        if y < minY {
            let aboveY = captureRect.maxY + gap
            y = (aboveY + size.height <= visibleFrame.maxY - 6) ? aboveY : (visibleFrame.minY + 14)
        }
        let x = captureRect.midX - size.width * 0.5
        return CGPoint(
            x: min(max(x, minX), maxX),
            y: min(max(y, minY), maxY)
        )
    }

    private func setUpControls() {
        innerContainer.autoresizingMask = [.width, .height]

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        dotView.layer?.backgroundColor = NSColor.systemMint.cgColor
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.setContentHuggingPriority(.required, for: .horizontal)
        dotView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),
        ])

        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        sizeLabel.textColor = .white
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.74)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(sizeLabel)
        textStack.addArrangedSubview(statusLabel)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(.required, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true

        autoButton.target = self
        autoButton.action = #selector(autoPressed)
        autoButton.translatesAutoresizingMaskIntoConstraints = false
        autoButton.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.setContentHuggingPriority(.required, for: .horizontal)
        divider.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),
        ])

        let ocrBtn = ScrollHUDIconButton(
            symbol: "text.viewfinder",
            tint: .systemCyan,
            tip: CCXL10n.text("Copy Text (OCR) (T)", zh: "识别文字 (OCR) (T)"),
            target: self,
            action: #selector(ocrPressed)
        )
        let pinBtn = ScrollHUDIconButton(
            symbol: "pin",
            tint: .systemGreen,
            tip: CCXL10n.text("Pin (Return)", zh: "贴图 (Return)"),
            target: self,
            action: #selector(pinPressed)
        )
        let copyBtn = ScrollHUDIconButton(
            symbol: "doc.on.doc",
            tint: .white,
            tip: CCXL10n.text("Copy (⌘C)", zh: "拷贝 (⌘C)"),
            target: self,
            action: #selector(copyPressed)
        )
        let saveBtn = ScrollHUDIconButton(
            symbol: "square.and.arrow.down",
            tint: .white,
            tip: CCXL10n.text("Save PNG (⌘S)", zh: "保存 PNG (⌘S)"),
            target: self,
            action: #selector(savePressed)
        )
        let cancelBtn = ScrollHUDIconButton(
            symbol: "xmark",
            tint: .systemRed,
            hoverTint: NSColor.systemRed.withAlphaComponent(0.22),
            tip: CCXL10n.text("Cancel (Esc)", zh: "取消 (Esc)"),
            target: self,
            action: #selector(cancelPressed)
        )

        let controls: [NSView] = [
            dotView,
            textStack,
            autoButton,
            divider,
            ocrBtn,
            pinBtn,
            saveBtn,
            copyBtn,
            cancelBtn,
        ]
        controlViewsForTesting = controls

        for view in controls {
            rootStack.addArrangedSubview(view)
        }
        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 4
        rootStack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)
        rootStack.setCustomSpacing(8, after: dotView)
        rootStack.setCustomSpacing(10, after: textStack)
        rootStack.setCustomSpacing(8, after: autoButton)
        rootStack.setCustomSpacing(8, after: divider)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        innerContainer.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: innerContainer.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: innerContainer.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: innerContainer.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: innerContainer.bottomAnchor),
        ])
    }

    @objc private func autoPressed() { onToggleAutoScroll?() }
    @objc private func ocrPressed() { onOCR?() }
    @objc private func pinPressed() { onPin?() }
    @objc private func copyPressed() { onCopy?() }
    @objc private func savePressed() { onSave?() }
    @objc private func cancelPressed() { onCancel?() }

    private static func makeGlassSurface(contentView: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.contentView = contentView
            // Clip the backing layer to a continuous rounded rect so Liquid Glass backdrop/SDF
            // layers cannot leak alpha into square corners and cause rectangular WindowServer
            // shadow artifacts on this borderless panel.
            glass.wantsLayer = true
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
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
}

@MainActor
private final class ScrollAutoPillButton: NSButton {
    private static let horizontalPadding: CGFloat = 11
    private static let iconTitleSpacing: CGFloat = 6
    private static let pillHeight: CGFloat = 30

    private var isHovered = false
    private var isRunningState = false
    private var hasConfiguredState = false

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageLeading
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = Self.pillHeight * 0.5
        layer?.masksToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setRunning(false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let iconWidth = image?.size.width ?? 12
        let titleWidth = ceil(attributedTitle.size().width)
        let explicitWidth = Self.horizontalPadding * 2 + iconWidth + Self.iconTitleSpacing + titleWidth
        let width = max(68, max(ceil(super.intrinsicContentSize.width + 18), explicitWidth))
        return NSSize(width: width, height: Self.pillHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance()
    }

    func setRunning(_ running: Bool) {
        guard !hasConfiguredState || isRunningState != running else { return }
        hasConfiguredState = true
        isRunningState = running
        let symbol = running ? "pause.fill" : "arrow.down.circle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let rawImage = NSImage(systemSymbolName: symbol, accessibilityDescription: CCXL10n.text("Auto Scroll", zh: "自动滚动"))
        image = rawImage?.withSymbolConfiguration(config) ?? rawImage
        let title = running ? CCXL10n.text("Pause", zh: "暂停") : CCXL10n.text("Auto", zh: "自动滚动")
        attributedTitle = NSAttributedString(
            string: " \(title)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: running ? NSColor.black : NSColor.white,
            ]
        )
        toolTip = running
            ? CCXL10n.text("Pause Auto-Scroll (Space)", zh: "暂停自动滚动 (Space)")
            : CCXL10n.text("Auto-Scroll Down (Space)", zh: "向下自动滚动 (Space)")
        setAccessibilityLabel(running
            ? CCXL10n.text("Pause Auto-Scroll", zh: "暂停自动滚动")
            : CCXL10n.text("Auto-Scroll Down", zh: "向下自动滚动"))
        applyAppearance()
        invalidateIntrinsicContentSize()
    }

    private func applyAppearance() {
        if isRunningState {
            contentTintColor = .black
            let alpha: CGFloat = isHovered ? 0.88 : 1.0
            layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(alpha).cgColor
        } else {
            contentTintColor = .white
            let alpha: CGFloat = isHovered ? 0.24 : 0.14
            layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        }
    }
}

@MainActor
private final class ScrollHUDIconButton: NSButton {
    private static let buttonSize: CGFloat = 30
    private let hoverBackground: NSColor
    private var isHovered = false

    override var mouseDownCanMoveWindow: Bool { false }

    init(
        symbol: String,
        tint: NSColor,
        hoverTint: NSColor = NSColor.white.withAlphaComponent(0.14),
        tip: String,
        target: AnyObject,
        action: Selector
    ) {
        self.hoverBackground = hoverTint
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let rawImage = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image = rawImage?.withSymbolConfiguration(config) ?? rawImage
        imageScaling = .scaleNone
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        contentTintColor = tint
        toolTip = tip
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.buttonSize),
            heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = hoverBackground.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
private final class ScrollCapturePreviewPanel: NSPanel {
    private static let panelWidth: CGFloat = 132
    private let maxPanelHeight: CGFloat
    private let imageView = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "1.0×")

    static func makeIfRoom(
        captureRect: CGRect,
        visibleFrame: CGRect,
        scale: CGFloat
    ) -> ScrollCapturePreviewPanel? {
        let gap: CGFloat = 12
        let neededWidth = panelWidth + gap
        let rightSpace = visibleFrame.maxX - captureRect.maxX
        let leftSpace = captureRect.minX - visibleFrame.minX

        let x: CGFloat
        if rightSpace >= neededWidth {
            x = captureRect.maxX + gap
        } else if leftSpace >= neededWidth {
            x = captureRect.minX - gap - panelWidth
        } else {
            return nil
        }

        let maxPanelHeight = min(max(captureRect.height, 200), min(420, visibleFrame.height - 24))
        let initialHeight = min(maxPanelHeight, max(120, captureRect.height))
        let y = min(max(captureRect.maxY - initialHeight, visibleFrame.minY + 12), visibleFrame.maxY - initialHeight - 12)
        return ScrollCapturePreviewPanel(
            frame: CGRect(x: x, y: y, width: panelWidth, height: initialHeight),
            maxPanelHeight: maxPanelHeight,
            anchorMaxY: min(captureRect.maxY, visibleFrame.maxY - 12),
            minVisibleY: visibleFrame.minY + 12
        )
    }

    private let anchorMaxY: CGFloat
    private let minVisibleY: CGFloat

    private init(
        frame: CGRect,
        maxPanelHeight: CGFloat,
        anchorMaxY: CGFloat,
        minVisibleY: CGFloat
    ) {
        self.maxPanelHeight = maxPanelHeight
        self.anchorMaxY = anchorMaxY
        self.minVisibleY = minVisibleY
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        container.layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignBottom
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.drawsBackground = true
        badgeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 5
        badgeLabel.layer?.masksToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),

            badgeLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            badgeLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])

        contentView = container
        setFrame(frame, display: true)
    }

    func update(image: CGImage, heightRatio: CGFloat) {
        let imgSize = NSSize(width: image.width, height: image.height)
        imageView.image = NSImage(cgImage: image, size: imgSize)
        badgeLabel.stringValue = String(format: " %.1f× ", max(1.0, heightRatio))

        let aspect = CGFloat(image.height) / max(1, CGFloat(image.width))
        let desiredHeight = min(maxPanelHeight, max(120, (Self.panelWidth - 8) * aspect + 8))
        let current = frame
        if abs(current.height - desiredHeight) >= 2 {
            let newY = max(minVisibleY, anchorMaxY - desiredHeight)
            setFrame(CGRect(x: current.minX, y: newY, width: Self.panelWidth, height: desiredHeight), display: true)
        }
    }
}
