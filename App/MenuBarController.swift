import AppKit
import CCXCore
import CCXPin
import CCXRecord
import SwiftUI

/// Commands issued from the status bar popover.
@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarRequestedSnip()
    func menuBarRequestedRecord()
    func menuBarRequestedOpenRecordingsFolder()
    func menuBarRequestedStopRecording()
    func menuBarRequestedTogglePauseRecording()
    func menuBarRequestedDiscardRecording()
    func menuBarRequestedPinFromClipboard()
    func menuBarRequestedClearClipboard()
    func menuBarRequestedPinHistoryEntry(_ entry: SnipHistoryEntry)
    func menuBarRequestedClearHistory()
    func menuBarRequestedToggleAllPins()
    func menuBarRequestedUnlockClickThrough()
    func menuBarRequestedCloseAllPins()
    func menuBarRequestedPermissionsGuide()
    func menuBarRequestedSettings()
}

private struct SendableMenuBarTeardown: @unchecked Sendable {
    let monitors: [Any]
    let observers: [NSObjectProtocol]
}

/// Non-activating borderless floating panel hosting the menu bar popover.
private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 316, height: 220),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}

/// Owns the `NSStatusItem` and presents a Liquid Glass popover panel anchored
/// directly beneath the menu bar icon.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    weak var delegate: MenuBarControllerDelegate?

    private struct StatusButtonRenderKey: Equatable {
        let isPaused: Bool
        let formattedElapsed: String
        let format: RecordingFormat
    }

    private static let statusTimerFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let recordingStatusIcon: NSImage? = makeRecordingStatusIcon(
        symbolName: "record.circle.fill",
        tintColor: .systemRed
    )
    private static let pausedStatusIcon: NSImage? = makeRecordingStatusIcon(
        symbolName: "pause.circle.fill",
        tintColor: .systemOrange
    )

    private static func makeRecordingStatusIcon(symbolName: String, tintColor: NSColor) -> NSImage? {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tintColor]))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Recording")?
            .withSymbolConfiguration(symbolConfig)
        image?.isTemplate = false
        return image
    }

    private let statusItem: NSStatusItem
    private let pinManager: PinManager
    private let clipboardStore: ClipboardStore
    private let model = MenuBarPanelModel()
    private var recordingStatus: RecordingMenuBarStatus?
    private var lastStatusButtonKey: StatusButtonRenderKey?
    private var isShowingRecordingButton = false
    private var lastRecordingPaused: Bool?
    private var brandButtonImage: NSImage?
    private var isSnipHotKeyRegistered = true
    private var isTrackingContextMenu = false
    private var pendingLayoutPass = false

    private var panel: MenuBarPanel?
    private var hostingView: NSHostingView<MenuBarPopoverView>?
    private var pendingPopoverActionAnchor: NSRect?

    nonisolated(unsafe) private var globalMouseMonitor: Any?
    nonisolated(unsafe) private var localMouseMonitor: Any?
    nonisolated(unsafe) private var localKeyMonitor: Any?
    nonisolated(unsafe) private var menuBeginObserver: NSObjectProtocol?
    nonisolated(unsafe) private var menuEndObserver: NSObjectProtocol?

    init(
        pinManager: PinManager,
        clipboardStore: ClipboardStore
    ) {
        self.pinManager = pinManager
        self.clipboardStore = clipboardStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            if let brandImage = NSImage(named: "MenuBarIcon") ?? NSImage(named: "BrandIcon") {
                brandImage.size = NSSize(width: 18, height: 18)
                brandImage.isTemplate = false
                brandImage.accessibilityDescription = "CCX"
                button.image = brandImage
            } else {
                let fallback = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "CCX")
                    ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "CCX")
                fallback?.isTemplate = true
                button.image = fallback
            }
            brandButtonImage = button.image
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        syncModel()
    }

    func updateRecordingStatus(_ status: RecordingMenuBarStatus?) {
        let previous = recordingStatus
        recordingStatus = status
        let nextKey = status.map {
            StatusButtonRenderKey(isPaused: $0.isPaused, formattedElapsed: $0.formattedElapsed, format: $0.format)
        }
        guard nextKey != lastStatusButtonKey else { return }
        lastStatusButtonKey = nextKey
        updateStatusButtonAppearance()
        updateStatusTooltip()
        guard panel?.isVisible == true else { return }

        let isElapsedTickOnly = previous != nil
            && status != nil
            && previous?.isPaused == status?.isPaused
            && previous?.format == status?.format
        if isElapsedTickOnly {
            model.updateRecordingStatusOnly(status)
        } else {
            refresh()
        }
    }

    func updateHotKeyRegistered(_ registered: Bool) {
        guard isSnipHotKeyRegistered != registered else { return }
        isSnipHotKeyRegistered = registered
        if panel?.isVisible == true {
            refresh()
        }
    }

    /// Syncs or drops cached recent snip entries immediately even while the popover is hidden
    /// so cleared or evicted screenshots do not stay retained in memory.
    func handleHistoryChanged() {
        model.syncRecentSnipsOnly(clipboardStore: clipboardStore)
        if panel?.isVisible == true {
            refresh()
        }
    }

    deinit {
        let teardown = SendableMenuBarTeardown(
            monitors: [globalMouseMonitor, localMouseMonitor, localKeyMonitor].compactMap { $0 },
            observers: [menuBeginObserver, menuEndObserver].compactMap { $0 }
        )
        let cleanup: @Sendable () -> Void = {
            for monitor in teardown.monitors {
                NSEvent.removeMonitor(monitor)
            }
            for observer in teardown.observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async(execute: cleanup)
        }
    }

    /// Screen-coordinate frame of the menu bar status item button.
    var statusButtonScreenFrame: NSRect? {
        statusItem.button?.window?.frame
    }

    /// Reliable display-consistent anchor frame for auxiliary windows (Settings / Setup Guide)
    /// launched from the menu bar popover or app reopen. Prefers `statusButtonScreenFrame` when
    /// it lives on the same display as the visible popover (or mouse cursor), falling back to the
    /// visible popover's top anchor if the status bar button frame is stale on another display.
    var popoverAnchorScreenFrame: NSRect? {
        if let pendingPopoverActionAnchor {
            return pendingPopoverActionAnchor
        }
        return resolvePopoverAnchorScreenFrame()
    }

    private var validStatusButtonScreenFrame: NSRect? {
        guard let frame = statusButtonScreenFrame,
              !frame.isNull,
              frame.width > 0,
              frame.height > 0,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              NSScreen.screens.contains(where: { screen in
                  let overlap = screen.frame.intersection(frame)
                  return !overlap.isNull && !overlap.isEmpty && overlap.width > 0 && overlap.height > 0
              })
        else {
            return nil
        }
        return frame
    }

    private func resolvePopoverAnchorScreenFrame() -> NSRect? {
        if let panel, panel.isVisible {
            let panelScreen = WindowScreenLocator.screen(for: panel.frame) ?? panel.screen
            if let buttonFrame = validStatusButtonScreenFrame,
               let buttonScreen = WindowScreenLocator.screen(for: buttonFrame),
               WindowScreenLocator.isSameScreen(buttonScreen, panelScreen) {
                return buttonFrame
            }
            return Self.panelTopAnchorFrame(for: panel.frame, on: panelScreen)
        }

        let cursorScreen = WindowScreenLocator.activeCursorScreen()
        if let buttonFrame = validStatusButtonScreenFrame,
           let buttonScreen = WindowScreenLocator.screen(for: buttonFrame),
           WindowScreenLocator.isSameScreen(buttonScreen, cursorScreen) {
            return buttonFrame
        }
        return nil
    }

    private static func panelTopAnchorFrame(for panelFrame: NSRect, on screen: NSScreen?) -> NSRect {
        let desiredY = panelFrame.maxY + 6
        let clampedY: CGFloat
        if let screenFrame = screen?.frame {
            let minY = screenFrame.minY
            let maxY = max(minY, screenFrame.maxY - 2)
            clampedY = min(max(desiredY, minY), maxY)
        } else {
            clampedY = desiredY
        }
        return NSRect(x: panelFrame.origin.x, y: clampedY, width: panelFrame.width, height: 1)
    }

    private func invokePopoverAction(_ action: () -> Void) {
        pendingPopoverActionAnchor = resolvePopoverAnchorScreenFrame()
        defer { pendingPopoverActionAnchor = nil }
        hidePanel()
        action()
    }

    /// Opens the popover when the status bar icon is currently visible on a display.
    /// Returns `false` if the icon is hidden/clipped (for example behind a MacBook notch),
    /// so callers can fall back to presenting Settings instead.
    @discardableResult
    func openPanelIfStatusButtonVisible() -> Bool {
        guard validStatusButtonScreenFrame != nil else {
            return false
        }
        if panel?.isVisible != true {
            showPanel()
        } else {
            panel?.makeKeyAndOrderFront(nil)
            refresh()
        }
        return true
    }

    /// Refreshes popover data and updates the panel geometry if visible.
    func refresh() {
        updateStatusTooltip()
        guard let panel, panel.isVisible else { return }
        syncModel()
        layoutAndPosition(panel: panel)
        guard !pendingLayoutPass else { return }
        pendingLayoutPass = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLayoutPass = false
            guard let panel = self.panel, panel.isVisible else { return }
            self.layoutAndPosition(panel: panel)
        }
    }

    // MARK: - Panel lifecycle

    @objc private func handleStatusItemClick() {
        togglePanel()
    }

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        syncModel()
        let panel = ensurePanel()
        layoutAndPosition(panel: panel)
        installEventMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.button?.highlight(true)
            if let panel = self.panel, panel.isVisible {
                self.layoutAndPosition(panel: panel)
            }
        }
    }

    func hidePanel() {
        removeEventMonitors()
        statusItem.button?.highlight(false)
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> MenuBarPanel {
        if let panel { return panel }

        let panel = MenuBarPanel()
        panel.delegate = self

        let rootView = MenuBarPopoverView(
            model: model,
            actions: MenuBarPopoverActions(
                onSnip: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedSnip()
                },
                onRecord: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedRecord()
                },
                onOpenRecordingsFolder: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedOpenRecordingsFolder()
                },
                onStopRecording: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedStopRecording()
                },
                onTogglePauseRecording: { [weak self] in
                    self?.delegate?.menuBarRequestedTogglePauseRecording()
                },
                onDiscardRecording: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedDiscardRecording()
                },
                onPastePin: { [weak self] in
                    self?.delegate?.menuBarRequestedPinFromClipboard()
                },
                onClearClipboard: { [weak self] in
                    self?.delegate?.menuBarRequestedClearClipboard()
                },
                onPinHistory: { [weak self] entry in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedPinHistoryEntry(entry)
                },
                onClearHistory: { [weak self] in
                    self?.delegate?.menuBarRequestedClearHistory()
                },
                onToggleAllPins: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedToggleAllPins()
                },
                onUnlockClickThrough: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedUnlockClickThrough()
                },
                onCloseAllPins: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedCloseAllPins()
                },
                onOpenPermissions: { [weak self] in
                    self?.invokePopoverAction {
                        self?.delegate?.menuBarRequestedPermissionsGuide()
                    }
                },
                onOpenSettings: { [weak self] in
                    self?.invokePopoverAction {
                        self?.delegate?.menuBarRequestedSettings()
                    }
                },
                onQuit: { [weak self] in
                    self?.hidePanel()
                    NSApp.terminate(nil)
                }
            )
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    private func layoutAndPosition(panel: MenuBarPanel) {
        guard let hostingView,
              let button = statusItem.button,
              let buttonWindow = button.window
        else { return }

        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let buttonFrame = buttonWindow.frame

        var originX = buttonFrame.midX - size.width / 2
        var originY = buttonFrame.minY - 6 - size.height

        if let visibleFrame = (WindowScreenLocator.screen(for: buttonFrame) ?? buttonWindow.screen)?.visibleFrame {
            let origin = WindowScreenLocator.clampOrigin(
                NSPoint(x: originX, y: originY),
                windowSize: size,
                to: visibleFrame
            )
            originX = origin.x
            originY = origin.y
        }

        let targetFrame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
            panel.invalidateShadow()
        }
    }

    private func syncModel() {
        model.sync(
            pinManager: pinManager,
            clipboardStore: clipboardStore,
            recordingStatus: recordingStatus,
            isSnipHotKeyRegistered: isSnipHotKeyRegistered
        )
        updateStatusTooltip()
    }

    private func updateStatusTooltip() {
        let nextTooltip: String
        if let recordingStatus {
            let stateWord = recordingStatus.isPaused ? "Paused" : "Recording"
            nextTooltip = "CCX — \(stateWord) \(recordingStatus.format.label) (\(recordingStatus.formattedElapsed))"
        } else if pinManager.hasClickThroughPins {
            nextTooltip = "CCX — Click-through pin active (click to unlock)"
        } else if pinManager.arePinsHidden {
            nextTooltip = "CCX — \(pinManager.pinCount) pin(s) hidden (click to show)"
        } else {
            nextTooltip = "CCX — Control · Command · X"
        }
        if statusItem.button?.toolTip != nextTooltip {
            statusItem.button?.toolTip = nextTooltip
        }
    }

    private func updateStatusButtonAppearance() {
        guard let button = statusItem.button else { return }
        guard let status = recordingStatus else {
            guard isShowingRecordingButton else { return }
            isShowingRecordingButton = false
            lastRecordingPaused = nil
            statusItem.length = NSStatusItem.squareLength
            button.image = brandButtonImage
            button.imagePosition = .imageOnly
            button.title = ""
            button.contentTintColor = nil
            return
        }

        if !isShowingRecordingButton || lastRecordingPaused != status.isPaused {
            isShowingRecordingButton = true
            lastRecordingPaused = status.isPaused
            statusItem.length = NSStatusItem.variableLength
            button.image = status.isPaused ? Self.pausedStatusIcon : Self.recordingStatusIcon
            button.imagePosition = .imageLeading
            button.contentTintColor = status.isPaused ? .systemOrange : .systemRed
        }
        button.attributedTitle = NSAttributedString(
            string: " \(status.formattedElapsed)",
            attributes: [
                .font: Self.statusTimerFont,
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    // MARK: - Event monitors & NSWindowDelegate

    private func installEventMonitors() {
        removeEventMonitors()

        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isTrackingContextMenu = true
            }
        }

        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isTrackingContextMenu = false
            }
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTrackingContextMenu, let panel = self.panel, panel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                if let buttonFrame = self.statusItem.button?.window?.frame, buttonFrame.contains(mouse) {
                    return
                }
                self.hidePanel()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let eventWindowNumber = event.windowNumber
            MainActor.assumeIsolated {
                guard let self, !self.isTrackingContextMenu, let panel = self.panel, panel.isVisible else { return }
                if eventWindowNumber != panel.windowNumber,
                   eventWindowNumber != self.statusItem.button?.window?.windowNumber {
                    self.hidePanel()
                }
            }
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let consumed = MainActor.assumeIsolated {
                guard let self, !self.isTrackingContextMenu, let panel = self.panel, panel.isVisible else { return false }

                if keyCode == 53 {
                    self.hidePanel()
                    return true
                }

                if modifiers == .command, let chars {
                    if chars == "w" {
                        self.hidePanel()
                        return true
                    }
                    if chars == "," {
                        self.invokePopoverAction {
                            self.delegate?.menuBarRequestedSettings()
                        }
                        return true
                    }
                    if chars == "q" {
                        self.hidePanel()
                        NSApp.terminate(nil)
                        return true
                    }
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    private func removeEventMonitors() {
        isTrackingContextMenu = false
        if let menuBeginObserver {
            NotificationCenter.default.removeObserver(menuBeginObserver)
            self.menuBeginObserver = nil
        }
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
            self.menuEndObserver = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if isTrackingContextMenu {
            return
        }
        if let type = NSApp.currentEvent?.type,
           type == .leftMouseDown || type == .rightMouseDown,
           statusButtonScreenFrame?.contains(NSEvent.mouseLocation) == true {
            return
        }
        hidePanel()
    }
}
