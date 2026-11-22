import CPXCore
import Foundation

/// Persists the global snip hotkey and offers preset choices for Settings.
enum HotKeyPreferences {
    // Carbon modifier masks (mirrors `cmdKey`, `shiftKey`, `optionKey`,
    // `controlKey` from Carbon.HIToolbox without importing Carbon here).
    private static let command: UInt32 = 1 << 8
    private static let shift: UInt32 = 1 << 9
    private static let option: UInt32 = 1 << 11
    private static let control: UInt32 = 1 << 12

    // Carbon virtual key codes.
    private enum KeyCode {
        static let a: UInt32 = 0
        static let f1: UInt32 = 122
        static let f2: UInt32 = 120
    }

    private static let defaultsKeyPrefix = "CPXHotKey."
    private static let legacyKeys = ["pastePin", "toggleAllPins", "unlockClickThrough"]

    static func defaultCombo(for action: CPXHotKeyAction) -> HotKeyCombo {
        switch action {
        case .snip: .defaultSnip
        }
    }

    /// Preset combos offered in Settings. The default always comes first.
    static func presets(for action: CPXHotKeyAction) -> [HotKeyCombo] {
        let alternatives: [HotKeyCombo]
        switch action {
        case .snip:
            alternatives = [
                HotKeyCombo(keyCode: KeyCode.f1, carbonModifiers: 0),
                HotKeyCombo(keyCode: KeyCode.f2, carbonModifiers: 0),
                HotKeyCombo(keyCode: KeyCode.a, carbonModifiers: control | shift),
                HotKeyCombo(keyCode: KeyCode.a, carbonModifiers: command | shift | option),
            ]
        }
        return [defaultCombo(for: action)] + alternatives
    }

    static func savedCombo(for action: CPXHotKeyAction) -> HotKeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKeyPrefix + action.rawValue) else {
            return nil
        }
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    static func save(_ combo: HotKeyCombo, for action: CPXHotKeyAction) {
        let key = defaultsKeyPrefix + action.rawValue
        if combo == defaultCombo(for: action) {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Removes retired hotkey prefs, registers defaults, and applies any saved overrides.
    @MainActor
    static func registerAll(on manager: GlobalHotKeyManager) {
        for legacyKey in legacyKeys {
            UserDefaults.standard.removeObject(forKey: defaultsKeyPrefix + legacyKey)
        }
        manager.registerDefaults()
        for action in CPXHotKeyAction.allCases {
            guard let saved = savedCombo(for: action), saved != manager.currentCombo(for: action) else {
                continue
            }
            manager.unregister(action)
            if !manager.register(action, combo: saved) {
                manager.register(action, combo: defaultCombo(for: action))
            }
        }
    }
}

extension CPXHotKeyAction {
    /// Human-readable title used in the menu bar and Settings.
    var cpxMenuTitle: String {
        switch self {
        case .snip: "Snip"
        }
    }
}
