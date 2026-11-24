import CoreGraphics
import Foundation

/// Owns the committed annotations, active drawing draft, selection, and undo/redo history.
@MainActor
public final class AnnotationDocument {
    private struct Snapshot {
        let items: [AnnotationItem]
        let selectedID: UUID?
    }

    public static let maxUndoSnapshots = 60

    public private(set) var items: [AnnotationItem] = []
    public var draft: AnnotationItem?
    public var selectedID: UUID?

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty && draft == nil }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var selectedItem: AnnotationItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    /// Next sequential 1-based step number for the counter badge tool.
    public var nextCounterNumber: Int {
        let highest = items.compactMap { item -> Int? in
            if case let .counter(_, number) = item.kind { return number }
            return nil
        }.max() ?? 0
        return highest < Int.max ? highest + 1 : Int.max
    }

    /// Captures an undo checkpoint before a continuous edit (dragging or handle resizing).
    public func beginMutationSnapshot() {
        pushUndoSnapshot(Snapshot(items: items, selectedID: selectedID))
        redoStack.removeAll()
    }

    /// Appends a finished item onto the canvas and selects it.
    public func commit(_ item: AnnotationItem) {
        beginMutationSnapshot()
        items.append(item)
        selectedID = item.id
        draft = nil
    }

    /// Updates an existing item in place, optionally pushing an undo snapshot first.
    /// Avoids pushing a no-op undo snapshot when `updated` equals the existing item.
    @discardableResult
    public func replaceItem(_ updated: AnnotationItem, recordUndo: Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == updated.id }) else { return false }
        guard items[index] != updated else { return true }
        if recordUndo { beginMutationSnapshot() }
        items[index] = updated
        return true
    }

    /// Updates the style of the currently selected item, optionally pushing an undo snapshot first.
    @discardableResult
    public func updateSelectedStyle(recordUndo: Bool = true, _ transform: (inout AnnotationStyle) -> Void) -> Bool {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return false }
        var updated = items[index]
        transform(&updated.style)
        if case let .mosaic(rect, _) = updated.kind {
            updated.kind = .mosaic(rect, updated.style.mosaicMode)
        }
        guard updated != items[index] else { return false }
        if recordUndo {
            beginMutationSnapshot()
        }
        items[index] = updated
        return true
    }

    @discardableResult
    public func deleteSelected() -> Bool {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return false }
        beginMutationSnapshot()
        items.remove(at: index)
        self.selectedID = nil
        return true
    }

    /// Returns the front-most committed item under `point`.
    public func hitTestItem(at point: CGPoint) -> AnnotationItem? {
        items.reversed().first { $0.hitTest(point: point) }
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(Snapshot(items: items, selectedID: selectedID))
        items = previous.items
        selectedID = previous.selectedID
        draft = nil
        reconcileSelection()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        pushUndoSnapshot(Snapshot(items: items, selectedID: selectedID))
        items = next.items
        selectedID = next.selectedID
        draft = nil
        reconcileSelection()
        return true
    }

    public func clear() {
        items.removeAll()
        draft = nil
        selectedID = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Replaces the committed annotation items without altering `undoStack`/`redoStack`
    /// or resets undo history when rolling back a cancelled editing session.
    public func replaceAll(items: [AnnotationItem], selectedID: UUID?) {
        self.items = items
        self.draft = nil
        self.selectedID = selectedID
        undoStack.removeAll()
        redoStack.removeAll()
        reconcileSelection()
    }

    private func pushUndoSnapshot(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.maxUndoSnapshots {
            undoStack.removeFirst(undoStack.count - Self.maxUndoSnapshots)
        }
    }

    private func reconcileSelection() {
        guard let selectedID else { return }
        if !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }
}
