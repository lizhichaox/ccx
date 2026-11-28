import AppKit
import CCXCapture
import CCXCore
import CCXPin
import CCXRecord
import Darwin
import UniformTypeIdentifiers

/// Owns the app-wide services and routes hotkeys, menu commands, and snip
/// outcomes between the capture, pin, record, and clipboard modules.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hasCompletedOnboardingKey = "CCXHasCompletedOnboarding"
    private static let lastSaveDirectoryKey = "CCXLastSaveDirectory"
    private static let recordingsDirectoryKey = "CCXRecordingsDirectory"
    private nonisolated static let maxQuickSaveSuffixAttempts = 9_999
    private nonisolated static let maxRetainedPasteboardRecordings = 3
    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private let clipboardStore: ClipboardStore
    private let pinManager: PinManager
    private let snipCoordinator: SnipCoordinator
    private let recordingCoordinator: RecordingCoordinator
    private let hotKeyManager: GlobalHotKeyManager
    private let toast: ToastHUD
    private let updateManager = AppUpdateManager()
    private let activityArbiter = ActivityArbiter()

    private var menuBarController: MenuBarController?
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var hotKeyBindings: [CCXHotKeyAction: HotKeyCombo] = {
        var bindings: [CCXHotKeyAction: HotKeyCombo] = [:]
        for action in CCXHotKeyAction.allCases {
            if let combo = HotKeyPreferences.loadBinding(for: action) {
                bindings[action] = combo
            }
        }
        return bindings
    }()
    private var currentSnipCombo: HotKeyCombo {
        hotKeyBindings[.snip] ?? .defaultSnip
    }
    private var isRecordingShortcut = false
    private var hadClickThroughPins = false
    private var pendingLaunchTask: Task<Void, Never>?
    private var scheduledUpdateCheckTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var ocrTaskID = UUID()
    private var isPresentingSavePanel = false
    private weak var activeSavePanel: NSSavePanel?
    private var activeRecordingSave: RecordingResult?
    private var pendingRecordingSaves: [RecordingResult] = []
    private var isRelaunching = false
    private var didBecomeActiveObserver: NSObjectProtocol?

    override init() {
        let clipboardStore = ClipboardStore(
            historyDirectoryURL: ClipboardStore.defaultHistoryDirectoryURL(),
            userDefaults: .standard
        )
        self.clipboardStore = clipboardStore
        self.pinManager = PinManager(clipboardStore: clipboardStore)
        self.snipCoordinator = SnipCoordinator()
        self.recordingCoordinator = RecordingCoordinator()
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
                self.toast.show(
                    CCXL10n.text("Click-Through On — Unlock in Menu Bar", zh: "已开启穿透，可在菜单栏解除"),
                    symbolName: "cursorarrow.click"
                )
            }
            self.hadClickThroughPins = hasClickThrough
            self.menuBarController?.refresh()
            self.settingsController?.refreshResourceUsage()
            self.activityArbiter.setCondition(.pin, active: self.pinManager.pinCount > 0)
        }
        pinManager.onClosedPinHistoryChanged = { [weak self] in
            self?.menuBarController?.refresh()
        }
        pinManager.onRequestSavePNG = { [weak self] image in
            self?.presentSavePanel(for: image)
        }
        pinManager.onRequestQuickSavePNG = { [weak self] image in
            self?.quickSavePNG(image)
        }
        pinManager.onCopied = { [weak self] message in
            self?.toast.show(message)
        }
        pinManager.onRequestRecognizeText = { [weak self] image in
            self?.recognizeAndCopyText(from: image)
        }

        hotKeyManager.onAction = { [weak self] action in
            self?.perform(action)
        }
        var snipHotKeyRegistered = false
        for action in CCXHotKeyAction.allCases {
            guard let combo = hotKeyBindings[action] else { continue }
            let ok = hotKeyManager.register(action, combo: combo)
            if action == .snip {
                snipHotKeyRegistered = ok
            }
        }

        RecordingCoordinator.cleanupTemporaryRecordings()
        DispatchQueue.global(qos: .utility).async {
            Self.cleanupPasteboardRecordings()
            AppUpdateInstaller.cleanupStaleStagingDirectories()
        }

        activityArbiter.onStateChanged = { [weak self] in
            self?.updateManager.notifyActivityStateChanged()
        }
        updateManager.canTerminateNow = { [weak self] in
            self?.activityArbiter.canTerminateNow ?? false
        }
        updateManager.canInstallSilentlyNow = { [weak self] in
            self?.activityArbiter.canInstallSilentlyNow ?? false
        }
        updateManager.onBlockedByActiveSession = { [weak self] in
            guard let self else { return }
            if self.activityArbiter.isActive(.recordingSession) {
                self.toast.show(
                    CCXL10n.text("Finish Active Recording First", zh: "请先结束当前录屏"),
                    symbolName: "record.circle.fill"
                )
            } else if self.activityArbiter.isActive(.savePanel) {
                self.toast.show(
                    CCXL10n.text("Finish Save Dialog First", zh: "请先完成当前保存窗口"),
                    symbolName: "square.and.arrow.down"
                )
            } else {
                self.toast.show(
                    CCXL10n.text("Saving File — Please Wait", zh: "正在保存文件，请稍候"),
                    symbolName: "square.and.arrow.down"
                )
            }
        }
        updateManager.onUserFacingError = { [weak self] message in
            self?.toast.show(message, symbolName: "exclamationmark.triangle")
        }
        updateManager.terminateHandler = {
            NSApp.terminate(nil)
        }

        let menuBarController = MenuBarController(
            pinManager: pinManager,
            clipboardStore: clipboardStore,
            updateManager: updateManager
        )
        menuBarController.delegate = self
        menuBarController.onPanelVisibilityChanged = { [weak self] visible in
            self?.activityArbiter.setCondition(.menuBarPopover, active: visible)
            if visible {
                self?.clipboardStore.pruneExpiredHistoryIfNeeded()
            }
        }
        menuBarController.updateSnipHotKey(combo: currentSnipCombo, isRegistered: snipHotKeyRegistered)
        self.menuBarController = menuBarController
        clipboardStore.onHistoryChanged = { [weak self] in
            guard let self else { return }
            self.menuBarController?.handleHistoryChanged()
            self.settingsController?.updateHasClearableHistory(!self.clipboardStore.history.isEmpty || self.clipboardStore.hasPasteboardContent)
            self.settingsController?.refreshResourceUsage(scheduleFollowUp: true)
        }

        recordingCoordinator.onStatusChanged = { [weak self] status in
            self?.menuBarController?.updateRecordingStatus(status)
        }
        recordingCoordinator.onNotice = { [weak self] message, symbol in
            self?.toast.show(message, symbolName: symbol)
        }

        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retrySnipHotKeySilentlyIfNeeded()
            }
        }

        if !snipHotKeyRegistered {
            toast.show(
                CCXL10n.text(
                    "\(currentSnipCombo.displayString) In Use by Another App",
                    zh: "\(currentSnipCombo.displayString) 已被其他应用占用"
                ),
                symbolName: "exclamationmark.triangle"
            )
        }

        let returnedFromPermissionRelaunch = PermissionStatusModel.consumePendingScreenRecordingRelaunch()
        if !PermissionManager.currentStatus().screenRecording {
            if returnedFromPermissionRelaunch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let liveGranted = await PermissionManager.verifyScreenRecordingLive()
                    if liveGranted {
                        self.menuBarController?.refresh()
                        if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
                            self.showOnboarding(startingAt: .ready, anchor: .centeredOnActiveScreen)
                        }
                    } else {
                        self.showOnboarding(
                            startingAt: .permissions,
                            anchor: .centeredOnActiveScreen,
                            detectedStaleScreenRecording: true
                        )
                    }
                }
            } else {
                showOnboarding(startingAt: .welcome, anchor: .centeredOnActiveScreen)
            }
        } else if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            showOnboarding(startingAt: .ready, anchor: .centeredOnActiveScreen)
        }

        scheduledUpdateCheckTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            while !Task.isCancelled {
                guard let self else { return }
                self.updateManager.checkForUpdatesInBackgroundIfDue()
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recordingCoordinator.phase == .finalizing {
            isRelaunching = false
            updateManager.notifyTerminationCancelled()
            toast.show(
                CCXL10n.text("Finishing Recording… Try Again Soon", zh: "正在生成录屏，请稍后再试"),
                symbolName: "hourglass"
            )
            return .terminateCancel
        }
        if recordingCoordinator.isRecordingOrPaused {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = CCXL10n.text("Recording in Progress", zh: "正在录屏")
            alert.informativeText = CCXL10n.text(
                "Quitting CCX now will discard the active recording.",
                zh: "现在退出 CCX 将丢弃当前正在录制的内容。"
            )
            alert.addButton(withTitle: CCXL10n.text("Keep Recording", zh: "继续录制"))
            alert.addButton(withTitle: CCXL10n.text("Discard & Quit", zh: "丢弃并退出"))
            if alert.runModal() != .alertSecondButtonReturn {
                isRelaunching = false
                updateManager.notifyTerminationCancelled()
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingLaunchTask?.cancel()
        pendingLaunchTask = nil
        scheduledUpdateCheckTask?.cancel()
        scheduledUpdateCheckTask = nil
        ocrTask?.cancel()
        ocrTask = nil
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        if let activeRecordingSave {
            try? FileManager.default.removeItem(at: activeRecordingSave.fileURL)
            self.activeRecordingSave = nil
        }
        for pending in pendingRecordingSaves {
            try? FileManager.default.removeItem(at: pending.fileURL)
        }
        pendingRecordingSaves.removeAll()
        syncPendingRecordingSaveCondition()
        snipCoordinator.cancelActiveSnip()
        recordingCoordinator.cancelActiveSession()
        hotKeyManager.unregisterAll()
        clipboardStore.handleApplicationWillTerminate()
        if isRelaunching {
            if !updateManager.applyPreparedUpdateOnQuitIfReady(relaunch: true) {
                _ = AppRelauncher.spawnRelaunchHelper()
            }
        } else {
            _ = updateManager.applyPreparedUpdateOnQuitIfReady()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !snipCoordinator.isSessionActive, !recordingCoordinator.isSessionActive else {
            return false
        }
        if !PermissionManager.currentStatus().screenRecording {
            let step: OnboardingStep = UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey)
                ? .permissions
                : .welcome
            let anchor: OnboardingAnchor = menuBarController?.popoverAnchorScreenFrame.map { .belowMenuBar($0) }
                ?? .centeredOnActiveScreen
            showOnboarding(startingAt: step, anchor: anchor)
            return false
        }
        if menuBarController?.openPanelIfStatusButtonVisible() != true {
            showSettings(anchoredTo: nil)
        }
        return false
    }

    // MARK: - Commands

    private func perform(_ action: CCXHotKeyAction) {
        switch action {
        case .snip:
            startSnip()
        case .quickOCR:
            startQuickOCR()
        case .pinClipboard:
            pinFromClipboard()
        case .record:
            if recordingCoordinator.isRecordingOrPaused {
                recordingCoordinator.stopActiveRecording()
            } else if case .countdown = recordingCoordinator.phase {
                recordingCoordinator.cancelActiveSession()
            } else {
                startRecordSelection()
            }
        case .togglePins:
            toggleAllPins()
        case .unlockClickThrough:
            unlockClickThroughPins()
        }
    }

    private func retrySnipHotKeySilentlyIfNeeded() {
        guard !isRecordingShortcut else { return }
        var changed = false
        for (action, combo) in hotKeyBindings where !hotKeyManager.isRegistered(action) {
            if hotKeyManager.register(action, combo: combo) {
                changed = true
            }
        }
        if changed {
            syncHotKeyState()
        }
    }

    private func retryHotKeyRegistration(for action: CCXHotKeyAction) -> Bool {
        guard let combo = hotKeyBindings[action] else { return false }
        let registered = hotKeyManager.register(action, combo: combo)
        syncHotKeyState()
        if registered {
            toast.show(
                CCXL10n.text(
                    "\(combo.displayString) Restored",
                    zh: "已恢复快捷键 \(combo.displayString)"
                ),
                symbolName: "checkmark.circle.fill"
            )
        } else {
            toast.show(
                CCXL10n.text(
                    "\(combo.displayString) Still In Use",
                    zh: "\(combo.displayString) 仍被其他应用占用"
                ),
                symbolName: "exclamationmark.triangle"
            )
        }
        return registered
    }

    private func beginShortcutRecording() {
        isRecordingShortcut = true
        hotKeyManager.unregisterAll()
    }

    private func endShortcutRecording() {
        isRecordingShortcut = false
        ensureCurrentHotKeysRegistered()
    }

    private func ensureCurrentHotKeysRegistered() {
        for (action, combo) in hotKeyBindings {
            if hotKeyManager.isRegistered(action), hotKeyManager.currentCombo(for: action) == combo {
                continue
            }
            _ = hotKeyManager.register(action, combo: combo)
        }
        syncHotKeyState()
    }

    private func changeHotKey(to candidate: HotKeyCombo?, for action: CCXHotKeyAction) -> HotKeyConflict? {
        guard let candidate else {
            guard action != .snip else { return nil }
            hotKeyManager.unregister(action)
            hotKeyBindings.removeValue(forKey: action)
            HotKeyPreferences.saveBinding(nil, for: action)
            if !isRecordingShortcut {
                syncHotKeyState()
            }
            return nil
        }

        let normalized = candidate.normalized
        // Check against saved bindings directly because active hotkeys are temporarily unregistered during recording.
        if let conflictingAction = hotKeyBindings.first(where: { $0.key != action && $0.value == normalized })?.key {
            return .internalConflict(normalized, action: conflictingAction)
        }

        switch hotKeyManager.registerChecked(action, combo: normalized) {
        case .registered(let combo):
            hotKeyBindings[action] = combo
            HotKeyPreferences.saveBinding(combo, for: action)
            if !isRecordingShortcut {
                syncHotKeyState()
            }
            toast.show(
                CCXL10n.text("Shortcut Set to \(combo.displayString)", zh: "快捷键已设为 \(combo.displayString)"),
                symbolName: "keyboard"
            )
            return nil
        case .conflict(let conflict):
            return conflict
        }
    }

    private func resetSnipHotKey() -> HotKeyConflict? {
        if let conflictingAction = hotKeyBindings.first(where: { $0.key != .snip && $0.value == .defaultSnip })?.key {
            return .internalConflict(.defaultSnip, action: conflictingAction)
        }
        switch hotKeyManager.registerChecked(.snip, combo: .defaultSnip) {
        case .registered(let combo):
            hotKeyBindings[.snip] = combo
            HotKeyPreferences.saveBinding(combo, for: .snip)
            syncHotKeyState()
            toast.show(
                CCXL10n.text(
                    "Shortcut Reset to \(HotKeyCombo.defaultSnip.displayString)",
                    zh: "快捷键已重置为 \(HotKeyCombo.defaultSnip.displayString)"
                ),
                symbolName: "arrow.counterclockwise"
            )
            return nil
        case .conflict(let conflict):
            return conflict
        }
    }

    private func syncHotKeyState() {
        let snipRegistered = hotKeyManager.isRegistered(.snip)
        let optionalBindings = currentOptionalBindings()
        let unregisteredOptional = currentUnregisteredOptionalActions()
        menuBarController?.updateSnipHotKey(combo: currentSnipCombo, isRegistered: snipRegistered)
        settingsController?.updateAllHotKeys(
            snipCombo: currentSnipCombo,
            isSnipRegistered: snipRegistered,
            optionalBindings: optionalBindings,
            unregisteredOptionalActions: unregisteredOptional
        )
        onboardingController?.updateSnipCombo(currentSnipCombo)
    }

    private func currentOptionalBindings() -> [CCXHotKeyAction: HotKeyCombo] {
        var result: [CCXHotKeyAction: HotKeyCombo] = [:]
        for action in CCXHotKeyAction.optionalActions {
            if let combo = hotKeyBindings[action] {
                result[action] = combo
            }
        }
        return result
    }

    private func currentUnregisteredOptionalActions() -> Set<CCXHotKeyAction> {
        var result: Set<CCXHotKeyAction> = []
        for action in CCXHotKeyAction.optionalActions {
            if hotKeyBindings[action] != nil, !hotKeyManager.isRegistered(action) {
                result.insert(action)
            }
        }
        return result
    }

    private func scheduleDelayedLaunch(milliseconds: Int, action: @escaping @MainActor () -> Void) {
        pendingLaunchTask?.cancel()
        pendingLaunchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled, let self else { return }
            self.pendingLaunchTask = nil
            action()
        }
    }

    private func prepareForCaptureSession() -> Bool {
        pendingLaunchTask?.cancel()
        pendingLaunchTask = nil

        if isPresentingSavePanel {
            NSApp.activate()
            activeSavePanel?.makeKeyAndOrderFront(nil)
            return false
        }
        if snipCoordinator.isSessionActive {
            return false
        }
        if recordingCoordinator.isSessionActive {
            toast.show(
                CCXL10n.text("Finish Active Recording First", zh: "请先结束当前录屏"),
                symbolName: "record.circle.fill"
            )
            return false
        }

        toast.hide()
        pinManager.closeAllToolbars(commit: true)
        return true
    }

    private func startSnip() {
        guard prepareForCaptureSession() else { return }
        let snipToken = activityArbiter.begin(.snipSession)
        snipCoordinator.startSnip(mode: .snip) { [weak self] outcome in
            defer { snipToken.end() }
            self?.handle(outcome)
        }
    }

    private func startQuickOCR() {
        guard prepareForCaptureSession() else { return }
        let snipToken = activityArbiter.begin(.snipSession)
        snipCoordinator.startSnip(mode: .ocr) { [weak self] outcome in
            defer { snipToken.end() }
            self?.handle(outcome)
        }
    }

    private func startRecordSelection() {
        guard prepareForCaptureSession() else { return }
        let snipToken = activityArbiter.begin(.snipSession)
        snipCoordinator.startSnip(mode: .record) { [weak self] outcome in
            defer { snipToken.end() }
            self?.handle(outcome)
        }
    }

    private func pinFromClipboard() {
        switch pinManager.pinNextAvailable() {
        case .pinned:
            break
        case .allAlreadyPinned:
            toast.show(CCXL10n.text("All Images Already Pinned", zh: "所有图片均已贴图"), symbolName: "checkmark.circle")
        case .nothingAvailable:
            toast.show(CCXL10n.text("Nothing to Pin", zh: "剪贴板无可贴图内容"), symbolName: "exclamationmark.circle")
        }
        menuBarController?.refresh()
    }

    private func toggleAllPins() {
        guard pinManager.pinCount > 0 else {
            toast.show(CCXL10n.text("No Active Pins", zh: "当前无悬浮贴图"), symbolName: "pin.slash")
            return
        }
        pinManager.toggleVisibilityOfAllPins()
    }

    private func unlockClickThroughPins() {
        guard pinManager.hasClickThroughPins else { return }
        pinManager.disableClickThroughForAllPins()
        toast.show(CCXL10n.text("Click-Through Disabled", zh: "已解除鼠标穿透"), symbolName: "cursorarrow.click")
    }

    // MARK: - Snip outcomes

    private func handle(_ outcome: SnipOutcome) {
        switch outcome {
        case .pin(let result):
            let entry = record(result)
            let identity = entry?.pinIdentity ?? .image(ImageFingerprint(image: result.image))
            if !pinManager.pin(content: .image(result.image, scale: result.scale), at: result.screenRect, contentIdentity: identity) {
                toast.show(CCXL10n.text("Already Pinned", zh: "已贴图"), symbolName: "pin.fill")
            }
        case .copy(let result):
            clipboardStore.recordAndCopyImage(result.image, scale: result.scale, screenRect: result.screenRect)
            toast.show(CCXL10n.text("Copied to Clipboard", zh: "已拷贝到剪贴板"))
        case .save(let result):
            record(result)
            presentSavePanel(for: result.image)
        case .quickSave(let result):
            record(result)
            quickSavePNG(result.image)
        case .ocr(let result):
            record(result)
            recognizeAndCopyText(from: result.image)
        case .record(let req):
            let region = RecordingRegion(
                displayID: req.displayID,
                displayFrame: req.displayFrame,
                localRect: req.localRect,
                screenRect: req.screenRect,
                scale: req.scale
            )
            startRecordingSession(region: region)
        case .copiedColor(let sample, let format):
            let text = sample.formatted(as: format)
            clipboardStore.copyText(text)
            toast.show(CCXL10n.text("Copied \(text)", zh: "已拷贝 \(text)"), symbolName: "eyedropper")
        case .permissionDenied:
            menuBarController?.refresh()
            toast.show(CCXL10n.text("Screen Recording Needed", zh: "需要屏幕录制权限"), symbolName: "exclamationmark.triangle")
            showOnboarding(startingAt: .permissions)
        case .failed(let message):
            let notice = Self.userFriendlyNotice(message)
            toast.show(
                CCXL10n.text("Capture Failed: \(notice)", zh: "截屏失败：\(notice)"),
                symbolName: "exclamationmark.triangle"
            )
        case .cancelled:
            break
        }
        menuBarController?.refresh()
    }

    @discardableResult
    private func record(_ result: SnipResult) -> SnipHistoryEntry? {
        clipboardStore.recordSnip(image: result.image, scale: result.scale, screenRect: result.screenRect)
    }

    private func recognizeAndCopyText(from image: CGImage) {
        ocrTask?.cancel()
        let taskID = UUID()
        ocrTaskID = taskID
        let ocrToken = activityArbiter.begin(.ocrTask)
        ocrTask = Task { @MainActor [weak self] in
            let progressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.toast.show(CCXL10n.text("Recognizing Text…", zh: "正在识别文字…"), symbolName: "text.viewfinder")
            }
            defer {
                progressTask.cancel()
                if let self, self.ocrTaskID == taskID {
                    self.ocrTask = nil
                }
                ocrToken.end()
            }
            guard let self else { return }

            do {
                let result = try await TextRecognizer.recognize(in: image)
                guard !Task.isCancelled else { return }
                progressTask.cancel()
                if result.text.isEmpty {
                    self.toast.show(CCXL10n.text("No Text Found", zh: "未识别到文字"), symbolName: "exclamationmark.circle")
                } else {
                    self.clipboardStore.copyText(result.text)
                    switch result.kind {
                    case .qrCode:
                        self.toast.show(CCXL10n.text("QR Copied", zh: "已拷贝二维码内容"), symbolName: "qrcode.viewfinder")
                    case .text:
                        self.toast.show(CCXL10n.text("Copied Text (OCR)", zh: "已拷贝识别文字 (OCR)"), symbolName: "text.viewfinder")
                    }
                    self.menuBarController?.refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                progressTask.cancel()
                self.toast.show(CCXL10n.text("OCR Failed", zh: "文字识别失败"), symbolName: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - Saving

    private func presentSavePanel(for image: CGImage) {
        if isPresentingSavePanel {
            NSApp.activate()
            activeSavePanel?.makeKeyAndOrderFront(nil)
            toast.show(CCXL10n.text("Finish Save Dialog First", zh: "请先完成当前保存窗口"), symbolName: "exclamationmark.circle")
            return
        }

        let panel = NSSavePanel()
        panel.title = CCXL10n.text("Save Snip", zh: "保存截屏")
        panel.directoryURL = preferredSaveDirectoryURL()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.defaultPNGFileName(for: Date())
        panel.level = .modalPanel

        isPresentingSavePanel = true
        activeSavePanel = panel
        let panelToken = activityArbiter.begin(.savePanel)
        NSApp.activate()

        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else {
                    panelToken.end()
                    return
                }
                self.isPresentingSavePanel = false
                self.activeSavePanel = nil

                guard response == .OK, let url = panel.url else {
                    panelToken.end()
                    self.drainPendingRecordingSavesIfIdle()
                    return
                }
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.lastSaveDirectoryKey)

                let exportToken = self.activityArbiter.begin(.backgroundExport)
                panelToken.end()
                self.drainPendingRecordingSavesIfIdle()

                Task.detached(priority: .userInitiated) {
                    defer { exportToken.end() }
                    do {
                        try autoreleasepool {
                            guard let pngData = ClipboardStore.encodePNG(image, scale: 1) else {
                                throw ClipboardStoreError.encodingFailed
                            }
                            try ClipboardStore.writePNGDataAtomically(pngData, to: url)
                        }
                        await MainActor.run { [weak self] in
                            self?.toast.show(CCXL10n.text("Saved PNG", zh: "已保存 PNG"), symbolName: "square.and.arrow.down")
                        }
                    } catch {
                        let description = Self.userFriendlySaveError(error)
                        await MainActor.run {
                            NSApp.activate()
                            let alert = NSAlert()
                            alert.alertStyle = .warning
                            alert.messageText = CCXL10n.text("Could Not Save PNG", zh: "无法保存 PNG")
                            alert.informativeText = description
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }

    private func preferredSaveDirectoryURL() -> URL {
        if let savedPath = UserDefaults.standard.string(forKey: Self.lastSaveDirectoryKey),
           AtomicFileWriter.isWritableRealDirectory(atPath: savedPath) {
            return URL(fileURLWithPath: AtomicFileWriter.normalizedPath(savedPath), isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    private func defaultRecordingsDirectoryURL() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CCX", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/CCX", isDirectory: true)
    }

    private func preferredRecordingsDirectoryURL(createIfNeeded: Bool = false) -> URL {
        if let savedPath = UserDefaults.standard.string(forKey: Self.recordingsDirectoryKey) {
            let normalized = AtomicFileWriter.normalizedPath(savedPath)
            if AtomicFileWriter.isWritableRealDirectory(atPath: normalized) {
                return URL(fileURLWithPath: normalized, isDirectory: true)
            }
        }

        let defaultURL = defaultRecordingsDirectoryURL()
        if createIfNeeded {
            let normalized = AtomicFileWriter.normalizedPath(defaultURL.path)
            var st = stat()
            if Darwin.lstat(normalized, &st) != 0, errno == ENOENT {
                try? FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
            }
        }
        return defaultURL
    }

    private func displayPathForDirectory(_ url: URL) -> String {
        let path = AtomicFileWriter.normalizedPath(url.path)
        let home = AtomicFileWriter.normalizedPath(NSHomeDirectory())
        if path == home {
            return "~"
        }
        let homePrefix = home + "/"
        if path.hasPrefix(homePrefix) {
            return "~/" + path.dropFirst(homePrefix.count)
        }
        return path
    }

    private var isUsingCustomRecordingsFolder: Bool {
        guard let savedPath = UserDefaults.standard.string(forKey: Self.recordingsDirectoryKey) else {
            return false
        }
        let normalizedSaved = AtomicFileWriter.normalizedPath(savedPath)
        guard AtomicFileWriter.isWritableRealDirectory(atPath: normalizedSaved) else {
            return false
        }
        let defaultPath = AtomicFileWriter.normalizedPath(defaultRecordingsDirectoryURL().path)
        return normalizedSaved != defaultPath
    }

    private func openRecordingsFolder() {
        let directory = preferredRecordingsDirectoryURL(createIfNeeded: true)
        settingsController?.updateRecordingsFolder(
            displayPathForDirectory(directory),
            isCustom: isUsingCustomRecordingsFolder
        )
        guard AtomicFileWriter.isRealDirectory(atPath: directory.path),
              NSWorkspace.shared.open(directory)
        else {
            toast.show(CCXL10n.text("Couldn't Open Recordings Folder", zh: "无法打开录屏目录"), symbolName: "exclamationmark.triangle")
            return
        }
    }

    private func resetRecordingsFolder() {
        UserDefaults.standard.removeObject(forKey: Self.recordingsDirectoryKey)
        let defaultDirectory = defaultRecordingsDirectoryURL()
        settingsController?.updateRecordingsFolder(
            displayPathForDirectory(defaultDirectory),
            isCustom: false
        )
        toast.show(
            CCXL10n.text("Recordings Folder Reset", zh: "已恢复默认录屏目录"),
            symbolName: "arrow.counterclockwise"
        )
    }

    private func copyRecordingsFolderPath() {
        let path = displayPathForDirectory(preferredRecordingsDirectoryURL(createIfNeeded: false))
        clipboardStore.copyText(path)
        toast.show(CCXL10n.text("Copied Folder Path", zh: "已拷贝目录路径"), symbolName: "doc.on.doc")
        menuBarController?.refresh()
    }

    private func copyVersionInfo(_ version: String) {
        clipboardStore.copyText(version)
        toast.show(CCXL10n.text("Copied \(version)", zh: "已拷贝 \(version)"), symbolName: "doc.on.doc")
        menuBarController?.refresh()
    }

    private func chooseRecordingsFolder() {
        if isPresentingSavePanel {
            NSApp.activate()
            activeSavePanel?.makeKeyAndOrderFront(nil)
            toast.show(CCXL10n.text("Finish Save Dialog First", zh: "请先完成当前保存窗口"), symbolName: "exclamationmark.circle")
            return
        }

        let panel = NSOpenPanel()
        panel.title = CCXL10n.text("Choose Recordings Folder", zh: "选择录屏目录")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = CCXL10n.text("Choose", zh: "选择")
        let currentDirectory = preferredRecordingsDirectoryURL(createIfNeeded: true)
        if AtomicFileWriter.isRealDirectory(atPath: currentDirectory.path) {
            panel.directoryURL = currentDirectory
        }
        panel.level = .modalPanel

        isPresentingSavePanel = true
        activeSavePanel = panel
        let panelToken = activityArbiter.begin(.savePanel)
        NSApp.activate()

        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else {
                    panelToken.end()
                    return
                }
                self.isPresentingSavePanel = false
                self.activeSavePanel = nil
                defer {
                    self.drainPendingRecordingSavesIfIdle()
                    panelToken.end()
                }

                guard response == .OK, let url = panel.url else { return }
                let normalizedPath = AtomicFileWriter.normalizedPath(url.path)
                guard AtomicFileWriter.isWritableRealDirectory(atPath: normalizedPath) else {
                    self.toast.show(
                        CCXL10n.text("Selected Folder Cannot Be Used", zh: "无法使用所选文件夹"),
                        symbolName: "exclamationmark.triangle"
                    )
                    return
                }

                let validatedURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
                let defaultPath = AtomicFileWriter.normalizedPath(self.defaultRecordingsDirectoryURL().path)
                if normalizedPath == defaultPath {
                    UserDefaults.standard.removeObject(forKey: Self.recordingsDirectoryKey)
                } else {
                    UserDefaults.standard.set(normalizedPath, forKey: Self.recordingsDirectoryKey)
                }
                self.settingsController?.updateRecordingsFolder(
                    self.displayPathForDirectory(validatedURL),
                    isCustom: normalizedPath != defaultPath
                )
                self.toast.show(CCXL10n.text("Recordings Folder Updated", zh: "已更新录屏目录"), symbolName: "folder.fill")
            }
        }
    }

    private func quickSavePNG(_ image: CGImage) {
        let directory = preferredSaveDirectoryURL()
        let stem = Self.defaultFileStem(for: Date())
        let exportToken = activityArbiter.begin(.backgroundExport)

        Task.detached(priority: .userInitiated) {
            defer { exportToken.end() }
            do {
                try autoreleasepool {
                    guard AtomicFileWriter.isWritableRealDirectory(atPath: directory.path) else {
                        throw ClipboardStoreError.writeFailed
                    }
                    guard let pngData = ClipboardStore.encodePNG(image, scale: 1) else {
                        throw ClipboardStoreError.encodingFailed
                    }
                    _ = try ClipboardStore.writePNGDataExclusively(
                        pngData,
                        in: directory,
                        stem: stem,
                        maxSuffixAttempts: Self.maxQuickSaveSuffixAttempts
                    )
                }
                let folderName = directory.lastPathComponent
                await MainActor.run { [weak self] in
                    self?.toast.show(
                        CCXL10n.text("Saved to \(folderName)", zh: "已保存到 \(folderName)"),
                        symbolName: "square.and.arrow.down"
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.toast.show(
                        CCXL10n.text("Quick Save Failed — Choose Folder", zh: "快速保存失败，请选择文件夹"),
                        symbolName: "exclamationmark.triangle"
                    )
                    self.presentSavePanel(for: image)
                }
            }
        }
    }

    /// Returns `CCX-yyyyMMdd-HHmmss.png` for the given date.
    static func defaultPNGFileName(for date: Date) -> String {
        "\(defaultFileStem(for: date)).png"
    }

    static func defaultRecordingFileName(for date: Date, format: RecordingFormat) -> String {
        "\(defaultFileStem(for: date)).\(format.fileExtension)"
    }

    private static func defaultFileStem(for date: Date) -> String {
        "CCX-\(fileTimestampFormatter.string(from: date))"
    }

    // MARK: - Recording Outcomes

    private func startRecordingSession(region: RecordingRegion) {
        let recordingToken = activityArbiter.begin(.recordingSession)
        recordingCoordinator.startSession(region: region) { [weak self] outcome in
            defer { recordingToken.end() }
            self?.handleRecordingOutcome(outcome)
        }
    }

    private func handleRecordingOutcome(_ outcome: RecordingOutcome) {
        switch outcome {
        case .copy(let result):
            copyRecordingToPasteboard(result)
        case .save(let result):
            presentSavePanel(for: result)
        case .quickSave(let result):
            quickSaveRecording(result, revealInFinder: false)
        case .reveal(let result):
            quickSaveRecording(result, revealInFinder: true)
        case .permissionDenied:
            menuBarController?.refresh()
            toast.show(CCXL10n.text("Screen Recording Needed", zh: "需要屏幕录制权限"), symbolName: "exclamationmark.triangle")
            showOnboarding(startingAt: .permissions)
        case .failed(let message):
            let notice = Self.userFriendlyNotice(message)
            toast.show(
                CCXL10n.text("Recording Failed: \(notice)", zh: "录屏失败：\(notice)"),
                symbolName: "exclamationmark.triangle"
            )
        case .cancelled:
            break
        }
        menuBarController?.refresh()
    }

    private func copyRecordingToPasteboard(_ result: RecordingResult) {
        let stem = Self.defaultFileStem(for: Date())
        let ext = result.format.fileExtension
        let label = result.format.label
        let exportToken = activityArbiter.begin(.backgroundExport)

        Task.detached(priority: .userInitiated) {
            defer { exportToken.end() }
            do {
                let pasteDir = Self.pasteboardRecordingsDirectoryURL()
                guard AtomicFileWriter.ensurePrivateDirectory(at: pasteDir) else {
                    throw CocoaError(.fileWriteNoPermission)
                }

                let destURL = try AtomicFileWriter.moveFileExclusively(
                    from: result.fileURL,
                    in: pasteDir,
                    stem: stem,
                    fileExtension: ext,
                    maxSuffixAttempts: Self.maxQuickSaveSuffixAttempts
                )
                _ = Darwin.chmod(destURL.path, 0o600)
                AtomicFileWriter.prunePrivateEntries(in: pasteDir, keepingLatest: Self.maxRetainedPasteboardRecordings)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.clipboardStore.copyFileURL(destURL)
                    self.menuBarController?.refresh()
                    self.settingsController?.updateHasClearableHistory(true)
                    self.settingsController?.refreshResourceUsage(scheduleFollowUp: true)
                    self.toast.show(CCXL10n.text("Copied \(label)", zh: "已拷贝 \(label)"), symbolName: "doc.on.doc")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.toast.show(
                        CCXL10n.text("Copy Failed — Choose Save Location", zh: "拷贝失败，请选择保存位置"),
                        symbolName: "exclamationmark.triangle"
                    )
                    self.presentSavePanel(for: result)
                }
            }
        }
    }

    private func syncPendingRecordingSaveCondition() {
        activityArbiter.setCondition(.savePanel, active: !pendingRecordingSaves.isEmpty)
    }

    private func drainPendingRecordingSavesIfIdle() {
        guard !isPresentingSavePanel else { return }
        if !pendingRecordingSaves.isEmpty {
            let next = pendingRecordingSaves.removeFirst()
            syncPendingRecordingSaveCondition()
            presentSavePanel(for: next)
        } else {
            syncPendingRecordingSaveCondition()
        }
    }

    private func presentSavePanel(for result: RecordingResult) {
        if isPresentingSavePanel {
            pendingRecordingSaves.append(result)
            syncPendingRecordingSaveCondition()
            NSApp.activate()
            activeSavePanel?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSSavePanel()
        panel.title = CCXL10n.text("Save \(result.format.label)", zh: "保存 \(result.format.label)")
        let recordingsDirectory = preferredRecordingsDirectoryURL(createIfNeeded: true)
        if AtomicFileWriter.isRealDirectory(atPath: recordingsDirectory.path) {
            panel.directoryURL = recordingsDirectory
        }
        panel.allowedContentTypes = [result.format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.defaultRecordingFileName(for: Date(), format: result.format)
        panel.level = .modalPanel

        isPresentingSavePanel = true
        activeSavePanel = panel
        activeRecordingSave = result
        let panelToken = activityArbiter.begin(.savePanel)
        NSApp.activate()

        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else {
                    panelToken.end()
                    return
                }
                self.isPresentingSavePanel = false
                self.activeSavePanel = nil

                guard response == .OK, let url = panel.url else {
                    if self.activeRecordingSave?.fileURL == result.fileURL {
                        self.activeRecordingSave = nil
                    }
                    try? FileManager.default.removeItem(at: result.fileURL)
                    self.drainPendingRecordingSavesIfIdle()
                    panelToken.end()
                    return
                }

                let label = result.format.label
                let exportToken = self.activityArbiter.begin(.backgroundExport)
                panelToken.end()

                Task.detached(priority: .userInitiated) {
                    defer { exportToken.end() }
                    do {
                        try AtomicFileWriter.moveFileAtomically(from: result.fileURL, to: url)
                        await MainActor.run { [weak self] in
                            if self?.activeRecordingSave?.fileURL == result.fileURL {
                                self?.activeRecordingSave = nil
                            }
                            self?.toast.show(CCXL10n.text("Saved \(label)", zh: "已保存 \(label)"), symbolName: "square.and.arrow.down")
                            self?.drainPendingRecordingSavesIfIdle()
                        }
                    } catch {
                        let description = Self.userFriendlySaveError(error)
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            NSApp.activate()
                            let alert = NSAlert()
                            alert.alertStyle = .warning
                            alert.messageText = CCXL10n.text("Could Not Save \(label)", zh: "无法保存 \(label)")
                            alert.informativeText = CCXL10n.text(
                                "\(description)\n\nYour recording has been preserved so you can choose another location.",
                                zh: "\(description)\n\n已保留录屏文件，你可以选择其他保存位置。"
                            )
                            alert.addButton(withTitle: CCXL10n.text("Choose Another Location…", zh: "选择其他位置…"))
                            alert.addButton(withTitle: CCXL10n.text("Discard Recording", zh: "丢弃录屏"))
                            if alert.runModal() == .alertFirstButtonReturn {
                                self.presentSavePanel(for: result)
                            } else {
                                if self.activeRecordingSave?.fileURL == result.fileURL {
                                    self.activeRecordingSave = nil
                                }
                                try? FileManager.default.removeItem(at: result.fileURL)
                                self.drainPendingRecordingSavesIfIdle()
                            }
                        }
                    }
                }
            }
        }
    }

    private func quickSaveRecording(_ result: RecordingResult, revealInFinder: Bool) {
        let directory = preferredRecordingsDirectoryURL(createIfNeeded: true)
        let ext = result.format.fileExtension
        let stem = Self.defaultFileStem(for: Date())
        let label = result.format.label
        let folderName = directory.lastPathComponent
        let exportToken = activityArbiter.begin(.backgroundExport)

        Task.detached(priority: .userInitiated) {
            defer { exportToken.end() }
            do {
                guard AtomicFileWriter.isWritableRealDirectory(atPath: directory.path) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let targetURL = try AtomicFileWriter.moveFileExclusively(
                    from: result.fileURL,
                    in: directory,
                    stem: stem,
                    fileExtension: ext,
                    maxSuffixAttempts: Self.maxQuickSaveSuffixAttempts
                )
                await MainActor.run { [weak self] in
                    self?.toast.show(
                        CCXL10n.text("Saved \(label) to \(folderName)", zh: "已保存 \(label) 到 \(folderName)"),
                        symbolName: "square.and.arrow.down"
                    )
                    if revealInFinder {
                        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.toast.show(
                        CCXL10n.text("Quick Save Failed — Choose Folder", zh: "快速保存失败，请选择文件夹"),
                        symbolName: "exclamationmark.triangle"
                    )
                    self.presentSavePanel(for: result)
                }
            }
        }
    }

    private nonisolated static func pasteboardRecordingsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CCXPasteboard", isDirectory: true)
    }

    private nonisolated static func clearPasteboardRecordings() {
        AtomicFileWriter.clearPrivateEntries(in: pasteboardRecordingsDirectoryURL())
    }

    private nonisolated static func cleanupPasteboardRecordings(olderThan maxAge: TimeInterval = 86_400) {
        let dir = pasteboardRecordingsDirectoryURL()
        AtomicFileWriter.cleanupPrivateEntries(in: dir, olderThan: maxAge)
        AtomicFileWriter.prunePrivateEntries(in: dir, keepingLatest: maxRetainedPasteboardRecordings)
    }

    private nonisolated static func userFriendlySaveError(_ error: Error) -> String {
        if let storeError = error as? ClipboardStoreError, let message = storeError.errorDescription {
            return message
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.fileWriteNoPermission.rawValue:
                return CCXL10n.text(
                    "CCX does not have permission to write to the selected folder.",
                    zh: "CCX 没有权限写入所选文件夹。"
                )
            case CocoaError.fileWriteOutOfSpace.rawValue:
                return CCXL10n.text(
                    "There is not enough free disk space in the selected folder.",
                    zh: "所选文件夹可用磁盘空间不足。"
                )
            case CocoaError.fileWriteVolumeReadOnly.rawValue:
                return CCXL10n.text(
                    "The selected disk or folder is read-only.",
                    zh: "所选磁盘或文件夹为只读状态。"
                )
            case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue:
                return CCXL10n.text(
                    "The temporary file could not be found.",
                    zh: "找不到临时文件。"
                )
            default:
                break
            }
        }
        return userFriendlyNotice(error.localizedDescription)
    }

    private nonisolated static func userFriendlyNotice(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CCXL10n.text("An unexpected error occurred.", zh: "发生意外错误。")
        }
        if trimmed.contains("Error Domain=")
            || trimmed.contains("NSCocoaErrorDomain")
            || trimmed.contains("NSPOSIXErrorDomain")
            || trimmed.contains("NSOSStatusErrorDomain")
            || trimmed.contains("NSURLErrorDomain")
            || trimmed.contains("SCStreamErrorDomain")
        {
            return CCXL10n.text("The operation could not be completed. Please try again.", zh: "操作未能完成，请重试。")
        }
        return trimmed
    }

    // MARK: - Windows

    private func relaunchApplication(forPermissionRetry: Bool = false) {
        guard AppRelauncher.validatedBundlePath() != nil else {
            NSSound.beep()
            return
        }
        if forPermissionRetry {
            PermissionStatusModel.markPendingScreenRecordingRelaunch()
        }
        isRelaunching = true
        NSApp.terminate(nil)
    }

    private func handlePermissionResetResult(_ succeeded: Bool) {
        if succeeded {
            toast.show(
                CCXL10n.text(
                    "Old Permission Cleared — Enable CCX & Relaunch",
                    zh: "已重置旧权限，请重新勾选 CCX 并重启"
                ),
                symbolName: "arrow.counterclockwise.circle.fill"
            )
        } else {
            toast.show(
                CCXL10n.text(
                    "Remove CCX (−) in Settings, Then Re-add",
                    zh: "请在系统设置点 − 移除 CCX 后重新添加"
                ),
                symbolName: "exclamationmark.triangle"
            )
        }
    }

    private func showOnboarding(
        startingAt step: OnboardingStep = .welcome,
        anchor: OnboardingAnchor = .centeredOnActiveScreen,
        detectedStaleScreenRecording: Bool = false
    ) {
        recordingCoordinator.cancelIfInReadyPhase()
        if onboardingController == nil {
            let controller = OnboardingWindowController(
                snipCombo: currentSnipCombo,
                onComplete: {
                    UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                },
                onTrySnip: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                    self?.scheduleDelayedLaunch(milliseconds: 220) {
                        self?.startSnip()
                    }
                },
                onRelaunch: { [weak self] in
                    self?.relaunchApplication(forPermissionRetry: true)
                },
                onPermissionReset: { [weak self] succeeded in
                    self?.handlePermissionResetResult(succeeded)
                }
            )
            controller.onWindowVisibilityChanged = { [weak self] visible in
                self?.activityArbiter.setCondition(.onboardingWindow, active: visible)
            }
            onboardingController = controller
        } else {
            onboardingController?.updateSnipCombo(currentSnipCombo)
        }
        onboardingController?.show(
            startingAt: step,
            anchor: anchor,
            detectedStaleScreenRecording: detectedStaleScreenRecording
        )
    }

    private func showSettings(anchoredTo anchorRect: NSRect? = nil) {
        recordingCoordinator.cancelIfInReadyPhase()
        let hasClearable = !clipboardStore.history.isEmpty || clipboardStore.hasPasteboardContent
        let recordingsFolderPath = displayPathForDirectory(preferredRecordingsDirectoryURL(createIfNeeded: false))
        let isCustomRecordingsFolder = self.isUsingCustomRecordingsFolder
        if settingsController == nil {
            let controller = SettingsWindowController(
                updateManager: updateManager,
                snipCombo: currentSnipCombo,
                isSnipHotKeyRegistered: hotKeyManager.isRegistered(.snip),
                optionalBindings: currentOptionalBindings(),
                unregisteredOptionalActions: currentUnregisteredOptionalActions(),
                hasClearableHistory: hasClearable,
                recordingsFolderPath: recordingsFolderPath,
                isCustomRecordingsFolder: isCustomRecordingsFolder,
                historyRetention: clipboardStore.retentionPolicy,
                concealClipboard: clipboardStore.concealFromClipboardManagers,
                resourceMetricsProvider: { [weak self] in
                    guard let self else { return .empty }
                    return SettingsResourceMetricsInput(
                        historyCount: self.clipboardStore.history.count,
                        maxHistoryCount: self.clipboardStore.maxHistoryCount,
                        activePinCount: self.pinManager.pinCount,
                        cacheDirectories: [
                            ClipboardStore.defaultHistoryDirectoryURL(),
                            Self.pasteboardRecordingsDirectoryURL(),
                        ]
                    )
                },
                onBeginShortcutRecording: { [weak self] in
                    self?.beginShortcutRecording()
                },
                onEndShortcutRecording: { [weak self] in
                    self?.endShortcutRecording()
                },
                onChangeHotKey: { [weak self] action, candidate in
                    self?.changeHotKey(to: candidate, for: action)
                },
                onResetSnipHotKey: { [weak self] in
                    self?.resetSnipHotKey()
                },
                onRetryHotKey: { [weak self] action in
                    self?.retryHotKeyRegistration(for: action) ?? false
                },
                onOpenRecordingsFolder: { [weak self] in
                    self?.openRecordingsFolder()
                },
                onChooseRecordingsFolder: { [weak self] in
                    self?.chooseRecordingsFolder()
                },
                onResetRecordingsFolder: { [weak self] in
                    self?.resetRecordingsFolder()
                },
                onCopyRecordingsFolderPath: { [weak self] in
                    self?.copyRecordingsFolderPath()
                },
                onCopyVersion: { [weak self] version in
                    self?.copyVersionInfo(version)
                },
                onOpenGuide: { [weak self] settingsFrame in
                    guard let self else { return }
                    let status = PermissionManager.currentStatus()
                    let allGranted = status.screenRecording && status.accessibility
                    let anchor: OnboardingAnchor = settingsFrame.map { .centeredOnWindow($0) }
                        ?? .centeredOnActiveScreen
                    self.showOnboarding(
                        startingAt: allGranted ? .welcome : .permissions,
                        anchor: anchor
                    )
                },
                onClearHistory: { [weak self] in
                    self?.menuBarRequestedClearHistory()
                    self?.toast.show(
                        CCXL10n.text("History & Clipboard Cleared", zh: "已清空记录与剪贴板"),
                        symbolName: "trash"
                    )
                },
                onChangeHistoryRetention: { [weak self] policy in
                    guard let self else { return }
                    self.clipboardStore.retentionPolicy = policy
                    self.settingsController?.updateHasClearableHistory(
                        !self.clipboardStore.history.isEmpty || self.clipboardStore.hasPasteboardContent
                    )
                    self.settingsController?.refreshResourceUsage(scheduleFollowUp: true)
                },
                onToggleConcealClipboard: { [weak self] concealed in
                    self?.clipboardStore.concealFromClipboardManagers = concealed
                },
                onRelaunch: { [weak self] in
                    self?.relaunchApplication(forPermissionRetry: true)
                },
                onPermissionReset: { [weak self] succeeded in
                    self?.handlePermissionResetResult(succeeded)
                }
            )
            controller.onWindowVisibilityChanged = { [weak self] visible in
                self?.activityArbiter.setCondition(.settingsWindow, active: visible)
            }
            settingsController = controller
        } else {
            settingsController?.updateAllHotKeys(
                snipCombo: currentSnipCombo,
                isSnipRegistered: hotKeyManager.isRegistered(.snip),
                optionalBindings: currentOptionalBindings(),
                unregisteredOptionalActions: currentUnregisteredOptionalActions()
            )
            settingsController?.updateHasClearableHistory(hasClearable)
            settingsController?.updateRecordingsFolder(recordingsFolderPath, isCustom: isCustomRecordingsFolder)
            settingsController?.updateHistoryPrivacy(
                retention: clipboardStore.retentionPolicy,
                concealClipboard: clipboardStore.concealFromClipboardManagers
            )
        }
        settingsController?.show(anchoredTo: anchorRect)
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarRequestedSnip() {
        scheduleDelayedLaunch(milliseconds: 120) { [weak self] in
            self?.startSnip()
        }
    }

    func menuBarRequestedRecord() {
        scheduleDelayedLaunch(milliseconds: 120) { [weak self] in
            self?.startRecordSelection()
        }
    }

    func menuBarRequestedOpenRecordingsFolder() {
        openRecordingsFolder()
    }

    func menuBarRequestedStopRecording() {
        recordingCoordinator.stopActiveRecording()
    }

    func menuBarRequestedTogglePauseRecording() {
        recordingCoordinator.togglePause()
    }

    func menuBarRequestedDiscardRecording() {
        recordingCoordinator.cancelActiveSession()
    }

    func menuBarRequestedPinFromClipboard() {
        pinFromClipboard()
    }

    func menuBarRequestedClearClipboard() {
        clipboardStore.clearClipboard()
        DispatchQueue.global(qos: .utility).async {
            Self.clearPasteboardRecordings()
        }
        menuBarController?.refresh()
        settingsController?.updateHasClearableHistory(!clipboardStore.history.isEmpty || clipboardStore.hasPasteboardContent)
        settingsController?.refreshResourceUsage(scheduleFollowUp: true)
    }

    func menuBarRequestedPinHistoryEntry(_ entry: SnipHistoryEntry) {
        guard clipboardStore.history.contains(where: { $0.id == entry.id }) else { return }
        if !pinManager.pin(content: .image(entry.image, scale: entry.scale), at: nil, contentIdentity: entry.pinIdentity) {
            toast.show(CCXL10n.text("Already Pinned", zh: "已贴图"), symbolName: "pin.fill")
        }
    }

    func menuBarRequestedCopyHistoryEntry(_ entry: SnipHistoryEntry) {
        guard clipboardStore.history.contains(where: { $0.id == entry.id }) else { return }
        clipboardStore.copyImage(entry.image, scale: entry.scale, historyEntryID: entry.id)
        menuBarController?.refresh()
        toast.show(CCXL10n.text("Copied to Clipboard", zh: "已拷贝到剪贴板"))
    }

    func menuBarRequestedSaveHistoryEntry(_ entry: SnipHistoryEntry) {
        guard clipboardStore.history.contains(where: { $0.id == entry.id }) else { return }
        presentSavePanel(for: entry.image)
    }

    func menuBarRequestedOCRHistoryEntry(_ entry: SnipHistoryEntry) {
        guard clipboardStore.history.contains(where: { $0.id == entry.id }) else { return }
        recognizeAndCopyText(from: entry.image)
    }

    func menuBarRequestedClearHistory() {
        clipboardStore.clearHistoryAndClipboard()
        pinManager.clearClosedPinHistory()
        snipCoordinator.clearLastSelections()
        let hasActiveRecordingOrExport = activityArbiter.isActive(.recordingSession)
            || activityArbiter.isActive(.savePanel)
            || activityArbiter.isActive(.backgroundExport)
        if !recordingCoordinator.isSessionActive && !hasActiveRecordingOrExport {
            RecordingCoordinator.cleanupTemporaryRecordings(olderThan: 0)
        }
        DispatchQueue.global(qos: .utility).async {
            Self.clearPasteboardRecordings()
        }
        menuBarController?.refresh()
        settingsController?.updateHasClearableHistory(false)
        settingsController?.refreshResourceUsage(scheduleFollowUp: true)
    }

    func menuBarRequestedToggleAllPins() {
        toggleAllPins()
    }

    func menuBarRequestedUnlockClickThrough() {
        unlockClickThroughPins()
    }

    func menuBarRequestedCloseAllPins() {
        pinManager.closeAllPins()
    }

    func menuBarRequestedReopenClosedPin() {
        _ = pinManager.reopenLastClosedPin()
    }

    func menuBarRequestedPermissionsGuide() {
        let status = PermissionManager.currentStatus()
        let allGranted = status.screenRecording && status.accessibility
        let anchor: OnboardingAnchor = menuBarController?.popoverAnchorScreenFrame.map { .belowMenuBar($0) }
            ?? .centeredOnActiveScreen
        showOnboarding(
            startingAt: allGranted ? .welcome : .permissions,
            anchor: anchor
        )
    }

    func menuBarRequestedSettings() {
        showSettings(anchoredTo: menuBarController?.popoverAnchorScreenFrame)
    }
}
