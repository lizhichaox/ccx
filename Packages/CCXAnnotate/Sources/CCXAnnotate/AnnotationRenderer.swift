import AppKit
import CoreGraphics
import Foundation

/// Vector, text, counter, and mosaic renderer shared between live overlay canvas and final export baking.
public enum AnnotationRenderer {
    public static func draw(
        _ item: AnnotationItem,
        in context: CGContext,
        screenBounds: CGRect,
        mosaicImage: ((MosaicMode, StrokeSize) -> CGImage?)?
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        switch item.kind {
        case let .rectangle(raw):
            let rect = raw.standardized
            guard rect.width >= 1, rect.height >= 1 else { return }
            let cornerWidth = min(2, rect.width / 2)
            let cornerHeight = min(2, rect.height / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: nil)
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
            if mode == .pixelate {
                context.interpolationQuality = .none
            }
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
                // Opaque privacy-preserving fallback so failed filtering never leaks redacted pixels beneath.
                context.setFillColor(CGColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1.0))
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

        let boundsToStroke: CGRect?
        switch item.kind {
        case .rectangle, .ellipse, .mosaic:
            boundsToStroke = item.boundingBox
        case .arrow:
            boundsToStroke = nil
        case .pen, .highlighter, .text, .counter:
            boundsToStroke = item.boundingBox.insetBy(dx: -4, dy: -4)
        }

        if let bounds = boundsToStroke {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
            context.setLineWidth(1.75)
            context.stroke(bounds)

            context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(bounds)
            context.setLineDash(phase: 0, lengths: [])
        }

        for center in item.handlePoints.values {
            let handleRect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -0.5),
                blur: 2,
                color: CGColor(gray: 0, alpha: 0.35)
            )
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: handleRect)
            context.restoreGState()

            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: handleRect)
        }
    }

    /// Draws a live canvas-only dashed guide around a mosaic/blur box so users can spot and grab
    /// redacted regions on light backgrounds. Never called during final export baking.
    public static func drawMosaicGuide(for rect: CGRect, isDraft: Bool, in context: CGContext) {
        let standardized = rect.standardized
        guard standardized.width >= 1, standardized.height >= 1 else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let outline = standardized.insetBy(dx: 0.5, dy: 0.5)
        if isDraft {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(2.0)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(outline)

            context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.25)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(outline)
        } else {
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(outline)

            context.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
            context.setLineWidth(1.0)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(outline)
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
        guard !pixelCropRect.isNull,
              !pixelCropRect.isInfinite,
              pixelCropRect.origin.x.isFinite,
              pixelCropRect.origin.y.isFinite,
              pixelCropRect.width.isFinite,
              pixelCropRect.height.isFinite,
              baseImage.width > 0,
              baseImage.height > 0
        else { return nil }

        let imageBounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let clampedCrop = pixelCropRect.standardized.intersection(imageBounds).integral
        guard !clampedCrop.isNull, clampedCrop.width >= 1, clampedCrop.height >= 1,
              let cropped = baseImage.cropping(to: clampedCrop)
        else { return nil }
        guard !document.items.isEmpty else { return cropped }

        let width = cropped.width
        let height = cropped.height
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixelCount > 0, pixelCount <= 150_000_000 else { return nil }

        let sx = (screenSize.width.isFinite && screenSize.width > 0) ? CGFloat(baseImage.width) / screenSize.width : 1
        let sy = (screenSize.height.isFinite && screenSize.height > 0) ? CGFloat(baseImage.height) / screenSize.height : 1
        let scale = max(sx, sy)
        let screenBounds = CGRect(
            origin: .zero,
            size: CGSize(
                width: (screenSize.width.isFinite && screenSize.width > 0) ? screenSize.width : CGFloat(baseImage.width),
                height: (screenSize.height.isFinite && screenSize.height > 0) ? screenSize.height : CGFloat(baseImage.height)
            )
        )

        // Anchor translation to the actual rounded/clamped `clampedCrop` origin so baked annotations and
        // mosaic patches align pixel-for-pixel with `cropped` even for fractional or edge-clamped selections.
        let cropOriginX = clampedCrop.minX / sx
        let cropOriginY = (CGFloat(baseImage.height) - clampedCrop.maxY) / sy

        let drawAnnotations: (CGContext) -> Void = { context in
            context.saveGState()
            context.scaleBy(x: sx, y: sy)
            context.translateBy(x: -cropOriginX, y: -cropOriginY)
            for item in document.items {
                draw(item, in: context, screenBounds: screenBounds) { mode, size in
                    mosaicCache?.filteredImage(mode: mode, size: size, backingScale: scale)
                }
            }
            context.restoreGState()
        }

        if hasTransparentExteriorCorners(cropped) {
            return bakePreservingExteriorCorners(
                cropped: cropped,
                baseImage: baseImage,
                width: width,
                height: height,
                pixelCount: pixelCount,
                drawAnnotations: drawAnnotations
            )
        }

        guard let context = makeBakeContext(width: width, height: height, baseImage: baseImage) else {
            return nil
        }

        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        drawAnnotations(context)

        return context.makeImage()
    }

    private static let exteriorCornerAlphaThreshold: UInt8 = 250
    private static let bakeBitmapInfo: UInt32 =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    internal static func hasTransparentExteriorCorners(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            break
        @unknown default:
            break
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }

        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let corners: [(Int, Int)] = [
            (0, 0),
            (width - 1, 0),
            (0, height - 1),
            (width - 1, height - 1),
        ]

        return pixel.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: 1,
                      height: 1,
                      bitsPerComponent: 8,
                      bytesPerRow: 4,
                      space: colorSpace,
                      bitmapInfo: bakeBitmapInfo
                  )
            else {
                return false
            }
            ctx.setBlendMode(.copy)
            let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            for (x, y) in corners {
                guard let cornerCrop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
                    continue
                }
                ctx.draw(cornerCrop, in: unitRect)
                if rawBuffer[3] < exteriorCornerAlphaThreshold {
                    return true
                }
            }
            return false
        }
    }

    private static func bakePreservingExteriorCorners(
        cropped: CGImage,
        baseImage: CGImage,
        width: Int,
        height: Int,
        pixelCount: Int,
        drawAnnotations: (CGContext) -> Void
    ) -> CGImage? {
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else { return nil }
        let (byteCount, countOverflow) = height.multipliedReportingOverflow(by: bytesPerRow)
        guard !countOverflow else { return nil }

        var baseBytes = [UInt8](repeating: 0, count: byteCount)
        let drewBase = baseBytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = makeBakeContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bytesPerRow: bytesPerRow,
                      baseImage: baseImage
                  )
            else {
                return false
            }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewBase else { return nil }

        var annotationBytes = [UInt8](repeating: 0, count: byteCount)
        let drewAnnotations = annotationBytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = makeBakeContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bytesPerRow: bytesPerRow,
                      baseImage: baseImage
                  )
            else {
                return false
            }
            drawAnnotations(ctx)
            return true
        }
        guard drewAnnotations else { return nil }

        let exteriorMask = exteriorCornerMask(from: baseBytes, width: width, height: height, pixelCount: pixelCount)

        baseBytes.withUnsafeMutableBufferPointer { baseBuf in
            annotationBytes.withUnsafeBufferPointer { annBuf in
                exteriorMask.withUnsafeBufferPointer { maskBuf in
                    for pixelIndex in 0..<pixelCount {
                        let offset = pixelIndex * 4
                        let sa = annBuf[offset + 3]
                        guard sa > 0 else { continue }

                        let da = baseBuf[offset + 3]
                        let invSa = UInt32(255 - sa)

                        if maskBuf[pixelIndex] != 0 {
                            // Exterior-connected corner / anti-aliased edge: Porter-Duff sourceAtop preserves
                            // exact `da` (`0` outside rounded corners, smooth anti-aliased alpha along the curve).
                            guard da > 0 else { continue }
                            let da32 = UInt32(da)
                            baseBuf[offset] = UInt8(min(255, (UInt32(annBuf[offset]) * da32 + UInt32(baseBuf[offset]) * invSa + 127) / 255))
                            baseBuf[offset + 1] = UInt8(min(255, (UInt32(annBuf[offset + 1]) * da32 + UInt32(baseBuf[offset + 1]) * invSa + 127) / 255))
                            baseBuf[offset + 2] = UInt8(min(255, (UInt32(annBuf[offset + 2]) * da32 + UInt32(baseBuf[offset + 2]) * invSa + 127) / 255))
                        } else if sa == 255 {
                            baseBuf[offset] = annBuf[offset]
                            baseBuf[offset + 1] = annBuf[offset + 1]
                            baseBuf[offset + 2] = annBuf[offset + 2]
                            baseBuf[offset + 3] = 255
                        } else {
                            // Interior pixel: standard Porter-Duff sourceOver leaves translucent interior content
                            // unharmed while compositing annotations normally.
                            baseBuf[offset] = UInt8(min(255, UInt32(annBuf[offset]) + (UInt32(baseBuf[offset]) * invSa + 127) / 255))
                            baseBuf[offset + 1] = UInt8(min(255, UInt32(annBuf[offset + 1]) + (UInt32(baseBuf[offset + 1]) * invSa + 127) / 255))
                            baseBuf[offset + 2] = UInt8(min(255, UInt32(annBuf[offset + 2]) + (UInt32(baseBuf[offset + 2]) * invSa + 127) / 255))
                            baseBuf[offset + 3] = UInt8(min(255, UInt32(sa) + (UInt32(da) * invSa + 127) / 255))
                        }
                    }
                }
            }
        }

        return baseBytes.withUnsafeMutableBytes { rawBuffer -> CGImage? in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = makeBakeContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bytesPerRow: bytesPerRow,
                      baseImage: baseImage
                  )
            else {
                return nil
            }
            return ctx.makeImage()
        }
    }

    /// Flood-fills exterior-connected transparent pixels (and their 1px anti-aliased fringe)
    /// starting only from corners whose alpha is below `exteriorCornerAlphaThreshold`.
    private static func exteriorCornerMask(
        from rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        pixelCount: Int
    ) -> [UInt8] {
        var visited = [UInt8](repeating: 0, count: pixelCount)
        var stack: [Int] = []
        stack.reserveCapacity(min(pixelCount, 1024))

        let cornerSeeds = [
            0,
            width - 1,
            (height - 1) * width,
            (height - 1) * width + (width - 1),
        ]
        for seed in cornerSeeds where visited[seed] == 0 {
            if rgbaBytes[seed * 4 + 3] < exteriorCornerAlphaThreshold {
                visited[seed] = 1
                stack.append(seed)
            }
        }

        while let idx = stack.popLast() {
            let row = idx / width
            let col = idx - row * width

            if col > 0 {
                let left = idx - 1
                if visited[left] == 0 {
                    let a = rgbaBytes[left * 4 + 3]
                    if a < exteriorCornerAlphaThreshold {
                        visited[left] = 1
                        stack.append(left)
                    } else if a < 255 {
                        visited[left] = 1
                    }
                }
            }
            if col + 1 < width {
                let right = idx + 1
                if visited[right] == 0 {
                    let a = rgbaBytes[right * 4 + 3]
                    if a < exteriorCornerAlphaThreshold {
                        visited[right] = 1
                        stack.append(right)
                    } else if a < 255 {
                        visited[right] = 1
                    }
                }
            }
            if row > 0 {
                let up = idx - width
                if visited[up] == 0 {
                    let a = rgbaBytes[up * 4 + 3]
                    if a < exteriorCornerAlphaThreshold {
                        visited[up] = 1
                        stack.append(up)
                    } else if a < 255 {
                        visited[up] = 1
                    }
                }
            }
            if row + 1 < height {
                let down = idx + width
                if visited[down] == 0 {
                    let a = rgbaBytes[down * 4 + 3]
                    if a < exteriorCornerAlphaThreshold {
                        visited[down] = 1
                        stack.append(down)
                    } else if a < 255 {
                        visited[down] = 1
                    }
                }
            }
        }

        return visited
    }

    private static func makeBakeContext(
        data: UnsafeMutableRawPointer? = nil,
        width: Int,
        height: Int,
        bytesPerRow: Int = 0,
        baseImage: CGImage
    ) -> CGContext? {
        let preferredSpace = resolvedOutputRGBColorSpace(for: baseImage)
        if let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: preferredSpace,
            bitmapInfo: bakeBitmapInfo
        ) {
            return ctx
        }
        let srgbFallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: srgbFallback,
            bitmapInfo: bakeBitmapInfo
        )
    }

    private static func resolvedOutputRGBColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb {
            if space.supportsOutput && !CGColorSpaceUsesExtendedRange(space) && !CGColorSpaceUsesITUR_2100TF(space) {
                return space
            }
            // Extended/HDR RGB spaces cannot back 8-bit integer CGContexts directly; preserve wide gamut via Display P3.
            if let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) {
                return displayP3
            }
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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
        let headHalfWidth = min(headLength * 0.55, max(6, lineWidth * 1.75))
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
        let numberString = "\(number)"
        let fontFactor: CGFloat = switch numberString.count {
        case ...1: 0.52
        case 2: 0.44
        default: 0.34
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: diameter * fontFactor, weight: .bold)
        let text = numberString as NSString
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
