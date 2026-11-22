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

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        permissions.refresh()
        permissions.startPolling()
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
        window.center()
        return window
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

            VStack(alignment: .leading, spacing: 14) {
                SettingsIdentityHeader()

                SettingsSection("GENERAL") {
                    SnipShortcutRow()
                    Divider().padding(.leading, 48)
                    LaunchAtLoginRow()
                }

                SettingsSection("PERMISSIONS") {
                    PermissionSettingRow(
                        symbol: "rectangle.dashed.badge.record",
                        tint: .orange,
                        title: "Screen Recording",
                        granted: permissions.status.screenRecording,
                        openAction: permissions.openScreenRecordingSettings
                    )
                    Divider().padding(.leading, 48)
                    PermissionSettingRow(
                        symbol: "accessibility",
                        tint: .indigo,
                        title: "Accessibility",
                        granted: permissions.status.accessibility,
                        openAction: permissions.openAccessibilitySettings
                    )
                }

                SettingsFooter()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
        .frame(width: 440)
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
        VStack(spacing: 6) {
            CCXBrandIcon(size: 56)

            VStack(spacing: 2) {
                Text("Control · Command · X")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("v\(AppVersion.shortDisplay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .ccxSettingsCard(cornerRadius: 12)
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)
                .font(.system(size: 13, weight: .medium))

            Spacer(minLength: 10)

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
            HStack(spacing: 8) {
                PermissionBadge(granted: granted)
                Button("Open…", action: openAction)
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
