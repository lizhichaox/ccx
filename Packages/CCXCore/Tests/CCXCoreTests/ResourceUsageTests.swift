import AppKit
@testable import CCXCore
import Foundation
import XCTest

final class ResourceUsageTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDown() {
        CCXL10n.setLanguageOverrideForTesting(nil)
        for dir in tempDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCXResourceUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    func testCurrentPhysicalMemoryFootprintIsPositive() {
        let bytes = AppResourceMonitor.currentPhysicalMemoryBytes()
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 0)
    }

    func testMemoryAndDiskByteFormatting() {
        XCTAssertEqual(ResourceUsageSnapshot.formatMemoryBytes(0), "0 KB")
        XCTAssertEqual(ResourceUsageSnapshot.formatMemoryBytes(512), "1 KB")
        XCTAssertEqual(ResourceUsageSnapshot.formatMemoryBytes(512 * 1024), "512 KB")
        XCTAssertEqual(ResourceUsageSnapshot.formatMemoryBytes(1024 * 1024 - 1), "1 MB")
        XCTAssertEqual(ResourceUsageSnapshot.formatMemoryBytes(42 * 1024 * 1024), "42 MB")
        XCTAssertEqual(ResourceUsageSnapshot.formatMemoryBytes(1024 * 1024 * 1024), "1.0 GB")
        XCTAssertEqual(ResourceUsageSnapshot.formatMemoryBytes(1_610_612_736), "1.5 GB")

        XCTAssertEqual(ResourceUsageSnapshot.formatDiskBytes(0), "0 KB")
        XCTAssertEqual(ResourceUsageSnapshot.formatDiskBytes(420), "< 1 KB")
        XCTAssertEqual(ResourceUsageSnapshot.formatDiskBytes(1_000), "1 KB")
        XCTAssertEqual(ResourceUsageSnapshot.formatDiskBytes(245_000), "245 KB")
        XCTAssertEqual(ResourceUsageSnapshot.formatDiskBytes(2_400_000), "2.4 MB")
        XCTAssertEqual(ResourceUsageSnapshot.formatDiskBytes(24_000_000), "24 MB")
        XCTAssertEqual(ResourceUsageSnapshot.formatDiskBytes(1_250_000_000), "1.2 GB")

        let emptySnapshot = ResourceUsageSnapshot()
        XCTAssertEqual(emptySnapshot.formattedMemory, "—")
        XCTAssertEqual(emptySnapshot.formattedDiskCache, "0 KB")
    }

    func testRegularFilesByteSizeCountsOnlyRegularFilesAndIgnoresSymlinks() throws {
        let dir = try makeTempDirectory()
        let externalDir = try makeTempDirectory()

        let fileA = dir.appendingPathComponent("a.png")
        let fileB = dir.appendingPathComponent("b.json")
        try Data(repeating: 0x11, count: 1_500).write(to: fileA)
        try Data(repeating: 0x22, count: 500).write(to: fileB)

        // Subdirectories and symlinks inside cache directory must not be counted.
        let nestedDir = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 9_000).write(to: nestedDir.appendingPathComponent("ignored.png"))

        let outsideFile = externalDir.appendingPathComponent("secret.dat")
        try Data(repeating: 0x44, count: 50_000).write(to: outsideFile)
        let symlinkChild = dir.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: symlinkChild, withDestinationURL: outsideFile)

        XCTAssertEqual(AppResourceMonitor.regularFilesByteSize(in: dir), 2_000)

        // A symlinked root directory must be ignored completely.
        let symlinkRoot = externalDir.appendingPathComponent("linked-cache")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: dir)
        XCTAssertEqual(AppResourceMonitor.regularFilesByteSize(in: symlinkRoot), 0)

        // Missing directory returns 0 safely.
        let missing = externalDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(AppResourceMonitor.regularFilesByteSize(in: missing), 0)

        // Multi-directory summation and (st_dev, st_ino) deduplication.
        XCTAssertEqual(AppResourceMonitor.totalRegularFilesByteSize(in: [dir, externalDir, missing]), 52_000)
        let dirWithDotSegment = dir.appendingPathComponent(".", isDirectory: true)
        XCTAssertEqual(AppResourceMonitor.totalRegularFilesByteSize(in: [dir, dir, dirWithDotSegment, externalDir]), 52_000)
    }

    @MainActor
    func testResourceUsageCopyAndSymbolsFitSingleLineInSettingsInBothLanguages() {
        // Settings window is 368pt wide -> 336pt card -> 316pt inner width (10pt horizontal padding each side).
        let cardInnerWidth: CGFloat = 316.0
        let headerTitleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let headerSubtitleFont = NSFont.systemFont(ofSize: 10.5)
        let memoryBadgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let itemTitleFont = NSFont.systemFont(ofSize: 11.0, weight: .semibold)
        let itemBadgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .medium)
        let itemDetailFont = NSFont.systemFont(ofSize: 10.5)

        // Header geometry: 24 icon + 9 spacing + [title/subtitle] + 9 spacing + [pill text + 14 padding] + 6 spacing + 12 chevron
        let headerFixedOverhead: CGFloat = 24 + 9 + 9 + 14 + 6 + 12
        // Expanded row geometry: 14 icon + 6 spacing = 20pt leading; HStack(spacing: 6) around Spacer(minLength: 6) = 18pt gap.
        let itemLine1Budget: CGFloat = cardInnerWidth - 20 - 18 // 278pt
        let itemDetailBudget: CGFloat = cardInnerWidth - 20 - 6 // 290pt (6pt safety margin)

        let worstSnapshots: [ResourceUsageSnapshot] = [
            ResourceUsageSnapshot(
                physicalMemoryBytes: 12_884_901_888, // 12.0 GB
                historyCount: 20,
                maxHistoryCount: 20,
                activePinCount: 64,
                diskCacheBytes: 999_000_000 // 999 MB
            ),
            ResourceUsageSnapshot(
                physicalMemoryBytes: 512 * 1024 * 1024, // 512 MB
                historyCount: 1,
                maxHistoryCount: 20,
                activePinCount: 1,
                diskCacheBytes: 500 // < 1 KB
            ),
            ResourceUsageSnapshot(
                physicalMemoryBytes: 256 * 1024 * 1024, // 256 MB
                historyCount: 12,
                maxHistoryCount: 20,
                activePinCount: 4,
                diskCacheBytes: 1_500_000_000 // 1.5 GB
            ),
            ResourceUsageSnapshot(
                physicalMemoryBytes: nil,
                historyCount: 0,
                maxHistoryCount: 20,
                activePinCount: 0,
                diskCacheBytes: 0
            ),
        ]

        XCTAssertNotNil(NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: nil))

        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                let title = ResourceUsageSnapshot.headerTitle
                let subtitle = ResourceUsageSnapshot.headerSubtitle
                XCTAssertFalse(title.isEmpty)
                XCTAssertFalse(subtitle.isEmpty)
                XCTAssertFalse(title.contains("\n"))
                XCTAssertFalse(subtitle.contains("\n"))

                let titleWidth = ceil(NSAttributedString(string: title, attributes: [.font: headerTitleFont]).size().width)
                let subtitleWidth = ceil(NSAttributedString(string: subtitle, attributes: [.font: headerSubtitleFont]).size().width)

                for snapshot in worstSnapshots {
                    let pillWidth = ceil(
                        NSAttributedString(string: snapshot.formattedMemory, attributes: [.font: memoryBadgeFont]).size().width
                    )
                    let maxLeftWidth = cardInnerWidth - headerFixedOverhead - pillWidth
                    XCTAssertLessThanOrEqual(
                        titleWidth,
                        maxLeftWidth,
                        "[\(language.rawValue)] Header title '\(title)' measured \(titleWidth)pt, exceeding \(maxLeftWidth)pt budget"
                    )
                    XCTAssertLessThanOrEqual(
                        subtitleWidth,
                        maxLeftWidth,
                        "[\(language.rawValue)] Header subtitle '\(subtitle)' measured \(subtitleWidth)pt, exceeding \(maxLeftWidth)pt budget"
                    )

                    for autoUpdates in [true, false] {
                        let items = snapshot.guideItems(automaticallyChecksForUpdates: autoUpdates)
                        XCTAssertEqual(items.map(\.kind), ResourceUsageGuideItem.Kind.allCases)

                        for item in items {
                            XCTAssertNotNil(
                                NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil),
                                "Invalid SF Symbol: \(item.symbol)"
                            )
                            for text in [item.title, item.badge, item.detail] {
                                XCTAssertFalse(text.isEmpty)
                                XCTAssertFalse(text.contains("\n"))
                            }

                            let itemTitleW = ceil(
                                NSAttributedString(string: item.title, attributes: [.font: itemTitleFont]).size().width
                            )
                            let itemBadgeW = ceil(
                                NSAttributedString(string: item.badge, attributes: [.font: itemBadgeFont]).size().width
                            )
                            XCTAssertLessThanOrEqual(
                                itemTitleW + itemBadgeW,
                                itemLine1Budget,
                                "[\(language.rawValue)] Item '\(item.title)' + '\(item.badge)' measured \(itemTitleW + itemBadgeW)pt, exceeding \(itemLine1Budget)pt budget"
                            )

                            let detailW = ceil(
                                NSAttributedString(string: item.detail, attributes: [.font: itemDetailFont]).size().width
                            )
                            XCTAssertLessThanOrEqual(
                                detailW,
                                itemDetailBudget,
                                "[\(language.rawValue)] Item detail '\(item.detail)' measured \(detailW)pt, exceeding \(itemDetailBudget)pt budget"
                            )
                        }
                    }
                }
            }
        }
    }
}
