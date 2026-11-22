import AppKit
import CPXCore
import CPXPin
import SwiftUI

/// Commands issued from the status bar popover.
@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarRequestedSnip()
    func menuBarRequestedPinFromClipboard()
    func menuBarRequestedPinHistoryEntry(_ entry: SnipHistoryEntry)
    func menuBarRequestedToggleAllPins()
    func menuBarRequestedUnlockClickThrough()
    func menuBarRequestedCloseAllPins()
    func menuBarRequestedPermissionsGuide()
    func menuBarRequestedSettings()
}

/// Non-activating borderless floating panel hosting the menu bar popover.
private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 272, height: 220),
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

    private let statusItem: NSStatusItem
    private let pinManager: PinManager
    private let hotKeyManager: GlobalHotKeyManager
    private let clipboardStore: ClipboardStore
    private let model = MenuBarPanelModel()

    private var panel: MenuBarPanel?
    private var hostingView: NSHostingView<MenuBarPopoverView>?

    nonisolated(unsafe) private var globalMouseMonitor: Any?
    nonisolated(unsafe) private var localMouseMonitor: Any?
    nonisolated(unsafe) private var localKeyMonitor: Any?

    init(
        pinManager: PinManager,
        hotKeyManager: GlobalHotKeyManager,
        clipboardStore: ClipboardStore
    ) {
        self.pinManager = pinManager
        self.hotKeyManager = hotKeyManager
        self.clipboardStore = clipboardStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "CPX")
                ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "CPX")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        syncModel()
    }

    deinit {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }

    /// Refreshes popover data and updates the panel geometry if visible.
    func refresh() {
        syncModel()
        if let panel, panel.isVisible {
            layoutAndPosition(panel: panel)
        }
    }

    // MARK: - Panel lifecycle

    @objc private func handleStatusItemClick() {
        if let type = NSApp.currentEvent?.type, type == .rightMouseDown || type == .rightMouseUp {
            hidePanel()
            delegate?.menuBarRequestedPinFromClipboard()
            return
        }
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

        Task { @MainActor [weak self] in
            self?.statusItem.button?.highlight(true)
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
                onPastePin: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedPinFromClipboard()
                },
                onPinHistory: { [weak self] entry in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedPinHistoryEntry(entry)
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
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedPermissionsGuide()
                },
                onOpenSettings: { [weak self] in
                    self?.hidePanel()
                    self?.delegate?.menuBarRequestedSettings()
                },
                onQuit: { [weak self] in
                    self?.hidePanel()
                    NSApp.terminate(nil)
                }
            )
        )

        let hostingView = NSHostingView(rootView: rootView)
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
        let buttonFrame = buttonWindow.frame

        var originX = buttonFrame.midX - size.width / 2
        let originY = buttonFrame.minY - 6 - size.height

        if let visibleFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            let minX = visibleFrame.minX + 8
            let maxX = visibleFrame.maxX - size.width - 8
            originX = min(max(originX, minX), maxX)
        }

        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
    }

    private func syncModel() {
        model.sync(
            pinManager: pinManager,
            hotKeyManager: hotKeyManager,
            clipboardStore: clipboardStore
        )
        if pinManager.hasClickThroughPins {
            statusItem.button?.toolTip = "CPX — Click-through pin active (click to unlock)"
        } else if pinManager.arePinsHidden {
            statusItem.button?.toolTip = "CPX — \(pinManager.pinCount) pin(s) hidden (click to show)"
        } else {
            statusItem.button?.toolTip = "CPX — Click to open, right-click to pin clipboard"
        }
    }

    // MARK: - Event monitors & NSWindowDelegate

    private func installEventMonitors() {
        removeEventMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
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
                guard let self, let panel = self.panel, panel.isVisible else { return }
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
                guard let self, let panel = self.panel, panel.isVisible else { return false }

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
                        self.hidePanel()
                        self.delegate?.menuBarRequestedSettings()
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
        hidePanel()
    }
}
