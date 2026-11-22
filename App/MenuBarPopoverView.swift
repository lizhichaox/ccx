import AppKit
import CPXCore
import CPXPin
import SwiftUI

/// Live state backing the menu bar Control-Center-style popover.
@MainActor
final class MenuBarPanelModel: ObservableObject {
    @Published private(set) var pinCount = 0
    @Published private(set) var arePinsHidden = false
    @Published private(set) var hasClickThroughPins = false
    @Published private(set) var permissions: CPXPermissionStatus = PermissionManager.currentStatus()
    @Published private(set) var recentSnips: [SnipHistoryEntry] = []

    @Published private(set) var snipShortcut = HotKeyCombo.defaultSnip.displayString
    @Published private(set) var pastePinShortcut = HotKeyCombo.defaultPastePin.displayString
    @Published private(set) var togglePinsShortcut = HotKeyCombo.defaultToggleAllPins.displayString
    @Published private(set) var unlockClickThroughShortcut = HotKeyCombo.defaultUnlockClickThrough.displayString

    func sync(
        pinManager: PinManager,
        hotKeyManager: GlobalHotKeyManager,
        clipboardStore: ClipboardStore
    ) {
        pinCount = pinManager.pinCount
        arePinsHidden = pinManager.arePinsHidden
        hasClickThroughPins = pinManager.hasClickThroughPins
        permissions = PermissionManager.currentStatus()
        recentSnips = Array(clipboardStore.history.prefix(4))

        snipShortcut = comboString(.snip, on: hotKeyManager)
        pastePinShortcut = comboString(.pastePin, on: hotKeyManager)
        togglePinsShortcut = comboString(.toggleAllPins, on: hotKeyManager)
        unlockClickThroughShortcut = comboString(.unlockClickThrough, on: hotKeyManager)
    }

    private func comboString(_ action: CPXHotKeyAction, on manager: GlobalHotKeyManager) -> String {
        (manager.currentCombo(for: action) ?? HotKeyPreferences.defaultCombo(for: action)).displayString
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
        VStack(alignment: .leading, spacing: 12) {
            HeaderStrip(permissions: model.permissions, onOpenPermissions: actions.onOpenPermissions)

            HStack(spacing: 8) {
                QuickActionTile(
                    title: "Snip",
                    shortcut: model.snipShortcut,
                    symbol: "viewfinder",
                    tint: .blue,
                    action: actions.onSnip
                )
                QuickActionTile(
                    title: "Paste Pin",
                    shortcut: model.pastePinShortcut,
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

            FloatingPinsSection(
                pinCount: model.pinCount,
                arePinsHidden: model.arePinsHidden,
                hasClickThroughPins: model.hasClickThroughPins,
                pastePinShortcut: model.pastePinShortcut,
                togglePinsShortcut: model.togglePinsShortcut,
                unlockClickThroughShortcut: model.unlockClickThroughShortcut,
                onToggleAllPins: actions.onToggleAllPins,
                onUnlockClickThrough: actions.onUnlockClickThrough,
                onCloseAllPins: actions.onCloseAllPins
            )

            UtilityFooterSection(
                permissions: model.permissions,
                onOpenPermissions: actions.onOpenPermissions,
                onOpenSettings: actions.onOpenSettings,
                onQuit: actions.onQuit
            )
        }
        .padding(14)
        .frame(width: 304)
        .fixedSize(horizontal: false, vertical: true)
        .cpxPopoverSurface(cornerRadius: 18)
    }
}

// MARK: - Header

private struct HeaderStrip: View {
    let permissions: CPXPermissionStatus
    let onOpenPermissions: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)

                Text("CPX")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer()

            StatusBadge(permissions: permissions, onTap: onOpenPermissions)
        }
        .padding(.horizontal, 2)
    }
}

private struct StatusBadge: View {
    let permissions: CPXPermissionStatus
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        if permissions.screenRecording && permissions.accessibility {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
        } else {
            let needsScreen = !permissions.screenRecording
            let pillTint: Color = needsScreen ? .orange : .yellow
            let pillTitle = needsScreen ? "Setup Needed" : "Accessibility"

            Button(action: onTap) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(pillTint)
                        .frame(width: 6, height: 6)
                    Text(pillTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(needsScreen ? Color.orange : Color.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
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
    let shortcut: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(
                            tint.opacity(isHovering ? 0.22 : 0.14),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )

                    Spacer(minLength: 4)

                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().opacity(0.6)

            HStack {
                Text("RECENT SNIPS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                Text("Click to pin")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            HStack(spacing: 6) {
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
                .frame(width: 64, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
    let pastePinShortcut: String
    let togglePinsShortcut: String
    let unlockClickThroughShortcut: String
    let onToggleAllPins: () -> Void
    let onUnlockClickThrough: () -> Void
    let onCloseAllPins: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.6)

            HStack {
                Text("FLOATING PINS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)

                Spacer()

                Text(pinCount == 0 ? "0" : "\(pinCount) active")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pinCount == 0 ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        (pinCount == 0 ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.14)),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 2)

            if pinCount == 0 {
                Text("Press \(pastePinShortcut) to pin clipboard items")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    MenuActionRow(
                        title: arePinsHidden ? "Show All Pins" : "Hide All Pins",
                        symbol: arePinsHidden ? "eye" : "eye.slash",
                        shortcut: togglePinsShortcut,
                        action: onToggleAllPins
                    )

                    if hasClickThroughPins {
                        MenuActionRow(
                            title: "Unlock Click-Through",
                            symbol: "cursorarrow.click",
                            shortcut: unlockClickThroughShortcut,
                            action: onUnlockClickThrough
                        )
                    }

                    MenuActionRow(
                        title: "Close All Pins",
                        symbol: "xmark.circle",
                        isDestructive: true,
                        action: onCloseAllPins
                    )
                }
            }
        }
    }
}

// MARK: - Utility Footer

private struct UtilityFooterSection: View {
    let permissions: CPXPermissionStatus
    let onOpenPermissions: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.6)
                .padding(.bottom, 2)

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
                .padding(.vertical, 2)

            MenuActionRow(
                title: "Quit CPX",
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
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(resolvedSymbolColor)
                    .frame(width: 18, alignment: .center)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovering && isDestructive ? Color.red : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let trailingDotColor {
                    Circle()
                        .fill(trailingDotColor)
                        .frame(width: 7, height: 7)
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
    func cpxPopoverSurface(cornerRadius: CGFloat) -> some View {
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
