import AppKit
import CoreGraphics
import CCXCore

/// Pure geometry for pins (no windows), shared by `PinPanel` and unit tests.
enum PinLayout {
    static let thumbnailSize = CGSize(width: 72, height: 72)
    static let thumbnailCornerRadius: CGFloat = 10
    static let textPadding: CGFloat = 12
    static let maxTextWidth: CGFloat = 480
    static let maxTextHeight: CGFloat = 720
    static let minTextCardSize = CGSize(width: 48, height: 36)
    static let colorCardSize = CGSize(width: 236, height: 88)

    /// Unrotated, unzoomed content size in points.
    static func baseSize(for content: PinContent) -> CGSize {
        switch content {
        case let .image(image, scale):
            let scale = scale > 0 && scale.isFinite ? scale : 1
            return CGSize(width: max(1, CGFloat(image.width) / scale), height: max(1, CGFloat(image.height) / scale))
        case let .text(text):
            return textCardSize(for: text)
        case .color:
            return colorCardSize
        }
    }

    static func textAttributes(color: NSColor = .textColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    static func textCardSize(for text: String) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: textAttributes())
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = ceil(bounds.width) + textPadding * 2
        let height = ceil(min(bounds.height, maxTextHeight)) + textPadding * 2
        return CGSize(width: max(width, minTextCardSize.width), height: max(height, minTextCardSize.height))
    }

    /// Window size for a given state: rotated and zoomed base size, or the fixed thumbnail.
    static func frameSize(baseSize: CGSize, state: PinState) -> CGSize {
        if state.isThumbnail { return thumbnailSize }
        let rotated = state.isQuarterTurned ? CGSize(width: baseSize.height, height: baseSize.width) : baseSize
        return CGSize(
            width: max(1, (rotated.width * state.zoom).rounded()),
            height: max(1, (rotated.height * state.zoom).rounded())
        )
    }

    /// Resizes `frame` to `newSize` keeping `anchor` (a screen point) at the same relative
    /// position inside the frame. Pass the top-left corner to grow/shrink from top-left.
    static func resizedFrame(_ frame: CGRect, to newSize: CGSize, keeping anchor: CGPoint) -> CGRect {
        let rx = frame.width > 0 ? (anchor.x - frame.minX) / frame.width : 0.5
        let ry = frame.height > 0 ? (anchor.y - frame.minY) / frame.height : 0.5
        return CGRect(
            x: (anchor.x - rx * newSize.width).rounded(),
            y: (anchor.y - ry * newSize.height).rounded(),
            width: newSize.width,
            height: newSize.height
        )
    }

    /// Frame for a new pin. With a `screenRect` (AppKit global coordinates) the pin's
    /// top-left corner matches the rect's top-left corner so a snip pins seamlessly in
    /// place. Without one, the pin is centered in `visibleFrame`, and the returned zoom
    /// shrinks oversize content to fit within 90% of it.
    static func initialPlacement(
        baseSize: CGSize,
        screenRect: CGRect?,
        visibleFrame: CGRect
    ) -> (frame: CGRect, zoom: CGFloat) {
        if let screenRect {
            let rect = screenRect.standardized
            let frame = CGRect(
                x: rect.minX,
                y: rect.maxY - baseSize.height,
                width: baseSize.width,
                height: baseSize.height
            )
            return (frame, 1)
        }
        var zoom: CGFloat = 1
        if visibleFrame.width > 0, visibleFrame.height > 0, baseSize.width > 0, baseSize.height > 0 {
            let fit = min(visibleFrame.width * 0.9 / baseSize.width, visibleFrame.height * 0.9 / baseSize.height)
            zoom = min(1, max(fit, PinState.zoomRange.lowerBound))
        }
        let size = CGSize(width: (baseSize.width * zoom).rounded(), height: (baseSize.height * zoom).rounded())
        let frame = CGRect(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: (visibleFrame.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        return (frame, zoom)
    }

    /// Returns `image` rotated clockwise by a multiple of 90 degrees (other angles return
    /// the original image).
    static func rotatedImage(_ image: CGImage, clockwiseDegrees degrees: Int) -> CGImage? {
        let degrees = ((degrees % 360) + 360) % 360
        guard degrees != 0 else { return image }
        guard degrees % 90 == 0 else { return image }
        let quarter = degrees % 180 == 90
        let width = quarter ? image.height : image.width
        let height = quarter ? image.width : image.height
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(
            image,
            in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                       width: CGFloat(image.width), height: CGFloat(image.height))
        )
        return context.makeImage()
    }
}

/// Draws pin content into the current `NSGraphicsContext`.
@MainActor
enum PinRenderer {
    /// Draws `content` filling `rect` (in base-size coordinates; caller applies zoom/rotation).
    static func draw(_ content: PinContent, in rect: CGRect, zoom: CGFloat, context: CGContext) {
        switch content {
        case let .image(image, _):
            // Pixel-exact at 100%; smooth when scaled.
            context.interpolationQuality = abs(zoom - 1) < 0.001 ? .none : .high
            context.draw(image, in: rect)
        case let .text(text):
            NSColor.textBackgroundColor.setFill()
            rect.fill()
            let textRect = rect.insetBy(dx: PinLayout.textPadding, dy: PinLayout.textPadding)
            NSAttributedString(string: text, attributes: PinLayout.textAttributes())
                .draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        case let .color(color):
            drawColorCard(color, in: rect)
        }
    }

    static func drawColorCard(_ color: CCXColorSample, in rect: CGRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        let swatchSide = rect.height - 24
        let swatch = CGRect(x: rect.minX + 12, y: rect.minY + 12, width: swatchSide, height: swatchSide)
        let swatchPath = NSBezierPath(roundedRect: swatch, xRadius: 6, yRadius: 6)
        color.nsColor.setFill()
        swatchPath.fill()
        NSColor.separatorColor.setStroke()
        swatchPath.lineWidth = 1
        swatchPath.stroke()

        let textX = swatch.maxX + 12
        let hexAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSAttributedString(string: color.hexString, attributes: hexAttributes)
            .draw(at: CGPoint(x: textX, y: rect.maxY - 12 - 22))
        NSAttributedString(string: color.rgbString, attributes: detailAttributes)
            .draw(at: CGPoint(x: textX, y: rect.minY + 12 + 16))
        NSAttributedString(string: color.hslString, attributes: detailAttributes)
            .draw(at: CGPoint(x: textX, y: rect.minY + 12))
    }

    /// Renders `content` at its base size into a bitmap (used for copy/save of
    /// non-image pins and rotated images).
    static func exportImage(for content: PinContent, rotationDegrees: Int, scale: CGFloat = 2) -> CGImage? {
        if case let .image(image, _) = content {
            return PinLayout.rotatedImage(image, clockwiseDegrees: rotationDegrees)
        }
        let size = PinLayout.baseSize(for: content)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(content, in: CGRect(origin: .zero, size: size), zoom: 1, context: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = context.makeImage() else { return nil }
        return PinLayout.rotatedImage(rendered, clockwiseDegrees: rotationDegrees)
    }
}
