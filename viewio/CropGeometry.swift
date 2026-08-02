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

    /// Maps a screen region (Cocoa global, bottom-left origin) into a
    /// normalized video crop (0...1, top-left origin) relative to a display
    /// frame in the same Cocoa space. Used so pre-record region selection
    /// becomes an editable soft crop on a full-frame recording.
    static func cropRect(region: CGRect, withinDisplay display: CGRect) -> CGRect? {
        guard display.width > 1, display.height > 1,
              region.width > 1, region.height > 1 else { return nil }
        let clampedRegion = region.intersection(display)
        guard clampedRegion.width > 1, clampedRegion.height > 1 else { return nil }
        let x = (clampedRegion.minX - display.minX) / display.width
        // Cocoa Y increases upward; video crop Y increases downward from top.
        let y = (display.maxY - clampedRegion.maxY) / display.height
        let w = clampedRegion.width / display.width
        let h = clampedRegion.height / display.height
        let rect = clamped(CGRect(x: x, y: y, width: w, height: h))
        // Essentially the full frame — no soft crop needed.
        if rect.minX <= 0.005, rect.minY <= 0.005,
           rect.width >= 0.99, rect.height >= 0.99 {
            return nil
        }
        return rect
    }
}
