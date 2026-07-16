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
    /// Converts Cocoa bottom-left samples to video top-left normalized points,
    /// then applies motion smoothing for the selected style.
    static func process(
        track: [CursorPosition],
        motion: CursorMotionStyle
    ) -> [CursorPosition] {
        guard !track.isEmpty else { return [] }

        let videoSpace = track.map { sample in
            CursorPosition(
                time: sample.time,
                x: min(1, max(0, sample.x)),
                y: min(1, max(0, 1 - sample.y))
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
    static func hotspot(for style: CursorStyle) -> CGPoint {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = hotspotCache[style] {
            return cached
        }
        let value = resolveHotspot(for: style)
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
        if let folder = style.systemCursorFolder,
           let system = renderSystemCursor(folder: folder, pixelScale: max(2, scale)) {
            rendered = system.image
            cacheLock.lock()
            hotspotCache[style] = system.hotspot
            cacheLock.unlock()
        } else {
            rendered = renderDrawnCursor(style: style, scale: max(2, scale))
        }

        cacheLock.lock()
        imageCache[cacheKey] = rendered
        cacheLock.unlock()
        return rendered
    }

    static func cgImage(style: CursorStyle) -> CGImage? {
        let nsImage = image(style: style, scale: 3)
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: System PDF loaders

    private static func resolveHotspot(for style: CursorStyle) -> CGPoint {
        if let folder = style.systemCursorFolder,
           let meta = loadSystemCursorMetadata(folder: folder) {
            return CGPoint(
                x: meta.hotX / max(meta.width, 1),
                y: meta.hotY / max(meta.height, 1)
            )
        }
        switch style {
        case .macArrow, .macArrowBlack, .modern, .soft:
            // Tip near top-left of the drawn arrow in a 32pt box.
            return CGPoint(x: 4.0 / 32.0, y: 4.0 / 32.0)
        case .dot:
            return CGPoint(x: 0.5, y: 0.5)
        default:
            return CGPoint(x: 0.2, y: 0.15)
        }
    }

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
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)

        guard let cgImage = context.makeImage() else { return nil }
        let size = NSSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        let image = NSImage(cgImage: cgImage, size: size)

        let meta = loadSystemCursorMetadata(folder: folder)
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
        let size = NSSize(width: pixel, height: pixel)

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
            return NSImage(size: size)
        }

        context.clear(CGRect(origin: .zero, size: CGSize(width: pixel, height: pixel)))
        // Draw in top-left friendly space: flip so y grows downward for hotspot math,
        // then use bottom-left path coords consistent with prior arrow geometry.
        context.translateBy(x: 0, y: pixel)
        context.scaleBy(x: scale, y: -scale)

        switch style {
        case .macArrow:
            // Official-looking white pointer with black outline + soft shadow.
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
            // Fallback if a system PDF is missing on this OS version.
            drawMacArrow(in: context, fill: .white, stroke: .black, lineWidth: 1.15, shadow: true)
        }

        guard let cgImage = context.makeImage() else {
            return NSImage(size: size)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: base, height: base))
    }

    /// Accurate macOS-style arrow (point-size 32 box, tip near top-left).
    private static func drawMacArrow(
        in context: CGContext,
        fill: NSColor,
        stroke: NSColor,
        lineWidth: CGFloat,
        shadow: Bool
    ) {
        // Coordinates use bottom-left origin after the flip in renderDrawnCursor.
        // Tip ~ (5, 28) which is top of the 32pt box.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 28))
        path.addLine(to: CGPoint(x: 5, y: 7))
        path.addLine(to: CGPoint(x: 10.5, y: 12.5))
        path.addLine(to: CGPoint(x: 15.5, y: 3.5))
        path.addLine(to: CGPoint(x: 18.2, y: 4.8))
        path.addLine(to: CGPoint(x: 13.2, y: 13.8))
        path.addLine(to: CGPoint(x: 21.5, y: 13.8))
        path.closeSubpath()

        if shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -1),
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
        path.move(to: CGPoint(x: 5, y: 27))
        path.addLine(to: CGPoint(x: 5, y: 7))
        path.addQuadCurve(to: CGPoint(x: 11, y: 12), control: CGPoint(x: 7, y: 9))
        path.addLine(to: CGPoint(x: 16, y: 4))
        path.addQuadCurve(to: CGPoint(x: 19, y: 6), control: CGPoint(x: 18, y: 4))
        path.addLine(to: CGPoint(x: 13.5, y: 13.5))
        path.addQuadCurve(to: CGPoint(x: 22, y: 14), control: CGPoint(x: 18, y: 13))
        path.addQuadCurve(to: CGPoint(x: 5, y: 27), control: CGPoint(x: 14, y: 22))
        path.closeSubpath()

        context.setShadow(
            offset: CGSize(width: 0, height: -1),
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
            offset: CGSize(width: 0, height: -1),
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
