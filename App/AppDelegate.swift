import AppKit
import CCXCapture
import CCXCore
import CCXPin
import UniformTypeIdentifiers

/// Owns the app-wide services and routes hotkeys, menu commands, and snip
/// outcomes between the capture, pin, and clipboard modules.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasCompletedOnboardingKey = "CCXHasCompletedOnboarding"

    private let clipboardStore: ClipboardStore
    private let pinManager: PinManager
    private let snipCoordinator: SnipCoordinator
    private let hotKeyManager: GlobalHotKeyManager
    private let toast: ToastHUD

    private var menuBarController: MenuBarController?
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var hadClickThroughPins = false

    override init() {
        let clipboardStore = ClipboardStore()
        self.clipboardStore = clipboardStore
        self.pinManager = PinManager(clipboardStore: clipboardStore)
        self.snipCoordinator = SnipCoordinator()
        self.hotKeyManager = GlobalHotKeyManager()
        self.toast = ToastHUD()
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        pinManager.onPinsChanged = { [weak self] in
            guard let self else { return }
            let hasClickThrough = self.pinManager.hasClickThroughPins
            if hasClickThrough && !self.hadClickThroughPins {
                self.toast.show("Click-Through On — Unlock in Menu Bar", symbolName: "cursorarrow.click")
            }
            self.hadClickThroughPins = hasClickThrough
            self.menuBarController?.refresh()
        }
        pinManager.onRequestSavePNG = { [weak self] image in
            self?.presentSavePanel(for: image)
        }

        hotKeyManager.onAction = { [weak self] action in
            self?.perform(action)
        }
        hotKeyManager.registerDefaults()

        let menuBarController = MenuBarController(
            pinManager: pinManager,
            clipboardStore: clipboardStore
        )
        menuBarController.delegate = self
        self.menuBarController = menuBarController

        if !PermissionManager.currentStatus().screenRecording {
            showOnboarding(startingAt: .welcome)
        } else if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            showOnboarding(startingAt: .ready)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        snipCoordinator.cancelActiveSnip()
        hotKeyManager.unregisterAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Commands

    private func perform(_ action: CCXHotKeyAction) {
        switch action {
        case .snip:
            startSnip()
        }
    }

    private func startSnip() {
        guard !snipCoordinator.isSessionActive else { return }
        snipCoordinator.startSnip { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    private func pinFromClipboard() {
        if !pinManager.pinFromClipboard() {
            toast.show("Nothing to Pin in Clipboard", symbolName: "exclamationmark.circle")
        }
    }

    private func toggleAllPins() {
        guard pinManager.pinCount > 0 else {
            toast.show("No Active Pins", symbolName: "pin.slash")
            return
        }
        pinManager.toggleVisibilityOfAllPins()
        menuBarController?.refresh()
    }

    private func unlockClickThroughPins() {
        guard pinManager.hasClickThroughPins else { return }
        pinManager.disableClickThroughForAllPins()
        toast.show("Click-Through Disabled", symbolName: "cursorarrow.click")
        menuBarController?.refresh()
    }

    // MARK: - Snip outcomes

    private func handle(_ outcome: SnipOutcome) {
        switch outcome {
        case .pin(let result):
            record(result)
            pinManager.pin(content: .image(result.image, scale: result.scale), at: result.screenRect)
        case .copy(let result):
            record(result)
            clipboardStore.copyImage(result.image, scale: result.scale)
            toast.show("Copied to Clipboard")
        case .save(let result):
            record(result)
            presentSavePanel(for: result.image)
        case .copiedColor(let sample, let format):
            let text = sample.formatted(as: format)
            clipboardStore.copyText(text)
            toast.show("Copied \(text)", symbolName: "eyedropper")
        case .permissionDenied:
            menuBarController?.refresh()
            toast.show("Screen Recording Permission Required", symbolName: "exclamationmark.triangle")
            showOnboarding(startingAt: .permissions)
        case .failed(let message):
            toast.show("Capture Failed: \(message)", symbolName: "exclamationmark.triangle")
        case .cancelled:
            break
        }
        menuBarController?.refresh()
    }

    private func record(_ result: SnipResult) {
        clipboardStore.recordSnip(image: result.image, scale: result.scale, screenRect: result.screenRect)
    }

    // MARK: - Saving

    private func presentSavePanel(for image: CGImage) {
        let panel = NSSavePanel()
        panel.title = "Save Snip"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.defaultPNGFileName(for: Date())
        panel.level = .modalPanel

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try clipboardStore.savePNG(image, to: url)
            toast.show("Saved PNG", symbolName: "square.and.arrow.down")
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Save PNG"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Returns `CCX-yyyyMMdd-HHmmss.png` for the given date.
    static func defaultPNGFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "CCX-\(formatter.string(from: date)).png"
    }

    // MARK: - Windows

    private func showOnboarding(startingAt step: OnboardingStep = .welcome) {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                onComplete: {
                    UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                },
                onTrySnip: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(220))
                        self?.startSnip()
                    }
                }
            )
        }
        onboardingController?.show(startingAt: step)
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.show()
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarRequestedSnip() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.startSnip()
        }
    }

    func menuBarRequestedPinFromClipboard() {
        pinFromClipboard()
    }

    func menuBarRequestedPinHistoryEntry(_ entry: SnipHistoryEntry) {
        pinManager.pin(content: .image(entry.image, scale: entry.scale), at: nil)
        menuBarController?.refresh()
    }

    func menuBarRequestedToggleAllPins() {
        toggleAllPins()
    }

    func menuBarRequestedUnlockClickThrough() {
        unlockClickThroughPins()
    }

    func menuBarRequestedCloseAllPins() {
        pinManager.closeAllPins()
        menuBarController?.refresh()
    }

    func menuBarRequestedPermissionsGuide() {
        showOnboarding(startingAt: .permissions)
    }

    func menuBarRequestedSettings() {
        showSettings()
    }
}
