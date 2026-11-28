import AppKit

/// Bounded cache of vector-rendered circular brush `NSCursor` instances keyed by
/// rounded point diameter (`6...96pt`) and tool visual style (`freehand` vs `mosaic`).
@MainActor
public final class BrushCursorCache {
    public enum Kind: Hashable, Sendable {
        case freehand
        case mosaic
    }

    private struct Key: Hashable {
        let diameterPoints: Int
        let kind: Kind
    }

    public static let shared = BrushCursorCache()
    public static let minimumDiameter: CGFloat = 6
    public static let maximumDiameter: CGFloat = 96
    public static let maxCachedCursors = 32

    private var cursors: [Key: NSCursor] = [:]
    private var accessOrder: [Key] = []

    public init() {}

    /// Returns a centered circular crosshair cursor sized to `diameter` points.
    public func cursor(diameter: CGFloat, kind: Kind) -> NSCursor {
        let sanitized = diameter.isFinite ? diameter : 12
        let clamped = max(Self.minimumDiameter, min(Self.maximumDiameter, sanitized))
        let quantized = Int(clamped.rounded())
        let key = Key(diameterPoints: quantized, kind: kind)

        if let cached = cursors[key] {
            touch(key)
            return cached
        }

        let built = Self.makeBrushCursor(diameterPoints: CGFloat(quantized), kind: kind)
        cursors[key] = built
        touch(key)
        while cursors.count > Self.maxCachedCursors, let evicted = accessOrder.first {
            accessOrder.removeFirst()
            cursors.removeValue(forKey: evicted)
        }
        return built
    }

    public func cachedCountForTesting() -> Int {
        cursors.count
    }

    public func clear() {
        cursors.removeAll()
        accessOrder.removeAll()
    }

    private func touch(_ key: Key) {
        if let idx = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: idx)
        }
        accessOrder.append(key)
    }

    private static func makeBrushCursor(diameterPoints: CGFloat, kind: Kind) -> NSCursor {
        let side = diameterPoints + 8
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let ringRect = NSRect(
                x: (bounds.width - diameterPoints) / 2,
                y: (bounds.height - diameterPoints) / 2,
                width: diameterPoints,
                height: diameterPoints
            )
            let halo = NSBezierPath(ovalIn: ringRect)
            halo.lineWidth = 2.4
            NSColor.black.withAlphaComponent(0.55).setStroke()
            halo.stroke()

            let inner = NSBezierPath(ovalIn: ringRect)
            inner.lineWidth = 1.25
            let ringColor: NSColor = switch kind {
            case .freehand:
                NSColor.white.withAlphaComponent(0.95)
            case .mosaic:
                NSColor.systemTeal.withAlphaComponent(0.95)
            }
            ringColor.setStroke()
            inner.stroke()

            // Crisp center dot so exact stroke pivot stays clear at larger diameters.
            if diameterPoints >= 14 {
                let dotRect = NSRect(
                    x: bounds.midX - 1,
                    y: bounds.midY - 1,
                    width: 2,
                    height: 2
                )
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
