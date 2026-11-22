import AppKit

/// Lightweight, non-activating floating pill that briefly confirms an action
/// (for example "Copied #FF3B30" or "Saved PNG") and fades out after ~1.4s.
@MainActor
final class ToastHUD {
    private static let fadeInDuration: TimeInterval = 0.15
    private static let holdDuration: TimeInterval = 1.0
    private static let fadeOutDuration: TimeInterval = 0.25

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .vibrantDark)

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.masksToBounds = true

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.contentTintColor = .white

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle

        background.addSubview(iconView)
        background.addSubview(label)
        panel.contentView = background
    }

    func show(_ message: String, symbolName: String = "checkmark.circle.fill") {
        hideTask?.cancel()

        label.stringValue = message
        label.sizeToFit()
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)

        let height: CGFloat = 36
        let horizontalPadding: CGFloat = 16
        let iconSize: CGFloat = 16
        let spacing: CGFloat = 8
        let labelWidth = min(ceil(label.frame.width), 420)
        let width = horizontalPadding * 2 + iconSize + spacing + labelWidth

        iconView.frame = NSRect(x: horizontalPadding, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        label.frame = NSRect(
            x: horizontalPadding + iconSize + spacing,
            y: (height - label.frame.height) / 2,
            width: labelWidth,
            height: label.frame.height
        )
        background.layer?.cornerRadius = height / 2

        let screen = Self.screenUnderMouse()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: (visible.midX - width / 2).rounded(),
            y: (visible.minY + visible.height * 0.18).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            panel.animator().alphaValue = 1
        }

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeInDuration + Self.holdDuration))
            guard !Task.isCancelled, let self else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeOutDuration
                self.panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
