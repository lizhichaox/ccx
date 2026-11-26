import AppKit
import CCXAnnotate
import CCXCore
import os
import OSLog
import ScreenCaptureKit

/// Entry point for an interactive snip session (freeze screens -> select -> act).
@MainActor
public final class SnipCoordinator {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "SnipCoordinator")

    private var overlay: SnipOverlayController?
    private var scrollController: ScrollCaptureController?
    private var captureTask: Task<Void, Never>?
    private var completion: (@MainActor (SnipOutcome) -> Void)?
    private var lastAnnotationStyle = AnnotationStyle()
    private var lastSelectionByDisplay: [CGDirectDisplayID: CGRect] = [:]

    /// Whether a snip session is currently capturing or showing its overlay.
    public private(set) var isSessionActive = false

    public init() {}

    /// Freezes all displays and presents the selection overlay.
    ///
    /// `completion` is called exactly once on the main actor. Calling this while a session is
    /// active is ignored.
    public func startSnip(
        mode: SnipSelectionMode = .snip,
        completion: @escaping @MainActor (SnipOutcome) -> Void
    ) {
        guard !isSessionActive else { return }
        isSessionActive = true
        self.completion = completion

        // Capture screen geometry once on @MainActor so ScreenSnapshotEngine and SmartElementDetector
        // share identical display frames and primaryScreenHeight, before overlays appear.
        let geometries = ScreenSnapshotEngine.currentScreenGeometries()
        let detector = SmartElementDetector()
        detector.refreshWindowList(screenFrames: geometries.values.map(\.frame))

        captureTask = Task { [weak self] in
            let overlayPrepTask = Task { @MainActor in
                await detector.prepareOverlayElements()
            }
            defer { overlayPrepTask.cancel() }
            do {
                let session = try await ScreenSnapshotEngine.captureSession(
                    geometries: geometries,
                    includeShareableWindows: mode == .snip
                )
                // Bound waiting on overlay AX pre-capture so a hung WidgetKit XPC can never stall snip launch.
                let prepCompleted = await Self.awaitTask(overlayPrepTask, timeoutNanoseconds: 160_000_000)
                if !prepCompleted {
                    detector.finalizePendingOverlayFallbackIfNeeded()
                }
                guard let self, self.isSessionActive, !Task.isCancelled else { return }
                PermissionManager.setScreenRecordingVerified(true)
                self.presentOverlay(
                    snapshots: session.snapshots,
                    detector: detector,
                    shareableWindows: session.shareableWindows,
                    selectionMode: mode
                )
            } catch {
                guard let self, !Task.isCancelled else { return }
                if ScreenSnapshotEngine.isPermissionDeniedError(error) {
                    PermissionManager.setScreenRecordingVerified(false)
                    Self.logger.error("ScreenCaptureKit permission denied: \(error.localizedDescription)")
                    self.finish(.permissionDenied)
                } else {
                    Self.logger.error("Snapshot failed: \(error.localizedDescription)")
                    self.finish(.failed(ScreenSnapshotEngine.userFacingErrorMessage(for: error)))
                }
            }
        }
    }

    private struct TimeoutWaitState: Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        var timerTask: Task<Void, Never>?
        var waitTask: Task<Void, Never>?
        var isResolved = false
    }

    /// Races an unstructured `Task` against a wall-clock timeout and caller cancellation.
    /// Returns `true` if `task` finished before timeout; otherwise cancels `task` and returns `false` promptly.
    internal nonisolated static func awaitTask(
        _ task: Task<Void, Never>,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        if Task.isCancelled {
            task.cancel()
            return false
        }
        let state = OSAllocatedUnfairLock(initialState: TimeoutWaitState())

        @Sendable func resolve(_ completed: Bool) {
            let pending = state.withLock { s -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
                guard !s.isResolved else { return (nil, nil, nil) }
                s.isResolved = true
                let cont = s.continuation
                let timer = s.timerTask
                let wait = s.waitTask
                s.continuation = nil
                s.timerTask = nil
                s.waitTask = nil
                return (cont, timer, wait)
            }
            pending.1?.cancel()
            pending.2?.cancel()
            if !completed {
                task.cancel()
            }
            pending.0?.resume(returning: completed)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyResolved = state.withLock { s -> Bool in
                    guard !s.isResolved else { return true }
                    s.continuation = continuation
                    return false
                }
                if alreadyResolved {
                    continuation.resume(returning: false)
                    return
                }
                let timerTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    resolve(false)
                }
                let waitTask = Task {
                    await task.value
                    resolve(true)
                }
                let tasksToCancel = state.withLock { s -> (Task<Void, Never>?, Task<Void, Never>?) in
                    if s.isResolved {
                        return (timerTask, waitTask)
                    }
                    s.timerTask = timerTask
                    s.waitTask = waitTask
                    return (nil, nil)
                }
                tasksToCancel.0?.cancel()
                tasksToCancel.1?.cancel()
            }
        } onCancel: {
            resolve(false)
        }
    }

    /// Cancels the active session (if any) and reports `.cancelled`.
    public func cancelActiveSnip() {
        guard isSessionActive else { return }
        finish(.cancelled)
    }

    /// Clears remembered per-display selection bounds so prior regions cannot be recalled.
    public func clearLastSelections() {
        lastSelectionByDisplay.removeAll()
    }

    private func presentOverlay(
        snapshots: [DisplaySnapshot],
        detector: SmartElementDetector,
        shareableWindows: [CGWindowID: UncheckedSendableBox<SCWindow>],
        selectionMode: SnipSelectionMode
    ) {
        captureTask = nil
        let controller = SnipOverlayController(
            snapshots: snapshots,
            detector: detector,
            shareableWindows: shareableWindows,
            selectionMode: selectionMode,
            initialStyle: lastAnnotationStyle,
            previousSelections: lastSelectionByDisplay,
            onStyleUpdated: { [weak self] style in
                self?.lastAnnotationStyle = style
            },
            onSelectionCommitted: { [weak self] displayID, rect in
                self?.lastSelectionByDisplay[displayID] = rect
            },
            onRequestScrollCapture: { [weak self] request in
                self?.beginScrollCapture(request)
            },
            onFinish: { [weak self] outcome in
                self?.finish(outcome)
            }
        )
        overlay = controller
        controller.show()
    }

    private func beginScrollCapture(_ request: ScrollCaptureRequest) {
        guard isSessionActive else { return }
        overlay = nil
        let controller = ScrollCaptureController(request: request) { [weak self] outcome in
            self?.finish(outcome)
        }
        scrollController = controller
        controller.start()
    }

    private func finish(_ outcome: SnipOutcome) {
        guard isSessionActive else { return }
        isSessionActive = false
        captureTask?.cancel()
        captureTask = nil
        overlay?.close()
        overlay = nil
        scrollController?.cancel()
        scrollController = nil
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }
}
