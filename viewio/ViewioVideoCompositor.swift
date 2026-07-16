//
//  ViewioVideoCompositor.swift
//  viewio
//
//  Custom compositor that applies zoom transforms and optional motion blur
//  for camera moves (export + preview).
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation

// MARK: - Instruction

/// Carries per-frame zoom + motion-blur parameters into the compositor.
final class ViewioCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let sourceTrackID: CMPersistentTrackID
    let renderSize: CGSize
    /// Sampled transforms over the timeline (seconds → transform in render space).
    let keyframes: [ZoomTransformSample]
    /// 0...1 zoom/pan motion blur strength.
    let motionBlurAmount: Double

    init(
        timeRange: CMTimeRange,
        sourceTrackID: CMPersistentTrackID,
        renderSize: CGSize,
        keyframes: [ZoomTransformSample],
        motionBlurAmount: Double
    ) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.renderSize = renderSize
        self.keyframes = keyframes
        self.motionBlurAmount = min(1, max(0, motionBlurAmount))
        self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        super.init()
    }

    func sample(at seconds: Double) -> ZoomTransformSample {
        ZoomTransformSample.interpolate(at: seconds, in: keyframes)
    }
}

struct ZoomTransformSample: Sendable {
    var time: Double
    var transform: CGAffineTransform
    /// Normalized focus used for zoom blur center (0...1).
    var focus: CGPoint
    var scale: CGFloat

    static func interpolate(at time: Double, in samples: [ZoomTransformSample]) -> ZoomTransformSample {
        guard let first = samples.first else {
            return ZoomTransformSample(time: time, transform: .identity, focus: CGPoint(x: 0.5, y: 0.5), scale: 1)
        }
        guard let last = samples.last else { return first }
        if time <= first.time { return first }
        if time >= last.time { return last }

        guard let index = samples.firstIndex(where: { $0.time >= time }), index > 0 else {
            return last
        }
        let next = samples[index]
        let previous = samples[index - 1]
        let span = max(0.0001, next.time - previous.time)
        let t = CGFloat((time - previous.time) / span)
        return ZoomTransformSample(
            time: time,
            transform: interpolate(previous.transform, next.transform, t: t),
            focus: CGPoint(
                x: previous.focus.x + (next.focus.x - previous.focus.x) * Double(t),
                y: previous.focus.y + (next.focus.y - previous.focus.y) * Double(t)
            ),
            scale: previous.scale + (next.scale - previous.scale) * t
        )
    }

    private static func interpolate(_ a: CGAffineTransform, _ b: CGAffineTransform, t: CGFloat) -> CGAffineTransform {
        CGAffineTransform(
            a: a.a + (b.a - a.a) * t,
            b: a.b + (b.b - a.b) * t,
            c: a.c + (b.c - a.c) * t,
            d: a.d + (b.d - a.d) * t,
            tx: a.tx + (b.tx - a.tx) * t,
            ty: a.ty + (b.ty - a.ty) * t
        )
    }
}

// MARK: - Compositor

final class ViewioVideoCompositor: NSObject, AVVideoCompositing {
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferOpenGLCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferOpenGLCompatibilityKey as String: true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? ViewioCompositionInstruction else {
                request.finish(with: CompositorError.badInstruction)
                return
            }

            guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.sourceTrackID) else {
                request.finish(with: CompositorError.missingFrame)
                return
            }

            guard let outputBuffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: CompositorError.noOutputBuffer)
                return
            }

            let seconds = request.compositionTime.seconds
            let sample = instruction.sample(at: seconds)
            var image = CIImage(cvPixelBuffer: sourceBuffer)
            let render = instruction.renderSize

            // AVVideoComposition transforms use a top-left origin; Core Image is
            // bottom-left — convert before applying the zoom matrix.
            let ciTransform = avTransformToCI(sample.transform, height: render.height)
            image = image.transformed(by: ciTransform)

            // Fill letterbox and crop to the output frame.
            let canvas = CIImage(color: .black).cropped(
                to: CGRect(origin: .zero, size: render)
            )
            image = image.composited(over: canvas).cropped(
                to: CGRect(origin: .zero, size: render)
            )

            let blurAmount = instruction.motionBlurAmount
            if blurAmount > 0.001 {
                image = applyMotionBlur(
                    to: image,
                    at: seconds,
                    instruction: instruction,
                    amount: blurAmount,
                    renderSize: render
                )
            }

            renderContext.render(
                image,
                to: outputBuffer,
                bounds: CGRect(origin: .zero, size: render),
                colorSpace: colorSpace
            )
            request.finish(withComposedVideoFrame: outputBuffer)
        }
    }

    private func applyMotionBlur(
        to image: CIImage,
        at time: Double,
        instruction: ViewioCompositionInstruction,
        amount: Double,
        renderSize: CGSize
    ) -> CIImage {
        let dt = 1.0 / 60.0
        let previous = instruction.sample(at: max(0, time - dt))
        let current = instruction.sample(at: time)

        // Track how the frame center moves in screen space.
        let mid = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
        let p0 = mid.applying(previous.transform)
        let p1 = mid.applying(current.transform)
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let panSpeed = hypot(dx, dy)
        let scaleDelta = abs(Double(current.scale - previous.scale))

        var result = image

        // Directional smear for pans / focus moves.
        if panSpeed > 0.35 {
            let radius = min(48, panSpeed * amount * 1.15)
            if radius > 0.4 {
                let angle = atan2(Double(dy), Double(dx))
                result = result.applyingFilter(
                    "CIMotionBlur",
                    parameters: [
                        kCIInputRadiusKey: radius,
                        kCIInputAngleKey: angle
                    ]
                )
            }
        }

        // Radial smear when zoom scale is changing.
        if scaleDelta > 0.002 {
            let zoomRadius = min(28, scaleDelta * 400 * amount)
            if zoomRadius > 0.35 {
                let center = CIVector(
                    x: current.focus.x * renderSize.width,
                    y: (1 - current.focus.y) * renderSize.height
                )
                result = result.applyingFilter(
                    "CIZoomBlur",
                    parameters: [
                        kCIInputCenterKey: center,
                        kCIInputAmountKey: zoomRadius
                    ]
                )
            }
        }

        return result.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// Convert an AVFoundation (top-left) affine transform into Core Image space.
    private func avTransformToCI(_ transform: CGAffineTransform, height: CGFloat) -> CGAffineTransform {
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        return flip.concatenating(transform).concatenating(flip)
    }

    private enum CompositorError: LocalizedError {
        case badInstruction
        case missingFrame
        case noOutputBuffer

        var errorDescription: String? {
            switch self {
            case .badInstruction: "Invalid composition instruction."
            case .missingFrame: "Missing source video frame."
            case .noOutputBuffer: "Could not allocate output frame."
            }
        }
    }
}
