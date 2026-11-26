import AppKit
import AVFoundation
import CCXCore
import Foundation
import os
import OSLog
import ScreenCaptureKit

/// Orchestrates an interactive screen recording session from pre-start options through live
/// recording, pause/resume, finalizing, and final Copy/Save/Quick Save/Reveal/Discard disposition.
@MainActor
public final class RecordingCoordinator {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "RecordingCoordinator")
    private nonisolated static let activeStagedURLs = OSAllocatedUnfairLock<Set<URL>>(initialState: [])

    public var onStatusChanged: ((RecordingMenuBarStatus?) -> Void)?
    public var onNotice: ((String, String) -> Void)?

    public private(set) var isSessionActive = false
    public private(set) var phase: RecordingPhase = .ready
    public private(set) var settings: RecordingSettings

    public var isRecordingOrPaused: Bool {
        switch phase {
        case .recording, .paused: true
        case .ready, .finalizing, .completed: false
        }
    }

    private let settingsStore: RecordingSettingsStore
    private var sessionGeneration: UInt64 = 0
    private var region: RecordingRegion?
    private var effectiveSettings: RecordingSettings?
    private var completion: (@MainActor (RecordingOutcome) -> Void)?

    nonisolated(unsafe) private var borderPanel: RecordingBorderPanel?
    nonisolated(unsafe) private var controlPanel: RecordingControlPanel?
    nonisolated(unsafe) private var pendingEngine: ScreenRecordingEngine?
    nonisolated(unsafe) private var engine: ScreenRecordingEngine?
    nonisolated(unsafe) private var stagedFileURL: URL?

    private var isStartingRecording = false
    private var accumulatedElapsed: TimeInterval = 0
    private var activeSegmentStartTime: TimeInterval?
    private var lastEmittedElapsedSecond: Int?
    nonisolated(unsafe) private var elapsedTimer: Timer?

    nonisolated(unsafe) private var globalKeyMonitor: Any?
    nonisolated(unsafe) private var localKeyMonitor: Any?
    nonisolated(unsafe) private var screenParametersObserver: NSObjectProtocol?

    public init(settingsStore: RecordingSettingsStore = RecordingSettingsStore()) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    deinit {
        if let staged = stagedFileURL {
            let standardized = staged.standardizedFileURL
            Self.activeStagedURLs.withLock { _ = $0.remove(standardized) }
        }
        let monitors = [globalKeyMonitor, localKeyMonitor].compactMap { $0 }.map(UncheckedSendableBox.init)
        let observer = screenParametersObserver.map(UncheckedSendableBox.init)
        let timerBox = elapsedTimer.map(UncheckedSendableBox.init)
        let pendingEngineBox = pendingEngine.map(UncheckedSendableBox.init)
        let engineBox = engine.map(UncheckedSendableBox.init)
        let borderBox = borderPanel.map(UncheckedSendableBox.init)
        let controlBox = controlPanel.map(UncheckedSendableBox.init)

        let cleanupMain: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                timerBox?.value.invalidate()
                for monitor in monitors { NSEvent.removeMonitor(monitor.value) }
                if let observer { NotificationCenter.default.removeObserver(observer.value) }
                pendingEngineBox?.value.cancel()
                engineBox?.value.cancel()
                borderBox?.value.tearDown()
                controlBox?.value.tearDown()
            }
        }
        if Thread.isMainThread {
            cleanupMain()
        } else if !monitors.isEmpty || observer != nil || timerBox != nil || pendingEngineBox != nil || engineBox != nil || borderBox != nil || controlBox != nil {
            DispatchQueue.main.async(execute: cleanupMain)
        }
    }

    /// Removes stale temporary recordings older than `maxAgeSeconds` using `lstat`-verified
    /// directory and file checks while skipping symlinks and currently active staged files.
    public static func cleanupTemporaryRecordings(olderThan maxAgeSeconds: TimeInterval = 3600) {
        let active = activeStagedURLs.withLock { $0 }
        RecordingFileSecurity.cleanupStagingDirectory(
            at: stagingDirectoryURL(),
            olderThan: maxAgeSeconds,
            activeFileURLs: active
        )
    }

    public static func stagingDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CCXRecordings", isDirectory: true)
    }

    /// Starts an interactive recording HUD session for `region`.
    public func startSession(
        region: RecordingRegion,
        completion: @escaping @MainActor (RecordingOutcome) -> Void
    ) {
        guard !isSessionActive else { return }
        sessionGeneration &+= 1
        isSessionActive = true
        self.region = region
        self.completion = completion
        self.settings = settingsStore.load()
        self.effectiveSettings = nil
        self.phase = .ready
        self.isStartingRecording = false
        self.accumulatedElapsed = 0
        self.activeSegmentStartTime = nil
        self.lastEmittedElapsedSecond = nil
        self.stagedFileURL = nil

        let screen = Self.screen(for: region)
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let topInset = screen?.safeAreaInsets.top ?? 0
        let border = RecordingBorderPanel(region: region, topInset: topInset, settings: settings)
        let initialRegion = border.currentRegion
        self.region = initialRegion
        let control = RecordingControlPanel(
            captureRect: initialRegion.screenRect,
            visibleFrame: visibleFrame,
            settings: settings
        )

        border.onRegionChanged = { [weak self] updated in
            guard let self, self.isSessionActive, self.phase == .ready, !self.isStartingRecording else { return }
            self.region = updated
            if self.borderPanel?.isActivelyAdjusting != true {
                self.controlPanel?.updateCaptureRect(updated.screenRect)
            }
        }
        border.onInteractionStateChanged = { [weak self] isAdjusting in
            guard let self, self.isSessionActive, self.phase == .ready, !self.isStartingRecording else { return }
            self.controlPanel?.setTemporarilyHidden(isAdjusting)
            if !isAdjusting, let rect = self.region?.screenRect {
                self.controlPanel?.updateCaptureRect(rect)
            }
        }

        control.onSettingsChanged = { [weak self] updated in
            guard let self, self.phase == .ready, !self.isStartingRecording else { return }
            self.settings = updated
            self.settingsStore.save(updated)
            self.refreshChrome()
        }
        control.onStart = { [weak self] in self?.beginRecording() }
        control.onTogglePause = { [weak self] in self?.togglePause() }
        control.onStop = { [weak self] in self?.stopActiveRecording() }
        control.onCancel = { [weak self] in self?.cancelActiveSession() }
        control.onCopy = { [weak self] in self?.emitCompleted(.copy) }
        control.onSave = { [weak self] in self?.emitCompleted(.save) }
        control.onQuickSave = { [weak self] in self?.emitCompleted(.quickSave) }
        control.onReveal = { [weak self] in self?.emitCompleted(.reveal) }
        control.onDiscard = { [weak self] in self?.cancelActiveSession() }

        self.borderPanel = border
        self.controlPanel = control

        border.update(phase: .ready, region: initialRegion, settings: settings)
        border.orderFrontRegardless()
        control.makeKeyAndOrderFront(nil)

        installMonitors()
        installScreenParametersObserver()
        emitMenuBarStatus()
    }

    /// Cancels the active session and returns `true` only when currently in `.ready` phase.
    @discardableResult
    public func cancelIfInReadyPhase() -> Bool {
        guard isSessionActive, case .ready = phase else { return false }
        cancelActiveSession()
        return true
    }

    public func togglePause() {
        switch phase {
        case .recording:
            stopElapsedTimer()
            lastEmittedElapsedSecond = nil
            engine?.pause()
            if let start = activeSegmentStartTime {
                accumulatedElapsed += max(0, ProcessInfo.processInfo.systemUptime - start)
                activeSegmentStartTime = nil
            }
            phase = .paused
            refreshChrome()
            emitMenuBarStatus()
        case .paused:
            engine?.resume()
            activeSegmentStartTime = ProcessInfo.processInfo.systemUptime
            phase = .recording
            let elapsed = currentElapsedSeconds()
            lastEmittedElapsedSecond = max(0, Int(elapsed.rounded(.down)))
            refreshChrome()
            startElapsedTimer()
            emitMenuBarStatus(elapsed: elapsed)
        case .ready, .finalizing, .completed:
            break
        }
    }

    public func stopActiveRecording() {
        guard isRecordingOrPaused else { return }
        guard let engine else {
            cancelActiveSession()
            return
        }

        let generation = sessionGeneration
        stopElapsedTimer()
        lastEmittedElapsedSecond = nil
        if let start = activeSegmentStartTime {
            accumulatedElapsed += max(0, ProcessInfo.processInfo.systemUptime - start)
            activeSegmentStartTime = nil
        }

        phase = .finalizing
        refreshChrome()
        onStatusChanged?(nil)

        Task { @MainActor [weak self] in
            guard self?.isSessionActive == true, self?.sessionGeneration == generation else { return }
            do {
                let result = try await engine.stop()
                guard let self, self.isSessionActive, self.sessionGeneration == generation else {
                    RecordingFileSecurity.removeRegularFileIfPresent(at: result.fileURL)
                    return
                }
                self.engine = nil
                self.phase = .completed(result)
                self.refreshChrome()
                self.controlPanel?.makeKeyAndOrderFront(nil)
            } catch {
                guard let self, self.isSessionActive, self.sessionGeneration == generation else { return }
                self.engine = nil
                if error is CancellationError {
                    self.tearDown(outcome: .cancelled, deleteStagedFile: true)
                    return
                }
                Self.logger.error("Failed to finalize recording: \(error.localizedDescription)")
                if Self.isPermissionDeniedError(error) {
                    PermissionManager.setScreenRecordingVerified(false)
                    self.tearDown(outcome: .permissionDenied, deleteStagedFile: true)
                } else {
                    self.tearDown(outcome: .failed(Self.userFacingErrorMessage(for: error)), deleteStagedFile: true)
                }
            }
        }
    }

    public func cancelActiveSession() {
        guard isSessionActive else { return }
        tearDown(outcome: .cancelled, deleteStagedFile: true)
    }

    // MARK: - Private Recording Flow

    private func beginRecording() {
        guard isSessionActive,
              phase == .ready,
              !isStartingRecording,
              !(borderPanel?.isActivelyAdjusting ?? false),
              let region
        else { return }
        let generation = sessionGeneration
        isStartingRecording = true
        removeGlobalKeyMonitor()
        borderPanel?.prepareForCapture(region: region)
        controlPanel?.setTemporarilyHidden(false)
        NSCursor.arrow.set()

        Task { @MainActor [weak self] in
            guard let self, self.isSessionActive, self.sessionGeneration == generation, self.phase == .ready else { return }

            var runSettings = self.settings
            if runSettings.effectiveMicrophone {
                let micStatus = PermissionManager.microphoneAuthorizationStatus()
                switch micStatus {
                case .authorized:
                    break
                case .notDetermined:
                    let granted = await PermissionManager.requestMicrophoneAccess()
                    guard self.isSessionActive, self.sessionGeneration == generation, self.phase == .ready else {
                        return
                    }
                    if !granted {
                        runSettings.capturesMicrophone = false
                        self.onNotice?(
                            CCXL10n.text("Mic Denied — Recording No Mic", zh: "未授权麦克风，将无麦录制"),
                            "mic.slash"
                        )
                    }
                case .denied, .restricted:
                    runSettings.capturesMicrophone = false
                    self.onNotice?(
                        CCXL10n.text("Mic Off in Settings — No Mic Audio", zh: "系统设置已禁用麦克风，将无麦录制"),
                        "mic.slash"
                    )
                @unknown default:
                    runSettings.capturesMicrophone = false
                }
            }

            let stageDir = Self.stagingDirectoryURL()
            do {
                try RecordingFileSecurity.ensureSecureStagingDirectory(at: stageDir)
            } catch {
                guard self.isSessionActive, self.sessionGeneration == generation else { return }
                self.isStartingRecording = false
                self.tearDown(outcome: .failed(Self.userFacingErrorMessage(for: error)), deleteStagedFile: true)
                return
            }

            let stageURL = stageDir.appendingPathComponent("\(RecordingFileSecurity.stagedFilePrefix)\(UUID().uuidString).\(runSettings.format.fileExtension)")
            self.registerActiveStagedURL(stageURL)
            self.stagedFileURL = stageURL
            self.effectiveSettings = runSettings

            let newEngine = ScreenRecordingEngine(region: region, settings: runSettings, outputURL: stageURL)
            newEngine.onNotice = { [weak self, weak newEngine] message, symbol in
                guard let self, self.isSessionActive, self.sessionGeneration == generation else { return }
                if let newEngine {
                    self.effectiveSettings = newEngine.effectiveSettings
                }
                self.onNotice?(message, symbol)
                if self.phase != .ready {
                    self.refreshChrome()
                }
            }
            newEngine.onLimitReached = { [weak self] in
                guard let self, self.isSessionActive, self.sessionGeneration == generation, self.isRecordingOrPaused else { return }
                self.onNotice?(
                    CCXL10n.text("GIF Frame Limit — Finalizing…", zh: "GIF 已达帧数上限，正在生成…"),
                    "film"
                )
                self.stopActiveRecording()
            }
            newEngine.onWriterError = { [weak self] error in
                guard let self, self.isSessionActive, self.sessionGeneration == generation else { return }
                Self.logger.error("Recording writer error: \(error.localizedDescription)")
                self.tearDown(outcome: .failed(Self.userFacingErrorMessage(for: error)), deleteStagedFile: true)
            }
            newEngine.onUnexpectedStop = { [weak self] error in
                guard let self, self.isSessionActive, self.sessionGeneration == generation else { return }
                Self.logger.error("Recording stream error: \(error.localizedDescription)")
                if Self.isPermissionDeniedError(error) {
                    PermissionManager.setScreenRecordingVerified(false)
                    self.tearDown(outcome: .permissionDenied, deleteStagedFile: true)
                } else if self.isRecordingOrPaused {
                    if !Self.isUserStoppedStreamError(error) {
                        self.onNotice?(
                            CCXL10n.text("Recording Interrupted — Saving…", zh: "录屏意外中断，正在保存已录片段…"),
                            "exclamationmark.triangle"
                        )
                    }
                    self.stopActiveRecording()
                } else {
                    self.tearDown(outcome: .failed(Self.userFacingErrorMessage(for: error)), deleteStagedFile: true)
                }
            }

            var excludedIDs: Set<CGWindowID> = []
            for windowNumber in [self.borderPanel?.windowNumber ?? 0, self.controlPanel?.windowNumber ?? 0] where windowNumber > 0 {
                excludedIDs.insert(CGWindowID(windowNumber))
            }

            self.pendingEngine = newEngine
            do {
                try await newEngine.start(excludingWindowIDs: excludedIDs)
                guard self.isSessionActive, self.sessionGeneration == generation else {
                    newEngine.cancel()
                    return
                }
                self.pendingEngine = nil
                self.engine = newEngine
                self.effectiveSettings = newEngine.effectiveSettings
                self.isStartingRecording = false
                self.accumulatedElapsed = 0
                self.activeSegmentStartTime = ProcessInfo.processInfo.systemUptime
                self.lastEmittedElapsedSecond = 0
                self.phase = .recording
                self.refreshChrome()
                self.startElapsedTimer()
                self.emitMenuBarStatus(elapsed: 0)
            } catch {
                newEngine.cancel()
                guard self.isSessionActive, self.sessionGeneration == generation else { return }
                self.pendingEngine = nil
                self.isStartingRecording = false
                if error is CancellationError {
                    self.tearDown(outcome: .cancelled, deleteStagedFile: true)
                } else if Self.isPermissionDeniedError(error) {
                    PermissionManager.setScreenRecordingVerified(false)
                    self.tearDown(outcome: .permissionDenied, deleteStagedFile: true)
                } else {
                    self.tearDown(outcome: .failed(Self.userFacingErrorMessage(for: error)), deleteStagedFile: true)
                }
            }
        }
    }

    private func emitCompleted(_ kind: CompletedDisposition) {
        guard case .completed(let result) = phase else { return }
        let outcome: RecordingOutcome = switch kind {
        case .copy: .copy(result)
        case .save: .save(result)
        case .quickSave: .quickSave(result)
        case .reveal: .reveal(result)
        }
        tearDown(outcome: outcome, deleteStagedFile: false)
    }

    private enum CompletedDisposition {
        case copy, save, quickSave, reveal
    }

    private func currentElapsedSeconds() -> TimeInterval {
        var total = accumulatedElapsed
        if case .recording = phase, let start = activeSegmentStartTime {
            total += max(0, ProcessInfo.processInfo.systemUptime - start)
        }
        return total
    }

    private func refreshChrome() {
        let displaySettings = effectiveSettings ?? settings
        let elapsed = currentElapsedSeconds()
        if let region {
            borderPanel?.update(phase: phase, region: region, settings: displaySettings)
        }
        controlPanel?.update(phase: phase, settings: displaySettings, elapsedSeconds: elapsed)
    }

    private func emitMenuBarStatus(elapsed: TimeInterval? = nil) {
        let resolvedElapsed = elapsed ?? currentElapsedSeconds()
        switch phase {
        case .recording:
            onStatusChanged?(RecordingMenuBarStatus(
                isPaused: false,
                elapsedSeconds: resolvedElapsed,
                format: (effectiveSettings ?? settings).format
            ))
        case .paused:
            onStatusChanged?(RecordingMenuBarStatus(
                isPaused: true,
                elapsedSeconds: resolvedElapsed,
                format: (effectiveSettings ?? settings).format
            ))
        case .ready, .finalizing, .completed:
            onStatusChanged?(nil)
        }
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        let elapsed = currentElapsedSeconds()
        let fractional = elapsed.truncatingRemainder(dividingBy: 1.0)
        let nextSecondDelay = max(0.05, 1.0 - fractional)
        let fireDate = Date().addingTimeInterval(nextSecondDelay)
        let timer = Timer(fire: fireDate, interval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleElapsedTimerTick()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func handleElapsedTimerTick() {
        guard isSessionActive, phase == .recording else { return }
        let elapsed = currentElapsedSeconds()
        let wholeSecond = max(0, Int(elapsed.rounded(.down)))
        guard wholeSecond != lastEmittedElapsedSecond else { return }
        lastEmittedElapsedSecond = wholeSecond
        controlPanel?.updateElapsedSeconds(elapsed)
        emitMenuBarStatus(elapsed: elapsed)
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func registerActiveStagedURL(_ url: URL) {
        let standardized = url.standardizedFileURL
        Self.activeStagedURLs.withLock { _ = $0.insert(standardized) }
    }

    private func unregisterActiveStagedURL(_ url: URL?) {
        guard let url else { return }
        let standardized = url.standardizedFileURL
        Self.activeStagedURLs.withLock { _ = $0.remove(standardized) }
    }

    private func tearDown(outcome: RecordingOutcome, deleteStagedFile: Bool) {
        guard isSessionActive else { return }
        sessionGeneration &+= 1
        isSessionActive = false
        isStartingRecording = false
        stopElapsedTimer()
        lastEmittedElapsedSecond = nil
        removeMonitors()
        removeScreenParametersObserver()

        pendingEngine?.cancel()
        pendingEngine = nil
        engine?.cancel()
        engine = nil

        let staged = stagedFileURL
        stagedFileURL = nil
        unregisterActiveStagedURL(staged)
        if deleteStagedFile, let staged {
            RecordingFileSecurity.removeRegularFileIfPresent(at: staged)
        }

        region = nil
        effectiveSettings = nil
        accumulatedElapsed = 0
        activeSegmentStartTime = nil
        phase = .ready

        borderPanel?.tearDown()
        controlPanel?.tearDown()
        borderPanel = nil
        controlPanel = nil
        NSCursor.arrow.set()

        onStatusChanged?(nil)

        let finish = completion
        completion = nil
        finish?(outcome)
    }

    // MARK: - Display Reconfiguration

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
        guard isSessionActive, let currentRegion = region else { return }
        guard let matchedScreen = Self.exactScreen(for: currentRegion.displayID) else {
            if phase == .ready && !isStartingRecording {
                onNotice?(
                    CCXL10n.text("Display Disconnected", zh: "显示器已断开"),
                    "display.trianglebadge.exclamationmark"
                )
                cancelActiveSession()
            } else if let fallbackScreen = NSScreen.main {
                controlPanel?.updateVisibleFrame(fallbackScreen.visibleFrame)
            }
            return
        }

        if phase == .ready && !isStartingRecording {
            let refreshed = RecordingRegion(
                displayID: currentRegion.displayID,
                displayFrame: matchedScreen.frame,
                localRect: currentRegion.localRect,
                screenRect: currentRegion.screenRect,
                scale: matchedScreen.backingScaleFactor
            ).updating(localRect: currentRegion.localRect)
            region = refreshed
            borderPanel?.updateDisplayBounds(
                region: refreshed,
                topInset: matchedScreen.safeAreaInsets.top,
                settings: settings
            )
            if let synced = borderPanel?.currentRegion {
                region = synced
                controlPanel?.updateVisibleFrame(matchedScreen.visibleFrame)
                controlPanel?.updateCaptureRect(synced.screenRect)
            }
        } else {
            controlPanel?.updateVisibleFrame(matchedScreen.visibleFrame)
        }
    }

    // MARK: - Keyboard Monitors

    /// Returns `true` only when a global `Esc` key press should cancel the session
    /// (strictly limited to unmodified `Esc` in `.ready` phase when no menu is open).
    func shouldHandleGlobalEscape(modifiers: NSEvent.ModifierFlags) -> Bool {
        let normalizedMods = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard normalizedMods.isEmpty else { return false }
        guard isSessionActive, case .ready = phase, !isStartingRecording else { return false }
        guard controlPanel?.isPopupMenuOpen != true else { return false }
        return true
    }

    /// Evaluates whether a local key-down event belongs to the recording HUD/border and handles it.
    func handleLocalKeyDown(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        chars: String,
        windowNumber: Int,
        isEditingText: Bool
    ) -> Bool {
        guard isSessionActive else { return false }
        guard !isEditingText else { return false }
        guard controlPanel?.isPopupMenuOpen != true else { return false }

        let borderWinNum = borderPanel?.windowNumber ?? 0
        let controlWinNum = controlPanel?.windowNumber ?? 0
        guard windowNumber > 0,
              (borderWinNum > 0 && windowNumber == borderWinNum) ||
              (controlWinNum > 0 && windowNumber == controlWinNum)
        else {
            return false
        }

        let mods = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if keyCode == 53 && mods.isEmpty { // Escape
            switch phase {
            case .ready:
                if borderPanel?.isActivelyAdjusting == true {
                    if let restored = borderPanel?.cancelActiveAdjustment() {
                        region = restored
                    }
                    return true
                }
                cancelActiveSession()
                return true
            case .recording, .paused, .completed:
                cancelActiveSession()
                return true
            case .finalizing:
                // Never abort active finalization on accidental Escape.
                return false
            }
        }

        switch phase {
        case .ready:
            if isStartingRecording {
                return false
            }
            if borderPanel?.isActivelyAdjusting == true {
                if keyCode == 49 {
                    // Let `RecordingBorderView` handle Space to move the redraw origin.
                    return false
                }
                if keyCode == 36 || keyCode == 76 || (123...126).contains(keyCode) || (mods == .command && chars == "a") {
                    return true
                }
                return false
            }
            if (keyCode == 36 || keyCode == 76 || keyCode == 49) && mods.isEmpty {
                beginRecording()
                return true
            }
            if (123...126).contains(keyCode), mods.isSubset(of: [.shift, .option]) {
                let step: CGFloat = mods.contains(.shift) ? 10 : 1
                let updated: RecordingRegion?
                if mods.contains(.option) {
                    let (dw, dh): (CGFloat, CGFloat) = switch keyCode {
                    case 123: (-step, 0)
                    case 124: (step, 0)
                    case 125: (0, -step)
                    case 126: (0, step)
                    default: (0, 0)
                    }
                    updated = borderPanel?.resizeBy(dw: dw, dh: dh)
                } else {
                    let (dx, dy): (CGFloat, CGFloat) = switch keyCode {
                    case 123: (-step, 0)
                    case 124: (step, 0)
                    case 125: (0, -step)
                    case 126: (0, step)
                    default: (0, 0)
                    }
                    updated = borderPanel?.nudge(dx: dx, dy: dy)
                }
                if let updated {
                    region = updated
                    controlPanel?.updateCaptureRect(updated.screenRect)
                }
                return true
            }
            if mods == .command && chars == "a" {
                if let updated = borderPanel?.selectAll() {
                    region = updated
                    controlPanel?.updateCaptureRect(updated.screenRect)
                }
                return true
            }
            if mods == .command && chars == "w" {
                cancelActiveSession()
                return true
            }

        case .recording, .paused:
            if keyCode == 49 && mods.isEmpty {
                togglePause()
                return true
            }
            if (keyCode == 36 || keyCode == 76) && mods.isEmpty {
                stopActiveRecording()
                return true
            }
            if mods == .command && chars == "w" {
                cancelActiveSession()
                return true
            }

        case .finalizing:
            return false

        case .completed:
            if (keyCode == 36 || keyCode == 76) && mods.isEmpty {
                emitCompleted(.quickSave)
                return true
            }
            if mods == [.command, .shift] && chars == "s" {
                emitCompleted(.quickSave)
                return true
            }
            if mods == .command {
                switch chars {
                case "c":
                    emitCompleted(.copy)
                    return true
                case "s":
                    emitCompleted(.save)
                    return true
                case "r":
                    emitCompleted(.reveal)
                    return true
                case "w":
                    cancelActiveSession()
                    return true
                default:
                    break
                }
            }
        }
        return false
    }

    private func installMonitors() {
        removeMonitors()

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            let mods = event.modifierFlags
            Task { @MainActor [weak self] in
                guard let self, self.shouldHandleGlobalEscape(modifiers: mods) else { return }
                if self.borderPanel?.isActivelyAdjusting == true {
                    if let restored = self.borderPanel?.cancelActiveAdjustment() {
                        self.region = restored
                    }
                } else {
                    self.cancelActiveSession()
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let mods = event.modifierFlags
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let windowNumber = event.windowNumber

            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
                return self.handleLocalKeyDown(
                    keyCode: keyCode,
                    modifiers: mods,
                    chars: chars,
                    windowNumber: windowNumber,
                    isEditingText: isEditingText
                )
            }
            return consumed ? nil : event
        }
    }

    private func removeGlobalKeyMonitor() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func removeMonitors() {
        removeGlobalKeyMonitor()
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    // MARK: - Testing Helpers

    var controlPanelWindowNumberForTesting: Int? { controlPanel?.windowNumber }
    var borderPanelWindowNumberForTesting: Int? { borderPanel?.windowNumber }
    var borderPanelForTesting: RecordingBorderPanel? { borderPanel }

    func setPhaseForTesting(_ testPhase: RecordingPhase) {
        self.phase = testPhase
    }

    private static func exactScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }

    private static func screen(for region: RecordingRegion) -> NSScreen? {
        if let matched = exactScreen(for: region.displayID) {
            return matched
        }
        return NSScreen.screens.first { $0.frame.intersects(region.screenRect) } ?? NSScreen.main
    }

    static func isPermissionDeniedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamError.errorDomain &&
            nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func isUserStoppedStreamError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamError.errorDomain &&
            nsError.code == SCStreamError.Code.systemStoppedStream.rawValue
    }

    /// Maps technical ScreenCaptureKit, AVFoundation, and filesystem errors to clear user-facing copy.
    static func userFacingErrorMessage(for error: Error) -> String {
        userFacingErrorMessage(for: error, depth: 0)
    }

    private static func userFacingErrorMessage(for error: Error, depth: Int) -> String {
        if let recordingError = error as? RecordingError,
           let description = recordingError.errorDescription {
            return description
        }

        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code) {
            switch code {
            case .userDeclined:
                return CCXL10n.text("Screen Recording permission is required.", zh: "需要屏幕录制权限。")
            case .missingEntitlements:
                return CCXL10n.text(
                    "Recording permission is unavailable. Try relaunching CCX.",
                    zh: "录屏权限不可用，请重新打开 CCX。"
                )
            case .failedToStartAudioCapture, .failedToStartMicrophoneCapture:
                return CCXL10n.text(
                    "Could not start audio capture. Check your audio device or record without audio.",
                    zh: "无法采集音频，请检查音频设备或静音录制。"
                )
            case .noDisplayList, .noWindowList, .noCaptureSource:
                return CCXL10n.text("The selected display is no longer available.", zh: "所选显示器已不可用。")
            case .systemStoppedStream:
                return CCXL10n.text("Recording was stopped by macOS.", zh: "录屏已被 macOS 停止。")
            case .failedToStart, .attemptToStartStreamState:
                return CCXL10n.text("Could not start screen recording. Please try again.", zh: "无法开始录屏，请重试。")
            default:
                return CCXL10n.text("Screen recording was interrupted by macOS.", zh: "录屏被 macOS 中断。")
            }
        }

        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileWriteOutOfSpaceError {
                return CCXL10n.text("Not enough disk space to save the recording.", zh: "磁盘空间不足，无法保存录屏。")
            }
            if nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError {
                return CCXL10n.text("CCX does not have permission to write the recording file.", zh: "CCX 没有权限写入录屏文件。")
            }
        }

        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(ENOSPC) {
                return CCXL10n.text("Not enough disk space to save the recording.", zh: "磁盘空间不足，无法保存录屏。")
            }
            if nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
                return CCXL10n.text("CCX does not have permission to write the recording file.", zh: "CCX 没有权限写入录屏文件。")
            }
        }

        if nsError.domain == AVFoundationErrorDomain {
            if nsError.code == AVError.Code.diskFull.rawValue {
                return CCXL10n.text("Not enough disk space to save the recording.", zh: "磁盘空间不足，无法保存录屏。")
            }
            if nsError.code == AVError.Code.deviceWasDisconnected.rawValue || nsError.code == AVError.Code.deviceNotConnected.rawValue {
                return CCXL10n.text("A recording device was disconnected. Please try again.", zh: "录制设备已断开，请重试。")
            }
            if nsError.code == AVError.Code.maximumFileSizeReached.rawValue || nsError.code == AVError.Code.maximumDurationReached.rawValue {
                return CCXL10n.text("Recording reached the maximum file size limit.", zh: "录屏已达到文件大小上限。")
            }
        }

        if depth < 3, let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            let mapped = userFacingErrorMessage(for: underlying, depth: depth + 1)
            if mapped != underlying.localizedDescription {
                return mapped
            }
        }

        if nsError.domain == AVFoundationErrorDomain {
            return CCXL10n.text("Could not encode the video recording. Please try again.", zh: "无法编码录屏视频，请重试。")
        }

        return error.localizedDescription
    }
}
