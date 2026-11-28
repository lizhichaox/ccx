@testable import CCXCore
import Foundation
import XCTest

@MainActor
final class ActivityArbiterTests: XCTestCase {
    func testIdleDefaultsAndTerminationVsSilentInstallPolicy() {
        let arbiter = ActivityArbiter()
        XCTAssertTrue(arbiter.canTerminateNow)
        XCTAssertTrue(arbiter.canInstallSilentlyNow)
        XCTAssertTrue(arbiter.activeKinds.isEmpty)

        for kind in ActivityKind.allCases {
            XCTAssertTrue(kind.blocksSilentInstall)
        }
        XCTAssertTrue(ActivityKind.recordingSession.blocksTermination)
        XCTAssertTrue(ActivityKind.savePanel.blocksTermination)
        XCTAssertTrue(ActivityKind.backgroundExport.blocksTermination)
        XCTAssertFalse(ActivityKind.snipSession.blocksTermination)
        XCTAssertFalse(ActivityKind.ocrTask.blocksTermination)
        XCTAssertFalse(ActivityKind.pin.blocksTermination)
        XCTAssertFalse(ActivityKind.menuBarPopover.blocksTermination)
        XCTAssertFalse(ActivityKind.settingsWindow.blocksTermination)
        XCTAssertFalse(ActivityKind.onboardingWindow.blocksTermination)

        let snipToken = arbiter.begin(.snipSession)
        XCTAssertTrue(arbiter.canTerminateNow)
        XCTAssertFalse(arbiter.canInstallSilentlyNow)
        snipToken.end()
        XCTAssertTrue(arbiter.canTerminateNow)
        XCTAssertTrue(arbiter.canInstallSilentlyNow)

        let exportToken = arbiter.begin(.backgroundExport)
        XCTAssertFalse(arbiter.canTerminateNow)
        XCTAssertFalse(arbiter.canInstallSilentlyNow)
        exportToken.end()
        XCTAssertTrue(arbiter.canTerminateNow)
        XCTAssertTrue(arbiter.canInstallSilentlyNow)
    }

    func testNestedTokensIdempotentEndAndDeduplicatedNotifications() {
        let arbiter = ActivityArbiter()
        var notifications = 0
        arbiter.onStateChanged = { notifications += 1 }

        let first = arbiter.begin(.backgroundExport)
        XCTAssertEqual(notifications, 1)
        let second = arbiter.begin(.backgroundExport)
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(arbiter.isActive(.backgroundExport))

        first.end()
        first.end() // Idempotent repeat call must not underflow ref-count.
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(arbiter.isActive(.backgroundExport))

        second.end()
        XCTAssertEqual(notifications, 2)
        XCTAssertFalse(arbiter.isActive(.backgroundExport))
        XCTAssertTrue(arbiter.canTerminateNow)
        XCTAssertTrue(arbiter.canInstallSilentlyNow)

        // Condition changes notify only when effective active state changes.
        arbiter.setCondition(.pin, active: false)
        XCTAssertEqual(notifications, 2)
        arbiter.setCondition(.pin, active: true)
        XCTAssertEqual(notifications, 3)
        arbiter.setCondition(.pin, active: true)
        XCTAssertEqual(notifications, 3)

        // Token + condition combined keep the kind active until both clear.
        let pinToken = arbiter.begin(.pin)
        XCTAssertEqual(notifications, 3)
        arbiter.setCondition(.pin, active: false)
        XCTAssertEqual(notifications, 3)
        XCTAssertTrue(arbiter.isActive(.pin))
        pinToken.end()
        XCTAssertEqual(notifications, 4)
        XCTAssertFalse(arbiter.isActive(.pin))
    }

    func testDeinitAutoReleasesOnMainActorAndBackgroundThread() async {
        let arbiter = ActivityArbiter()
        var notifications = 0
        arbiter.onStateChanged = { notifications += 1 }

        var scopedToken: ActivityToken? = arbiter.begin(.ocrTask)
        XCTAssertNotNil(scopedToken)
        XCTAssertTrue(arbiter.isActive(.ocrTask))
        XCTAssertEqual(notifications, 1)
        scopedToken = nil
        XCTAssertFalse(arbiter.isActive(.ocrTask))
        XCTAssertEqual(notifications, 2)

        let backgroundToken = arbiter.begin(.backgroundExport)
        XCTAssertFalse(arbiter.canTerminateNow)
        XCTAssertEqual(notifications, 3)

        await Task.detached(priority: .userInitiated) {
            backgroundToken.end()
        }.value

        let deadline = Date().addingTimeInterval(2.0)
        while !arbiter.canTerminateNow && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(arbiter.isActive(.backgroundExport))
        XCTAssertTrue(arbiter.canTerminateNow)
        XCTAssertTrue(arbiter.canInstallSilentlyNow)
        XCTAssertEqual(notifications, 4)
    }
}
