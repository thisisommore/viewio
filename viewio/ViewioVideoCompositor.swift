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
        cornerRadius: CGFloat = 28
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
