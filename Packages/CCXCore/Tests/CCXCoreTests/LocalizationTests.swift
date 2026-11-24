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
}
