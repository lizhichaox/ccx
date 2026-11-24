import AppKit
import CCXCore
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions = 1
    case ready = 2
}

enum OnboardingAnchor: Equatable, Sendable {
    case belowMenuBar(NSRect)
    case centeredOnWindow(NSRect)
    case centeredOnActiveScreen
}

@MainActor
final class OnboardingFlowState: ObservableObject {
    static let springAnimation = Animation.spring(response: 0.30, dampingFraction: 0.86)

    @Published var step: OnboardingStep = .welcome
    @Published var requestedScreenRecording = false
    @Published var swipeOffset: CGFloat = 0
    @Published var snipCombo: HotKeyCombo = .defaultSnip

    func goNext() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func goPrevious() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }
}

private struct SendableEventMonitorBox: @unchecked Sendable {
    let monitor: Any
}

/// Hosts the compact 3-page Guide & Permissions flow with native horizontal swipe paging.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static let windowSize = NSSize(width: 464, height: 344)

    private enum GestureAxis {
        case horizontal
        case vertical
    }

    private let model = PermissionStatusModel()
    private let flow = OnboardingFlowState()
    private let onComplete: () -> Void
    private let onTrySnip: () -> Void
    private var window: NSWindow?

    nonisolated(unsafe) private var eventMonitor: Any?
    private var accumulatedScrollX: CGFloat = 0
    private var accumulatedScrollY: CGFloat = 0
    private var lastHorizontalDelta: CGFloat = 0
    private var activeAxis: GestureAxis?
    private var lastDiscreteSwipeTime: TimeInterval = 0

    init(
        snipCombo: HotKeyCombo = .defaultSnip,
        onComplete: @escaping () -> Void,
        onTrySnip: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        self.onTrySnip = onTrySnip
        super.init()
        self.flow.snipCombo = snipCombo
    }

    func updateSnipCombo(_ combo: HotKeyCombo) {
        if flow.snipCombo != combo {
            flow.snipCombo = combo
        }
    }

    deinit {
        if let eventMonitor {
            let box = SendableEventMonitorBox(monitor: eventMonitor)
            if Thread.isMainThread {
                NSEvent.removeMonitor(box.monitor)
            } else {
                DispatchQueue.main.async {
                    NSEvent.removeMonitor(box.monitor)
                }
            }
        }
    }

    func show(startingAt step: OnboardingStep = .welcome, anchor: OnboardingAnchor = .centeredOnActiveScreen) {
        flow.swipeOffset = 0
        flow.step = step

        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        model.startPolling()

        let targetScreen = Self.targetScreen(for: anchor)
        let currentScreen = window.screen ?? WindowScreenLocator.screen(for: window.frame)
        let isOnDifferentScreen = targetScreen != nil && !WindowScreenLocator.isSameScreen(currentScreen, targetScreen)
        if !window.isVisible || isOnDifferentScreen {
            position(window: window, anchor: anchor, targetScreen: targetScreen)
        }
        installEventMonitor()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(
            model: model,
            flow: flow,
            onDone: { [weak self] in
                self?.onComplete()
                self?.window?.close()
            },
            onTrySnip: { [weak self] in
                self?.onComplete()
                self?.window?.orderOut(nil)
                self?.model.stopPolling()
                self?.removeEventMonitor()
                self?.onTrySnip()
            }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.safeAreaRegions = []
        let window = DismissibleWindow(contentViewController: hosting)
        window.title = "CCX"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.windowSize)
        return window
    }

    private static func targetScreen(for anchor: OnboardingAnchor) -> NSScreen? {
        switch anchor {
        case .belowMenuBar(let anchorRect):
            WindowScreenLocator.screen(for: anchorRect)
        case .centeredOnWindow(let parentFrame):
            WindowScreenLocator.screen(for: parentFrame)
        case .centeredOnActiveScreen:
            WindowScreenLocator.activeCursorScreen()
        }
    }

    private func position(window: NSWindow, anchor: OnboardingAnchor, targetScreen: NSScreen?) {
        let size = window.frame.size
        let screen = targetScreen ?? Self.targetScreen(for: anchor)

        var origin: NSPoint
        switch anchor {
        case .belowMenuBar(let anchorRect):
            origin = NSPoint(
                x: (anchorRect.midX - size.width / 2).rounded(),
                y: (anchorRect.minY - 6 - size.height).rounded()
            )
        case .centeredOnWindow(let parentFrame):
            origin = NSPoint(
                x: (parentFrame.midX - size.width / 2).rounded(),
                y: (parentFrame.midY - size.height / 2).rounded()
            )
        case .centeredOnActiveScreen:
            guard let visibleFrame = screen?.visibleFrame else {
                window.center()
                return
            }
            origin = NSPoint(
                x: (visibleFrame.midX - size.width / 2).rounded(),
                y: (visibleFrame.midY - size.height / 2).rounded()
            )
        }

        if let visibleFrame = screen?.visibleFrame {
            origin = WindowScreenLocator.clampOrigin(origin, windowSize: size, to: visibleFrame)
        }

        window.setFrame(NSRect(origin: origin, size: size), display: window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        if flow.step == .ready || model.status.screenRecording {
            onComplete()
        }
        model.stopPolling()
        removeEventMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        withAnimation(OnboardingFlowState.springAnimation) {
            resetSwipeTracking()
        }
    }

    // MARK: - Swipe & Keyboard Navigation

    private func matchesWindow(windowNumber: Int, mouseLocation: NSPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        return windowNumber == window.windowNumber || (windowNumber == 0 && window.frame.contains(mouseLocation))
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .keyDown]) { [weak self] event in
            let windowNumber = event.windowNumber
            let mouseLocation = NSEvent.mouseLocation

            switch event.type {
            case .scrollWheel:
                let phase = event.phase
                let momentumPhase = event.momentumPhase
                let precise = event.hasPreciseScrollingDeltas
                let scrollDeltaX = event.scrollingDeltaX
                let scrollDeltaY = event.scrollingDeltaY
                let timestamp = event.timestamp
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.matchesWindow(windowNumber: windowNumber, mouseLocation: mouseLocation) else {
                        return false
                    }
                    return self.handleScrollWheel(
                        phase: phase,
                        momentumPhase: momentumPhase,
                        hasPreciseDeltas: precise,
                        deltaX: scrollDeltaX,
                        deltaY: scrollDeltaY,
                        timestamp: timestamp
                    )
                }
                return consumed ? nil : event

            case .swipe:
                let swipeDeltaX = event.deltaX
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.matchesWindow(windowNumber: windowNumber, mouseLocation: mouseLocation) else {
                        return false
                    }
                    return self.handleSwipeGesture(deltaX: swipeDeltaX)
                }
                return consumed ? nil : event

            case .keyDown:
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .numericPad, .function])
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.matchesWindow(windowNumber: windowNumber, mouseLocation: mouseLocation) else {
                        return false
                    }
                    guard modifiers.intersection([.command, .option, .control]).isEmpty else { return false }
                    if keyCode == 123 {
                        withAnimation(OnboardingFlowState.springAnimation) { self.flow.goPrevious() }
                        return true
                    }
                    if keyCode == 124 {
                        withAnimation(OnboardingFlowState.springAnimation) { self.flow.goNext() }
                        return true
                    }
                    return false
                }
                return consumed ? nil : event

            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        resetSwipeTracking()
    }

    private func resetSwipeTracking() {
        accumulatedScrollX = 0
        accumulatedScrollY = 0
        lastHorizontalDelta = 0
        activeAxis = nil
        if flow.swipeOffset != 0 { flow.swipeOffset = 0 }
    }

    private func handleSwipeGesture(deltaX: CGFloat) -> Bool {
        if deltaX < 0 {
            withAnimation(OnboardingFlowState.springAnimation) { flow.goNext() }
            return true
        }
        if deltaX > 0 {
            withAnimation(OnboardingFlowState.springAnimation) { flow.goPrevious() }
            return true
        }
        return false
    }

    private func handleScrollWheel(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        hasPreciseDeltas: Bool,
        deltaX: CGFloat,
        deltaY: CGFloat,
        timestamp: TimeInterval
    ) -> Bool {
        guard momentumPhase.isEmpty else { return false }

        if hasPreciseDeltas && !phase.isEmpty {
            if phase.contains(.mayBegin) || phase.contains(.began) {
                accumulatedScrollX = 0
                accumulatedScrollY = 0
                lastHorizontalDelta = 0
                activeAxis = nil
            }

            if phase.contains(.began) || phase.contains(.changed) {
                accumulatedScrollX += deltaX
                accumulatedScrollY += deltaY
                if deltaX != 0 {
                    lastHorizontalDelta = deltaX
                }

                if activeAxis == nil, abs(accumulatedScrollX) + abs(accumulatedScrollY) >= 2.5 {
                    activeAxis = abs(accumulatedScrollX) >= abs(accumulatedScrollY) ? .horizontal : .vertical
                }

                if activeAxis == .horizontal {
                    let atStartBoundary = flow.step == .welcome && accumulatedScrollX > 0
                    let atEndBoundary = flow.step == .ready && accumulatedScrollX < 0
                    if atStartBoundary || atEndBoundary {
                        flow.swipeOffset = min(max(accumulatedScrollX * 0.25, -48), 48)
                    } else {
                        let limit = Self.windowSize.width * 0.85
                        flow.swipeOffset = min(max(accumulatedScrollX, -limit), limit)
                    }
                    return true
                }
                return false
            }

            if phase.contains(.ended) || phase.contains(.cancelled) {
                let wasHorizontal = activeAxis == .horizontal
                let totalX = accumulatedScrollX + deltaX
                let velocityX = deltaX != 0 ? deltaX : lastHorizontalDelta
                accumulatedScrollX = 0
                accumulatedScrollY = 0
                lastHorizontalDelta = 0
                activeAxis = nil

                guard wasHorizontal else { return false }
                withAnimation(OnboardingFlowState.springAnimation) {
                    if phase.contains(.ended) {
                        if totalX <= -28 || (totalX <= -12 && velocityX <= -4) {
                            flow.goNext()
                        } else if totalX >= 28 || (totalX >= 12 && velocityX >= 4) {
                            flow.goPrevious()
                        }
                    }
                    flow.swipeOffset = 0
                }
                return true
            }
            return false
        }

        // Discrete horizontal mouse wheel / Magic Mouse flick without gesture phases.
        guard abs(deltaX) > abs(deltaY), abs(deltaX) >= 2 else { return false }
        guard timestamp - lastDiscreteSwipeTime >= 0.28 else { return true }
        lastDiscreteSwipeTime = timestamp
        withAnimation(OnboardingFlowState.springAnimation) {
            if deltaX < 0 {
                flow.goNext()
            } else {
                flow.goPrevious()
            }
        }
        return true
    }
}

/// Relaunches CCX so macOS applies a freshly granted Screen Recording permission.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: bundleURL.path)
        else {
            NSSound.beep()
            return
        }

        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit (bounded to 5s) before reopening via LaunchServices,
        // avoiding both premature hotkey collisions and blind sleep races.
        process.arguments = [
            "-c",
            "pid=$1; app=$2; i=0; while kill -0 \"$pid\" 2>/dev/null && [ $i -lt 50 ]; do /bin/sleep 0.1; i=$((i+1)); done; exec /usr/bin/open -- \"$app\"",
            "ccx-relaunch",
            pid,
            bundleURL.path,
        ]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Root Guide Pager

private struct OnboardingView: View {
    @ObservedObject var model: PermissionStatusModel
    @ObservedObject var flow: OnboardingFlowState
    let onDone: () -> Void
    let onTrySnip: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.12),
                    Color.indigo.opacity(0.04),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                GeometryReader { proxy in
                    let pageWidth = max(proxy.size.width, 1)
                    HStack(spacing: 0) {
                        WelcomeStepView()
                            .padding(.horizontal, 20)
                            .padding(.top, 28)
                            .padding(.bottom, 12)
                            .frame(width: pageWidth, height: proxy.size.height)

                        PermissionsStepView(model: model, flow: flow)
                            .padding(.horizontal, 20)
                            .padding(.top, 28)
                            .padding(.bottom, 12)
                            .frame(width: pageWidth, height: proxy.size.height)

                        ReadyStepView(flow: flow)
                            .padding(.horizontal, 20)
                            .padding(.top, 28)
                            .padding(.bottom, 12)
                            .frame(width: pageWidth, height: proxy.size.height)
                    }
                    .offset(x: -CGFloat(flow.step.rawValue) * pageWidth + flow.swipeOffset)
                }
                .clipped()

                Divider().opacity(0.6)

                OnboardingFooterBar(
                    model: model,
                    flow: flow,
                    onDone: onDone,
                    onTrySnip: onTrySnip
                )
                .padding(.horizontal, 18)
                .frame(height: 48)
            }
        }
        .frame(width: 464, height: 344)
    }
}

// MARK: - Step 1: Overview

private struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                CCXBrandIcon(size: 48)

                Text("Control · Command · X")
                    .font(.system(size: 16, weight: .bold))

                Text("Local captures & OCR · No accounts, no telemetry")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 8) {
                FeatureBentoCard(
                    symbol: "viewfinder",
                    tint: .blue,
                    title: "Smart Snip",
                    detail: "Detect, draw & OCR"
                )
                FeatureBentoCard(
                    symbol: "pin.fill",
                    tint: .indigo,
                    title: "Floating Pins",
                    detail: "Always on top"
                )
                FeatureBentoCard(
                    symbol: "record.circle.fill",
                    tint: .red,
                    title: "Screen Record",
                    detail: "MP4, MOV & GIF"
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
        VStack(alignment: .center, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))

            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .center)
        .ccxCardSurface(cornerRadius: 12)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStepView: View {
    @ObservedObject var model: PermissionStatusModel
    @ObservedObject var flow: OnboardingFlowState

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Text("Permissions")
                .font(.system(size: 16, weight: .bold))

            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    tint: .blue,
                    title: "Screen Recording",
                    detail: "Capture displays & pixels",
                    granted: model.status.screenRecording,
                    prominentAction: true,
                    isDisabled: model.isCheckingScreenRecording
                ) {
                    flow.requestedScreenRecording = true
                    model.allowScreenRecording()
                }

                Divider().padding(.leading, 46)

                PermissionRow(
                    symbol: "accessibility",
                    tint: .indigo,
                    title: "Accessibility",
                    detail: "Detect UI elements",
                    granted: model.status.accessibility,
                    prominentAction: false,
                    isDisabled: false
                ) {
                    model.allowAccessibility()
                }
            }
            .ccxCardSurface(cornerRadius: 12)

            if !model.status.screenRecording {
                ScreenRecordingHintStrip(
                    showRelaunch: flow.requestedScreenRecording,
                    isVerifying: model.isCheckingScreenRecording,
                    onVerify: { model.verifyScreenRecordingLive() }
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    let prominentAction: Bool
    let isDisabled: Bool
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(granted ? .green : tint)
                .frame(width: 28, height: 28)
                .background(
                    (granted ? Color.green : tint).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if granted {
                PermissionGrantedPill()
            } else if prominentAction {
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDisabled)
                    .fixedSize()
            } else {
                Button("Allow", action: onAllow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDisabled)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct PermissionGrantedPill: View {
    var body: some View {
        Label("Granted", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.green.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

private struct ScreenRecordingHintStrip: View {
    let showRelaunch: Bool
    let isVerifying: Bool
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Enable CCX in Settings, then relaunch.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            Button(isVerifying ? "Checking…" : "Verify", action: onVerify)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isVerifying)
                .fixedSize()

            if showRelaunch {
                Button("Relaunch") {
                    AppRelauncher.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Step 3: Shortcuts & Gestures

private struct ReadyStepView: View {
    @ObservedObject var flow: OnboardingFlowState

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)

                Text("All Set")
                    .font(.system(size: 16, weight: .bold))
            }

            VStack(spacing: 0) {
                GuideActionRow(
                    symbol: "viewfinder",
                    tint: .blue,
                    title: "Smart Snip",
                    trailing: { KeycapComboView(combo: flow.snipCombo) }
                )
                Divider().padding(.leading, 40)
                GuideActionRow(
                    symbol: "pin.fill",
                    tint: .indigo,
                    title: "Paste as Pin",
                    trailing: { InteractionPillView(text: "Menu Bar · Pin") }
                )
                Divider().padding(.leading, 40)
                GuideActionRow(
                    symbol: "text.viewfinder",
                    tint: .cyan,
                    title: "Annotate, OCR & Record",
                    trailing: { InteractionPillView(text: "1–8 · T · R") }
                )
            }
            .ccxCardSurface(cornerRadius: 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GuideActionRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 10)

            trailing()
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8.5)
    }
}

private struct InteractionPillView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 22)
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

struct KeycapComboView: View {
    let combo: HotKeyCombo

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(combo.tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, token.count > 1 ? 6 : 0)
                    .frame(minWidth: 24, minHeight: 24)
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
            HStack(spacing: 10) {
                if flow.step != .welcome {
                    Button("Back") {
                        withAnimation(OnboardingFlowState.springAnimation) {
                            flow.goPrevious()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize()
                }

                Spacer()

                HStack(spacing: 8) {
                    switch flow.step {
                    case .welcome:
                        Button("Get Started") {
                            withAnimation(OnboardingFlowState.springAnimation) {
                                flow.step = .permissions
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .fixedSize()

                    case .permissions:
                        if !model.status.screenRecording && flow.requestedScreenRecording {
                            Button("Relaunch") {
                                AppRelauncher.relaunch()
                            }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                        } else if model.status.screenRecording {
                            Button("Continue") {
                                withAnimation(OnboardingFlowState.springAnimation) {
                                    flow.step = .ready
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .fixedSize()
                        } else {
                            Button("Continue") {
                                withAnimation(OnboardingFlowState.springAnimation) {
                                    flow.step = .ready
                                }
                            }
                            .buttonStyle(.bordered)
                            .fixedSize()
                        }

                    case .ready:
                        Button("Done", action: onDone)
                            .buttonStyle(.bordered)
                            .fixedSize()

                        Button("Try Snip", action: onTrySnip)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .fixedSize()
                    }
                }
            }

            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    Button {
                        withAnimation(OnboardingFlowState.springAnimation) {
                            flow.step = step
                        }
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
    func ccxCardSurface(cornerRadius: CGFloat = 14) -> some View {
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

/// Appearance-adaptive CCX brand icon backed by `BrandIcon.imageset`.
struct CCXBrandIcon: View {
    let size: CGFloat

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
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
