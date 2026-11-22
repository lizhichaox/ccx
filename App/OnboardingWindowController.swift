import AppKit
import CPXCore
import ServiceManagement
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case ready = 2
}

@MainActor
final class OnboardingFlowState: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var requestedScreenRecording = false
}

/// Hosts the 3-step first-run guide: Welcome, Permissions, and Ready.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model = PermissionStatusModel()
    private let flow = OnboardingFlowState()
    private let currentCombo: (CPXHotKeyAction) -> HotKeyCombo
    private let onComplete: () -> Void
    private let onTrySnip: () -> Void
    private let onOpenSettings: () -> Void
    private var window: NSWindow?

    init(
        currentCombo: @escaping (CPXHotKeyAction) -> HotKeyCombo,
        onComplete: @escaping () -> Void,
        onTrySnip: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.currentCombo = currentCombo
        self.onComplete = onComplete
        self.onTrySnip = onTrySnip
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func show(startingAt step: OnboardingStep = .welcome) {
        flow.step = step
        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        model.startPolling()
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(
            model: model,
            flow: flow,
            currentCombo: currentCombo,
            onDone: { [weak self] in
                self?.onComplete()
                self?.window?.close()
            },
            onTrySnip: { [weak self] in
                self?.onComplete()
                self?.window?.orderOut(nil)
                self?.model.stopPolling()
                self?.onTrySnip()
            },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
            }
        )
        let window = DismissibleWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "CPX"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 580, height: 420))
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

// MARK: - Root Onboarding View

private struct OnboardingView: View {
    @ObservedObject var model: PermissionStatusModel
    @ObservedObject var flow: OnboardingFlowState
    let currentCombo: (CPXHotKeyAction) -> HotKeyCombo
    let onDone: () -> Void
    let onTrySnip: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.14),
                    Color.indigo.opacity(0.05),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Group {
                    switch flow.step {
                    case .welcome:
                        WelcomeStepView()
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    case .permissions:
                        PermissionsStepView(model: model, flow: flow)
                            .transition(.opacity)
                    case .ready:
                        ReadyStepView(
                            currentCombo: currentCombo,
                            onOpenSettings: onOpenSettings
                        )
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 14)

                Divider()

                OnboardingFooterBar(
                    model: model,
                    flow: flow,
                    onDone: onDone,
                    onTrySnip: onTrySnip
                )
                .padding(.horizontal, 24)
                .frame(height: 54)
            }
        }
        .frame(width: 580, height: 420)
        .animation(.spring(duration: 0.25), value: flow.step)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 78, height: 78)

                VStack(spacing: 4) {
                    Text("Welcome to CPX")
                        .font(.system(size: 24, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Capture, pin, and record your screen at native macOS speed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                FeatureBentoCard(
                    symbol: "viewfinder",
                    tint: .blue,
                    title: "Smart Snip",
                    detail: "Auto-detect windows and UI elements with a pixel-accurate loupe."
                )
                FeatureBentoCard(
                    symbol: "pin.fill",
                    tint: .indigo,
                    title: "Floating Pins",
                    detail: "Keep snips, colors, and clipboard notes floating across Spaces."
                )
                FeatureBentoCard(
                    symbol: "bolt.fill",
                    tint: .teal,
                    title: "Built for macOS",
                    detail: "ScreenCaptureKit + Retina native speed, zero telemetry."
                )
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

private struct FeatureBentoCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .cpxCardSurface(cornerRadius: 14)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStepView: View {
    @ObservedObject var model: PermissionStatusModel
    @ObservedObject var flow: OnboardingFlowState

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            VStack(alignment: .center, spacing: 4) {
                Text("Grant macOS Permissions")
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Everything runs locally on your Mac. Nothing leaves your device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                PermissionSetupCard(
                    symbol: "rectangle.dashed.badge.record",
                    tint: .blue,
                    title: "Screen & System Audio Recording",
                    badgeText: "Required",
                    badgeTint: .blue,
                    detail: "Needed to capture displays, windows, and color pixels cleanly.",
                    granted: model.status.screenRecording,
                    prominentAction: true,
                    onAllow: {
                        flow.requestedScreenRecording = true
                        model.allowScreenRecording()
                    },
                    extraFooter: {
                        if !model.status.screenRecording {
                            ScreenRecordingHintStrip(
                                showRelaunch: flow.requestedScreenRecording,
                                onVerify: {
                                    model.verifyScreenRecordingLive()
                                }
                            )
                        }
                    }
                )

                PermissionSetupCard(
                    symbol: "accessibility",
                    tint: .indigo,
                    title: "Accessibility",
                    badgeText: "Recommended",
                    badgeTint: .secondary,
                    detail: "Enables automatic detection of UI buttons, toolbars, and controls under your cursor.",
                    granted: model.status.accessibility,
                    prominentAction: false,
                    onAllow: {
                        model.allowAccessibility()
                    },
                    extraFooter: { EmptyView() }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionSetupCard<Footer: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let badgeText: String
    let badgeTint: Color
    let detail: String
    let granted: Bool
    let prominentAction: Bool
    let onAllow: () -> Void
    @ViewBuilder let extraFooter: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(granted ? .green : tint)
                    .frame(width: 36, height: 36)
                    .background(
                        (granted ? Color.green : tint).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)

                        if !granted {
                            Text(badgeText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(badgeTint)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(badgeTint.opacity(0.12), in: Capsule())
                                .fixedSize()
                        }
                    }

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if granted {
                    PermissionGrantedPill()
                        .fixedSize()
                } else if prominentAction {
                    Button("Allow Access", action: onAllow)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .fixedSize()
                } else {
                    Button("Allow Access", action: onAllow)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .fixedSize()
                }
            }

            extraFooter()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cpxCardSurface(cornerRadius: 14)
    }
}

private struct PermissionGrantedPill: View {
    var body: some View {
        Label("Granted", systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.14), in: Capsule())
    }
}

private struct ScreenRecordingHintStrip: View {
    let showRelaunch: Bool
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("CPX")
                    .font(.caption2.weight(.semibold))
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 24, height: 14)
                    Circle()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()

            Text("Enable CPX under Screen & System Audio Recording (top list, not System Audio Only), then relaunch CPX.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Verify", action: onVerify)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()

            if showRelaunch {
                Button("Relaunch Now") {
                    AppRelauncher.relaunch()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Step 3: Ready

private struct ReadyStepView: View {
    let currentCombo: (CPXHotKeyAction) -> HotKeyCombo
    let onOpenSettings: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            VStack(alignment: .center, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.green)

                    Text("You're All Set")
                        .font(.system(size: 20, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("CPX stays quietly in your menu bar. Here's how to use it:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                GuideActionRow(
                    symbol: "viewfinder",
                    title: "Smart Snip",
                    subtitle: "Capture windows, regions, or sample screen pixels",
                    trailing: { KeycapComboView(combo: currentCombo(.snip)) }
                )
                Divider().padding(.leading, 40)
                GuideActionRow(
                    symbol: "pin.fill",
                    title: "Paste as Pin",
                    subtitle: "Float your clipboard image, text, or HEX color on top",
                    trailing: { InteractionPillView(text: "Right-Click Icon") }
                )
                Divider().padding(.leading, 40)
                GuideActionRow(
                    symbol: "macwindow.on.rectangle",
                    title: "Manage Floating Pins",
                    subtitle: "Hide, close, or unlock click-through pins anytime",
                    trailing: { InteractionPillView(text: "Menu Bar") }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .cpxCardSurface(cornerRadius: 14)

            HStack {
                Toggle("Launch CPX at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in
                        applyLaunchAtLogin(enabled)
                    }

                Spacer()

                Button("Change Shortcut…", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .cpxCardSurface(cornerRadius: 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
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

private struct GuideActionRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            trailing()
                .fixedSize()
        }
        .padding(.vertical, 8)
    }
}

private struct InteractionPillView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct KeycapComboView: View {
    let combo: HotKeyCombo

    private var tokens: [String] {
        var result: [String] = []
        let display = combo.displayString
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var index = display.startIndex
        while index < display.endIndex, modifiers.contains(display[index]) {
            result.append(String(display[index]))
            index = display.index(after: index)
        }
        if index < display.endIndex {
            result.append(String(display[index...]))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 24, minHeight: 24)
                    .padding(.horizontal, token.count > 1 ? 7 : 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Footer Bar

private struct OnboardingFooterBar: View {
    @ObservedObject var model: PermissionStatusModel
    @ObservedObject var flow: OnboardingFlowState
    let onDone: () -> Void
    let onTrySnip: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                // Left: Back button
                if flow.step != .welcome {
                    Button("Back") {
                        if let previous = OnboardingStep(rawValue: flow.step.rawValue - 1) {
                            flow.step = previous
                        }
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                }

                Spacer()

                // Right: Primary & secondary navigation CTAs
                HStack(spacing: 10) {
                    switch flow.step {
                    case .welcome:
                        Button("Get Started") {
                            flow.step = .permissions
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .fixedSize()

                    case .permissions:
                        if model.status.screenRecording {
                            Button("Continue") {
                                flow.step = .ready
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .fixedSize()
                        } else {
                            Button("Skip for now") {
                                flow.step = .ready
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .fixedSize()

                            if flow.requestedScreenRecording {
                                Button("Relaunch CPX") {
                                    AppRelauncher.relaunch()
                                }
                                .buttonStyle(.borderedProminent)
                                .fixedSize()
                            } else {
                                Button("Continue") {
                                    flow.step = .ready
                                }
                                .buttonStyle(.bordered)
                                .fixedSize()
                            }
                        }

                    case .ready:
                        Button("Done", action: onDone)
                            .buttonStyle(.bordered)
                            .fixedSize()

                        Button("Try Snip Now", action: onTrySnip)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .fixedSize()
                    }
                }
            }

            // Center: Mathematically centered step indicator pills
            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Button {
                        flow.step = step
                    } label: {
                        Capsule()
                            .fill(flow.step == step ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: flow.step == step ? 20 : 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Step \(step.rawValue + 1)")
                }
            }
        }
    }
}

// MARK: - Surface Helper & Shared Badge

private extension View {
    @ViewBuilder
    func cpxCardSurface(cornerRadius: CGFloat = 14) -> some View {
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

/// Green check / orange warning label for a permission state (shared with Settings).
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
        .fixedSize()
    }
}
