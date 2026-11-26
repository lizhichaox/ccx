import AppKit

/// Lightweight, non-activating floating pill that briefly confirms an action
/// (for example "Copied #FF3B30" or "Saved PNG") and fades out smoothly.
@MainActor
final class ToastHUD {
    private static let fadeInDuration: TimeInterval = 0.14
    private static let shortHoldDuration: TimeInterval = 1.15
    private static let mediumHoldDuration: TimeInterval = 1.75
    private static let extendedHoldDuration: TimeInterval = 2.30
    private static let fadeOutDuration: TimeInterval = 0.24

    private let panel: NSPanel
    private let surfaceView: NSView
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    nonisolated(unsafe) private var hideTask: Task<Void, Never>?

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
        panel.sharingType = .none
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .vibrantDark)

        let hostSurface: NSView
        let contentContainer: NSView

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 18
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true

            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            glass.contentView = content

            hostSurface = glass
            contentContainer = content
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 1
            effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

            hostSurface = effect
            contentContainer = effect
        }

        self.surfaceView = hostSurface

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .white

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle

        contentContainer.addSubview(iconView)
        contentContainer.addSubview(label)
        panel.contentView = hostSurface
    }

    deinit {
        hideTask?.cancel()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    func show(_ message: String, symbolName: String = "checkmark.circle.fill") {
        hideTask?.cancel()

        label.stringValue = message
        label.sizeToFit()
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = Self.symbolTintColor(for: symbolName)

        let screen = WindowScreenLocator.activeCursorScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let height: CGFloat = 36
        let horizontalPadding: CGFloat = 15
        let iconSize: CGFloat = 16
        let spacing: CGFloat = 8
        let maxLabelWidth = max(120, min(560, visible.width - horizontalPadding * 2 - iconSize - spacing - 32))
        let labelWidth = min(ceil(label.frame.width), maxLabelWidth)
        let width = horizontalPadding * 2 + iconSize + spacing + labelWidth

        iconView.frame = NSRect(x: horizontalPadding, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        label.frame = NSRect(
            x: horizontalPadding + iconSize + spacing,
            y: ((height - label.frame.height) / 2).rounded(),
            width: labelWidth,
            height: label.frame.height
        )

        let radius = height / 2
        if #available(macOS 26.0, *), let glass = surfaceView as? NSGlassEffectView {
            glass.cornerRadius = radius
            glass.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        surfaceView.layer?.cornerRadius = radius
        surfaceView.layer?.cornerCurve = .continuous

        let minX = visible.minX + 16
        let maxX = max(minX, visible.maxX - width - 16)
        let minY = visible.minY + 16
        let maxY = max(minY, visible.maxY - height - 16)
        let desiredY = (visible.minY + visible.height * 0.18).rounded()
        let origin = NSPoint(
            x: min(max((visible.midX - width / 2).rounded(), minX), maxX),
            y: min(max(desiredY, minY), maxY)
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.invalidateShadow()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = panel.isVisible && panel.alphaValue > 0.1
        if !wasVisible {
            panel.alphaValue = reduceMotion ? 1 : 0
        }
        panel.orderFrontRegardless()
        if reduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = wasVisible ? 0.08 : Self.fadeInDuration
                panel.animator().alphaValue = 1
            }
        }

        let isWarning = symbolName.hasPrefix("exclamationmark.")
        let announcementPriority: NSAccessibilityPriorityLevel = isWarning ? .high : .medium
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: announcementPriority.rawValue,
            ]
        )

        let holdDuration = Self.holdDuration(for: message, isWarning: isWarning)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeInDuration + holdDuration))
            guard !Task.isCancelled, let self else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.panel.alphaValue = 0
            } else {
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeOutDuration
                    self.panel.animator().alphaValue = 0
                }
            }
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }

    private static func holdDuration(for message: String, isWarning: Bool) -> TimeInterval {
        if isWarning || message.count >= 30 {
            return extendedHoldDuration
        }
        if message.count >= 20 {
            return mediumHoldDuration
        }
        return shortHoldDuration
    }

    private static func symbolTintColor(for symbolName: String) -> NSColor {
        if symbolName.hasPrefix("checkmark.") {
            return NSColor(srgbRed: 0.30, green: 0.86, blue: 0.50, alpha: 1)
        }
        if symbolName.hasPrefix("exclamationmark.") {
            return NSColor(srgbRed: 1.00, green: 0.72, blue: 0.28, alpha: 1)
        }
        if symbolName.hasPrefix("record.circle") {
            return NSColor(srgbRed: 1.00, green: 0.44, blue: 0.42, alpha: 1)
        }
        if symbolName == "eyedropper" || symbolName == "cursorarrow.click" {
            return NSColor(srgbRed: 0.28, green: 0.86, blue: 0.92, alpha: 1)
        }
        if symbolName.hasPrefix("folder") {
            return NSColor(srgbRed: 1.00, green: 0.70, blue: 0.28, alpha: 1)
        }
        if symbolName == "text.viewfinder"
            || symbolName == "keyboard"
            || symbolName == "square.and.arrow.down"
            || symbolName == "doc.on.doc"
            || symbolName.hasPrefix("arrow.counterclockwise")
        {
            return NSColor(srgbRed: 0.40, green: 0.76, blue: 1.00, alpha: 1)
        }
        return .white
    }
}
