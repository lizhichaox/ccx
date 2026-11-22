import AppKit
import CoreGraphics
import Foundation

/// Vector, text, counter, and mosaic renderer shared between live overlay canvas and final export baking.
public enum AnnotationRenderer {
    public static func draw(
        _ item: AnnotationItem,
        in context: CGContext,
        screenBounds: CGRect,
        mosaicImage: ((MosaicMode, StrokePreset) -> CGImage?)?
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        switch item.kind {
        case let .rectangle(raw):
            let rect = raw.standardized
            guard rect.width >= 1, rect.height >= 1 else { return }
            let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.setStrokeColor(item.style.color.cgColor)
            context.setLineWidth(item.style.size.lineWidth)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()

        case let .ellipse(raw):
            let rect = raw.standardized
            guard rect.width >= 1, rect.height >= 1 else { return }
            context.setStrokeColor(item.style.color.cgColor)
            context.setLineWidth(item.style.size.lineWidth)
            context.strokeEllipse(in: rect)

        case let .arrow(start, end):
            drawArrow(from: start, to: end, color: item.style.color.cgColor, lineWidth: item.style.size.lineWidth, in: context)

        case let .pen(points):
            drawSmoothPolyline(
                points,
                color: item.style.color.cgColor,
                lineWidth: item.style.size.lineWidth,
                alpha: 1,
                in: context
            )

        case let .highlighter(points):
            drawSmoothPolyline(
                points,
                color: item.style.color.cgColor,
                lineWidth: item.style.size.highlighterWidth,
                alpha: 0.36,
                in: context
            )

        case let .mosaic(raw, mode):
            let rect = raw.standardized
            guard rect.width >= 1, rect.height >= 1 else { return }
            context.saveGState()
            context.clip(to: rect)
            if let filtered = mosaicImage?(mode, item.style.size) {
                let visible = rect.intersection(screenBounds)
                if !visible.isNull, !visible.isEmpty,
                   screenBounds.width > 0, screenBounds.height > 0 {
                    let scaleX = CGFloat(filtered.width) / screenBounds.width
                    let scaleY = CGFloat(filtered.height) / screenBounds.height
                    let pxMinX = max(0, Int(floor((visible.minX - screenBounds.minX) * scaleX)))
                    let pxMaxX = min(filtered.width, Int(ceil((visible.maxX - screenBounds.minX) * scaleX)))
                    let pxMinY = max(0, Int(floor((screenBounds.maxY - visible.maxY) * scaleY)))
                    let pxMaxY = min(filtered.height, Int(ceil((screenBounds.maxY - visible.minY) * scaleY)))
                    let pixelRect = CGRect(
                        x: pxMinX,
                        y: pxMinY,
                        width: max(0, pxMaxX - pxMinX),
                        height: max(0, pxMaxY - pxMinY)
                    )
                    if !pixelRect.isEmpty, let cropped = filtered.cropping(to: pixelRect) {
                        let drawRect = CGRect(
                            x: screenBounds.minX + CGFloat(pxMinX) / scaleX,
                            y: screenBounds.maxY - CGFloat(pxMaxY) / scaleY,
                            width: CGFloat(cropped.width) / scaleX,
                            height: CGFloat(cropped.height) / scaleY
                        )
                        context.draw(cropped, in: drawRect)
                    } else {
                        context.draw(filtered, in: screenBounds)
                    }
                }
            } else {
                context.setFillColor(NSColor(white: 0.25, alpha: 0.85).cgColor)
                context.fill(rect)
            }
            context.restoreGState()

        case let .text(origin, content):
            guard !content.isEmpty else { return }
            let rect = AnnotationItem.textBoundingBox(origin: origin, content: content, fontSize: item.style.size.fontSize)
            let attributed = NSAttributedString(
                string: content,
                attributes: AnnotationItem.textAttributes(color: item.style.color, fontSize: item.style.size.fontSize)
            )
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -1),
                blur: 3,
                color: CGColor(gray: 0, alpha: 0.45)
            )
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            attributed.draw(in: rect.insetBy(dx: 3, dy: 2))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()

        case let .counter(center, number):
            drawCounter(center: center, number: number, style: item.style, in: context)
        }
    }

    public static func drawSelectionChrome(for item: AnnotationItem, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let bounds = item.boundingBox.insetBy(dx: -4, dy: -4)
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(bounds)
        context.setLineDash(phase: 0, lengths: [])

        for center in item.handlePoints.values {
            let handleRect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: handleRect)
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: handleRect)
        }
    }

    /// Bakes all committed annotations onto the cropped backing pixels at full Retina resolution.
    @MainActor
    public static func bake(
        baseImage: CGImage,
        localSelectionRect: CGRect,
        pixelCropRect: CGRect,
        screenSize: CGSize,
        document: AnnotationDocument,
        mosaicCache: MosaicImageCache?
    ) -> CGImage? {
        guard let cropped = baseImage.cropping(to: pixelCropRect) else { return nil }
        guard !document.items.isEmpty else { return cropped }

        let width = cropped.width
        let height = cropped.height
        let colorSpace = baseImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cropped }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sx = screenSize.width > 0 ? CGFloat(baseImage.width) / screenSize.width : 1
        let sy = screenSize.height > 0 ? CGFloat(baseImage.height) / screenSize.height : 1
        let scale = max(sx, sy)
        let screenBounds = CGRect(origin: .zero, size: screenSize)

        context.saveGState()
        context.scaleBy(x: sx, y: sy)
        context.translateBy(x: -localSelectionRect.minX, y: -localSelectionRect.minY)
        for item in document.items {
            draw(item, in: context, screenBounds: screenBounds) { mode, preset in
                mosaicCache?.filteredImage(mode: mode, preset: preset, backingScale: scale)
            }
        }
        context.restoreGState()

        return context.makeImage() ?? cropped
    }

    // MARK: - Primitives

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: CGColor,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 2 else { return }

        let ux = dx / length
        let uy = dy / length
        let px = -uy
        let py = ux

        let headLength = min(length * 0.72, max(14, lineWidth * 4.2))
        let headHalfWidth = max(6, lineWidth * 1.75)
        let neckHalfWidth = max(0.8, lineWidth * 0.55)
        let tailHalfWidth = max(0.4, lineWidth * 0.22)

        let neck = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let baseCenter = CGPoint(x: end.x - ux * (headLength * 0.78), y: end.y - uy * (headLength * 0.78))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: start.x + px * tailHalfWidth, y: start.y + py * tailHalfWidth))
        path.addLine(to: CGPoint(x: neck.x + px * neckHalfWidth, y: neck.y + py * neckHalfWidth))
        path.addLine(to: CGPoint(x: baseCenter.x + px * headHalfWidth, y: baseCenter.y + py * headHalfWidth))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: baseCenter.x - px * headHalfWidth, y: baseCenter.y - py * headHalfWidth))
        path.addLine(to: CGPoint(x: neck.x - px * neckHalfWidth, y: neck.y - py * neckHalfWidth))
        path.addLine(to: CGPoint(x: start.x - px * tailHalfWidth, y: start.y - py * tailHalfWidth))
        path.closeSubpath()

        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
    }

    private static func drawSmoothPolyline(
        _ points: [CGPoint],
        color: CGColor,
        lineWidth: CGFloat,
        alpha: CGFloat,
        in context: CGContext
    ) {
        guard let first = points.first else { return }
        let resolvedColor = alpha >= 0.999 ? color : (color.copy(alpha: alpha) ?? color)
        context.setStrokeColor(resolvedColor)
        context.setFillColor(resolvedColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if points.count == 1 {
            let r = lineWidth / 2
            context.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: lineWidth, height: lineWidth))
            return
        }

        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[i].x + points[i + 1].x) / 2,
                    y: (points[i].y + points[i + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: points[i])
            }
            if let last = points.last {
                path.addLine(to: last)
            }
        }
        context.addPath(path)
        context.strokePath()
    }

    private static func drawCounter(
        center: CGPoint,
        number: Int,
        style: AnnotationStyle,
        in context: CGContext
    ) {
        let diameter = style.size.counterDiameter
        let circle = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1),
            blur: 3,
            color: CGColor(gray: 0, alpha: 0.35)
        )
        context.setFillColor(style.color.cgColor)
        context.fillEllipse(in: circle)
        context.restoreGState()

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))

        let labelColor: NSColor = style.color.isLightColor ? .black : .white
        let font = NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.52, weight: .bold)
        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor,
        ]
        let size = text.size(withAttributes: attrs)
        let origin = CGPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
