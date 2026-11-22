import CPXCore
import Foundation

/// Persists user-selected global hotkeys and offers preset choices for the
/// Settings window.
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
        static let h: UInt32 = 4
        static let p: UInt32 = 35
        static let u: UInt32 = 32
        static let f1: UInt32 = 122
        static let f2: UInt32 = 120
        static let f4: UInt32 = 118
    }

    private static let defaultsKeyPrefix = "CPXHotKey."

    static func defaultCombo(for action: CPXHotKeyAction) -> HotKeyCombo {
        switch action {
        case .snip: .defaultSnip
        case .pastePin: .defaultPastePin
        case .toggleAllPins: .defaultToggleAllPins
        case .unlockClickThrough: .defaultUnlockClickThrough
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
        case .pastePin:
            alternatives = [
                HotKeyCombo(keyCode: KeyCode.f4, carbonModifiers: 0),
                HotKeyCombo(keyCode: KeyCode.p, carbonModifiers: control | shift),
                HotKeyCombo(keyCode: KeyCode.p, carbonModifiers: command | shift | option),
            ]
        case .toggleAllPins:
            alternatives = [
                HotKeyCombo(keyCode: KeyCode.f4, carbonModifiers: shift),
                HotKeyCombo(keyCode: KeyCode.h, carbonModifiers: control | shift),
            ]
        case .unlockClickThrough:
            alternatives = [
                HotKeyCombo(keyCode: KeyCode.f4, carbonModifiers: option | shift),
                HotKeyCombo(keyCode: KeyCode.u, carbonModifiers: control | shift),
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

    /// Registers the defaults, then applies any saved overrides. A saved combo
    /// that fails to register falls back to the default binding.
    @MainActor
    static func registerAll(on manager: GlobalHotKeyManager) {
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
        case .pastePin: "Paste / Pin from Clipboard"
        case .toggleAllPins: "Hide / Show All Pins"
        case .unlockClickThrough: "Unlock Click-Through Pins"
        }
    }
}
