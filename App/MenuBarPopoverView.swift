import AppKit
import CCXCore
import CCXPin
import CCXRecord
import SwiftUI

/// Live state backing the menu bar Control-Center-style popover.
@MainActor
final class MenuBarPanelModel: ObservableObject {
    @Published private(set) var pinCount = 0
    @Published private(set) var arePinsHidden = false
    @Published private(set) var hasClickThroughPins = false
    @Published private(set) var permissions: CCXPermissionStatus = PermissionManager.currentStatus()
    @Published private(set) var recentSnips: [SnipHistoryEntry] = []
    @Published private(set) var recordingStatus: RecordingMenuBarStatus?

    let snipShortcut = HotKeyCombo.defaultSnip.displayString
    @Published private(set) var isSnipHotKeyRegistered = true
    @Published private(set) var pinBadge = "Empty"
    @Published private(set) var isPinBadgeDimmed = true
    @Published private(set) var hasClipboardContent = false
    @Published private(set) var pinnedHistoryIDs: Set<UUID> = []

    func updateRecordingStatusOnly(_ recordingStatus: RecordingMenuBarStatus?) {
        let currentStatusKey = self.recordingStatus.map { ($0.isPaused, $0.formattedElapsed, $0.format) }
        let nextStatusKey = recordingStatus.map { ($0.isPaused, $0.formattedElapsed, $0.format) }
        if currentStatusKey?.0 != nextStatusKey?.0
            || currentStatusKey?.1 != nextStatusKey?.1
            || currentStatusKey?.2 != nextStatusKey?.2 {
            self.recordingStatus = recordingStatus
        }
    }

    func syncRecentSnipsOnly(clipboardStore: ClipboardStore) {
        let nextRecent = Array(clipboardStore.history.prefix(4))
        if recentSnips.map(\.id) != nextRecent.map(\.id) {
            recentSnips = nextRecent
        }
    }

    func sync(
        pinManager: PinManager,
        clipboardStore: ClipboardStore,
        recordingStatus: RecordingMenuBarStatus? = nil,
        isSnipHotKeyRegistered: Bool = true
    ) {
        let nextPinCount = pinManager.pinCount
        if pinCount != nextPinCount { pinCount = nextPinCount }

        let nextHidden = pinManager.arePinsHidden
        if arePinsHidden != nextHidden { arePinsHidden = nextHidden }

        let nextClickThrough = pinManager.hasClickThroughPins
        if hasClickThroughPins != nextClickThrough { hasClickThroughPins = nextClickThrough }

        let nextPermissions = PermissionManager.currentStatus()
        if permissions != nextPermissions { permissions = nextPermissions }

        if self.isSnipHotKeyRegistered != isSnipHotKeyRegistered {
            self.isSnipHotKeyRegistered = isSnipHotKeyRegistered
        }

        syncRecentSnipsOnly(clipboardStore: clipboardStore)
        updateRecordingStatusOnly(recordingStatus)

        let nextHasClipboard = clipboardStore.hasPasteboardContent
        if hasClipboardContent != nextHasClipboard { hasClipboardContent = nextHasClipboard }

        let nextPinnedIDs = Set(
            recentSnips.compactMap { entry in
                pinManager.isPinned(entry.pinIdentity) ? entry.id : nil
            }
        )
        if pinnedHistoryIDs != nextPinnedIDs { pinnedHistoryIDs = nextPinnedIDs }

        let nextBadge: String
        let nextDimmed: Bool
        switch pinManager.pinTileStatus() {
        case .empty:
            nextBadge = "Empty"
            nextDimmed = true
        case .allPinned:
            nextBadge = "All Pinned"
            nextDimmed = true
        case let .ready(count, primaryLabel):
            nextBadge = count > 1 ? "\(count) Ready" : primaryLabel
            nextDimmed = false
        }
        if pinBadge != nextBadge { pinBadge = nextBadge }
        if isPinBadgeDimmed != nextDimmed { isPinBadgeDimmed = nextDimmed }
    }
}

/// Action callbacks invoked from the popover UI (navigation/capture actions close
/// the panel; in-place actions such as Clear keep it open).
struct MenuBarPopoverActions {
    let onSnip: () -> Void
    let onRecord: () -> Void
    let onStopRecording: () -> Void
    let onTogglePauseRecording: () -> Void
    let onDiscardRecording: () -> Void
    let onPastePin: () -> Void
    let onClearClipboard: () -> Void
    let onPinHistory: (SnipHistoryEntry) -> Void
    let onClearHistory: () -> Void
    let onToggleAllPins: () -> Void
    let onUnlockClickThrough: () -> Void
    let onCloseAllPins: () -> Void
    let onOpenPermissions: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
}

/// Refined Liquid Glass menu bar popover replacing the legacy `NSMenu`.
struct MenuBarPopoverView: View {
    @ObservedObject var model: MenuBarPanelModel
    let actions: MenuBarPopoverActions

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            CCXBrandIcon(size: 38)

            if let recordingStatus = model.recordingStatus {
                ActiveRecordingBanner(
                    status: recordingStatus,
                    onTogglePause: actions.onTogglePauseRecording,
                    onStop: actions.onStopRecording,
                    onDiscard: actions.onDiscardRecording
                )
            } else {
                HStack(spacing: 8) {
                    QuickActionTile(
                        title: "Snip",
                        badge: model.isSnipHotKeyRegistered ? model.snipShortcut : "Conflict",
                        isBadgeDimmed: !model.isSnipHotKeyRegistered,
                        symbol: "viewfinder",
                        tint: model.isSnipHotKeyRegistered ? .blue : .orange,
                        tooltip: model.isSnipHotKeyRegistered
                            ? "Capture screen (\(model.snipShortcut))"
                            : "Shortcut \(model.snipShortcut) is in use by another app — check Settings",
                        action: actions.onSnip
                    )
                    QuickActionTile(
                        title: "Pin",
                        badge: model.pinBadge,
                        isBadgeDimmed: model.isPinBadgeDimmed,
                        symbol: "pin.fill",
                        tint: .indigo,
                        onClear: model.hasClipboardContent ? actions.onClearClipboard : nil,
                        clearTooltip: "Clear clipboard",
                        action: actions.onPastePin
                    )
                    QuickActionTile(
                        title: "Record",
                        badge: "Video · GIF",
                        symbol: "record.circle.fill",
                        tint: .red,
                        action: actions.onRecord
                    )
                }
            }

            if !model.recentSnips.isEmpty {
                RecentSnipsSection(
                    entries: model.recentSnips,
                    pinnedHistoryIDs: model.pinnedHistoryIDs,
                    onPinHistory: actions.onPinHistory,
                    onClearHistory: actions.onClearHistory
                )
            }

            if model.pinCount > 0 {
                FloatingPinsSection(
                    pinCount: model.pinCount,
                    arePinsHidden: model.arePinsHidden,
                    hasClickThroughPins: model.hasClickThroughPins,
                    onToggleAllPins: actions.onToggleAllPins,
                    onUnlockClickThrough: actions.onUnlockClickThrough,
                    onCloseAllPins: actions.onCloseAllPins
                )
            }

            UtilityFooterSection(
                permissions: model.permissions,
                onOpenPermissions: actions.onOpenPermissions,
                onOpenSettings: actions.onOpenSettings,
                onQuit: actions.onQuit
            )
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(width: 316)
        .fixedSize(horizontal: false, vertical: true)
        .ccxPopoverSurface(cornerRadius: 16)
    }
}

private struct ActiveRecordingBanner: View {
    let status: RecordingMenuBarStatus
    let onTogglePause: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        let tint: Color = status.isPaused ? .orange : .red
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(status.isPaused ? "Paused · \(status.format.label)" : "Recording · \(status.format.label)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(status.formattedElapsed)
                    .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
            }

            HStack(spacing: 6) {
                PinControlPill(
                    title: status.isPaused ? "Resume" : "Pause",
                    symbol: status.isPaused ? "play.fill" : "pause.fill",
                    tint: status.isPaused ? .cyan : .secondary,
                    isActive: status.isPaused,
                    action: onTogglePause
                )
                PinControlPill(
                    title: "Stop",
                    symbol: "stop.fill",
                    tint: .red,
                    isActive: true,
                    action: onStop
                )
                Button(action: onDiscard) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Cancel Recording")
                .accessibilityLabel("Cancel Recording")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Hero Quick Actions

private struct QuickActionTile: View {
    let title: String
    let badge: String
    var isBadgeDimmed = false
    let symbol: String
    let tint: Color
    var tooltip: String? = nil
    var onClear: (() -> Void)? = nil
    var clearTooltip: String = "Clear"
    let action: () -> Void

    @State private var isHovering = false
    @State private var isClearHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(
                        tint.opacity(isHovering ? 0.24 : 0.15),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(badge)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(isBadgeDimmed ? .tertiary : .secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHovering ? tint.opacity(0.35) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(tooltip ?? title)
        .overlay(alignment: .topTrailing) {
            if let onClear, isHovering {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isClearHovering ? Color.red : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(clearTooltip)
                .accessibilityLabel(clearTooltip)
                .padding(2)
                .onHover { isClearHovering = $0 }
            }
        }
        .contextMenu {
            if let onClear {
                Button(clearTooltip, action: onClear)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if !hovering {
                isClearHovering = false
            }
        }
    }
}

// MARK: - Recent Snips

private struct RecentSnipsSection: View {
    let entries: [SnipHistoryEntry]
    let pinnedHistoryIDs: Set<UUID>
    let onPinHistory: (SnipHistoryEntry) -> Void
    let onClearHistory: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Divider().opacity(0.45)

            ZStack {
                Text("RECENT SNIPS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                HStack {
                    Spacer()
                    RecentClearButton(action: onClearHistory)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                ForEach(entries) { entry in
                    RecentSnipThumbnail(entry: entry, isPinned: pinnedHistoryIDs.contains(entry.id)) {
                        onPinHistory(entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct RecentClearButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("Clear")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? Color.red.opacity(0.11) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help("Clear recent snips and clipboard")
        .onHover { isHovering = $0 }
    }
}

private struct RecentSnipThumbnail: View {
    let entry: SnipHistoryEntry
    let isPinned: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(decorative: entry.thumbnail, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60.5, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Circle()
                            .fill(Color.indigo)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .padding(3)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHovering ? Color.accentColor : Color.primary.opacity(0.14),
                            lineWidth: isHovering ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help("\(entry.image.width) × \(entry.image.height) · \(isPinned ? "Already pinned" : "Click to pin")")
        .accessibilityLabel("Recent snip \(entry.image.width) by \(entry.image.height), \(isPinned ? "already pinned" : "click to pin")")
        .onHover { isHovering = $0 }
    }
}

// MARK: - Floating Pins

private struct FloatingPinsSection: View {
    let pinCount: Int
    let arePinsHidden: Bool
    let hasClickThroughPins: Bool
    let onToggleAllPins: () -> Void
    let onUnlockClickThrough: () -> Void
    let onCloseAllPins: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Divider().opacity(0.45)

            HStack(spacing: 6) {
                Text("FLOATING PINS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                Text("\(pinCount) active")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    PinControlPill(
                        title: arePinsHidden ? "Show All" : "Hide All",
                        symbol: arePinsHidden ? "eye" : "eye.slash",
                        tint: arePinsHidden ? .accentColor : .secondary,
                        isActive: arePinsHidden,
                        action: onToggleAllPins
                    )

                    PinControlPill(
                        title: "Close All",
                        symbol: "xmark.circle",
                        tint: .secondary,
                        isDestructive: true,
                        action: onCloseAllPins
                    )
                }

                if hasClickThroughPins {
                    PinControlPill(
                        title: "Unlock Click-Through",
                        symbol: "cursorarrow.click",
                        tint: .cyan,
                        isActive: true,
                        action: onUnlockClickThrough
                    )
                }
            }
        }
    }
}

private struct PinControlPill: View {
    let title: String
    let symbol: String
    let tint: Color
    var isActive = false
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var foregroundColor: Color {
        if isHovering && isDestructive { return .red }
        if isActive { return tint }
        return .primary
    }

    private var backgroundColor: Color {
        if isHovering && isDestructive { return Color.red.opacity(0.11) }
        if isActive { return tint.opacity(isHovering ? 0.22 : 0.14) }
        return isHovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05)
    }

    private var borderColor: Color {
        if isHovering && isDestructive { return Color.red.opacity(0.32) }
        if isActive { return tint.opacity(0.35) }
        return Color.primary.opacity(0.08)
    }
}

// MARK: - Utility Dock

private struct UtilityFooterSection: View {
    let permissions: CCXPermissionStatus
    let onOpenPermissions: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.45)

            let allGranted = permissions.screenRecording && permissions.accessibility
            HStack(spacing: 6) {
                UtilityDockButton(
                    title: allGranted ? "Ready" : "Guide",
                    symbol: allGranted ? "checkmark.shield" : "exclamationmark.triangle.fill",
                    symbolTint: allGranted ? .green : .orange,
                    needsAttention: !allGranted,
                    tooltip: allGranted
                        ? "All permissions granted — click to open Guide"
                        : "Setup needed — click to open Permissions & Guide",
                    action: onOpenPermissions
                )

                UtilityDockButton(
                    title: "Settings",
                    symbol: "gearshape",
                    tooltip: "Settings (⌘,)",
                    action: onOpenSettings
                )

                UtilityDockButton(
                    title: "Quit",
                    symbol: "power",
                    isDestructive: true,
                    tooltip: "Quit CCX (⌘Q)",
                    action: onQuit
                )
            }
        }
    }
}

private struct UtilityDockButton: View {
    let title: String
    let symbol: String
    var symbolTint: Color? = nil
    var needsAttention = false
    var isDestructive = false
    let tooltip: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(resolvedSymbolColor)

                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(resolvedLabelColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hoverBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hoverBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovering = $0 }
    }

    private var resolvedSymbolColor: Color {
        if isDestructive && isHovering { return .red }
        if let symbolTint { return symbolTint }
        return isHovering ? .primary : .secondary
    }

    private var resolvedLabelColor: Color {
        if isDestructive && isHovering { return .red }
        if needsAttention { return .orange }
        return isHovering ? .primary : .secondary
    }

    private var hoverBackground: Color {
        if isDestructive && isHovering { return Color.red.opacity(0.11) }
        if needsAttention { return Color.orange.opacity(isHovering ? 0.18 : 0.10) }
        return isHovering ? Color.primary.opacity(0.08) : .clear
    }

    private var hoverBorder: Color {
        if isDestructive && isHovering { return Color.red.opacity(0.28) }
        if needsAttention { return Color.orange.opacity(isHovering ? 0.36 : 0.22) }
        return isHovering ? Color.primary.opacity(0.10) : .clear
    }
}

// MARK: - Surface

private extension View {
    @ViewBuilder
    func ccxPopoverSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
    }
}
