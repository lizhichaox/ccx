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

    static let minImageScale: CGFloat = 0.1
    static let maxImageScale: CGFloat = 16.0
    /// Caps window backing stores within Metal texture dimension (16384px at 2x) and RAM limits.
    static let maxWindowDimension: CGFloat = 8_192
    static let maxWindowArea: CGFloat = 16_777_216
    /// Hard safety limits for incoming / transformed bitmaps to prevent OOM from malformed payloads.
    static let maxImagePixelDimension: Int = 32_768
    static let maxImagePixelCount: Int = 64_000_000
    /// Caps CoreText measurement/rendering length to avoid main-thread stalls on multi-MB clipboard text.
    static let maxDisplayTextLength: Int = 4_096
    /// Minimum visible edge margin kept inside active screen bounds when clamping/rescuing pins.
    static let minVisibleMargin: CGFloat = 40

    static func sanitizedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(max(scale, minImageScale), maxImageScale)
    }

    static func displayText(for text: String) -> String {
        if text.utf8.count <= maxDisplayTextLength {
            return text
        }
        guard text.count > maxDisplayTextLength else { return text }
        return String(text.prefix(maxDisplayTextLength)) + "…"
    }

    /// Rejects zero-dimension images and safely downsamples oversized images to fit within pixel budgets.
    static func sanitizedImage(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let (pixelCount, overflowed) = width.multipliedReportingOverflow(by: height)
        if !overflowed,
           width <= maxImagePixelDimension,
           height <= maxImagePixelDimension,
           pixelCount <= maxImagePixelCount {
            return image
        }

        let dimScale = min(
            Double(maxImagePixelDimension) / Double(width),
            Double(maxImagePixelDimension) / Double(height)
        )
        let areaScale = sqrt(Double(maxImagePixelCount) / (Double(width) * Double(height)))
        let factor = min(1.0, dimScale, areaScale)
        guard factor.isFinite, factor > 0 else { return nil }

        let targetWidth = max(1, min(maxImagePixelDimension, Int((Double(width) * factor).rounded(.down))))
        let targetHeight = max(1, min(maxImagePixelDimension, Int((Double(height) * factor).rounded(.down))))
        guard let context = makeRGBContext(
            width: targetWidth,
            height: targetHeight,
            preferredColorSpace: image.colorSpace
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// Creates an 8-bit premultiplied RGBA `CGContext`, gracefully falling back from extended/HDR
    /// color spaces (which reject 8-bit integer contexts) to Display P3, sRGB, or DeviceRGB.
    static func makeRGBContext(
        width: Int,
        height: Int,
        preferredColorSpace: CGColorSpace?
    ) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, overflowed) = width.multipliedReportingOverflow(by: height)
        guard !overflowed, pixels <= maxImagePixelCount else { return nil }

        var candidates: [CGColorSpace] = []
        if let preferredColorSpace, preferredColorSpace.model == .rgb {
            candidates.append(preferredColorSpace)
        }
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3) {
            candidates.append(p3)
        }
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            candidates.append(srgb)
        }
        candidates.append(CGColorSpaceCreateDeviceRGB())

        for space in candidates {
            if let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                return context
            }
        }
        return nil
    }

    /// Unrotated, unzoomed content size in points.
    static func baseSize(for content: PinContent) -> CGSize {
        switch content {
        case let .image(image, scale):
            let safeScale = sanitizedScale(scale)
            let rawW = image.width > 0 ? CGFloat(image.width) / safeScale : 1
            let rawH = image.height > 0 ? CGFloat(image.height) / safeScale : 1
            let width = rawW.isFinite ? max(1, rawW) : 1
            let height = rawH.isFinite ? max(1, rawH) : 1
            return CGSize(width: width, height: height)
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
        let bounded = displayText(for: text)
        let attributed = NSAttributedString(string: bounded, attributes: textAttributes())
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let width = ceil(bounds.width) + textPadding * 2
        let height = ceil(min(bounds.height, maxTextHeight)) + textPadding * 2
        return CGSize(width: max(width, minTextCardSize.width), height: max(height, minTextCardSize.height))
    }

    /// Effective zoom clamped to keep the backing window within `maxWindowDimension` and `maxWindowArea`.
    static func effectiveZoom(for baseSize: CGSize, state: PinState) -> CGFloat {
        guard baseSize.width.isFinite, baseSize.height.isFinite, baseSize.width > 0, baseSize.height > 0 else {
            return 1
        }
        let rotated = state.isQuarterTurned ? CGSize(width: baseSize.height, height: baseSize.width) : baseSize
        let maxSide = max(rotated.width, rotated.height)
        let area = rotated.width * rotated.height
        guard maxSide.isFinite, maxSide > 0, area.isFinite, area > 0 else { return 1 }

        let dimLimit = maxWindowDimension / maxSide
        let areaLimit = sqrt(maxWindowArea / area)
        let maxAllowedZoom = min(PinState.zoomRange.upperBound, dimLimit, areaLimit)
        guard maxAllowedZoom.isFinite, maxAllowedZoom > 0 else { return PinState.zoomRange.lowerBound }
        return min(state.zoom, maxAllowedZoom)
    }

    /// Window size for a given state: rotated and zoomed base size (capped for WindowServer safety),
    /// or the fixed thumbnail.
    static func frameSize(baseSize: CGSize, state: PinState) -> CGSize {
        if state.isThumbnail { return thumbnailSize }
        let safeBase = CGSize(
            width: (baseSize.width.isFinite && baseSize.width > 0) ? baseSize.width : 1,
            height: (baseSize.height.isFinite && baseSize.height > 0) ? baseSize.height : 1
        )
        let rotated = state.isQuarterTurned ? CGSize(width: safeBase.height, height: safeBase.width) : safeBase
        let zoom = effectiveZoom(for: safeBase, state: state)
        return CGSize(
            width: max(1, (rotated.width * zoom).rounded()),
            height: max(1, (rotated.height * zoom).rounded())
        )
    }

    /// Clamps `point` inside `rect`, falling back to `rect`'s center on non-finite input.
    static func clampedPoint(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        guard isFiniteRect(rect) else { return .zero }
        guard point.x.isFinite, point.y.isFinite else {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    /// Resizes `frame` to `newSize` keeping `anchor` (a screen point) at the same relative
    /// position inside the frame. Pass the top-left corner to grow/shrink from top-left.
    static func resizedFrame(_ frame: CGRect, to newSize: CGSize, keeping anchor: CGPoint) -> CGRect {
        let safeWidth = (newSize.width.isFinite && newSize.width > 0)
            ? newSize.width
            : (frame.width.isFinite && frame.width > 0 ? frame.width : 1)
        let safeHeight = (newSize.height.isFinite && newSize.height > 0)
            ? newSize.height
            : (frame.height.isFinite && frame.height > 0 ? frame.height : 1)
        guard isFiniteRect(frame) else {
            return CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)
        }
        let safeAnchor = (anchor.x.isFinite && anchor.y.isFinite)
            ? anchor
            : CGPoint(x: frame.midX, y: frame.midY)
        let rx = frame.width > 0 ? (safeAnchor.x - frame.minX) / frame.width : 0.5
        let ry = frame.height > 0 ? (safeAnchor.y - frame.minY) / frame.height : 0.5
        return CGRect(
            x: (safeAnchor.x - rx * safeWidth).rounded(),
            y: (safeAnchor.y - ry * safeHeight).rounded(),
            width: safeWidth,
            height: safeHeight
        )
    }

    /// Picks the screen `visibleFrame` with the largest intersection area with `rect`
    /// (or nearest screen center if disjoint).
    static func bestScreenFrame(
        for rect: CGRect,
        in screens: [(frame: CGRect, visibleFrame: CGRect)]
    ) -> CGRect? {
        let validScreens = screens.filter { isFiniteRect($0.frame) && isFiniteRect($0.visibleFrame) }
        guard !validScreens.isEmpty else { return nil }
        guard isFiniteRect(rect) else { return validScreens.first?.visibleFrame }

        let standardized = rect.standardized
        var bestOverlap: (area: CGFloat, visibleFrame: CGRect)?
        for screen in validScreens {
            let overlap = screen.frame.intersection(standardized)
            if !overlap.isNull, !overlap.isEmpty {
                let area = overlap.width * overlap.height
                if let current = bestOverlap {
                    if area > current.area {
                        bestOverlap = (area, screen.visibleFrame)
                    }
                } else {
                    bestOverlap = (area, screen.visibleFrame)
                }
            }
        }
        if let bestOverlap {
            return bestOverlap.visibleFrame
        }

        let center = CGPoint(x: standardized.midX, y: standardized.midY)
        return validScreens.min { lhs, rhs in
            squaredDistance(from: center, to: lhs.frame) < squaredDistance(from: center, to: rhs.frame)
        }?.visibleFrame
    }

    /// Ensures `frame` retains at least `minVisibleMargin` points overlapping at least one active
    /// screen's `visibleFrame` so pins can never be lost off-screen via nudging, zooming, or display disconnect.
    static func clampedOriginToScreens(
        _ frame: CGRect,
        screens: [CGRect],
        minVisibleMargin: CGFloat = minVisibleMargin
    ) -> CGRect {
        guard isFiniteRect(frame) else { return frame }
        let validScreens = screens.filter { isFiniteRect($0) && $0.width > 0 && $0.height > 0 }
        guard !validScreens.isEmpty else { return frame }

        let marginX = min(max(1, minVisibleMargin), max(1, frame.width))
        let marginY = min(max(1, minVisibleMargin), max(1, frame.height))
        for screen in validScreens {
            let overlap = screen.intersection(frame)
            if !overlap.isNull, overlap.width >= marginX, overlap.height >= marginY {
                return frame
            }
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let target = validScreens.min(by: {
            squaredDistance(from: center, to: $0) < squaredDistance(from: center, to: $1)
        }) else {
            return frame
        }

        let minX = target.minX - frame.width + marginX
        let maxX = target.maxX - marginX
        let minY = target.minY - frame.height + marginY
        let maxY = target.maxY - marginY

        let clampedX = minX <= maxX ? min(max(frame.origin.x, minX), maxX) : target.minX
        let clampedY = minY <= maxY ? min(max(frame.origin.y, minY), maxY) : target.minY
        return CGRect(x: clampedX.rounded(), y: clampedY.rounded(), width: frame.width, height: frame.height)
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
        let safeBase = CGSize(
            width: (baseSize.width.isFinite && baseSize.width > 0) ? baseSize.width : 1,
            height: (baseSize.height.isFinite && baseSize.height > 0) ? baseSize.height : 1
        )
        let safeVisible = isFiniteRect(visibleFrame) ? visibleFrame.standardized : .zero

        if let screenRect, isFiniteRect(screenRect) {
            let rect = screenRect.standardized
            let fitsScreen = safeVisible.width <= 0 || safeVisible.height <= 0 ||
                (safeBase.width <= safeVisible.width * 1.05 && safeBase.height <= safeVisible.height * 1.05)
            let withinBackingCap = safeBase.width <= maxWindowDimension
                && safeBase.height <= maxWindowDimension
                && (safeBase.width * safeBase.height) <= maxWindowArea
            if fitsScreen && withinBackingCap {
                let frame = CGRect(
                    x: rect.minX,
                    y: rect.maxY - safeBase.height,
                    width: safeBase.width,
                    height: safeBase.height
                )
                return (frame, 1)
            }
        }
        var zoom: CGFloat = 1
        if safeVisible.width > 0, safeVisible.height > 0 {
            let fit = min(safeVisible.width * 0.9 / safeBase.width, safeVisible.height * 0.9 / safeBase.height)
            if fit.isFinite {
                zoom = min(1, max(fit, PinState.zoomRange.lowerBound))
            }
        }
        zoom = effectiveZoom(for: safeBase, state: PinState(zoom: zoom))
        let size = CGSize(
            width: max(1, (safeBase.width * zoom).rounded()),
            height: max(1, (safeBase.height * zoom).rounded())
        )
        let frame = CGRect(
            x: (safeVisible.midX - size.width / 2).rounded(),
            y: (safeVisible.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        return (frame, zoom)
    }

    /// Returns `image` rotated clockwise by a multiple of 90 degrees (other angles return
    /// the original image).
    static func rotatedImage(_ image: CGImage, clockwiseDegrees degrees: Int) -> CGImage? {
        transformedImage(image, clockwiseDegrees: degrees, flipHorizontal: false, flipVertical: false)
    }

    /// Returns `image` rotated clockwise by a multiple of 90 degrees and mirrored in screen space.
    static func transformedImage(
        _ image: CGImage,
        clockwiseDegrees degrees: Int,
        flipHorizontal: Bool,
        flipVertical: Bool
    ) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let degrees = ((degrees % 360) + 360) % 360
        if degrees == 0, !flipHorizontal, !flipVertical {
            return image
        }
        guard degrees % 90 == 0 else { return image }
        let quarter = degrees % 180 == 90
        let width = quarter ? image.height : image.width
        let height = quarter ? image.width : image.height
        guard let context = makeRGBContext(
            width: width,
            height: height,
            preferredColorSpace: image.colorSpace
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        if flipHorizontal || flipVertical {
            context.scaleBy(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
        }
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(
            image,
            in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                       width: CGFloat(image.width), height: CGFloat(image.height))
        )
        return context.makeImage()
    }

    static func isFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}

/// Draws pin content into the current `NSGraphicsContext`.
@MainActor
enum PinRenderer {
    /// Draws `content` filling `rect` (in base-size coordinates; caller applies zoom/rotation).
    static func draw(
        _ content: PinContent,
        in rect: CGRect,
        zoom: CGFloat,
        context: CGContext,
        cachedAttributedText: NSAttributedString? = nil
    ) {
        switch content {
        case let .image(image, _):
            // Pixel-exact at 100%; smooth when scaled.
            context.interpolationQuality = abs(zoom - 1) < 0.001 ? .none : .high
            context.draw(image, in: rect)
        case let .text(text):
            NSColor.textBackgroundColor.setFill()
            rect.fill()
            let textRect = rect.insetBy(dx: PinLayout.textPadding, dy: PinLayout.textPadding)
            let attributed = cachedAttributedText
                ?? NSAttributedString(string: PinLayout.displayText(for: text), attributes: PinLayout.textAttributes())
            attributed.draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
            )
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

    /// Renders `content` at its base size into a bitmap (used for copy/save/OCR of
    /// non-image pins and transformed images).
    static func exportImage(
        for content: PinContent,
        rotationDegrees: Int,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        scale: CGFloat = 2,
        appearance: NSAppearance? = nil
    ) -> CGImage? {
        if case let .image(image, _) = content {
            return PinLayout.transformedImage(
                image,
                clockwiseDegrees: rotationDegrees,
                flipHorizontal: flipHorizontal,
                flipVertical: flipVertical
            )
        }
        let safeScale = PinLayout.sanitizedScale(scale)
        let size = PinLayout.baseSize(for: content)
        let rawWidth = (size.width * safeScale).rounded()
        let rawHeight = (size.height * safeScale).rounded()
        guard rawWidth.isFinite, rawHeight.isFinite,
              rawWidth >= 1, rawHeight >= 1,
              rawWidth <= CGFloat(PinLayout.maxImagePixelDimension),
              rawHeight <= CGFloat(PinLayout.maxImagePixelDimension)
        else { return nil }
        let width = Int(rawWidth)
        let height = Int(rawHeight)
        guard let context = PinLayout.makeRGBContext(
            width: width,
            height: height,
            preferredColorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) else { return nil }
        context.scaleBy(x: safeScale, y: safeScale)
        let drawBlock = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(content, in: CGRect(origin: .zero, size: size), zoom: 1, context: context)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(drawBlock)
        } else {
            drawBlock()
        }
        guard let rendered = context.makeImage() else { return nil }
        return PinLayout.transformedImage(
            rendered,
            clockwiseDegrees: rotationDegrees,
            flipHorizontal: flipHorizontal,
            flipVertical: flipVertical
        )
    }
}
