//
//  ExportSettings.swift
//  viewio
//
//  User-selected export format, resolution scale, and frame rate.
//

import Foundation

struct ExportSettings: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case mp4H264
        case mp4HEVC
        case movH264
        case gif

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .mp4H264: return "MP4 (H.264)"
            case .mp4HEVC: return "MP4 (HEVC)"
            case .movH264: return "MOV (H.264)"
            case .gif: return "GIF"
            }
        }

        var fileExtension: String {
            switch self {
            case .mp4H264, .mp4HEVC: return "mp4"
            case .movH264: return "mov"
            case .gif: return "gif"
            }
        }

        var isGIF: Bool { self == .gif }
    }

    enum ResolutionScale: Double, CaseIterable, Identifiable {
        case full = 1
        case threeQuarter = 0.75
        case half = 0.5
        case quarter = 0.25

        var id: Double { rawValue }

        var displayName: String {
            switch self {
            case .full: return "100%"
            case .threeQuarter: return "75%"
            case .half: return "50%"
            case .quarter: return "25%"
            }
        }
    }

    static let videoFrameRates = [60, 30, 24]
    static let gifFrameRates = [30, 15, 10]

    var format: Format = .mp4H264
    var scale: ResolutionScale = .full
    var frameRate: Int = 60

    var allowedFrameRates: [Int] {
        format.isGIF ? Self.gifFrameRates : Self.videoFrameRates
    }

    /// Snaps the frame rate to the closest allowed value for the format
    /// (e.g. 60 -> 30 when switching to GIF).
    mutating func coerceFrameRate() {
        let allowed = allowedFrameRates
        guard !allowed.contains(frameRate) else { return }
        frameRate = allowed.min(by: { abs($0 - frameRate) < abs($1 - frameRate) }) ?? allowed[0]
    }
}
