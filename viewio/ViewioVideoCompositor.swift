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

/// Everything the compositor needs to draw the tracked cursor into the frame.
/// Plain data only — the compositor renders off the main thread.
struct CursorRenderData {
    let image: CGImage
    /// Hotspot as a fraction of the image size, origin top-left.
    let hotspot: CGPoint
    /// Cursor size in render pixels (matches the real cursor's on-screen size).
    let size: CGFloat
    /// Normalized track (0...1, top-left origin), precise — no smoothing.
    let track: [CursorPosition]
    let clickTimes: [Double]
    let clickEffect: CursorClickEffect
    /// 0 disables the ghost trail.
    let trailStrength: Double
    /// Seconds the trail looks back.
    let trailLookback: Double
    /// Ghost copies behind the live head.
    let trailGhosts: Int
}

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
    /// Optional camera track to composite as picture-in-picture.
    let cameraTrackID: CMPersistentTrackID?
    /// AVFoundation transform (top-left origin) that places the camera frame.
    let cameraTransform: CGAffineTransform?
    /// Local file URL of a static image to draw behind the source video.
    let backgroundImageURL: URL?
    /// When true, mask the source video with rounded corners so window captures
    /// don't show black corners over the wallpaper background.
    let applyRoundedCorners: Bool
    /// Radius (in source image pixels) of the rounded-corner mask.
    let cornerRadius: CGFloat
    /// Tracked cursor to draw into the frame (export only; nil for live preview).
    let cursor: CursorRenderData?

    init(
        timeRange: CMTimeRange,
        sourceTrackID: CMPersistentTrackID,
        renderSize: CGSize,
        keyframes: [ZoomTransformSample],
        motionBlurAmount: Double,
        cameraTrackID: CMPersistentTrackID? = nil,
        cameraTransform: CGAffineTransform? = nil,
        backgroundImageURL: URL? = nil,
        applyRoundedCorners: Bool = false,
        cornerRadius: CGFloat = 28,
        cursor: CursorRenderData? = nil
    ) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.renderSize = renderSize
        self.keyframes = keyframes
        self.motionBlurAmount = min(1, max(0, motionBlurAmount))
        self.cameraTrackID = cameraTrackID
        self.cameraTransform = cameraTransform
        self.backgroundImageURL = backgroundImageURL
        self.applyRoundedCorners = applyRoundedCorners
        self.cornerRadius = max(0, cornerRadius)
        self.cursor = cursor
        var required: [NSValue] = [NSNumber(value: sourceTrackID)]
        if let cameraTrackID {
            required.append(NSNumber(value: cameraTrackID))
        }
        self.requiredSourceTrackIDs = required
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
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_32BGRA,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ],
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
            print("CamDebug compositor startRequest time=\(request.compositionTime.seconds), sourceTrackIDs=\(request.sourceTrackIDs)")
            guard let instruction = request.videoCompositionInstruction as? ViewioCompositionInstruction else {
                print("CamDebug compositor bad instruction")
                request.finish(with: CompositorError.badInstruction)
                return
            }

            guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.sourceTrackID) else {
                print("CamDebug compositor missing source frame for track \(instruction.sourceTrackID)")
                request.finish(with: CompositorError.missingFrame)
                return
            }
            print("CamDebug compositor got screen buffer \(CVPixelBufferGetWidth(sourceBuffer))x\(CVPixelBufferGetHeight(sourceBuffer))")

            guard let outputBuffer = request.renderContext.newPixelBuffer() else {
                print("CamDebug compositor failed to allocate output buffer")
                request.finish(with: CompositorError.noOutputBuffer)
                return
            }
            print("CamDebug compositor allocated output buffer")

            let seconds = request.compositionTime.seconds
            let sample = instruction.sample(at: seconds)
            var image = CIImage(cvPixelBuffer: sourceBuffer)
            let render = instruction.renderSize

            // Window captures have black pixels in the rounded corners of the
            // window frame. Mask them out at the source image size before the
            // placement/zoom transform so the corners track the actual window.
            if instruction.applyRoundedCorners {
                image = applyRoundedCorners(to: image, radius: instruction.cornerRadius)
            }

            // AVVideoComposition transforms use a top-left origin; Core Image is
            // bottom-left — convert before applying the zoom matrix.
            let ciTransform = avTransformToCI(sample.transform, height: render.height)
            image = image.transformed(by: ciTransform)

            // Fill the output frame with the selected wallpaper, or black.
            let canvas: CIImage
            if let backgroundURL = instruction.backgroundImageURL,
               let wallpaperImage = CIImage(contentsOf: backgroundURL) {
                let scaleX = render.width / wallpaperImage.extent.width
                let scaleY = render.height / wallpaperImage.extent.height
                let scale = max(scaleX, scaleY)
                let centered = CGAffineTransform(
                    a: scale,
                    b: 0,
                    c: 0,
                    d: scale,
                    tx: (render.width - wallpaperImage.extent.width * scale) / 2,
                    ty: (render.height - wallpaperImage.extent.height * scale) / 2
                )
                canvas = wallpaperImage
                    .transformed(by: centered)
                    .cropped(to: CGRect(origin: .zero, size: render))
            } else {
                canvas = CIImage(color: .black).cropped(
                    to: CGRect(origin: .zero, size: render)
                )
            }
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

            // Composite the camera picture-in-picture on top (if present).
            if let cameraTrackID = instruction.cameraTrackID,
               let cameraTransform = instruction.cameraTransform {
                if let cameraBuffer = request.sourceFrame(byTrackID: cameraTrackID) {
                    print("CamDebug compositor got camera buffer \(CVPixelBufferGetWidth(cameraBuffer))x\(CVPixelBufferGetHeight(cameraBuffer))")
                    var cameraImage = CIImage(cvPixelBuffer: cameraBuffer)
                    // The camera transform is already in Core Image bottom-left space.
                    cameraImage = cameraImage.transformed(by: cameraTransform)
                    image = cameraImage.composited(over: image).cropped(
                        to: CGRect(origin: .zero, size: render)
                    )
                } else {
                    print("CamDebug compositor missing camera frame for track \(cameraTrackID)")
                }
            }

            // Draw the tracked cursor last, on top of everything. The cursor is
            // baked here (not via AVVideoCompositionCoreAnimationTool) because
            // the animation tool is ignored when a custom compositor renders.
            if let cursor = instruction.cursor, !cursor.track.isEmpty {
                image = drawCursorOverlay(
                    image,
                    at: seconds,
                    data: cursor,
                    instruction: instruction,
                    renderSize: render
                )
            }

            renderContext.render(
                image,
                to: outputBuffer,
                bounds: CGRect(origin: .zero, size: render),
                colorSpace: colorSpace
            )
            print("CamDebug compositor rendered frame")
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

    // MARK: - Cursor overlay

    private var clickRingCache: [CursorClickEffect: CIImage] = [:]

    private func drawCursorOverlay(
        _ frame: CIImage,
        at time: Double,
        data: CursorRenderData,
        instruction: ViewioCompositionInstruction,
        renderSize: CGSize
    ) -> CIImage {
        let cursor = CIImage(cgImage: data.image)
        var result = frame

        // Ghost trail behind the live head (same timing as the old CA tool).
        if data.trailGhosts > 0 {
            for index in 1...data.trailGhosts {
                let fraction = Double(index) / Double(data.trailGhosts)
                let opacity = data.trailStrength * 0.55 * (1 - fraction)
                guard opacity > 0.02 else { continue }
                let ghostTime = max(0, time - data.trailLookback * fraction)
                let point = cursorFramePoint(at: ghostTime, data: data, instruction: instruction, renderSize: renderSize)
                let ghost = cursor.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
                ])
                result = place(cursor: ghost, hotspot: data.hotspot, size: data.size, at: point, over: result)
            }
        }

        // Live head — the hotspot lands exactly on the tracked point.
        let headPoint = cursorFramePoint(at: time, data: data, instruction: instruction, renderSize: renderSize)
        result = place(cursor: cursor, hotspot: data.hotspot, size: data.size, at: headPoint, over: result)

        if data.clickEffect != .none {
            result = drawClickEffects(over: result, at: time, data: data, instruction: instruction, renderSize: renderSize)
        }

        return result.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// Composites the cursor so its hotspot (top-left fraction) sits on `point`,
    /// which is in Core Image space (bottom-left origin).
    private func place(cursor: CIImage, hotspot: CGPoint, size: CGFloat, at point: CGPoint, over frame: CIImage) -> CIImage {
        let scale = size / max(cursor.extent.width, 1)
        let tx = point.x - hotspot.x * size
        let ty = point.y - (1 - hotspot.y) * size
        return cursor
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .composited(over: frame)
    }

    /// Tracked cursor position in CI frame space, applying the exact same
    /// zoom/placement transform as the video so the tip locks to the content.
    private func cursorFramePoint(
        at time: Double,
        data: CursorRenderData,
        instruction: ViewioCompositionInstruction,
        renderSize: CGSize
    ) -> CGPoint {
        let normalized = interpolateCursorTrack(data.track, at: time)
        let sourcePoint = CGPoint(
            x: normalized.x * renderSize.width,
            y: normalized.y * renderSize.height
        )
        let framePoint = sourcePoint.applying(instruction.sample(at: time).transform)
        // AVFoundation transforms are top-left origin; Core Image is bottom-left.
        return CGPoint(x: framePoint.x, y: renderSize.height - framePoint.y)
    }

    private func interpolateCursorTrack(_ track: [CursorPosition], at time: Double) -> CGPoint {
        guard let first = track.first else { return CGPoint(x: 0.5, y: 0.5) }
        guard let index = track.firstIndex(where: { $0.time >= time }) else {
            guard let last = track.last else { return CGPoint(x: first.x, y: first.y) }
            return CGPoint(x: last.x, y: last.y)
        }
        if index == 0 { return CGPoint(x: first.x, y: first.y) }
        let previous = track[index - 1]
        let next = track[index]
        let span = max(0.0001, next.time - previous.time)
        let t = min(1, max(0, (time - previous.time) / span))
        return CGPoint(
            x: previous.x + (next.x - previous.x) * t,
            y: previous.y + (next.y - previous.y) * t
        )
    }

    private func drawClickEffects(
        over frame: CIImage,
        at time: Double,
        data: CursorRenderData,
        instruction: ViewioCompositionInstruction,
        renderSize: CGSize
    ) -> CIImage {
        var result = frame
        let effectDuration = data.clickEffect == .pulse ? 0.28 : 0.45
        for clickTime in data.clickTimes {
            let progress = (time - clickTime) / effectDuration
            guard progress >= 0, progress <= 1,
                  let ring = clickRingImage(for: data.clickEffect) else { continue }

            let center = cursorFramePoint(at: clickTime, data: data, instruction: instruction, renderSize: renderSize)
            let baseRadius = max(10, data.size * 0.55)
            let (startScale, endScale): (Double, Double)
            switch data.clickEffect {
            case .ring: (startScale, endScale) = (0.35, 2.2)
            case .pulse: (startScale, endScale) = (0.7, 1.0)
            case .ripple: (startScale, endScale) = (0.35, 2.6)
            case .none: continue
            }
            let eased = 1 - pow(1 - progress, 2)
            let diameter = baseRadius * 2 * (startScale + (endScale - startScale) * eased)
            let opacity = progress < 0.15
                ? 0.85 * progress / 0.15
                : 0.85 * (1 - progress) / (1 - 0.15)

            let faded = ring.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
            ])
            let scale = diameter / max(faded.extent.width, 1)
            let placed = faded
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: center.x - diameter / 2, y: center.y - diameter / 2))
            result = placed.composited(over: result)
        }
        return result
    }

    private func clickRingImage(for effect: CursorClickEffect) -> CIImage? {
        if let cached = clickRingCache[effect] { return cached }
        let px: CGFloat = 64
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(px),
                height: Int(px),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: px, height: px))
        let rect = CGRect(x: 3, y: 3, width: px - 6, height: px - 6)
        // Approximate NSColor.systemBlue without importing AppKit.
        let systemBlue = CGColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        switch effect {
        case .ripple:
            context.setStrokeColor(systemBlue.copy(alpha: 0.85) ?? systemBlue)
            context.setLineWidth(2)
            context.strokeEllipse(in: rect)
        case .ring:
            context.setStrokeColor(white.copy(alpha: 0.9) ?? white)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: rect)
        case .pulse:
            context.setFillColor(systemBlue.copy(alpha: 0.25) ?? systemBlue)
            context.fillEllipse(in: rect)
            context.setStrokeColor(systemBlue.copy(alpha: 0.9) ?? systemBlue)
            context.setLineWidth(2)
            context.strokeEllipse(in: rect)
        case .none:
            return nil
        }

        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage)
        clickRingCache[effect] = image
        return image
    }

    /// Masks the source image to a rounded rectangle so window captures don't
    /// leave black corners over the background wallpaper.
    private func applyRoundedCorners(to image: CIImage, radius: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, radius > 0 else { return image }
        guard let mask = roundedRectMask(size: extent.size, radius: radius) else { return image }
        let clear = CIImage(color: .clear).cropped(to: extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: mask
        ])
    }

    private func roundedRectMask(size: CGSize, radius: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
        filter.setValue(CIVector(cgRect: CGRect(origin: .zero, size: size)), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: "inputColor")
        return filter.outputImage
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
