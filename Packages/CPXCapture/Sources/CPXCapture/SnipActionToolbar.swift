import AppKit

/// Actions offered by the floating snip toolbar.
enum SnipToolbarAction: Sendable {
    case pin, copy, save, cancel
}

/// Floating action toolbar shown below/above a finished selection.
///
/// Uses Liquid Glass (`NSGlassEffectView`) on macOS 26+, otherwise a dark `NSVisualEffectView`.
@MainActor
final class SnipActionToolbar: NSView {
    static let preferredSize = CGSize(width: 4 * 36 + 3 * 2 + 16, height: 40)

    var onAction: ((SnipToolbarAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        let stack = NSStackView(views: [
            makeButton(symbol: "pin", tooltip: "Pin (Return)", action: .pin),
            makeButton(symbol: "doc.on.doc", tooltip: "Copy (⌘C)", action: .copy),
            makeButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", action: .save),
            makeButton(symbol: "xmark", tooltip: "Cancel (Esc)", action: .cancel),
        ])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 12
            glass.style = .regular
            glass.contentView = stack
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                stack.topAnchor.constraint(equalTo: effect.topAnchor),
                stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            background = effect
        }
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    private func makeButton(symbol: String, tooltip: String, action: SnipToolbarAction) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = ToolbarButton(image: image, target: nil, action: nil)
        button.snipAction = action
        button.target = self
        button.action = #selector(buttonPressed(_:))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = action == .cancel ? .systemRed : .white
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = (sender as? ToolbarButton)?.snipAction else { return }
        onAction?(action)
    }

    /// Anchors the toolbar below the selection (right-aligned), else above, else inside; clamped to `bounds`.
    static func frame(for selection: CGRect, in bounds: CGRect, topInset: CGFloat) -> CGRect {
        let size = preferredSize
        let gap: CGFloat = 8
        let usableMaxY = bounds.maxY - topInset
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.minY - gap - size.height)
        if origin.y < bounds.minY {
            origin.y = selection.maxY + gap
            if origin.y + size.height > usableMaxY {
                origin.y = selection.minY + gap
            }
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), usableMaxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

private final class ToolbarButton: NSButton {
    var snipAction: SnipToolbarAction = .cancel
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
