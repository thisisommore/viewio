//
//  MotionBlurSettings.swift
//  viewio
//
//  Post-edit motion blur for cursor trails and zoom camera moves.
//

import CoreGraphics
import Foundation

struct MotionBlurSettings: Codable, Equatable {
    /// Master switch.
    var isEnabled: Bool = false
    /// 0 = none, 1 = strong smear.
    var amount: Double = 0.05
    var applyToCursor: Bool = true
    var applyToZoom: Bool = true

    static let `default` = MotionBlurSettings()

    var clampedAmount: Double {
        min(1, max(0, amount))
    }

    /// Effective strength for cursor trails (0 when off).
    var cursorStrength: Double {
        guard isEnabled, applyToCursor else { return 0 }
        return clampedAmount
    }

    /// Effective strength for zoom/pan blur (0 when off).
    var zoomStrength: Double {
        guard isEnabled, applyToZoom else { return 0 }
        return clampedAmount
    }

    /// How far back in time (seconds) to sample the cursor trail.
    var cursorTrailDuration: Double {
        0.02 + cursorStrength * 0.10
    }

    /// Ghost samples along the trail (including the live cursor).
    var cursorTrailSamples: Int {
        guard cursorStrength > 0.001 else { return 1 }
        return min(14, max(3, Int(3 + cursorStrength * 11)))
    }
}

// MARK: - Shared math for trails

enum MotionBlurMath {
    /// Positions for a fading trail ending at `time` (index 0 = live tip).
    static func trailTimes(at time: Double, settings: MotionBlurSettings) -> [(time: Double, opacity: Double)] {
        let strength = settings.cursorStrength
        guard strength > 0.001 else {
            return [(time, 1)]
        }

        let count = settings.cursorTrailSamples
        let lookback = settings.cursorTrailDuration
        var samples: [(Double, Double)] = []
        samples.reserveCapacity(count)

        for index in 0..<count {
            let fraction = Double(index) / Double(max(1, count - 1))
            let sampleTime = max(0, time - lookback * fraction)
            // Head is solid; tail fades with strength.
            let opacity = index == 0
                ? 1.0
                : strength * 0.55 * (1 - fraction)
            if opacity > 0.02 {
                samples.append((sampleTime, opacity))
            }
        }
        return samples
    }
}
