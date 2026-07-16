//
//  CursorOverlayBuilder.swift
//  viewio
//
//  Builds a Core Animation tree that redraws the cursor from tracked samples
//  (post-record), including motion styles and click effects.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

enum CursorOverlayBuilder {
    /// Attach a cursor overlay to the video composition when custom cursor is on
    /// and track data is available.
    static func apply(
        to videoComposition: AVMutableVideoComposition,
        settings: CursorSettings,
        processedTrack: [CursorPosition],
        clickEvents: [ClickEvent],
        renderSize: CGSize,
        duration: Double,
        displayPosition: @escaping (Double) -> CGPoint
    ) {
        guard settings.isEnabled, !processedTrack.isEmpty, duration > 0 else { return }
        guard let cursorCGImage = CursorArtwork.cgImage(style: settings.style) else { return }

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds

        let cursorSize = 32 * CGFloat(settings.size)
        let hotspot = CursorArtwork.hotspot(for: settings.style)
        let cursorLayer = CALayer()
        cursorLayer.contents = cursorCGImage
        cursorLayer.contentsGravity = .resizeAspect
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: cursorSize, height: cursorSize)
        cursorLayer.anchorPoint = hotspot
        cursorLayer.zPosition = 10

        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(cursorLayer)

        addPositionAnimation(
            to: cursorLayer,
            duration: duration,
            displayPosition: displayPosition
        )

        if settings.clickEffect != .none, !clickEvents.isEmpty {
            addClickEffects(
                to: parentLayer,
                effect: settings.clickEffect,
                clicks: clickEvents,
                duration: duration,
                cursorSize: cursorSize,
                displayPosition: displayPosition
            )
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    // MARK: - Position

    private static func addPositionAnimation(
        to layer: CALayer,
        duration: Double,
        displayPosition: @escaping (Double) -> CGPoint
    ) {
        let sampleRate = 60.0
        let step = 1.0 / sampleRate
        var times: [NSNumber] = []
        var values: [CGPoint] = []
        times.reserveCapacity(Int(duration * sampleRate) + 2)
        values.reserveCapacity(Int(duration * sampleRate) + 2)

        var t = 0.0
        while t <= duration {
            times.append(NSNumber(value: t / duration))
            values.append(displayPosition(t))
            t += step
        }
        if times.last?.doubleValue != 1 {
            times.append(1)
            values.append(displayPosition(duration))
        }

        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = values.map { NSValue(point: $0) }
        animation.keyTimes = times
        animation.duration = duration
        animation.calculationMode = .linear
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        layer.add(animation, forKey: "cursorPosition")

        if let first = values.first {
            layer.position = first
        }
    }

    // MARK: - Clicks

    private static func addClickEffects(
        to parent: CALayer,
        effect: CursorClickEffect,
        clicks: [ClickEvent],
        duration: Double,
        cursorSize: CGFloat,
        displayPosition: @escaping (Double) -> CGPoint
    ) {
        for click in clicks {
            guard click.time >= 0, click.time <= duration else { continue }
            let origin = displayPosition(click.time)
            let ring = CAShapeLayer()
            let baseRadius = max(10, cursorSize * 0.55)
            ring.path = CGPath(
                ellipseIn: CGRect(x: -baseRadius, y: -baseRadius, width: baseRadius * 2, height: baseRadius * 2),
                transform: nil
            )
            ring.position = origin
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = clickStrokeColor(for: effect).cgColor
            ring.lineWidth = effect == .ring ? 2.5 : 2
            ring.opacity = 0
            ring.zPosition = 9
            parent.addSublayer(ring)

            let effectDuration: CFTimeInterval = effect == .pulse ? 0.28 : 0.45
            let begin = AVCoreAnimationBeginTimeAtZero + click.time

            switch effect {
            case .none:
                break
            case .ripple, .ring:
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.35
                scale.toValue = effect == .ring ? 2.2 : 2.6
                scale.duration = effectDuration
                scale.beginTime = begin
                scale.fillMode = .forwards
                scale.isRemovedOnCompletion = false
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [0, 0.85, 0]
                opacity.keyTimes = [0, 0.15, 1]
                opacity.duration = effectDuration
                opacity.beginTime = begin
                opacity.fillMode = .forwards
                opacity.isRemovedOnCompletion = false

                ring.add(scale, forKey: "scale")
                ring.add(opacity, forKey: "opacity")

            case .pulse:
                ring.fillColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
                ring.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [0.7, 1.25, 1]
                scale.keyTimes = [0, 0.45, 1]
                scale.duration = effectDuration
                scale.beginTime = begin
                scale.fillMode = .forwards
                scale.isRemovedOnCompletion = false

                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [0, 0.9, 0]
                opacity.keyTimes = [0, 0.2, 1]
                opacity.duration = effectDuration
                opacity.beginTime = begin
                opacity.fillMode = .forwards
                opacity.isRemovedOnCompletion = false

                ring.add(scale, forKey: "scale")
                ring.add(opacity, forKey: "opacity")
            }
        }
    }

    private static func clickStrokeColor(for effect: CursorClickEffect) -> NSColor {
        switch effect {
        case .none: .clear
        case .ripple: NSColor.systemBlue.withAlphaComponent(0.85)
        case .ring: NSColor.white.withAlphaComponent(0.9)
        case .pulse: NSColor.systemBlue
        }
    }
}
