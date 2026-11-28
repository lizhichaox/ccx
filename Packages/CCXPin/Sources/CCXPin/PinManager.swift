import AppKit
import CCXAnnotate
import CCXCore

/// Outcome when triggering the smart Pin action (newest unpinned item first, no duplicates).
public enum PinNextOutcome: Equatable, Sendable {
    case pinned
    case allAlreadyPinned
    case nothingAvailable
}

/// Zero-decode status summary for the menu bar Pin quick-action tile.
public enum PinTileStatus: Equatable, Sendable {
    case ready(count: Int, primaryLabel: String)
    case allPinned
    case empty
}

/// Owns every floating pin: creation, visibility, click-through, copy/save routing.
@MainActor
public final class PinManager {
    public static let maxActivePins = 64

    private struct ClosedPinSnapshot {
        let content: PinContent
        let frame: CGRect
        let state: PinState
        let contentIdentity: PinContentIdentity
    }

    public static let maxClosedPinHistory = 5

    public private(set) var panels: [PinPanel] = []
    public private(set) var arePinsHidden = false
    public private(set) var lastAnnotationStyle = AnnotationStyle()
    private var closedPins: [ClosedPinSnapshot] = []

    public var pinCount: Int { panels.count }
    public var closedPinCount: Int { closedPins.count }
    public var canReopenClosedPin: Bool { !closedPins.isEmpty }
    public var clickThroughPinCount: Int {
        panels.reduce(0) { $0 + ($1.state.isClickThrough ? 1 : 0) }
    }
    public var hasClickThroughPins: Bool { clickThroughPinCount > 0 }

    /// Called whenever pins are added, removed, hidden/shown, or change state.
    public var onPinsChanged: (() -> Void)?
    /// Called whenever the recently-closed pin ring buffer changes.
    public var onClosedPinHistoryChanged: (() -> Void)?
    /// Called when the user asks to save a pin (Cmd+S or "Save PNG"); the host shows the
    /// save panel and typically calls `ClipboardStore.savePNG(_:to:)`.
    public var onRequestSavePNG: ((CGImage) -> Void)?
    /// Called when the user asks to instant-save a pin without a dialog (Shift+Cmd+S).
    public var onRequestQuickSavePNG: ((CGImage) -> Void)?
    /// Called after copying pin content to the clipboard with a short confirmation label.
    public var onCopied: ((String) -> Void)?
    /// Called when the user triggers OCR ("Copy Text (OCR)") on an image pin.
    public var onRequestRecognizeText: ((CGImage) -> Void)?

    private let clipboardStore: ClipboardStore
    private var isBatchUpdatingState = false
    private let screenObserver: ScreenParametersObserver

    public init(clipboardStore: ClipboardStore) {
        self.clipboardStore = clipboardStore
        let observer = ScreenParametersObserver()
        self.screenObserver = observer
        observer.onScreensChanged = { [weak self] in
            self?.rescueOffScreenPanels()
        }
    }

    public func existingPanel(matching identity: PinContentIdentity) -> PinPanel? {
        panels.first { $0.contentIdentity.matches(identity) }
    }

    public func isPinned(_ identity: PinContentIdentity) -> Bool {
        existingPanel(matching: identity) != nil
    }

    /// Closes any open annotation toolbars across active pins (committing edits by default).
    public func closeAllToolbars(commit: Bool = true) {
        for panel in panels where panel.isToolbarVisible {
            panel.closeToolbar(commit: commit)
        }
    }

    /// Pins `content` if not already on screen. Returns `false` and focuses the existing pin
    /// when a matching pin is already active, or when `content` is invalid / pin limit reached.
    ///
    /// With `screenRect` (AppKit global coordinates, points) the pin is placed directly over
    /// that area; with `nil` it is centered near the cursor and cascaded to avoid stacking.
    @discardableResult
    public func pin(
        content: PinContent,
        at screenRect: CGRect?,
        contentIdentity: PinContentIdentity? = nil
    ) -> Bool {
        guard let sanitizedContent = Self.sanitize(content) else { return false }

        let resolvedIdentity = contentIdentity ?? sanitizedContent.defaultIdentity
        if let existing = existingPanel(matching: resolvedIdentity) {
            if arePinsHidden {
                arePinsHidden = false
                panels.forEach { $0.orderFrontRegardless() }
            } else {
                existing.orderFrontRegardless()
            }
            existing.flashHUD(
                existing.state.isClickThrough
                    ? CCXL10n.text("Pinned · Click-Through", zh: "已贴图 · 鼠标穿透")
                    : CCXL10n.text("Pinned", zh: "已贴图")
            )
            onPinsChanged?()
            return false
        }

        guard panels.count < Self.maxActivePins else { return false }

        let validScreenRect = screenRect.flatMap { PinLayout.isFiniteRect($0) ? $0 : nil }
        let baseSize = PinLayout.baseSize(for: sanitizedContent)
        let visibleFrame = validScreenRect.map { Self.visibleFrame(containing: $0) }
            ?? Self.visibleFrameUnderMouse()
        let placement = PinLayout.initialPlacement(
            baseSize: baseSize,
            screenRect: validScreenRect,
            visibleFrame: visibleFrame
        )
        var targetFrame = placement.frame
        if validScreenRect == nil && !panels.isEmpty {
            targetFrame = Self.cascadedFrame(
                startingFrom: targetFrame,
                existingFrames: panels.map(\.frame),
                visibleFrame: visibleFrame
            )
        }
        let panel = PinPanel(
            content: sanitizedContent,
            frame: targetFrame,
            state: PinState(zoom: placement.zoom),
            contentIdentity: resolvedIdentity
        )
        attachHandlers(to: panel)
        presentNewPanel(panel)
        return true
    }

    private func attachHandlers(to panel: PinPanel) {
        panel.onClose = { [weak self] panel in self?.panelDidClose(panel) }
        panel.onCopy = { [weak self] panel in self?.copy(panel) }
        panel.onCopyText = { [weak self] text in self?.clipboardStore.copyText(text) }
        panel.onSave = { [weak self] panel in self?.save(panel) }
        panel.onQuickSave = { [weak self] panel in self?.quickSave(panel) }
        panel.onDuplicate = { [weak self] panel in self?.duplicate(panel) }
        panel.onCopyFormattedColor = { [weak self] panel, format in
            self?.copyFormattedColor(panel, format: format)
        }
        panel.onRecognizeText = { [weak self] panel in self?.recognizeText(panel) }
        panel.onHideAll = { [weak self] in self?.toggleVisibilityOfAllPins() }
        panel.onCloseAll = { [weak self] in self?.closeAllPins() }
        panel.onUnlockAllClickThrough = { [weak self] in self?.disableClickThroughForAllPins() }
        panel.clickThroughCountProvider = { [weak self] in self?.clickThroughPinCount ?? 0 }
        panel.onReopenClosedPin = { [weak self] in _ = self?.reopenLastClosedPin() }
        panel.canReopenClosedPinProvider = { [weak self] in self?.canReopenClosedPin ?? false }
        panel.onStateChanged = { [weak self] _ in
            guard let self, !self.isBatchUpdatingState else { return }
            self.onPinsChanged?()
        }
        panel.onToolbarWillOpen = { [weak self] openingPanel in
            guard let self else { return }
            for other in self.panels where other !== openingPanel && other.isToolbarVisible {
                other.closeToolbar(commit: true)
            }
            openingPanel.currentAnnotationStyle = self.lastAnnotationStyle
        }
        panel.onAnnotationStyleChanged = { [weak self] style in
            self?.lastAnnotationStyle = style
        }
    }

    private func presentNewPanel(_ panel: PinPanel) {
        panels.append(panel)
        if arePinsHidden {
            // A new pin implies the user wants to see pins again.
            arePinsHidden = false
            panels.forEach { $0.orderFrontRegardless() }
        } else {
            panel.orderFrontRegardless()
        }
        onPinsChanged?()
    }

    /// Pins the next unpinned item in newest-to-oldest order across recent snips and the
    /// clipboard without creating duplicate pins for the same image/content.
    public func pinNextAvailable() -> PinNextOutcome {
        enum LazyCandidate {
            case history(SnipHistoryEntry)
            case clipboard(content: PinContent, identity: PinContentIdentity)

            var identity: PinContentIdentity {
                switch self {
                case let .history(entry): entry.pinIdentity
                case let .clipboard(_, identity): identity
                }
            }

            func resolveContent() -> PinContent {
                switch self {
                case let .history(entry): .image(entry.image, scale: entry.scale)
                case let .clipboard(content, _): content
                }
            }
        }

        let historyCandidates: [LazyCandidate] = clipboardStore.history.map { .history($0) }

        // Fast path: when history takes priority over clipboard, avoid decoding large clipboard
        // or disk-backed PNG payloads unless an unpinned candidate is actually chosen.
        if !clipboardStore.hasClipboardChangedSinceLatestSnip {
            for candidate in historyCandidates where !isPinned(candidate.identity) {
                if pin(content: candidate.resolveContent(), at: nil, contentIdentity: candidate.identity) {
                    return .pinned
                }
            }
        }

        var clipboardCandidate: LazyCandidate?
        if let resolved = clipboardStore.readPinPayloadWithIdentity() {
            let content: PinContent = switch resolved.payload {
            case let .image(image, scale): .image(image, scale: scale)
            case let .color(color): .color(color)
            case let .text(text): .text(text)
            }
            clipboardCandidate = .clipboard(content: content, identity: resolved.identity)
        }

        let matchesHistory = clipboardCandidate.map { clip in
            clipboardStore.history.contains { $0.pinIdentity.matches(clip.identity) }
        } ?? false

        var candidates: [LazyCandidate] = []
        if let clipboardCandidate, !matchesHistory {
            if clipboardStore.hasClipboardChangedSinceLatestSnip {
                candidates.append(clipboardCandidate)
                candidates.append(contentsOf: historyCandidates)
            } else {
                candidates.append(contentsOf: historyCandidates)
                candidates.append(clipboardCandidate)
            }
        } else {
            candidates = historyCandidates
        }

        guard !candidates.isEmpty else { return .nothingAvailable }

        for candidate in candidates where !isPinned(candidate.identity) {
            if pin(content: candidate.resolveContent(), at: nil, contentIdentity: candidate.identity) {
                return .pinned
            }
        }
        return .allAlreadyPinned
    }

    /// Zero-decode status summary for the menu bar Pin quick-action tile.
    public func pinTileStatus() -> PinTileStatus {
        var uniqueHistory: [PinContentIdentity] = []
        for entry in clipboardStore.history {
            let identity = entry.pinIdentity
            if !uniqueHistory.contains(where: { $0.matches(identity) }) {
                uniqueHistory.append(identity)
            }
        }
        let unpinnedHistoryCount = uniqueHistory.filter { !isPinned($0) }.count

        let pbBadge = clipboardStore.peekPinBadge()
        if pbBadge == .empty {
            if unpinnedHistoryCount > 0 {
                return .ready(count: unpinnedHistoryCount, primaryLabel: CCXL10n.text("Image", zh: "图片"))
            }
            return uniqueHistory.isEmpty ? .empty : .allPinned
        }

        if let knownIdentity = clipboardStore.cachedClipboardIdentityIfKnown() {
            let matchesHistory = uniqueHistory.contains { $0.matches(knownIdentity) }
            let clipUnpinned = !matchesHistory && !isPinned(knownIdentity)
            let totalUnpinned = unpinnedHistoryCount + (clipUnpinned ? 1 : 0)
            guard totalUnpinned > 0 else { return .allPinned }
            if clipUnpinned && (clipboardStore.hasClipboardChangedSinceLatestSnip || unpinnedHistoryCount == 0) {
                return .ready(count: totalUnpinned, primaryLabel: pbBadge.displayText)
            }
            return .ready(count: totalUnpinned, primaryLabel: CCXL10n.text("Image", zh: "图片"))
        }

        let label = (unpinnedHistoryCount == 0 || clipboardStore.hasClipboardChangedSinceLatestSnip)
            ? pbBadge.displayText
            : CCXL10n.text("Image", zh: "图片")
        return .ready(count: unpinnedHistoryCount + 1, primaryLabel: label)
    }

    /// Pins the next unpinned item (or clipboard content). Returns `false` when nothing remains to pin.
    @discardableResult
    public func pinFromClipboard() -> Bool {
        pinNextAvailable() == .pinned
    }

    public func toggleVisibilityOfAllPins() {
        guard !panels.isEmpty else {
            arePinsHidden = false
            onPinsChanged?()
            return
        }
        arePinsHidden.toggle()
        for panel in panels {
            if arePinsHidden {
                if panel.isToolbarVisible { panel.closeToolbar(commit: true) }
                panel.orderOut(nil)
            } else {
                panel.orderFrontRegardless()
            }
        }
        onPinsChanged?()
    }

    public func disableClickThroughForAllPins() {
        let targets = panels.filter { $0.state.isClickThrough }
        guard !targets.isEmpty else { return }
        isBatchUpdatingState = true
        for panel in targets {
            panel.setClickThrough(false)
        }
        isBatchUpdatingState = false
        onPinsChanged?()
    }

    public func closeAllPins() {
        let closing = panels
        panels.removeAll()
        var recordedAny = false
        for panel in closing {
            if recordClosedSnapshot(from: panel) {
                recordedAny = true
            }
            panel.onClose = nil
            panel.close()
        }
        arePinsHidden = false
        if recordedAny {
            onClosedPinHistoryChanged?()
        }
        onPinsChanged?()
    }

    /// Reopens the most recently closed pin from the 5-item FIFO history buffer,
    /// clamping its restored frame onto active visible screens and clearing click-through.
    @discardableResult
    public func reopenLastClosedPin() -> Bool {
        guard panels.count < Self.maxActivePins else { return false }
        let screens = NSScreen.screens.map(\.visibleFrame)
        var droppedInvalid = false
        while let snapshot = closedPins.popLast() {
            guard let safeContent = Self.sanitize(snapshot.content) else {
                droppedInvalid = true
                continue
            }
            var restoredState = snapshot.state
            restoredState.isClickThrough = false
            let clampedFrame = screens.isEmpty
                ? snapshot.frame
                : PinLayout.clampedOriginToScreens(
                    snapshot.frame,
                    screens: screens,
                    keepFullyVisible: restoredState.isThumbnail
                )
            let panel = PinPanel(
                content: safeContent,
                frame: clampedFrame,
                state: restoredState,
                contentIdentity: snapshot.contentIdentity
            )
            attachHandlers(to: panel)
            presentNewPanel(panel)
            onClosedPinHistoryChanged?()
            return true
        }
        if droppedInvalid {
            onClosedPinHistoryChanged?()
        }
        return false
    }

    /// Clears all snapshots stored for reopening closed pins.
    public func clearClosedPinHistory() {
        guard !closedPins.isEmpty else { return }
        closedPins.removeAll()
        onClosedPinHistoryChanged?()
        onPinsChanged?()
    }

    /// Clamps any pins stranded off-screen (e.g. after disconnecting an external monitor) back
    /// onto active screens and repositions any open annotation toolbars.
    internal func rescueOffScreenPanels(visibleScreens: [CGRect]? = nil) {
        let screens = visibleScreens ?? NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return }
        for panel in panels {
            let clamped = PinLayout.clampedOriginToScreens(panel.frame, screens: screens)
            if clamped.origin != panel.frame.origin {
                panel.setFrameOrigin(clamped.origin)
            }
            panel.repositionAnnotationToolbarIfVisible()
        }
    }

    // MARK: - Private

    private static func sanitize(_ content: PinContent) -> PinContent? {
        switch content {
        case let .image(image, scale):
            guard let safeImage = PinLayout.sanitizedImage(image) else { return nil }
            return .image(safeImage, scale: PinLayout.sanitizedScale(scale))
        case let .text(string):
            guard string.contains(where: { !$0.isWhitespace && !$0.isNewline }) else { return nil }
            return .text(string)
        case .color:
            return content
        }
    }

    @discardableResult
    private func recordClosedSnapshot(from panel: PinPanel) -> Bool {
        guard let safeContent = Self.sanitize(panel.content) else { return false }
        var savedState = panel.state
        savedState.isClickThrough = false
        let snapshot = ClosedPinSnapshot(
            content: safeContent,
            frame: panel.frame,
            state: savedState,
            contentIdentity: panel.contentIdentity
        )
        closedPins.append(snapshot)
        if closedPins.count > Self.maxClosedPinHistory {
            closedPins.removeFirst(closedPins.count - Self.maxClosedPinHistory)
        }
        return true
    }

    private func panelDidClose(_ panel: PinPanel) {
        let recorded = recordClosedSnapshot(from: panel)
        panels.removeAll { $0 === panel }
        if panels.isEmpty { arePinsHidden = false }
        if recorded {
            onClosedPinHistoryChanged?()
        }
        onPinsChanged?()
    }

    private func copy(_ panel: PinPanel) {
        switch panel.content {
        case let .text(text):
            clipboardStore.copyText(text)
            onCopied?(CCXL10n.text("Copied to Clipboard", zh: "已拷贝到剪贴板"))
        case let .color(color):
            clipboardStore.copyText(color.hexString)
            onCopied?(CCXL10n.text("Copied \(color.hexString)", zh: "已拷贝 \(color.hexString)"))
        case .image:
            if let image = panel.exportImage() {
                clipboardStore.copyImage(image, scale: panel.exportScale)
                onCopied?(CCXL10n.text("Copied to Clipboard", zh: "已拷贝到剪贴板"))
            }
        }
    }

    private func save(_ panel: PinPanel) {
        guard let image = panel.exportImage() else { return }
        onRequestSavePNG?(image)
    }

    private func quickSave(_ panel: PinPanel) {
        guard let image = panel.exportImage() else { return }
        onRequestQuickSavePNG?(image)
    }

    private func duplicate(_ panel: PinPanel) {
        guard panels.count < Self.maxActivePins else {
            panel.flashHUD(CCXL10n.text("Pin Limit Reached", zh: "贴图数量已达上限"))
            return
        }
        if panel.isToolbarVisible {
            panel.closeToolbar(commit: true)
        }
        var clonedState = panel.state
        clonedState.isClickThrough = false

        let visible = Self.visibleFrame(containing: panel.frame)
        let origin = panel.frame
        var candidate = origin.offsetBy(dx: 20, dy: -20)
        if candidate.maxX > visible.maxX || candidate.minY < visible.minY {
            let alt = origin.offsetBy(dx: -20, dy: 20)
            if alt.minX >= visible.minX && alt.maxY <= visible.maxY {
                candidate = alt
            }
        }
        if visible.width > 0 && visible.height > 0 {
            let maxX = max(visible.minX, visible.maxX - candidate.width)
            let maxY = max(visible.minY, visible.maxY - candidate.height)
            candidate.origin.x = min(max(candidate.minX, visible.minX), maxX)
            candidate.origin.y = min(max(candidate.minY, visible.minY), maxY)
        }

        let copy = PinPanel(
            content: panel.content,
            frame: candidate,
            state: clonedState,
            contentIdentity: panel.contentIdentity
        )
        attachHandlers(to: copy)
        presentNewPanel(copy)
    }

    private func copyFormattedColor(_ panel: PinPanel, format: ColorFormat) {
        guard case let .color(sample) = panel.content else { return }
        let formatted = sample.formatted(as: format)
        clipboardStore.copyText(formatted)
        onCopied?(CCXL10n.text("Copied \(formatted)", zh: "已拷贝 \(formatted)"))
    }

    private func recognizeText(_ panel: PinPanel) {
        guard case .image = panel.content, let image = panel.exportImage() else { return }
        panel.flashHUD(CCXL10n.text("OCR…", zh: "识别中…"))
        onRequestRecognizeText?(image)
    }

    private static func cascadedFrame(
        startingFrom initial: CGRect,
        existingFrames: [CGRect],
        visibleFrame: CGRect
    ) -> CGRect {
        var candidate = initial
        for _ in 0..<12 {
            let overlapsOrigin = existingFrames.contains {
                abs($0.origin.x - candidate.origin.x) < 8 &&
                abs($0.origin.y - candidate.origin.y) < 8
            }
            if !overlapsOrigin {
                return candidate
            }
            var next = candidate.offsetBy(dx: 24, dy: -24)
            if visibleFrame.width > 0 && visibleFrame.height > 0 {
                let minX = visibleFrame.minX
                let maxX = max(minX, visibleFrame.maxX - next.width)
                let minY = visibleFrame.minY
                let maxY = max(minY, visibleFrame.maxY - next.height)
                if next.maxX > visibleFrame.maxX {
                    next.origin.x = min(minX + 24, maxX)
                } else {
                    next.origin.x = max(next.origin.x, minX)
                }
                if next.minY < visibleFrame.minY {
                    next.origin.y = max(maxY - 24, minY)
                } else {
                    next.origin.y = min(next.origin.y, maxY)
                }
            }
            candidate = next
        }
        return candidate
    }

    private static func visibleFrame(containing rect: CGRect) -> CGRect {
        let screens = NSScreen.screens.map { ($0.frame, $0.visibleFrame) }
        return PinLayout.bestScreenFrame(for: rect, in: screens) ?? visibleFrameUnderMouse()
    }

    private static func visibleFrameUnderMouse() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

/// Selector-based observer for screen configuration changes (automatically unregisters on dealloc).
@MainActor
private final class ScreenParametersObserver: NSObject {
    var onScreensChanged: (() -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersDidChange() {
        onScreensChanged?()
    }
}
