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

    @Published private(set) var snipShortcut = HotKeyCombo.defaultSnip.displayString
    @Published private(set) var isSnipHotKeyRegistered = true
    @Published private(set) var pinBadge = CCXL10n.text("Empty", zh: "空")
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
        let nextRecent = clipboardStore.history
        if recentSnips.map(\.id) != nextRecent.map(\.id) {
            recentSnips = nextRecent
        }
    }

    func sync(
        pinManager: PinManager,
        clipboardStore: ClipboardStore,
        recordingStatus: RecordingMenuBarStatus? = nil,
        snipShortcut: String = HotKeyCombo.defaultSnip.displayString,
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

        if self.snipShortcut != snipShortcut {
            self.snipShortcut = snipShortcut
        }

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
            nextBadge = CCXL10n.text("Empty", zh: "空")
            nextDimmed = true
        case .allPinned:
            nextBadge = CCXL10n.text("All Pinned", zh: "已全部贴图")
            nextDimmed = true
        case let .ready(count, primaryLabel):
            nextBadge = count > 1
                ? CCXL10n.text("\(count) Ready", zh: "\(count) 张待贴")
                : primaryLabel
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
    let onOpenRecordingsFolder: () -> Void
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
    @ObservedObject var updateManager: AppUpdateManager
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
                        title: CCXL10n.text("Snip", zh: "截屏"),
                        badge: model.isSnipHotKeyRegistered
                            ? model.snipShortcut
                            : CCXL10n.text("Conflict", zh: "冲突"),
                        isBadgeDimmed: !model.isSnipHotKeyRegistered,
                        symbol: "viewfinder",
                        tint: model.isSnipHotKeyRegistered ? .blue : .orange,
                        tooltip: model.isSnipHotKeyRegistered
                            ? CCXL10n.text("Capture screen (\(model.snipShortcut))", zh: "截屏 (\(model.snipShortcut))")
                            : CCXL10n.text(
                                "Shortcut \(model.snipShortcut) is in use by another app — check Settings",
                                zh: "快捷键 \(model.snipShortcut) 已被其他应用占用，请在设置中修改"
                            ),
                        action: actions.onSnip
                    )
                    QuickActionTile(
                        title: CCXL10n.text("Pin", zh: "贴图"),
                        badge: model.pinBadge,
                        isBadgeDimmed: model.isPinBadgeDimmed,
                        symbol: "pin.fill",
                        tint: .indigo,
                        accessorySymbol: "xmark.circle.fill",
                        accessoryTooltip: CCXL10n.text("Clear clipboard", zh: "清空剪贴板"),
                        isAccessoryDestructive: true,
                        onAccessory: model.hasClipboardContent ? actions.onClearClipboard : nil,
                        action: actions.onPastePin
                    )
                    QuickActionTile(
                        title: CCXL10n.text("Record", zh: "录屏"),
                        badge: CCXL10n.text("Video · GIF", zh: "视频 · GIF"),
                        symbol: "record.circle.fill",
                        tint: .red,
                        tooltip: CCXL10n.text("Record screen (MP4, MOV, or GIF)", zh: "录屏 (MP4、MOV 或 GIF)"),
                        accessorySymbol: "folder.fill",
                        accessoryTooltip: CCXL10n.text("Open Recordings Folder", zh: "打开录屏目录"),
                        isAccessoryDestructive: false,
                        onAccessory: actions.onOpenRecordingsFolder,
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

            if updateManager.shouldShowPopoverBanner {
                UpdateAvailableBanner(updateManager: updateManager)
            }

            UtilityFooterSection(
                permissions: model.permissions,
                hasUpdateBadge: updateManager.availableRelease != nil && !updateManager.shouldShowPopoverBanner,
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
                Text(
                    status.isPaused
                        ? CCXL10n.text("Paused · \(status.format.label)", zh: "已暂停 · \(status.format.label)")
                        : CCXL10n.text("Recording · \(status.format.label)", zh: "录制中 · \(status.format.label)")
                )
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(status.formattedElapsed)
                    .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
            }

            HStack(spacing: 6) {
                PinControlPill(
                    title: status.isPaused ? CCXL10n.text("Resume", zh: "继续") : CCXL10n.text("Pause", zh: "暂停"),
                    symbol: status.isPaused ? "play.fill" : "pause.fill",
                    tint: status.isPaused ? .cyan : .secondary,
                    isActive: status.isPaused,
                    action: onTogglePause
                )
                PinControlPill(
                    title: CCXL10n.text("Stop", zh: "停止"),
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
                .help(CCXL10n.text("Cancel Recording", zh: "取消录制"))
                .accessibilityLabel(CCXL10n.text("Cancel Recording", zh: "取消录制"))
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
    var accessorySymbol: String? = nil
    var accessoryTooltip: String = ""
    var isAccessoryDestructive = false
    var onAccessory: (() -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false
    @State private var isAccessoryHovering = false

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
            if let onAccessory, let accessorySymbol, isHovering {
                Button(action: onAccessory) {
                    Image(systemName: accessorySymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            isAccessoryHovering
                                ? (isAccessoryDestructive ? Color.red : Color.accentColor)
                                : Color.secondary
                        )
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(accessoryTooltip)
                .accessibilityLabel(accessoryTooltip)
                .padding(2)
                .onHover { isAccessoryHovering = $0 }
            }
        }
        .contextMenu {
            if let onAccessory {
                Button(accessoryTooltip, action: onAccessory)
            }
        }
        .onHover { hovering in
            isHovering = hovering
            if !hovering {
                isAccessoryHovering = false
            }
        }
    }
}

// MARK: - Recent Snips

private struct ScrollEdgeState: Equatable, Sendable {
    let canScrollLeft: Bool
    let canScrollRight: Bool
    let contentOffsetX: CGFloat
    let visibleWidth: CGFloat
    let contentWidth: CGFloat

    static let edgeEpsilon: CGFloat = 1.5
    static let initialOverflow = ScrollEdgeState(
        canScrollLeft: false,
        canScrollRight: true,
        contentOffsetX: 0,
        visibleWidth: 288,
        contentWidth: 0
    )

    static func from(_ geometry: ScrollGeometry) -> ScrollEdgeState {
        let visibleWidth = geometry.visibleRect.width
        let contentWidth = geometry.contentSize.width
        guard visibleWidth > 0, contentWidth > 0 else {
            return .initialOverflow
        }
        let maxOffset = max(0, contentWidth - visibleWidth)
        let rawOffset = geometry.contentOffset.x + geometry.contentInsets.leading
        let clampedOffset = min(max(rawOffset, 0), maxOffset)
        let roundedOffset = (clampedOffset * 2).rounded() / 2
        return ScrollEdgeState(
            canScrollLeft: clampedOffset > edgeEpsilon,
            canScrollRight: maxOffset - clampedOffset > edgeEpsilon,
            contentOffsetX: roundedOffset,
            visibleWidth: visibleWidth,
            contentWidth: contentWidth
        )
    }
}

private struct RecentSnipsSection: View {
    let entries: [SnipHistoryEntry]
    let pinnedHistoryIDs: Set<UUID>
    let onPinHistory: (SnipHistoryEntry) -> Void
    let onClearHistory: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Divider().opacity(0.45)

            ZStack {
                HStack(spacing: 5) {
                    Text(CCXL10n.text("RECENT SNIPS", zh: "最近截屏"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)

                    Text("\(entries.count)")
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(CCXL10n.text(
                    "Recent snips, \(entries.count)",
                    zh: "最近截屏，共 \(entries.count) 张"
                ))

                HStack {
                    Spacer()
                    RecentClearButton(action: onClearHistory)
                }
            }
            .frame(maxWidth: .infinity)

            if entries.count <= 4 {
                HStack(spacing: 6) {
                    ForEach(entries) { entry in
                        RecentSnipThumbnail(entry: entry, isPinned: pinnedHistoryIDs.contains(entry.id)) {
                            onPinHistory(entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 42)
            } else {
                ScrollableRecentSnipsStrip(
                    entries: entries,
                    pinnedHistoryIDs: pinnedHistoryIDs,
                    onPinHistory: onPinHistory
                )
            }
        }
    }
}

private struct ScrollableRecentSnipsStrip: View {
    private static let thumbnailWidth: CGFloat = 60.5
    private static let thumbnailSpacing: CGFloat = 6
    private static let horizontalInset: CGFloat = 2
    private static let stripHeight: CGFloat = 42
    private static let fallbackVisibleWidth: CGFloat = 288
    private static let leadingFadeWidth: CGFloat = 14
    private static let trailingFadeWidth: CGFloat = 18
    private static let stepThumbnails: CGFloat = 3

    let entries: [SnipHistoryEntry]
    let pinnedHistoryIDs: Set<UUID>
    let onPinHistory: (SnipHistoryEntry) -> Void

    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var scrollEdgeState = ScrollEdgeState.initialOverflow
    @State private var isStripHovering = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.thumbnailSpacing) {
                ForEach(entries) { entry in
                    RecentSnipThumbnail(entry: entry, isPinned: pinnedHistoryIDs.contains(entry.id)) {
                        onPinHistory(entry)
                    }
                }
            }
            .padding(.horizontal, Self.horizontalInset)
            .frame(height: Self.stripHeight)
        }
        .defaultScrollAnchor(.leading)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollEdgeState.self) { geometry in
            ScrollEdgeState.from(geometry)
        } action: { _, nextState in
            scrollEdgeState = nextState
        }
        .frame(height: Self.stripHeight)
        .mask {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let leftStop = min(Self.leadingFadeWidth / width, 0.25)
                let rightStop = max(1 - Self.trailingFadeWidth / width, 0.75)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(scrollEdgeState.canScrollLeft ? 0 : 1), location: 0),
                        .init(color: .black, location: leftStop),
                        .init(color: .black, location: rightStop),
                        .init(color: .black.opacity(scrollEdgeState.canScrollRight ? 0 : 1), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .animation(.easeInOut(duration: 0.16), value: scrollEdgeState.canScrollLeft)
                .animation(.easeInOut(duration: 0.16), value: scrollEdgeState.canScrollRight)
            }
        }
        .overlay(alignment: .leading) {
            Group {
                if isStripHovering && scrollEdgeState.canScrollLeft {
                    ScrollStepButton(
                        symbol: "chevron.left",
                        label: CCXL10n.text("Scroll newer snips", zh: "查看较新截屏"),
                        action: { stepScroll(direction: -1) }
                    )
                    .padding(.leading, 2)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isStripHovering && scrollEdgeState.canScrollLeft)
        }
        .overlay(alignment: .trailing) {
            Group {
                if isStripHovering && scrollEdgeState.canScrollRight {
                    ScrollStepButton(
                        symbol: "chevron.right",
                        label: CCXL10n.text("Scroll older snips", zh: "查看较早截屏"),
                        action: { stepScroll(direction: 1) }
                    )
                    .padding(.trailing, 2)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isStripHovering && scrollEdgeState.canScrollRight)
        }
        .onAppear {
            scrollPosition.scrollTo(x: 0)
        }
        .onHover { isStripHovering = $0 }
        .onChange(of: entries.first?.id) { _, _ in
            scrollPosition.scrollTo(x: 0)
        }
    }

    private func stepScroll(direction: CGFloat) {
        let visibleWidth = scrollEdgeState.visibleWidth > 0
            ? scrollEdgeState.visibleWidth
            : Self.fallbackVisibleWidth
        let estimatedContentWidth = CGFloat(entries.count) * Self.thumbnailWidth
            + CGFloat(max(0, entries.count - 1)) * Self.thumbnailSpacing
            + Self.horizontalInset * 2
        let contentWidth = scrollEdgeState.contentWidth > 0
            ? scrollEdgeState.contentWidth
            : estimatedContentWidth
        let maxOffset = max(0, contentWidth - visibleWidth)
        guard maxOffset > 0 else { return }

        let stepWidth = Self.stepThumbnails * (Self.thumbnailWidth + Self.thumbnailSpacing)
        var targetX = scrollEdgeState.contentOffsetX + direction * stepWidth
        if direction > 0, maxOffset - targetX < 20 {
            targetX = maxOffset
        } else if direction < 0, targetX < 20 {
            targetX = 0
        }
        let clampedTargetX = min(max(targetX, 0), maxOffset)
        withAnimation(.snappy(duration: 0.24)) {
            scrollPosition.scrollTo(x: clampedTargetX)
        }
    }
}

private struct ScrollStepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isHovering ? Color.primary : Color.primary.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle()
                        .fill(Color.primary.opacity(isHovering ? 0.12 : 0.03))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(isHovering ? 0.28 : 0.16),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .onHover { isHovering = $0 }
    }
}

private struct RecentClearButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(CCXL10n.text("Clear", zh: "清空"))
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
        .help(CCXL10n.text("Clear recent snips and clipboard", zh: "清空最近截屏与剪贴板"))
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
            Color.clear
                .frame(width: 60.5, height: 38)
                .overlay {
                    Image(decorative: entry.thumbnail, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isPinned {
                        Circle()
                            .fill(Color.indigo)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                            .padding(3)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHovering ? Color.accentColor : Color.primary.opacity(0.14),
                            lineWidth: isHovering ? 1.5 : 1
                        )
                        .allowsHitTesting(false)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: 60.5, height: 38)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(CCXL10n.text(
            "\(entry.image.width) × \(entry.image.height) · \(isPinned ? "Already pinned" : "Click to pin")",
            zh: "\(entry.image.width) × \(entry.image.height) · \(isPinned ? "已贴图" : "点击贴图")"
        ))
        .accessibilityLabel(CCXL10n.text(
            "Recent snip \(entry.image.width) by \(entry.image.height), \(isPinned ? "already pinned" : "click to pin")",
            zh: "最近截屏 \(entry.image.width) × \(entry.image.height)，\(isPinned ? "已贴图" : "点击贴图")"
        ))
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
                Text(CCXL10n.text("FLOATING PINS", zh: "悬浮贴图"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                Text(CCXL10n.text("\(pinCount) active", zh: "\(pinCount) 个显示"))
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
                        title: arePinsHidden ? CCXL10n.text("Show All", zh: "显示全部") : CCXL10n.text("Hide All", zh: "隐藏全部"),
                        symbol: arePinsHidden ? "eye" : "eye.slash",
                        tint: arePinsHidden ? .accentColor : .secondary,
                        isActive: arePinsHidden,
                        action: onToggleAllPins
                    )

                    PinControlPill(
                        title: CCXL10n.text("Close All", zh: "关闭全部"),
                        symbol: "xmark.circle",
                        tint: .secondary,
                        isDestructive: true,
                        action: onCloseAllPins
                    )
                }

                if hasClickThroughPins {
                    PinControlPill(
                        title: CCXL10n.text("Unlock Click-Through", zh: "解除穿透"),
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

// MARK: - In-App Update Banner

private struct UpdateAvailableBanner: View {
    @ObservedObject var updateManager: AppUpdateManager

    private var isFailedState: Bool {
        if case .failed = updateManager.state {
            return true
        }
        return false
    }

    var body: some View {
        let tint: Color = isFailedState ? .orange : .green

        Group {
            switch updateManager.state {
            case .available(let release):
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)

                    Text(CCXL10n.text(
                        "Update v\(release.version.description)",
                        zh: "发现更新 v\(release.version.description)"
                    ))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Button {
                        updateManager.installAvailableUpdate()
                    } label: {
                        Text(CCXL10n.text("Update", zh: "更新"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Color.green, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    Button {
                        updateManager.dismissPopoverBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(CCXL10n.text("Dismiss update notice", zh: "关闭更新提示"))
                    .accessibilityLabel(CCXL10n.text("Dismiss update notice", zh: "关闭更新提示"))
                }

            case .downloading(_, let progress):
                let pct = Int((progress * 100).rounded())
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text(CCXL10n.text("Downloading \(pct)%", zh: "下载中 \(pct)%"))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 64)

                    Button {
                        updateManager.cancelDownload()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(CCXL10n.text("Cancel download", zh: "取消下载"))
                    .accessibilityLabel(CCXL10n.text("Cancel download", zh: "取消下载"))
                }

            case .verifying:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(CCXL10n.text("Verifying…", zh: "校验中…"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }

            case .installing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(CCXL10n.text("Installing…", zh: "安装中…"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }

            case .failed(let message, let release):
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)

                        Text(CCXL10n.text("Update Failed", zh: "更新失败"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Button {
                            updateManager.installAvailableUpdate()
                        } label: {
                            Text(CCXL10n.text("Retry", zh: "重试"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()

                        Button {
                            NSWorkspace.shared.open(release?.releaseURL ?? AppUpdateURLPolicy.releasesPageURL)
                        } label: {
                            Text("GitHub")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .fixedSize()

                        Button {
                            updateManager.dismissPopoverBanner()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(CCXL10n.text("Dismiss update error", zh: "关闭更新错误提示"))
                        .accessibilityLabel(CCXL10n.text("Dismiss update error", zh: "关闭更新错误提示"))
                    }

                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .idle, .checking, .upToDate:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.26), lineWidth: 1)
        )
    }
}

// MARK: - Utility Dock

private struct UtilityFooterSection: View {
    let permissions: CCXPermissionStatus
    var hasUpdateBadge = false
    let onOpenPermissions: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.45)

            let allGranted = permissions.screenRecording && permissions.accessibility
            HStack(spacing: 6) {
                UtilityDockButton(
                    title: allGranted ? CCXL10n.text("Ready", zh: "就绪") : CCXL10n.text("Guide", zh: "指南"),
                    symbol: allGranted ? "checkmark.shield" : "exclamationmark.triangle.fill",
                    symbolTint: allGranted ? .green : .orange,
                    needsAttention: !allGranted,
                    tooltip: allGranted
                        ? CCXL10n.text("All permissions granted — click to open Guide", zh: "权限已就绪，点击打开使用指南")
                        : CCXL10n.text("Setup needed — click to open Permissions & Guide", zh: "需要授权，点击打开权限与使用指南"),
                    action: onOpenPermissions
                )

                UtilityDockButton(
                    title: CCXL10n.text("Settings", zh: "设置"),
                    symbol: "gearshape",
                    showBadgeDot: hasUpdateBadge,
                    tooltip: hasUpdateBadge
                        ? CCXL10n.text("Settings (⌘,) — Update available", zh: "设置 (⌘,) · 有新版本可用")
                        : CCXL10n.text("Settings (⌘,)", zh: "设置 (⌘,)"),
                    action: onOpenSettings
                )

                UtilityDockButton(
                    title: CCXL10n.text("Quit", zh: "退出"),
                    symbol: "power",
                    isDestructive: true,
                    tooltip: CCXL10n.text("Quit CCX (⌘Q)", zh: "退出 CCX (⌘Q)"),
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
    var showBadgeDot = false
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
                    .overlay(alignment: .topTrailing) {
                        if showBadgeDot {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                                .offset(x: 4, y: -2)
                        }
                    }

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
