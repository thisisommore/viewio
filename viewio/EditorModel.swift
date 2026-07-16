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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Edit"
        case .cursor: "Cursor"
        }
    }
}

/// Live preview of the custom cursor (UI overlay — CA tool is export-only).
struct CursorPreviewState: Equatable {
    var normalizedPosition: CGPoint
    var style: CursorStyle
    var size: Double
    var clickEffect: CursorClickEffect
    var clickProgress: Double?
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
    @Published private(set) var hasCursorData = false
    /// Pixel size of the composed video frame (for letterboxed cursor overlay).
    @Published private(set) var videoRenderSize: CGSize = CGSize(width: 1920, height: 1080)

    private var cursorTrack: [CursorPosition] = []
    private var processedCursorTrack: [CursorPosition] = []
    private var clickEvents: [ClickEvent] = []
    @Published var isPlaying = false

    private var sourceAsset: AVURLAsset?
    private var sourceVideoTrack: AVAssetTrack?
    private var sourceAudioTracks: [AVAssetTrack] = []
    private var timeObserver: Any?
    private var exportSession: AVAssetExportSession?
    private var exportProgressTimer: Timer?
    private var isSeeking = false

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
        installTimeObserver()
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

    /// Cursor state for the live player overlay (not baked into AVPlayerItem).
    func cursorPreview(at time: Double) -> CursorPreviewState? {
        guard cursorSettings.isEnabled, hasCursorData else { return nil }
        let renderSize = videoRenderSize
        guard renderSize.width > 1, renderSize.height > 1 else { return nil }

        let baseTransform = sourceVideoTrack?.preferredTransform ?? .identity
        let point = displayCursorPoint(at: time, renderSize: renderSize, baseTransform: baseTransform)
        let normalized = CGPoint(
            x: point.x / renderSize.width,
            y: point.y / renderSize.height
        )

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
            normalizedPosition: normalized,
            style: cursorSettings.style,
            size: cursorSettings.size,
            clickEffect: cursorSettings.clickEffect,
            clickProgress: clickProgress
        )
    }

    func generateAutoZoomRanges() {
        guard !cursorTrack.isEmpty, duration > 0.25 else { return }

        var candidates: [ZoomRange] = []

        for click in clickEvents {
            // Wider windows so entry/exit can ease over ~0.85s without feeling rushed.
            let start = max(0, click.time - 0.9)
            let end = min(duration, max(start + 1.2, click.time + 1.4))
            candidates.append(ZoomRange(start: start, end: end))
        }

        for pause in findPauseSegments() {
            let start = max(0, pause.start - 0.5)
            let end = min(duration, max(start + 1.0, pause.end + 0.5))
            candidates.append(ZoomRange(start: start, end: end))
        }

        // Fallback: if there are no clicks/pauses, still place zooms on low-motion dwells.
        if candidates.isEmpty {
            candidates.append(contentsOf: findDwellZoomCandidates())
        }

        let merged = mergeZoomRanges(candidates)
            .map { clampZoomRange($0, in: duration) }
            .filter { $0.end - $0.start >= 0.6 }

        let built = merged.compactMap { range -> ZoomRange? in
            let positions = cursorPositions(in: range.start...range.end)
            let spread = spatialSpread(of: positions)
            // Allow slightly larger spreads so auto-zoom still fires on normal mouse use.
            guard spread <= 0.85 else { return nil }
            let amount = min(2.2, max(1.25, 1.25 + (1 - spread) * 1.1))
            return ZoomRange(
                id: range.id,
                start: range.start,
                end: range.end,
                amount: amount,
                entryAnimation: .smooth,
                exitAnimation: .smooth
            )
        }

        // Cap count so the compositor is not flooded with transform ramps.
        zoomRanges = Array(built.prefix(24))
        selectedZoomID = zoomRanges.first?.id
        rebuildPreview(preservingPlayhead: true)
    }

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

    /// When there are no clicks, invent zoom windows around slow cursor segments.
    private func findDwellZoomCandidates() -> [ZoomRange] {
        let pauses = findPauseSegments()
        if !pauses.isEmpty {
            return pauses.map { pause in
                ZoomRange(
                    start: max(0, pause.start - 0.4),
                    end: min(duration, pause.end + 0.8)
                )
            }
        }

        // Last resort: a few evenly spaced zooms along the track so Auto Zoom always does something.
        guard duration > 2 else { return [] }
        var result: [ZoomRange] = []
        let count = min(4, max(1, Int(duration / 8)))
        for index in 0..<count {
            let center = duration * (Double(index) + 0.5) / Double(count)
            result.append(
                ZoomRange(
                    start: max(0, center - 1.1),
                    end: min(duration, center + 1.1)
                )
            )
        }
        return result
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

    private func loadCursorTrack() -> [CursorPosition] {
        let trackURL = sourceURL.deletingPathExtension().appendingPathExtension("cursor.json")
        guard FileManager.default.fileExists(atPath: trackURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: trackURL)
            return try JSONDecoder().decode([CursorPosition].self, from: data)
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

        compositionVideoTrack.preferredTransform = sourceVideoTrack.preferredTransform
        let compositionAudioTracks = sourceAudioTracks.compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

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

            let outputDuration = CMTime(seconds: clip.outputDuration, preferredTimescale: 600)
            if clip.speed != 1 {
                let insertedRange = CMTimeRange(start: cursor, duration: sourceDuration)
                compositionVideoTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
                for compositionAudioTrack in compositionAudioTracks {
                    compositionAudioTrack.scaleTimeRange(insertedRange, toDuration: outputDuration)
                }
            }

            cursor = cursor + outputDuration
        }

        let videoComposition = makeVideoComposition(
            compositionTrack: compositionVideoTrack,
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
        compositionTrack: AVCompositionTrack,
        sourceTrack: AVAssetTrack,
        duration: CMTime,
        includeCursorOverlay: Bool
    ) -> AVMutableVideoComposition {
        let naturalSize = sourceTrack.naturalSize
        let transformedSize = naturalSize.applying(sourceTrack.preferredTransform)
        // Even dimensions avoid rare VRP failures with some decoders/compositors.
        let rawWidth = max(2, abs(transformedSize.width))
        let rawHeight = max(2, abs(transformedSize.height))
        let renderSize = CGSize(
            width: (rawWidth / 2).rounded(.down) * 2,
            height: (rawHeight / 2).rounded(.down) * 2
        )
        videoRenderSize = renderSize

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        let baseTransform = sourceTrack.preferredTransform
        layerInstruction.setTransform(baseTransform, at: .zero)

        applyZoomRamps(
            to: layerInstruction,
            baseTransform: baseTransform,
            renderSize: renderSize,
            duration: duration.seconds
        )

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // AVVideoCompositionCoreAnimationTool is offline-only (export). Using it on
        // AVPlayerItem crashes with NSInvalidArgumentException.
        if includeCursorOverlay, cursorSettings.isEnabled, hasCursorData {
            let clicks = clickEvents
            CursorOverlayBuilder.apply(
                to: videoComposition,
                settings: cursorSettings,
                processedTrack: processedCursorTrack,
                clickEvents: clicks,
                renderSize: renderSize,
                duration: duration.seconds,
                displayPosition: { [weak self] time in
                    guard let self else {
                        return CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
                    }
                    return self.displayCursorPoint(at: time, renderSize: renderSize, baseTransform: baseTransform)
                }
            )
        }

        return videoComposition
    }

    private func refreshProcessedCursorTrack() {
        processedCursorTrack = CursorMotion.process(
            track: cursorTrack,
            motion: cursorSettings.motion
        )
    }

    /// Final on-screen cursor point in layer coordinates (top-left origin via geometryFlipped).
    private func displayCursorPoint(
        at time: Double,
        renderSize: CGSize,
        baseTransform: CGAffineTransform
    ) -> CGPoint {
        let normalized = CursorMotion.position(
            at: time,
            in: processedCursorTrack,
            motion: cursorSettings.motion
        )
        let sourcePoint = CGPoint(
            x: normalized.x * renderSize.width,
            y: normalized.y * renderSize.height
        )

        // Match transformForZoom: preferred orientation first, then zoom.
        let zoom = activeZoomTransform(at: time, renderSize: renderSize)
        let transformed = sourcePoint.applying(zoom.concatenating(baseTransform))
        return CGPoint(
            x: min(renderSize.width, max(0, transformed.x)),
            y: min(renderSize.height, max(0, transformed.y))
        )
    }

    private func activeZoomTransform(at time: Double, renderSize: CGSize) -> CGAffineTransform {
        guard let range = zoomRanges.first(where: { time >= $0.start && time <= $0.end }) else {
            return .identity
        }
        let rangeDuration = max(0.001, range.end - range.start)
        let transition = transitionDuration(for: range, totalDuration: rangeDuration)
        let scale = zoomScale(at: time, range: range, transition: transition)
        // Zoom focus follows the processed cursor so motion style and framing stay in sync.
        let center = CursorMotion.position(
            at: time,
            in: processedCursorTrack,
            motion: cursorSettings.motion
        )
        return zoomTransform(
            renderSize: renderSize,
            scale: scale,
            center: center,
            targetAmount: CGFloat(min(3, max(1, range.amount)))
        )
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

        let midX = renderSize.width / 2
        let midY = renderSize.height / 2

        // Keep the scaled content covering the full frame (no black bars).
        let inset = min(0.49, 0.5 / Double(safeScale))
        let clampedX = min(1 - inset, max(inset, Double(center.x.isFinite ? center.x : 0.5)))
        let clampedY = min(1 - inset, max(inset, Double(center.y.isFinite ? center.y : 0.5)))
        let anchorX = CGFloat(clampedX) * renderSize.width
        let anchorY = CGFloat(clampedY) * renderSize.height

        // Animate pan with zoom-in so scale=1 stays identity, and at full zoom
        // the focus point sits at the frame center.
        let amount = max(CGFloat(min(3, max(1, Double(targetAmount)))), safeScale)
        let panProgress = min(1, max(0, (safeScale - 1) / max(0.0001, amount - 1)))

        // T * p = scale * p + (1 - scale) * anchor + (mid - anchor) * panProgress
        let tx = (1 - safeScale) * anchorX + (midX - anchorX) * panProgress
        let ty = (1 - safeScale) * anchorY + (midY - anchorY) * panProgress
        return CGAffineTransform(a: safeScale, b: 0, c: 0, d: safeScale, tx: tx, ty: ty)
    }

    /// Cursor position in normalized video coordinates (origin top-left, 0...1).
    private func cursorPosition(at time: Double) -> CGPoint {
        if !processedCursorTrack.isEmpty {
            return CursorMotion.position(
                at: time,
                in: processedCursorTrack,
                motion: cursorSettings.motion
            )
        }
        // Fallback when motion pipeline has not run yet.
        guard !cursorTrack.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let raw = CursorMotion.process(track: cursorTrack, motion: .natural)
        return CursorMotion.position(at: time, in: raw, motion: .natural)
    }

    private func findPauseSegments() -> [(start: Double, end: Double)] {
        guard cursorTrack.count >= 2 else { return [] }

        let velocityThreshold: Double = 0.2
        let minimumPauseDuration: Double = 0.3

        var pauses: [(start: Double, end: Double)] = []
        var pauseStart: Double?

        for index in 0..<(cursorTrack.count - 1) {
            let current = cursorTrack[index]
            let next = cursorTrack[index + 1]
            let dx = next.x - current.x
            let dy = next.y - current.y
            let dt = next.time - current.time
            let velocity = dt > 0 ? sqrt(dx * dx + dy * dy) / dt : 0

            if velocity < velocityThreshold {
                if pauseStart == nil {
                    pauseStart = current.time
                }
            } else if let start = pauseStart {
                let end = current.time
                if end - start >= minimumPauseDuration {
                    pauses.append((start: start, end: end))
                }
                pauseStart = nil
            }
        }

        if let start = pauseStart, let last = cursorTrack.last {
            let end = last.time
            if end - start >= minimumPauseDuration {
                pauses.append((start: start, end: end))
            }
        }

        return pauses
    }

    private func mergeZoomRanges(_ ranges: [ZoomRange]) -> [ZoomRange] {
        guard !ranges.isEmpty else { return [] }

        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [ZoomRange] = [sorted[0]]

        for range in sorted.dropFirst() {
            var last = merged[merged.count - 1]
            if range.start <= last.end {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private func cursorPositions(in timeRange: ClosedRange<Double>) -> [CursorPosition] {
        cursorTrack.filter { $0.time >= timeRange.lowerBound && $0.time <= timeRange.upperBound }
    }

    private func spatialSpread(of positions: [CursorPosition]) -> Double {
        guard positions.count >= 2 else { return 0 }
        let xs = positions.map { $0.x }
        let ys = positions.map { $0.y }
        let width = xs.max()! - xs.min()!
        let height = ys.max()! - ys.min()!
        return max(0, min(1, max(width, height)))
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

    private func applyZoomRamps(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        baseTransform: CGAffineTransform,
        renderSize: CGSize,
        duration: Double
    ) {
        guard duration > 0, !zoomRanges.isEmpty else { return }

        // Build one monotonic keyframe list, then emit non-overlapping ramps.
        // Flooding AVFoundation with 60fps ramps + conflicting setTransform calls
        // triggers VRP err=-12852 and breaks playback.
        let timescale: CMTimeScale = 60_000
        let sampleInterval = 1.0 / 20.0
        var keyframes: [(time: Double, transform: CGAffineTransform)] = [
            (0, sanitizedTransform(baseTransform))
        ]

        let sorted = zoomRanges
            .map { clampZoomRange($0, in: duration) }
            .filter { $0.end - $0.start > 0.05 }
            .sorted { $0.start < $1.start }

        for range in sorted {
            let start = range.start
            let end = range.end
            let transition = transitionDuration(for: range, totalDuration: end - start)

            // Gap before this zoom: hold base transform.
            if let last = keyframes.last, last.time < start - 0.0005 {
                appendKeyframe(&keyframes, time: start, transform: baseTransform)
            }

            var sampleTime = start
            while sampleTime < end - 0.0005 {
                let transform = transformForZoom(
                    at: sampleTime,
                    range: range,
                    transition: transition,
                    baseTransform: baseTransform,
                    renderSize: renderSize
                )
                appendKeyframe(&keyframes, time: sampleTime, transform: transform)
                sampleTime += sampleInterval
            }

            let endTransform = transformForZoom(
                at: end,
                range: range,
                transition: transition,
                baseTransform: baseTransform,
                renderSize: renderSize
            )
            appendKeyframe(&keyframes, time: end, transform: endTransform)

            // Settle back to base after exit so later content is stable.
            let settle = min(duration, end + 1.0 / 30.0)
            appendKeyframe(&keyframes, time: settle, transform: baseTransform)
        }

        if let last = keyframes.last, last.time < duration {
            appendKeyframe(&keyframes, time: duration, transform: baseTransform)
        }

        for index in 0..<(keyframes.count - 1) {
            let from = keyframes[index]
            let to = keyframes[index + 1]
            let delta = to.time - from.time
            guard delta > 0.0008 else { continue }

            let startTime = CMTime(seconds: from.time, preferredTimescale: timescale)
            let endTime = CMTime(seconds: to.time, preferredTimescale: timescale)
            let timeRange = CMTimeRange(start: startTime, end: endTime)
            guard timeRange.duration.isValid,
                  timeRange.duration.seconds > 0,
                  !timeRange.duration.seconds.isNaN else {
                continue
            }

            layerInstruction.setTransformRamp(
                fromStart: from.transform,
                toEnd: to.transform,
                timeRange: timeRange
            )
        }
    }

    private func appendKeyframe(
        _ keyframes: inout [(time: Double, transform: CGAffineTransform)],
        time: Double,
        transform: CGAffineTransform
    ) {
        let safe = sanitizedTransform(transform)
        if let last = keyframes.last {
            if abs(last.time - time) < 0.0005 {
                keyframes[keyframes.count - 1] = (time, safe)
                return
            }
            if last.time > time {
                return
            }
        }
        keyframes.append((time, safe))
    }

    private func sanitizedTransform(_ transform: CGAffineTransform) -> CGAffineTransform {
        let values = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        guard values.allSatisfy(\.isFinite) else {
            return .identity
        }
        // Reject degenerate scales that can crash the video render pipeline.
        guard abs(transform.a) > 0.01, abs(transform.d) > 0.01 else {
            return .identity
        }
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
        // Apply preferred orientation first, then zoom in the oriented frame.
        return sanitizedTransform(zoom.concatenating(baseTransform))
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
