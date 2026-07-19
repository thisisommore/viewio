//
//  EditorModel.swift
//  viewio
//

import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

struct EditClip: Identifiable, Codable, Equatable {
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

struct ZoomRange: Identifiable, Codable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var amount: Double
    var entryAnimation: ZoomAnimation
    var exitAnimation: ZoomAnimation
    /// Where the zoomed viewport places its focus.
    var focusMode: ZoomFocusMode
    /// Frame anchor the cursor is pinned to (anchor mode).
    var focusAnchor: FocusAnchor
    /// Frame-edge padding fraction for anchored focus (0.08 = 8%).
    var focusPadding: Double
    /// Normalized video-space point the viewport centers on (fixed mode).
    var fixedFocusPoint: CGPoint

    init(
        id: UUID = UUID(),
        start: Double,
        end: Double,
        amount: Double = 1.24,
        entryAnimation: ZoomAnimation = .smooth,
        exitAnimation: ZoomAnimation = .smooth,
        focusMode: ZoomFocusMode = .followCursor,
        focusAnchor: FocusAnchor = .center,
        focusPadding: Double = 0.08,
        fixedFocusPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.amount = amount
        self.entryAnimation = entryAnimation
        self.exitAnimation = exitAnimation
        self.focusMode = focusMode
        self.focusAnchor = focusAnchor
        self.focusPadding = focusPadding
        self.fixedFocusPoint = fixedFocusPoint
    }
}

enum ZoomAnimation: String, Codable, CaseIterable, Identifiable {
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

/// Where the zoomed viewport places its focus, per zoom range.
enum ZoomFocusMode: String, Codable, CaseIterable, Identifiable {
    /// Magnify around the cursor wherever it is (default).
    case followCursor
    /// Pin the cursor to a chosen frame anchor (corner / edge / center).
    case anchor
    /// Keep the viewport centered on a fixed point, ignoring the cursor.
    case fixedPoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followCursor: "Follow cursor"
        case .anchor: "Anchor"
        case .fixedPoint: "Fixed point"
        }
    }
}

/// Frame anchor for pinned zoom focus (3x3 pad).
enum FocusAnchor: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight
    case leading, center, trailing
    case bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }

    /// 0 = left edge, 0.5 = middle, 1 = right edge.
    private var column: Double {
        switch self {
        case .topLeft, .leading, .bottomLeft: 0
        case .top, .center, .bottom: 0.5
        case .topRight, .trailing, .bottomRight: 1
        }
    }

    /// 0 = top edge, 0.5 = middle, 1 = bottom edge (origin top-left).
    private var row: Double {
        switch self {
        case .topLeft, .top, .topRight: 0
        case .leading, .center, .trailing: 0.5
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }

    /// Where the focus lands in the output frame. `padding` is a fraction of
    /// the frame kept between the focus and the nearest edges (no effect on
    /// `.center`). Origin top-left, matching normalized video space.
    func targetPoint(in size: CGSize, padding: Double) -> CGPoint {
        let pad = min(0.25, max(0, padding))
        let x = column == 0.5 ? size.width / 2 : size.width * (column == 0 ? pad : 1 - pad)
        let y = row == 0.5 ? size.height / 2 : size.height * (row == 0 ? pad : 1 - pad)
        return CGPoint(x: x, y: y)
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
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Edit"
        case .cursor: "Cursor"
        case .camera: "Camera"
        case .background: "Background"
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .edit: "scissors"
        case .cursor: "cursorarrow.motionlines"
        case .camera: "camera.fill"
        case .background: "photo.fill"
        case .audio: "music.note"
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
    /// Pixels per on-screen point of the recording (≈2 on Retina).
    var pointScale: Double
    /// Cursor scale for the shrink click effect (1 = normal).
    var clickScale: Double
    var clickEffect: CursorClickEffect
    var clickProgress: Double?
    /// 1 normally; fades to 0 while "hide when typing" hides the cursor.
    var typingOpacity: Double = 1
}

struct CursorTrailSample: Equatable {
    var normalizedPosition: CGPoint
    var opacity: Double
}

/// Point-in-time editor document for undo / redo (max 5 steps).
private struct EditSnapshot: Equatable {
    var clips: [EditClip]
    var zoomRanges: [ZoomRange]
    var selectedClipID: UUID?
    var selectedZoomID: UUID?
    var cursorSettings: CursorSettings
    var motionBlurSettings: MotionBlurSettings
    var cameraSettings: CameraSettings
    var isBackgroundEnabled: Bool
    var backgroundCornerRadius: Double
    var backgroundPadding: Double
    var musicURL: URL?
    var musicVolume: Double
    var isOriginalAudioMuted: Bool
    var wallpaperID: String?
    var isDirty: Bool
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

    private(set) var sourceURL: URL
    /// Set when this session is backed by a saved `.viewioproj` package.
    private(set) var projectURL: URL?
    /// Called after a successful Save / Save As so the app can track the project.
    var onProjectSaved: ((URL) -> Void)?
    let player = AVPlayer()

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var exportState: ExportState = .idle
    @Published private(set) var isDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var projectSaveError: String?
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
    @Published private(set) var hasKeyData = false
    @Published private(set) var cameraSettings: CameraSettings = .default
    @Published private(set) var hasCameraVideo = false
    @Published var isBackgroundEnabled: Bool
    @Published var backgroundCornerRadius: Double
    /// Fraction of the frame width/height left as background margin on each
    /// edge when a wallpaper is active (0.025 = video scaled to 95%).
    @Published var backgroundPadding: Double = 0.025
    /// Local music file mixed under the video (nil = none).
    @Published private(set) var musicURL: URL?
    @Published private(set) var musicError: String?
    @Published var musicVolume: Double = 0.8
    @Published var isOriginalAudioMuted: Bool = false
    /// Loaded audio track of `musicURL` (kept so composition building stays sync).
    private var musicSourceTrack: AVAssetTrack?
    /// The asset must stay alive for its track to remain readable across
    /// composition rebuilds (zoom, trim, speed changes).
    private var musicAsset: AVURLAsset?
    /// TrackID of the music track inside the current composition (for the mix).
    private var compositionMusicTrackID: CMPersistentTrackID?
    /// Tracks of the composition currently attached to the player, kept so
    /// zoom-only changes can swap just the video composition on the live item
    /// instead of rebuilding and replacing the whole player item (which flickers).
    private var previewCompositionVideoTrack: AVMutableCompositionTrack?
    private var previewCompositionCameraTrack: AVMutableCompositionTrack?
    private var previewCompositionDuration: CMTime = .zero
    /// Pixel size of the composed video frame (for letterboxed cursor overlay).
    @Published private(set) var videoRenderSize: CGSize = CGSize(width: 1920, height: 1080)
    @Published private(set) var timelineThumbnails: [NSImage] = []
    @Published private(set) var timelineThumbnailTimes: [Double] = []

    private(set) var captureMode: CaptureMode
    /// Original recording-space cursor samples (never mutated by edits).
    private var sourceCursorTrack: [CursorPosition] = []
    /// Original recording-space click times (never mutated by edits).
    private var sourceClickEvents: [ClickEvent] = []
    /// Original recording-space keystroke times (never mutated by edits).
    private var sourceKeyEvents: [KeyEvent] = []
    /// Cursor samples remapped onto the current composition (output) timeline.
    private var cursorTrack: [CursorPosition] = []
    /// Point size of the recorded region (from cursor.json) for cursor scaling.
    private var cursorCaptureSizePoints: CGSize?
    /// Precise video-space track (no smoothing) — used to draw the cursor on content.
    private var preciseCursorTrack: [CursorPosition] = []
    /// Click events remapped onto the current composition timeline.
    private var clickEvents: [ClickEvent] = []
    /// Keystroke times remapped onto the current composition timeline.
    private var keyEventTimes: [Double] = []
    /// Ranges where "hide when typing" hides the cursor (composition timeline).
    private var typingHiddenSegments: [CursorHiddenSegment] = []
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
    /// Independent of AVPlayer's periodic observer — that observer often stalls
    /// under ScreenCaptureKit / IOSurface pressure while frames still render,
    /// which freezes the SwiftUI cursor overlay (driven by `playhead`).
    private var playheadPollTimer: Timer?
    private var exportSession: AVAssetExportSession?
    private var exportProgressTimer: Timer?
    private var isSeeking = false
    private let wallpaperManager = WallpaperManager.shared
    private var wallpaperCancellable: AnyCancellable?
    /// Edit document to apply after media finishes loading (project open).
    private var pendingDocument: ViewioProjectDocument?

    // MARK: Undo / redo
    private static let maxHistoryDepth = 5
    /// Snapshot after the last committed edit (or load). Used so `markDirty`
    /// can push the pre-edit state even though mutators change fields first.
    private var lastCommittedSnapshot: EditSnapshot?
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var isApplyingUndoRedo = false
    private var lastCheckpointTime: Date?

    init(sourceURL: URL, captureMode: CaptureMode = .display) {
        self.sourceURL = sourceURL
        self.captureMode = captureMode
        self.isBackgroundEnabled = (captureMode == .window)
        self.backgroundCornerRadius = 28
        // Fresh recordings are unsaved projects until the user saves.
        self.isDirty = true
        installTimeObserver()
        wallpaperManager.loadWallpapersIfNeeded()
        // Wallpaper choice is per recording — reset to the default so a
        // previous recording's selection doesn't leak into this one.
        if let first = wallpaperManager.wallpapers.first {
            wallpaperManager.selectWallpaper(first)
        }
        observeWallpaperChanges()
        Task {
            await loadSource()
        }
    }

    /// Opens a saved `.viewioproj` package with media + edit settings.
    init(projectURL: URL) {
        do {
            let loaded = try ViewioProject.load(from: projectURL)
            self.sourceURL = loaded.mediaURL
            self.projectURL = loaded.projectURL
            self.captureMode = loaded.document.captureMode
            self.isBackgroundEnabled = loaded.document.isBackgroundEnabled
            self.backgroundCornerRadius = loaded.document.backgroundCornerRadius
            self.backgroundPadding = loaded.document.backgroundPadding
            self.musicVolume = loaded.document.musicVolume
            self.isOriginalAudioMuted = loaded.document.isOriginalAudioMuted
            self.pendingDocument = loaded.document
            self.isDirty = false
            installTimeObserver()
            wallpaperManager.loadWallpapersIfNeeded()
            observeWallpaperChanges()
            Task {
                await loadSource()
            }
        } catch {
            self.sourceURL = projectURL
            self.projectURL = projectURL
            self.captureMode = .display
            self.isBackgroundEnabled = false
            self.backgroundCornerRadius = 28
            self.isDirty = false
            self.loadState = .failed(error.localizedDescription)
            installTimeObserver()
        }
    }

    private func observeWallpaperChanges() {
        wallpaperCancellable = wallpaperManager.$selectedWallpaperID
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.markDirty()
                    self.rebuildPreview(preservingPlayhead: true)
                }
            }
    }

    /// Stops listening for wallpaper selection so programmatic restores don't
    /// count as user edits (publisher delivers asynchronously on the main queue).
    private func pauseWallpaperObservation() {
        wallpaperCancellable?.cancel()
        wallpaperCancellable = nil
    }

    private func markDirty() {
        guard !isApplyingUndoRedo else { return }

        // Mutators change state first, then call markDirty. Capture the
        // pre-edit snapshot from `lastCommittedSnapshot` onto the undo stack.
        if let previous = lastCommittedSnapshot {
            let now = Date()
            let coalescing = lastCheckpointTime.map { now.timeIntervalSince($0) < 0.4 } ?? false
            if !coalescing {
                if undoStack.last != previous {
                    undoStack.append(previous)
                    while undoStack.count > Self.maxHistoryDepth {
                        undoStack.removeFirst()
                    }
                }
                redoStack.removeAll(keepingCapacity: true)
            }
            lastCheckpointTime = now
        }

        if !isDirty {
            isDirty = true
        }
        lastCommittedSnapshot = makeEditSnapshot()
        publishHistoryState()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let current = makeEditSnapshot()
        redoStack.append(current)
        while redoStack.count > Self.maxHistoryDepth {
            redoStack.removeFirst()
        }
        applyEditSnapshot(previous)
        lastCommittedSnapshot = previous
        lastCheckpointTime = nil
        publishHistoryState()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        let current = makeEditSnapshot()
        undoStack.append(current)
        while undoStack.count > Self.maxHistoryDepth {
            undoStack.removeFirst()
        }
        applyEditSnapshot(next)
        lastCommittedSnapshot = next
        lastCheckpointTime = nil
        publishHistoryState()
    }

    private func publishHistoryState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func resetEditHistory() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        lastCheckpointTime = nil
        lastCommittedSnapshot = makeEditSnapshot()
        publishHistoryState()
    }

    private func makeEditSnapshot() -> EditSnapshot {
        EditSnapshot(
            clips: clips,
            zoomRanges: zoomRanges,
            selectedClipID: selectedClipID,
            selectedZoomID: selectedZoomID,
            cursorSettings: cursorSettings,
            motionBlurSettings: motionBlurSettings,
            cameraSettings: cameraSettings,
            isBackgroundEnabled: isBackgroundEnabled,
            backgroundCornerRadius: backgroundCornerRadius,
            backgroundPadding: backgroundPadding,
            musicURL: musicURL,
            musicVolume: musicVolume,
            isOriginalAudioMuted: isOriginalAudioMuted,
            wallpaperID: wallpaperManager.selectedWallpaperID,
            isDirty: isDirty
        )
    }

    private func applyEditSnapshot(_ snapshot: EditSnapshot) {
        isApplyingUndoRedo = true
        defer { isApplyingUndoRedo = false }

        clips = snapshot.clips
        zoomRanges = snapshot.zoomRanges
        selectedClipID = snapshot.selectedClipID
        selectedZoomID = snapshot.selectedZoomID
        cursorSettings = snapshot.cursorSettings
        motionBlurSettings = snapshot.motionBlurSettings
        cameraSettings = snapshot.cameraSettings
        isBackgroundEnabled = snapshot.isBackgroundEnabled
        backgroundCornerRadius = snapshot.backgroundCornerRadius
        backgroundPadding = snapshot.backgroundPadding
        musicVolume = snapshot.musicVolume
        isOriginalAudioMuted = snapshot.isOriginalAudioMuted
        isDirty = snapshot.isDirty

        // Wallpaper: pause observation so selection doesn't create a new undo entry.
        pauseWallpaperObservation()
        if let id = snapshot.wallpaperID,
           let wallpaper = wallpaperManager.wallpaper(withID: id) {
            wallpaperManager.selectWallpaper(wallpaper)
        }
        observeWallpaperChanges()

        saveCameraSettings()
        refreshProcessedCursorTrack()

        let musicTarget = snapshot.musicURL
        if musicURL != musicTarget {
            if let musicTarget {
                Task { @MainActor in
                    await self.loadMusic(from: musicTarget)
                    self.rebuildTimelineCursorData()
                    self.duration = self.timelineClips.last?.end ?? self.duration
                    self.rebuildPreview(preservingPlayhead: true)
                }
                return
            } else {
                musicURL = nil
                musicAsset = nil
                musicSourceTrack = nil
                musicError = nil
            }
        }

        rebuildTimelineCursorData()
        duration = timelineClips.last?.end ?? duration
        rebuildPreview(preservingPlayhead: true)
    }

    deinit {
        playheadPollTimer?.invalidate()
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
        let base: String
        if let projectURL {
            base = projectURL.deletingPathExtension().lastPathComponent
        } else {
            base = sourceURL.deletingPathExtension().lastPathComponent
        }
        return isDirty ? "\(base)*" : base
    }

    var canSaveProject: Bool {
        loadState == .ready
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing || player.rate > 0 {
            player.pause()
            isPlaying = false
            stopPlayheadPolling()
        } else {
            if playhead >= duration - 0.01 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
            startPlayheadPolling()
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
        ) { [weak self] finished in
            // Seek completion can arrive while screen capture is starving the
            // cooperative MainActor queue — prefer a direct main hop.
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.isSeeking = false
                    if finished {
                        self.syncPlayheadFromPlayer()
                    }
                }
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
        markDirty()
        rebuildTimelineCursorData()
        rebuildPreview(preservingPlayhead: true)
    }

    /// True when the selected V1 segment can be removed (always keep at least one clip).
    var canDeleteSelectedClip: Bool {
        guard let selectedClipID else { return false }
        return clips.count > 1 && clips.contains(where: { $0.id == selectedClipID })
    }

    /// Removes the selected V1 timeline segment and closes the gap.
    func deleteSelectedClip() {
        guard let selectedClipID else { return }
        deleteClip(id: selectedClipID)
    }

    /// Removes a V1 timeline segment. Later segments slide left; zoom ranges are
    /// remapped to the new output timeline. The last remaining clip cannot be deleted.
    func deleteClip(id: UUID) {
        guard clips.count > 1,
              let index = clips.firstIndex(where: { $0.id == id }) else {
            return
        }
        let layouts = timelineClips
        guard index < layouts.count else { return }
        let layout = layouts[index]
        let removedStart = layout.start
        let removedEnd = layout.end
        let removedDuration = layout.duration

        clips.remove(at: index)
        remapZoomRangesRemoving(from: removedStart, to: removedEnd)
        // Drop cursor/click samples that lived only in the deleted source range
        // and retime the rest onto the new composition timeline.
        rebuildTimelineCursorData()
        markDirty()

        if selectedClipID == id {
            if index > 0 {
                selectedClipID = clips[index - 1].id
            } else {
                selectedClipID = clips.first?.id
            }
        }
        selectedZoomID = nil

        // Keep the playhead on the join where the segment was removed.
        if playhead >= removedEnd {
            playhead = max(0, playhead - removedDuration)
        } else if playhead > removedStart {
            playhead = removedStart
        }

        rebuildPreview(preservingPlayhead: true)
    }

    /// Shifts / trims zoom ranges after a timeline segment is deleted.
    private func remapZoomRangesRemoving(from removedStart: Double, to removedEnd: Double) {
        let removedDuration = max(0, removedEnd - removedStart)
        guard removedDuration > 0.000_1 else { return }

        let minimumLength = 0.25
        var remapped: [ZoomRange] = []
        remapped.reserveCapacity(zoomRanges.count)

        for range in zoomRanges {
            // Entirely before the cut — unchanged.
            if range.end <= removedStart + 0.000_1 {
                remapped.append(range)
                continue
            }
            // Entirely after the cut — shift left.
            if range.start >= removedEnd - 0.000_1 {
                var shifted = range
                shifted.start = max(0, range.start - removedDuration)
                shifted.end = max(shifted.start, range.end - removedDuration)
                remapped.append(shifted)
                continue
            }

            // Overlaps the deleted interval — keep only the surviving portion.
            var start = range.start
            var end = range.end
            if start < removedStart && end > removedEnd {
                // Spans the hole: close the gap.
                end -= removedDuration
            } else if start < removedStart {
                // Left overhang only.
                end = removedStart
            } else if end > removedEnd {
                // Right overhang only — lands at the join after the collapse.
                start = removedStart
                end -= removedDuration
            } else {
                // Fully inside the deleted segment.
                continue
            }

            guard end - start >= minimumLength else { continue }
            var trimmed = range
            trimmed.start = max(0, start)
            trimmed.end = end
            remapped.append(trimmed)
        }

        // Drop selection if that zoom range was removed by the remap.
        if let selectedZoomID, !remapped.contains(where: { $0.id == selectedZoomID }) {
            self.selectedZoomID = nil
        }
        zoomRanges = remapped
    }

    /// Maps a composition-timeline time through a single clip's speed change.
    /// Times inside the clip scale with its output duration; times after it shift
    /// by the duration delta so later segments stay locked to their source.
    private func mapOutputTimeForSpeedChange(
        _ time: Double,
        clipStart: Double,
        oldOutputDuration: Double,
        newOutputDuration: Double
    ) -> Double {
        guard oldOutputDuration > 0.000_1 else { return max(0, time) }
        let scale = newOutputDuration / oldOutputDuration
        if abs(scale - 1) < 0.000_1 { return max(0, time) }

        let oldClipEnd = clipStart + oldOutputDuration
        let durationDelta = newOutputDuration - oldOutputDuration

        if time <= clipStart + 0.000_1 {
            return max(0, time)
        }
        if time >= oldClipEnd - 0.000_1 {
            return max(0, time + durationDelta)
        }
        return max(0, clipStart + (time - clipStart) * scale)
    }

    /// Scales / shifts zoom ranges when a clip's speed changes so zooms stay
    /// attached to the same source content (they shrink when you speed up, etc.).
    private func remapZoomRangesForSpeedChange(
        clipStart: Double,
        oldOutputDuration: Double,
        newOutputDuration: Double
    ) {
        guard oldOutputDuration > 0.000_1 else { return }
        let scale = newOutputDuration / oldOutputDuration
        guard abs(scale - 1) >= 0.000_1 else { return }

        // Match composition filtering: keep very short scaled zooms (high speed).
        let minimumLength = 0.08
        var remapped: [ZoomRange] = []
        remapped.reserveCapacity(zoomRanges.count)

        for range in zoomRanges {
            var start = mapOutputTimeForSpeedChange(
                range.start,
                clipStart: clipStart,
                oldOutputDuration: oldOutputDuration,
                newOutputDuration: newOutputDuration
            )
            var end = mapOutputTimeForSpeedChange(
                range.end,
                clipStart: clipStart,
                oldOutputDuration: oldOutputDuration,
                newOutputDuration: newOutputDuration
            )
            if end < start {
                swap(&start, &end)
            }
            guard end - start >= minimumLength else { continue }
            var updated = range
            updated.start = start
            updated.end = end
            remapped.append(updated)
        }

        if let selectedZoomID, !remapped.contains(where: { $0.id == selectedZoomID }) {
            self.selectedZoomID = nil
        }
        zoomRanges = remapped
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
        let newSpeed = max(0.001, speed)
        let oldSpeed = max(0.001, clips[index].speed)
        guard abs(newSpeed - oldSpeed) > 0.000_1 else { return }

        // Capture pre-change layout so zoom (and playhead) can retime with the clip.
        let layouts = timelineClips
        guard index < layouts.count else { return }
        let layout = layouts[index]
        let clipStart = layout.start
        let oldOutputDuration = layout.duration
        let newOutputDuration = clips[index].sourceDuration / newSpeed

        clips[index].speed = newSpeed
        remapZoomRangesForSpeedChange(
            clipStart: clipStart,
            oldOutputDuration: oldOutputDuration,
            newOutputDuration: newOutputDuration
        )
        // Keep the playhead on the same source frame after retime.
        playhead = mapOutputTimeForSpeedChange(
            playhead,
            clipStart: clipStart,
            oldOutputDuration: oldOutputDuration,
            newOutputDuration: newOutputDuration
        )

        markDirty()
        rebuildTimelineCursorData()
        rebuildPreview(preservingPlayhead: true)
    }

    func addZoomRange() {
        // Long enough that entry + exit transitions (~0.85s each) still leave a hold.
        let start = min(max(0, playhead), max(0, duration - 2.5))
        let end = min(duration, start + min(3.2, max(0.8, duration)))
        zoomRanges.append(ZoomRange(start: start, end: end))
        selectedZoomID = zoomRanges.last?.id
        markDirty()
        refreshZoomVideoComposition()
    }

    func updateZoomRange(_ range: ZoomRange) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == range.id }) else { return }
        let minimumLength = min(0.25, max(0.05, duration))
        var updated = zoomRanges[index]
        updated.start = min(max(0, range.start), max(0, duration - minimumLength))
        updated.end = min(duration, max(updated.start + minimumLength, range.end))
        zoomRanges[index] = updated
        markDirty()
        refreshZoomVideoComposition()
    }

    func setZoomAmount(_ amount: Double, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].amount = min(3, max(1, amount))
        markDirty()
        refreshZoomVideoComposition()
    }

    func setZoomEntryAnimation(_ animation: ZoomAnimation, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].entryAnimation = animation
        markDirty()
        refreshZoomVideoComposition()
    }

    func setZoomExitAnimation(_ animation: ZoomAnimation, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].exitAnimation = animation
        markDirty()
        refreshZoomVideoComposition()
    }

    func setZoomFocusMode(_ mode: ZoomFocusMode, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].focusMode = mode
        markDirty()
        refreshZoomVideoComposition()
    }

    func setZoomFocusAnchor(_ anchor: FocusAnchor, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].focusAnchor = anchor
        markDirty()
        refreshZoomVideoComposition()
    }

    func setZoomFocusPadding(_ padding: Double, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].focusPadding = min(0.25, max(0, padding))
        markDirty()
        refreshZoomVideoComposition()
    }

    func setZoomFixedFocusPoint(_ point: CGPoint, for id: UUID) {
        guard let index = zoomRanges.firstIndex(where: { $0.id == id }) else { return }
        zoomRanges[index].fixedFocusPoint = CGPoint(
            x: min(1, max(0, point.x)),
            y: min(1, max(0, point.y))
        )
        markDirty()
        refreshZoomVideoComposition()
    }

    func removeZoomRange(id: UUID) {
        zoomRanges.removeAll { $0.id == id }
        if selectedZoomID == id {
            selectedZoomID = nil
        }
        markDirty()
        refreshZoomVideoComposition()
    }

    func setCursorEnabled(_ enabled: Bool) {
        guard cursorSettings.isEnabled != enabled else { return }
        var settings = cursorSettings
        settings.isEnabled = enabled
        cursorSettings = settings
        markDirty()
        // Preview uses a UI overlay; export bakes the cursor offline.
    }

    func setCameraEnabled(_ enabled: Bool) {
        guard hasCameraVideo, cameraSettings.isEnabled != enabled else { return }
        var settings = cameraSettings
        settings.isEnabled = enabled
        cameraSettings = settings
        markDirty()
        saveCameraSettings()
        rebuildPreview(preservingPlayhead: true)
    }

    func setBackgroundEnabled(_ enabled: Bool) {
        guard isBackgroundEnabled != enabled else { return }
        isBackgroundEnabled = enabled
        markDirty()
        rebuildPreview(preservingPlayhead: true)
    }

    func setBackgroundCornerRadius(_ radius: Double) {
        let clamped = min(120, max(0, radius))
        guard abs(backgroundCornerRadius - clamped) > 0.001 else { return }
        backgroundCornerRadius = clamped
        markDirty()
        rebuildPreview(preservingPlayhead: true)
    }

    func setBackgroundPadding(_ padding: Double) {
        let clamped = min(0.3, max(0, padding))
        guard abs(backgroundPadding - clamped) > 0.0001 else { return }
        backgroundPadding = clamped
        markDirty()
        rebuildPreview(preservingPlayhead: true)
    }

    // MARK: - Music

    /// Lets the user pick a local audio file to mix under the video.
    func chooseMusicFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Music"
        panel.message = "Pick an audio file to use as background music."
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                musicError = "That file doesn't contain an audio track."
                return
            }
            musicAsset = asset
            musicSourceTrack = track
            musicURL = url
            musicError = nil
            markDirty()
            rebuildPreview(preservingPlayhead: true)
        }
    }

    func clearMusic() {
        guard musicURL != nil else { return }
        musicURL = nil
        musicAsset = nil
        musicSourceTrack = nil
        musicError = nil
        markDirty()
        rebuildPreview(preservingPlayhead: true)
    }

    func setMusicVolume(_ volume: Double) {
        let clamped = min(1, max(0, volume))
        guard abs(musicVolume - clamped) > 0.001 else { return }
        musicVolume = clamped
        markDirty()
        refreshAudioMix()
    }

    func setOriginalAudioMuted(_ muted: Bool) {
        guard isOriginalAudioMuted != muted else { return }
        isOriginalAudioMuted = muted
        markDirty()
        refreshAudioMix()
    }

    /// Re-applies volume settings to the live player item without rebuilding
    /// the composition (safe for slider drags).
    private func refreshAudioMix() {
        guard let item = player.currentItem,
              let composition = item.asset as? AVMutableComposition else { return }
        item.audioMix = makeAudioMix(for: composition)
    }

    /// Volume params for every audio track: music gets `musicVolume`, original
    /// recording audio is silenced when muted.
    private func makeAudioMix(for composition: AVMutableComposition) -> AVMutableAudioMix? {
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }
        let parameters = audioTracks.map { track -> AVMutableAudioMixInputParameters in
            let params = AVMutableAudioMixInputParameters(track: track)
            if track.trackID == compositionMusicTrackID {
                params.setVolume(Float(musicVolume), at: .zero)
            } else if isOriginalAudioMuted {
                params.setVolume(0, at: .zero)
            }
            return params
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    func setCameraCorner(_ corner: CameraCorner) {
        guard cameraSettings.corner != corner else { return }
        var settings = cameraSettings
        settings.corner = corner
        cameraSettings = settings
        markDirty()
        saveCameraSettings()
        rebuildPreview(preservingPlayhead: true)
    }

    func setCameraSize(_ size: Double) {
        let clamped = min(0.45, max(0.08, size))
        guard abs(cameraSettings.size - clamped) > 0.001 else { return }
        var settings = cameraSettings
        settings.size = clamped
        cameraSettings = settings
        markDirty()
        saveCameraSettings()
        rebuildPreview(preservingPlayhead: true)
    }

    func setCursorStyle(_ style: CursorStyle) {
        guard cursorSettings.style != style else { return }
        var settings = cursorSettings
        settings.style = style
        cursorSettings = settings
        markDirty()
    }

    func setCursorMotion(_ motion: CursorMotionStyle) {
        guard cursorSettings.motion != motion else { return }
        var settings = cursorSettings
        settings.motion = motion
        cursorSettings = settings
        markDirty()
        refreshProcessedCursorTrack()
        // Motion also drives zoom focus, so rebuild the player composition.
        rebuildPreview(preservingPlayhead: true)
    }

    func setCursorSize(_ size: Double) {
        let clamped = min(4, max(0.6, size))
        guard abs(cursorSettings.size - clamped) > 0.001 else { return }
        var settings = cursorSettings
        settings.size = clamped
        cursorSettings = settings
        markDirty()
    }

    func setCursorClickEffect(_ effect: CursorClickEffect) {
        guard cursorSettings.clickEffect != effect else { return }
        var settings = cursorSettings
        settings.clickEffect = effect
        cursorSettings = settings
        markDirty()
    }

    func setCursorHideWhenTyping(_ enabled: Bool) {
        guard cursorSettings.hideWhenTyping != enabled else { return }
        var settings = cursorSettings
        settings.hideWhenTyping = enabled
        cursorSettings = settings
        markDirty()
        // Preview reads segments live; export passes them via CursorRenderData.
    }

    func setMotionBlurEnabled(_ enabled: Bool) {
        guard motionBlurSettings.isEnabled != enabled else { return }
        var settings = motionBlurSettings
        settings.isEnabled = enabled
        motionBlurSettings = settings
        markDirty()
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
        markDirty()
        if settings.isEnabled, settings.applyToZoom {
            rebuildPreview(preservingPlayhead: true)
        }
    }

    func setMotionBlurApplyToCursor(_ enabled: Bool) {
        guard motionBlurSettings.applyToCursor != enabled else { return }
        var settings = motionBlurSettings
        settings.applyToCursor = enabled
        motionBlurSettings = settings
        markDirty()
        // Cursor trail is a live overlay — no composition rebuild.
    }

    func setMotionBlurApplyToZoom(_ enabled: Bool) {
        guard motionBlurSettings.applyToZoom != enabled else { return }
        var settings = motionBlurSettings
        settings.applyToZoom = enabled
        motionBlurSettings = settings
        markDirty()
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
            pointScale: Double(cursorPointPixelScale(renderSize: renderSize)),
            clickScale: cursorSettings.clickEffect.shrinkScale(at: time, clickTimes: clickEvents.map(\.time)),
            clickEffect: cursorSettings.clickEffect,
            clickProgress: clickProgress,
            typingOpacity: cursorTypingOpacity(at: time)
        )
    }

    /// Visibility multiplier from "hide when typing" (1 when the option is off).
    private func cursorTypingOpacity(at time: Double) -> Double {
        guard cursorSettings.hideWhenTyping, !typingHiddenSegments.isEmpty else { return 1 }
        return CursorTypingHider.opacity(at: time, in: typingHiddenSegments)
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
        markDirty()
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
        panel.nameFieldStringValue = "\(exportBaseTitle) Edited.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        export(to: outputURL)
    }

    private var exportBaseTitle: String {
        if let projectURL {
            return projectURL.deletingPathExtension().lastPathComponent
        }
        return sourceURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Project save / load

    func saveProject() {
        guard canSaveProject else { return }
        if let projectURL {
            performSave(to: projectURL)
        } else {
            saveProjectAs()
        }
    }

    func saveProjectAs() {
        guard canSaveProject else { return }
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.message = "Save this recording and all edit settings as a viewio project."
        panel.nameFieldStringValue = "\(exportBaseTitle).\(ViewioProject.pathExtension)"
        panel.allowedContentTypes = [.viewioProject]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let projectURL = url.pathExtension.lowercased() == ViewioProject.pathExtension
            ? url
            : url.appendingPathExtension(ViewioProject.pathExtension)
        performSave(to: projectURL)
    }

    func dismissProjectSaveError() {
        projectSaveError = nil
    }

    private func performSave(to projectURL: URL) {
        do {
            let wallpaperRef = currentWallpaperRef()
            let customWallpaper = currentCustomWallpaper()
            var document = ViewioProjectDocument(
                version: ViewioProjectDocument.currentVersion,
                captureMode: captureMode,
                clips: clips,
                zoomRanges: zoomRanges,
                cursorSettings: cursorSettings,
                motionBlurSettings: motionBlurSettings,
                cameraSettings: cameraSettings,
                isBackgroundEnabled: isBackgroundEnabled,
                backgroundCornerRadius: backgroundCornerRadius,
                backgroundPadding: backgroundPadding,
                wallpaper: wallpaperRef,
                musicRelativePath: nil,
                musicVolume: musicVolume,
                isOriginalAudioMuted: isOriginalAudioMuted
            )

            document = try ViewioProject.save(
                to: projectURL,
                sourceMediaURL: sourceURL,
                document: document,
                musicSourceURL: musicURL,
                customWallpaperURL: customWallpaper?.localURL,
                customWallpaperID: customWallpaper?.id
            )

            self.projectURL = projectURL
            sourceURL = ViewioProject.screenMediaURL(in: projectURL)
            if let relative = document.musicRelativePath {
                musicURL = projectURL.appendingPathComponent(relative)
            }
            if case let .custom(relativePath, id) = document.wallpaper {
                let url = projectURL.appendingPathComponent(relativePath)
                // Pause observation so the async wallpaper publisher can't re-dirty
                // a project we just saved.
                pauseWallpaperObservation()
                wallpaperManager.restoreProjectWallpaper(
                    bundledID: nil,
                    customURL: url,
                    customID: id
                )
                observeWallpaperChanges()
            }
            isDirty = false
            lastCommittedSnapshot = makeEditSnapshot()
            publishHistoryState()
            projectSaveError = nil
            Task {
                await relinkSourceMedia()
                onProjectSaved?(projectURL)
            }
        } catch {
            projectSaveError = error.localizedDescription
        }
    }

    /// Rebinds AVAssets to `sourceURL` after a project save (media may have moved).
    private func relinkSourceMedia() async {
        let asset = AVURLAsset(url: sourceURL)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let videoTrack = videoTracks.first else { return }
            sourceAsset = asset
            sourceVideoTrack = videoTrack
            sourceAudioTracks = audioTracks
            sourceCursorTrack = loadCursorTrack()
            sourceClickEvents = loadClickEvents()
            sourceKeyEvents = loadKeyEvents()
            hasCursorData = !sourceCursorTrack.isEmpty
            hasKeyData = !sourceKeyEvents.isEmpty
            let camera = await loadCameraTrack()
            cameraAsset = camera.0
            cameraVideoTrack = camera.1
            cameraDuration = camera.2
            cameraNaturalSize = camera.3
            cameraPreferredTransform = camera.4
            // Keep editor cameraSettings; sidecar was just written from them.
            hasCameraVideo = camera.1 != nil
            if let musicURL {
                await loadMusic(from: musicURL)
            }
            rebuildTimelineCursorData()
            rebuildPreview(preservingPlayhead: true)
        } catch {
            // Keep playing previous in-memory composition if relink fails.
        }
    }

    private func currentWallpaperRef() -> ProjectWallpaperRef? {
        guard let id = wallpaperManager.selectedWallpaperID,
              let wallpaper = wallpaperManager.wallpaper(withID: id) else {
            return nil
        }
        if let resourceURL = Bundle.main.resourceURL,
           wallpaper.localURL.standardizedFileURL.path.hasPrefix(resourceURL.standardizedFileURL.path) {
            return .bundled(id: id)
        }
        return .custom(relativePath: "", id: id)
    }

    private func currentCustomWallpaper() -> WallpaperManager.Wallpaper? {
        guard let id = wallpaperManager.selectedWallpaperID,
              let wallpaper = wallpaperManager.wallpaper(withID: id) else {
            return nil
        }
        if case .custom = currentWallpaperRef() {
            return wallpaper
        }
        return nil
    }

    private func applyProjectDocument(_ document: ViewioProjectDocument) async {
        // Pause wallpaper observation for the whole restore. `$selectedWallpaperID`
        // delivers on the next main-queue turn; if we only briefly suppress dirty,
        // that late delivery marks a freshly opened project as edited.
        pauseWallpaperObservation()

        clips = document.clips.isEmpty
            ? clips
            : document.clips
        selectedClipID = clips.first?.id
        zoomRanges = document.zoomRanges
        selectedZoomID = zoomRanges.first?.id
        cursorSettings = document.cursorSettings
        motionBlurSettings = document.motionBlurSettings
        cameraSettings = document.cameraSettings
        isBackgroundEnabled = document.isBackgroundEnabled
        backgroundCornerRadius = document.backgroundCornerRadius
        backgroundPadding = document.backgroundPadding
        musicVolume = document.musicVolume
        isOriginalAudioMuted = document.isOriginalAudioMuted

        if let projectURL {
            switch document.wallpaper {
            case let .bundled(id):
                wallpaperManager.restoreProjectWallpaper(
                    bundledID: id,
                    customURL: nil,
                    customID: nil
                )
            case let .custom(relativePath, id):
                let url = projectURL.appendingPathComponent(relativePath)
                wallpaperManager.restoreProjectWallpaper(
                    bundledID: nil,
                    customURL: url,
                    customID: id
                )
            case nil:
                break
            }

            if let relative = document.musicRelativePath {
                let url = projectURL.appendingPathComponent(relative)
                await loadMusic(from: url)
            }
        }

        rebuildTimelineCursorData()
        duration = timelineClips.last?.end ?? duration
        rebuildPreview(preservingPlayhead: false)
        isDirty = false
        // Re-subscribe after restore; dropFirst ignores the restored selection.
        observeWallpaperChanges()
        resetEditHistory()
    }

    private func loadMusic(from url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            musicError = "Couldn’t load the project music file."
            return
        }
        musicAsset = asset
        musicSourceTrack = track
        musicURL = url
        musicError = nil
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
                cursorCaptureSizePoints = file.captureSizePoints
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

    private func loadKeyEvents() -> [KeyEvent] {
        let keysURL = sourceURL.deletingPathExtension().appendingPathExtension("keys.json")
        guard FileManager.default.fileExists(atPath: keysURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: keysURL)
            return try JSONDecoder().decode([KeyEvent].self, from: data)
        } catch {
            print("Failed to load key events: \(error)")
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
            sourceCursorTrack = loadCursorTrack()
            sourceClickEvents = loadClickEvents()
            sourceKeyEvents = loadKeyEvents()
            hasCursorData = !sourceCursorTrack.isEmpty
            hasKeyData = !sourceKeyEvents.isEmpty

            (cameraAsset, cameraVideoTrack, cameraDuration, cameraNaturalSize, cameraPreferredTransform, cameraSettings) = await loadCameraTrack()
            hasCameraVideo = cameraVideoTrack != nil

            if let document = pendingDocument {
                pendingDocument = nil
                // Default cursor enablement before applying saved settings.
                var settings = cursorSettings
                settings.isEnabled = hasCursorData
                cursorSettings = settings
                clips = [EditClip(sourceStart: 0, sourceEnd: seconds)]
                selectedClipID = clips.first?.id
                rebuildTimelineCursorData()
                duration = seconds
                loadState = .ready
                await applyProjectDocument(document)
            } else {
                // Default custom cursor on when we have track data (system cursor is hidden on record).
                var settings = cursorSettings
                settings.isEnabled = hasCursorData
                cursorSettings = settings

                // Detect the window corner radius from black pixels at the corners.
                if captureMode == .window,
                   let detectedRadius = await detectWindowCornerRadius(asset: asset) {
                    backgroundCornerRadius = detectedRadius
                }

                clips = [EditClip(sourceStart: 0, sourceEnd: seconds)]
                selectedClipID = clips.first?.id
                rebuildTimelineCursorData()
                duration = seconds
                loadState = .ready
                rebuildPreview(preservingPlayhead: false)
                resetEditHistory()
            }

            Task {
                await generateTimelineThumbnails(asset: asset, duration: seconds)
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Generates evenly spaced frame thumbnails for the timeline.
    private func generateTimelineThumbnails(asset: AVURLAsset, duration: Double) async {
        guard duration > 0.1 else { return }
        let count = max(40, min(120, Int(duration / 0.25)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 320, height: 180)

        var images: [NSImage] = []
        var times: [Double] = []

        for index in 0..<count {
            let time = duration * Double(index) / Double(count)
            do {
                let cgImage = try generator.copyCGImage(
                    at: CMTime(seconds: time, preferredTimescale: 600),
                    actualTime: nil
                )
                images.append(NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height)))
                times.append(time)
            } catch {
                continue
            }
        }

        timelineThumbnails = images
        timelineThumbnailTimes = times
    }

    /// Returns the thumbnails that fall within a clip's source time range.
    func thumbnailsForClip(_ clip: EditClip) -> [NSImage] {
        let range = clip.sourceStart...clip.sourceEnd
        return timelineThumbnailTimes.enumerated().compactMap { index, time in
            range.contains(time) ? timelineThumbnails[index] : nil
        }
    }

    private func rebuildPreview(preservingPlayhead: Bool) {
        // Core Animation cursor tool is export-only — never attach it to AVPlayerItem.
        guard let build = makeComposition(includeCursorOverlay: false) else { return }
        let previousPlayhead = preservingPlayhead ? min(playhead, build.duration) : 0

        let item = AVPlayerItem(asset: build.composition)
        item.videoComposition = build.videoComposition
        item.audioMix = makeAudioMix(for: build.composition)
        // Full-quality preview decode (avoid soft low-bitrate streaming defaults).
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = CGSize(width: 8192, height: 8192)
        player.replaceCurrentItem(with: item)
        previewCompositionVideoTrack = build.videoTrack
        previewCompositionCameraTrack = build.cameraTrack
        previewCompositionDuration = CMTime(seconds: build.duration, preferredTimescale: 600)
        duration = build.duration
        videoRenderSize = build.renderSize
        playhead = previousPlayhead
        isPlaying = false
        stopPlayheadPolling()
        player.pause()

        if previousPlayhead > 0 {
            seek(to: previousPlayhead)
        }
    }

    /// Zoom-only changes (range bounds, amount, animation style) touch just the
    /// video composition's transform keyframes — the composition's tracks stay
    /// identical. Swapping `videoComposition` on the live player item applies
    /// them without a decoder restart, so dragging a zoom edge no longer
    /// flickers (a full item rebuild is only needed when tracks change).
    private func refreshZoomVideoComposition() {
        guard let item = player.currentItem,
              let compositionTrack = previewCompositionVideoTrack,
              let sourceVideoTrack else {
            rebuildPreview(preservingPlayhead: true)
            return
        }
        item.videoComposition = makeVideoComposition(
            compositionTrack: compositionTrack,
            cameraTrack: previewCompositionCameraTrack,
            sourceTrack: sourceVideoTrack,
            duration: previewCompositionDuration,
            includeCursorOverlay: false
        )
    }

    private func makeComposition(
        includeCursorOverlay: Bool
    ) -> (
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        videoTrack: AVMutableCompositionTrack,
        cameraTrack: AVMutableCompositionTrack?,
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

        // Music bed: loop the picked track so it covers the whole composition.
        compositionMusicTrackID = nil
        if let musicSourceTrack,
           let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicDuration = musicSourceTrack.timeRange.duration
            if musicDuration > .zero {
                var musicCursor = CMTime.zero
                while musicCursor < cursor {
                    let remaining = cursor - musicCursor
                    let segment = CMTimeRange(start: .zero, duration: CMTimeMinimum(remaining, musicDuration))
                    try? musicTrack.insertTimeRange(segment, of: musicSourceTrack, at: musicCursor)
                    musicCursor = musicCursor + segment.duration
                }
            }
            compositionMusicTrackID = musicTrack.trackID
        }

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
            compositionVideoTrack,
            compositionCameraTrack,
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
        // Tag as BT.709 so players interpret the sRGB-space frames consistently
        // instead of guessing the color space (washed-out playback).
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let selectedWallpaperURL = wallpaperManager.selectedWallpaperID
            .flatMap { wallpaperManager.wallpaper(withID: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.localURL.path) ? $0.localURL : nil }
        let includeWallpaper = isBackgroundEnabled && selectedWallpaperURL != nil
        let applyRoundedCorners = isBackgroundEnabled && captureMode == .window

        // When a wallpaper is active, shrink the video by the padding setting
        // and center it so the background image shows around the edges.
        let baseTransform: CGAffineTransform
        if includeWallpaper {
            let placementScale = CGFloat(1 - 2 * backgroundPadding)
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

        // The cursor must go through the custom compositor as well:
        // AVVideoCompositionCoreAnimationTool is ignored whenever a custom
        // compositor renders the frames (camera / wallpaper / blur / cursor).
        let includeCursor = includeCursorOverlay && cursorSettings.isEnabled && hasCursorData
        if includeCamera || zoomBlur > 0.001 || includeWallpaper || includeCursor {
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
                cornerRadius: CGFloat(backgroundCornerRadius),
                cursor: includeCursor ? makeCursorRenderData(renderSize: renderSize) : nil
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
                scale = zoomScale(
                    at: time,
                    range: range,
                    transition: transition,
                    compositionDuration: duration
                )
                let cursorFocus = zoomFocus(at: time, in: range)
                // The sample's focus is the zoom pivot (zoom-blur epicenter).
                focus = range.focusMode == .fixedPoint ? range.fixedFocusPoint : cursorFocus
                zoom = zoomTransform(
                    renderSize: renderSize,
                    scale: scale,
                    center: cursorFocus,
                    targetAmount: CGFloat(min(3, max(1, range.amount))),
                    range: range
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
    }

    /// Maps original recording-space cursor/click samples onto the current
    /// composition timeline using `clips`. Samples that fall only inside a
    /// deleted section are dropped; later samples shift earlier so playhead
    /// time matches the edited video (including speed changes).
    private func rebuildTimelineCursorData() {
        guard !sourceCursorTrack.isEmpty || !sourceClickEvents.isEmpty || !sourceKeyEvents.isEmpty,
              !clips.isEmpty else {
            cursorTrack = []
            clickEvents = []
            keyEventTimes = []
            typingHiddenSegments = []
            preciseCursorTrack = []
            return
        }

        var mappedTrack: [CursorPosition] = []
        var mappedClicks: [ClickEvent] = []
        var mappedKeys: [Double] = []
        mappedTrack.reserveCapacity(sourceCursorTrack.count)
        mappedClicks.reserveCapacity(sourceClickEvents.count)
        mappedKeys.reserveCapacity(sourceKeyEvents.count)

        var outputTime = 0.0
        for (clipIndex, clip) in clips.enumerated() {
            let isLast = clipIndex == clips.count - 1
            let sourceStart = clip.sourceStart
            let sourceEnd = clip.sourceEnd
            let speed = max(0.001, clip.speed)

            for sample in sourceCursorTrack {
                guard sourceTime(sample.time, isIn: sourceStart, sourceEnd, includeEnd: isLast) else {
                    continue
                }
                let mappedTime = outputTime + (sample.time - sourceStart) / speed
                mappedTrack.append(
                    CursorPosition(time: mappedTime, x: sample.x, y: sample.y)
                )
            }

            for click in sourceClickEvents {
                guard sourceTime(click.time, isIn: sourceStart, sourceEnd, includeEnd: isLast) else {
                    continue
                }
                let mappedTime = outputTime + (click.time - sourceStart) / speed
                mappedClicks.append(ClickEvent(time: mappedTime, button: click.button))
            }

            for key in sourceKeyEvents {
                guard sourceTime(key.time, isIn: sourceStart, sourceEnd, includeEnd: isLast) else {
                    continue
                }
                mappedKeys.append(outputTime + (key.time - sourceStart) / speed)
            }

            outputTime += clip.outputDuration
        }

        mappedTrack.sort { $0.time < $1.time }
        mappedClicks.sort { $0.time < $1.time }
        mappedKeys.sort()
        cursorTrack = mappedTrack
        clickEvents = mappedClicks
        keyEventTimes = mappedKeys
        refreshProcessedCursorTrack()
        refreshTypingHiddenSegments()
    }

    private func refreshTypingHiddenSegments() {
        let totalDuration = clips.reduce(0) { $0 + $1.outputDuration }
        typingHiddenSegments = CursorTypingHider.segments(
            keyTimes: keyEventTimes,
            cursorTrack: cursorTrack,
            duration: totalDuration
        )
    }

    /// Inclusive start; end is exclusive for mid clips so a cut boundary sample
    /// belongs to only one segment.
    private func sourceTime(
        _ time: Double,
        isIn sourceStart: Double,
        _ sourceEnd: Double,
        includeEnd: Bool
    ) -> Bool {
        if time < sourceStart - 0.000_1 { return false }
        if includeEnd {
            return time <= sourceEnd + 0.000_1
        }
        return time < sourceEnd
    }

    /// Pixels per on-screen point for the recording (≈2 on Retina), so the
    /// redrawn cursor matches the real cursor's captured size.
    private func cursorPointPixelScale(renderSize: CGSize) -> CGFloat {
        guard let capturePoints = cursorCaptureSizePoints, capturePoints.width > 1 else { return 1 }
        return renderSize.width / capturePoints.width
    }

    /// Plain-data cursor description for the compositor's export render.
    private func makeCursorRenderData(renderSize: CGSize) -> CursorRenderData? {
        guard cursorSettings.isEnabled, hasCursorData, !preciseCursorTrack.isEmpty,
              let image = CursorArtwork.cgImage(style: cursorSettings.style) else { return nil }
        return CursorRenderData(
            image: image,
            hotspot: CursorArtwork.hotspot(for: cursorSettings.style),
            size: 16 * CGFloat(cursorSettings.size) * cursorPointPixelScale(renderSize: renderSize),
            track: preciseCursorTrack,
            clickTimes: clickEvents.map(\.time),
            clickEffect: cursorSettings.clickEffect,
            trailStrength: motionBlurSettings.cursorStrength,
            trailLookback: motionBlurSettings.cursorTrailDuration,
            trailGhosts: max(0, motionBlurSettings.cursorTrailSamples - 1),
            hiddenSegments: cursorSettings.hideWhenTyping ? typingHiddenSegments : []
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

    /// Builds a transform that scales the frame and places the zoom anchor
    /// according to the range's focus mode. `center` is the cursor position in
    /// normalized video space (origin top-left).
    private func zoomTransform(
        renderSize: CGSize,
        scale: CGFloat,
        center: CGPoint,
        targetAmount: CGFloat,
        range: ZoomRange
    ) -> CGAffineTransform {
        let safeScale = CGFloat(min(3, max(1, Double(scale))))
        guard safeScale > 1.0001,
              renderSize.width > 1,
              renderSize.height > 1 else {
            return .identity
        }

        let rawX = Double(center.x.isFinite ? center.x : 0.5)
        let rawY = Double(center.y.isFinite ? center.y : 0.5)

        // Anchor: the video point the zoom pivots around; target: where that
        // point lands in the output frame (both in pixels, origin top-left).
        let anchor: CGPoint
        let target: CGPoint
        switch range.focusMode {
        case .followCursor:
            // Cursor stays exactly where it is; content magnifies around it.
            anchor = CGPoint(x: rawX * renderSize.width, y: rawY * renderSize.height)
            target = anchor
        case .anchor:
            // Cursor is pinned to the chosen frame anchor (with padding).
            anchor = CGPoint(x: rawX * renderSize.width, y: rawY * renderSize.height)
            target = range.focusAnchor.targetPoint(in: renderSize, padding: range.focusPadding)
        case .fixedPoint:
            // Cursor is ignored; the viewport centers on the fixed point.
            let fx = min(1, max(0, Double(range.fixedFocusPoint.x.isFinite ? range.fixedFocusPoint.x : 0.5)))
            let fy = min(1, max(0, Double(range.fixedFocusPoint.y.isFinite ? range.fixedFocusPoint.y : 0.5)))
            anchor = CGPoint(x: fx * renderSize.width, y: fy * renderSize.height)
            target = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
        }

        var tx = target.x - safeScale * anchor.x
        var ty = target.y - safeScale * anchor.y
        // Keep the scaled video covering the whole frame — never reveal beyond
        // the video edges. For followCursor this is already satisfied, and for
        // pinned modes it slides the viewport along the edges instead of
        // showing black when the focus sits near the border.
        tx = min(0, max((1 - safeScale) * renderSize.width, tx))
        ty = min(0, max((1 - safeScale) * renderSize.height, ty))
        return CGAffineTransform(a: safeScale, b: 0, c: 0, d: safeScale, tx: tx, ty: ty)
    }

    /// Normalized cursor position at the playhead (0...1, origin top-left) —
    /// shown on the fixed-focus mini map in the zoom inspector.
    var cursorPositionAtPlayhead: CGPoint {
        preciseCursorPosition(at: playhead)
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

    private func zoomScale(
        at time: Double,
        range: ZoomRange,
        transition: Double,
        compositionDuration: Double
    ) -> CGFloat {
        let amount = CGFloat(min(3, max(1, range.amount)))
        let relativeTime = time - range.start
        let rangeDuration = max(0.001, range.end - range.start)

        // When a zoom is pinned to the timeline start, there is no pre-zoom
        // content to ease in from — hold full zoom from frame 0.
        // When pinned to the end, hold full zoom through the last frame.
        let pinEntry = range.start <= 0.001
        let pinExit = range.end >= compositionDuration - 0.001
        let entryTransition = pinEntry ? 0 : transition
        let exitTransition = pinExit ? 0 : transition

        if entryTransition > 0, relativeTime < entryTransition {
            let progress = relativeTime / entryTransition
            let eased = range.entryAnimation.progress(at: progress)
            return 1 + (amount - 1) * CGFloat(eased)
        } else if exitTransition > 0, relativeTime > rangeDuration - exitTransition {
            let progress = (rangeDuration - relativeTime) / exitTransition
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
        renderSize: CGSize,
        compositionDuration: Double
    ) -> CGAffineTransform {
        let scale = zoomScale(
            at: time,
            range: range,
            transition: transition,
            compositionDuration: compositionDuration
        )
        let center = cursorPosition(at: time)
        let zoom = zoomTransform(
            renderSize: renderSize,
            scale: scale,
            center: center,
            targetAmount: CGFloat(min(3, max(1, range.amount))),
            range: range
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
        session.audioMix = makeAudioMix(for: build.composition)
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
        // Best-effort: AVFoundation may stop delivering these under GPU/IOSurface
        // pressure (e.g. recording another window while previewing). Polling is
        // the reliable path for the cursor overlay.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            MainActor.assumeIsolated {
                self.syncPlayheadFromPlayer(seconds: seconds)
            }
        }
    }

    private func startPlayheadPolling() {
        guard playheadPollTimer == nil else { return }
        // `.common` keeps the cursor moving during tracking loops and while
        // ScreenCaptureKit / recording timers dominate the default mode.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.syncPlayheadFromPlayer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadPollTimer = timer
    }

    private func stopPlayheadPolling() {
        playheadPollTimer?.invalidate()
        playheadPollTimer = nil
    }

    /// Reads `AVPlayer.currentTime()` so the overlay stays live even when
    /// `addPeriodicTimeObserver` stalls (common while another window records).
    private func syncPlayheadFromPlayer(seconds: Double? = nil) {
        guard !isSeeking else { return }
        let t = seconds ?? player.currentTime().seconds
        guard t.isFinite else { return }
        let next = min(duration, max(0, t))
        if abs(playhead - next) > 0.000_8 {
            playhead = next
        }

        let playing = player.timeControlStatus == .playing || player.rate > 0.01
        if isPlaying != playing {
            isPlaying = playing
        }
        if playing {
            startPlayheadPolling()
        } else {
            stopPlayheadPolling()
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
