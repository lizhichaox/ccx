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
            guard isFiniteRect(raw) else { return }
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
            guard isFiniteRect(raw) else { return }
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
            guard isFiniteRect(raw) else { return }
            let rect = raw.standardized
            guard rect.width >= 1, rect.height >= 1 else { return }
            context.saveGState()
            context.clip(to: rect)
            if mode == .pixelate {
                context.interpolationQuality = .none
            }
            if let filtered = mosaicImage?(mode, item.style.size) {
                guard isFiniteRect(screenBounds) else {
                    context.restoreGState()
                    return
                }
                let visible = rect.intersection(screenBounds)
                if !visible.isNull, !visible.isEmpty,
                   screenBounds.width > 0, screenBounds.height > 0 {
                    let scaleX = CGFloat(filtered.width) / screenBounds.width
                    let scaleY = CGFloat(filtered.height) / screenBounds.height
                    let rawMinX = floor((visible.minX - screenBounds.minX) * scaleX)
                    let rawMaxX = ceil((visible.maxX - screenBounds.minX) * scaleX)
                    let rawMinY = floor((screenBounds.maxY - visible.maxY) * scaleY)
                    let rawMaxY = ceil((screenBounds.maxY - visible.minY) * scaleY)
                    if scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0,
                       rawMinX.isFinite, rawMaxX.isFinite, rawMinY.isFinite, rawMaxY.isFinite {
                        let maxW = CGFloat(filtered.width)
                        let maxH = CGFloat(filtered.height)
                        let pxMinX = Int(min(max(rawMinX, 0), maxW))
                        let pxMaxX = Int(min(max(rawMaxX, 0), maxW))
                        let pxMinY = Int(min(max(rawMinY, 0), maxH))
                        let pxMaxY = Int(min(max(rawMaxY, 0), maxH))
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
            guard origin.x.isFinite, origin.y.isFinite, !content.isEmpty else { return }
            let bounded = AnnotationItem.boundedText(content)
            let rect = AnnotationItem.textBoundingBox(origin: origin, content: bounded, fontSize: item.style.size.fontSize)
            let attributed = NSAttributedString(
                string: bounded,
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
            guard center.x.isFinite, center.y.isFinite else { return }
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

        let blueCG = NSColor.systemBlue.cgColor
        if let bounds = boundsToStroke {
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.65))
            context.setLineWidth(1.75)
            context.stroke(bounds)

            context.setStrokeColor(blueCG.copy(alpha: 0.95) ?? blueCG)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(bounds)
            context.setLineDash(phase: 0, lengths: [])
        }

        let handleCenters = item.handlePoints.values
        guard !handleCenters.isEmpty else { return }

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -0.5),
            blur: 2,
            color: CGColor(gray: 0, alpha: 0.35)
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for center in handleCenters where center.x.isFinite && center.y.isFinite {
            let handleRect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            context.fillEllipse(in: handleRect)
        }
        context.restoreGState()

        context.setStrokeColor(blueCG)
        context.setLineWidth(1.5)
        for center in handleCenters where center.x.isFinite && center.y.isFinite {
            let handleRect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
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
        guard sx.isFinite, sy.isFinite, sx >= 0.01, sx <= 64, sy >= 0.01, sy <= 64 else { return nil }
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
        guard cropOriginX.isFinite, cropOriginY.isFinite else { return nil }

        guard let context = makeBakeContext(width: width, height: height, baseImage: baseImage) else {
            return nil
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cropped, in: canvas)

        let hasNonMosaicItems = document.items.contains {
            if case .mosaic = $0.kind { return false }
            return true
        }
        let cornerMask = hasNonMosaicItems ? exteriorCornerMask(in: cropped, scaleX: sx, scaleY: sy) : nil
        let interiorPath = CGMutablePath()
        if let cornerMask {
            interiorPath.addRect(canvas)
            interiorPath.addPath(cornerMask.path)
        }

        func drawInSelection(_ item: AnnotationItem, filtered: CGImage? = nil) {
            context.scaleBy(x: sx, y: sy)
            context.translateBy(x: -cropOriginX, y: -cropOriginY)
            draw(item, in: context, screenBounds: screenBounds) { _, _ in filtered }
        }

        func itemIntersectsProtectedCorners(_ item: AnnotationItem, cornerBounds: [CGRect]) -> Bool {
            let strokePad = max(
                item.style.size.highlighterWidth,
                item.style.size.lineWidth * 5,
                item.style.size.counterDiameter,
                24
            )
            let localBox = item.boundingBox.insetBy(dx: -strokePad, dy: -strokePad)
            let pixelBox = CGRect(
                x: (localBox.minX - cropOriginX) * sx,
                y: (localBox.minY - cropOriginY) * sy,
                width: localBox.width * sx,
                height: localBox.height * sy
            )
            return cornerBounds.contains { $0.intersects(pixelBox) }
        }

        for item in document.items {
            context.saveGState()
            if case let .mosaic(_, mode) = item.kind {
                let filtered = mosaicCache?.filteredImage(mode: mode, size: item.style.size, backingScale: scale)
                // The filtered image already carries the backing alpha. Copy it so no unfiltered
                // pixels are blended back in. The opaque fallback uses the destination alpha once.
                context.setBlendMode(filtered == nil ? .sourceAtop : .copy)
                drawInSelection(item, filtered: filtered)
            } else if let cornerMask, itemIntersectsProtectedCorners(item, cornerBounds: cornerMask.cornerBounds) {
                context.saveGState()
                context.addPath(interiorPath)
                context.clip(using: .evenOdd)
                drawInSelection(item)
                context.restoreGState()

                context.addPath(cornerMask.path)
                context.clip()
                context.setBlendMode(.sourceAtop)
                drawInSelection(item)
            } else {
                drawInSelection(item)
            }
            context.restoreGState()
        }

        return context.makeImage()
    }

    private static let exteriorAlphaThreshold: UInt8 = 8
    private static let bakeBitmapInfo: UInt32 =
        CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    internal static func hasTransparentExteriorCorners(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let lastX = image.width - 1
        let lastY = image.height - 1
        let middleX = image.width / 2
        let middleY = image.height / 2
        guard lastX > 0, lastY > 0,
              let sample = makeBakeContext(width: 1, height: 1, baseImage: image),
              let rgba = sample.data?.assumingMemoryBound(to: UInt8.self)
        else { return false }

        sample.setBlendMode(.copy)
        func alphaAt(_ x: Int, _ y: Int) -> UInt8? {
            guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
            sample.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgba[3]
        }

        let corners = [(0, 0), (lastX, 0), (0, lastY), (lastX, lastY)]
        guard corners.contains(where: { alphaAt($0.0, $0.1) ?? 255 < exteriorAlphaThreshold }) else {
            return false
        }
        // An ordinary padded image has a transparent edge midpoint. Window chrome can be translucent.
        let midpoints = [(0, middleY), (lastX, middleY), (middleX, 0), (middleX, lastY)]
        return midpoints.allSatisfy { alphaAt($0.0, $0.1) ?? 0 >= 16 }
    }

    private struct ExteriorCornerMask {
        let path: CGPath
        let cornerBounds: [CGRect]
    }

    private static func exteriorCornerMask(in image: CGImage, scaleX: CGFloat, scaleY: CGFloat) -> ExteriorCornerMask? {
        guard hasTransparentExteriorCorners(image) else { return nil }

        // Match the capture corner span and bound work even for malformed image scale metadata.
        let width = min(image.width / 2, Int((72 * min(max(scaleX, 1), 4)).rounded(.up)))
        let height = min(image.height / 2, Int((72 * min(max(scaleY, 1), 4)).rounded(.up)))
        guard width >= 2, height >= 2,
              let raster = makeBakeContext(width: width, height: height, baseImage: image),
              let rgba = raster.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }

        let path = CGMutablePath()
        var cornerBounds: [CGRect] = []
        let rowBytes = raster.bytesPerRow
        raster.setBlendMode(.copy)

        var exterior = [Bool](repeating: false, count: width * height)
        var pending: [(row: Int, col: Int)] = []
        pending.reserveCapacity(width + height)

        for y in [0, image.height - height] {
            for x in [0, image.width - width] {
                guard let patch = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else { continue }
                raster.draw(patch, in: CGRect(x: 0, y: 0, width: width, height: height))
                let cornerX = x == 0 ? 0 : width - 1
                let cornerY = y == 0 ? 0 : height - 1
                let innerX = width - 1 - cornerX
                let innerY = height - 1 - cornerY
                @inline(__always) func alphaAt(row: Int, col: Int) -> UInt8 {
                    rgba[row * rowBytes + col * 4 + 3]
                }

                guard alphaAt(row: cornerY, col: cornerX) < exteriorAlphaThreshold else { continue }
                exterior.withUnsafeMutableBufferPointer { $0.initialize(repeating: false) }
                exterior[cornerY * width + cornerX] = true
                pending.removeAll(keepingCapacity: true)
                pending.append((cornerY, cornerX))
                var reachesInnerEdge = false
                while let (row, column) = pending.popLast() {
                    if row == innerY || column == innerX {
                        reachesInnerEdge = true
                        break
                    }
                    @inline(__always) func visit(r: Int, c: Int) {
                        let idx = r * width + c
                        guard !exterior[idx], alphaAt(row: r, col: c) < exteriorAlphaThreshold else { return }
                        exterior[idx] = true
                        pending.append((r, c))
                    }
                    if column > 0 { visit(r: row, c: column - 1) }
                    if column + 1 < width { visit(r: row, c: column + 1) }
                    if row > 0 { visit(r: row - 1, c: column) }
                    if row + 1 < height { visit(r: row + 1, c: column) }
                }
                guard !reachesInnerEdge else { continue }

                // Include the nearby antialiasing fringe while leaving translucent chrome
                // farther from the exterior available for ordinary source-over drawing.
                func isProtected(column: Int, row: Int) -> Bool {
                    if exterior[row * width + column] { return true }
                    guard alphaAt(row: row, col: column) < 255 else { return false }
                    let rMin = max(0, row - 2), rMax = min(height - 1, row + 2)
                    let cMin = max(0, column - 2), cMax = min(width - 1, column + 2)
                    for nearbyRow in rMin...rMax {
                        let base = nearbyRow * width
                        for nearbyColumn in cMin...cMax where exterior[base + nearbyColumn] {
                            return true
                        }
                    }
                    return false
                }

                var patchBounds = CGRect.null
                for row in 0..<height {
                    var start: Int?
                    for column in 0...width {
                        if column < width && isProtected(column: column, row: row) {
                            if start == nil { start = column }
                        } else if let first = start {
                            let rect = CGRect(
                                x: x + first, y: image.height - y - row - 1,
                                width: column - first, height: 1
                            )
                            path.addRect(rect)
                            patchBounds = patchBounds.union(rect)
                            start = nil
                        }
                    }
                }
                if !patchBounds.isNull, !patchBounds.isEmpty {
                    cornerBounds.append(patchBounds)
                }
            }
        }
        return path.isEmpty ? nil : ExteriorCornerMask(path: path, cornerBounds: cornerBounds)
    }

    private static func isFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite &&
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite
    }

    private static func makeBakeContext(
        width: Int,
        height: Int,
        baseImage: CGImage
    ) -> CGContext? {
        let preferredSpace = resolvedOutputRGBColorSpace(for: baseImage)
        if let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: preferredSpace,
            bitmapInfo: bakeBitmapInfo
        ) {
            return ctx
        }
        let srgbFallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
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
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              lineWidth.isFinite, lineWidth > 0 else { return }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, length >= 2 else { return }

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
        guard lineWidth.isFinite, lineWidth > 0, !points.isEmpty else { return }
        let safePoints = points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            ? points
            : points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = safePoints.first else { return }
        let resolvedColor = alpha >= 0.999 ? color : (color.copy(alpha: alpha) ?? color)
        context.setStrokeColor(resolvedColor)
        context.setFillColor(resolvedColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if safePoints.count == 1 {
            let r = lineWidth / 2
            context.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: lineWidth, height: lineWidth))
            return
        }

        let path = CGMutablePath()
        path.move(to: first)
        if safePoints.count == 2 {
            path.addLine(to: safePoints[1])
        } else {
            for i in 1..<(safePoints.count - 1) {
                let mid = CGPoint(
                    x: (safePoints[i].x + safePoints[i + 1].x) / 2,
                    y: (safePoints[i].y + safePoints[i + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: safePoints[i])
            }
            if let last = safePoints.last {
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
