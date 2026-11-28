import AppKit
import CCXAnnotate

/// Transparent non-hit-testing canvas rendering all committed, draft, and selected annotations.
@MainActor
final class AnnotationCanvasView: NSView {
    let document: AnnotationDocument
    let mosaicCache: MosaicImageCache
    var clipRect: CGRect?
    var clipCornerRadii: AdaptiveCornerRadii = .zero
    var backingScale: CGFloat = 1
    var editingTextItemID: UUID?
    private var lastDirtyRect: CGRect?

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

    private static let redrawPadding: CGFloat = 64

    /// Invalidates the union of the previous and current active item bounds so dragging stays localized.
    func invalidate(rect: CGRect?) {
        let padded = rect?.insetBy(dx: -Self.redrawPadding, dy: -Self.redrawPadding)
        let dirty: CGRect?
        switch (lastDirtyRect, padded) {
        case let (.some(prev), .some(curr)):
            dirty = prev.union(curr)
        case let (.some(prev), .none):
            dirty = prev
        case let (.none, .some(curr)):
            dirty = curr
        case (.none, .none):
            dirty = nil
        }
        lastDirtyRect = padded
        if let target = dirty?.intersection(bounds), !target.isNull, !target.isEmpty {
            setNeedsDisplay(target)
        } else {
            lastDirtyRect = nil
            needsDisplay = true
        }
    }

    /// Invalidates only the active selection clip region (plus handle padding) or the full canvas if unselected.
    func invalidateActiveRegion() {
        lastDirtyRect = nil
        if let clipRect {
            let target = clipRect.insetBy(dx: -Self.redrawPadding, dy: -Self.redrawPadding).intersection(bounds)
            if !target.isNull, !target.isEmpty {
                setNeedsDisplay(target)
                return
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        if let clipRect {
            if clipCornerRadii.isAllZero {
                context.clip(to: clipRect)
            } else {
                context.addPath(WindowCornerMaskExtractor.makeRoundedRectPath(rect: clipRect, radii: clipCornerRadii))
                context.clip()
            }
        }
        let scale = backingScale
        let cache = mosaicCache
        let screenBounds = bounds
        let cullPadding = Self.redrawPadding
        for item in document.items where item.id != editingTextItemID {
            guard item.boundingBox.insetBy(dx: -cullPadding, dy: -cullPadding).intersects(dirtyRect) else {
                continue
            }
            AnnotationRenderer.draw(item, in: context, screenBounds: screenBounds) { mode, size in
                cache.filteredSurface(mode: mode, size: size, backingScale: scale)
            }
        }
        if let draft = document.draft {
            AnnotationRenderer.draw(draft, in: context, screenBounds: screenBounds) { mode, size in
                cache.filteredSurface(mode: mode, size: size, backingScale: scale)
            }
        }
        for item in document.items where item.id != editingTextItemID && item.id != document.selectedID {
            if case let .mosaic(raw, _) = item.kind,
               item.boundingBox.insetBy(dx: -cullPadding, dy: -cullPadding).intersects(dirtyRect) {
                AnnotationRenderer.drawMosaicGuide(for: raw, isDraft: false, in: context)
            }
        }
        if let draft = document.draft, case let .mosaic(raw, _) = draft.kind {
            AnnotationRenderer.drawMosaicGuide(for: raw, isDraft: true, in: context)
        }
        context.restoreGState()

        if let selected = document.selectedItem,
           selected.id != editingTextItemID,
           selected.boundingBox.insetBy(dx: -cullPadding, dy: -cullPadding).intersects(dirtyRect) {
            AnnotationRenderer.drawSelectionChrome(for: selected, in: context)
        }
    }
}
