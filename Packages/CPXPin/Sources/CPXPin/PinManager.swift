import AppKit
import CPXCore

/// Owns every floating pin: creation, visibility, click-through, copy/save routing.
@MainActor
public final class PinManager {
    public private(set) var panels: [PinPanel] = []
    public private(set) var arePinsHidden = false

    public var pinCount: Int { panels.count }
    public var hasClickThroughPins: Bool { panels.contains { $0.state.isClickThrough } }

    /// Called whenever pins are added, removed, hidden/shown, or change state.
    public var onPinsChanged: (() -> Void)?
    /// Called when the user asks to save a pin (Cmd+S or "Save PNG…"); the host shows the
    /// save panel and typically calls `ClipboardStore.savePNG(_:to:)`.
    public var onRequestSavePNG: ((CGImage) -> Void)?

    private let clipboardStore: ClipboardStore

    public init(clipboardStore: ClipboardStore) {
        self.clipboardStore = clipboardStore
    }

    /// Pins `content`. With `screenRect` (AppKit global coordinates, points) the pin is
    /// placed exactly over that area so a fresh snip pins seamlessly; with `nil` it is
    /// centered on the screen containing the mouse, shrunk to fit if needed.
    public func pin(content: PinContent, at screenRect: CGRect?) {
        let baseSize = PinLayout.baseSize(for: content)
        let placement = PinLayout.initialPlacement(
            baseSize: baseSize,
            screenRect: screenRect,
            visibleFrame: Self.visibleFrameUnderMouse()
        )
        let panel = PinPanel(content: content, frame: placement.frame, state: PinState(zoom: placement.zoom))
        panel.onClose = { [weak self] panel in self?.panelDidClose(panel) }
        panel.onCopy = { [weak self] panel in self?.copy(panel) }
        panel.onSave = { [weak self] panel in self?.save(panel) }
        panel.onCloseAll = { [weak self] in self?.closeAllPins() }
        panel.onStateChanged = { [weak self] _ in self?.onPinsChanged?() }

        panels.append(panel)
        if arePinsHidden {
            // A new pin implies the user wants to see pins again.
            arePinsHidden = false
            panels.forEach { $0.orderFrontRegardless() }
        } else {
            panel.orderFrontRegardless()
        }
        onPinsChanged?()
    }

    /// Pins the current pasteboard content (image, HEX color, or text). Returns `false`
    /// when the pasteboard holds nothing pinnable.
    @discardableResult
    public func pinFromClipboard() -> Bool {
        guard let payload = clipboardStore.readPinPayload() else { return false }
        switch payload {
        case let .image(image, scale): pin(content: .image(image, scale: scale), at: nil)
        case let .color(color): pin(content: .color(color), at: nil)
        case let .text(text): pin(content: .text(text), at: nil)
        }
        return true
    }

    public func toggleVisibilityOfAllPins() {
        guard !panels.isEmpty else {
            arePinsHidden = false
            onPinsChanged?()
            return
        }
        arePinsHidden.toggle()
        for panel in panels {
            if arePinsHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        }
        onPinsChanged?()
    }

    public func disableClickThroughForAllPins() {
        for panel in panels where panel.state.isClickThrough {
            panel.setClickThrough(false)
        }
        onPinsChanged?()
    }

    public func closeAllPins() {
        let closing = panels
        panels.removeAll()
        for panel in closing {
            panel.onClose = nil
            panel.close()
        }
        arePinsHidden = false
        onPinsChanged?()
    }

    // MARK: - Private

    private func panelDidClose(_ panel: PinPanel) {
        panels.removeAll { $0 === panel }
        if panels.isEmpty { arePinsHidden = false }
        onPinsChanged?()
    }

    private func copy(_ panel: PinPanel) {
        switch panel.content {
        case let .text(text):
            clipboardStore.copyText(text)
        case let .color(color):
            clipboardStore.copyText(color.hexString)
        case .image:
            if let image = panel.exportImage() {
                clipboardStore.copyImage(image, scale: panel.exportScale)
            }
        }
    }

    private func save(_ panel: PinPanel) {
        guard let image = panel.exportImage() else { return }
        onRequestSavePNG?(image)
    }

    private static func visibleFrameUnderMouse() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
