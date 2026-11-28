import AppKit
import Carbon.HIToolbox
import Foundation

/// Global actions that can be bound to a system-wide hotkey.
public enum CCXHotKeyAction: String, CaseIterable, Sendable, Codable {
    case snip
    case quickOCR
    case pinClipboard
    case record
    case togglePins
    case unlockClickThrough

    /// Optional secondary actions that ship unbound by default.
    public static let optionalActions: [CCXHotKeyAction] = [
        .quickOCR,
        .pinClipboard,
        .record,
        .togglePins,
        .unlockClickThrough,
    ]

    /// Human-readable title for settings and menus.
    public var displayName: String {
        switch self {
        case .snip:
            CCXL10n.text("Snip", zh: "截屏")
        case .quickOCR:
            CCXL10n.text("Quick OCR", zh: "快捷识字")
        case .pinClipboard:
            CCXL10n.text("Pin Clipboard", zh: "剪贴板贴图")
        case .record:
            CCXL10n.text("Record", zh: "录屏")
        case .togglePins:
            CCXL10n.text("Toggle Pins", zh: "显隐贴图")
        case .unlockClickThrough:
            CCXL10n.text("Unlock Pins", zh: "解除穿透")
        }
    }

    /// The factory-default combo for this action, or `nil` when unbound by default.
    public var defaultCombo: HotKeyCombo? {
        switch self {
        case .snip: .defaultSnip
        case .quickOCR, .pinClipboard, .record, .togglePins, .unlockClickThrough: nil
        }
    }

    /// Stable, non-zero Carbon hotkey identifier.
    var carbonID: UInt32 {
        UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    init?(carbonID: UInt32) {
        let index = Int(carbonID) - 1
        guard Self.allCases.indices.contains(index) else { return nil }
        self = Self.allCases[index]
    }
}

/// A virtual key code plus Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
public struct HotKeyCombo: Equatable, Hashable, Sendable, Codable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a combo from AppKit modifier flags (e.g. from a shortcut recorder `NSEvent`).
    public init(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, carbonModifiers: Self.carbonModifiers(from: modifierFlags))
    }

    /// `Control+Command+X` (`⌃⌘X`)
    public static let defaultSnip = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_X),
        carbonModifiers: UInt32(controlKey | cmdKey)
    )

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5),
        UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10),
        UInt32(kVK_F11), UInt32(kVK_F12), UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15),
        UInt32(kVK_F16), UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand),
        UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function),
    ]

    /// Copy of this combo with `carbonModifiers` masked to `validCarbonModifierMask`.
    public var normalized: HotKeyCombo {
        HotKeyCombo(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers & validCarbonModifierMask
        )
    }

    /// Whether `keyCode` is a function key (`F1`–`F20`).
    public var isFunctionKey: Bool {
        Self.functionKeyCodes.contains(keyCode)
    }

    /// Whether `keyCode` is a standalone modifier key (Command, Shift, Option, Control, Caps Lock, or Fn).
    public var isModifierOnlyKey: Bool {
        Self.modifierOnlyKeyCodes.contains(keyCode)
    }

    /// Converts AppKit modifier flags into a Carbon modifier mask.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// The equivalent AppKit modifier flags.
    public var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// Canonical modifier symbols (`⌃`, `⌥`, `⇧`, `⌘`) followed by the key name token.
    public var tokens: [String] {
        var result: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { result.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { result.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        result.append(KeyCodeNames.name(for: keyCode))
        return result
    }

    /// Mac-style shortcut string, modifiers in canonical `⌃⌥⇧⌘` order, e.g. `⌃⌘X`.
    public var displayString: String {
        tokens.joined()
    }
}

/// Describes why a candidate global hotkey cannot be assigned or registered.
public enum HotKeyConflict: Equatable, Sendable, LocalizedError {
    case modifierOnly
    case missingModifier
    case escapeNotAllowed
    case systemShortcut(HotKeyCombo)
    case reservedAppShortcut(HotKeyCombo, label: String)
    case internalConflict(HotKeyCombo, action: CCXHotKeyAction)
    case inUseByAnotherApp(HotKeyCombo)
    case registrationFailed(HotKeyCombo, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .modifierOnly:
            CCXL10n.text("Add a key with ⌘, ⌃, or ⌥.", zh: "请搭配 ⌘、⌃ 或 ⌥ 与其他按键")
        case .missingModifier:
            CCXL10n.text("Use ⌘, ⌃, ⌥, or F1–F20.", zh: "需包含 ⌘、⌃、⌥ 或 F1–F20")
        case .escapeNotAllowed:
            CCXL10n.text("Esc cannot be a shortcut.", zh: "Esc 不能作为全局快捷键")
        case .systemShortcut(let combo):
            CCXL10n.text(
                "\(combo.displayString) conflicts with macOS.",
                zh: "\(combo.displayString) 与系统快捷键冲突"
            )
        case .reservedAppShortcut(let combo, let label):
            CCXL10n.text(
                "\(combo.displayString) is reserved for \(label).",
                zh: "\(combo.displayString) 为系统「\(label)」保留"
            )
        case .internalConflict(let combo, let action):
            CCXL10n.text(
                "\(combo.displayString) is already used by \(action.displayName).",
                zh: "\(combo.displayString) 已被「\(action.displayName)」占用"
            )
        case .inUseByAnotherApp(let combo):
            CCXL10n.text(
                "\(combo.displayString) is in use by another app.",
                zh: "\(combo.displayString) 已被其他应用占用"
            )
        case .registrationFailed(let combo, let status):
            CCXL10n.text(
                "Couldn't register \(combo.displayString) (\(status)).",
                zh: "无法注册 \(combo.displayString)（错误 \(status)）"
            )
        }
    }
}

/// Outcome of validated global hotkey registration.
public enum HotKeyRegistrationResult: Equatable, Sendable {
    case registered(HotKeyCombo)
    case conflict(HotKeyConflict)
}

/// Validates shortcut structure and checks reserved app and active macOS symbolic shortcuts.
public enum HotKeyConflictDetector {
    private struct LocalizedShortcutLabel: Sendable {
        let english: String
        let simplifiedChinese: String

        var localized: String {
            CCXL10n.text(english, zh: simplifiedChinese)
        }
    }

    private static let reservedAppShortcutLabels: [HotKeyCombo: LocalizedShortcutLabel] = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Copy", simplifiedChinese: "拷贝"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Paste", simplifiedChinese: "粘贴"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Cut", simplifiedChinese: "剪切"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Undo", simplifiedChinese: "撤销"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: UInt32(cmdKey | shiftKey)):
            LocalizedShortcutLabel(english: "Redo", simplifiedChinese: "重做"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Select All", simplifiedChinese: "全选"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Save", simplifiedChinese: "保存"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Quit", simplifiedChinese: "退出"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey | shiftKey)):
            LocalizedShortcutLabel(english: "Log Out", simplifiedChinese: "退出登录"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Close Window", simplifiedChinese: "关闭窗口"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Hide", simplifiedChinese: "隐藏"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(cmdKey | optionKey)):
            LocalizedShortcutLabel(english: "Hide Others", simplifiedChinese: "隐藏其他"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Minimize", simplifiedChinese: "最小化"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "New", simplifiedChinese: "新建"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Open", simplifiedChinese: "打开"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Print", simplifiedChinese: "打印"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Find", simplifiedChinese: "查找"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "New Tab", simplifiedChinese: "新建标签页"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Reload", simplifiedChinese: "刷新"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_Comma), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Settings", simplifiedChinese: "设置"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_Period), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Cancel", simplifiedChinese: "取消"),
        HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "App Switcher", simplifiedChinese: "切换应用"),
        HotKeyCombo(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(cmdKey | shiftKey)):
            LocalizedShortcutLabel(english: "App Switcher", simplifiedChinese: "切换应用"),
        HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey)):
            LocalizedShortcutLabel(english: "Spotlight", simplifiedChinese: "聚焦搜索"),
        HotKeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(cmdKey | optionKey)):
            LocalizedShortcutLabel(english: "Force Quit", simplifiedChinese: "强制退出"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(controlKey | cmdKey)):
            LocalizedShortcutLabel(english: "Lock Screen", simplifiedChinese: "锁定屏幕"),
    ]

    /// Essential system & standard application shortcuts that must not be hijacked globally.
    public static var reservedAppShortcuts: [HotKeyCombo: String] {
        reservedAppShortcutLabels.mapValues(\.localized)
    }

    internal static func isReservedAppShortcut(_ combo: HotKeyCombo) -> Bool {
        reservedAppShortcutLabels[combo.normalized] != nil
    }

    /// Queries Carbon `CopySymbolicHotKeys` for all currently enabled macOS system shortcuts.
    public static func activeSystemSymbolicHotKeys() -> Set<HotKeyCombo> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else {
            return []
        }

        var result = Set<HotKeyCombo>()
        result.reserveCapacity(entries.count)
        for item in entries {
            guard (item[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = (item[kHISymbolicHotKeyCode] as? NSNumber)?.intValue,
                  code >= 0,
                  code < Int(UInt16.max),
                  let mods = (item[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value
            else {
                continue
            }
            result.insert(
                HotKeyCombo(
                    keyCode: UInt32(code),
                    carbonModifiers: mods & validCarbonModifierMask
                )
            )
        }
        return result
    }

    /// Validates that `combo` has an allowed key and primary modifier structure for a global hotkey.
    public static func validateStructure(_ combo: HotKeyCombo) -> HotKeyConflict? {
        let normalized = combo.normalized
        if normalized.isModifierOnlyKey {
            return .modifierOnly
        }
        if normalized.keyCode == UInt32(kVK_Escape), normalized.carbonModifiers == 0 {
            return .escapeNotAllowed
        }
        let primaryModifierMask = UInt32(cmdKey | controlKey | optionKey)
        if !normalized.isFunctionKey && (normalized.carbonModifiers & primaryModifierMask) == 0 {
            return .missingModifier
        }
        return nil
    }

    /// Runs structure validation, reserved app shortcut lookup, and active system symbolic hotkey lookup.
    public static func checkPreRegistrationConflict(
        _ combo: HotKeyCombo,
        symbolicHotKeysProvider: () -> Set<HotKeyCombo> = activeSystemSymbolicHotKeys
    ) -> HotKeyConflict? {
        let normalized = combo.normalized
        if let structureConflict = validateStructure(normalized) {
            return structureConflict
        }
        if let label = reservedAppShortcutLabels[normalized]?.localized {
            return .reservedAppShortcut(normalized, label: label)
        }
        let activeSystem = symbolicHotKeysProvider()
        if activeSystem.contains(normalized) {
            return .systemShortcut(normalized)
        }
        return nil
    }
}

/// Persists customized hotkey bindings in `UserDefaults`, falling back to factory defaults on absence or corruption.
public enum HotKeyPreferences {
    public static let snipComboKey = "CCXSnipHotKeyCombo"

    public static func storageKey(for action: CCXHotKeyAction) -> String {
        switch action {
        case .snip: snipComboKey
        case .quickOCR, .pinClipboard, .record, .togglePins, .unlockClickThrough:
            "CCXHotKeyCombo.\(action.rawValue)"
        }
    }

    /// Loads an optional shortcut binding (`nil` when unset or corrupted for optional actions).
    public static func loadBinding(
        for action: CCXHotKeyAction,
        from defaults: UserDefaults = .standard
    ) -> HotKeyCombo? {
        guard let data = defaults.data(forKey: storageKey(for: action)),
              let decoded = try? JSONDecoder().decode(HotKeyCombo.self, from: data)
        else {
            return action.defaultCombo
        }
        let normalized = decoded.normalized
        guard normalized.keyCode <= UInt32(UInt16.max),
              HotKeyConflictDetector.validateStructure(normalized) == nil,
              !HotKeyConflictDetector.isReservedAppShortcut(normalized)
        else {
            return action.defaultCombo
        }
        return normalized
    }

    /// Saves or clears (`nil`) a shortcut binding for `action`.
    public static func saveBinding(
        _ combo: HotKeyCombo?,
        for action: CCXHotKeyAction,
        to defaults: UserDefaults = .standard
    ) {
        let key = storageKey(for: action)
        guard let combo else {
            defaults.removeObject(forKey: key)
            return
        }
        let normalized = combo.normalized
        if normalized == action.defaultCombo {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: key)
        }
    }

    public static func loadCombo(
        for action: CCXHotKeyAction,
        from defaults: UserDefaults = .standard
    ) -> HotKeyCombo {
        loadBinding(for: action, from: defaults) ?? .defaultSnip
    }

    public static func saveCombo(
        _ combo: HotKeyCombo,
        for action: CCXHotKeyAction,
        to defaults: UserDefaults = .standard
    ) {
        saveBinding(combo, for: action, to: defaults)
    }
}

/// Display names for virtual key codes (ANSI layout).
enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    private static let names: [UInt32: String] = {
        var map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_ANSI_Keypad0: "Num 0", kVK_ANSI_Keypad1: "Num 1", kVK_ANSI_Keypad2: "Num 2",
            kVK_ANSI_Keypad3: "Num 3", kVK_ANSI_Keypad4: "Num 4", kVK_ANSI_Keypad5: "Num 5",
            kVK_ANSI_Keypad6: "Num 6", kVK_ANSI_Keypad7: "Num 7", kVK_ANSI_Keypad8: "Num 8",
            kVK_ANSI_Keypad9: "Num 9", kVK_ANSI_KeypadDecimal: "Num .",
            kVK_ANSI_KeypadMultiply: "Num *", kVK_ANSI_KeypadPlus: "Num +",
            kVK_ANSI_KeypadClear: "Clear", kVK_ANSI_KeypadDivide: "Num /",
            kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadMinus: "Num -",
            kVK_ANSI_KeypadEquals: "Num =",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() {
            map[code] = "F\(index + 1)"
        }
        return Dictionary(uniqueKeysWithValues: map.map { (UInt32($0.key), $0.value) })
    }()
}

/// Four-char code `'CCXH'` tagging every hotkey registered by CCX.
private let ccxHotKeySignature: OSType = 0x4343_5848
private let validCarbonModifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

private struct SendableHotKeyTeardown: @unchecked Sendable {
    let token: UInt
    let hotKeyRefs: [EventHotKeyRef]
    let eventHandlerRef: EventHandlerRef?
}

/// Carbon event callback. Carbon delivers hotkey events on the main thread through the
/// application event target; the `userData` pointer carries an integer token (not a
/// retained object), so no Swift object crosses the C boundary unsafely.
private func ccxHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == ccxHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let token = UInt(bitPattern: userData)
    guard token != 0 else { return OSStatus(eventNotHandledErr) }
    let carbonID = hotKeyID.id
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            GlobalHotKeyManager.dispatch(token: token, carbonID: carbonID)
        }
    } else {
        Task { @MainActor in
            GlobalHotKeyManager.dispatch(token: token, carbonID: carbonID)
        }
    }
    return noErr
}

/// Registers system-wide hotkeys via Carbon `RegisterEventHotKey`, which requires no
/// Accessibility / Input Monitoring permission.
@MainActor
public final class GlobalHotKeyManager {
    /// Called on the main actor whenever a registered hotkey is pressed.
    public var onAction: ((CCXHotKeyAction) -> Void)?

    /// Most recent Carbon `OSStatus` returned when registering each action (`noErr` on success).
    public private(set) var lastRegistrationStatus: [CCXHotKeyAction: OSStatus] = [:]

    private var combos: [CCXHotKeyAction: HotKeyCombo] = [:]
    // Carbon refs are only mutated on `@MainActor` and handed off once from `deinit`.
    nonisolated(unsafe) private var hotKeyRefs: [CCXHotKeyAction: EventHotKeyRef] = [:]
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    private let token: UInt

    private final class WeakBox {
        weak var manager: GlobalHotKeyManager?
        init(_ manager: GlobalHotKeyManager) { self.manager = manager }
    }

    private static var nextToken: UInt = 1
    private static var instances: [UInt: WeakBox] = [:]

    public init() {
        Self.instances = Self.instances.filter { $0.value.manager != nil }
        token = Self.allocateToken()
        Self.instances[token] = WeakBox(self)
    }

    deinit {
        let teardown = SendableHotKeyTeardown(
            token: token,
            hotKeyRefs: Array(hotKeyRefs.values),
            eventHandlerRef: eventHandlerRef
        )
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.performTeardown(teardown)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.performTeardown(teardown)
                }
            }
        }
    }

    private static func allocateToken() -> UInt {
        var candidate = nextToken
        if candidate == 0 { candidate = 1 }
        while instances[candidate] != nil {
            candidate &+= 1
            if candidate == 0 { candidate = 1 }
        }
        nextToken = candidate &+ 1
        if nextToken == 0 { nextToken = 1 }
        return candidate
    }

    private static func performTeardown(_ teardown: SendableHotKeyTeardown) {
        instances.removeValue(forKey: teardown.token)
        for ref in teardown.hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let handler = teardown.eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    static func dispatch(token: UInt, carbonID: UInt32) {
        guard let manager = instances[token]?.manager,
              let action = CCXHotKeyAction(carbonID: carbonID),
              manager.combos[action] != nil
        else { return }
        manager.onAction?(action)
    }

    static func registeredInstanceCountForTesting() -> Int {
        instances.filter { $0.value.manager != nil }.count
    }

    /// Whether `action` currently has an active Carbon hotkey registration.
    public func isRegistered(_ action: CCXHotKeyAction) -> Bool {
        hotKeyRefs[action] != nil && combos[action] != nil
    }

    /// Registers (or re-binds) `action` to `combo`. Returns `false` when the combo is
    /// already bound to another action of this manager or the system rejects it; in that
    /// case any previous binding of `action` is preserved.
    @discardableResult
    public func register(_ action: CCXHotKeyAction, combo: HotKeyCombo) -> Bool {
        let normalized = combo.normalized
        if combos[action] == normalized, hotKeyRefs[action] != nil {
            lastRegistrationStatus[action] = noErr
            return true
        }
        if combos.contains(where: { $0.key != action && $0.value == normalized }) {
            lastRegistrationStatus[action] = OSStatus(eventHotKeyExistsErr)
            return false
        }
        guard installEventHandlerIfNeeded(for: action) else { return false }

        let previous = combos[action]
        unregister(action)
        if registerCarbon(action, combo: normalized) { return true }
        let failureStatus = lastRegistrationStatus[action]
        if let previous { _ = registerCarbon(action, combo: previous) }
        if let failureStatus { lastRegistrationStatus[action] = failureStatus }
        return false
    }

    /// Validates structure, reserved shortcuts, active macOS symbolic hotkeys, internal duplicates,
    /// and exclusive Carbon registration before applying `combo` to `action`.
    /// On any conflict, the existing binding for `action` is left undisturbed.
    @discardableResult
    public func registerChecked(
        _ action: CCXHotKeyAction,
        combo: HotKeyCombo,
        symbolicHotKeysProvider: () -> Set<HotKeyCombo> = HotKeyConflictDetector.activeSystemSymbolicHotKeys
    ) -> HotKeyRegistrationResult {
        let normalized = combo.normalized
        if combos[action] == normalized, hotKeyRefs[action] != nil {
            lastRegistrationStatus[action] = noErr
            return .registered(normalized)
        }
        if let preConflict = HotKeyConflictDetector.checkPreRegistrationConflict(
            normalized,
            symbolicHotKeysProvider: symbolicHotKeysProvider
        ) {
            return .conflict(preConflict)
        }
        if let existing = combos.first(where: { $0.key != action && $0.value == normalized }) {
            lastRegistrationStatus[action] = OSStatus(eventHotKeyExistsErr)
            return .conflict(.internalConflict(normalized, action: existing.key))
        }
        if register(action, combo: normalized) {
            return .registered(normalized)
        }
        let status = lastRegistrationStatus[action] ?? OSStatus(eventHotKeyExistsErr)
        if status == OSStatus(eventHotKeyExistsErr) {
            return .conflict(.inUseByAnotherApp(normalized))
        }
        return .conflict(.registrationFailed(normalized, status))
    }

    public func unregister(_ action: CCXHotKeyAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        combos.removeValue(forKey: action)
    }

    public func unregisterAll() {
        for action in Array(combos.keys) {
            unregister(action)
        }
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    public func currentCombo(for action: CCXHotKeyAction) -> HotKeyCombo? {
        combos[action]
    }

    /// Registers every action with its factory-default combo.
    public func registerDefaults() {
        for action in CCXHotKeyAction.allCases where action.defaultCombo == nil {
            unregister(action)
        }
        for action in CCXHotKeyAction.allCases {
            if let combo = action.defaultCombo {
                register(action, combo: combo)
            }
        }
    }

    private func registerCarbon(_ action: CCXHotKeyAction, combo: HotKeyCombo) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: ccxHotKeySignature, id: action.carbonID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers & validCarbonModifierMask,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        lastRegistrationStatus[action] = status
        guard status == noErr, let ref else { return false }
        hotKeyRefs[action] = ref
        combos[action] = combo
        return true
    }

    private func installEventHandlerIfNeeded(for action: CCXHotKeyAction) -> Bool {
        if eventHandlerRef != nil { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            ccxHotKeyEventHandler,
            1,
            &spec,
            UnsafeMutableRawPointer(bitPattern: token),
            &handler
        )
        guard status == noErr, let handler else {
            lastRegistrationStatus[action] = status
            return false
        }
        eventHandlerRef = handler
        return true
    }
}
