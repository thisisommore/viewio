//
//  CameraOverlayModel.swift
//  viewio
//
//  Shared camera-corner model for recording preview and post-edit composition.
//

import CoreGraphics
import Foundation

enum CameraCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var systemImage: String {
        switch self {
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        }
    }
}

struct CameraSettings: Codable, Equatable {
    var isEnabled: Bool = true
    var corner: CameraCorner = .bottomRight
    var size: Double = 0.22

    static let `default` = CameraSettings()

    var clampedSize: Double {
        min(0.45, max(0.08, size))
    }
}

enum CameraOverlayGeometry {
    /// Size of the camera picture-in-picture as a fraction of the render width.
    static let defaultSize = 0.22
    /// Padding between the camera frame and the container edge, in pixels.
    static let padding: CGFloat = 16
    /// Corner radius of the camera frame.
    static let cornerRadius: CGFloat = 10

    /// Frame for the camera overlay in a given render size.
    /// Rounded to integer pixels — fractional values trip the video renderer.
    static func cameraFrame(
        in renderSize: CGSize,
        sizeFraction: Double,
        corner: CameraCorner,
        padding: CGFloat = CameraOverlayGeometry.padding
    ) -> CGRect {
        guard renderSize.width > 1, renderSize.height > 1 else { return .zero }
        let safeFraction = min(0.45, max(0.08, sizeFraction))
        let width = (renderSize.width * CGFloat(safeFraction)).rounded()
        let height = (width * (9.0 / 16.0)).rounded()
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft:
            x = padding.rounded()
            y = padding.rounded()
        case .topRight:
            x = (renderSize.width - width - padding).rounded()
            y = padding.rounded()
        case .bottomLeft:
            x = padding.rounded()
            y = (renderSize.height - height - padding).rounded()
        case .bottomRight:
            x = (renderSize.width - width - padding).rounded()
            y = (renderSize.height - height - padding).rounded()
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Snap a dragged frame to the nearest corner.
    static func snappedCorner(
        for frame: CGRect,
        in containerSize: CGSize
    ) -> CameraCorner {
        let midX = frame.midX
        let midY = frame.midY
        if midX < containerSize.width / 2 {
            return midY < containerSize.height / 2 ? .topLeft : .bottomLeft
        } else {
            return midY < containerSize.height / 2 ? .topRight : .bottomRight
        }
    }

    /// Frame for the camera overlay in Core Image / bottom-left origin coordinates.
    static func cameraFrameInCI(
        in renderSize: CGSize,
        sizeFraction: Double,
        corner: CameraCorner
    ) -> CGRect {
        let avFrame = cameraFrame(in: renderSize, sizeFraction: sizeFraction, corner: corner)
        return CGRect(
            x: avFrame.origin.x,
            y: renderSize.height - avFrame.maxY,
            width: avFrame.width,
            height: avFrame.height
        )
    }

    /// Affine transform that places the camera video into the selected corner
    /// of the render frame. The video is scaled uniformly to fill the target
    /// frame and centered (cropping edges if the aspect ratios differ).
    /// Values are rounded to integer pixels to keep the video renderer happy.
    static func cameraTransform(
        cameraNaturalSize: CGSize,
        renderSize: CGSize,
        sizeFraction: Double,
        corner: CameraCorner
    ) -> CGAffineTransform {
        guard renderSize.width > 1, renderSize.height > 1,
              cameraNaturalSize.width > 1, cameraNaturalSize.height > 1 else {
            return .identity
        }
        let frame = cameraFrame(in: renderSize, sizeFraction: sizeFraction, corner: corner)
        return cameraTransform(cameraNaturalSize: cameraNaturalSize, targetFrame: frame)
    }

    /// Affine transform that maps the camera video into an explicit target frame.
    static func cameraTransform(
        cameraNaturalSize: CGSize,
        targetFrame: CGRect
    ) -> CGAffineTransform {
        guard targetFrame.width > 1, targetFrame.height > 1,
              cameraNaturalSize.width > 1, cameraNaturalSize.height > 1 else {
            return .identity
        }
        // Uniform scale to fill the target frame.
        let scaleX = targetFrame.width / cameraNaturalSize.width
        let scaleY = targetFrame.height / cameraNaturalSize.height
        let scale = max(scaleX, scaleY)
        // Center the scaled video inside the target frame.
        let scaledWidth = cameraNaturalSize.width * scale
        let scaledHeight = cameraNaturalSize.height * scale
        let offsetX = ((targetFrame.width - scaledWidth) / 2).rounded()
        let offsetY = ((targetFrame.height - scaledHeight) / 2).rounded()
        let tx = (targetFrame.origin.x + offsetX).rounded()
        let ty = (targetFrame.origin.y + offsetY).rounded()
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }
}
