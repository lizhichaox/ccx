import Foundation
import os

/// Supported UI languages for CCX.
///
/// CCX automatically follows the user's macOS System Settings → Language & Region
/// preference order, resolving to Simplified Chinese (`.zhHans`) or English (`.en`,
/// default and fallback).
public enum CCXLanguage: String, CaseIterable, Equatable, Hashable, Sendable {
    case en = "en"
    case zhHans = "zh-Hans"
}

/// Lightweight, thread-safe localization helper shared across CCX packages and the app target.
///
/// Resolves language automatically from `Locale.preferredLanguages` with Simplified Chinese
/// (`zh-Hans`) and English (`en`) support, falling back to English for any unmatched language
/// (including Traditional Chinese).
public enum CCXL10n {
    private static let languageOverrideLock = OSAllocatedUnfairLock<CCXLanguage?>(initialState: nil)
    private static let resolvedSystemLanguage: CCXLanguage = resolveLanguage()

    /// Resolves the best supported `CCXLanguage` from an ordered list of BCP-47 / macOS
    /// language identifiers (such as `Locale.preferredLanguages`).
    ///
    /// Entries are scanned in priority order and the first matching supported language wins:
    /// - Simplified Chinese (`zh`, `zh-Hans`, `zh-Hans-*`, `zh-CN`, `zh-SG`) resolves to `.zhHans`.
    /// - Traditional Chinese (`zh-Hant*`, `zh-TW`, `zh-HK`, `zh-MO`) and other unsupported
    ///   languages are skipped so subsequent preferences can match.
    /// - English (`en`, `en-*`) resolves to `.en`.
    /// - If no entry matches (or the list is empty), falls back to `.en`.
    public static func resolveLanguage(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> CCXLanguage {
        for rawEntry in preferredLanguages {
            let trimmed = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Strip optional locale keyword suffix (e.g. "@calendar=gregorian").
            let base = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? trimmed
            let tag = base.lowercased().replacingOccurrences(of: "_", with: "-")
            guard !tag.isEmpty else { continue }

            if tag == "zh"
                || tag == "zh-hans"
                || tag.hasPrefix("zh-hans-")
                || tag == "zh-cn"
                || tag.hasPrefix("zh-cn-")
                || tag == "zh-sg"
                || tag.hasPrefix("zh-sg-")
            {
                return .zhHans
            }

            if tag == "en" || tag.hasPrefix("en-") {
                return .en
            }
        }
        return .en
    }

    /// The active language, honoring any thread-safe test override before falling back to
    /// the cached system resolution from `resolveLanguage()`.
    public static var currentLanguage: CCXLanguage {
        if let override = languageOverrideLock.withLock({ $0 }) {
            return override
        }
        return resolvedSystemLanguage
    }

    /// Sets or clears a process-wide language override for deterministic unit tests.
    public static func setLanguageOverrideForTesting(_ language: CCXLanguage?) {
        languageOverrideLock.withLock { $0 = language }
    }

    /// Runs `body` with `currentLanguage` overridden to `language`, restoring the previous
    /// override state when `body` returns or throws.
    public static func withLanguageForTesting<T>(
        _ language: CCXLanguage,
        _ body: () throws -> T
    ) rethrows -> T {
        let previous = languageOverrideLock.withLock { current -> CCXLanguage? in
            let prior = current
            current = language
            return prior
        }
        defer {
            languageOverrideLock.withLock { $0 = previous }
        }
        return try body()
    }

    /// Returns `simplifiedChinese` when `currentLanguage == .zhHans`, otherwise `english`.
    public static func text(_ english: String, zh simplifiedChinese: String) -> String {
        switch currentLanguage {
        case .zhHans:
            return simplifiedChinese
        case .en:
            return english
        }
    }
}
