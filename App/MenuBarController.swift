import AppKit
import CPXCore
import CPXPin

/// Commands issued from the status bar menu.
@MainActor
protocol MenuBarControllerDelegate: AnyObject {
    func menuBarRequestedSnip()
    func menuBarRequestedPinFromClipboard()
    func menuBarRequestedToggleAllPins()
    func menuBarRequestedUnlockClickThrough()
    func menuBarRequestedCloseAllPins()
    func menuBarRequestedPermissionsGuide()
    func menuBarRequestedSettings()
}

/// Owns the `NSStatusItem` and rebuilds its menu from live pin, hotkey, and
/// permission state every time it opens.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    weak var delegate: MenuBarControllerDelegate?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let pinManager: PinManager
    private let hotKeyManager: GlobalHotKeyManager

    init(pinManager: PinManager, hotKeyManager: GlobalHotKeyManager) {
        self.pinManager = pinManager
        self.hotKeyManager = hotKeyManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "CPX")
                ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "CPX")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "CPX"
        }

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    /// Rebuilds the menu so state changes are reflected immediately.
    func refresh() {
        rebuildMenu()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(commandItem(.snip, symbol: "viewfinder", action: #selector(snip)))
        menu.addItem(commandItem(.pastePin, symbol: "pin", action: #selector(pinFromClipboard)))

        menu.addItem(.separator())

        let pinCount = pinManager.pinCount
        let countItem = NSMenuItem(
            title: pinCount == 1 ? "1 Active Pin" : "\(pinCount) Active Pins",
            action: nil,
            keyEquivalent: ""
        )
        countItem.isEnabled = false
        menu.addItem(countItem)

        let toggleItem = commandItem(
            .toggleAllPins,
            title: pinManager.arePinsHidden ? "Show All Pins" : "Hide All Pins",
            symbol: pinManager.arePinsHidden ? "eye" : "eye.slash",
            action: #selector(toggleAllPins)
        )
        toggleItem.isEnabled = pinCount > 0
        menu.addItem(toggleItem)

        let unlockItem = commandItem(
            .unlockClickThrough,
            symbol: "cursorarrow.click",
            action: #selector(unlockClickThrough)
        )
        unlockItem.isEnabled = pinManager.hasClickThroughPins
        menu.addItem(unlockItem)

        let closeAllItem = item("Close All Pins", symbol: "xmark.circle", action: #selector(closeAllPins))
        closeAllItem.isEnabled = pinCount > 0
        menu.addItem(closeAllItem)

        menu.addItem(.separator())

        menu.addItem(permissionsItem())
        menu.addItem(item("Settings…", symbol: "gearshape", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit CPX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
    }

    private func permissionsItem() -> NSMenuItem {
        let status = PermissionManager.currentStatus()
        let allGranted = status.screenRecording && status.accessibility

        let parent = NSMenuItem(title: "Permissions…", action: nil, keyEquivalent: "")
        parent.image = symbolImage(allGranted ? "checkmark.shield" : "exclamationmark.triangle.fill")

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(permissionRow(
            "Screen Recording",
            granted: status.screenRecording,
            action: #selector(openScreenRecordingSettings)
        ))
        submenu.addItem(permissionRow(
            "Accessibility",
            granted: status.accessibility,
            action: #selector(openAccessibilitySettings)
        ))
        submenu.addItem(.separator())
        submenu.addItem(item("Open Permissions Guide…", symbol: "questionmark.circle", action: #selector(openPermissionsGuide)))
        parent.submenu = submenu
        return parent
    }

    private func permissionRow(_ title: String, granted: Bool, action: Selector) -> NSMenuItem {
        let row = NSMenuItem(
            title: granted ? title : "\(title) — Not Granted",
            action: action,
            keyEquivalent: ""
        )
        row.target = self
        row.state = granted ? .on : .off
        if !granted {
            row.image = symbolImage("exclamationmark.triangle.fill")
        }
        row.toolTip = granted ? "Granted" : "Click to open System Settings"
        return row
    }

    private func commandItem(
        _ action: CPXHotKeyAction,
        title: String? = nil,
        symbol: String,
        action selector: Selector
    ) -> NSMenuItem {
        let title = title ?? action.cpxMenuTitle
        let menuItem = item(title, symbol: symbol, action: selector)
        if let combo = hotKeyManager.currentCombo(for: action) {
            menuItem.attributedTitle = Self.titleWithShortcut(title, shortcut: combo.displayString)
            menuItem.toolTip = "\(title) (\(combo.displayString))"
        }
        return menuItem
    }

    private func item(
        _ title: String,
        symbol: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.target = self
        menuItem.image = symbolImage(symbol)
        return menuItem
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// Renders "Title<tab>Shortcut" with a right-aligned, secondary-colored
    /// global hotkey label (these are Carbon hotkeys, not menu key equivalents).
    private static func titleWithShortcut(_ title: String, shortcut: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 260)]

        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        result.append(NSAttributedString(
            string: "\t\(shortcut)",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        ))
        return result
    }

    // MARK: - Actions

    @objc private func snip() {
        delegate?.menuBarRequestedSnip()
    }

    @objc private func pinFromClipboard() {
        delegate?.menuBarRequestedPinFromClipboard()
    }

    @objc private func toggleAllPins() {
        delegate?.menuBarRequestedToggleAllPins()
    }

    @objc private func unlockClickThrough() {
        delegate?.menuBarRequestedUnlockClickThrough()
    }

    @objc private func closeAllPins() {
        delegate?.menuBarRequestedCloseAllPins()
    }

    @objc private func openScreenRecordingSettings() {
        PermissionManager.openScreenRecordingSettings()
    }

    @objc private func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }

    @objc private func openPermissionsGuide() {
        delegate?.menuBarRequestedPermissionsGuide()
    }

    @objc private func openSettings() {
        delegate?.menuBarRequestedSettings()
    }
}
