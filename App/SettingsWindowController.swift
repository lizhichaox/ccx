import AppKit
import CCXCore
import ServiceManagement
import SwiftUI

/// Hosts the compact, single-screen Settings window: shortcut, launch at login, and permissions.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let permissions = PermissionStatusModel()
    private var window: NSWindow?

    override init() {
        super.init()
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
        let view = SettingsView(permissions: permissions)
        let hosting = NSHostingController(rootView: view)
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
                    SnipShortcutRow()
                    Divider().padding(.leading, 42)
                    LaunchAtLoginRow()
                    Divider().padding(.leading, 42)
                    PermissionSettingRow(
                        symbol: "rectangle.dashed.badge.record",
                        tint: .orange,
                        title: "Screen Recording",
                        granted: permissions.status.screenRecording,
                        openAction: permissions.openScreenRecordingSettings
                    )
                    Divider().padding(.leading, 42)
                    PermissionSettingRow(
                        symbol: "accessibility",
                        tint: .indigo,
                        title: "Accessibility",
                        granted: permissions.status.accessibility,
                        openAction: permissions.openAccessibilitySettings
                    )
                }
                .ccxSettingsCard(cornerRadius: 12)

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
    private static let authorURL = URL(string: "https://lizhichao.com")!
    @State private var isHoveringAuthor = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Made By ")
                .foregroundStyle(.tertiary)

            Button {
                NSWorkspace.shared.open(Self.authorURL)
            } label: {
                Text("LIZHICHAO")
                    .fontWeight(.semibold)
                    .foregroundStyle(isHoveringAuthor ? Color.accentColor : Color.secondary)
                    .underline(isHoveringAuthor)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                guard hovering != isHoveringAuthor else { return }
                isHoveringAuthor = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHoveringAuthor {
                    isHoveringAuthor = false
                    NSCursor.pop()
                }
            }

            Text(" with ❤️.")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
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
    var body: some View {
        SettingsRow(symbol: "viewfinder", tint: .blue, title: "Snip Shortcut") {
            KeycapComboView(combo: .defaultSnip)
        }
    }
}

private struct LaunchAtLoginRow: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsRow(symbol: "power", tint: .teal, title: "Launch at Login") {
            Toggle("", isOn: $launchAtLogin)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: launchAtLogin) { _, enabled in
                    apply(enabled)
                }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
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
