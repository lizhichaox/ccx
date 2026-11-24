import AppKit
import Carbon.HIToolbox
@testable import CCXCore
import Foundation
import XCTest

final class HotKeyConflictTests: XCTestCase {
    func testComboNormalizedFunctionModifierOnlyAndTokens() {
        let withStrayBits = HotKeyCombo(
            keyCode: UInt32(kVK_ANSI_X),
            carbonModifiers: UInt32(controlKey | cmdKey | alphaLock)
        )
        XCTAssertEqual(withStrayBits.normalized, HotKeyCombo.defaultSnip)
        XCTAssertEqual(withStrayBits.normalized.carbonModifiers, UInt32(controlKey | cmdKey))

        let allFunctionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for code in allFunctionKeys {
            XCTAssertTrue(HotKeyCombo(keyCode: UInt32(code), carbonModifiers: 0).isFunctionKey)
        }
        XCTAssertFalse(HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0).isFunctionKey)
        XCTAssertFalse(HotKeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: 0).isFunctionKey)
        XCTAssertFalse(HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: 0).isFunctionKey)

        let modifierKeys = [
            kVK_Command, kVK_RightCommand,
            kVK_Shift, kVK_RightShift,
            kVK_Option, kVK_RightOption,
            kVK_Control, kVK_RightControl,
            kVK_CapsLock, kVK_Function,
        ]
        for code in modifierKeys {
            XCTAssertTrue(HotKeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(cmdKey)).isModifierOnlyKey)
        }
        XCTAssertFalse(HotKeyCombo.defaultSnip.isModifierOnlyKey)
        XCTAssertFalse(HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: 0).isModifierOnlyKey)

        XCTAssertEqual(HotKeyCombo.defaultSnip.tokens, ["⌃", "⌘", "X"])
        let allMods = HotKeyCombo(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
        XCTAssertEqual(allMods.tokens, ["⌃", "⌥", "⇧", "⌘", "Space"])
        XCTAssertEqual(allMods.tokens.joined(), allMods.displayString)
        XCTAssertEqual(HotKeyCombo(keyCode: UInt32(kVK_F12), carbonModifiers: 0).tokens, ["F12"])
    }

    func testConflictLocalizedDescriptions() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey))
        XCTAssertEqual(HotKeyConflict.modifierOnly.localizedDescription, "Add a key with ⌘, ⌃, or ⌥.")
        XCTAssertEqual(
            HotKeyConflict.missingModifier.localizedDescription,
            "Use ⌘, ⌃, ⌥, or F1–F20."
        )
        XCTAssertEqual(
            HotKeyConflict.escapeNotAllowed.localizedDescription,
            "Esc cannot be a shortcut."
        )
        XCTAssertEqual(
            HotKeyConflict.systemShortcut(combo).localizedDescription,
            "⇧⌘4 conflicts with macOS."
        )
        XCTAssertEqual(
            HotKeyConflict.reservedAppShortcut(combo, label: "Copy").localizedDescription,
            "⇧⌘4 is reserved for Copy."
        )
        XCTAssertEqual(
            HotKeyConflict.internalConflict(combo, action: .snip).localizedDescription,
            "⇧⌘4 is already used by Snip."
        )
        XCTAssertEqual(
            HotKeyConflict.inUseByAnotherApp(combo).localizedDescription,
            "⇧⌘4 is in use by another app."
        )
        XCTAssertEqual(
            HotKeyConflict.registrationFailed(combo, -50).localizedDescription,
            "Couldn't register ⇧⌘4 (-50)."
        )
    }

    @MainActor
    func testAllConflictDescriptionsFitSingleLineInSettings() {
        let font = NSFont.systemFont(ofSize: 10.5)
        let maxSettingsSublineWidth: CGFloat = 278.0
        let worstCombo = HotKeyCombo(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        XCTAssertEqual(worstCombo.displayString, "⌃⌥⇧⌘Space")

        var conflicts: [HotKeyConflict] = [
            .modifierOnly,
            .missingModifier,
            .escapeNotAllowed,
            .systemShortcut(worstCombo),
            .reservedAppShortcut(worstCombo, label: "App Switcher"),
            .inUseByAnotherApp(worstCombo),
            .registrationFailed(worstCombo, OSStatus(eventHotKeyExistsErr)),
        ]
        for action in CCXHotKeyAction.allCases {
            conflicts.append(.internalConflict(worstCombo, action: action))
        }
        for label in Set(HotKeyConflictDetector.reservedAppShortcuts.values) {
            conflicts.append(.reservedAppShortcut(worstCombo, label: label))
        }

        for conflict in conflicts {
            let text = conflict.localizedDescription
            XCTAssertFalse(text.isEmpty, "Conflict description must not be empty: \(conflict)")
            XCTAssertFalse(text.contains("\n"), "Conflict description must be single-line: \(text)")
            let width = ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
            XCTAssertLessThanOrEqual(
                width,
                maxSettingsSublineWidth,
                "Conflict prompt '\(text)' measured \(width)pt, exceeding \(maxSettingsSublineWidth)pt Settings sub-line budget"
            )
        }

        // Also verify Settings' unregistered sub-line fits cleanly beside the mini Retry button (283pt total).
        let unregisteredPrompt = "\(worstCombo.displayString) in use by another app."
        let unregisteredWidth = ceil(NSAttributedString(string: unregisteredPrompt, attributes: [.font: font]).size().width)
        XCTAssertLessThanOrEqual(
            unregisteredWidth,
            220.0,
            "Unregistered shortcut sub-line '\(unregisteredPrompt)' measured \(unregisteredWidth)pt, risking collision with Retry button"
        )
    }

    func testValidateStructure() {
        // Rejected: bare letter, Shift+letter, modifier-only, bare Escape.
        XCTAssertEqual(
            HotKeyConflictDetector.validateStructure(HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0)),
            .missingModifier
        )
        XCTAssertEqual(
            HotKeyConflictDetector.validateStructure(HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(shiftKey))),
            .missingModifier
        )
        XCTAssertEqual(
            HotKeyConflictDetector.validateStructure(HotKeyCombo(keyCode: UInt32(kVK_Command), carbonModifiers: UInt32(cmdKey))),
            .modifierOnly
        )
        XCTAssertEqual(
            HotKeyConflictDetector.validateStructure(HotKeyCombo(keyCode: UInt32(kVK_Function), carbonModifiers: 0)),
            .modifierOnly
        )
        XCTAssertEqual(
            HotKeyConflictDetector.validateStructure(HotKeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)),
            .escapeNotAllowed
        )

        // Accepted: primary modifiers or Function keys F1–F20.
        XCTAssertNil(HotKeyConflictDetector.validateStructure(.defaultSnip))
        XCTAssertNil(
            HotKeyConflictDetector.validateStructure(
                HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(optionKey | cmdKey))
            )
        )
        XCTAssertNil(
            HotKeyConflictDetector.validateStructure(
                HotKeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0)
            )
        )
        XCTAssertNil(
            HotKeyConflictDetector.validateStructure(
                HotKeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: UInt32(optionKey))
            )
        )
    }

    func testCheckPreRegistrationConflictReservedAndSystemSymbolicHotKeys() {
        let cmdC = HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey))
        let cmdQ = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey))
        let cmdW = HotKeyCombo(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: UInt32(cmdKey))
        let forceQuit = HotKeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(optionKey | cmdKey))
        let lockScreen = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(controlKey | cmdKey))
        let spotlight = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))

        XCTAssertEqual(
            HotKeyConflictDetector.checkPreRegistrationConflict(cmdC, symbolicHotKeysProvider: { [] }),
            .reservedAppShortcut(cmdC, label: "Copy")
        )
        XCTAssertEqual(
            HotKeyConflictDetector.checkPreRegistrationConflict(cmdQ, symbolicHotKeysProvider: { [] }),
            .reservedAppShortcut(cmdQ, label: "Quit")
        )
        XCTAssertEqual(
            HotKeyConflictDetector.checkPreRegistrationConflict(cmdW, symbolicHotKeysProvider: { [] }),
            .reservedAppShortcut(cmdW, label: "Close Window")
        )
        XCTAssertEqual(
            HotKeyConflictDetector.checkPreRegistrationConflict(forceQuit, symbolicHotKeysProvider: { [] }),
            .reservedAppShortcut(forceQuit, label: "Force Quit")
        )
        XCTAssertEqual(
            HotKeyConflictDetector.checkPreRegistrationConflict(lockScreen, symbolicHotKeysProvider: { [] }),
            .reservedAppShortcut(lockScreen, label: "Lock Screen")
        )
        XCTAssertEqual(
            HotKeyConflictDetector.checkPreRegistrationConflict(spotlight, symbolicHotKeysProvider: { [] }),
            .reservedAppShortcut(spotlight, label: "Spotlight")
        )

        // Active system symbolic hotkey (e.g. Shift+Cmd+4) is flagged when enabled, allowed when omitted.
        let shiftCmd4 = HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(shiftKey | cmdKey))
        XCTAssertEqual(
            HotKeyConflictDetector.checkPreRegistrationConflict(shiftCmd4, symbolicHotKeysProvider: { [shiftCmd4] }),
            .systemShortcut(shiftCmd4)
        )
        XCTAssertNil(
            HotKeyConflictDetector.checkPreRegistrationConflict(shiftCmd4, symbolicHotKeysProvider: { [] })
        )

        // Live CopySymbolicHotKeys query returns normalized combos without crashing.
        for combo in HotKeyConflictDetector.activeSystemSymbolicHotKeys() {
            XCTAssertEqual(combo, combo.normalized)
        }
    }

    @MainActor
    func testRegisterCheckedDetectsLiveExclusiveConflictAndPreservesPreviousHotKey() {
        let manager1 = GlobalHotKeyManager()
        let manager2 = GlobalHotKeyManager()
        defer {
            manager1.unregisterAll()
            manager2.unregisterAll()
        }

        let comboA = HotKeyCombo(keyCode: UInt32(kVK_F17), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))
        let comboB = HotKeyCombo(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | shiftKey))

        let firstResult = manager1.registerChecked(.snip, combo: comboA, symbolicHotKeysProvider: { [] })
        guard case .registered(let registeredA) = firstResult else {
            // Carbon event hotkey registration may be unavailable in restricted headless shells.
            return
        }
        XCTAssertEqual(registeredA, comboA)
        XCTAssertTrue(manager1.isRegistered(.snip))
        XCTAssertEqual(manager1.currentCombo(for: .snip), comboA)

        // Re-registering the same combo is a no-op returning .registered.
        XCTAssertEqual(
            manager1.registerChecked(.snip, combo: comboA, symbolicHotKeysProvider: { [] }),
            .registered(comboA)
        )

        // Pre-registration conflict must NOT disturb the active registration.
        let cmdC = HotKeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(
            manager1.registerChecked(.snip, combo: cmdC, symbolicHotKeysProvider: { [] }),
            .conflict(.reservedAppShortcut(cmdC, label: "Copy"))
        )
        XCTAssertTrue(manager1.isRegistered(.snip))
        XCTAssertEqual(manager1.currentCombo(for: .snip), comboA)

        // Register comboB exclusively in manager2, then attempt to switch manager1 to comboB.
        XCTAssertEqual(
            manager2.registerChecked(.snip, combo: comboB, symbolicHotKeysProvider: { [] }),
            .registered(comboB)
        )
        XCTAssertEqual(
            manager1.registerChecked(.snip, combo: comboB, symbolicHotKeysProvider: { [] }),
            .conflict(.inUseByAnotherApp(comboB))
        )

        // Previous working hotkey on manager1 must still be active!
        XCTAssertTrue(manager1.isRegistered(.snip))
        XCTAssertEqual(manager1.currentCombo(for: .snip), comboA)

        // Once manager2 releases comboB, manager1 can claim it cleanly.
        manager2.unregisterAll()
        XCTAssertEqual(
            manager1.registerChecked(.snip, combo: comboB, symbolicHotKeysProvider: { [] }),
            .registered(comboB)
        )
        XCTAssertEqual(manager1.currentCombo(for: .snip), comboB)
    }

    func testHotKeyPreferencesPersistenceDefaultCleanupAndCorruptFallback() throws {
        let suiteName = "com.lizhichaox.ccx.tests.hotkeys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default when unset.
        XCTAssertEqual(HotKeyPreferences.loadCombo(for: .snip, from: defaults), .defaultSnip)

        // Round-trip custom combo (and strips stray modifier bits).
        let customRaw = HotKeyCombo(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(optionKey | cmdKey | alphaLock)
        )
        let customNormalized = HotKeyCombo(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(optionKey | cmdKey)
        )
        HotKeyPreferences.saveCombo(customRaw, for: .snip, to: defaults)
        XCTAssertNotNil(defaults.data(forKey: HotKeyPreferences.snipComboKey))
        XCTAssertEqual(HotKeyPreferences.loadCombo(for: .snip, from: defaults), customNormalized)

        // Saving the default combo removes the persisted preference key cleanly.
        HotKeyPreferences.saveCombo(.defaultSnip, for: .snip, to: defaults)
        XCTAssertNil(defaults.object(forKey: HotKeyPreferences.snipComboKey))
        XCTAssertEqual(HotKeyPreferences.loadCombo(for: .snip, from: defaults), .defaultSnip)

        // Corrupt JSON falls back to default.
        defaults.set(Data("not valid json".utf8), forKey: HotKeyPreferences.snipComboKey)
        XCTAssertEqual(HotKeyPreferences.loadCombo(for: .snip, from: defaults), .defaultSnip)

        // Structurally invalid stored combo (e.g. bare letter or bare Esc) falls back to default.
        let invalidBareLetter = HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0)
        defaults.set(try JSONEncoder().encode(invalidBareLetter), forKey: HotKeyPreferences.snipComboKey)
        XCTAssertEqual(HotKeyPreferences.loadCombo(for: .snip, from: defaults), .defaultSnip)

        let invalidBareEsc = HotKeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)
        defaults.set(try JSONEncoder().encode(invalidBareEsc), forKey: HotKeyPreferences.snipComboKey)
        XCTAssertEqual(HotKeyPreferences.loadCombo(for: .snip, from: defaults), .defaultSnip)
    }
}
