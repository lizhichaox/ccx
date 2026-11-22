import AppKit

/// Process entry point. CPX is a menu bar (accessory) app without a main window,
/// so it boots `NSApplication` manually instead of using a SwiftUI `App` scene.
@main
@MainActor
enum CPXApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory policy keeps CPX out of the Dock and lets floating panels
        // appear above other apps' full-screen Spaces.
        app.setActivationPolicy(.accessory)
        // `NSApplication.delegate` is weak; keep the delegate alive for the
        // lifetime of the run loop.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
