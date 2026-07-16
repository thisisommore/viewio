//
//  CursorOverlayBuilder.swift
//  viewio
//
//  Builds a Core Animation tree that redraws the cursor from tracked samples
//  (post-record), including motion styles, click effects, and motion-blur trails.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

enum CursorOverlayBuilder {
    /// Attach a cursor overlay to the video composition when custom cursor is on
    /// and track data is available. Export-only (not valid on AVPlayerItem).
    static func apply(
        to videoComposition: AVMutableVideoComposition,
        settings: CursorSettings,
        motionBlur: MotionBlurSettings,
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

        parentLayer.addSublayer(videoLayer)

        // Motion-blur trail (ghosts), then solid head on top.
        let trail = MotionBlurMath.trailTimes(at: 0, settings: motionBlur)
        let ghostCount = max(0, trail.count - 1)
        var ghostLayers: [CALayer] = []
        if ghostCount > 0 {
            for _ in 0..<ghostCount {
                let ghost = makeCursorLayer(
                    image: cursorCGImage,
                    size: cursorSize,
                    hotspot: hotspot,
                    z: 9
                )
                ghost.opacity = 0
                parentLayer.addSublayer(ghost)
                ghostLayers.append(ghost)
            }
        }

        let cursorLayer = makeCursorLayer(
            image: cursorCGImage,
            size: cursorSize,
            hotspot: hotspot,
            z: 10
        )
        parentLayer.addSublayer(cursorLayer)

        addTrailAnimations(
            head: cursorLayer,
            ghosts: ghostLayers,
            duration: duration,
            motionBlur: motionBlur,
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

    private static func makeCursorLayer(
        image: CGImage,
        size: CGFloat,
        hotspot: CGPoint,
        z: CGFloat
    ) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.anchorPoint = hotspot
        layer.zPosition = z
        return layer
    }

    // MARK: - Trail / position

    private static func addTrailAnimations(
        head: CALayer,
        ghosts: [CALayer],
        duration: Double,
        motionBlur: MotionBlurSettings,
        displayPosition: @escaping (Double) -> CGPoint
    ) {
        let sampleRate = 60.0
        let step = 1.0 / sampleRate
        var times: [NSNumber] = []
        times.reserveCapacity(Int(duration * sampleRate) + 2)

        var headValues: [CGPoint] = []
        var ghostValues: [[CGPoint]] = Array(repeating: [], count: ghosts.count)
        var ghostOpacities: [[NSNumber]] = Array(repeating: [], count: ghosts.count)

        var t = 0.0
        while t <= duration {
            let keyTime = NSNumber(value: t / duration)
            times.append(keyTime)

            let trail = MotionBlurMath.trailTimes(at: t, settings: motionBlur)
            let headPoint = trail.first.map { displayPosition($0.time) } ?? displayPosition(t)
            headValues.append(headPoint)

            for ghostIndex in ghosts.indices {
                let sampleIndex = ghostIndex + 1
                if sampleIndex < trail.count {
                    let sample = trail[sampleIndex]
                    ghostValues[ghostIndex].append(displayPosition(sample.time))
                    ghostOpacities[ghostIndex].append(NSNumber(value: sample.opacity))
                } else {
                    ghostValues[ghostIndex].append(headPoint)
                    ghostOpacities[ghostIndex].append(0)
                }
            }

            t += step
        }

        if times.last?.doubleValue != 1 {
            times.append(1)
            let trail = MotionBlurMath.trailTimes(at: duration, settings: motionBlur)
            let headPoint = trail.first.map { displayPosition($0.time) } ?? displayPosition(duration)
            headValues.append(headPoint)
            for ghostIndex in ghosts.indices {
                let sampleIndex = ghostIndex + 1
                if sampleIndex < trail.count {
                    let sample = trail[sampleIndex]
                    ghostValues[ghostIndex].append(displayPosition(sample.time))
                    ghostOpacities[ghostIndex].append(NSNumber(value: sample.opacity))
                } else {
                    ghostValues[ghostIndex].append(headPoint)
                    ghostOpacities[ghostIndex].append(0)
                }
            }
        }

        addPositionAnimation(to: head, times: times, values: headValues, duration: duration)
        if let first = headValues.first {
            head.position = first
        }

        for (index, ghost) in ghosts.enumerated() {
            addPositionAnimation(to: ghost, times: times, values: ghostValues[index], duration: duration)
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = ghostOpacities[index]
            opacity.keyTimes = times
            opacity.duration = duration
            opacity.calculationMode = .linear
            opacity.fillMode = .forwards
            opacity.isRemovedOnCompletion = false
            opacity.beginTime = AVCoreAnimationBeginTimeAtZero
            ghost.add(opacity, forKey: "cursorOpacity")
            if let first = ghostValues[index].first {
                ghost.position = first
            }
            if let firstOpacity = ghostOpacities[index].first {
                ghost.opacity = firstOpacity.floatValue
            }
        }
    }

    private static func addPositionAnimation(
        to layer: CALayer,
        times: [NSNumber],
        values: [CGPoint],
        duration: Double
    ) {
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = values.map { NSValue(point: $0) }
        animation.keyTimes = times
        animation.duration = duration
        animation.calculationMode = .linear
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        layer.add(animation, forKey: "cursorPosition")
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
