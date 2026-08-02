//
//  CropGeometry.swift
//  viewio
//
//  Shared math for the project-wide frame crop: normalized rect clamping,
//  pixel mapping, and remapping normalized points (cursor, zoom focus)
//  between full-frame and crop space. All rects/points are normalized
//  0...1 with a top-left origin, relative to the oriented source video.
//

import CoreGraphics

enum CropGeometry {
    /// Smallest crop edge as a fraction of the source frame.
    static let minimumFraction: CGFloat = 0.05

    /// Clamps a normalized crop rect to the unit square with a minimum size.
    static func clamped(_ rect: CGRect) -> CGRect {
        let width = min(1, max(minimumFraction, rect.width))
        let height = min(1, max(minimumFraction, rect.height))
        let x = min(1 - width, max(0, rect.minX))
        let y = min(1 - height, max(0, rect.minY))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Crop rect in source pixels with an even-rounded size (odd/fractional
    /// sizes trip the VRP and most codecs), minimum 2×2.
    static func pixelRect(for normalized: CGRect, in sourceSize: CGSize) -> CGRect {
        let rawWidth = normalized.width * sourceSize.width
        let rawHeight = normalized.height * sourceSize.height
        let width = min(sourceSize.width, max(2, (rawWidth / 2).rounded(.down) * 2))
        let height = min(sourceSize.height, max(2, (rawHeight / 2).rounded(.down) * 2))
        return CGRect(
            x: normalized.minX * sourceSize.width,
            y: normalized.minY * sourceSize.height,
            width: width,
            height: height
        )
    }

    /// Largest rect with the given width/height aspect centered on `current`,
    /// clamped to the unit square.
    static func rect(aspect: CGFloat, centeredOn current: CGRect) -> CGRect {
        var height = min(1, current.height)
        var width = height * aspect
        if width > 1 {
            width = 1
            height = width / aspect
        }
        let centered = CGRect(
            x: current.midX - width / 2,
            y: current.midY - height / 2,
            width: width,
            height: height
        )
        return clamped(centered)
    }

    /// Maps a normalized full-frame point into crop space. Results inside
    /// 0...1 are within the crop; outside values mean the point is cropped away.
    static func remap(_ point: CGPoint, to crop: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - crop.minX) / crop.width,
            y: (point.y - crop.minY) / crop.height
        )
    }

    /// True when a normalized full-frame point lies inside the crop rect.
    static func contains(_ point: CGPoint, in crop: CGRect) -> Bool {
        point.x >= crop.minX && point.x <= crop.maxX
            && point.y >= crop.minY && point.y <= crop.maxY
    }
}
