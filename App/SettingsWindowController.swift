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
    private let onOpenGuide: () -> Void
    private let onClearHistory: () -> Void
    private var window: NSWindow?

    init(
        isSnipHotKeyRegistered: Bool = true,
        hasClearableHistory: Bool = false,
        onRetryHotKey: @escaping () -> Bool = { false },
        onOpenGuide: @escaping () -> Void = {},
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
        if !window.isVisible {
            position(window: window, anchoredTo: anchorRect)
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
                self?.onOpenGuide()
            },
            onClearHistory: { [weak self] in
                self?.onClearHistory()
            }
        )
        let hosting = NSHostingController(rootView: view)
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

    private func position(window: NSWindow, anchoredTo anchorRect: NSRect?) {
        let size = window.frame.size
        let screen = anchorRect.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.main

        var originX: CGFloat
        var originY: CGFloat
        if let anchorRect {
            originX = anchorRect.midX - size.width / 2
            originY = anchorRect.minY - 6 - size.height
        } else if let visibleFrame = screen?.visibleFrame {
            originX = visibleFrame.maxX - size.width - 12
            originY = visibleFrame.maxY - size.height - 8
        } else {
            window.center()
            return
        }

        if let visibleFrame = screen?.visibleFrame {
            let minX = visibleFrame.minX + 8
            let maxX = max(minX, visibleFrame.maxX - size.width - 8)
            let minY = visibleFrame.minY + 8
            let maxY = max(minY, visibleFrame.maxY - size.height - 6)
            originX = min(max(originX, minX), maxX)
            originY = min(max(originY, minY), maxY)
        }

        window.setFrameOrigin(NSPoint(x: originX, y: originY))
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
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 344)
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
        }
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
                    .padding(.leading, 43)
                    .padding(.trailing, 10)
                    .padding(.bottom, 7)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
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
