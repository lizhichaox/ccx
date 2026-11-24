import AppKit
import CCXCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsHotKeyState: ObservableObject {
    @Published var isSnipRegistered: Bool
    @Published var hasClearableHistory: Bool

    init(isSnipRegistered: Bool = true, hasClearableHistory: Bool = false) {
        self.isSnipRegistered = isSnipRegistered
        self.hasClearableHistory = hasClearableHistory
    }
}

/// Hosts the compact, single-screen Settings window: shortcut, launch at login, and permissions.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let permissions = PermissionStatusModel()
    private let hotKeyState: SettingsHotKeyState
    private let onRetryHotKey: () -> Bool
    private let onOpenGuide: (NSRect?) -> Void
    private let onClearHistory: () -> Void
    private var window: NSWindow?

    var windowFrame: NSRect? { window?.frame }

    init(
        isSnipHotKeyRegistered: Bool = true,
        hasClearableHistory: Bool = false,
        onRetryHotKey: @escaping () -> Bool = { false },
        onOpenGuide: @escaping (NSRect?) -> Void = { _ in },
        onClearHistory: @escaping () -> Void = {}
    ) {
        self.hotKeyState = SettingsHotKeyState(
            isSnipRegistered: isSnipHotKeyRegistered,
            hasClearableHistory: hasClearableHistory
        )
        self.onRetryHotKey = onRetryHotKey
        self.onOpenGuide = onOpenGuide
        self.onClearHistory = onClearHistory
        super.init()
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

    func show(anchoredTo anchorRect: NSRect? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
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
            onRetryHotKey: { [weak self] in
                guard let self else { return }
                let registered = self.onRetryHotKey()
                self.updateHotKeyRegistered(registered)
            },
            onOpenGuide: { [weak self] in
                self?.onOpenGuide(self?.window?.frame)
            },
            onClearHistory: { [weak self] in
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

    func windowWillClose(_ notification: Notification) {
        permissions.stopPolling()
    }
}

private struct SettingsView: View {
    @ObservedObject var permissions: PermissionStatusModel
    @ObservedObject var hotKeyState: SettingsHotKeyState
    let onRetryHotKey: () -> Void
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

                VStack(spacing: 0) {
                    SnipShortcutRow(
                        isRegistered: hotKeyState.isSnipRegistered,
                        onRetry: onRetryHotKey
                    )
                    Divider().padding(.leading, 42)
                    LaunchAtLoginRow()
                    Divider().padding(.leading, 42)
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
            Text("100% local & private · Zero telemetry")
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
    let isRegistered: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SettingsRow(
                symbol: "viewfinder",
                tint: isRegistered ? .blue : .orange,
                title: "Snip Shortcut"
            ) {
                HStack(spacing: 6) {
                    if !isRegistered {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                    }
                    KeycapComboView(combo: .defaultSnip)
                }
            }

            if !isRegistered {
                Text("Shortcut is currently in use by another app.")
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
