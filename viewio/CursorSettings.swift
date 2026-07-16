//
//  CursorSettings.swift
//  viewio
//
//  Post-record cursor style + motion. Track data is captured while recording;
//  the system cursor is hidden in the file so we can redraw it here.
//
//  Native macOS looks load real cursor PDFs from HIServices (same assets the
//  Window Server uses). Arrow white/black are high-quality recreations of the
//  system pointer (the default arrow PDF is not exposed as a file).
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Settings

struct CursorSettings: Equatable {
    var isEnabled: Bool = true
    var style: CursorStyle = .macArrow
    var motion: CursorMotionStyle = .smooth
    var size: Double = 1.0
    var clickEffect: CursorClickEffect = .ripple

    static let `default` = CursorSettings()
}

// MARK: - Style

/// Built-in looks for the post-record cursor overlay.
enum CursorStyle: String, CaseIterable, Identifiable {
    // macOS native (system PDF assets where available)
    case macArrow
    case macArrowBlack
    case macHand
    case macIBeam
    case macCrosshair
    case macOpenHand
    case macClosedHand
    case macResizeH
    case macResizeV
    case macMove
    case macNotAllowed
    case macZoomIn
    case macZoomOut
    case macHelp
    case macCopy
    // Lightweight custom accents
    case modern
    case soft
    case dot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macArrow: "Arrow"
        case .macArrowBlack: "Arrow Black"
        case .macHand: "Hand"
        case .macIBeam: "I-Beam"
        case .macCrosshair: "Crosshair"
        case .macOpenHand: "Open Hand"
        case .macClosedHand: "Grab"
        case .macResizeH: "Resize ↔"
        case .macResizeV: "Resize ↕"
        case .macMove: "Move"
        case .macNotAllowed: "Forbidden"
        case .macZoomIn: "Zoom In"
        case .macZoomOut: "Zoom Out"
        case .macHelp: "Help"
        case .macCopy: "Copy"
        case .modern: "Modern"
        case .soft: "Soft"
        case .dot: "Dot"
        }
    }

    var subtitle: String {
        switch self {
        case .macArrow: "macOS white pointer"
        case .macArrowBlack: "macOS black pointer"
        case .macHand: "Pointing hand"
        case .macIBeam: "Text selection"
        case .macCrosshair: "Precise cross"
        case .macOpenHand: "Open palm"
        case .macClosedHand: "Closed grab"
        case .macResizeH: "Horizontal resize"
        case .macResizeV: "Vertical resize"
        case .macMove: "Move / drag"
        case .macNotAllowed: "Not allowed"
        case .macZoomIn: "Zoom in"
        case .macZoomOut: "Zoom out"
        case .macHelp: "Help arrow"
        case .macCopy: "Drag copy"
        case .modern: "Rounded tip"
        case .soft: "Soft outline"
        case .dot: "Minimal circle"
        }
    }

    /// HIServices folder under `…/Resources/cursors/`.
    var systemCursorFolder: String? {
        switch self {
        case .macHand: "pointinghand"
        case .macIBeam: "ibeamvertical"
        case .macCrosshair: "cross"
        case .macOpenHand: "openhand"
        case .macClosedHand: "closedhand"
        case .macResizeH: "resizeleftright"
        case .macResizeV: "resizeupdown"
        case .macMove: "move"
        case .macNotAllowed: "notallowed"
        case .macZoomIn: "zoomin"
        case .macZoomOut: "zoomout"
        case .macHelp: "help"
        case .macCopy: "copy"
        default: nil
        }
    }

    var isNativeMacOS: Bool {
        switch self {
        case .modern, .soft, .dot: false
        default: true
        }
    }

    /// True when the hotspot is the arrow tip (top-left), so tip-pixel detection
    /// is valid. Centered cursors (cross, I-beam, …) must use the system plist
    /// hotspot instead.
    var usesArrowTipHotspot: Bool {
        switch self {
        case .macArrow, .macArrowBlack, .modern, .soft:
            true
        default:
            false
        }
    }
}

// MARK: - Motion

enum CursorMotionStyle: String, CaseIterable, Identifiable {
    case precise
    case natural
    case smooth
    case fluid
    case cinematic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .precise: "Precise"
        case .natural: "Natural"
        case .smooth: "Smooth"
        case .fluid: "Fluid"
        case .cinematic: "Cinematic"
        }
    }

    var subtitle: String {
        switch self {
        case .precise: "Exact path, no lag"
        case .natural: "Light interpolation"
        case .smooth: "Softened movement"
        case .fluid: "Glides between points"
        case .cinematic: "Slow, polished ease"
        }
    }

    /// Exponential moving-average weight (higher = snappier).
    var smoothingAlpha: Double {
        switch self {
        case .precise: 1.0
        case .natural: 0.85
        case .smooth: 0.42
        case .fluid: 0.22
        case .cinematic: 0.12
        }
    }

    var usesEasedInterpolation: Bool {
        switch self {
        case .cinematic, .fluid: true
        default: false
        }
    }
}

// MARK: - Click effect

enum CursorClickEffect: String, CaseIterable, Identifiable {
    case none
    case ripple
    case ring
    case pulse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .ripple: "Ripple"
        case .ring: "Ring"
        case .pulse: "Pulse"
        }
    }
}

// MARK: - Track processing

enum CursorMotion {
    /// Track samples are expected in **video top-left** normalized space (0...1).
    /// Applies optional motion smoothing for camera-style paths.
    static func process(
        track: [CursorPosition],
        motion: CursorMotionStyle
    ) -> [CursorPosition] {
        guard !track.isEmpty else { return [] }

        let videoSpace = track.map { sample in
            CursorPosition(
                time: sample.time,
                x: min(1, max(0, sample.x)),
                y: min(1, max(0, sample.y))
            )
        }

        let alpha = motion.smoothingAlpha
        guard alpha < 0.999, videoSpace.count >= 2 else {
            return videoSpace
        }

        var smoothed: [CursorPosition] = []
        smoothed.reserveCapacity(videoSpace.count)
        var sx = videoSpace[0].x
        var sy = videoSpace[0].y
        smoothed.append(videoSpace[0])

        for index in 1..<videoSpace.count {
            let sample = videoSpace[index]
            let dt = max(0.001, sample.time - videoSpace[index - 1].time)
            let frameAlpha = 1 - pow(1 - alpha, dt * 30)
            sx += (sample.x - sx) * frameAlpha
            sy += (sample.y - sy) * frameAlpha
            smoothed.append(CursorPosition(time: sample.time, x: sx, y: sy))
        }
        return smoothed
    }

    static func position(
        at time: Double,
        in track: [CursorPosition],
        motion: CursorMotionStyle
    ) -> CGPoint {
        guard !track.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }

        if let index = track.firstIndex(where: { $0.time >= time }) {
            if index == 0 {
                return CGPoint(x: track[0].x, y: track[0].y)
            }
            let previous = track[index - 1]
            let next = track[index]
            var t = (time - previous.time) / max(0.001, next.time - previous.time)
            t = min(1, max(0, t))
            // Only ease for cinematic camera paths — never for precise tip drawing.
            if motion.usesEasedInterpolation {
                t = t * t * t * (t * (t * 6 - 15) + 10)
            }
            return CGPoint(
                x: previous.x + (next.x - previous.x) * t,
                y: previous.y + (next.y - previous.y) * t
            )
        }

        if let last = track.last {
            return CGPoint(x: last.x, y: last.y)
        }
        return CGPoint(x: 0.5, y: 0.5)
    }
}

// MARK: - Cursor artwork

enum CursorArtwork {
    private static let systemCursorsRoot = URL(fileURLWithPath:
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"
    )

    private static var imageCache: [String: NSImage] = [:]
    private static var hotspotCache: [CursorStyle: CGPoint] = [:]
    private static let cacheLock = NSLock()

    /// Hotspot as a fraction of image size (origin top-left of the bitmap).
    /// System cursors use Apple's `info.plist` hotx/hoty (correct for crosshair,
    /// I-beam, hands, etc.). Drawn arrows use tip detection so the hotspot
    /// lands exactly on the recorded cursor point.
    static func hotspot(for style: CursorStyle) -> CGPoint {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = hotspotCache[style] {
            return cached
        }
        // Force-render so system/drawn hotspots are populated.
        cacheLock.unlock()
        _ = image(style: style, scale: 3)
        cacheLock.lock()
        if let cached = hotspotCache[style] {
            return cached
        }
        let value = fallbackHotspot(for: style)
        hotspotCache[style] = value
        return value
    }

    static func image(style: CursorStyle, scale: CGFloat = 2) -> NSImage {
        let cacheKey = "\(style.rawValue)@\(scale)"
        cacheLock.lock()
        if let cached = imageCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let rendered: NSImage
        let hotspot: CGPoint
        if let folder = style.systemCursorFolder,
           let system = renderSystemCursor(folder: folder, pixelScale: max(2, scale)) {
            rendered = system.image
            // Apple's hotx/hoty are the real click point for each system cursor.
            // Never use "topmost pixel" here — that breaks crosshair, I-beam, hands.
            hotspot = system.hotspot
        } else if style.usesArrowTipHotspot {
            rendered = renderDrawnCursor(style: style, scale: max(2, scale))
            // Use the detected tip directly so the overlay hotspot matches the
            // recorded cursor point instead of being shifted by an optical nudge.
            hotspot = detectTipHotspot(in: rendered) ?? fallbackHotspot(for: style)
        } else {
            rendered = renderDrawnCursor(style: style, scale: max(2, scale))
            hotspot = fallbackHotspot(for: style)
        }

        cacheLock.lock()
        imageCache[cacheKey] = rendered
        hotspotCache[style] = hotspot
        cacheLock.unlock()
        return rendered
    }

    static func cgImage(style: CursorStyle) -> CGImage? {
        let nsImage = image(style: style, scale: 3)
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: Tip / hotspot

    private static func fallbackHotspot(for style: CursorStyle) -> CGPoint {
        if let folder = style.systemCursorFolder,
           let meta = loadSystemCursorMetadata(folder: folder) {
            return CGPoint(
                x: meta.hotX / max(meta.width, 1),
                y: meta.hotY / max(meta.height, 1)
            )
        }
        switch style {
        case .macArrow, .macArrowBlack, .modern, .soft:
            return CGPoint(x: 5.0 / 32.0, y: 4.0 / 32.0)
        case .dot:
            return CGPoint(x: 0.5, y: 0.5)
        default:
            return CGPoint(x: 0.2, y: 0.15)
        }
    }

    /// Find the topmost (then leftmost) opaque pixel — the visual tip.
    /// The hotspot is the top-left corner of that pixel, which aligns with the
    /// actual point of the arrow better than the pixel center when the cursor
    /// is rendered at small sizes.
    private static func detectTipHotspot(in image: NSImage) -> CGPoint? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return detectTipHotspot(in: cgImage)
    }

    private static func detectTipHotspot(in image: CGImage) -> CGPoint? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw with top-left origin into our buffer (flip so row 0 is top).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let alphaThreshold: UInt8 = 40
        // Topmost row with ink, then leftmost pixel on that row (arrow tip).
        for y in 0..<height {
            var rowLeft: Int?
            for x in 0..<width {
                let alpha = data[y * bytesPerRow + x * bytesPerPixel + 3]
                if alpha >= alphaThreshold {
                    rowLeft = x
                    break
                }
            }
            if let x = rowLeft {
                return CGPoint(
                    x: CGFloat(x) / CGFloat(width),
                    y: CGFloat(y) / CGFloat(height)
                )
            }
        }
        return nil
    }

    // MARK: System PDF loaders

    private struct SystemCursorMetadata {
        var width: CGFloat
        var height: CGFloat
        var hotX: CGFloat
        var hotY: CGFloat
    }

    private static func loadSystemCursorMetadata(folder: String) -> SystemCursorMetadata? {
        let dir = systemCursorsRoot.appendingPathComponent(folder)
        let pdfURL = dir.appendingPathComponent("cursor.pdf")
        let infoURL = dir.appendingPathComponent("info.plist")
        guard FileManager.default.fileExists(atPath: pdfURL.path) else { return nil }

        var width: CGFloat = 32
        var height: CGFloat = 32
        if let doc = CGPDFDocument(pdfURL as CFURL), let page = doc.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            width = box.width
            height = box.height
        }

        var hotX = width * 0.2
        var hotY = height * 0.15
        if let info = NSDictionary(contentsOf: infoURL) {
            if let x = info["hotx"] as? NSNumber { hotX = CGFloat(truncating: x) }
            if let y = info["hoty"] as? NSNumber { hotY = CGFloat(truncating: y) }
        }
        return SystemCursorMetadata(width: width, height: height, hotX: hotX, hotY: hotY)
    }

    private static func renderSystemCursor(
        folder: String,
        pixelScale: CGFloat
    ) -> (image: NSImage, hotspot: CGPoint)? {
        let dir = systemCursorsRoot.appendingPathComponent(folder)
        let pdfURL = dir.appendingPathComponent("cursor.pdf")
        guard let doc = CGPDFDocument(pdfURL as CFURL),
              let page = doc.page(at: 1) else {
            return nil
        }

        let box = page.getBoxRect(.mediaBox)
        let scale = max(2, pixelScale)
        let pixelWidth = max(1, Int((box.width * scale).rounded()))
        let pixelHeight = max(1, Int((box.height * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        // Bitmap contexts are bottom-up; flip while drawing so the PDF is upright
        // in the final image (tip at the top).
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.drawPDFPage(page)

        guard let cgImage = context.makeImage() else { return nil }
        let size = NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        let image = NSImage(cgImage: cgImage, size: size)

        let meta = loadSystemCursorMetadata(folder: folder)
        // hotx/hoty in info.plist are from the top-left of the cursor artwork.
        let hotspot = CGPoint(
            x: (meta?.hotX ?? box.width * 0.2) / max(box.width, 1),
            y: (meta?.hotY ?? box.height * 0.15) / max(box.height, 1)
        )
        return (image, hotspot)
    }

    // MARK: Drawn cursors (arrow white/black + accents)

    private static func renderDrawnCursor(style: CursorStyle, scale: CGFloat) -> NSImage {
        let base: CGFloat = 32
        let pixel = base * scale

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(pixel),
                height: Int(pixel),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return NSImage(size: NSSize(width: pixel, height: pixel))
        }

        context.clear(CGRect(origin: .zero, size: CGSize(width: pixel, height: pixel)))
        // Flip Y so we can draw in top-left space (y down), matching how the
        // hotspot and SwiftUI/CALayer present the bitmap.
        context.translateBy(x: 0, y: pixel)
        context.scaleBy(x: scale, y: -scale)

        switch style {
        case .macArrow:
            drawMacArrow(
                in: context,
                fill: .white,
                stroke: .black,
                lineWidth: 1.15,
                shadow: true
            )
        case .macArrowBlack:
            drawMacArrow(
                in: context,
                fill: .black,
                stroke: .white,
                lineWidth: 1.25,
                shadow: true
            )
        case .modern:
            drawModernArrow(in: context)
        case .soft:
            drawMacArrow(
                in: context,
                fill: NSColor.white.withAlphaComponent(0.96),
                stroke: NSColor.black.withAlphaComponent(0.32),
                lineWidth: 0.95,
                shadow: false
            )
        case .dot:
            drawDot(in: context)
        default:
            drawMacArrow(in: context, fill: .white, stroke: .black, lineWidth: 1.15, shadow: true)
        }

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: pixel, height: pixel))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: base, height: base))
    }

    /// macOS-style arrow in top-left space (y grows downward). Tip near (5, 4).
    private static func drawMacArrow(
        in context: CGContext,
        fill: NSColor,
        stroke: NSColor,
        lineWidth: CGFloat,
        shadow: Bool
    ) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 4))
        path.addLine(to: CGPoint(x: 5, y: 25))
        path.addLine(to: CGPoint(x: 10.5, y: 19.5))
        path.addLine(to: CGPoint(x: 15.5, y: 28.5))
        path.addLine(to: CGPoint(x: 18.2, y: 27.2))
        path.addLine(to: CGPoint(x: 13.2, y: 18.2))
        path.addLine(to: CGPoint(x: 21.5, y: 18.2))
        path.closeSubpath()

        if shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 1.8,
                color: NSColor.black.withAlphaComponent(0.28).cgColor
            )
        }

        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()

        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
    }

    private static func drawModernArrow(in context: CGContext) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 5))
        path.addLine(to: CGPoint(x: 5, y: 25))
        path.addQuadCurve(to: CGPoint(x: 11, y: 20), control: CGPoint(x: 7, y: 23))
        path.addLine(to: CGPoint(x: 16, y: 28))
        path.addQuadCurve(to: CGPoint(x: 19, y: 26), control: CGPoint(x: 18, y: 28))
        path.addLine(to: CGPoint(x: 13.5, y: 18.5))
        path.addQuadCurve(to: CGPoint(x: 22, y: 18), control: CGPoint(x: 18, y: 19))
        path.addQuadCurve(to: CGPoint(x: 5, y: 5), control: CGPoint(x: 14, y: 10))
        path.closeSubpath()

        context.setShadow(
            offset: CGSize(width: 0, height: 1),
            blur: 1.5,
            color: NSColor.black.withAlphaComponent(0.22).cgColor
        )
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.15)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private static func drawDot(in context: CGContext) {
        let rect = CGRect(x: 10, y: 10, width: 12, height: 12)
        context.setShadow(
            offset: CGSize(width: 0, height: 1),
            blur: 2.5,
            color: NSColor.black.withAlphaComponent(0.25).cgColor
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fillEllipse(in: rect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect.insetBy(dx: -0.5, dy: -0.5))
    }
}
