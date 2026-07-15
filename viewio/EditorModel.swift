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
        switch self {
        case .none, .linear:
            value
        case .easeIn:
            value * value
        case .easeOut:
            1 - (1 - value) * (1 - value)
        case .smooth:
            value * value * (3 - 2 * value)
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
        let start = min(max(0, playhead), max(0, duration - 1.5))
        let end = min(duration, start + min(2, max(0.5, duration)))
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
        guard let build = makeComposition() else { return }
        let previousPlayhead = preservingPlayhead ? min(playhead, build.duration) : 0

        let item = AVPlayerItem(asset: build.composition)
        item.videoComposition = build.videoComposition
        player.replaceCurrentItem(with: item)
        duration = build.duration
        playhead = previousPlayhead
        isPlaying = false
        player.pause()

        if previousPlayhead > 0 {
            seek(to: previousPlayhead)
        }
    }

    private func makeComposition() -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, duration: Double)? {
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
            duration: cursor
        )
        return (composition, videoComposition, max(0, cursor.seconds))
    }

    private func makeVideoComposition(
        compositionTrack: AVCompositionTrack,
        sourceTrack: AVAssetTrack,
        duration: CMTime
    ) -> AVMutableVideoComposition {
        let naturalSize = sourceTrack.naturalSize
        let transformedSize = naturalSize.applying(sourceTrack.preferredTransform)
        let renderSize = CGSize(
            width: max(1, abs(transformedSize.width)),
            height: max(1, abs(transformedSize.height))
        )

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
        return videoComposition
    }

    private func centeredZoomTransform(renderSize: CGSize, amount: Double) -> CGAffineTransform {
        let scale = CGFloat(min(3, max(1, amount)))
        return CGAffineTransform(
            translationX: renderSize.width * (1 - scale) / 2,
            y: renderSize.height * (1 - scale) / 2
        )
        .scaledBy(x: scale, y: scale)
    }

    private func applyZoomRamps(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        baseTransform: CGAffineTransform,
        renderSize: CGSize,
        duration: Double
    ) {
        let transitionDuration = 0.35
        for range in zoomRanges.sorted(by: { $0.start < $1.start }) {
            let start = min(duration, max(0, range.start))
            let end = min(duration, max(start, range.end))
            guard end > start else { continue }

            let transition = min(transitionDuration, (end - start) / 2)
            let startTime = CMTime(seconds: start, preferredTimescale: 600)
            let zoomInEnd = CMTime(seconds: start + transition, preferredTimescale: 600)
            let zoomOutStart = CMTime(seconds: end - transition, preferredTimescale: 600)
            let endTime = CMTime(seconds: end, preferredTimescale: 600)
            let zoomTransform = baseTransform.concatenating(
                centeredZoomTransform(renderSize: renderSize, amount: range.amount)
            )

            applyTransformAnimation(
                to: layerInstruction,
                from: baseTransform,
                to: zoomTransform,
                start: startTime,
                end: zoomInEnd,
                animation: range.entryAnimation
            )
            layerInstruction.setTransform(zoomTransform, at: zoomInEnd)
            applyTransformAnimation(
                to: layerInstruction,
                from: zoomTransform,
                to: baseTransform,
                start: zoomOutStart,
                end: endTime,
                animation: range.exitAnimation
            )
        }
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
        guard let build = makeComposition() else {
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
