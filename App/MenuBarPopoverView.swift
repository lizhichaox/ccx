import AppKit
import CCXCore
import CCXPin
import SwiftUI

/// Live state backing the menu bar Control-Center-style popover.
@MainActor
final class MenuBarPanelModel: ObservableObject {
    @Published private(set) var pinCount = 0
    @Published private(set) var arePinsHidden = false
    @Published private(set) var hasClickThroughPins = false
    @Published private(set) var permissions: CCXPermissionStatus = PermissionManager.currentStatus()
    @Published private(set) var recentSnips: [SnipHistoryEntry] = []

    let snipShortcut = HotKeyCombo.defaultSnip.displayString
    @Published private(set) var clipboardBadge = "Empty"

    func sync(
        pinManager: PinManager,
        clipboardStore: ClipboardStore
    ) {
        pinCount = pinManager.pinCount
        arePinsHidden = pinManager.arePinsHidden
        hasClickThroughPins = pinManager.hasClickThroughPins
        permissions = PermissionManager.currentStatus()
        recentSnips = Array(clipboardStore.history.prefix(4))

        clipboardBadge = clipboardStore.peekPinBadge().displayText
    }
}

/// Action callbacks invoked from the popover UI (navigation/capture actions close
/// the panel; in-place actions such as Clear keep it open).
struct MenuBarPopoverActions {
    let onSnip: () -> Void
    let onPastePin: () -> Void
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

            HStack(spacing: 8) {
                QuickActionTile(
                    title: "Snip",
                    badge: model.snipShortcut,
                    symbol: "viewfinder",
                    tint: .blue,
                    action: actions.onSnip
                )
                QuickActionTile(
                    title: "Paste Pin",
                    badge: model.clipboardBadge,
                    isBadgeDimmed: model.clipboardBadge == "Empty",
                    symbol: "pin.fill",
                    tint: .indigo,
                    action: actions.onPastePin
                )
            }

            if !model.recentSnips.isEmpty {
                RecentSnipsSection(
                    entries: model.recentSnips,
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
        .frame(width: 276)
        .fixedSize(horizontal: false, vertical: true)
        .ccxPopoverSurface(cornerRadius: 16)
    }
}

// MARK: - Hero Quick Actions

private struct QuickActionTile: View {
    let title: String
    let badge: String
    var isBadgeDimmed = false
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

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
        .onHover { isHovering = $0 }
    }
}

// MARK: - Recent Snips

private struct RecentSnipsSection: View {
    let entries: [SnipHistoryEntry]
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
                    RecentSnipThumbnail(entry: entry) {
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
        .help("Clear all recent snips")
        .onHover { isHovering = $0 }
    }
}

private struct RecentSnipThumbnail: View {
    let entry: SnipHistoryEntry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: NSImage(cgImage: entry.thumbnail, size: .zero))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 57.5, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHovering ? Color.accentColor : Color.primary.opacity(0.14),
                            lineWidth: isHovering ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help("\(entry.image.width) × \(entry.image.height) · Click to pin")
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
