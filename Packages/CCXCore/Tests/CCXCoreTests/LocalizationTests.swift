import AppKit
@testable import CCXCore
import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    private enum DummyError: Error, Equatable {
        case failed
    }

    override func tearDown() {
        CCXL10n.setLanguageOverrideForTesting(nil)
        super.tearDown()
    }

    func testResolveLanguageSimplifiedChineseVariants() {
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hans-CN", "en-US"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hans-US"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hans-HK"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hans"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-CN"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-SG"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh_Hans_CN"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["  zh_CN \n"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-CN@calendar=chinese"]), .zhHans)
    }

    func testResolveLanguageEnglishPriorityAndUnmatchedFallbacks() {
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["en-US", "zh-Hans-CN"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["en"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["en-GB"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["en_US"]), .en)

        // Traditional Chinese must NOT match Simplified Chinese; skip or fall back to English.
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hant-TW"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hant-HK", "en-US"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-TW"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hant"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-HK"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-MO"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["zh-Hant-TW", "zh-Hans-CN"]), .zhHans)

        // Unmatched languages scan remaining entries and fall back to English when none match.
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["ja-JP", "fr-FR"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["ja-JP", "zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: ["", "   ", "ko-KR"]), .en)
        XCTAssertEqual(CCXL10n.resolveLanguage(preferredLanguages: []), .en)
    }

    func testWithLanguageForTestingSwitchesAndRestoresState() {
        CCXL10n.setLanguageOverrideForTesting(nil)

        CCXL10n.withLanguageForTesting(.en) {
            XCTAssertEqual(CCXL10n.currentLanguage, .en)
            XCTAssertEqual(CCXL10n.text("Snip", zh: "截屏"), "Snip")
            XCTAssertEqual(CCXHotKeyAction.snip.displayName, "Snip")

            // Nested override must restore outer override cleanly.
            CCXL10n.withLanguageForTesting(.zhHans) {
                XCTAssertEqual(CCXL10n.currentLanguage, .zhHans)
                XCTAssertEqual(CCXL10n.text("Snip", zh: "截屏"), "截屏")
                XCTAssertEqual(CCXHotKeyAction.snip.displayName, "截屏")
            }

            XCTAssertEqual(CCXL10n.currentLanguage, .en)
            XCTAssertEqual(CCXL10n.text("Snip", zh: "截屏"), "Snip")
        }

        // Restores previous override even when the body throws.
        CCXL10n.setLanguageOverrideForTesting(.zhHans)
        XCTAssertThrowsError(
            try CCXL10n.withLanguageForTesting(.en) {
                XCTAssertEqual(CCXL10n.currentLanguage, .en)
                throw DummyError.failed
            }
        ) { error in
            XCTAssertEqual(error as? DummyError, .failed)
        }
        XCTAssertEqual(CCXL10n.currentLanguage, .zhHans)

        CCXL10n.setLanguageOverrideForTesting(nil)
        XCTAssertEqual(CCXL10n.currentLanguage, CCXL10n.resolveLanguage())
    }

    func testClipboardStoreLocalizedStringsInBothLanguages() {
        CCXL10n.withLanguageForTesting(.en) {
            XCTAssertEqual(ClipboardPinBadge.image.displayText, "Image")
            XCTAssertEqual(ClipboardPinBadge.text.displayText, "Text")
            XCTAssertEqual(ClipboardPinBadge.empty.displayText, "Empty")
            XCTAssertEqual(
                ClipboardPinBadge.color(CCXColorSample(red: 0x12, green: 0x34, blue: 0x56)).displayText,
                "#123456"
            )
            XCTAssertEqual(ClipboardStoreError.encodingFailed.errorDescription, "Could not encode the image as PNG.")
            XCTAssertEqual(ClipboardStoreError.writeFailed.errorDescription, "Could not write the PNG file to disk.")
        }

        CCXL10n.withLanguageForTesting(.zhHans) {
            XCTAssertEqual(ClipboardPinBadge.image.displayText, "图片")
            XCTAssertEqual(ClipboardPinBadge.text.displayText, "文本")
            XCTAssertEqual(ClipboardPinBadge.empty.displayText, "空")
            XCTAssertEqual(
                ClipboardPinBadge.color(CCXColorSample(red: 0x12, green: 0x34, blue: 0x56)).displayText,
                "#123456"
            )
            XCTAssertEqual(ClipboardStoreError.encodingFailed.errorDescription, "无法将图片编码为 PNG。")
            XCTAssertEqual(ClipboardStoreError.writeFailed.errorDescription, "无法将 PNG 文件写入磁盘。")
        }
    }

    func testBundleIdentifierValidationForTCCReset() {
        XCTAssertTrue(PermissionManager.isValidBundleIdentifier("com.lizhichaox.ccx"))
        XCTAssertTrue(PermissionManager.isValidBundleIdentifier("com.example.my-app2"))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier(""))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier("-com.lizhichaox.ccx"))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier(".com.lizhichaox.ccx"))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier("com.lizhichaox.ccx."))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier("com..lizhichaox.ccx"))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier("nodot"))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier("com.lizhichaox.ccx;rm -rf /"))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier("com.lizhichaox.ccx/sub"))
        XCTAssertFalse(PermissionManager.isValidBundleIdentifier(String(repeating: "a", count: 256) + ".b"))
    }

    func testRelativeAgeFormattingInBothLanguages() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        CCXL10n.withLanguageForTesting(.en) {
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-10), now: now), "Just now")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(30), now: now), "Just now")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-180), now: now), "3m ago")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-7_200), now: now), "2h ago")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-90_000), now: now), "Yesterday")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
        }

        CCXL10n.withLanguageForTesting(.zhHans) {
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-10), now: now), "刚刚")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-180), now: now), "3 分钟前")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-7_200), now: now), "2 小时前")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-90_000), now: now), "昨天")
            XCTAssertEqual(CCXL10n.relativeAge(from: now.addingTimeInterval(-3 * 86_400), now: now), "3 天前")
        }
    }

    @MainActor
    func testV010PopoverSettingsAndGuideCopyFitWidthBudgetsInBothLanguages() {
        let settingsTitleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let smallButtonFont = NSFont.systemFont(ofSize: 11.0)
        let popoverSectionFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        let popoverBadgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        let guideTitleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let guidePillFont = NSFont.systemFont(ofSize: 11.0, weight: .medium)

        // Settings RecordingsFolderRow: 316pt inner width -> 24 icon + 9 gap + title + 9 gap + [22 reset + 5] + Choose + 5 + Open + 36 button chrome.
        let settingsCardInnerWidth: CGFloat = 316.0
        // Popover FloatingPinsSection header: 288pt inner width.
        let popoverInnerWidth: CGFloat = 288.0
        // Setup Guide ReadyStepView row: 464 - 40 outer - 24 row padding = 400pt inner width (24 icon + 10 gap + title + 10 spacer + pill + 18 pill padding).
        let guideRowInnerWidth: CGFloat = 400.0

        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                let recTitleW = ceil(NSAttributedString(string: CCXL10n.text("Recordings", zh: "录屏目录"), attributes: [.font: settingsTitleFont]).size().width)
                let chooseW = ceil(NSAttributedString(string: CCXL10n.text("Choose…", zh: "选择…"), attributes: [.font: smallButtonFont]).size().width)
                let openW = ceil(NSAttributedString(string: CCXL10n.text("Open", zh: "打开"), attributes: [.font: smallButtonFont]).size().width)
                let recordingsRowTotal = 24 + 9 + recTitleW + 9 + 22 + 5 + chooseW + 18 + 5 + openW + 18
                XCTAssertLessThanOrEqual(
                    recordingsRowTotal,
                    settingsCardInnerWidth,
                    "[\(language.rawValue)] RecordingsFolderRow measured \(recordingsRowTotal)pt, exceeding \(settingsCardInnerWidth)pt"
                )

                let pinsHeaderW = ceil(NSAttributedString(string: CCXL10n.text("FLOATING PINS", zh: "悬浮贴图"), attributes: [.font: popoverSectionFont]).size().width)
                for status in [
                    CCXL10n.text("99 active", zh: "99 个显示"),
                    CCXL10n.text("99 hidden", zh: "99 个已隐藏"),
                ] {
                    let badgeW = ceil(NSAttributedString(string: status, attributes: [.font: popoverBadgeFont]).size().width)
                    let totalW = pinsHeaderW + 6 + badgeW + 12
                    XCTAssertLessThanOrEqual(
                        totalW,
                        popoverInnerWidth,
                        "[\(language.rawValue)] FloatingPinsSection header '\(status)' measured \(totalW)pt, exceeding \(popoverInnerWidth)pt"
                    )
                }

                let readyRowTitleW = ceil(NSAttributedString(
                    string: CCXL10n.text("Annotate, OCR & Scroll", zh: "标注、OCR 与长截屏"),
                    attributes: [.font: guideTitleFont]
                ).size().width)
                let readyPillW = ceil(NSAttributedString(string: "1–8 · T · L", attributes: [.font: guidePillFont]).size().width)
                let readyRowTotal = 24 + 10 + readyRowTitleW + 10 + readyPillW + 18
                XCTAssertLessThanOrEqual(
                    readyRowTotal,
                    guideRowInnerWidth,
                    "[\(language.rawValue)] ReadyStepView row measured \(readyRowTotal)pt, exceeding \(guideRowInnerWidth)pt"
                )
            }
        }
    }

    @MainActor
    func testScreenRecordingPermissionRecoveryCopyFitsSingleLineInBothLanguages() {
        let guideHintFont = NSFont.systemFont(ofSize: 11.0)
        let guideButtonFont = NSFont.systemFont(ofSize: 11.0) // .controlSize(.small)
        let settingsHintFont = NSFont.systemFont(ofSize: 10.5)
        let settingsButtonFont = NSFont.systemFont(ofSize: 9.5) // .controlSize(.mini)

        // Setup Guide: 464 window - 40 outer padding - 20 strip padding = 404pt inner width.
        // Worst case has 3 bordered .small buttons (~18pt chrome each) + 4 HStack gaps (6+4+6+6 = 22pt).
        let guideInnerWidth: CGFloat = 404.0
        let guideThreeButtonOverhead: CGFloat = 18 * 3 + 22

        // Settings: 368 window - 32 outer padding - 43 leading - 10 trailing = 283pt sub-row width.
        // Worst case has 3 bordered .mini buttons (~14pt chrome each) + 4 HStack gaps (5+4+5+5 = 19pt).
        let settingsSubRowWidth: CGFloat = 283.0
        let settingsThreeButtonOverhead: CGFloat = 14 * 3 + 19

        for language in CCXLanguage.allCases {
            CCXL10n.withLanguageForTesting(language) {
                let verifyIdle = CCXL10n.text("Verify", zh: "验证")
                let verifyBusy = CCXL10n.text("Checking…", zh: "验证中…")
                let relaunch = CCXL10n.text("Relaunch", zh: "重启")
                let resetIdle = PermissionManager.ScreenRecordingCopy.resetButtonTitle
                let resetBusy = PermissionManager.ScreenRecordingCopy.resettingButtonTitle

                let guideHints = [
                    PermissionManager.ScreenRecordingCopy.guideHintDefault,
                    PermissionManager.ScreenRecordingCopy.guideHintStale,
                ]
                let maxGuideVerify = max(
                    ceil(NSAttributedString(string: verifyIdle, attributes: [.font: guideButtonFont]).size().width),
                    ceil(NSAttributedString(string: verifyBusy, attributes: [.font: guideButtonFont]).size().width)
                )
                let maxGuideReset = max(
                    ceil(NSAttributedString(string: resetIdle, attributes: [.font: guideButtonFont]).size().width),
                    ceil(NSAttributedString(string: resetBusy, attributes: [.font: guideButtonFont]).size().width)
                )
                let guideRelaunchW = ceil(NSAttributedString(string: relaunch, attributes: [.font: guideButtonFont]).size().width)

                for hint in guideHints {
                    XCTAssertFalse(hint.isEmpty)
                    XCTAssertFalse(hint.contains("\n"))
                    let hintW = ceil(NSAttributedString(string: hint, attributes: [.font: guideHintFont]).size().width)
                    let isThreeButtons = (hint == PermissionManager.ScreenRecordingCopy.guideHintStale)
                    let buttonsW = (isThreeButtons ? maxGuideReset : 0) + maxGuideVerify + guideRelaunchW
                    let overhead = isThreeButtons ? guideThreeButtonOverhead : (18 * 2 + 16)
                    let totalW = hintW + buttonsW + overhead
                    XCTAssertLessThanOrEqual(
                        totalW,
                        guideInnerWidth,
                        "[\(language.rawValue)] Guide hint '\(hint)' measured \(totalW)pt, exceeding \(guideInnerWidth)pt"
                    )
                }

                let settingsHints = [
                    PermissionManager.ScreenRecordingCopy.settingsHintDefault,
                    PermissionManager.ScreenRecordingCopy.settingsHintRelaunch,
                    PermissionManager.ScreenRecordingCopy.settingsHintStale,
                ]
                let maxSettingsVerify = max(
                    ceil(NSAttributedString(string: verifyIdle, attributes: [.font: settingsButtonFont]).size().width),
                    ceil(NSAttributedString(string: verifyBusy, attributes: [.font: settingsButtonFont]).size().width)
                )
                let maxSettingsReset = max(
                    ceil(NSAttributedString(string: resetIdle, attributes: [.font: settingsButtonFont]).size().width),
                    ceil(NSAttributedString(string: resetBusy, attributes: [.font: settingsButtonFont]).size().width)
                )
                let settingsRelaunchW = ceil(NSAttributedString(string: relaunch, attributes: [.font: settingsButtonFont]).size().width)

                for hint in settingsHints {
                    XCTAssertFalse(hint.isEmpty)
                    XCTAssertFalse(hint.contains("\n"))
                    let hintW = ceil(NSAttributedString(string: hint, attributes: [.font: settingsHintFont]).size().width)
                    // Default/Relaunch states have 2 buttons; Stale state has 3 buttons.
                    let isThreeButtons = (hint == PermissionManager.ScreenRecordingCopy.settingsHintStale)
                    let buttonsW = (isThreeButtons ? maxSettingsReset : 0) + maxSettingsVerify + settingsRelaunchW
                    let overhead = isThreeButtons ? settingsThreeButtonOverhead : (14 * 2 + 14)
                    let totalW = hintW + buttonsW + overhead
                    XCTAssertLessThanOrEqual(
                        totalW,
                        settingsSubRowWidth,
                        "[\(language.rawValue)] Settings hint '\(hint)' measured \(totalW)pt, exceeding \(settingsSubRowWidth)pt"
                    )
                }
            }
        }
    }
}
