import AppKit
import CPXCore
import SwiftUI

/// Hosts the Settings window: global hotkeys, permission status, and version.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    typealias ComboProvider = (CPXHotKeyAction) -> HotKeyCombo
    typealias ComboUpdater = (CPXHotKeyAction, HotKeyCombo) -> Bool

    private let permissions = PermissionStatusModel()
    private let currentCombo: ComboProvider
    private let updateCombo: ComboUpdater
    private var window: NSWindow?

    init(currentCombo: @escaping ComboProvider, updateCombo: @escaping ComboUpdater) {
        self.currentCombo = currentCombo
        self.updateCombo = updateCombo
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
        let view = SettingsView(
            permissions: permissions,
            currentCombo: currentCombo,
            updateCombo: updateCombo
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "CPX Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        permissions.stopPolling()
    }
}

private struct SettingsView: View {
    @ObservedObject var permissions: PermissionStatusModel
    let currentCombo: SettingsWindowController.ComboProvider
    let updateCombo: SettingsWindowController.ComboUpdater

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader()
                .padding([.horizontal, .top], 20)

            Form {
                Section {
                    ForEach(CPXHotKeyAction.allCases, id: \.self) { action in
                        HotKeyRow(
                            action: action,
                            initialCombo: currentCombo(action),
                            updateCombo: updateCombo
                        )
                    }
                } header: {
                    Text("Global Hotkeys")
                } footer: {
                    Text("Hotkeys work system-wide, even when CPX is in the background.")
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    LabeledContent("Screen Recording") {
                        HStack {
                            PermissionBadge(granted: permissions.status.screenRecording)
                            Button("Open…", action: permissions.openScreenRecordingSettings)
                        }
                    }
                    LabeledContent("Accessibility") {
                        HStack {
                            PermissionBadge(granted: permissions.status.accessibility)
                            Button("Open…", action: permissions.openAccessibilitySettings)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: AppVersion.shortDisplay)
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "com.lizhichaox.cpx")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 560)
    }
}

/// Picker row for one hotkey action. Reverts the selection when registration
/// fails (for example, when another app already owns the combo).
private struct HotKeyRow: View {
    let action: CPXHotKeyAction
    let updateCombo: SettingsWindowController.ComboUpdater
    private let options: [HotKeyCombo]

    @State private var selection: HotKeyCombo
    @State private var committed: HotKeyCombo
    @State private var failed = false

    init(action: CPXHotKeyAction, initialCombo: HotKeyCombo, updateCombo: @escaping SettingsWindowController.ComboUpdater) {
        self.action = action
        self.updateCombo = updateCombo
        var options = HotKeyPreferences.presets(for: action)
        if !options.contains(initialCombo) {
            options.append(initialCombo)
        }
        self.options = options
        _selection = State(initialValue: initialCombo)
        _committed = State(initialValue: initialCombo)
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { combo in
                Text(combo.displayString).tag(combo)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.cpxMenuTitle)
                if failed {
                    Text("That shortcut is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            guard newValue != committed else { return }
            if updateCombo(action, newValue) {
                committed = newValue
                failed = false
            } else {
                failed = true
                selection = committed
            }
        }
    }
}

private struct SettingsHeader: View {
    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("CPX").font(.title3.weight(.semibold))
                Text("Capture · Paste · X — \(AppVersion.display)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)

        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
