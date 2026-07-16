//
//  CursorSettings.swift
//  viewio
//
//  Post-record cursor style + motion. Track data is captured while recording;
//  the system cursor is hidden in the file so we can redraw it here.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Settings

struct CursorSettings: Equatable {
    var isEnabled: Bool = true
    var style: CursorStyle = .classic
    var motion: CursorMotionStyle = .smooth
    var size: Double = 1.0
    var clickEffect: CursorClickEffect = .ripple

    static let `default` = CursorSettings()
}

// MARK: - Style

enum CursorStyle: String, CaseIterable, Identifiable {
    case classic
    case modern
    case bold
    case soft
    case dot
    case hand
    case crosshair

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .modern: "Modern"
        case .bold: "Bold"
        case .soft: "Soft"
        case .dot: "Dot"
        case .hand: "Hand"
        case .crosshair: "Cross"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: "macOS arrow"
        case .modern: "Rounded tip"
        case .bold: "High contrast"
        case .soft: "Light outline"
        case .dot: "Minimal circle"
        case .hand: "Pointer hand"
        case .crosshair: "Precise aim"
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

    /// Extra ease when interpolating between samples.
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
            // Time-aware blend so sparse samples still settle.
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
    /// Hotspot as a fraction of image size (tip of the arrow).
    static func hotspot(for style: CursorStyle) -> CGPoint {
        switch style {
        case .classic, .modern, .bold, .soft:
            CGPoint(x: 0.18, y: 0.12)
        case .dot:
            CGPoint(x: 0.5, y: 0.5)
        case .hand:
            CGPoint(x: 0.35, y: 0.12)
        case .crosshair:
            CGPoint(x: 0.5, y: 0.5)
        }
    }

    static func image(style: CursorStyle, scale: CGFloat = 2) -> NSImage {
        let base: CGFloat = 32
        let size = NSSize(width: base * scale, height: base * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        context.scaleBy(x: scale, y: scale)

        switch style {
        case .classic:
            drawArrow(in: context, fill: .white, stroke: .black, lineWidth: 1.1, bold: false)
        case .modern:
            drawModernArrow(in: context)
        case .bold:
            drawArrow(in: context, fill: .white, stroke: .black, lineWidth: 1.6, bold: true)
        case .soft:
            drawArrow(in: context, fill: NSColor.white.withAlphaComponent(0.95), stroke: NSColor.black.withAlphaComponent(0.35), lineWidth: 0.9, bold: false)
        case .dot:
            drawDot(in: context)
        case .hand:
            drawHand(in: context)
        case .crosshair:
            drawCrosshair(in: context)
        }

        return image
    }

    static func cgImage(style: CursorStyle) -> CGImage? {
        let nsImage = image(style: style, scale: 2)
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: Drawing

    private static func drawArrow(
        in context: CGContext,
        fill: NSColor,
        stroke: NSColor,
        lineWidth: CGFloat,
        bold: Bool
    ) {
        let path = CGMutablePath()
        // Classic macOS-ish pointer tip at ~ (4, 28) in 32pt with bottom-left origin.
        path.move(to: CGPoint(x: 4, y: 28))
        path.addLine(to: CGPoint(x: 4, y: 6))
        path.addLine(to: CGPoint(x: 10, y: 12))
        path.addLine(to: CGPoint(x: 15, y: 3))
        path.addLine(to: CGPoint(x: 18, y: 4.5))
        path.addLine(to: CGPoint(x: 13, y: 13.5))
        path.addLine(to: CGPoint(x: 22, y: 13.5))
        path.closeSubpath()

        if bold {
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }

        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()

        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
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

        context.setFillColor(NSColor.white.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1.15)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private static func drawDot(in context: CGContext) {
        let rect = CGRect(x: 10, y: 10, width: 12, height: 12)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: rect.insetBy(dx: -0.5, dy: -0.5))
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.01).cgColor)
        context.fillEllipse(in: rect)
    }

    private static func drawHand(in context: CGContext) {
        // Simplified pointing hand.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10, y: 28))
        path.addLine(to: CGPoint(x: 10, y: 16))
        path.addLine(to: CGPoint(x: 7, y: 16))
        path.addLine(to: CGPoint(x: 7, y: 12))
        path.addLine(to: CGPoint(x: 10, y: 12))
        path.addLine(to: CGPoint(x: 10, y: 10))
        path.addLine(to: CGPoint(x: 13, y: 10))
        path.addLine(to: CGPoint(x: 13, y: 8))
        path.addLine(to: CGPoint(x: 16, y: 8))
        path.addLine(to: CGPoint(x: 16, y: 10))
        path.addLine(to: CGPoint(x: 19, y: 10))
        path.addLine(to: CGPoint(x: 19, y: 14))
        path.addLine(to: CGPoint(x: 22, y: 15))
        path.addLine(to: CGPoint(x: 22, y: 20))
        path.addLine(to: CGPoint(x: 18, y: 28))
        path.closeSubpath()

        context.setFillColor(NSColor.white.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1.1)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private static func drawCrosshair(in context: CGContext) {
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: 8, y: 8, width: 16, height: 16))
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(1.2)
        context.move(to: CGPoint(x: 16, y: 6))
        context.addLine(to: CGPoint(x: 16, y: 12))
        context.move(to: CGPoint(x: 16, y: 20))
        context.addLine(to: CGPoint(x: 16, y: 26))
        context.move(to: CGPoint(x: 6, y: 16))
        context.addLine(to: CGPoint(x: 12, y: 16))
        context.move(to: CGPoint(x: 20, y: 16))
        context.addLine(to: CGPoint(x: 26, y: 16))
        context.strokePath()
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fillEllipse(in: CGRect(x: 14.5, y: 14.5, width: 3, height: 3))
    }
}
