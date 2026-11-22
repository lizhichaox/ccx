import AppKit
import SwiftUI

/// Hosts the first-run permissions guide.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model = PermissionStatusModel()
    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        model.startPolling()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(model: model) { [weak self] in
            self?.window?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to CPX"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}

/// Relaunches CPX so macOS applies a freshly granted Screen Recording permission.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then reopen the bundle via LaunchServices.
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: PermissionStatusModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to CPX")
                        .font(.title2.weight(.semibold))
                    Text("Capture, pin, and record your screen. CPX needs two permissions to work.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Required to snip, pin, and record the screen.",
                    symbol: "rectangle.dashed.badge.record",
                    granted: model.status.screenRecording,
                    grant: model.requestScreenRecording,
                    openSettings: model.openScreenRecordingSettings
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Optional. Detects UI elements under the cursor while snipping.",
                    symbol: "accessibility",
                    granted: model.status.accessibility,
                    grant: model.requestAccessibility,
                    openSettings: model.openAccessibilitySettings
                )
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                Text("After enabling Screen Recording, quit and relaunch CPX. macOS applies this permission only when an app starts.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                Spacer()
                Button("Quit & Relaunch CPX") {
                    AppRelauncher.relaunch()
                }
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let grant: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PermissionBadge(granted: granted)
            if !granted {
                Button("Grant…", action: grant)
            }
            Button("Open System Settings", action: openSettings)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Green check / orange warning label for a permission state.
struct PermissionBadge: View {
    let granted: Bool

    var body: some View {
        Label(
            granted ? "Granted" : "Not Granted",
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .foregroundStyle(granted ? Color.green : Color.orange)
    }
}
