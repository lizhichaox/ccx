import AppKit
import CCXCore
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
    private enum FinishKind {
        case pin, copy, save, quickSave, ocr
    }

    private let request: ScrollCaptureRequest
    private let onFinish: (SnipOutcome) -> Void
    private let engine: ScrollCaptureEngine
    private let autoScroll = AutoScrollDriver()

    private var borderPanel: ScrollCaptureFramePanel?
    private var hudPanel: ScrollCaptureHUDPanel?
    private var previewPanel: ScrollCapturePreviewPanel?

    nonisolated(unsafe) private var globalKeyMonitor: Any?
    nonisolated(unsafe) private var localKeyMonitor: Any?

    private var isFinishing = false
    private var isClosed = false
    private let initialPixelHeight: Int
    private var statusText = "Scroll down"

    init(request: ScrollCaptureRequest, onFinish: @escaping (SnipOutcome) -> Void) {
        self.request = request
        self.onFinish = onFinish
        self.initialPixelHeight = max(1, request.initialImage.height)
        self.engine = ScrollCaptureEngine(request: request, fallbackInitialImage: request.initialImage)
    }

    func start() {
        let visibleFrame = Self.visibleFrame(for: request.screenRect)
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
            status: statusText,
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

        Task { @MainActor [weak self] in
            guard let self, !self.isClosed else { return }
            do {
                try await self.engine.start(excludingWindowIDs: excludedWindowIDs)
            } catch {
                guard !self.isClosed else { return }
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
            tearDown(outcome: .failed(error.localizedDescription))
        }
    }

    private func wireCallbacks() {
        engine.onProgress = { [weak self] progress in
            guard let self, !self.isClosed, !self.isFinishing else { return }
            self.autoScroll.notifyHeightAdvanced(progress.pixelHeight)

            let accent: ScrollCaptureVisualAccent
            if progress.reachedLimit {
                self.autoScroll.stop()
                self.statusText = "Max height"
                accent = .warning
            } else if self.autoScroll.isRunning {
                self.statusText = "Auto-scrolling"
                accent = .autoScroll
            } else {
                accent = .active
            }

            self.borderPanel?.setAccent(accent)
            self.hudPanel?.updateMetrics(
                width: progress.pixelWidth,
                height: progress.pixelHeight,
                status: self.statusText,
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
                self.statusText = "Auto-scrolling"
            } else if self.statusText == "Auto-scrolling" {
                self.statusText = "Scroll down"
            }
            self.borderPanel?.setAccent(accent)
            self.hudPanel?.updateAutoScroll(isRunning: running, status: self.statusText, accent: accent)
        }

        autoScroll.onReachedBottom = { [weak self] in
            guard let self, !self.isClosed else { return }
            self.statusText = "Reached bottom"
            self.borderPanel?.setAccent(.warning)
            self.hudPanel?.updateAutoScroll(isRunning: false, status: self.statusText, accent: .warning)
        }

        autoScroll.onAccessibilityRequired = { [weak self] in
            guard let self, !self.isClosed else { return }
            self.statusText = "Needs Accessibility"
            self.borderPanel?.setAccent(.warning)
            self.hudPanel?.updateAutoScroll(isRunning: false, status: self.statusText, accent: .warning)
        }
    }

    private func toggleAutoScroll() {
        guard !isFinishing, !isClosed else { return }
        if autoScroll.isRunning {
            autoScroll.stop()
        } else {
            let primaryHeight = CoordinateConverter.primaryScreenHeight(screens: NSScreen.screens.map(\.frame))
            let currentHeight = hudPanel?.lastHeightPixels ?? initialPixelHeight
            autoScroll.start(
                captureScreenRect: request.screenRect,
                primaryScreenHeight: primaryHeight,
                currentPixelHeight: currentHeight
            )
        }
    }

    private func finish(kind: FinishKind) {
        guard !isFinishing, !isClosed else { return }
        isFinishing = true
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
        autoScroll.stop()
        removeMonitors()
        if cancelEngine {
            engine.cancel()
        }
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        previewPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
        previewPanel = nil
        onFinish(outcome)
    }

    private func installMonitors() {
        removeMonitors()

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    self?.cancel()
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, !self.isClosed, !self.isFinishing else { return false }
                if keyCode == 53 {
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
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private static func visibleFrame(for rect: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

// MARK: - Visual Styling & Auxiliary Panels

private enum ScrollCaptureVisualAccent {
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
        level = .statusBar
        isFloatingPanel = true
        ignoresMouseEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
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
private final class ScrollCaptureHUDPanel: NSPanel {
    var onToggleAutoScroll: (() -> Void)?
    var onOCR: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var lastHeightPixels = 0

    private let dotView = NSView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let autoButton = NSButton()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(captureRect: CGRect, visibleFrame: CGRect) {
        let size = CGSize(width: 404, height: 42)
        let gap: CGFloat = 8
        var origin = CGPoint(x: captureRect.midX - size.width / 2, y: captureRect.minY - gap - size.height)
        if origin.y < visibleFrame.minY + 6 {
            let aboveY = captureRect.maxY + gap
            if aboveY + size.height <= visibleFrame.maxY - 6 {
                origin.y = aboveY
            } else {
                origin.y = visibleFrame.minY + 14
            }
        }
        origin.x = min(max(origin.x, visibleFrame.minX + 8), max(visibleFrame.minX + 8, visibleFrame.maxX - size.width - 8))
        origin.y = min(max(origin.y, visibleFrame.minY + 6), max(visibleFrame.minY + 6, visibleFrame.maxY - size.height - 6))

        let frame = CGRect(origin: origin, size: size)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)

        let inner = NSView(frame: CGRect(origin: .zero, size: size))
        setUpControls(in: inner)
        let surface = Self.makeGlassSurface(contentView: inner, cornerRadius: 12)
        surface.frame = CGRect(origin: .zero, size: size)
        contentView = surface
        setFrame(frame, display: true)
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
        statusLabel.textColor = isRunning ? NSColor.systemCyan : NSColor.white.withAlphaComponent(0.72)

        let symbol = isRunning ? "pause.fill" : "play.fill"
        autoButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Auto Scroll")
        let title = isRunning ? "Pause" : "Auto"
        autoButton.attributedTitle = NSAttributedString(
            string: " \(title)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: isRunning ? NSColor.black : NSColor.white,
            ]
        )
        autoButton.contentTintColor = isRunning ? .black : .white
        autoButton.layer?.backgroundColor = (isRunning ? NSColor.systemCyan : NSColor.white.withAlphaComponent(0.14)).cgColor
        autoButton.toolTip = isRunning ? "Pause Auto-Scroll (Space)" : "Auto-Scroll Down (Space)"
    }

    private func setUpControls(in container: NSView) {
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        dotView.layer?.backgroundColor = NSColor.systemMint.cgColor
        dotView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),
        ])

        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        sizeLabel.textColor = .white
        sizeLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        statusLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [sizeLabel, statusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true

        autoButton.bezelStyle = .regularSquare
        autoButton.isBordered = false
        autoButton.imagePosition = .imageLeading
        autoButton.wantsLayer = true
        autoButton.layer?.cornerRadius = 7
        autoButton.target = self
        autoButton.action = #selector(autoPressed)
        autoButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            autoButton.widthAnchor.constraint(equalToConstant: 66),
            autoButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        let ocrBtn = makeIconButton(symbol: "text.viewfinder", tint: .systemCyan, tip: "Copy Text (OCR) (T)", action: #selector(ocrPressed))
        let pinBtn = makeIconButton(symbol: "pin", tint: .systemGreen, tip: "Pin (Return)", action: #selector(pinPressed))
        let copyBtn = makeIconButton(symbol: "doc.on.doc", tint: .white, tip: "Copy (⌘C)", action: #selector(copyPressed))
        let saveBtn = makeIconButton(symbol: "square.and.arrow.down", tint: .white, tip: "Save PNG (⌘S)", action: #selector(savePressed))
        let cancelBtn = makeIconButton(symbol: "xmark", tint: .systemRed, tip: "Cancel (Esc)", action: #selector(cancelPressed))

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 20),
        ])

        let stack = NSStackView(views: [
            dotView,
            textStack,
            autoButton,
            divider,
            ocrBtn,
            pinBtn,
            copyBtn,
            saveBtn,
            cancelBtn,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func makeIconButton(symbol: String, tint: NSColor, tip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.contentTintColor = tint
        button.toolTip = tip
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
        return button
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
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
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
        level = .statusBar
        isFloatingPanel = true
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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
