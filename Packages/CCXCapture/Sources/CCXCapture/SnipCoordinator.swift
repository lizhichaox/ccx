import AppKit
import CCXAnnotate
import CCXCore
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
                let session = try await ScreenSnapshotEngine.captureSession(geometries: geometries)
                // Bound waiting on overlay AX pre-capture so a hung WidgetKit XPC can never stall snip launch.
                await Self.awaitWithTimeout(nanoseconds: 160_000_000) {
                    await overlayPrepTask.value
                }
                overlayPrepTask.cancel()
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

    private static func awaitWithTimeout(
        nanoseconds: UInt64,
        operation: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
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
