import AppKit
import CCXAnnotate
import CCXCore
import OSLog

/// Entry point for an interactive snip session (freeze screens -> select -> act).
@MainActor
public final class SnipCoordinator {
    private static let logger = Logger(subsystem: "com.lizhichaox.ccx", category: "SnipCoordinator")

    private var overlay: SnipOverlayController?
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
    public func startSnip(completion: @escaping @MainActor (SnipOutcome) -> Void) {
        guard !isSessionActive else { return }
        isSessionActive = true
        self.completion = completion

        // Tier 1 window metadata and snapshots are read before overlays appear so all visible
        // windows (including CCX's own guide, settings, and pins) are captured while overlays never show up.
        let detector = SmartElementDetector()
        detector.refreshWindowList()

        captureTask = Task { [weak self] in
            do {
                let snapshots = try await ScreenSnapshotEngine.captureAllDisplays()
                guard let self, self.isSessionActive, !Task.isCancelled else { return }
                PermissionManager.setScreenRecordingVerified(true)
                self.presentOverlay(snapshots: snapshots, detector: detector)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if ScreenSnapshotEngine.isPermissionDeniedError(error) {
                    PermissionManager.setScreenRecordingVerified(false)
                    Self.logger.error("ScreenCaptureKit permission denied: \(error.localizedDescription)")
                    self.finish(.permissionDenied)
                } else {
                    Self.logger.error("Snapshot failed: \(error.localizedDescription)")
                    self.finish(.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Cancels the active session (if any) and reports `.cancelled`.
    public func cancelActiveSnip() {
        guard isSessionActive else { return }
        finish(.cancelled)
    }

    private func presentOverlay(snapshots: [DisplaySnapshot], detector: SmartElementDetector) {
        captureTask = nil
        let controller = SnipOverlayController(
            snapshots: snapshots,
            detector: detector,
            initialStyle: lastAnnotationStyle,
            previousSelections: lastSelectionByDisplay,
            onStyleUpdated: { [weak self] style in
                self?.lastAnnotationStyle = style
            },
            onSelectionCommitted: { [weak self] displayID, rect in
                self?.lastSelectionByDisplay[displayID] = rect
            },
            onFinish: { [weak self] outcome in
                self?.finish(outcome)
            }
        )
        overlay = controller
        controller.show()
    }

    private func finish(_ outcome: SnipOutcome) {
        guard isSessionActive else { return }
        isSessionActive = false
        captureTask?.cancel()
        captureTask = nil
        overlay?.close()
        overlay = nil
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }
}
