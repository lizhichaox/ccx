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

        switch clipboardStore.readPinPayload() {
        case .image: clipboardBadge = "Image"
        case let .color(sample): clipboardBadge = sample.hexString
        case .text: clipboardBadge = "Text"
        case nil: clipboardBadge = "Empty"
        }
    }
}

/// Action callbacks invoked from the popover UI (panel closes before running).
struct MenuBarPopoverActions {
    let onSnip: () -> Void
    let onPastePin: () -> Void
    let onPinHistory: (SnipHistoryEntry) -> Void
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
        VStack(alignment: .leading, spacing: 9) {
            HeaderStrip(permissions: model.permissions, onOpenPermissions: actions.onOpenPermissions)

            HStack(spacing: 7) {
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
                    onPinHistory: actions.onPinHistory
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
        .padding(11)
        .frame(width: 272)
        .fixedSize(horizontal: false, vertical: true)
        .ccxPopoverSurface(cornerRadius: 15)
    }
}

// MARK: - Header

private struct HeaderStrip: View {
    let permissions: CCXPermissionStatus
    let onOpenPermissions: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                CCXBrandIcon(size: 22)

                Text("CCX")
                    .font(.system(size: 13.5, weight: .semibold))
            }

            Spacer()

            StatusBadge(permissions: permissions, onTap: onOpenPermissions)
        }
        .padding(.horizontal, 2)
    }
}

private struct StatusBadge: View {
    let permissions: CCXPermissionStatus
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        if permissions.screenRecording && permissions.accessibility {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5.5, height: 5.5)
                Text("Ready")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
        } else {
            let needsScreen = !permissions.screenRecording
            let pillTint: Color = needsScreen ? .orange : .yellow
            let pillTitle = needsScreen ? "Setup Needed" : "Accessibility"

            Button(action: onTap) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(pillTint)
                        .frame(width: 5.5, height: 5.5)
                    Text(pillTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(needsScreen ? Color.orange : Color.primary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    pillTint.opacity(isHovering ? 0.22 : 0.14),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)
                        .background(
                            tint.opacity(isHovering ? 0.22 : 0.14),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )

                    Spacer(minLength: 4)

                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(isBadgeDimmed ? .tertiary : .secondary)
                        .lineLimit(1)
                }

                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().opacity(0.6)

            HStack {
                Text("RECENT SNIPS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                Text("Click to pin")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 5) {
                ForEach(entries) { entry in
                    RecentSnipThumbnail(entry: entry) {
                        onPinHistory(entry)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct RecentSnipThumbnail: View {
    let entry: SnipHistoryEntry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: NSImage(cgImage: entry.image, size: .zero))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 58, height: 38)
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
        VStack(alignment: .leading, spacing: 5) {
            Divider().opacity(0.6)

            HStack {
                Text("FLOATING PINS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)

                Spacer()

                Text("\(pinCount) active")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 2)

            VStack(spacing: 5) {
                HStack(spacing: 5) {
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
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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

// MARK: - Utility Footer

private struct UtilityFooterSection: View {
    let permissions: CCXPermissionStatus
    let onOpenPermissions: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().opacity(0.6)
                .padding(.bottom, 1)

            let allGranted = permissions.screenRecording && permissions.accessibility
            MenuActionRow(
                title: "Permissions & Guide…",
                symbol: allGranted ? "checkmark.shield" : "exclamationmark.triangle.fill",
                symbolTint: allGranted ? .green : .orange,
                trailingDotColor: allGranted ? .green : .orange,
                action: onOpenPermissions
            )

            MenuActionRow(
                title: "Settings…",
                symbol: "gearshape",
                shortcut: "⌘,",
                action: onOpenSettings
            )

            Divider().opacity(0.6)
                .padding(.vertical, 1)

            MenuActionRow(
                title: "Quit CCX",
                symbol: "power",
                shortcut: "⌘Q",
                isDestructive: true,
                action: onQuit
            )
        }
    }
}

// MARK: - Uniform Row & Surface

private struct MenuActionRow: View {
    let title: String
    let symbol: String
    var symbolTint: Color? = nil
    var shortcut: String? = nil
    var trailingDotColor: Color? = nil
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(resolvedSymbolColor)
                    .frame(width: 16, alignment: .center)

                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isHovering && isDestructive ? Color.red : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 10)

                if let trailingDotColor {
                    Circle()
                        .fill(trailingDotColor)
                        .frame(width: 6.5, height: 6.5)
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hoverBackground)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var resolvedSymbolColor: Color {
        if isHovering && isDestructive { return .red }
        return symbolTint ?? .secondary
    }

    private var hoverBackground: Color {
        guard isHovering else { return .clear }
        return isDestructive ? Color.red.opacity(0.11) : Color.primary.opacity(0.08)
    }
}

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
