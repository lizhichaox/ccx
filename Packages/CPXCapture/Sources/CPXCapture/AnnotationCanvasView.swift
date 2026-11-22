import AppKit
import CPXAnnotate

/// Transparent non-hit-testing canvas rendering all committed, draft, and selected annotations.
@MainActor
final class AnnotationCanvasView: NSView {
    let document: AnnotationDocument
    let mosaicCache: MosaicImageCache
    var clipRect: CGRect?
    var backingScale: CGFloat = 1
    var editingTextItemID: UUID?

    init(frame frameRect: NSRect, document: AnnotationDocument, mosaicCache: MosaicImageCache, backingScale: CGFloat) {
        self.document = document
        self.mosaicCache = mosaicCache
        self.backingScale = backingScale
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        if let clipRect {
            context.clip(to: clipRect)
        }
        let scale = backingScale
        let cache = mosaicCache
        let screenBounds = bounds
        for item in document.items where item.id != editingTextItemID {
            AnnotationRenderer.draw(item, in: context, screenBounds: screenBounds) { mode, preset in
                cache.filteredImage(mode: mode, preset: preset, backingScale: scale)
            }
        }
        if let draft = document.draft {
            AnnotationRenderer.draw(draft, in: context, screenBounds: screenBounds) { mode, preset in
                cache.filteredImage(mode: mode, preset: preset, backingScale: scale)
            }
        }
        context.restoreGState()

        if let selected = document.selectedItem, selected.id != editingTextItemID {
            AnnotationRenderer.drawSelectionChrome(for: selected, in: context)
        }
    }
}
