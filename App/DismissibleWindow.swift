import AppKit

/// Standard CCX window that dismisses cleanly on `Esc` and `⌘W`, even when running
/// as an `.accessory` menu bar app without a main menu bar.
@MainActor
final class DismissibleWindow: NSWindow {
    /// Suppresses `Esc` and `⌘W` window dismissal while a child control (such as a shortcut recorder) captures key events.
    var suppressDismissKeyEquivalents = false

    override func cancelOperation(_ sender: Any?) {
        guard !suppressDismissKeyEquivalents else { return }
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !suppressDismissKeyEquivalents, event.type == .keyDown {
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])

            if flags.isEmpty && event.keyCode == 53 {
                performClose(nil)
                return true
            }

            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                performClose(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
