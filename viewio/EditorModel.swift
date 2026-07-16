//
//  EditorModel.swift
//  viewio
//

import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

struct EditClip: Identifiable, Equatable {
    let id: UUID
    var sourceStart: Double
    var sourceEnd: Double
    var speed: Double

    init(id: UUID = UUID(), sourceStart: Double, sourceEnd: Double, speed: Double = 1) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
    }

    var sourceDuration: Double {
        max(0, sourceEnd - sourceStart)
    }

    var outputDuration: Double {
        sourceDuration / speed
    }
}

struct ZoomRange: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var amount: Double
    var entryAnimation: ZoomAnimation
    var exitAnimation: ZoomAnimation

    init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        amount: Double = 1.24,
        entryAnimation: ZoomAnimation = .smooth,
        exitAnimation: ZoomAnimation = .smooth
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.amount = amount
        self.entryAnimation = entryAnimation
        self.exitAnimation = exitAnimation
    }
}

enum ZoomAnimation: String, CaseIterable, Identifiable {
    case none
    case linear
    case easeIn
    case easeOut
    case smooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Instant"
        case .linear: "Linear"
        case .easeIn: "Ease in"
        case .easeOut: "Ease out"
        case .smooth: "Smooth"
        }
    }
}

private extension ZoomAnimation {
    func progress(at value: Double) -> Double {
        let t = min(1, max(0, value))
        switch self {
        case .none, .linear:
            return t
        case .easeIn:
            // Cubic ease-in: slow start, then accelerates.
            return t * t * t
        case .easeOut:
            // Cubic ease-out: fast start, soft landing.
            let inv = 1 - t
            return 1 - inv * inv * inv
        case .smooth:
            // Smootherstep (Perlin): zero 1st + 2nd derivatives at endpoints.
            // Feels much less snappy than classic smoothstep for camera zooms.
            return t * t * t * (t * (t * 6 - 15) + 10)
        }
    }
}

struct TimelineClipLayout: Identifiable {
    let clip: EditClip
    let start: Double
    let end: Double

    var id: UUID { clip.id }
    var duration: Double { end - start }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case edit
    case cursor
    case camera
    case background

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Edit"
        case .cursor: "Cursor"
        case .camera: "Camera"
        case .background: "Background"
        }
    }

    var systemImage: String {
        switch self {
        case .edit: "scissors"
        case .cursor: "cursorarrow.motionlines"
        case .camera: "camera.fill"
        case .background: "photo.fill"
        }
    }
}

/// Live preview of the custom cursor (UI overlay — CA tool is export-only).
struct CursorPreviewState: Equatable {
    var normalizedPosition: CGPoint
    /// Index 0 is the live cursor; further entries are motion-blur ghosts.
    var trail: [CursorTrailSample]
    var style: CursorStyle
    var size: Double
    var clickEffect: CursorClickEffect
    var clickProgress: Double?
}

struct CursorTrailSample: Equatable {
    var normalizedPosition: CGPoint
    var opacity: Double
}

@MainActor
final class EditorModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum ExportState: Equatable {
        case idle
        case exporting(Double)
        case completed(URL)
        case failed(String)
    }

    let sourceURL: URL
    let player = AVPlayer()

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var exportState: ExportState = .idle
    @Published private(set) var duration: Double = 0
    @Published var playhead: Double = 0
    @Published private(set) var clips: [EditClip] = []
    @Published private(set) var zoomRanges: [ZoomRange] = []
    @Published var selectedClipID: UUID?
    @Published var selectedZoomID: UUID?
    @Published var inspectorTab: InspectorTab = .edit
    @Published private(set) var cursorSettings: CursorSettings = .default
    @Published private(set) var motionBlurSettings: MotionBlurSettings = .default
    @Published private(set) var hasCursorData = false
    @Published private(set) var cameraSettings: CameraSettings = .default
    @Published private(set) var hasCameraVideo = false
    @Published var isBackgroundEnabled: Bool
    @Published var backgroundCornerRadius: Double
    /// Pixel size of the composed video frame (for letterboxed cursor overlay).
    @Published private(set) var videoRenderSize: CGSize = CGSize(width: 1920, height: 1080)

    private(set) var captureMode: CaptureMode
    private var cursorTrack: [CursorPosition] = []
    /// Precise video-space track (no smoothing) — used to draw the cursor on content.
    private var preciseCursorTrack: [CursorPosition] = []
    /// Optional smoothed track for soft camera follow.
    private var processedCursorTrack: [CursorPosition] = []
    private var clickEvents: [ClickEvent] = []
    /// Same zoom transforms used by the video composition — cursor overlay must
    /// sample these so tip and content stay locked when zoomed.
    private var zoomTransformSamples: [ZoomTransformSample] = []
    private var compositionBaseTransform: CGAffineTransform = .identity
    @Published var isPlaying = false

    private var sourceAsset: AVURLAsset?
    private var sourceVideoTrack: AVAssetTrack?
    private var sourceAudioTracks: [AVAssetTrack] = []
    private var cameraAsset: AVURLAsset?
    private var cameraVideoTrack: AVAssetTrack?
    private var cameraDuration: Double = 0
    private var cameraNaturalSize: CGSize = .zero
    private var cameraPreferredTransform: CGAffineTransform = .identity
    private var timeObserver: Any?
    private var exportSession: AVAssetExportSession?
    private var exportProgressTimer: Timer?
    private var isSeeking = false
    private let wallpaperManager = WallpaperManager.shared
    private var wallpaperCancellable: AnyCancellable?

    init(sourceURL: URL, captureMode: CaptureMode = .display) {
        self.sourceURL = sourceURL
        self.captureMode = captureMode
        self.isBackgroundEnabled = (captureMode == .window)
        self.backgroundCornerRadius = 28
        installTimeObserver()
        wallpaperManager.loadWallpapersIfNeeded()
        wallpaperCancellable = wallpaperManager.$selectedWallpaperID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rebuildPreview(preservingPlayhead: true)
                }
            }
        Task {
            await loadSource()
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }


    var timelineClips: [TimelineClipLayout] {
        var cursor = 0.0
        return clips.map { clip in
            let layout = TimelineClipLayout(
                clip: clip,
                start: cursor,
                end: cursor + clip.outputDuration
            )
            cursor = layout.end
            return layout
        }
    }

    var selectedClip: EditClip? {
        guard let selectedClipID else { return nil }
        return clips.first { $0.id == selectedClipID }
    }

    var selectedZoomRange: ZoomRange? {
        guard let selectedZoomID else { return nil }
        return zoomRanges.first { $0.id == selectedZoomID }
    }

    var clipTitle: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            if playhead >= duration - 0.01 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        let clamped = min(duration, max(0, time))
        playhead = clamped
        isSeeking = true
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
            }
        }
    }

    func cutAtPlayhead() {
        guard let clipIndex = timelineClips.firstIndex(where: { layout in
            playhead > layout.start + 0.04 && playhead < layout.end - 0.04
        }) else {
            return
        }

        let layout = timelineClips[clipIndex]
        let clip = clips[clipIndex]
        let sourceCut = clip.sourceStart + (playhead - layout.start) * clip.speed
        guard sourceCut > clip.sourceStart + 0.04, sourceCut < clip.sourceEnd - 0.04 else {
            return
        }

        let left = EditClip(
            sourceStart: clip.sourceStart,
            sourceEnd: sourceCut,
            speed: clip.speed
        )
        let right = EditClip(
            sourceStart: sourceCut,
            sourceEnd: clip.sourceEnd,
            speed: clip.speed
        )
        clips.replaceSubrange(clipIndex...clipIndex, with: [left, right])
        selectedClipID = right.id
        rebuildPreview(preservingPlayhead: true)
    }

    func selectClip(_ id: UUID) {
        selectedClipID = id
        selectedZoomID = nil
    }

    func selectZoom(_ id: UUID) {
        selectedZoomID = id
        selectedClipID = nil
    }

    func setSpeed(_ speed: Double, for clipID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[index].speed = speed
        rebuildPreview(preservingPlayhead: true)
    }

    func addZoomRange() {
        // Long enough that entry + exit transitions (~0.85s each) still leave a hold.
        let start = min(max(0, playhead), max(0, duration - 2.5))
        let end = min(duration, start + min(3.2, max(0.8, duration)))
        zoomRanges.append(ZoomRange(start: start, end: end))
        selectedZoomID = zoomRanges.last?.id
        rebuildPreview(preservingPlayhead: true)
    }

    func updateZoomRange(_ range: ZoomRange) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == range.id }) else { return }
        let minimumLength = min(0.25, max(0.05, duration))
        var updated = zoomRanges[index]
        updated.start = min(max(0, range.start), max(0, duration - minimumLength))
        updated.end = min(duration, max(updated.start + minimumLength, range.end))
        zoomRanges[index] = updated
        rebuildPreview(preservingPlayhead: true)
    }

    func setZoomAmount(_ amount: Double, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].amount = min(3, max(1, amount))
        rebuildPreview(preservingPlayhead: true)
    }

    func setZoomEntryAnimation(_ animation: ZoomAnimation, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].entryAnimation = animation
        rebuildPreview(preservingPlayhead: true)
    }

    func setZoomExitAnimation(_ animation: ZoomAnimation, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].exitAnimation = animation
        rebuildPreview(preservingPlayhead: true)
    }

    func removeZoomRange(id: UUID) {
        zoomRanges.removeAll { $0.id == id }
        if selectedZoomID == id {
            selectedZoomID = nil
        }
        rebuildPreview(preservingPlayhead: true)
    }

    func setCursorEnabled(_ enabled: Bool) {
        guard cursorSettings.isEnabled != enabled else { return }
        var settings = cursorSettings
        settings.isEnabled = enabled
        cursorSettings = settings
        // Preview uses a UI overlay; export bakes the cursor offline.
    }

    func setCameraEnabled(_ enabled: Bool) {
        guard hasCameraVideo, cameraSettings.isEnabled != enabled else { return }
        var settings = cameraSettings
        settings.isEnabled = enabled
        cameraSettings = settings
        saveCameraSettings()
        rebuildPreview(preservingPlayhead: true)
    }

    func setBackgroundEnabled(_ enabled: Bool) {
        guard isBackgroundEnabled != enabled else { return }
        isBackgroundEnabled = enabled
        rebuildPreview(preservingPlayhead: true)
    }

    func setBackgroundCornerRadius(_ radius: Double) {
        let clamped = min(120, max(0, radius))
        guard abs(backgroundCornerRadius - clamped) > 0.001 else { return }
        backgroundCornerRadius = clamped
        rebuildPreview(preservingPlayhead: true)
    }

    func setCameraCorner(_ corner: CameraCorner) {
        guard cameraSettings.corner != corner else { return }
        var settings = cameraSettings
        settings.corner = corner
        cameraSettings = settings
        saveCameraSettings()
        rebuildPreview(preservingPlayhead: true)
    }

    func setCameraSize(_ size: Double) {
        let clamped = min(0.45, max(0.08, size))
        guard abs(cameraSettings.size - clamped) > 0.001 else { return }
        var settings = cameraSettings
        settings.size = clamped
        cameraSettings = settings
        saveCameraSettings()
        rebuildPreview(preservingPlayhead: true)
    }

    func setCursorStyle(_ style: CursorStyle) {
        guard cursorSettings.style != style else { return }
        var settings = cursorSettings
        settings.style = style
        cursorSettings = settings
    }

    func setCursorMotion(_ motion: CursorMotionStyle) {
        guard cursorSettings.motion != motion else { return }
        var settings = cursorSettings
        settings.motion = motion
        cursorSettings = settings
        refreshProcessedCursorTrack()
        // Motion also drives zoom focus, so rebuild the player composition.
        rebuildPreview(preservingPlayhead: true)
    }

    func setCursorSize(_ size: Double) {
        let clamped = min(2, max(0.6, size))
        guard abs(cursorSettings.size - clamped) > 0.001 else { return }
        var settings = cursorSettings
        settings.size = clamped
        cursorSettings = settings
    }

    func setCursorClickEffect(_ effect: CursorClickEffect) {
        guard cursorSettings.clickEffect != effect else { return }
        var settings = cursorSettings
        settings.clickEffect = effect
        cursorSettings = settings
    }

    func setMotionBlurEnabled(_ enabled: Bool) {
        guard motionBlurSettings.isEnabled != enabled else { return }
        var settings = motionBlurSettings
        settings.isEnabled = enabled
        motionBlurSettings = settings
        // Zoom blur is baked into the video composition.
        if settings.applyToZoom {
            rebuildPreview(preservingPlayhead: true)
        }
    }

    func setMotionBlurAmount(_ amount: Double) {
        let clamped = min(1, max(0, amount))
        guard abs(motionBlurSettings.amount - clamped) > 0.001 else { return }
        var settings = motionBlurSettings
        settings.amount = clamped
        motionBlurSettings = settings
        if settings.isEnabled, settings.applyToZoom {
            rebuildPreview(preservingPlayhead: true)
        }
    }

    func setMotionBlurApplyToCursor(_ enabled: Bool) {
        guard motionBlurSettings.applyToCursor != enabled else { return }
        var settings = motionBlurSettings
        settings.applyToCursor = enabled
        motionBlurSettings = settings
        // Cursor trail is a live overlay — no composition rebuild.
    }

    func setMotionBlurApplyToZoom(_ enabled: Bool) {
        guard motionBlurSettings.applyToZoom != enabled else { return }
        var settings = motionBlurSettings
        settings.applyToZoom = enabled
        motionBlurSettings = settings
        if settings.isEnabled {
            rebuildPreview(preservingPlayhead: true)
        }
    }

    /// Cursor state for the live player overlay (not baked into AVPlayerItem).
    func cursorPreview(at time: Double) -> CursorPreviewState? {
        guard cursorSettings.isEnabled, hasCursorData else { return nil }
        let renderSize = videoRenderSize
        guard renderSize.width > 1, renderSize.height > 1 else { return nil }

        let trailTimes = MotionBlurMath.trailTimes(at: time, settings: motionBlurSettings)
        let trail: [CursorTrailSample] = trailTimes.compactMap { sample in
            let point = displayCursorPoint(at: sample.time, renderSize: renderSize)
            return CursorTrailSample(
                normalizedPosition: CGPoint(
                    x: point.x / renderSize.width,
                    y: point.y / renderSize.height
                ),
                opacity: sample.opacity
            )
        }

        guard let head = trail.first else { return nil }

        var clickProgress: Double?
        if cursorSettings.clickEffect != .none {
            let effectDuration = cursorSettings.clickEffect == .pulse ? 0.28 : 0.45
            for click in clickEvents {
                let dt = time - click.time
                if dt >= 0, dt <= effectDuration {
                    clickProgress = dt / effectDuration
                    break
                }
            }
        }

        return CursorPreviewState(
            normalizedPosition: head.normalizedPosition,
            trail: trail,
            style: cursorSettings.style,
            size: cursorSettings.size,
            clickEffect: cursorSettings.clickEffect,
            clickProgress: clickProgress
        )
    }

    func generateAutoZoomRanges() {
        guard !cursorTrack.isEmpty, duration > 0.25 else { return }

        // Screen-Studio-style pipeline: cluster interest points → scenes →
        // merge any pair that would leave a janky micro-gap between zooms.
        zoomRanges = AutoZoomEngine.generate(
            duration: duration,
            cursorTrack: cursorTrack,
            clickEvents: clickEvents
        )
        selectedZoomID = zoomRanges.first?.id
        rebuildPreview(preservingPlayhead: true)
    }

    /// Used by the video compositor path when manual ranges overlap.
    private func clampZoomRange(_ range: ZoomRange, in duration: Double) -> ZoomRange {
        var start = min(max(0, range.start), max(0, duration - 0.25))
        var end = min(duration, max(start + 0.25, range.end))
        if end - start < 0.6 {
            end = min(duration, start + 0.6)
            start = max(0, end - 0.6)
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

    /// Ensures zoom windows never overlap for transform ramps.
    /// Close ranges are merged (not trimmed with a tiny gap) so the camera
    /// does not zoom out and immediately back in.
    private func resolveNonOverlappingZoomRanges(
        _ ranges: [ZoomRange],
        minGap: Double,
        minLength: Double
    ) -> [ZoomRange] {
        guard !ranges.isEmpty else { return [] }

        let sorted = ranges.sorted { $0.start < $1.start }
        var result: [ZoomRange] = [sorted[0]]

        for range in sorted.dropFirst() {
            var last = result[result.count - 1]
            let gap = range.start - last.end
            // Merge overlaps and any gap too small for a clean full-frame beat.
            if gap < max(minGap, 1.75) {
                last.end = max(last.end, range.end)
                last.amount = max(last.amount, range.amount)
                last.entryAnimation = .smooth
                last.exitAnimation = .smooth
                result[result.count - 1] = last
            } else if range.end - range.start >= minLength {
                result.append(range)
            }
        }

        return result.filter { $0.end - $0.start >= minLength }
    }

    func export() {
        guard case .ready = loadState else { return }
        guard !clips.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.message = "Choose where to save the edited recording."
        panel.nameFieldStringValue = "\(clipTitle) Edited.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        export(to: outputURL)
    }

    func export(to outputURL: URL) {
        guard case .ready = loadState else { return }
        guard !clips.isEmpty else { return }
        startExport(to: outputURL)
    }

    func dismissExportMessage() {
        switch exportState {
        case .completed, .failed:
            exportState = .idle
        case .idle, .exporting:
            break
        }
    }

    private func loadCameraTrack() async -> (AVURLAsset?, AVAssetTrack?, Double, CGSize, CGAffineTransform, CameraSettings) {
        let cameraURL = sourceURL.deletingPathExtension().appendingPathExtension("camera.mp4")
        let settingsURL = sourceURL.deletingPathExtension().appendingPathExtension("cameracorner.json")
        print("[Camera] sidecar path: \(cameraURL.path), exists: \(FileManager.default.fileExists(atPath: cameraURL.path))")
        guard FileManager.default.fileExists(atPath: cameraURL.path) else {
            return (nil, nil, 0, .zero, .identity, .default)
        }

        let asset = AVURLAsset(url: cameraURL)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                print("[Camera] no video track in sidecar")
                return (nil, nil, 0, .zero, .identity, .default)
            }
            let duration = try await asset.load(.duration).seconds
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let settings: CameraSettings
            if FileManager.default.fileExists(atPath: settingsURL.path),
               let data = try? Data(contentsOf: settingsURL),
               let decoded = try? JSONDecoder().decode(CameraSettings.self, from: data) {
                settings = decoded
            } else {
                settings = CameraSettings(isEnabled: true, corner: .bottomRight, size: CameraOverlayGeometry.defaultSize)
            }
            print("[Camera] loaded size=\(naturalSize), transform=\(preferredTransform), duration=\(duration), enabled=\(settings.isEnabled)")
            return (asset, track, duration, naturalSize, preferredTransform, settings)
        } catch {
            print("[Camera] failed to load camera track: \(error)")
            return (nil, nil, 0, .zero, .identity, .default)
        }
    }

    private func saveCameraSettings() {
        let settingsURL = sourceURL.deletingPathExtension().appendingPathExtension("cameracorner.json")
        do {
            let data = try JSONEncoder().encode(cameraSettings)
            try data.write(to: settingsURL)
        } catch {
            print("Failed to save camera settings: \(error)")
        }
    }

    private func loadCursorTrack() -> [CursorPosition] {
        let trackURL = sourceURL.deletingPathExtension().appendingPathExtension("cursor.json")
        guard FileManager.default.fileExists(atPath: trackURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: trackURL)
            // v2+: { version, coordinateSpace, samples } in video top-left space.
            if let file = try? JSONDecoder().decode(CursorTrackFile.self, from: data) {
                if file.coordinateSpace == CursorTrackFile.videoTopLeft || file.version >= 2 {
                    return file.samples
                }
                // Explicit cocoa space in a versioned file.
                return file.samples.map { sample in
                    CursorPosition(time: sample.time, x: sample.x, y: 1 - sample.y)
                }
            }
            // Legacy bare array: Cocoa bottom-left → convert to video top-left.
            let legacy = try JSONDecoder().decode([CursorPosition].self, from: data)
            return legacy.map { sample in
                CursorPosition(time: sample.time, x: sample.x, y: 1 - sample.y)
            }
        } catch {
            print("Failed to load cursor track: \(error)")
            return []
        }
    }

    private func loadClickEvents() -> [ClickEvent] {
        let clicksURL = sourceURL.deletingPathExtension().appendingPathExtension("clicks.json")
        guard FileManager.default.fileExists(atPath: clicksURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: clicksURL)
            return try JSONDecoder().decode([ClickEvent].self, from: data)
        } catch {
            print("Failed to load click events: \(error)")
            return []
        }
    }

    /// Estimates the window corner radius by scanning diagonally from each corner
    /// of the first video frame for the transition from black to non-black pixels.
    private func detectWindowCornerRadius(asset: AVURLAsset) async -> Double? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixelData,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let corners: [(start: (Int, Int), step: (Int, Int))] = [
            ((0, 0), (1, 1)),
            ((width - 1, 0), (-1, 1)),
            ((0, height - 1), (1, -1)),
            ((width - 1, height - 1), (-1, -1))
        ]

        var radii: [Double] = []
        let threshold: UInt8 = 30
        let maxDistance = min(200, min(width, height) / 2)

        for (start, step) in corners {
            var x = start.0
            var y = start.1
            var distance = 0
            while distance < maxDistance {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                let brightness = max(r, max(g, b))
                if brightness > threshold {
                    break
                }
                x += step.0
                y += step.1
                distance += 1
            }
            // Along a diagonal, the black quarter-circle extends to ~0.293 * radius.
            if distance > 2, distance < maxDistance {
                radii.append(Double(distance) / 0.293)
            }
        }

        guard !radii.isEmpty else { return nil }
        radii.sort()
        return radii[radii.count / 2]
    }

    private func loadSource() async {
        let asset = AVURLAsset(url: sourceURL)

        do {
            let assetDuration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            guard let videoTrack = videoTracks.first else {
                throw EditorError.missingVideoTrack
            }

            let seconds = assetDuration.seconds
            guard seconds.isFinite, seconds > 0 else {
                throw EditorError.invalidDuration
            }

            sourceAsset = asset
            sourceVideoTrack = videoTrack
            sourceAudioTracks = audioTracks
            cursorTrack = loadCursorTrack()
            clickEvents = loadClickEvents()
            hasCursorData = !cursorTrack.isEmpty
            refreshProcessedCursorTrack()
            // Default custom cursor on when we have track data (system cursor is hidden on record).
            var settings = cursorSettings
            settings.isEnabled = hasCursorData
            cursorSettings = settings

            (cameraAsset, cameraVideoTrack, cameraDuration, cameraNaturalSize, cameraPreferredTransform, cameraSettings) = await loadCameraTrack()
            hasCameraVideo = cameraVideoTrack != nil

            // Detect the window corner radius from black pixels at the corners.
            if captureMode == .window,
               let detectedRadius = await detectWindowCornerRadius(asset: asset) {
                backgroundCornerRadius = detectedRadius
            }

            clips = [EditClip(sourceStart: 0, sourceEnd: seconds)]
            selectedClipID = clips.first?.id
            duration = seconds
            loadState = .ready
            rebuildPreview(preservingPlayhead: false)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func rebuildPreview(preservingPlayhead: Bool) {
        // Core Animation cursor tool is export-only — never attach it to AVPlayerItem.
        guard let build = makeComposition(includeCursorOverlay: false) else { return }
        let previousPlayhead = preservingPlayhead ? min(playhead, build.duration) : 0

        let item = AVPlayerItem(asset: build.composition)
        item.videoComposition = build.videoComposition
        // Full-quality preview decode (avoid soft low-bitrate streaming defaults).
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = CGSize(width: 8192, height: 8192)
        player.replaceCurrentItem(with: item)
        duration = build.duration
        videoRenderSize = build.renderSize
        playhead = previousPlayhead
        isPlaying = false
        player.pause()

        if previousPlayhead > 0 {
            seek(to: previousPlayhead)
        }
    }

    private func makeComposition(
        includeCursorOverlay: Bool
    ) -> (
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        duration: Double,
        renderSize: CGSize
    )? {
        guard let sourceVideoTrack else { return nil }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }

        // When a video composition supplies layer transforms, keep the track
        // preferredTransform identity to avoid double-applying orientation
        // (a common VRP failure mode).
        compositionVideoTrack.preferredTransform = .identity

        let compositionAudioTracks = sourceAudioTracks.compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        let includeCamera = cameraSettings.isEnabled && cameraVideoTrack != nil
        let compositionCameraTrack: AVMutableCompositionTrack? = includeCamera
            ? composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil
        compositionCameraTrack?.preferredTransform = .identity

        var cursor = CMTime.zero
        for clip in clips {
            let sourceDuration = CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: sourceDuration
            )

            do {
                try compositionVideoTrack.insertTimeRange(sourceRange, of: sourceVideoTrack, at: cursor)
                for (sourceAudioTrack, compositionAudioTrack) in zip(sourceAudioTracks, compositionAudioTracks) {
                    try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: cursor)
                }
            } catch {
                continue
            }

            // Camera sidecar may be slightly shorter than the screen recording.
            // Insert only the overlapping range so the overlay still appears.
            var cameraInsertedDuration: CMTime?
            if let cameraVideoTrack, let compositionCameraTrack {
                let cameraMaxStart = CMTime(seconds: cameraDuration, preferredTimescale: 600)
                if sourceRange.start < cameraMaxStart {
                    let available = cameraMaxStart - sourceRange.start
                    let cameraRange = CMTimeRange(start: sourceRange.start, duration: min(sourceRange.duration, available))
                    if cameraRange.duration > .zero {
                        do {
                            try compositionCameraTrack.insertTimeRange(cameraRange, of: cameraVideoTrack, at: cursor)
                            cameraInsertedDuration = cameraRange.duration
                            print("[Camera] inserted range \(cameraRange.start.seconds)...\(cameraRange.end.seconds) at composition cursor \(cursor.seconds)")
                        } catch {
                            print("[Camera] insert failed: \(error)")
                        }
                    } else {
                        print("[Camera] no overlapping range (camera duration \(cameraDuration) < source start \(sourceRange.start.seconds))")
                    }
                }
            }

            let outputDuration = CMTime(seconds: clip.outputDuration, preferredTimescale: 600)
            if clip.speed != 1 {
                let insertedRange = CMTimeRange(start: cursor, duration: sourceDuration)
                compositionVideoTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
                for compositionAudioTrack in compositionAudioTracks {
                    compositionAudioTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
                }
                if let compositionCameraTrack, let cameraInsertedDuration, cameraInsertedDuration > .zero {
                    let cameraTargetDuration = CMTime(seconds: cameraInsertedDuration.seconds / clip.speed, preferredTimescale: 600)
                    let cameraInsertedRange = CMTimeRange(start: cursor, duration: cameraInsertedDuration)
                    compositionCameraTrack.scaleTimeRange(cameraInsertedRange, toDuration: cameraTargetDuration)
                }
            }

            cursor = cursor + outputDuration
        }


        print("CamDebug composition tracks: screen segments=\(compositionVideoTrack.segments.count), camera segments=\(compositionCameraTrack?.segments.count ?? 0)")
        let videoComposition = makeVideoComposition(
            compositionTrack: compositionVideoTrack,
            cameraTrack: compositionCameraTrack,
            sourceTrack: sourceVideoTrack,
            duration: cursor,
            includeCursorOverlay: includeCursorOverlay
        )
        return (
            composition,
            videoComposition,
            max(0, cursor.seconds),
            videoComposition.renderSize
        )
    }

    private func makeVideoComposition(
        compositionTrack: AVMutableCompositionTrack,
        cameraTrack: AVMutableCompositionTrack?,
        sourceTrack: AVAssetTrack,
        duration: CMTime,
        includeCursorOverlay: Bool
    ) -> AVMutableVideoComposition {
        let naturalSize = sourceTrack.naturalSize
        let preferred = sourceTrack.preferredTransform
        let transformedSize = naturalSize.applying(preferred)
        // Integer pixel size — fractional render sizes can trip the VRP.
        let renderSize = CGSize(
            width: max(2, abs(transformedSize.width).rounded()),
            height: max(2, abs(transformedSize.height).rounded())
        )
        videoRenderSize = renderSize


        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)

        let selectedWallpaperURL = wallpaperManager.selectedWallpaperID
            .flatMap { wallpaperManager.wallpaper(withID: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.localURL.path) ? $0.localURL : nil }
        let includeWallpaper = isBackgroundEnabled && selectedWallpaperURL != nil
        let applyRoundedCorners = isBackgroundEnabled && captureMode == .window

        // When a wallpaper is active, shrink the video slightly and center it so
        // the background image shows around the edges.
        let baseTransform: CGAffineTransform
        if includeWallpaper {
            let placementScale: CGFloat = 0.95
            let orientedWidth = abs(transformedSize.width)
            let orientedHeight = abs(transformedSize.height)
            let offsetX = (renderSize.width - orientedWidth * placementScale) / 2
            let offsetY = (renderSize.height - orientedHeight * placementScale) / 2
            let placement = CGAffineTransform(scaleX: placementScale, y: placementScale)
                .translatedBy(x: offsetX / placementScale, y: offsetY / placementScale)
            baseTransform = preferred.concatenating(placement)
        } else {
            baseTransform = preferred
        }
        compositionBaseTransform = baseTransform
        // One keyframe timeline shared by video + cursor overlay (critical for lock-on).
        let samples = buildZoomTransformSamples(
            baseTransform: baseTransform,
            renderSize: renderSize,
            duration: duration.seconds
        )
        zoomTransformSamples = samples

        let zoomBlur = motionBlurSettings.zoomStrength
        let includeCamera = cameraTrack != nil && cameraSettings.isEnabled
        print("CamDebug makeVideoComposition renderSize=\(renderSize), frameDuration=\(videoComposition.frameDuration), includeCamera=\(includeCamera), cameraSettings.enabled=\(cameraSettings.isEnabled)")
        print("CamDebug source formatDescriptions=\(sourceTrack.formatDescriptions)")
        print("CamDebug camera formatDescriptions=\(cameraVideoTrack?.formatDescriptions ?? [])")

        var cameraTransform: CGAffineTransform?
        if includeCamera {
            let cameraBaseTransform = cameraPreferredTransform
            // Use the oriented pixel size (after applying the track's preferred
            // transform) so flips/rotations don't push the overlay out of frame.
            let orientedSize = CGSize(
                width: abs(cameraNaturalSize.applying(cameraBaseTransform).width),
                height: abs(cameraNaturalSize.applying(cameraBaseTransform).height)
            )
            // Core Image uses a bottom-left origin, so place the camera using a
            // bottom-left target frame and apply the transform directly.
            let ciFrame = CameraOverlayGeometry.cameraFrameInCI(
                in: renderSize,
                sizeFraction: cameraSettings.clampedSize,
                corner: cameraSettings.corner
            )
            cameraTransform = CameraOverlayGeometry.cameraTransform(
                cameraNaturalSize: orientedSize,
                targetFrame: ciFrame
            )
            print("[Camera] custom compositor transform renderSize=\(renderSize), orientedSize=\(orientedSize), ciFrame=\(ciFrame), transform=\(String(describing: cameraTransform))")
        }

        if includeCamera || zoomBlur > 0.001 || includeWallpaper {
            // Use the Core-Image compositor so we can draw the wallpaper background
            // and scale the camera overlay ourselves. The hardware layer-instruction
            // path cannot composite a static image background.
            let instruction = ViewioCompositionInstruction(
                timeRange: CMTimeRange(start: .zero, duration: duration),
                sourceTrackID: compositionTrack.trackID,
                renderSize: renderSize,
                keyframes: samples,
                motionBlurAmount: includeCamera ? 0 : zoomBlur,
                cameraTrackID: includeCamera ? cameraTrack?.trackID : nil,
                cameraTransform: cameraTransform,
                backgroundImageURL: selectedWallpaperURL,
                applyRoundedCorners: applyRoundedCorners,
                cornerRadius: CGFloat(backgroundCornerRadius)
            )
            videoComposition.instructions = [instruction]
            videoComposition.customVideoCompositorClass = ViewioVideoCompositor.self
        } else {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

            var layerInstructions: [AVVideoCompositionLayerInstruction] = []

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
            if zoomRanges.isEmpty {
                layerInstruction.setTransform(baseTransform, at: .zero)
            } else {
                applyZoomRamps(
                    from: samples,
                    to: layerInstruction,
                    baseTransform: baseTransform,
                    compositionDuration: duration
                )
            }
            layerInstructions.append(layerInstruction)

            instruction.layerInstructions = layerInstructions
            videoComposition.instructions = [instruction]
        }

        // AVVideoCompositionCoreAnimationTool is offline-only (export). Using it on
        // AVPlayerItem crashes with NSInvalidArgumentException.
        if includeCursorOverlay, cursorSettings.isEnabled, hasCursorData {
            let clicks = clickEvents
            CursorOverlayBuilder.apply(
                to: videoComposition,
                settings: cursorSettings,
                motionBlur: motionBlurSettings,
                processedTrack: processedCursorTrack,
                clickEvents: clicks,
                renderSize: renderSize,
                duration: duration.seconds,
                displayPosition: { [weak self] time in
                    guard let self else {
                        return CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
                    }
                    return self.displayCursorPoint(at: time, renderSize: renderSize)
                }
            )
        }

        return videoComposition
    }

    /// Dense transform samples for video composition AND cursor overlay.
    private func buildZoomTransformSamples(
        baseTransform: CGAffineTransform,
        renderSize: CGSize,
        duration: Double
    ) -> [ZoomTransformSample] {
        // 30fps is dense enough that linear ramps ≈ evaluating the zoom function live,
        // so the overlay tip stays locked to the pixels under it.
        let step = 1.0 / 30.0
        var times: [Double] = [0, duration]
        for range in zoomRanges {
            let start = max(0, range.start)
            let end = min(duration, range.end)
            guard end > start else { continue }
            var t = start
            while t <= end {
                times.append(t)
                t += step
            }
            times.append(end)
            // Settle identity just after exit.
            times.append(min(duration, end + step))
        }
        times = Array(Set(times.map { ($0 * 1000).rounded() / 1000 })).sorted()

        return times.map { time in
            let scale: CGFloat
            let focus: CGPoint
            let zoom: CGAffineTransform

            if let range = zoomRanges.first(where: { time + 0.0001 >= $0.start && time <= $0.end + 0.0001 }) {
                let length = max(0.001, range.end - range.start)
                let transition = transitionDuration(for: range, totalDuration: length)
                scale = zoomScale(at: time, range: range, transition: transition)
                focus = zoomFocus(at: time, in: range)
                zoom = zoomTransform(
                    renderSize: renderSize,
                    scale: scale,
                    center: focus,
                    targetAmount: CGFloat(min(3, max(1, range.amount)))
                )
            } else {
                scale = 1
                focus = CGPoint(x: 0.5, y: 0.5)
                zoom = .identity
            }

            let transform = finiteTransform(baseTransform.concatenating(zoom)) ?? baseTransform
            return ZoomTransformSample(time: time, transform: transform, focus: focus, scale: scale)
        }
    }

    private func refreshProcessedCursorTrack() {
        // Precise: where the system cursor actually was (for drawing on UI).
        preciseCursorTrack = CursorMotion.process(track: cursorTrack, motion: .precise)
        // Smoothed: softer camera path only (never used for the drawn tip).
        processedCursorTrack = CursorMotion.process(
            track: cursorTrack,
            motion: cursorSettings.motion
        )
    }

    /// Final on-screen cursor point in layer coordinates (top-left origin via geometryFlipped).
    private func displayCursorPoint(
        at time: Double,
        renderSize: CGSize
    ) -> CGPoint {
        // Always use the precise track so the tip matches the recording position.
        let normalized = preciseCursorPosition(at: time)
        let sourcePoint = CGPoint(
            x: normalized.x * renderSize.width,
            y: normalized.y * renderSize.height
        )

        // CRITICAL: use the same interpolated transform as the video composition.
        // Computing zoom live here while the player linearly ramps between sparse
        // keyframes made the cursor drift whenever zoom was active.
        let transform: CGAffineTransform
        if zoomTransformSamples.isEmpty {
            transform = compositionBaseTransform
        } else {
            transform = ZoomTransformSample.interpolate(at: time, in: zoomTransformSamples).transform
        }
        let transformed = sourcePoint.applying(transform)

        return CGPoint(
            x: min(renderSize.width, max(0, transformed.x)),
            y: min(renderSize.height, max(0, transformed.y))
        )
    }

    /// Camera focus: track the real cursor so the pointer stays in frame.
    private func zoomFocus(at time: Double, in range: ZoomRange) -> CGPoint {
        // Use precise position for focus so zoom and cursor tip share the same point.
        preciseCursorPosition(at: time)
    }

    /// Builds a transform that scales the frame and keeps the focus point at the
    /// viewport center. `center` is normalized video space (origin top-left).
    private func zoomTransform(
        renderSize: CGSize,
        scale: CGFloat,
        center: CGPoint,
        targetAmount: CGFloat
    ) -> CGAffineTransform {
        let safeScale = CGFloat(min(3, max(1, Double(scale))))
        guard safeScale > 1.0001,
              renderSize.width > 1,
              renderSize.height > 1 else {
            return .identity
        }

        // Focus exactly on the cursor so the zoom camera follows it and the
        // pointer stays in view. Clamping the focus inward prevented black bars
        // but pushed the cursor toward the crop edge, where the arrow image
        // got clipped and looked like it disappeared.
        let rawX = Double(center.x.isFinite ? center.x : 0.5)
        let rawY = Double(center.y.isFinite ? center.y : 0.5)
        let anchorX = CGFloat(rawX) * renderSize.width
        let anchorY = CGFloat(rawY) * renderSize.height

        // T * p = scale * p + (1 - scale) * anchor
        let tx = (1 - safeScale) * anchorX
        let ty = (1 - safeScale) * anchorY
        return CGAffineTransform(a: safeScale, b: 0, c: 0, d: safeScale, tx: tx, ty: ty)
    }

    /// Precise tip position in normalized video coordinates (origin top-left, 0...1).
    /// Does not apply cinematic/smooth lag — that only affects optional camera styles.
    private func preciseCursorPosition(at time: Double) -> CGPoint {
        let track = preciseCursorTrack.isEmpty
            ? CursorMotion.process(track: cursorTrack, motion: .precise)
            : preciseCursorTrack
        return CursorMotion.position(at: time, in: track, motion: .precise)
    }

    /// Cursor position used for zoom framing (precise; kept as a named alias).
    private func cursorPosition(at time: Double) -> CGPoint {
        preciseCursorPosition(at: time)
    }

    private func cursorPositions(in timeRange: ClosedRange<Double>) -> [CursorPosition] {
        cursorTrack.filter { $0.time >= timeRange.lowerBound && $0.time <= timeRange.upperBound }
    }

    /// Entry/exit length: longer base ease, and a bit more time for stronger zooms.
    private func transitionDuration(for range: ZoomRange, totalDuration: Double) -> Double {
        let amount = min(3, max(1, range.amount))
        // ~0.85s at 1.25x, up to ~1.15s at 2.5x+.
        let base: Double = 0.85
        let amountBoost = min(0.35, max(0, (amount - 1.25) * 0.35))
        let desired = base + amountBoost
        // Always leave a little hold in the middle when the range is long enough.
        return min(desired, max(0.12, totalDuration / 2.4))
    }

    private func zoomScale(at time: Double, range: ZoomRange, transition: Double) -> CGFloat {
        let amount = CGFloat(min(3, max(1, range.amount)))
        let relativeTime = time - range.start
        let rangeDuration = range.end - range.start

        if relativeTime < transition {
            let progress = transition > 0 ? relativeTime / transition : 1
            let eased = range.entryAnimation.progress(at: progress)
            return 1 + (amount - 1) * CGFloat(eased)
        } else if relativeTime > rangeDuration - transition {
            let progress = transition > 0 ? (rangeDuration - relativeTime) / transition : 1
            let eased = range.exitAnimation.progress(at: progress)
            return 1 + (amount - 1) * CGFloat(eased)
        } else {
            return amount
        }
    }

    /// Apply the shared zoom sample timeline as non-overlapping transform ramps.
    private func applyZoomRamps(
        from samples: [ZoomTransformSample],
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        baseTransform: CGAffineTransform,
        compositionDuration: CMTime
    ) {
        let timescale: CMTimeScale = 600
        let total = CMTimeConvertScale(compositionDuration, timescale: timescale, method: .default)
        guard total.seconds > 0.05, total.isValid, !samples.isEmpty else {
            layerInstruction.setTransform(baseTransform, at: .zero)
            return
        }

        let safeBase = finiteTransform(baseTransform) ?? .identity
        var rampCount = 0

        for index in 0..<(samples.count - 1) {
            let from = samples[index]
            let to = samples[index + 1]
            guard to.time > from.time + 0.0005 else { continue }

            var start = CMTime(seconds: from.time, preferredTimescale: timescale)
            var end = CMTime(seconds: to.time, preferredTimescale: timescale)
            if CMTimeCompare(start, .zero) < 0 { start = .zero }
            if CMTimeCompare(end, total) > 0 { end = total }
            guard CMTimeCompare(end, start) > 0 else { continue }

            let range = CMTimeRange(start: start, end: end)
            let clamped = CMTimeRange(start: .zero, duration: total).intersection(range)
            guard CMTimeCompare(clamped.duration, .zero) > 0 else { continue }

            let fromXF = finiteTransform(from.transform) ?? safeBase
            let toXF = finiteTransform(to.transform) ?? safeBase

            layerInstruction.setTransformRamp(
                fromStart: fromXF,
                toEnd: toXF,
                timeRange: clamped
            )
            rampCount += 1
            // Hard cap for compositor stability on very long timelines.
            if rampCount >= 400 { break }
        }

        if rampCount == 0 {
            layerInstruction.setTransform(safeBase, at: .zero)
        }
    }

    /// Sorted zoom windows with overlaps trimmed (never merged into one long zoom).
    private func nonOverlappingZoomRanges(duration: Double) -> [ZoomRange] {
        resolveNonOverlappingZoomRanges(
            zoomRanges
                .map { clampZoomRange($0, in: duration) }
                .filter { $0.end - $0.start > 0.08 },
            minGap: 0.05,
            minLength: 0.08
        )
    }

    /// Average cursor position in a range (stable zoom anchor).
    private func focusPoint(for range: ZoomRange) -> CGPoint {
        // Prefer precise video-space track.
        let track = preciseCursorTrack.isEmpty ? cursorTrack : preciseCursorTrack
        let samples = track.filter { $0.time >= range.start && $0.time <= range.end }
        if samples.isEmpty {
            return preciseCursorPosition(at: (range.start + range.end) / 2)
        }
        let xs = samples.map(\.x)
        let ys = samples.map(\.y)
        let x = xs.reduce(0, +) / Double(xs.count)
        let y = ys.reduce(0, +) / Double(ys.count)
        return CGPoint(
            x: min(1, max(0, x)),
            y: min(1, max(0, y))
        )
    }

    private func finiteTransform(_ transform: CGAffineTransform) -> CGAffineTransform? {
        let values = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        guard values.allSatisfy(\.isFinite) else { return nil }
        // Reject only true zeros determinant (non-invertible), not rotated bases
        // where a or d may be ~0.
        let det = transform.a * transform.d - transform.b * transform.c
        guard abs(det) > 1e-6 else { return nil }
        return transform
    }

    private func transformForZoom(
        at time: Double,
        range: ZoomRange,
        transition: Double,
        baseTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let scale = zoomScale(at: time, range: range, transition: transition)
        let center = cursorPosition(at: time)
        let zoom = zoomTransform(
            renderSize: renderSize,
            scale: scale,
            center: center,
            targetAmount: CGFloat(min(3, max(1, range.amount)))
        )
        return finiteTransform(baseTransform.concatenating(zoom)) ?? baseTransform
    }

    private func applyTransformAnimation(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        from startTransform: CGAffineTransform,
        to endTransform: CGAffineTransform,
        start: CMTime,
        end: CMTime,
        animation: ZoomAnimation
    ) {
        guard end > start else { return }
        if animation == .none {
            layerInstruction.setTransform(endTransform, at: start)
            return
        }

        let steps = animation == .linear ? 1 : 12
        let duration = end.seconds - start.seconds
        for step in 0..<steps {
            let lower = Double(step) / Double(steps)
            let upper = Double(step + 1) / Double(steps)
            let lowerProgress = animation.progress(at: lower)
            let upperProgress = animation.progress(at: upper)
            let firstTime = CMTime(seconds: start.seconds + duration * lower, preferredTimescale: 600)
            let secondTime = CMTime(seconds: start.seconds + duration * upper, preferredTimescale: 600)

            layerInstruction.setTransformRamp(
                fromStart: interpolate(startTransform, endTransform, progress: lowerProgress),
                toEnd: interpolate(startTransform, endTransform, progress: upperProgress),
                timeRange: CMTimeRange(start: firstTime, end: secondTime)
            )
        }
    }

    private func interpolate(
        _ start: CGAffineTransform,
        _ end: CGAffineTransform,
        progress: Double
    ) -> CGAffineTransform {
        let value = CGFloat(progress)
        return CGAffineTransform(
            a: start.a + (end.a - start.a) * value,
            b: start.b + (end.b - start.b) * value,
            c: start.c + (end.c - start.c) * value,
            d: start.d + (end.d - start.d) * value,
            tx: start.tx + (end.tx - start.tx) * value,
            ty: start.ty + (end.ty - start.ty) * value
        )
    }

    private func startExport(to outputURL: URL) {
        // Bake cursor with Core Animation tool — valid for offline export only.
        guard let build = makeComposition(includeCursorOverlay: true) else {
            exportState = .failed("Unable to prepare this recording for export.")
            return
        }

        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: build.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            exportState = .failed("This recording cannot be exported on this Mac.")
            return
        }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.videoComposition = build.videoComposition
        session.shouldOptimizeForNetworkUse = true
        exportSession = session
        exportState = .exporting(0)
        startExportProgressTimer(for: session)

        session.exportAsynchronously { [weak self] in
            Task { @MainActor in
                self?.finishExport(session: session, outputURL: outputURL)
            }
        }
    }

    private func startExportProgressTimer(for session: AVAssetExportSession) {
        exportProgressTimer?.invalidate()
        exportProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.exportState = .exporting(Double(session.progress))
            }
        }
    }

    private func finishExport(session: AVAssetExportSession, outputURL: URL) {
        exportProgressTimer?.invalidate()
        exportProgressTimer = nil
        exportSession = nil

        switch session.status {
        case .completed:
            exportState = .completed(outputURL)
        case .failed, .cancelled:
            exportState = .failed(session.error?.localizedDescription ?? "Export did not finish.")
        default:
            exportState = .failed("Export ended unexpectedly.")
        }
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.playhead = min(self.duration, max(0, seconds))
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }
}

private enum EditorError: LocalizedError {
    case missingVideoTrack
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            "The recording does not contain a video track."
        case .invalidDuration:
            "The recording has no playable duration."
        }
    }
}
