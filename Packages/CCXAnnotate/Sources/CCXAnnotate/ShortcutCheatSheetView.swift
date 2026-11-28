import AppKit
import CCXCore

/// Keycap-description pair displayed inside `ShortcutCheatSheetView`.
public struct ShortcutCheatSheetEntry: Equatable, Sendable {
    public let keys: String
    public let description: String

    public init(keys: String, description: String) {
        self.keys = keys
        self.description = description
    }
}

/// Modal Liquid Glass HUD listing contextual keyboard shortcuts when the user presses `?`.
@MainActor
public final class ShortcutCheatSheetView: NSView {
    public let titleText: String
    public let entries: [ShortcutCheatSheetEntry]

    public static var snipOverlayEntries: [ShortcutCheatSheetEntry] {
        [
            ShortcutCheatSheetEntry(keys: "1–8", description: CCXL10n.text("Annotation tools", zh: "切换标注工具")),
            ShortcutCheatSheetEntry(keys: "V", description: CCXL10n.text("Select / move item", zh: "选择 / 移动标注")),
            ShortcutCheatSheetEntry(keys: "[ / ]", description: CCXL10n.text("Adjust stroke size", zh: "调整粗细 / 强度")),
            ShortcutCheatSheetEntry(keys: "⌘Z / ⇧⌘Z", description: CCXL10n.text("Undo / redo", zh: "撤销 / 重做")),
            ShortcutCheatSheetEntry(keys: "Space + Drag", description: CCXL10n.text("Reposition selection", zh: "拖动调整选区位置")),
            ShortcutCheatSheetEntry(keys: "Shift + Drag", description: CCXL10n.text("Lock 1:1 / snap", zh: "锁定比例 / 对齐")),
            ShortcutCheatSheetEntry(keys: "C", description: CCXL10n.text("Copy color hex", zh: "拷贝吸管色值")),
            ShortcutCheatSheetEntry(keys: "T / L / R", description: CCXL10n.text("OCR / Scroll / Record", zh: "识字 / 长截屏 / 录屏")),
            ShortcutCheatSheetEntry(keys: "↩ / Esc", description: CCXL10n.text("Pin / cancel", zh: "贴图 / 取消")),
        ]
    }

    public static var pinWindowEntries: [ShortcutCheatSheetEntry] {
        [
            ShortcutCheatSheetEntry(keys: "Scroll / ⌘0", description: CCXL10n.text("Zoom / reset 100%", zh: "缩放 / 重置大小")),
            ShortcutCheatSheetEntry(keys: "⌥ + Scroll", description: CCXL10n.text("Adjust opacity", zh: "调节不透明度")),
            ShortcutCheatSheetEntry(keys: "E / 1–8", description: CCXL10n.text("Edit / annotate", zh: "开启或切换标注")),
            ShortcutCheatSheetEntry(keys: "R / H / V", description: CCXL10n.text("Rotate 90° / Flip", zh: "旋转 90° / 翻转")),
            ShortcutCheatSheetEntry(keys: "T", description: CCXL10n.text("Copy text (OCR) / select", zh: "识别文字 / 选择文本")),
            ShortcutCheatSheetEntry(keys: "⇧⌘T", description: CCXL10n.text("Reopen closed pin", zh: "恢复刚关闭的贴图")),
            ShortcutCheatSheetEntry(keys: "⌘C / ⌘S", description: CCXL10n.text("Copy / save PNG", zh: "拷贝 / 保存图片")),
            ShortcutCheatSheetEntry(keys: "Double-Click", description: CCXL10n.text("Annotate / thumbnail", zh: "标注 / 缩略图模式")),
            ShortcutCheatSheetEntry(keys: "Esc", description: CCXL10n.text("Dismiss / close pin", zh: "退出编辑 / 关闭贴图")),
        ]
    }

    public init(title: String = CCXL10n.text("Keyboard Shortcuts", zh: "快捷键一览"), entries: [ShortcutCheatSheetEntry]) {
        self.titleText = title
        self.entries = entries
        super.init(frame: .zero)
        wantsLayer = true
        setUpHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func setUpHierarchy() {
        let surface: NSView
        let contentContainer: NSView
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 14
            glass.style = .regular
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.tintColor = NSColor(white: 0.08, alpha: 0.72)
            let contentHost = NSView()
            contentHost.autoresizingMask = [.width, .height]
            contentHost.addSubview(stack)
            glass.contentView = contentHost
            surface = glass
            contentContainer = contentHost
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 14
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.addSubview(stack)
            surface = blur
            contentContainer = blur
        }
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 14
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 0.75
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        headerRow.addArrangedSubview(titleLabel)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(headerSpacer)

        let dismissBadge = NSTextField(labelWithString: CCXL10n.text("? / Esc to close", zh: "按 ? / Esc 关闭"))
        dismissBadge.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        dismissBadge.textColor = NSColor.white.withAlphaComponent(0.65)
        headerRow.addArrangedSubview(dismissBadge)

        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.alphaValue = 0.35
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for entry in entries {
            let row = Self.makeEntryRow(entry)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -14),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 310),
        ])
    }

    private static func makeEntryRow(_ entry: ShortcutCheatSheetEntry) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let keyPill = NSView()
        keyPill.wantsLayer = true
        keyPill.layer?.cornerRadius = 5
        keyPill.layer?.cornerCurve = .continuous
        keyPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        keyPill.layer?.borderWidth = 0.5
        keyPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        keyPill.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: entry.keys)
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        keyLabel.textColor = .white
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyPill.addSubview(keyLabel)

        NSLayoutConstraint.activate([
            keyLabel.leadingAnchor.constraint(equalTo: keyPill.leadingAnchor, constant: 6),
            keyLabel.trailingAnchor.constraint(equalTo: keyPill.trailingAnchor, constant: -6),
            keyLabel.topAnchor.constraint(equalTo: keyPill.topAnchor, constant: 2),
            keyLabel.bottomAnchor.constraint(equalTo: keyPill.bottomAnchor, constant: -2),
            keyPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])

        let descLabel = NSTextField(labelWithString: entry.description)
        descLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        descLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(keyPill)
        row.addArrangedSubview(descLabel)
        return row
    }
}
