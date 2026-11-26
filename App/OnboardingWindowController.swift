import AppKit
import CCXCore
import Darwin
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
    private let onRelaunch: () -> Void
    private let onPermissionReset: @MainActor (Bool) -> Void
    private var window: NSWindow?

    var onWindowVisibilityChanged: ((Bool) -> Void)?
    private(set) var isWindowVisible = false

    nonisolated(unsafe) private var eventMonitor: Any?
    private var accumulatedScrollX: CGFloat = 0
    private var accumulatedScrollY: CGFloat = 0
    private var lastHorizontalDelta: CGFloat = 0
    private var activeAxis: GestureAxis?
    private var lastDiscreteSwipeTime: TimeInterval = 0

    init(
        snipCombo: HotKeyCombo = .defaultSnip,
        onComplete: @escaping () -> Void,
        onTrySnip: @escaping () -> Void,
        onRelaunch: @escaping () -> Void = { _ = AppRelauncher.relaunch() },
        onPermissionReset: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.onComplete = onComplete
        self.onTrySnip = onTrySnip
        self.onRelaunch = onRelaunch
        self.onPermissionReset = onPermissionReset
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

    func show(
        startingAt step: OnboardingStep = .welcome,
        anchor: OnboardingAnchor = .centeredOnActiveScreen,
        detectedStaleScreenRecording: Bool = false
    ) {
        flow.swipeOffset = 0
        flow.step = step

        let window = self.window ?? makeWindow()
        self.window = window
        model.refresh()
        if detectedStaleScreenRecording {
            flow.requestedScreenRecording = true
            model.markSuspectedStaleScreenRecordingGrant()
        }
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
        if !isWindowVisible {
            isWindowVisible = true
            onWindowVisibilityChanged?(true)
        }
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
                guard let self else { return }
                self.onComplete()
                self.window?.orderOut(nil)
                self.model.stopPolling()
                self.removeEventMonitor()
                if self.isWindowVisible {
                    self.isWindowVisible = false
                    self.onWindowVisibilityChanged?(false)
                }
                self.onTrySnip()
            },
            onRelaunch: { [weak self] in
                self?.onRelaunch()
            },
            onPermissionReset: { [weak self] succeeded in
                self?.onPermissionReset(succeeded)
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
        if isWindowVisible {
            isWindowVisible = false
            onWindowVisibilityChanged?(false)
        }
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
    /// Returns the normalized path to the running `.app` bundle when it is a real, non-symlink
    /// directory and the process has a valid PID.
    static func validatedBundlePath() -> String? {
        var path = Bundle.main.bundleURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let normalizedURL = URL(fileURLWithPath: path, isDirectory: true)
        var st = stat()
        guard normalizedURL.pathExtension == "app",
              Darwin.lstat(path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              ProcessInfo.processInfo.processIdentifier > 1
        else {
            return nil
        }
        return path
    }

    /// Spawns the detached relaunch helper without calling `NSApp.terminate(nil)`.
    /// Call only once termination is confirmed (e.g. inside `applicationWillTerminate`).
    @discardableResult
    static func spawnRelaunchHelper() -> Bool {
        guard let path = validatedBundlePath() else {
            return false
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit (bounded to 5s) before reopening via LaunchServices,
        // exiting quietly if the process is still alive.
        process.arguments = [
            "-c",
            "pid=$1; app=$2; i=0; while /bin/kill -0 \"$pid\" 2>/dev/null && [ \"$i\" -lt 50 ]; do /bin/sleep 0.1; i=$((i+1)); done; if /bin/kill -0 \"$pid\" 2>/dev/null; then exit 0; fi; exec /usr/bin/open -- \"$app\"",
            "ccx-relaunch",
            String(pid),
            path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func relaunch() -> Bool {
        guard spawnRelaunchHelper() else {
            NSSound.beep()
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - Root Guide Pager

private struct OnboardingView: View {
    @ObservedObject var model: PermissionStatusModel
    @ObservedObject var flow: OnboardingFlowState
    let onDone: () -> Void
    let onTrySnip: () -> Void
    let onRelaunch: () -> Void
    let onPermissionReset: @MainActor (Bool) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    CCXBadgePalette.blue.topColor.opacity(0.14),
                    CCXBadgePalette.indigo.topColor.opacity(0.06),
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

                        PermissionsStepView(
                            model: model,
                            flow: flow,
                            onRelaunch: onRelaunch,
                            onPermissionReset: onPermissionReset
                        )
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
                    onTrySnip: onTrySnip,
                    onRelaunch: onRelaunch
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

                Text(CCXL10n.text(
                    "Local captures & OCR · No accounts, no telemetry",
                    zh: "本地截屏与 OCR · 无需账号，零遥测"
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 8) {
                FeatureBentoCard(
                    symbol: "viewfinder",
                    palette: .blue,
                    title: CCXL10n.text("Smart Snip", zh: "智能截屏"),
                    detail: CCXL10n.text("Detect, draw & OCR", zh: "识别、标注与 OCR")
                )
                FeatureBentoCard(
                    symbol: "pin.fill",
                    palette: .indigo,
                    title: CCXL10n.text("Floating Pins", zh: "悬浮贴图"),
                    detail: CCXL10n.text("Always on top", zh: "始终置顶显示")
                )
                FeatureBentoCard(
                    symbol: "record.circle.fill",
                    palette: .red,
                    title: CCXL10n.text("Screen Record", zh: "屏幕录制"),
                    detail: CCXL10n.text("MP4, MOV & GIF", zh: "MP4、MOV 与 GIF")
                )
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}

private struct FeatureBentoCard: View {
    let symbol: String
    let palette: CCXBadgePalette
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            CCXIconBadge(
                symbol: symbol,
                palette: palette,
                size: 28,
                cornerRadius: 8,
                symbolSize: 14
            )

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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.accentColor.opacity(0.055))
        )
        .ccxCardSurface(cornerRadius: 12, borderColor: palette.accentColor.opacity(0.20))
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStepView: View {
    @ObservedObject var model: PermissionStatusModel
    @ObservedObject var flow: OnboardingFlowState
    let onRelaunch: () -> Void
    let onPermissionReset: @MainActor (Bool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            Text(CCXL10n.text("Permissions", zh: "权限设置"))
                .font(.system(size: 16, weight: .bold))

            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    palette: .blue,
                    title: CCXL10n.text("Screen Recording", zh: "屏幕录制"),
                    detail: CCXL10n.text("Capture displays & pixels", zh: "用于截屏、取色与录屏"),
                    granted: model.status.screenRecording,
                    prominentAction: true,
                    isDisabled: model.isCheckingScreenRecording || model.isResettingScreenRecording
                ) {
                    flow.requestedScreenRecording = true
                    model.allowScreenRecording()
                }

                Divider().padding(.leading, 46)

                PermissionRow(
                    symbol: "accessibility",
                    palette: .indigo,
                    title: CCXL10n.text("Accessibility", zh: "辅助功能"),
                    detail: CCXL10n.text("Detect UI elements", zh: "自动识别窗口与界面元素"),
                    granted: model.status.accessibility,
                    prominentAction: false,
                    isDisabled: model.isResettingScreenRecording
                ) {
                    model.allowAccessibility()
                }
            }
            .ccxCardSurface(cornerRadius: 12)

            if !model.status.screenRecording {
                ScreenRecordingHintStrip(
                    showRelaunch: flow.requestedScreenRecording,
                    showReset: model.mayHaveStaleScreenRecordingGrant,
                    isVerifying: model.isCheckingScreenRecording,
                    isResetting: model.isResettingScreenRecording,
                    onReset: {
                        flow.requestedScreenRecording = true
                        model.resetAndReopenScreenRecording(onComplete: onPermissionReset)
                    },
                    onVerify: { model.verifyScreenRecordingLive() },
                    onRelaunch: onRelaunch
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let palette: CCXBadgePalette
    let title: String
    let detail: String
    let granted: Bool
    let prominentAction: Bool
    let isDisabled: Bool
    let onAllow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CCXIconBadge(
                symbol: symbol,
                palette: granted ? .green : palette,
                size: 28,
                cornerRadius: 7.5,
                symbolSize: 14
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
                Button(CCXL10n.text("Allow", zh: "授权"), action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDisabled)
                    .accessibilityLabel(CCXL10n.text("Allow \(title)", zh: "授权\(title)"))
                    .fixedSize()
            } else {
                Button(CCXL10n.text("Allow", zh: "授权"), action: onAllow)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDisabled)
                    .accessibilityLabel(CCXL10n.text("Allow \(title)", zh: "授权\(title)"))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct PermissionGrantedPill: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let green = CCXBadgePalette.green.labelColor(for: colorScheme)
        Label(CCXL10n.text("Granted", zh: "已授权"), systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(CCXBadgePalette.green.accentColor.opacity(0.14), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(CCXBadgePalette.green.accentColor.opacity(0.24), lineWidth: 0.75)
            )
            .fixedSize()
    }
}

private struct ScreenRecordingHintStrip: View {
    let showRelaunch: Bool
    let showReset: Bool
    let isVerifying: Bool
    let isResetting: Bool
    let onReset: () -> Void
    let onVerify: () -> Void
    let onRelaunch: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(
                showReset
                    ? PermissionManager.ScreenRecordingCopy.guideHintStale
                    : PermissionManager.ScreenRecordingCopy.guideHintDefault
            )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if showReset {
                Button(
                    isResetting
                        ? PermissionManager.ScreenRecordingCopy.resettingButtonTitle
                        : PermissionManager.ScreenRecordingCopy.resetButtonTitle,
                    action: onReset
                )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isVerifying || isResetting)
                    .help(PermissionManager.ScreenRecordingCopy.resetTooltip)
                    .fixedSize()
            }

            Button(
                isVerifying ? CCXL10n.text("Checking…", zh: "验证中…") : CCXL10n.text("Verify", zh: "验证"),
                action: onVerify
            )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isVerifying || isResetting)
                .fixedSize()

            if showRelaunch {
                Button(CCXL10n.text("Relaunch", zh: "重启"), action: onRelaunch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isResetting)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CCXBadgePalette.orange.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CCXBadgePalette.orange.accentColor.opacity(0.24), lineWidth: 0.75)
        )
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
                    .foregroundStyle(CCXBadgePalette.green.accentColor)

                Text(CCXL10n.text("All Set", zh: "准备就绪"))
                    .font(.system(size: 16, weight: .bold))
            }

            VStack(spacing: 0) {
                GuideActionRow(
                    symbol: "viewfinder",
                    palette: .blue,
                    title: CCXL10n.text("Smart Snip", zh: "智能截屏"),
                    trailing: { KeycapComboView(combo: flow.snipCombo) }
                )
                Divider().padding(.leading, 40)
                GuideActionRow(
                    symbol: "pin.fill",
                    palette: .indigo,
                    title: CCXL10n.text("Paste as Pin", zh: "粘贴为贴图"),
                    trailing: { InteractionPillView(text: CCXL10n.text("Menu Bar · Pin", zh: "菜单栏 · 贴图")) }
                )
                Divider().padding(.leading, 40)
                GuideActionRow(
                    symbol: "text.viewfinder",
                    palette: .teal,
                    title: CCXL10n.text("Annotate, OCR & Scroll", zh: "标注、OCR 与长截屏"),
                    trailing: { InteractionPillView(text: "1–8 · T · L") }
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
    let palette: CCXBadgePalette
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            CCXIconBadge(
                symbol: symbol,
                palette: palette,
                size: 24,
                cornerRadius: 6.5,
                symbolSize: 12.5
            )

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
    let onRelaunch: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                if flow.step != .welcome {
                    Button(CCXL10n.text("Back", zh: "上一步")) {
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
                        Button(CCXL10n.text("Get Started", zh: "开始使用")) {
                            withAnimation(OnboardingFlowState.springAnimation) {
                                flow.step = .permissions
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .fixedSize()

                    case .permissions:
                        if !model.status.screenRecording && flow.requestedScreenRecording {
                            Button(CCXL10n.text("Relaunch", zh: "重启"), action: onRelaunch)
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                        } else if model.status.screenRecording {
                            Button(CCXL10n.text("Continue", zh: "下一步")) {
                                withAnimation(OnboardingFlowState.springAnimation) {
                                    flow.step = .ready
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .fixedSize()
                        } else {
                            Button(CCXL10n.text("Continue", zh: "下一步")) {
                                withAnimation(OnboardingFlowState.springAnimation) {
                                    flow.step = .ready
                                }
                            }
                            .buttonStyle(.bordered)
                            .fixedSize()
                        }

                    case .ready:
                        Button(CCXL10n.text("Done", zh: "完成"), action: onDone)
                            .buttonStyle(.bordered)
                            .fixedSize()

                        Button(CCXL10n.text("Try Snip", zh: "立即截屏"), action: onTrySnip)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .fixedSize()
                    }
                }
            }

            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    let stepTitle: String = switch step {
                    case .welcome: CCXL10n.text("Overview", zh: "功能概览")
                    case .permissions: CCXL10n.text("Permissions", zh: "权限设置")
                    case .ready: CCXL10n.text("Shortcuts", zh: "快捷操作")
                    }
                    Button {
                        withAnimation(OnboardingFlowState.springAnimation) {
                            flow.step = step
                        }
                    } label: {
                        Capsule()
                            .fill(flow.step == step ? CCXBadgePalette.blue.accentColor : Color.primary.opacity(0.2))
                            .frame(width: flow.step == step ? 20 : 7, height: 7)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(stepTitle)
                    .accessibilityLabel(CCXL10n.text(
                        "Step \(step.rawValue + 1): \(stepTitle)",
                        zh: "第 \(step.rawValue + 1) 步：\(stepTitle)"
                    ))
                    .accessibilityAddTraits(flow.step == step ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Surface Helper & Shared Badge

private extension View {
    @ViewBuilder
    func ccxCardSurface(cornerRadius: CGFloat = 14, borderColor: Color = Color.primary.opacity(0.08)) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                .overlay(
                    shape
                        .strokeBorder(borderColor, lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .clipShape(shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(
                    shape
                        .strokeBorder(borderColor, lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .clipShape(shape)
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

/// Luminous Apple-calibrated accent pairs shared across Popover, Settings, and Setup Guide.
enum CCXBadgePalette: Sendable {
    case blue
    case indigo
    case red
    case orange
    case green
    case teal
    case pink

    var topColor: Color {
        switch self {
        case .blue: Color(red: 0.22, green: 0.66, blue: 1.00)
        case .indigo: Color(red: 0.56, green: 0.44, blue: 1.00)
        case .red: Color(red: 1.00, green: 0.38, blue: 0.34)
        case .orange: Color(red: 1.00, green: 0.66, blue: 0.18)
        case .green: Color(red: 0.24, green: 0.84, blue: 0.46)
        case .teal: Color(red: 0.18, green: 0.82, blue: 0.86)
        case .pink: Color(red: 1.00, green: 0.36, blue: 0.60)
        }
    }

    var bottomColor: Color {
        switch self {
        case .blue: Color(red: 0.04, green: 0.45, blue: 0.98)
        case .indigo: Color(red: 0.36, green: 0.28, blue: 0.92)
        case .red: Color(red: 0.92, green: 0.16, blue: 0.24)
        case .orange: Color(red: 0.96, green: 0.44, blue: 0.06)
        case .green: Color(red: 0.10, green: 0.68, blue: 0.32)
        case .teal: Color(red: 0.04, green: 0.62, blue: 0.78)
        case .pink: Color(red: 0.90, green: 0.16, blue: 0.44)
        }
    }

    var accentColor: Color {
        switch self {
        case .blue: Color(red: 0.06, green: 0.47, blue: 0.98)
        case .indigo: Color(red: 0.40, green: 0.31, blue: 0.94)
        case .red: Color(red: 0.94, green: 0.20, blue: 0.26)
        case .orange: Color(red: 0.96, green: 0.48, blue: 0.08)
        case .green: Color(red: 0.12, green: 0.70, blue: 0.34)
        case .teal: Color(red: 0.06, green: 0.65, blue: 0.80)
        case .pink: Color(red: 0.92, green: 0.20, blue: 0.48)
        }
    }

    func labelColor(for colorScheme: ColorScheme) -> Color {
        switch colorScheme {
        case .dark:
            switch self {
            case .blue: Color(red: 0.38, green: 0.74, blue: 1.00)
            case .indigo: Color(red: 0.66, green: 0.56, blue: 1.00)
            case .red: Color(red: 1.00, green: 0.44, blue: 0.42)
            case .orange: Color(red: 1.00, green: 0.70, blue: 0.26)
            case .green: Color(red: 0.30, green: 0.86, blue: 0.50)
            case .teal: Color(red: 0.26, green: 0.84, blue: 0.90)
            case .pink: Color(red: 1.00, green: 0.44, blue: 0.68)
            }
        default:
            accentColor
        }
    }
}

/// Crisp Apple System Settings–style saturated gradient rounded-square icon tile.
struct CCXIconBadge: View {
    let symbol: String
    let palette: CCXBadgePalette
    var size: CGFloat = 24
    var cornerRadius: CGFloat = 6.5
    var symbolSize: CGFloat = 12
    var isHighlighted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.14), radius: 0.75, y: 0.5)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [palette.topColor, palette.bottomColor],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isHighlighted ? 0.38 : 0.24), lineWidth: 0.75)
            )
            .shadow(
                color: palette.accentColor.opacity(isHighlighted ? 0.42 : 0.26),
                radius: isHighlighted ? 4.5 : 2.5,
                y: 1.5
            )
    }
}

/// Green check / orange warning label for a permission state (shared with Settings).
struct PermissionBadge: View {
    let granted: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(
            granted ? CCXL10n.text("Granted", zh: "已授权") : CCXL10n.text("Not Granted", zh: "未授权"),
            systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .foregroundStyle(
            granted
                ? CCXBadgePalette.green.labelColor(for: colorScheme)
                : CCXBadgePalette.orange.labelColor(for: colorScheme)
        )
        .fixedSize()
    }
}
