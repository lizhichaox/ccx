import AppKit
import Carbon.HIToolbox
import Foundation

/// Global actions that can be bound to a system-wide hotkey.
public enum CPXHotKeyAction: String, CaseIterable, Sendable, Codable {
    case snip
    case pastePin
    case toggleAllPins
    case unlockClickThrough

    /// Human-readable title for settings and menus.
    public var displayName: String {
        switch self {
        case .snip: "Snip"
        case .pastePin: "Paste as Pin"
        case .toggleAllPins: "Hide/Show All Pins"
        case .unlockClickThrough: "Unlock Click-Through Pins"
        }
    }

    /// The factory-default combo for this action.
    public var defaultCombo: HotKeyCombo {
        switch self {
        case .snip: .defaultSnip
        case .pastePin: .defaultPastePin
        case .toggleAllPins: .defaultToggleAllPins
        case .unlockClickThrough: .defaultUnlockClickThrough
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

    /// `F1`
    public static let defaultSnip = HotKeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0)
    /// `F3`
    public static let defaultPastePin = HotKeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0)
    /// `Shift+F3`
    public static let defaultToggleAllPins = HotKeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: UInt32(shiftKey))
    /// `Option+Shift+F3`
    public static let defaultUnlockClickThrough = HotKeyCombo(
        keyCode: UInt32(kVK_F3),
        carbonModifiers: UInt32(optionKey | shiftKey)
    )

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

    /// Mac-style shortcut string, modifiers in canonical `⌃⌥⇧⌘` order, e.g. `⌥⇧F3`.
    public var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += KeyCodeNames.name(for: keyCode)
        return result
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

/// Four-char code `'CPXH'` tagging every hotkey registered by CPX.
private let cpxHotKeySignature: OSType = 0x4350_5848

/// Carbon event callback. Carbon delivers hotkey events on the main thread through the
/// application event target; the `userData` pointer carries an integer token (not a
/// retained object), so no Swift object crosses the C boundary unsafely.
private func cpxHotKeyEventHandler(
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
    guard status == noErr, hotKeyID.signature == cpxHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let token = UInt(bitPattern: userData)
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
    public var onAction: ((CPXHotKeyAction) -> Void)?

    private var combos: [CPXHotKeyAction: HotKeyCombo] = [:]
    // Carbon refs are only touched on the main actor, plus once from `deinit`.
    nonisolated(unsafe) private var hotKeyRefs: [CPXHotKeyAction: EventHotKeyRef] = [:]
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    private let token: UInt

    private final class WeakBox {
        weak var manager: GlobalHotKeyManager?
        init(_ manager: GlobalHotKeyManager) { self.manager = manager }
    }

    private static var nextToken: UInt = 1
    private static var instances: [UInt: WeakBox] = [:]

    public init() {
        token = Self.nextToken
        Self.nextToken += 1
        Self.instances = Self.instances.filter { $0.value.manager != nil }
        Self.instances[token] = WeakBox(self)
    }

    deinit {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    static func dispatch(token: UInt, carbonID: UInt32) {
        guard let manager = instances[token]?.manager,
              let action = CPXHotKeyAction(carbonID: carbonID),
              manager.combos[action] != nil
        else { return }
        manager.onAction?(action)
    }

    /// Registers (or re-binds) `action` to `combo`. Returns `false` when the combo is
    /// already bound to another action of this manager or the system rejects it; in that
    /// case any previous binding of `action` is preserved.
    @discardableResult
    public func register(_ action: CPXHotKeyAction, combo: HotKeyCombo) -> Bool {
        if combos[action] == combo, hotKeyRefs[action] != nil { return true }
        if combos.contains(where: { $0.key != action && $0.value == combo }) { return false }
        guard installEventHandlerIfNeeded() else { return false }

        let previous = combos[action]
        unregister(action)
        if registerCarbon(action, combo: combo) { return true }
        if let previous { _ = registerCarbon(action, combo: previous) }
        return false
    }

    public func unregister(_ action: CPXHotKeyAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
        combos.removeValue(forKey: action)
    }

    public func unregisterAll() {
        for action in Array(combos.keys) {
            unregister(action)
        }
    }

    public func currentCombo(for action: CPXHotKeyAction) -> HotKeyCombo? {
        combos[action]
    }

    /// Registers every action with its factory-default combo.
    public func registerDefaults() {
        for action in CPXHotKeyAction.allCases {
            register(action, combo: action.defaultCombo)
        }
    }

    private func registerCarbon(_ action: CPXHotKeyAction, combo: HotKeyCombo) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: cpxHotKeySignature, id: action.carbonID)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRefs[action] = ref
        combos[action] = combo
        return true
    }

    private func installEventHandlerIfNeeded() -> Bool {
        if eventHandlerRef != nil { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            cpxHotKeyEventHandler,
            1,
            &spec,
            UnsafeMutableRawPointer(bitPattern: token),
            &handler
        )
        guard status == noErr, let handler else { return false }
        eventHandlerRef = handler
        return true
    }
}
