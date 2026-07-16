//
//  AutoZoomEngine.swift
//  viewio
//
//  State-of-the-art auto zoom for screen recordings.
//
//  Inspired by Screen Studio / cinematic tutorial tools:
//  1. Clicks (and optional dwells) are interest points
//  2. Nearby-in-time and nearby-on-screen points form one "focus scene"
//  3. Each scene becomes one zoom window (pre-roll + hold + post-hold)
//  4. Scenes that would leave only a tiny unzoomed gap are merged so the
//     camera never rapidly zooms out and back in
//

import CoreGraphics
import Foundation

enum AutoZoomEngine {
    // MARK: - Tunables

    /// How early to ease in before the first action in a scene.
    private static let preRoll: Double = 0.65
    /// How long to hold after the last action in a scene.
    private static let postHold: Double = 1.25
    /// Max time between consecutive clicks still considered one scene.
    private static let clusterTimeGap: Double = 2.2
    /// Max normalized screen distance for “same region” clustering.
    private static let clusterSpatialRadius: Double = 0.28
    /// Max time gap when clustering by space alone (looser).
    private static let clusterSpatialTimeGap: Double = 3.5
    /// Minimum unzoomed gap between two zooms (must fit exit + breath + entry).
    /// Below this, ranges merge so we never flash full-frame between zooms.
    private static let minUnzoomedGap: Double = 1.75
    /// Shortest allowed zoom block.
    private static let minZoomLength: Double = 1.4
    /// Longest single continuous zoom (still allows long merged scenes).
    private static let maxZoomLength: Double = 10.0
    /// Minimum pause length to count as a dwell interest point.
    private static let minDwellSeconds: Double = 0.55
    private static let maxZooms = 20

    // MARK: - Public

    /// Build cinematic, non-janky zoom ranges from cursor + click tracks.
    static func generate(
        duration: Double,
        cursorTrack: [CursorPosition],
        clickEvents: [ClickEvent]
    ) -> [ZoomRange] {
        guard duration > 0.5, !cursorTrack.isEmpty else { return [] }

        let interests = collectInterestPoints(
            duration: duration,
            cursorTrack: cursorTrack,
            clickEvents: clickEvents
        )
        guard !interests.isEmpty else { return [] }

        let clusters = clusterInterests(interests)
        var windows = clusters.compactMap { cluster -> ZoomRange? in
            makeZoomWindow(from: cluster, duration: duration)
        }

        windows = mergeTightGaps(windows, duration: duration)
        windows = windows
            .map { clampToTimeline($0, duration: duration) }
            .filter { $0.end - $0.start >= minZoomLength }

        // Final safety: never leave a sub-threshold gap.
        windows = mergeTightGaps(windows, duration: duration)

        return Array(windows.prefix(maxZooms))
    }

    // MARK: - Interest points

    private struct InterestPoint {
        var time: Double
        /// Normalized video space (origin top-left), matching zoom focus.
        var x: Double
        var y: Double
        var weight: Double
        var kind: Kind

        enum Kind {
            case click
            case dwell
        }
    }

    private static func collectInterestPoints(
        duration: Double,
        cursorTrack: [CursorPosition],
        clickEvents: [ClickEvent]
    ) -> [InterestPoint] {
        var points: [InterestPoint] = []

        for click in clickEvents {
            guard click.time >= 0, click.time <= duration else { continue }
            let pos = videoPosition(at: click.time, in: cursorTrack)
            points.append(
                InterestPoint(
                    time: click.time,
                    x: pos.x,
                    y: pos.y,
                    weight: 1.0,
                    kind: .click
                )
            )
        }

        // Dwells only fill sparse timelines (few clicks).
        if points.count < 2 {
            points.append(contentsOf: dwellInterestPoints(
                duration: duration,
                cursorTrack: cursorTrack
            ))
        }

        return points.sorted { $0.time < $1.time }
    }

    private static func dwellInterestPoints(
        duration: Double,
        cursorTrack: [CursorPosition]
    ) -> [InterestPoint] {
        guard cursorTrack.count >= 3 else { return [] }

        let velocityThreshold = 0.18
        var points: [InterestPoint] = []
        var pauseStart: Double?

        for index in 0..<(cursorTrack.count - 1) {
            let current = cursorTrack[index]
            let next = cursorTrack[index + 1]
            let dx = next.x - current.x
            let dy = next.y - current.y
            let dt = max(0.001, next.time - current.time)
            let velocity = sqrt(dx * dx + dy * dy) / dt

            if velocity < velocityThreshold {
                if pauseStart == nil { pauseStart = current.time }
            } else if let start = pauseStart {
                let end = current.time
                if end - start >= minDwellSeconds {
                    let mid = (start + end) / 2
                    let pos = videoPosition(at: mid, in: cursorTrack)
                    points.append(
                        InterestPoint(
                            time: mid,
                            x: pos.x,
                            y: pos.y,
                            weight: 0.55,
                            kind: .dwell
                        )
                    )
                }
                pauseStart = nil
            }
        }

        if let start = pauseStart, let last = cursorTrack.last {
            let end = last.time
            if end - start >= minDwellSeconds {
                let mid = (start + end) / 2
                let pos = videoPosition(at: mid, in: cursorTrack)
                points.append(
                    InterestPoint(
                        time: mid,
                        x: pos.x,
                        y: pos.y,
                        weight: 0.55,
                        kind: .dwell
                    )
                )
            }
        }

        return points
    }

    // MARK: - Clustering

    private static func clusterInterests(_ points: [InterestPoint]) -> [[InterestPoint]] {
        guard !points.isEmpty else { return [] }

        var clusters: [[InterestPoint]] = [[points[0]]]

        for point in points.dropFirst() {
            guard var last = clusters.last, let anchor = last.last else {
                clusters.append([point])
                continue
            }

            let dt = point.time - anchor.time
            let dist = hypot(point.x - anchor.x, point.y - anchor.y)

            // Same scene if close in time, or nearby on screen within a looser window.
            let sameScene =
                dt <= clusterTimeGap
                || (dist <= clusterSpatialRadius && dt <= clusterSpatialTimeGap)

            // Also keep chain: if point is near the scene centroid and within spatial time.
            let centroid = sceneCentroid(last)
            let distToScene = hypot(point.x - centroid.x, point.y - centroid.y)
            let nearScene = distToScene <= clusterSpatialRadius * 1.15 && dt <= clusterSpatialTimeGap

            if sameScene || nearScene {
                last.append(point)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([point])
            }
        }

        return clusters
    }

    private static func sceneCentroid(_ points: [InterestPoint]) -> (x: Double, y: Double) {
        let totalWeight = points.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return (0.5, 0.5) }
        let x = points.reduce(0.0) { $0 + $1.x * $1.weight } / totalWeight
        let y = points.reduce(0.0) { $0 + $1.y * $1.weight } / totalWeight
        return (x, y)
    }

    // MARK: - Windows

    private static func makeZoomWindow(from cluster: [InterestPoint], duration: Double) -> ZoomRange? {
        guard let first = cluster.first, let last = cluster.last else { return nil }

        var start = max(0, first.time - preRoll)
        var end = min(duration, last.time + postHold)

        // Guarantee room for smooth entry/exit.
        if end - start < minZoomLength {
            let mid = (first.time + last.time) / 2
            start = max(0, mid - minZoomLength / 2)
            end = min(duration, start + minZoomLength)
            start = max(0, end - minZoomLength)
        }

        // Soft cap extreme length while preserving center of activity.
        if end - start > maxZoomLength {
            let mid = (first.time + last.time) / 2
            start = max(0, mid - maxZoomLength / 2)
            end = min(duration, start + maxZoomLength)
        }

        let amount = zoomAmount(for: cluster)
        return ZoomRange(
            start: start,
            end: end,
            amount: amount,
            entryAnimation: .smooth,
            exitAnimation: .smooth
        )
    }

    private static func zoomAmount(for cluster: [InterestPoint]) -> Double {
        guard cluster.count >= 2 else {
            return cluster.first?.kind == .click ? 1.85 : 1.55
        }

        let xs = cluster.map(\.x)
        let ys = cluster.map(\.y)
        let spread = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        // Tight UI work → stronger zoom; wide multi-panel work → gentler.
        let tightness = 1 - min(1, spread / 0.45)
        let clickBoost = cluster.contains(where: { $0.kind == .click }) ? 0.1 : 0
        return min(2.15, max(1.4, 1.45 + tightness * 0.65 + clickBoost))
    }

    // MARK: - Temporal merge (the key anti-jank step)

    /// Merge consecutive zooms when the unzoomed gap is too short for a clean
    /// full-frame beat between them.
    private static func mergeTightGaps(_ ranges: [ZoomRange], duration: Double) -> [ZoomRange] {
        guard !ranges.isEmpty else { return [] }

        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [ZoomRange] = [sorted[0]]

        for range in sorted.dropFirst() {
            var previous = merged[merged.count - 1]
            let gap = range.start - previous.end

            // Overlap or tiny gap → one continuous camera move.
            if gap < minUnzoomedGap {
                previous.end = max(previous.end, range.end)
                previous.amount = max(previous.amount, range.amount)
                // Prefer smooth on long merged scenes.
                previous.entryAnimation = .smooth
                previous.exitAnimation = .smooth
                merged[merged.count - 1] = previous
            } else {
                merged.append(range)
            }
        }

        // Second pass after length clamp can re-introduce tight gaps.
        return merged.map { clampToTimeline($0, duration: duration) }
    }

    private static func clampToTimeline(_ range: ZoomRange, duration: Double) -> ZoomRange {
        var start = min(max(0, range.start), max(0, duration - 0.25))
        var end = min(duration, max(start + 0.25, range.end))
        if end - start < minZoomLength {
            end = min(duration, start + minZoomLength)
            start = max(0, end - minZoomLength)
        }
        return ZoomRange(
            id: range.id,
            start: start,
            end: end,
            amount: range.amount,
            entryAnimation: range.entryAnimation,
            exitAnimation: range.exitAnimation
        )
    }

    // MARK: - Cursor helpers

    /// Cursor track is Cocoa bottom-left normalized; convert to video top-left.
    private static func videoPosition(at time: Double, in track: [CursorPosition]) -> (x: Double, y: Double) {
        guard !track.isEmpty else { return (0.5, 0.5) }

        let sample: CursorPosition
        if let index = track.firstIndex(where: { $0.time >= time }) {
            if index == 0 {
                sample = track[0]
            } else {
                let previous = track[index - 1]
                let next = track[index]
                let t = (time - previous.time) / max(0.001, next.time - previous.time)
                sample = CursorPosition(
                    time: time,
                    x: previous.x + (next.x - previous.x) * t,
                    y: previous.y + (next.y - previous.y) * t
                )
            }
        } else if let last = track.last {
            sample = last
        } else {
            return (0.5, 0.5)
        }

        return (
            min(1, max(0, sample.x)),
            min(1, max(0, 1 - sample.y))
        )
    }
}
