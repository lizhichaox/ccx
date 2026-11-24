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

    private var menuBarController: MenuBarController?
    private var onboardingController: OnboardingWindowController?
    private var settingsController: SettingsWindowController?
    private var currentSnipCombo: HotKeyCombo = HotKeyPreferences.loadCombo(for: .snip)
    private var isRecordingShortcut = false
    private var hadClickThroughPins = false
    private var pendingLaunchTask: Task<Void, Never>?
    private var scheduledUpdateCheckTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?
    private var isPresentingSavePanel = false
    private weak var activeSavePanel: NSSavePanel?
    private var pendingRecordingSaves: [RecordingResult] = []
    private var didBecomeActiveObserver: NSObjectProtocol?

    override init() {
        let clipboardStore = ClipboardStore(historyDirectoryURL: ClipboardStore.defaultHistoryDirectoryURL())
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
                self.toast.show("Click-Through On — Unlock in Menu Bar", symbolName: "cursorarrow.click")
            }
            self.hadClickThroughPins = hasClickThrough
            self.menuBarController?.refresh()
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
        let snipHotKeyRegistered = hotKeyManager.register(.snip, combo: currentSnipCombo)

        RecordingCoordinator.cleanupTemporaryRecordings()
        DispatchQueue.global(qos: .utility).async {
            Self.cleanupPasteboardRecordings()
            AppUpdateInstaller.cleanupStaleStagingDirectories()
        }

        updateManager.canTerminateNow = { [weak self] in
            guard let self else { return false }
            return !self.recordingCoordinator.isSessionActive && !self.isPresentingSavePanel
        }
        updateManager.onBlockedByActiveSession = { [weak self] in
            self?.toast.show("Finish Active Recording First", symbolName: "record.circle.fill")
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
        menuBarController.updateSnipHotKey(combo: currentSnipCombo, isRegistered: snipHotKeyRegistered)
        self.menuBarController = menuBarController
        clipboardStore.onHistoryChanged = { [weak self] in
            guard let self else { return }
            self.menuBarController?.handleHistoryChanged()
            self.settingsController?.updateHasClearableHistory(!self.clipboardStore.history.isEmpty || self.clipboardStore.hasPasteboardContent)
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
                "\(currentSnipCombo.displayString) In Use by Another App",
                symbolName: "exclamationmark.triangle"
            )
        }

        if !PermissionManager.currentStatus().screenRecording {
            showOnboarding(startingAt: .welcome, anchor: .centeredOnActiveScreen)
        } else if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            showOnboarding(startingAt: .ready, anchor: .centeredOnActiveScreen)
        }

        scheduledUpdateCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.scheduledUpdateCheckTask = nil
            self.updateManager.checkForUpdatesInBackgroundIfDue()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recordingCoordinator.phase == .finalizing {
            toast.show("Finishing Recording… Try Again Soon", symbolName: "hourglass")
            return .terminateCancel
        }
        if recordingCoordinator.isRecordingOrPaused {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Recording in Progress"
            alert.informativeText = "Quitting CCX now will discard the active recording."
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Discard & Quit")
            if alert.runModal() != .alertSecondButtonReturn {
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
        for pending in pendingRecordingSaves {
            try? FileManager.default.removeItem(at: pending.fileURL)
        }
        pendingRecordingSaves.removeAll()
        snipCoordinator.cancelActiveSnip()
        recordingCoordinator.cancelActiveSession()
        hotKeyManager.unregisterAll()
        clipboardStore.flushPendingPersistence()
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
        }
    }

    private func retrySnipHotKeySilentlyIfNeeded() {
        guard !isRecordingShortcut, !hotKeyManager.isRegistered(.snip) else { return }
        let registered = hotKeyManager.register(.snip, combo: currentSnipCombo)
        syncHotKeyState(registered: registered)
    }

    private func retrySnipHotKeyRegistration() -> Bool {
        let registered = hotKeyManager.register(.snip, combo: currentSnipCombo)
        syncHotKeyState(registered: registered)
        if registered {
            toast.show("\(currentSnipCombo.displayString) Restored", symbolName: "checkmark.circle.fill")
        } else {
            toast.show(
                "\(currentSnipCombo.displayString) Still In Use",
                symbolName: "exclamationmark.triangle"
            )
        }
        return registered
    }

    private func beginShortcutRecording() {
        isRecordingShortcut = true
        hotKeyManager.unregister(.snip)
    }

    private func endShortcutRecording() {
        isRecordingShortcut = false
        ensureCurrentSnipHotKeyRegistered()
    }

    private func ensureCurrentSnipHotKeyRegistered() {
        let registered: Bool
        if hotKeyManager.isRegistered(.snip),
           hotKeyManager.currentCombo(for: .snip) == currentSnipCombo {
            registered = true
        } else {
            registered = hotKeyManager.register(.snip, combo: currentSnipCombo)
        }
        syncHotKeyState(registered: registered)
    }

    private func changeSnipHotKey(to candidate: HotKeyCombo) -> HotKeyConflict? {
        switch hotKeyManager.registerChecked(.snip, combo: candidate) {
        case .registered(let combo):
            currentSnipCombo = combo
            HotKeyPreferences.saveCombo(combo, for: .snip)
            syncHotKeyState(registered: true)
            toast.show("Shortcut Set to \(combo.displayString)", symbolName: "keyboard")
            return nil
        case .conflict(let conflict):
            return conflict
        }
    }

    private func resetSnipHotKey() -> HotKeyConflict? {
        switch hotKeyManager.registerChecked(.snip, combo: .defaultSnip) {
        case .registered(let combo):
            currentSnipCombo = combo
            HotKeyPreferences.saveCombo(combo, for: .snip)
            syncHotKeyState(registered: true)
            toast.show("Shortcut Reset to \(HotKeyCombo.defaultSnip.displayString)", symbolName: "arrow.counterclockwise")
            return nil
        case .conflict(let conflict):
            return conflict
        }
    }

    private func syncHotKeyState(registered: Bool) {
        menuBarController?.updateSnipHotKey(combo: currentSnipCombo, isRegistered: registered)
        settingsController?.updateSnipHotKey(combo: currentSnipCombo, isRegistered: registered)
        onboardingController?.updateSnipCombo(currentSnipCombo)
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
            toast.show("Finish Active Recording First", symbolName: "record.circle.fill")
            return false
        }

        toast.hide()
        pinManager.closeAllToolbars(commit: true)
        return true
    }

    private func startSnip() {
        guard prepareForCaptureSession() else { return }
        snipCoordinator.startSnip(mode: .snip) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    private func startRecordSelection() {
        guard prepareForCaptureSession() else { return }
        snipCoordinator.startSnip(mode: .record) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    private func pinFromClipboard() {
        switch pinManager.pinNextAvailable() {
        case .pinned:
            break
        case .allAlreadyPinned:
            toast.show("All Images Already Pinned", symbolName: "checkmark.circle")
        case .nothingAvailable:
            toast.show("Nothing to Pin", symbolName: "exclamationmark.circle")
        }
        menuBarController?.refresh()
    }

    private func toggleAllPins() {
        guard pinManager.pinCount > 0 else {
            toast.show("No Active Pins", symbolName: "pin.slash")
            return
        }
        pinManager.toggleVisibilityOfAllPins()
    }

    private func unlockClickThroughPins() {
        guard pinManager.hasClickThroughPins else { return }
        pinManager.disableClickThroughForAllPins()
        toast.show("Click-Through Disabled", symbolName: "cursorarrow.click")
    }

    // MARK: - Snip outcomes

    private func handle(_ outcome: SnipOutcome) {
        switch outcome {
        case .pin(let result):
            let entry = record(result)
            let identity = entry?.pinIdentity ?? .image(ImageFingerprint(image: result.image))
            if !pinManager.pin(content: .image(result.image, scale: result.scale), at: result.screenRect, contentIdentity: identity) {
                toast.show("Already Pinned", symbolName: "pin.fill")
            }
        case .copy(let result):
            let entry = record(result)
            clipboardStore.copyImage(result.image, scale: result.scale, historyEntryID: entry?.id)
            toast.show("Copied to Clipboard")
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
            toast.show("Copied \(text)", symbolName: "eyedropper")
        case .permissionDenied:
            menuBarController?.refresh()
            toast.show("Screen Recording Needed", symbolName: "exclamationmark.triangle")
            showOnboarding(startingAt: .permissions)
        case .failed(let message):
            toast.show("Capture Failed: \(Self.userFriendlyNotice(message))", symbolName: "exclamationmark.triangle")
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
        ocrTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let progressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.toast.show("Recognizing Text…", symbolName: "text.viewfinder")
            }
            defer { progressTask.cancel() }

            do {
                let text = try await TextRecognizer.recognizeText(in: image)
                guard !Task.isCancelled else { return }
                progressTask.cancel()
                if text.isEmpty {
                    self.toast.show("No Text Found", symbolName: "exclamationmark.circle")
                } else {
                    self.clipboardStore.copyText(text)
                    self.toast.show("Copied Text (OCR)", symbolName: "text.viewfinder")
                    self.menuBarController?.refresh()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                progressTask.cancel()
                self.toast.show("OCR Failed", symbolName: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - Saving

    private func presentSavePanel(for image: CGImage) {
        if isPresentingSavePanel {
            NSApp.activate()
            activeSavePanel?.makeKeyAndOrderFront(nil)
            toast.show("Finish Save Dialog First", symbolName: "exclamationmark.circle")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Snip"
        panel.directoryURL = preferredSaveDirectoryURL()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.defaultPNGFileName(for: Date())
        panel.level = .modalPanel

        isPresentingSavePanel = true
        activeSavePanel = panel
        NSApp.activate()

        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPresentingSavePanel = false
                self.activeSavePanel = nil
                defer { self.drainPendingRecordingSavesIfIdle() }

                guard response == .OK, let url = panel.url else { return }
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.lastSaveDirectoryKey)

                Task.detached(priority: .userInitiated) {
                    do {
                        guard let pngData = ClipboardStore.encodePNG(image, scale: 1) else {
                            throw ClipboardStoreError.encodingFailed
                        }
                        try ClipboardStore.writePNGDataAtomically(pngData, to: url)
                        await MainActor.run { [weak self] in
                            self?.toast.show("Saved PNG", symbolName: "square.and.arrow.down")
                        }
                    } catch {
                        let description = Self.userFriendlySaveError(error)
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.alertStyle = .warning
                            alert.messageText = "Could Not Save PNG"
                            alert.informativeText = description
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }

    private func preferredSaveDirectoryURL() -> URL {
        let fm = FileManager.default
        if let savedPath = UserDefaults.standard.string(forKey: Self.lastSaveDirectoryKey) {
            var st = stat()
            if Darwin.lstat(savedPath, &st) == 0,
               (st.st_mode & S_IFMT) == S_IFDIR,
               fm.isWritableFile(atPath: savedPath) {
                return URL(fileURLWithPath: savedPath, isDirectory: true)
            }
        }
        return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }

    private nonisolated static func normalizedDirectoryPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private nonisolated static func isRealDirectory(atPath path: String) -> Bool {
        let normalized = normalizedDirectoryPath(path)
        guard !normalized.isEmpty else { return false }
        var st = stat()
        return Darwin.lstat(normalized, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private nonisolated static func isWritableRealDirectory(atPath path: String) -> Bool {
        let normalized = normalizedDirectoryPath(path)
        return isRealDirectory(atPath: normalized) && FileManager.default.isWritableFile(atPath: normalized)
    }

    private func defaultRecordingsDirectoryURL() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CCX", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/CCX", isDirectory: true)
    }

    private func preferredRecordingsDirectoryURL(createIfNeeded: Bool = false) -> URL {
        if let savedPath = UserDefaults.standard.string(forKey: Self.recordingsDirectoryKey) {
            let normalized = Self.normalizedDirectoryPath(savedPath)
            if Self.isWritableRealDirectory(atPath: normalized) {
                return URL(fileURLWithPath: normalized, isDirectory: true)
            }
        }

        let defaultURL = defaultRecordingsDirectoryURL()
        if createIfNeeded {
            let normalized = Self.normalizedDirectoryPath(defaultURL.path)
            var st = stat()
            if Darwin.lstat(normalized, &st) != 0, errno == ENOENT {
                try? FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
            }
            _ = Self.isRealDirectory(atPath: normalized)
        }
        return defaultURL
    }

    private func displayPathForDirectory(_ url: URL) -> String {
        let path = Self.normalizedDirectoryPath(url.path)
        let home = Self.normalizedDirectoryPath(NSHomeDirectory())
        if path == home {
            return "~"
        }
        let homePrefix = home + "/"
        if path.hasPrefix(homePrefix) {
            return "~/" + path.dropFirst(homePrefix.count)
        }
        return path
    }

    private func openRecordingsFolder() {
        let directory = preferredRecordingsDirectoryURL(createIfNeeded: true)
        settingsController?.updateRecordingsFolder(displayPathForDirectory(directory))
        guard Self.isRealDirectory(atPath: directory.path),
              NSWorkspace.shared.open(directory)
        else {
            toast.show("Couldn't Open Recordings Folder", symbolName: "exclamationmark.triangle")
            return
        }
    }

    private func chooseRecordingsFolder() {
        if isPresentingSavePanel {
            NSApp.activate()
            activeSavePanel?.makeKeyAndOrderFront(nil)
            toast.show("Finish Save Dialog First", symbolName: "exclamationmark.circle")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Recordings Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let currentDirectory = preferredRecordingsDirectoryURL(createIfNeeded: true)
        if Self.isRealDirectory(atPath: currentDirectory.path) {
            panel.directoryURL = currentDirectory
        }
        panel.level = .modalPanel

        isPresentingSavePanel = true
        activeSavePanel = panel
        NSApp.activate()

        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPresentingSavePanel = false
                self.activeSavePanel = nil
                defer { self.drainPendingRecordingSavesIfIdle() }

                guard response == .OK, let url = panel.url else { return }
                let normalizedPath = Self.normalizedDirectoryPath(url.path)
                guard Self.isWritableRealDirectory(atPath: normalizedPath) else {
                    self.toast.show("Selected Folder Cannot Be Used", symbolName: "exclamationmark.triangle")
                    return
                }

                let validatedURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
                UserDefaults.standard.set(normalizedPath, forKey: Self.recordingsDirectoryKey)
                self.settingsController?.updateRecordingsFolder(self.displayPathForDirectory(validatedURL))
                self.toast.show("Recordings Folder Updated", symbolName: "folder.fill")
            }
        }
    }

    private func quickSavePNG(_ image: CGImage) {
        let directory = preferredSaveDirectoryURL()
        let stem = Self.defaultFileStem(for: Date())

        Task.detached(priority: .userInitiated) {
            guard let targetURL = Self.nextUniqueURL(in: directory, stem: stem, fileExtension: "png") else {
                await MainActor.run { [weak self] in
                    self?.toast.show("Could Not Save PNG", symbolName: "exclamationmark.triangle")
                }
                return
            }
            do {
                guard let pngData = ClipboardStore.encodePNG(image, scale: 1) else {
                    throw ClipboardStoreError.encodingFailed
                }
                try ClipboardStore.writePNGDataAtomically(pngData, to: targetURL)
                let folderName = directory.lastPathComponent
                await MainActor.run { [weak self] in
                    self?.toast.show("Saved to \(folderName)", symbolName: "square.and.arrow.down")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.toast.show("Could Not Save PNG", symbolName: "exclamationmark.triangle")
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

    private nonisolated static func nextUniqueURL(
        in directory: URL,
        stem: String,
        fileExtension: String
    ) -> URL? {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(stem).\(fileExtension)")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            if suffix > maxQuickSaveSuffixAttempts {
                return directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(fileExtension)")
            }
            candidate = directory.appendingPathComponent("\(stem)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }

    // MARK: - Recording Outcomes

    private func startRecordingSession(region: RecordingRegion) {
        recordingCoordinator.startSession(region: region) { [weak self] outcome in
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
            toast.show("Screen Recording Needed", symbolName: "exclamationmark.triangle")
            showOnboarding(startingAt: .permissions)
        case .failed(let message):
            toast.show("Recording Failed: \(Self.userFriendlyNotice(message))", symbolName: "exclamationmark.triangle")
        case .cancelled:
            break
        }
        menuBarController?.refresh()
    }

    private func copyRecordingToPasteboard(_ result: RecordingResult) {
        let stem = Self.defaultFileStem(for: Date())
        let ext = result.format.fileExtension
        let label = result.format.label

        Task.detached(priority: .userInitiated) {
            do {
                let pasteDir = Self.pasteboardRecordingsDirectoryURL()
                guard Self.ensurePrivateDirectory(at: pasteDir),
                      let destURL = Self.nextUniqueURL(in: pasteDir, stem: stem, fileExtension: ext)
                else {
                    throw CocoaError(.fileWriteNoPermission)
                }

                try Self.moveRecordingAtomically(from: result.fileURL, to: destURL)
                _ = Darwin.chmod(destURL.path, 0o600)
                Self.prunePasteboardRecordings(keepingLatest: Self.maxRetainedPasteboardRecordings)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.clipboardStore.copyFileURL(destURL)
                    self.menuBarController?.refresh()
                    self.toast.show("Copied \(label)", symbolName: "doc.on.doc")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.toast.show("Copy Failed — Choose Save Location", symbolName: "exclamationmark.triangle")
                    self.presentSavePanel(for: result)
                }
            }
        }
    }

    private func drainPendingRecordingSavesIfIdle() {
        guard !isPresentingSavePanel, !pendingRecordingSaves.isEmpty else { return }
        let next = pendingRecordingSaves.removeFirst()
        presentSavePanel(for: next)
    }

    private func presentSavePanel(for result: RecordingResult) {
        if isPresentingSavePanel {
            pendingRecordingSaves.append(result)
            NSApp.activate()
            activeSavePanel?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save \(result.format.label)"
        let recordingsDirectory = preferredRecordingsDirectoryURL(createIfNeeded: true)
        if Self.isRealDirectory(atPath: recordingsDirectory.path) {
            panel.directoryURL = recordingsDirectory
        }
        panel.allowedContentTypes = [result.format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.defaultRecordingFileName(for: Date(), format: result.format)
        panel.level = .modalPanel

        isPresentingSavePanel = true
        activeSavePanel = panel
        NSApp.activate()

        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPresentingSavePanel = false
                self.activeSavePanel = nil

                guard response == .OK, let url = panel.url else {
                    try? FileManager.default.removeItem(at: result.fileURL)
                    self.drainPendingRecordingSavesIfIdle()
                    return
                }

                let label = result.format.label
                Task.detached(priority: .userInitiated) {
                    do {
                        try Self.moveRecordingAtomically(from: result.fileURL, to: url)
                        await MainActor.run { [weak self] in
                            self?.toast.show("Saved \(label)", symbolName: "square.and.arrow.down")
                            self?.drainPendingRecordingSavesIfIdle()
                        }
                    } catch {
                        let description = Self.userFriendlySaveError(error)
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            NSApp.activate()
                            let alert = NSAlert()
                            alert.alertStyle = .warning
                            alert.messageText = "Could Not Save \(label)"
                            alert.informativeText = "\(description)\n\nYour recording has been preserved so you can choose another location."
                            alert.addButton(withTitle: "Choose Another Location…")
                            alert.addButton(withTitle: "Discard Recording")
                            if alert.runModal() == .alertFirstButtonReturn {
                                self.presentSavePanel(for: result)
                            } else {
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

        Task.detached(priority: .userInitiated) {
            do {
                guard Self.isWritableRealDirectory(atPath: directory.path),
                      let targetURL = Self.nextUniqueURL(in: directory, stem: stem, fileExtension: ext)
                else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try Self.moveRecordingAtomically(from: result.fileURL, to: targetURL)
                await MainActor.run { [weak self] in
                    self?.toast.show("Saved \(label) to \(folderName)", symbolName: "square.and.arrow.down")
                    if revealInFinder {
                        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.toast.show("Quick Save Failed — Choose Folder", symbolName: "exclamationmark.triangle")
                    self.presentSavePanel(for: result)
                }
            }
        }
    }

    /// Moves `sourceURL` to `destinationURL` without ever deleting an existing file before replacement
    /// and without losing `sourceURL` if the copy/move fails (including across volumes).
    private nonisolated static func moveRecordingAtomically(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        let destinationExists = fm.fileExists(atPath: destinationURL.path)

        if destinationExists {
            do {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: sourceURL)
                return
            } catch {
                // Cross-volume replace falls back to staging a sibling temp file in the
                // destination directory and swapping atomically on the destination volume.
            }
        } else if Darwin.rename(sourceURL.path, destinationURL.path) == 0 {
            return
        }

        let siblingTemp = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".ccx-save-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: sourceURL, to: siblingTemp)
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: siblingTemp)
            } else {
                try fm.moveItem(at: siblingTemp, to: destinationURL)
            }
            try? fm.removeItem(at: sourceURL)
        } catch {
            try? fm.removeItem(at: siblingTemp)
            throw error
        }
    }

    private nonisolated static func pasteboardRecordingsDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CCXPasteboard", isDirectory: true)
    }

    private nonisolated static func ensurePrivateDirectory(at url: URL) -> Bool {
        var st = stat()
        if Darwin.lstat(url.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == Darwin.getuid() else { return false }
            return Darwin.chmod(url.path, 0o700) == 0
        }
        guard errno == ENOENT else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        guard Darwin.lstat(url.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == Darwin.getuid()
        else { return false }
        return Darwin.chmod(url.path, 0o700) == 0
    }

    private nonisolated static func isPrivateExistingDirectory(at url: URL) -> Bool {
        var st = stat()
        return Darwin.lstat(url.path, &st) == 0
            && (st.st_mode & S_IFMT) == S_IFDIR
            && st.st_uid == Darwin.getuid()
    }

    private nonisolated static func prunePasteboardRecordings(keepingLatest maxKeep: Int) {
        let dir = pasteboardRecordingsDirectoryURL()
        guard isPrivateExistingDirectory(at: dir) else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        ) else { return }

        let sorted = urls.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return lDate > rDate
        }
        for url in sorted.dropFirst(max(0, maxKeep)) {
            _ = Darwin.unlink(url.path)
        }
    }

    private nonisolated static func clearPasteboardRecordings() {
        let dir = pasteboardRecordingsDirectoryURL()
        guard isPrivateExistingDirectory(at: dir) else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in urls {
            _ = Darwin.unlink(url.path)
        }
    }

    private nonisolated static func cleanupPasteboardRecordings(olderThan maxAge: TimeInterval = 86_400) {
        let dir = pasteboardRecordingsDirectoryURL()
        guard isPrivateExistingDirectory(at: dir) else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in urls {
            if let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate, created < cutoff {
                _ = Darwin.unlink(url.path)
            }
        }
        prunePasteboardRecordings(keepingLatest: maxRetainedPasteboardRecordings)
    }

    private nonisolated static func userFriendlySaveError(_ error: Error) -> String {
        if let storeError = error as? ClipboardStoreError, let message = storeError.errorDescription {
            return message
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case CocoaError.fileWriteNoPermission.rawValue:
                return "CCX does not have permission to write to the selected folder."
            case CocoaError.fileWriteOutOfSpace.rawValue:
                return "There is not enough free disk space in the selected folder."
            case CocoaError.fileWriteVolumeReadOnly.rawValue:
                return "The selected disk or folder is read-only."
            case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue:
                return "The temporary file could not be found."
            default:
                break
            }
        }
        return userFriendlyNotice(error.localizedDescription)
    }

    private nonisolated static func userFriendlyNotice(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "An unexpected error occurred." }
        if trimmed.contains("Error Domain=") || trimmed.contains("NSCocoaErrorDomain") || trimmed.contains("NSPOSIXErrorDomain") {
            return "The operation could not be completed. Please try again."
        }
        return trimmed
    }

    // MARK: - Windows

    private func showOnboarding(
        startingAt step: OnboardingStep = .welcome,
        anchor: OnboardingAnchor = .centeredOnActiveScreen
    ) {
        recordingCoordinator.cancelIfInReadyPhase()
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                snipCombo: currentSnipCombo,
                onComplete: {
                    UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                },
                onTrySnip: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
                    self?.scheduleDelayedLaunch(milliseconds: 220) {
                        self?.startSnip()
                    }
                }
            )
        } else {
            onboardingController?.updateSnipCombo(currentSnipCombo)
        }
        onboardingController?.show(startingAt: step, anchor: anchor)
    }

    private func showSettings(anchoredTo anchorRect: NSRect? = nil) {
        recordingCoordinator.cancelIfInReadyPhase()
        let hasClearable = !clipboardStore.history.isEmpty || clipboardStore.hasPasteboardContent
        let recordingsFolderPath = displayPathForDirectory(preferredRecordingsDirectoryURL(createIfNeeded: false))
        if settingsController == nil {
            settingsController = SettingsWindowController(
                updateManager: updateManager,
                snipCombo: currentSnipCombo,
                isSnipHotKeyRegistered: hotKeyManager.isRegistered(.snip),
                hasClearableHistory: hasClearable,
                recordingsFolderPath: recordingsFolderPath,
                onBeginShortcutRecording: { [weak self] in
                    self?.beginShortcutRecording()
                },
                onEndShortcutRecording: { [weak self] in
                    self?.endShortcutRecording()
                },
                onChangeSnipHotKey: { [weak self] candidate in
                    self?.changeSnipHotKey(to: candidate)
                },
                onResetSnipHotKey: { [weak self] in
                    self?.resetSnipHotKey()
                },
                onRetryHotKey: { [weak self] in
                    self?.retrySnipHotKeyRegistration() ?? false
                },
                onOpenRecordingsFolder: { [weak self] in
                    self?.openRecordingsFolder()
                },
                onChooseRecordingsFolder: { [weak self] in
                    self?.chooseRecordingsFolder()
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
                    self?.toast.show("History & Clipboard Cleared", symbolName: "trash")
                }
            )
        } else {
            settingsController?.updateSnipHotKey(
                combo: currentSnipCombo,
                isRegistered: hotKeyManager.isRegistered(.snip)
            )
            settingsController?.updateHasClearableHistory(hasClearable)
            settingsController?.updateRecordingsFolder(recordingsFolderPath)
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
    }

    func menuBarRequestedPinHistoryEntry(_ entry: SnipHistoryEntry) {
        guard clipboardStore.history.contains(where: { $0.id == entry.id }) else { return }
        if !pinManager.pin(content: .image(entry.image, scale: entry.scale), at: nil, contentIdentity: entry.pinIdentity) {
            toast.show("Already Pinned", symbolName: "pin.fill")
        }
    }

    func menuBarRequestedClearHistory() {
        clipboardStore.clearHistoryAndClipboard()
        snipCoordinator.clearLastSelections()
        if !recordingCoordinator.isSessionActive {
            RecordingCoordinator.cleanupTemporaryRecordings(olderThan: 0)
        }
        DispatchQueue.global(qos: .utility).async {
            Self.clearPasteboardRecordings()
        }
        menuBarController?.refresh()
        settingsController?.updateHasClearableHistory(false)
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
