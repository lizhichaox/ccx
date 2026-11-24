import AppKit
import CCXCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsHotKeyState: ObservableObject {
    @Published var snipCombo: HotKeyCombo
    @Published var isSnipRegistered: Bool
    @Published var isRecordingShortcut: Bool = false
    @Published var liveRecordingModifiers: NSEvent.ModifierFlags = []
    @Published var shortcutFeedback: String?
    @Published var hasClearableHistory: Bool
    @Published var recordingsFolderPath: String

    init(
        snipCombo: HotKeyCombo = .defaultSnip,
        isSnipRegistered: Bool = true,
        hasClearableHistory: Bool = false,
        recordingsFolderPath: String = "~/Movies/CCX"
    ) {
        self.snipCombo = snipCombo
        self.isSnipRegistered = isSnipRegistered
        self.hasClearableHistory = hasClearableHistory
        self.recordingsFolderPath = recordingsFolderPath
    }
}

private struct SendableSettingsMonitorBox: @unchecked Sendable {
    let monitor: Any
}

/// Hosts the compact, two-card Settings window: preferences (updates, launch at login,
/// recordings folder, customizable snip shortcut) and macOS permissions.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let permissions = PermissionStatusModel()
    private let hotKeyState: SettingsHotKeyState
    private let updateManager: AppUpdateManager
    private let onBeginShortcutRecording: () -> Void
    private let onEndShortcutRecording: () -> Void
    private let onChangeSnipHotKey: (HotKeyCombo) -> HotKeyConflict?
    private let onResetSnipHotKey: () -> HotKeyConflict?
    private let onRetryHotKey: () -> Bool
    private let onOpenRecordingsFolder: () -> Void
    private let onChooseRecordingsFolder: () -> Void
    private let onOpenGuide: (NSRect?) -> Void
    private let onClearHistory: () -> Void
    private var window: NSWindow?
    nonisolated(unsafe) private var shortcutMonitor: Any?

    var windowFrame: NSRect? { window?.frame }

    init(
        updateManager: AppUpdateManager,
        snipCombo: HotKeyCombo = .defaultSnip,
        isSnipHotKeyRegistered: Bool = true,
        hasClearableHistory: Bool = false,
        recordingsFolderPath: String = "~/Movies/CCX",
        onBeginShortcutRecording: @escaping () -> Void = {},
        onEndShortcutRecording: @escaping () -> Void = {},
        onChangeSnipHotKey: @escaping (HotKeyCombo) -> HotKeyConflict? = { _ in nil },
        onResetSnipHotKey: @escaping () -> HotKeyConflict? = { nil },
        onRetryHotKey: @escaping () -> Bool = { false },
        onOpenRecordingsFolder: @escaping () -> Void = {},
        onChooseRecordingsFolder: @escaping () -> Void = {},
        onOpenGuide: @escaping (NSRect?) -> Void = { _ in },
        onClearHistory: @escaping () -> Void = {}
    ) {
        self.updateManager = updateManager
        self.hotKeyState = SettingsHotKeyState(
            snipCombo: snipCombo,
            isSnipRegistered: isSnipHotKeyRegistered,
            hasClearableHistory: hasClearableHistory,
            recordingsFolderPath: recordingsFolderPath
        )
        self.onBeginShortcutRecording = onBeginShortcutRecording
        self.onEndShortcutRecording = onEndShortcutRecording
        self.onChangeSnipHotKey = onChangeSnipHotKey
        self.onResetSnipHotKey = onResetSnipHotKey
        self.onRetryHotKey = onRetryHotKey
        self.onOpenRecordingsFolder = onOpenRecordingsFolder
        self.onChooseRecordingsFolder = onChooseRecordingsFolder
        self.onOpenGuide = onOpenGuide
        self.onClearHistory = onClearHistory
        super.init()
    }

    deinit {
        if let shortcutMonitor {
            let box = SendableSettingsMonitorBox(monitor: shortcutMonitor)
            if Thread.isMainThread {
                NSEvent.removeMonitor(box.monitor)
            } else {
                DispatchQueue.main.async {
                    NSEvent.removeMonitor(box.monitor)
                }
            }
        }
    }

    func updateSnipHotKey(combo: HotKeyCombo, isRegistered: Bool) {
        if hotKeyState.snipCombo != combo {
            hotKeyState.snipCombo = combo
        }
        if hotKeyState.isSnipRegistered != isRegistered {
            hotKeyState.isSnipRegistered = isRegistered
        }
    }

    func updateHotKeyRegistered(_ registered: Bool) {
        if hotKeyState.isSnipRegistered != registered {
            hotKeyState.isSnipRegistered = registered
        }
    }

    func updateHasClearableHistory(_ hasHistory: Bool) {
        if hotKeyState.hasClearableHistory != hasHistory {
            hotKeyState.hasClearableHistory = hasHistory
        }
    }

    func updateRecordingsFolder(_ path: String) {
        if hotKeyState.recordingsFolderPath != path {
            hotKeyState.recordingsFolderPath = path
        }
    }

    func show(anchoredTo anchorRect: NSRect? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        if !hotKeyState.isRecordingShortcut {
            hotKeyState.shortcutFeedback = nil
        }
        permissions.refresh()
        permissions.startPolling()

        let targetScreen = anchorRect.flatMap { WindowScreenLocator.screen(for: $0) }
            ?? WindowScreenLocator.activeCursorScreen()
        let currentScreen = window.screen ?? WindowScreenLocator.screen(for: window.frame)
        let shouldReposition: Bool
        if !window.isVisible {
            shouldReposition = true
        } else if anchorRect != nil,
                  let targetScreen,
                  !WindowScreenLocator.isSameScreen(currentScreen, targetScreen) {
            shouldReposition = true
        } else {
            shouldReposition = false
        }

        syncWindowHeightToFit(preserveTopEdge: !shouldReposition)
        if shouldReposition {
            position(window: window, anchoredTo: anchorRect, targetScreen: targetScreen)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(
            permissions: permissions,
            hotKeyState: hotKeyState,
            updateManager: updateManager,
            onStartRecordingShortcut: { [weak self] in
                self?.startRecordingShortcut()
            },
            onCancelRecordingShortcut: { [weak self] in
                self?.stopRecordingShortcut()
            },
            onResetSnipHotKey: { [weak self] in
                self?.resetSnipShortcut()
            },
            onRetryHotKey: { [weak self] in
                guard let self else { return }
                self.stopRecordingShortcut()
                let registered = self.onRetryHotKey()
                self.updateHotKeyRegistered(registered)
                if registered {
                    self.hotKeyState.shortcutFeedback = nil
                }
            },
            onOpenRecordingsFolder: { [weak self] in
                self?.stopRecordingShortcut()
                self?.onOpenRecordingsFolder()
            },
            onChooseRecordingsFolder: { [weak self] in
                self?.stopRecordingShortcut()
                self?.onChooseRecordingsFolder()
            },
            onOpenGuide: { [weak self] in
                self?.stopRecordingShortcut()
                self?.onOpenGuide(self?.window?.frame)
            },
            onClearHistory: { [weak self] in
                self?.stopRecordingShortcut()
                self?.onClearHistory()
            },
            onContentHeightChange: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.syncWindowHeightToFit(preserveTopEdge: true)
                }
            }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.safeAreaRegions = []
        hosting.sizingOptions = [.intrinsicContentSize]
        let window = DismissibleWindow(contentViewController: hosting)
        window.title = "CCX Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        return window
    }

    // MARK: - Shortcut Recording

    private func startRecordingShortcut() {
        guard !hotKeyState.isRecordingShortcut else { return }
        hotKeyState.isRecordingShortcut = true
        hotKeyState.liveRecordingModifiers = []
        hotKeyState.shortcutFeedback = nil
        (window as? DismissibleWindow)?.suppressDismissKeyEquivalents = true
        onBeginShortcutRecording()
        installShortcutMonitor()
    }

    private func stopRecordingShortcut(clearFeedback: Bool = true) {
        let wasRecording = hotKeyState.isRecordingShortcut
        removeShortcutMonitor()
        (window as? DismissibleWindow)?.suppressDismissKeyEquivalents = false
        hotKeyState.liveRecordingModifiers = []
        if clearFeedback {
            hotKeyState.shortcutFeedback = nil
        }
        guard wasRecording else { return }
        hotKeyState.isRecordingShortcut = false
        onEndShortcutRecording()
    }

    private func resetSnipShortcut() {
        stopRecordingShortcut()
        if let conflict = onResetSnipHotKey() {
            hotKeyState.shortcutFeedback = conflict.localizedDescription
            NSSound.beep()
        } else {
            hotKeyState.snipCombo = .defaultSnip
            hotKeyState.isSnipRegistered = true
            hotKeyState.shortcutFeedback = nil
        }
    }

    private func installShortcutMonitor() {
        removeShortcutMonitor()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let eventType = event.type
            let eventWindowNumber = event.windowNumber
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            let isARepeat = eventType == .keyDown ? event.isARepeat : false

            let consumed = MainActor.assumeIsolated {
                guard let self,
                      self.hotKeyState.isRecordingShortcut,
                      let window = self.window,
                      window.isVisible,
                      window.isKeyWindow
                else {
                    return false
                }
                if eventWindowNumber != 0 && eventWindowNumber != window.windowNumber {
                    return false
                }
                return self.handleShortcutEvent(
                    type: eventType,
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    isARepeat: isARepeat
                )
            }
            return consumed ? nil : event
        }
    }

    private func removeShortcutMonitor() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
    }

    private func handleShortcutEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isARepeat: Bool
    ) -> Bool {
        let cleanFlags = modifierFlags.intersection([.control, .option, .shift, .command])

        if type == .flagsChanged {
            hotKeyState.liveRecordingModifiers = cleanFlags
            return false
        }

        guard type == .keyDown else { return false }
        if isARepeat { return true }

        // Pure Esc (53) or pure Delete/ForwardDelete (51 / 117) cancels recording cleanly.
        if cleanFlags.isEmpty && (keyCode == 53 || keyCode == 51 || keyCode == 117) {
            stopRecordingShortcut()
            return true
        }

        let candidate = HotKeyCombo(keyCode: UInt32(keyCode), modifierFlags: cleanFlags)
        if candidate.isModifierOnlyKey {
            return true
        }

        if candidate == hotKeyState.snipCombo && hotKeyState.isSnipRegistered {
            stopRecordingShortcut()
            return true
        }

        if let conflict = onChangeSnipHotKey(candidate) {
            hotKeyState.shortcutFeedback = conflict.localizedDescription
            NSSound.beep()
            return true
        }

        hotKeyState.snipCombo = candidate
        hotKeyState.isSnipRegistered = true
        hotKeyState.shortcutFeedback = nil
        stopRecordingShortcut()
        return true
    }

    private func syncWindowHeightToFit(preserveTopEdge: Bool) {
        guard let window, let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        guard abs(currentContentSize.width - fitting.width) > 0.5
            || abs(currentContentSize.height - fitting.height) > 0.5
        else { return }

        if preserveTopEdge {
            let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: fitting)).size
            var frame = window.frame
            frame.origin.y += frame.height - targetFrameSize.height
            frame.size = targetFrameSize
            if let visibleFrame = (window.screen ?? WindowScreenLocator.screen(for: window.frame))?.visibleFrame {
                let minY = visibleFrame.minY + 8
                let maxY = max(minY, visibleFrame.maxY - frame.height - 6)
                frame.origin.y = min(max(frame.origin.y, minY), maxY)
            }
            window.setFrame(frame, display: true)
        } else {
            window.setContentSize(fitting)
        }
    }

    private func position(window: NSWindow, anchoredTo anchorRect: NSRect?, targetScreen: NSScreen?) {
        let size = window.frame.size
        let screen = targetScreen
            ?? anchorRect.flatMap { WindowScreenLocator.screen(for: $0) }
            ?? WindowScreenLocator.activeCursorScreen()

        var origin: NSPoint
        if let anchorRect {
            origin = NSPoint(
                x: (anchorRect.midX - size.width / 2).rounded(),
                y: (anchorRect.minY - 6 - size.height).rounded()
            )
        } else if let visibleFrame = screen?.visibleFrame {
            origin = NSPoint(
                x: (visibleFrame.midX - size.width / 2).rounded(),
                y: (visibleFrame.midY - size.height / 2).rounded()
            )
        } else {
            window.center()
            return
        }

        if let visibleFrame = screen?.visibleFrame {
            origin = WindowScreenLocator.clampOrigin(origin, windowSize: size, to: visibleFrame)
        }

        window.setFrame(NSRect(origin: origin, size: size), display: window.isVisible)
    }

    func windowDidResignKey(_ notification: Notification) {
        if hotKeyState.isRecordingShortcut {
            stopRecordingShortcut()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if hotKeyState.isRecordingShortcut {
            stopRecordingShortcut()
        }
        permissions.stopPolling()
    }
}

private struct SettingsView: View {
    @ObservedObject var permissions: PermissionStatusModel
    @ObservedObject var hotKeyState: SettingsHotKeyState
    @ObservedObject var updateManager: AppUpdateManager
    let onStartRecordingShortcut: () -> Void
    let onCancelRecordingShortcut: () -> Void
    let onResetSnipHotKey: () -> Void
    let onRetryHotKey: () -> Void
    let onOpenRecordingsFolder: () -> Void
    let onChooseRecordingsFolder: () -> Void
    let onOpenGuide: () -> Void
    let onClearHistory: () -> Void
    let onContentHeightChange: () -> Void
    @State private var openedScreenRecordingSettings = false

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(alignment: .center, spacing: 12) {
                SettingsIdentityHeader()

                VStack(spacing: 10) {
                    // Card 1 — Preferences
                    VStack(spacing: 0) {
                        UpdatesSettingRow(updateManager: updateManager)
                        Divider().padding(.leading, 42)
                        LaunchAtLoginRow()
                        Divider().padding(.leading, 42)
                        RecordingsFolderRow(
                            folderPath: hotKeyState.recordingsFolderPath,
                            onChoose: onChooseRecordingsFolder,
                            onOpen: onOpenRecordingsFolder
                        )
                        Divider().padding(.leading, 42)
                        SnipShortcutRow(
                            combo: hotKeyState.snipCombo,
                            isRegistered: hotKeyState.isSnipRegistered,
                            isRecording: hotKeyState.isRecordingShortcut,
                            liveModifiers: hotKeyState.liveRecordingModifiers,
                            feedback: hotKeyState.shortcutFeedback,
                            onStartRecording: onStartRecordingShortcut,
                            onCancelRecording: onCancelRecordingShortcut,
                            onReset: onResetSnipHotKey,
                            onRetry: onRetryHotKey
                        )
                    }
                    .ccxSettingsCard(cornerRadius: 12)

                    // Card 2 — Permissions
                    VStack(spacing: 0) {
                        ScreenRecordingSettingRow(
                            granted: permissions.status.screenRecording,
                            isChecking: permissions.isCheckingScreenRecording,
                            showRelaunch: openedScreenRecordingSettings && !permissions.status.screenRecording,
                            onOpen: {
                                openedScreenRecordingSettings = true
                                permissions.openScreenRecordingSettings()
                            },
                            onVerify: {
                                permissions.verifyScreenRecordingLive()
                            },
                            onRelaunch: {
                                AppRelauncher.relaunch()
                            }
                        )
                        Divider().padding(.leading, 42)
                        PermissionSettingRow(
                            symbol: "accessibility",
                            tint: .indigo,
                            title: "Accessibility",
                            granted: permissions.status.accessibility,
                            openAction: permissions.openAccessibilitySettings
                        )
                        Divider().padding(.leading, 42)
                        PermissionSettingRow(
                            symbol: "mic.fill",
                            tint: .pink,
                            title: "Microphone",
                            granted: permissions.status.microphone,
                            openAction: permissions.openMicrophoneSettings
                        )
                    }
                    .ccxSettingsCard(cornerRadius: 12)
                }

                HStack(spacing: 8) {
                    Button {
                        onOpenGuide()
                    } label: {
                        Label("Setup Guide", systemImage: "book.closed")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        onClearHistory()
                    } label: {
                        Label("Clear Snip History", systemImage: "trash")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hotKeyState.hasClearableHistory)
                }

                SettingsFooter()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { oldHeight, newHeight in
                if abs(oldHeight - newHeight) > 0.5 {
                    onContentHeightChange()
                }
            }
        }
        .frame(width: 368)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsFooter: View {
    private static let authorURL = URL(string: "https://lizhichao.com")
    @State private var isHoveringAuthor = false

    var body: some View {
        VStack(spacing: 3) {
            Text("Local captures & OCR · Zero telemetry")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                Text("Made By ")
                    .foregroundStyle(.tertiary)

                Button {
                    if let url = Self.authorURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("LIZHICHAO")
                        .fontWeight(.semibold)
                        .foregroundStyle(isHoveringAuthor ? Color.accentColor : Color.secondary)
                        .underline(isHoveringAuthor)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { hovering in
                    isHoveringAuthor = hovering
                }

                Text(" with ❤️.")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Header & Section Building Blocks

private struct SettingsIdentityHeader: View {
    var body: some View {
        VStack(spacing: 4) {
            CCXBrandIcon(size: 44)

            VStack(spacing: 1.5) {
                Text("Control · Command · X")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("v\(AppVersion.shortDisplay)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
    }
}

// MARK: - Rows

private struct SnipShortcutRow: View {
    let combo: HotKeyCombo
    let isRegistered: Bool
    let isRecording: Bool
    let liveModifiers: NSEvent.ModifierFlags
    let feedback: String?
    let onStartRecording: () -> Void
    let onCancelRecording: () -> Void
    let onReset: () -> Void
    let onRetry: () -> Void

    @State private var isHoveringKeycaps = false
    @State private var isHoveringReset = false
    @State private var isHoveringCancel = false

    private var iconTint: Color {
        if feedback != nil || (!isRecording && !isRegistered) {
            return .orange
        }
        return .blue
    }

    private var liveRecordingLabel: String {
        var parts: [String] = []
        if liveModifiers.contains(.control) { parts.append("⌃") }
        if liveModifiers.contains(.option) { parts.append("⌥") }
        if liveModifiers.contains(.shift) { parts.append("⇧") }
        if liveModifiers.contains(.command) { parts.append("⌘") }
        if parts.isEmpty {
            return "Press shortcut…"
        }
        parts.append("…")
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SettingsRow(
                symbol: "viewfinder",
                tint: iconTint,
                title: "Snip Shortcut"
            ) {
                if isRecording {
                    HStack(spacing: 5) {
                        Text(liveRecordingLabel)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .frame(minHeight: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.25)
                            )
                            .fixedSize()

                        Button(action: onCancelRecording) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isHoveringCancel ? Color.primary : Color.secondary)
                                .frame(width: 22, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isHoveringCancel ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(isHoveringCancel ? 0.18 : 0.10), lineWidth: 0.75)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel recording (Esc)")
                        .accessibilityLabel("Cancel shortcut recording")
                        .onHover { isHoveringCancel = $0 }
                    }
                } else {
                    HStack(spacing: 5) {
                        if !isRegistered {
                            Button("Retry", action: onRetry)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize()
                        }

                        if combo != .defaultSnip {
                            Button(action: onReset) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(isHoveringReset ? Color.primary : Color.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(isHoveringReset ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(isHoveringReset ? 0.18 : 0.10), lineWidth: 0.75)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Reset to default (\(HotKeyCombo.defaultSnip.displayString))")
                            .accessibilityLabel("Reset shortcut to default")
                            .onHover { isHoveringReset = $0 }
                        }

                        Button(action: onStartRecording) {
                            KeycapComboView(combo: combo)
                                .padding(2)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isHoveringKeycaps ? Color.accentColor.opacity(0.08) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(
                                            isHoveringKeycaps ? Color.accentColor.opacity(0.50) : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Click to customize shortcut")
                        .accessibilityLabel("Snip shortcut \(combo.displayString). Click to customize.")
                        .onHover { isHoveringKeycaps = $0 }
                    }
                }
            }

            if let feedback {
                Text(feedback)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 43)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
            } else if isRecording {
                Text("Press your new shortcut, or Esc to cancel.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 43)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
            } else if !isRegistered {
                Text("Shortcut \(combo.displayString) is currently in use by another app.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 43)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
            }
        }
    }
}

private struct LaunchAtLoginRow: View {
    @State private var serviceStatus = SMAppService.mainApp.status
    @State private var errorMessage: String?

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { serviceStatus == .enabled },
            set: { enabled in
                apply(enabled)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(symbol: "power", tint: .teal, title: "Launch at Login") {
                HStack(spacing: 6) {
                    if serviceStatus == .requiresApproval {
                        Button("Approve") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Toggle("", isOn: toggleBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            if serviceStatus == .requiresApproval {
                Text("Approval required in System Settings → Login Items.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 43)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 43)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
            }
        }
        .onAppear {
            syncStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncStatus()
        }
    }

    private func syncStatus() {
        serviceStatus = SMAppService.mainApp.status
        if serviceStatus == .enabled || serviceStatus == .notRegistered {
            errorMessage = nil
        }
    }

    private func apply(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            serviceStatus = SMAppService.mainApp.status
        } catch {
            serviceStatus = SMAppService.mainApp.status
            errorMessage = "Could not update Launch at Login."
        }
    }
}

private struct RecordingsFolderRow: View {
    let folderPath: String
    let onChoose: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))

            VStack(alignment: .leading, spacing: 1.5) {
                Text("Recordings")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)

                Text(folderPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button("Choose…", action: onChoose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .help("Default recordings folder: \(folderPath)")
    }
}

private struct UpdatesSettingRow: View {
    @ObservedObject var updateManager: AppUpdateManager

    private var iconTint: Color {
        if case .available = updateManager.state {
            return .green
        }
        return .blue
    }

    private var statusSubtitle: String {
        switch updateManager.state {
        case .idle:
            return updateManager.automaticallyChecksForUpdates ? "Automatic" : "Manual"
        case .checking:
            return "Checking…"
        case .upToDate:
            return "Up to date"
        case .available(let release):
            return "v\(release.version.description) available"
        case .downloading(_, let progress):
            return "Downloading \(Int((progress * 100).rounded()))%…"
        case .verifying:
            return "Verifying…"
        case .installing:
            return "Installing…"
        case .failed:
            return "Update failed"
        }
    }

    private var subtitleColor: Color {
        switch updateManager.state {
        case .available:
            return .green
        case .failed:
            return .red
        case .idle, .checking, .upToDate, .downloading, .verifying, .installing:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 24, height: 24)
                    .background(iconTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))

                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Updates")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)

                    Text(statusSubtitle)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingControls
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)

            switch updateManager.state {
            case .available(let release):
                HStack(spacing: 6) {
                    Button {
                        NSWorkspace.shared.open(release.releaseURL)
                    } label: {
                        Text("View Release Notes ↗")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 43)
                .padding(.trailing, 10)
                .padding(.bottom, 7)

            case .failed(let message, let release):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        NSWorkspace.shared.open(release?.releaseURL ?? AppUpdateURLPolicy.releasesPageURL)
                    } label: {
                        Text("Open GitHub ↗")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                }
                .padding(.leading, 43)
                .padding(.trailing, 10)
                .padding(.bottom, 7)

            case .idle, .checking, .upToDate, .downloading, .verifying, .installing:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch updateManager.state {
        case .idle, .upToDate:
            HStack(spacing: 6) {
                Button("Check") {
                    updateManager.checkForUpdates(userInitiated: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                autoCheckToggle
            }

        case .checking:
            HStack(spacing: 6) {
                Button("Checking…") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                    .fixedSize()
                autoCheckToggle
            }

        case .available:
            HStack(spacing: 6) {
                Button("Update") {
                    updateManager.installAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                autoCheckToggle
            }

        case .downloading(_, let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 66)
                Button("Cancel") {
                    updateManager.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }

        case .verifying, .installing:
            ProgressView()
                .controlSize(.small)

        case .failed(_, let release):
            HStack(spacing: 6) {
                Button("Retry") {
                    if release != nil {
                        updateManager.installAvailableUpdate()
                    } else {
                        updateManager.checkForUpdates(userInitiated: true)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                autoCheckToggle
            }
        }
    }

    private var autoCheckToggle: some View {
        Toggle("", isOn: $updateManager.automaticallyChecksForUpdates)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Automatically check for updates daily")
    }
}

private struct ScreenRecordingSettingRow: View {
    let granted: Bool
    let isChecking: Bool
    let showRelaunch: Bool
    let onOpen: () -> Void
    let onVerify: () -> Void
    let onRelaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SettingsRow(
                symbol: "rectangle.dashed.badge.record",
                tint: granted ? .green : .orange,
                title: "Screen Recording"
            ) {
                HStack(spacing: 6) {
                    PermissionBadge(granted: granted)
                    Button("Open", action: onOpen)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                }
            }

            if !granted {
                HStack(spacing: 6) {
                    Text(showRelaunch ? "Relaunch CCX after enabling." : "Already enabled?")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(isChecking ? "Checking…" : "Verify", action: onVerify)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isChecking)
                        .fixedSize()
                    if showRelaunch {
                        Button("Relaunch", action: onRelaunch)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .fixedSize()
                    }
                }
                .padding(.leading, 43)
                .padding(.trailing, 10)
                .padding(.bottom, 7)
            }
        }
    }
}

private struct PermissionSettingRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let granted: Bool
    let openAction: () -> Void

    var body: some View {
        SettingsRow(symbol: symbol, tint: granted ? .green : tint, title: title) {
            HStack(spacing: 6) {
                PermissionBadge(granted: granted)
                Button("Open", action: openAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Surface & Version

private extension View {
    @ViewBuilder
    func ccxSettingsCard(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

enum AppVersion {
    static var shortDisplay: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    static var display: String {
        "Version \(shortDisplay)"
    }
}

/// Multi-display screen lookup and clamping helpers shared by Settings, Setup Guide,
/// and the menu bar popover so auxiliary windows always open on the intended display.
@MainActor
enum WindowScreenLocator {
    static func screen(for rect: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        if !rect.isNull,
           rect.origin.x.isFinite,
           rect.origin.y.isFinite,
           rect.size.width.isFinite,
           rect.size.height.isFinite
        {
            let center = NSPoint(x: rect.midX, y: rect.midY)
            if let containingCenter = screens.first(where: { $0.frame.contains(center) }) {
                return containingCenter
            }

            var bestScreen: NSScreen?
            var bestArea: CGFloat = 0
            for candidate in screens {
                let overlap = candidate.frame.intersection(rect)
                guard !overlap.isNull, !overlap.isEmpty, overlap.width > 0, overlap.height > 0 else {
                    continue
                }
                let area = overlap.width * overlap.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = candidate
                }
            }
            if let bestScreen {
                return bestScreen
            }
        }

        return activeCursorScreen()
    }

    static func activeCursorScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func isSameScreen(_ lhs: NSScreen?, _ rhs: NSScreen?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        if lhs === rhs { return true }
        if let lhsID = displayID(of: lhs), let rhsID = displayID(of: rhs) {
            return lhsID == rhsID
        }
        return lhs == rhs
    }

    static func clampOrigin(
        _ origin: NSPoint,
        windowSize: NSSize,
        to visibleFrame: NSRect,
        horizontalInset: CGFloat = 8,
        bottomInset: CGFloat = 8,
        topInset: CGFloat = 6
    ) -> NSPoint {
        let minX = visibleFrame.minX + horizontalInset
        let maxX = max(minX, visibleFrame.maxX - windowSize.width - horizontalInset)
        let minY = visibleFrame.minY + bottomInset
        let maxY = max(minY, visibleFrame.maxY - windowSize.height - topInset)
        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
