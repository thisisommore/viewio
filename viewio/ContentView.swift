//
//  ContentView.swift
//  viewio
//

import AppKit
import AVKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        Group {
            switch recorder.state {
            case .idle:
                RecordingStartView(
                    recorder: recorder,
                    isPreparing: false,
                    onRecord: recorder.startRecording
                )

            case .preparing:
                RecordingProgressView(
                    recorder: recorder,
                    elapsed: recorder.elapsed,
                    isStopping: false,
                    onStop: recorder.stopRecording
                )

            case .recording:
                RecordingProgressView(
                    recorder: recorder,
                    elapsed: recorder.elapsed,
                    isStopping: false,
                    onStop: recorder.stopRecording
                )

            case .stopping:
                RecordingProgressView(
                    recorder: recorder,
                    elapsed: recorder.elapsed,
                    isStopping: true,
                    onStop: {}
                )

            case let .finished(url):
                EditorWorkspace(sourceURL: url, captureMode: recorder.captureMode)
                    .id(url)

            case let .failed(message):
                RecordingStartView(
                    recorder: recorder,
                    isPreparing: false,
                    errorMessage: message,
                    onRecord: recorder.startRecording,
                    onDismissError: recorder.dismissError
                )
            }
        }
        .navigationTitle("viewio")
        .animation(.snappy(duration: 0.28), value: recorder.isRecording)
        .frame(minWidth: 960, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct RecordingStartView: View {
    @ObservedObject var recorder: RecordingController
    let isPreparing: Bool
    var errorMessage: String?
    let onRecord: () -> Void
    var onDismissError: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let errorMessage {
                        errorBanner(message: errorMessage)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("New Recording")
                            .font(.title2.bold())
                        Text("Choose what to capture — everything else is ready to go.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    CaptureSourceSection(recorder: recorder, isPreparing: isPreparing)

                    RecordingSettingsSection(recorder: recorder, isPreparing: isPreparing)
                }
                .padding(32)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack(spacing: 16) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Button("Start Recording", action: onRecord)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPreparing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    /// One-line recap of the current setup shown next to the Start button.
    private var summary: String {
        var parts: [String] = [recorder.captureMode.title]
        if recorder.pickedFilter != nil {
            parts.append(recorder.pickedContentName ?? "System picker selection")
        } else {
            switch recorder.captureMode {
            case .display:
                if let display = recorder.availableDisplays.first(where: { $0.id == recorder.selectedDisplayID })
                    ?? recorder.availableDisplays.first {
                    parts.append(display.name)
                }
            case .window:
                if let window = recorder.availableWindows.first(where: { $0.id == recorder.selectedWindowID }) {
                    parts.append(window.appName)
                }
            }
        }
        parts.append(recorder.selectedResolution.title)
        parts.append(recorder.selectedFrameRate.title)
        if recorder.captureSystemAudio {
            parts.append("System audio")
        }
        if recorder.captureMicrophone, let micID = recorder.selectedMicrophoneID,
           let mic = recorder.availableMicrophones.first(where: { $0.id == micID }) {
            parts.append(mic.name)
        }
        if recorder.captureCamera {
            parts.append("Camera")
        }
        return parts.joined(separator: " · ")
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("Open Settings") {
                if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            Button("Dismiss") {
                onDismissError?()
            }
        }
        .font(.callout)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.15))
        }
    }
}

private struct RecordButtonStyle: ButtonStyle {
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88)
            .background {
                Rectangle()
                    .fill(isDisabled ? Color.red.opacity(0.4) : Color.red.opacity(configuration.isPressed ? 0.85 : 1))
            }
            .contentShape(Rectangle())
    }
}

private struct CaptureSourceSection: View {
    @ObservedObject var recorder: RecordingController
    let isPreparing: Bool

    var body: some View {
        Button(action: recorder.presentContentPicker) {
            HStack(spacing: 12) {
                Image(systemName: recorder.captureMode == .window ? "macwindow" : "display")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(recorder.captureMode.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("Choose…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SourcePickerCardStyle())
        .disabled(isPreparing)
    }

    private var selectionName: String {
        if recorder.pickedFilter != nil {
            return recorder.pickedContentName
                ?? (recorder.captureMode == .window ? "Selected Window" : "Selected Display")
        }
        switch recorder.captureMode {
        case .display:
            if let display = recorder.availableDisplays.first(where: { $0.id == recorder.selectedDisplayID })
                ?? recorder.availableDisplays.first {
                return display.name
            }
            return "Main Display"
        case .window:
            if let window = recorder.availableWindows.first(where: { $0.id == recorder.selectedWindowID }) {
                return "\(window.appName) — \(window.title)"
            }
            return "No window selected"
        }
    }
}

private struct SourcePickerCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.1))
            }
    }
}

private struct RecordingSettingsSection: View {
    @ObservedObject var recorder: RecordingController
    let isPreparing: Bool
    @State private var isRequestingAuthorization = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                SettingsRow(icon: "aspectratio", tint: .blue, title: "Resolution") {
                    Picker(selection: $recorder.selectedResolution) {
                        ForEach(RecordingResolution.allCases) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(isPreparing)
                }

                Divider().padding(.leading, 44)

                SettingsRow(icon: "film", tint: .indigo, title: "Frame Rate") {
                    Picker(selection: $recorder.selectedFrameRate) {
                        ForEach(RecordingFrameRate.allCases) { fps in
                            Text(fps.title).tag(fps)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(isPreparing)
                }

                Divider().padding(.leading, 44)

                SettingsRow(icon: "speaker.wave.2", tint: .pink, title: "System Audio") {
                    Toggle(isOn: $recorder.captureSystemAudio) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isPreparing)
                }

                if !recorder.availableMicrophones.isEmpty {
                    Divider().padding(.leading, 44)

                    SettingsRow(icon: "mic", tint: .orange, title: "Microphone") {
                        Picker(selection: microphoneSelection) {
                            Text("None").tag(String?.none)
                            ForEach(recorder.availableMicrophones) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .disabled(isPreparing)
                    }
                }

                if !recorder.availableCameras.isEmpty {
                    Divider().padding(.leading, 44)

                    SettingsRow(icon: "video", tint: .green, title: "Camera") {
                        Picker(selection: cameraSelection) {
                            Text("Off").tag(String?.none)
                            ForEach(recorder.availableCameras) { device in
                                Text(device.name).tag(Optional(device.id))
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .disabled(isPreparing || isRequestingAuthorization)
                    }
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            Text(resolutionHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            if recorder.captureCamera {
                Text("A picture-in-picture camera overlay will be recorded separately so you can move it after recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Maps the menu picker onto the captureMicrophone/selectedMicrophoneID pair.
    private var microphoneSelection: Binding<String?> {
        Binding(
            get: { recorder.captureMicrophone ? recorder.selectedMicrophoneID : nil },
            set: { newValue in
                if let id = newValue {
                    recorder.captureMicrophone = true
                    recorder.selectedMicrophoneID = id
                } else {
                    recorder.captureMicrophone = false
                    recorder.selectedMicrophoneID = nil
                }
            }
        )
    }

    /// Same mapping for camera, but enabling one requires authorization first.
    private var cameraSelection: Binding<String?> {
        Binding(
            get: { recorder.captureCamera ? recorder.selectedCameraID : nil },
            set: { newValue in
                guard let id = newValue else {
                    recorder.captureCamera = false
                    return
                }
                Task {
                    isRequestingAuthorization = true
                    let granted = await recorder.requestCameraAuthorizationIfNeeded()
                    isRequestingAuthorization = false
                    if granted {
                        recorder.selectedCameraID = id
                        recorder.captureCamera = true
                    }
                }
            }
        )
    }

    private var resolutionHint: String {
        let native = nativeSize
        let out = recorder.selectedResolution.outputSize(forNative: native)
        let isClamped = recorder.selectedResolution != .native
            && abs(out.width - native.width) < 1
            && abs(out.height - native.height) < 1
            && recorder.selectedResolution.maxSize != nil
        if isClamped {
            return String(
                format: "Source is %.0f×%.0f — this preset can’t go higher, so capture stays at native.",
                native.width, native.height
            )
        }
        return String(
            format: "Will capture ≈ %.0f×%.0f (source %.0f×%.0f).",
            out.width, out.height, native.width, native.height
        )
    }

    private var nativeSize: CGSize {
        if let picked = recorder.pickedFilter {
            let scale = CGFloat(picked.pointPixelScale)
            return CGSize(width: picked.contentRect.width * scale, height: picked.contentRect.height * scale)
        }
        if recorder.captureMode == .window {
            guard let window = recorder.availableWindows.first(where: { $0.id == recorder.selectedWindowID })
                    ?? recorder.availableWindows.first else {
                return CGSize(width: 1920, height: 1080)
            }
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            return CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        }
        guard let display = recorder.availableDisplays.first(where: { $0.id == recorder.selectedDisplayID })
                ?? recorder.availableDisplays.first else {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(
            width: CGDisplayPixelsWide(display.id),
            height: CGDisplayPixelsHigh(display.id)
        )
    }
}

private struct SettingsRow<Control: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5))

            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 12)

            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct RecordingProgressView: View {
    @ObservedObject var recorder: RecordingController
    let elapsed: TimeInterval
    let isStopping: Bool
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !isStopping)

                VStack(spacing: 6) {
                    Text(isStopping ? "Finishing recording…" : "Recording your screen")
                        .font(.system(size: 22, weight: .semibold))
                    Text(isStopping ? "Saving your video" : formattedDuration(elapsed))
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if recorder.captureCamera {
                        Text("Camera overlay is shown on the selected display")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onStop) {
                Text(isStopping ? "Stopping…" : "Stop Recording")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(RecordButtonStyle(isDisabled: isStopping))
            .disabled(isStopping)
        }
    }
}

private struct EditorWorkspace: View {
    @StateObject private var model: EditorModel

    init(sourceURL: URL, captureMode: CaptureMode = .display) {
        _model = StateObject(wrappedValue: EditorModel(sourceURL: sourceURL, captureMode: captureMode))
    }

    var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView("Preparing recording…")
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .failed(message):
                ContentUnavailableView(
                    "Couldn’t open recording",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                editor
            }
        }
        .navigationTitle(model.clipTitle)
        .focusedSceneValue(\.exportModel, model)
        .overlay {
            ExportOverlay(state: model.exportState, dismiss: model.dismissExportMessage)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VideoPreview(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ClipInspector(model: model)
                    .frame(width: 268)
            }
            .frame(minHeight: 330)

            Divider()

            TimelineView(model: model)
                .frame(height: 148)

            Divider()

            ZoomLane(model: model)
                .frame(height: 86)
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    @Binding var videoRect: CGRect

    func makeCoordinator() -> Coordinator {
        Coordinator(videoRect: $videoRect)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = TrackingPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        playerView.layer?.minificationFilter = .trilinear
        playerView.layer?.magnificationFilter = .trilinear
        playerView.onVideoRectChange = { rect in
            context.coordinator.updateVideoRect(rect)
        }
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        if let item = player.currentItem {
            item.preferredPeakBitRate = 0
            item.preferredMaximumResolution = CGSize(width: 8192, height: 8192)
        }
        if let tracking = nsView as? TrackingPlayerView {
            tracking.onVideoRectChange = { rect in
                context.coordinator.updateVideoRect(rect)
            }
            tracking.reportVideoRect()
        }
    }

    final class Coordinator {
        var binding: Binding<CGRect>
        init(videoRect: Binding<CGRect>) { binding = videoRect }
        @MainActor
        func updateVideoRect(_ rect: CGRect) {
            if binding.wrappedValue != rect {
                binding.wrappedValue = rect
            }
        }
    }
}

/// Reports the exact `AVPlayerLayer.videoRect` so the cursor overlay lines up
/// with pixels (AVMakeRect alone can be a few points off).
private final class TrackingPlayerView: AVPlayerView {
    var onVideoRectChange: ((CGRect) -> Void)?

    override func layout() {
        super.layout()
        reportVideoRect()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportVideoRect()
    }

    func reportVideoRect() {
        let rect = resolvedVideoRect()
        onVideoRectChange?(rect)
    }

    private func resolvedVideoRect() -> CGRect {
        guard let playerLayer = findPlayerLayer(in: layer) else {
            return bounds
        }
        let video = playerLayer.videoRect
        guard video.width > 1, video.height > 1 else { return bounds }
        // videoRect is in the player layer's space — convert into this view.
        if let superlayer = playerLayer.superlayer, let host = layer {
            return host.convert(video, from: playerLayer)
        }
        return video
    }

    private func findPlayerLayer(in layer: CALayer?) -> AVPlayerLayer? {
        guard let layer else { return nil }
        if let playerLayer = layer as? AVPlayerLayer { return playerLayer }
        for child in layer.sublayers ?? [] {
            if let found = findPlayerLayer(in: child) { return found }
        }
        return nil
    }
}

private struct VideoPreview: View {
    @ObservedObject var model: EditorModel
    @State private var playerVideoRect: CGRect = .zero

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PlayerView(player: model.player, videoRect: $playerVideoRect)
                    .background(Color.black)

                // Live cursor overlay — Core Animation tool cannot run on AVPlayerItem.
                CursorPlayerOverlay(model: model, playerVideoRect: playerVideoRect)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Button {
                    model.seek(to: model.playhead - 10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                .help("Back 10 seconds")

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause" : "Play")

                Button {
                    model.seek(to: model.playhead + 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
                .help("Forward 10 seconds")

                Divider()
                    .frame(height: 16)

                Button {
                    model.cutAtPlayhead()
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .help("Cut at playhead")

                Spacer()

                Text("\(formattedDuration(model.playhead)) / \(formattedDuration(model.duration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.bar)
        }
    }
}

/// Draws the custom cursor on top of the player, aligned to the real video rect.
private struct CursorPlayerOverlay: View {
    @ObservedObject var model: EditorModel
    var playerVideoRect: CGRect

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let render = model.videoRenderSize
            // Prefer the live AVPlayerLayer rect; fall back to aspect-fit math.
            // AVPlayerLayer.videoRect is in CALayer bottom-left coordinates, but
            // this overlay is drawn by SwiftUI which uses top-left coordinates.
            let videoRect: CGRect = {
                if playerVideoRect.width > 2, playerVideoRect.height > 2 {
                    return CGRect(
                        x: playerVideoRect.minX,
                        y: container.height - playerVideoRect.maxY,
                        width: playerVideoRect.width,
                        height: playerVideoRect.height
                    )
                }
                return letterboxedRect(aspect: render, in: container)
            }()

            if let state = model.cursorPreview(at: model.playhead) {
                let cursorSize = 16 * state.size
                let hotspot = CursorArtwork.hotspot(for: state.style)
                let cursorImage = CursorArtwork.image(style: state.style, scale: 2)

                ZStack {
                    ForEach(Array(state.trail.enumerated().reversed()), id: \.offset) { index, sample in
                        let tip = tipPoint(normalized: sample.normalizedPosition, in: videoRect)
                        // Anchor the *hotspot* (tip) at the recorded point — not the image center.
                        let center = CGPoint(
                            x: tip.x + cursorSize * (0.5 - hotspot.x),
                            y: tip.y + cursorSize * (0.5 - hotspot.y)
                        )
                        Image(nsImage: cursorImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: cursorSize, height: cursorSize)
                            .opacity(sample.opacity)
                            .shadow(
                                color: .black.opacity(index == 0 ? 0.2 : 0.06),
                                radius: index == 0 ? 1.2 : 0.4,
                                y: 0.4
                            )
                            .position(center)
                    }

                    if let progress = state.clickProgress, state.clickEffect != .none {
                        let tip = tipPoint(normalized: state.normalizedPosition, in: videoRect)
                        ClickOverlayShape(effect: state.clickEffect, progress: progress)
                            .frame(width: cursorSize * 3.2, height: cursorSize * 3.2)
                            .position(tip)
                    }
                }
                .frame(width: videoRect.width, height: videoRect.height)
                .position(x: videoRect.midX, y: videoRect.midY)
                .clipped()
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }

    private func tipPoint(normalized: CGPoint, in videoRect: CGRect) -> CGPoint {
        // Coordinates are relative to the inner ZStack, whose origin is already
        // at videoRect.minX/minY via its .position(videoRect.mid) frame.
        CGPoint(
            x: min(1, max(0, normalized.x)) * videoRect.width,
            y: min(1, max(0, normalized.y)) * videoRect.height
        )
    }

    private func letterboxedRect(aspect: CGSize, in container: CGSize) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        return AVMakeRect(
            aspectRatio: aspect,
            insideRect: CGRect(origin: .zero, size: container)
        )
    }
}

private struct ClickOverlayShape: View {
    let effect: CursorClickEffect
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let t = min(1, max(0, progress))
            switch effect {
            case .none:
                break
            case .ripple:
                let radius = 6 + CGFloat(t) * min(size.width, size.height) * 0.42
                var path = Path()
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(path, with: .color(.accentColor.opacity(0.85 * (1 - t))), lineWidth: 2)
            case .ring:
                let radius = 8 + CGFloat(t) * min(size.width, size.height) * 0.35
                var path = Path()
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(path, with: .color(.white.opacity(0.9 * (1 - t))), lineWidth: 2.5)
            case .pulse:
                let scale = 1 + CGFloat(sin(t * .pi)) * 0.85
                let radius = 8 * scale
                var path = Path()
                path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.fill(path, with: .color(.accentColor.opacity(0.35 * (1 - t))))
                context.stroke(path, with: .color(.accentColor.opacity(0.9 * (1 - t))), lineWidth: 1.5)
            }
        }
    }
}

private struct ClipInspector: View {
    @ObservedObject var model: EditorModel

    private let speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorTabBar(selection: $model.inspectorTab)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.inspectorTab {
                    case .edit:
                        editTab
                    case .cursor:
                        CursorInspectorPanel(model: model)
                    case .camera:
                        CameraInspectorPanel(model: model)
                    case .background:
                        BackgroundInspectorPanel(model: model)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Divider()
        }
    }

    @ViewBuilder
    private var editTab: some View {
        if let range = model.selectedZoomRange {
            zoomHeader(range: range)
            zoomControls(for: range)
        } else if let selectedClip = model.selectedClip {
            inspectorHeader(title: "CLIP INSPECTOR", subtitle: "Playback speed")
            clipControls(for: selectedClip)
        } else {
            inspectorHeader(title: "CLIP INSPECTOR", subtitle: "Select a clip")
            Text("Click a segment in the V1 lane to adjust it independently.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func inspectorHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.75)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    @ViewBuilder
    private func zoomHeader(range: ZoomRange) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("ZOOM")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(.secondary)
                Text("Zoom range")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            Button {
                model.removeZoomRange(id: range.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func clipControls(for selectedClip: EditClip) -> some View {
        Text(speedLabel(selectedClip.speed))
            .font(.system(size: 30, weight: .medium, design: .rounded))
            .contentTransition(.numericText())

        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2),
            spacing: 6
        ) {
            ForEach(speeds, id: \.self) { speed in
                Button(speedLabel(speed)) {
                    model.setSpeed(speed, for: selectedClip.id)
                }
                .buttonStyle(SpeedChipStyle(isSelected: abs(speed - selectedClip.speed) < 0.01))
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: 5) {
            Label("Clip duration", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedDuration(selectedClip.outputDuration))
                .font(.system(size: 12, design: .monospaced))
        }
    }

    @ViewBuilder
    private func zoomControls(for range: ZoomRange) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(format: "%.2gx", range.amount))
                .font(.system(size: 26, weight: .medium, design: .rounded))
            Spacer()
            Text("amount")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Slider(
            value: Binding(
                get: { range.amount },
                set: { model.setZoomAmount($0, for: range.id) }
            ),
            in: 1...3,
            step: 0.05
        )
        .tint(.accentColor)

        Divider()

        ZoomAnimationPicker(
            title: "Entry",
            selection: range.entryAnimation,
            onChange: { model.setZoomEntryAnimation($0, for: range.id) }
        )

        ZoomAnimationPicker(
            title: "Exit",
            selection: range.exitAnimation,
            onChange: { model.setZoomExitAnimation($0, for: range.id) }
        )
    }
}

private struct InspectorTabBar: View {
    @Binding var selection: InspectorTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                InspectorTabButton(
                    tab: tab,
                    isSelected: selection == tab
                ) {
                    selection = tab
                }
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 14)
                Text(tab.title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.55))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SpeedChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.07))
            }
            .foregroundStyle(isSelected ? .white : .primary)
    }
}

private struct ZoomAnimationPicker: View {
    let title: String
    let selection: ZoomAnimation
    let onChange: (ZoomAnimation) -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Picker(title, selection: Binding(
                get: { selection },
                set: onChange
            )) {
                ForEach(ZoomAnimation.allCases) { animation in
                    Text(animation.title)
                        .tag(animation)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 112, alignment: .trailing)
        }
    }
}

private struct TimelineView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TIMELINE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(formattedDuration(model.playhead))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 31)

            Divider()

            HStack(spacing: 0) {
                Text("V1")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 72, alignment: .top)
                    .padding(.top, 27)

                GeometryReader { proxy in
                    let trackWidth = max(1, proxy.size.width - 40)
                    let duration = max(0.01, model.duration)

                    ZStack(alignment: .topLeading) {
                        TimelineRuler(duration: duration, width: trackWidth)

                        ForEach(model.timelineClips) { layout in
                            let x = trackWidth * CGFloat(layout.start / duration)
                            let width = max(2, trackWidth * CGFloat(layout.duration / duration))

                            TimelineClipBlock(
                                title: model.clipTitle,
                                speed: layout.clip.speed,
                                isSelected: model.selectedClipID == layout.clip.id,
                                thumbnails: model.thumbnailsForClip(layout.clip),
                                videoAspect: model.videoRenderSize.width / max(1, model.videoRenderSize.height)
                            )
                            .frame(width: width, height: 48)
                            .offset(x: x, y: 24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectClip(layout.clip.id)
                            }
                        }

                        PlayheadView()
                            .frame(height: proxy.size.height)
                            .offset(x: trackWidth * CGFloat(model.playhead / duration))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                model.seek(to: Double(value.location.x / trackWidth) * duration)
                            }
                    )
                    .padding(.trailing, 40)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TimelineRuler: View {
    let duration: Double
    let width: CGFloat

    var body: some View {
        ForEach(0...6, id: \.self) { marker in
            let fraction = CGFloat(marker) / 6
            let isFirst = marker == 0
            let isLast = marker == 6
            VStack(alignment: isLast ? .trailing : .leading, spacing: 3) {
                Text(formattedDuration(duration * Double(fraction)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 5)
            }
            .frame(width: isLast ? 30 : nil, alignment: isLast ? .trailing : .leading)
            .offset(x: isLast ? width - 30 : (isFirst ? 0 : width * fraction - 15), y: 5)
        }
    }
}

private struct TimelineClipBlock: View {
    let title: String
    let speed: Double
    let isSelected: Bool
    let thumbnails: [NSImage]
    let videoAspect: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if thumbnails.isEmpty {
                HStack(spacing: 1) {
                    ForEach(0..<18, id: \.self) { index in
                        Color(
                            red: 0.22 + Double(index.isMultiple(of: 4) ? 0.09 : 0),
                            green: 0.33 + Double(index.isMultiple(of: 5) ? 0.08 : 0),
                            blue: 0.45 + Double(index.isMultiple(of: 3) ? 0.08 : 0)
                        )
                    }
                }
            } else {
                // Flexible base keeps the block at the frame width; the rigid image
                // strip would otherwise oversize it and get centered past 00:00.
                Color.clear
                    .overlay(alignment: .leading) {
                        HStack(spacing: 1) {
                            ForEach(thumbnails.indices, id: \.self) { index in
                                Image(nsImage: thumbnails[index])
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 48 * videoAspect, height: 48)
                                    .clipped()
                            }
                        }
                    }
                    .clipped()
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(speedLabel(speed))
                    .fontDesign(.monospaced)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.accentColor : .black.opacity(0.45), lineWidth: isSelected ? 2 : 1)
        }
    }
}

private struct PlayheadView: View {
    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .offset(y: -2)
            }
    }
}

private struct ZoomLane: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ZOOM")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    model.generateAutoZoomRanges()
                } label: {
                    Label("Auto Zoom", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .help("Generate zoom ranges from cursor movement and clicks")

                Button {
                    model.addZoomRange()
                } label: {
                    Label("Add zoom range", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Add zoom range at the playhead")
            }
            .padding(.horizontal, 16)
            .frame(height: 29)

            Divider()

            HStack(spacing: 0) {
                Text("ZOOM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 40, alignment: .top)
                    .padding(.top, 12)

                GeometryReader { proxy in
                    let trackWidth = max(1, proxy.size.width - 14)
                    let duration = max(0.01, model.duration)

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 34)

                        ForEach(model.zoomRanges) { range in
                            ZoomRangeBlock(
                                range: range,
                                duration: duration,
                                trackWidth: trackWidth,
                                onChange: model.updateZoomRange,
                                onSelect: { model.selectZoom(range.id) },
                                isSelected: model.selectedZoomID == range.id,
                                onRemove: { model.removeZoomRange(id: range.id) }
                            )
                        }

                        PlayheadView()
                            .frame(height: 40)
                            .offset(x: trackWidth * CGFloat(model.playhead / duration))
                    }
                    .frame(height: 40)
                    .padding(.trailing, 14)
                }
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ZoomRangeBlock: View {
    let range: ZoomRange
    let duration: Double
    let trackWidth: CGFloat
    let onChange: (ZoomRange) -> Void
    let onSelect: () -> Void
    let isSelected: Bool
    let onRemove: () -> Void

    @State private var moveStart: ZoomRange?
    @State private var resizeStart: ZoomRange?

    private var x: CGFloat {
        trackWidth * CGFloat(range.start / duration)
    }

    private var width: CGFloat {
        max(24, trackWidth * CGFloat((range.end - range.start) / duration))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(0.20))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : Color.accentColor.opacity(0.65), lineWidth: isSelected ? 2 : 1.25)
            }
            .overlay(alignment: .center) {
                Text(String(format: "%.2gx", range.amount))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .opacity(width > 46 ? 1 : 0)
            }
            .frame(width: width, height: 34)
            .overlay(alignment: .leading) {
                rangeHandle
                    .padding(.leading, 4)
                    .highPriorityGesture(resizeGesture(isLeading: true))
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 4) {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .opacity(width > 62 ? 1 : 0)

                    rangeHandle
                        .highPriorityGesture(resizeGesture(isLeading: false))
                }
                .padding(.trailing, 4)
            }
            .offset(x: x)
            .gesture(moveGesture)
            .onTapGesture(perform: onSelect)
            .help("Drag to move the zoom range. Drag its edges to resize.")
    }

    private var rangeHandle: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 4, height: 18)
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let initial = moveStart ?? range
                if moveStart == nil {
                    moveStart = initial
                }
                let delta = Double(value.translation.width / trackWidth) * duration
                let length = initial.end - initial.start
                let start = min(duration - length, max(0, initial.start + delta))
                onChange(ZoomRange(id: initial.id, start: start, end: start + length))
            }
            .onEnded { _ in
                moveStart = nil
            }
    }

    private func resizeGesture(isLeading: Bool) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let initial = resizeStart ?? range
                if resizeStart == nil {
                    resizeStart = initial
                }
                let delta = Double(value.translation.width / trackWidth) * duration
                let minimumLength = 0.25
                let updated: ZoomRange

                if isLeading {
                    updated = ZoomRange(
                        id: initial.id,
                        start: min(initial.end - minimumLength, max(0, initial.start + delta)),
                        end: initial.end
                    )
                } else {
                    updated = ZoomRange(
                        id: initial.id,
                        start: initial.start,
                        end: max(initial.start + minimumLength, min(duration, initial.end + delta))
                    )
                }
                onChange(updated)
            }
            .onEnded { _ in
                resizeStart = nil
            }
    }
}

// MARK: - Cursor inspector

private struct CursorInspectorPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CURSOR")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.75)
                        .foregroundStyle(.secondary)
                    Text("Style & motion")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Toggle(
                    "On",
                    isOn: Binding(
                        get: { model.cursorSettings.isEnabled },
                        set: model.setCursorEnabled
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!model.hasCursorData)
                .help(model.hasCursorData ? "Show custom cursor" : "No cursor track for this recording")
            }

            if !model.hasCursorData {
                missingTrackBanner
            } else {
                Text("Recordings hide the system cursor so you can restyle movement after capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                sectionLabel("macOS cursors")
                Text("Loaded from the real system cursor assets on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(CursorStyle.allCases.filter(\.isNativeMacOS)) { style in
                        CursorStyleCard(
                            style: style,
                            isSelected: model.cursorSettings.style == style,
                            isEnabled: model.cursorSettings.isEnabled
                        ) {
                            model.setCursorStyle(style)
                        }
                    }
                }

                sectionLabel("Custom")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(CursorStyle.allCases.filter { !$0.isNativeMacOS }) { style in
                        CursorStyleCard(
                            style: style,
                            isSelected: model.cursorSettings.style == style,
                            isEnabled: model.cursorSettings.isEnabled
                        ) {
                            model.setCursorStyle(style)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Size")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", model.cursorSettings.size * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { model.cursorSettings.size },
                            set: model.setCursorSize
                        ),
                        in: 0.6...2.0,
                        step: 0.05
                    )
                    .disabled(!model.cursorSettings.isEnabled)
                }

                sectionLabel("Motion")
                Text("How the pointer eases when it changes position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach(CursorMotionStyle.allCases) { motion in
                        CursorMotionCard(
                            motion: motion,
                            isSelected: model.cursorSettings.motion == motion,
                            isEnabled: model.cursorSettings.isEnabled
                        ) {
                            model.setCursorMotion(motion)
                        }
                    }
                }

                sectionLabel("Click effect")
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(CursorClickEffect.allCases) { effect in
                        CursorClickCard(
                            effect: effect,
                            isSelected: model.cursorSettings.clickEffect == effect,
                            isEnabled: model.cursorSettings.isEnabled
                        ) {
                            model.setCursorClickEffect(effect)
                        }
                    }
                }

                motionBlurSection
            }
        }
        .opacity(model.hasCursorData && !model.cursorSettings.isEnabled ? 0.85 : 1)
    }

    @ViewBuilder
    private var motionBlurSection: some View {
        sectionLabel("Motion blur")
        Text("Smear on fast cursor moves and zoom pans. Turn off for a crisp look.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            Text("Enabled")
                .font(.callout)
            Spacer()
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { model.motionBlurSettings.isEnabled },
                    set: model.setMotionBlurEnabled
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", model.motionBlurSettings.amount * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { model.motionBlurSettings.amount },
                    set: model.setMotionBlurAmount
                ),
                in: 0...1,
                step: 0.05
            )
            .disabled(!model.motionBlurSettings.isEnabled)
        }

        Toggle(
            "Cursor trail",
            isOn: Binding(
                get: { model.motionBlurSettings.applyToCursor },
                set: model.setMotionBlurApplyToCursor
            )
        )
        .toggleStyle(.checkbox)
        .disabled(!model.motionBlurSettings.isEnabled)
        .font(.callout)

        Toggle(
            "Zoom & pan",
            isOn: Binding(
                get: { model.motionBlurSettings.applyToZoom },
                set: model.setMotionBlurApplyToZoom
            )
        )
        .toggleStyle(.checkbox)
        .disabled(!model.motionBlurSettings.isEnabled)
        .font(.callout)
        .help("Uses a high-quality compositor for directional blur during zooms.")
    }

    private var missingTrackBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No cursor data", systemImage: "cursorarrow.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("New recordings track the pointer automatically. Re-record to unlock styles, motion, and click effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

// MARK: - Camera inspector

private struct CameraInspectorPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CAMERA")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.75)
                        .foregroundStyle(.secondary)
                    Text("Overlay position")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Toggle(
                    "On",
                    isOn: Binding(
                        get: { model.cameraSettings.isEnabled },
                        set: model.setCameraEnabled
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!model.hasCameraVideo)
                .help(model.hasCameraVideo ? "Show camera overlay" : "No camera video for this recording")
            }

            if !model.hasCameraVideo {
                missingCameraBanner
            } else {
                Text("Camera was recorded separately. Choose one corner for the entire video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(CameraCorner.allCases) { corner in
                        CornerButton(
                            corner: corner,
                            isSelected: model.cameraSettings.corner == corner,
                            isEnabled: model.cameraSettings.isEnabled
                        ) {
                            model.setCameraCorner(corner)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Size")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", model.cameraSettings.clampedSize * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { model.cameraSettings.clampedSize },
                            set: model.setCameraSize
                        ),
                        in: 0.08...0.45,
                        step: 0.02
                    )
                    .disabled(!model.cameraSettings.isEnabled)
                }
            }
        }
        .opacity(model.hasCameraVideo && !model.cameraSettings.isEnabled ? 0.85 : 1)
    }

    private var missingCameraBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No camera video", systemImage: "video.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("Enable Camera before starting a recording to capture a picture-in-picture overlay.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BackgroundInspectorPanel: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject private var wallpaperManager: WallpaperManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("BACKGROUND")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.75)
                        .foregroundStyle(.secondary)
                    Text("Wallpaper behind recording")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Toggle(
                    "On",
                    isOn: Binding(
                        get: { model.isBackgroundEnabled },
                        set: model.setBackgroundEnabled
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            if !model.isBackgroundEnabled {
                Text("Background is off. Turn it on to apply a wallpaper behind the recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if wallpaperManager.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading wallpapers…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let error = wallpaperManager.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if wallpaperManager.wallpapers.isEmpty {
                Text("No wallpapers available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap a wallpaper to apply it behind the recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.captureMode == .window {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Corner radius")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f px", model.backgroundCornerRadius))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { model.backgroundCornerRadius },
                                set: model.setBackgroundCornerRadius
                            ),
                            in: 0...120,
                            step: 1
                        )
                    }
                }

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(wallpaperManager.wallpapers) { wallpaper in
                            WallpaperCard(
                                wallpaper: wallpaper,
                                isSelected: wallpaperManager.selectedWallpaperID == wallpaper.id
                            ) {
                                wallpaperManager.selectWallpaper(wallpaper)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }
}

private struct WallpaperCard: View {
    let wallpaper: WallpaperManager.Wallpaper
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))

                    if let image = NSImage(contentsOf: wallpaper.localURL) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                }

                Text(wallpaper.name)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 24)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CornerButton: View {
    let corner: CameraCorner
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: corner.systemImage)
                    .imageScale(.large)
                Text(corner.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .imageScale(.small)
                }
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct CursorStyleCard: View {
    let style: CursorStyle
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .controlBackgroundColor),
                                    Color.primary.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    CursorStylePreview(style: style)
                        .frame(width: 36, height: 36)
                }
                .frame(height: 52)

                Text(style.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(style.subtitle)
    }
}

private struct CursorStylePreview: View {
    let style: CursorStyle

    var body: some View {
        Image(nsImage: CursorArtwork.image(style: style, scale: 2))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }
}

private struct CursorMotionCard: View {
    let motion: CursorMotionStyle
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                MotionDemoView(motion: motion)
                    .frame(width: 72, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(motion.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(motion.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .imageScale(.small)
                }
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Tiny looping path demo so motion styles are easy to compare.
private struct MotionDemoView: View {
    let motion: CursorMotionStyle

    var body: some View {
        // Qualify SwiftUI.TimelineView — this file also defines a timeline lane view.
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cycle = demoProgress(at: t)
            Canvas { context, size in
                let path = demoPath(in: size)
                context.stroke(
                    path,
                    with: .color(.secondary.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                let point = pointOnDemoPath(progress: cycle, in: size)
                let radius: CGFloat = 4
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.accentColor))
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
        }
        .padding(4)
    }

    private func demoProgress(at time: TimeInterval) -> CGFloat {
        let period: Double
        switch motion {
        case .precise: period = 1.1
        case .natural: period = 1.35
        case .smooth: period = 1.7
        case .fluid: period = 2.1
        case .cinematic: period = 2.6
        }
        let raw = time.truncatingRemainder(dividingBy: period) / period
        // Triangle wave so the dot travels forth and back.
        let triangle = raw < 0.5 ? raw * 2 : (1 - raw) * 2
        switch motion {
        case .precise:
            // Quantize to show steppy tracking.
            return CGFloat((triangle * 8).rounded() / 8)
        case .natural:
            return CGFloat(triangle)
        case .smooth:
            return CGFloat(triangle * triangle * (3 - 2 * triangle))
        case .fluid:
            let t = triangle
            return CGFloat(t * t * t * (t * (t * 6 - 15) + 10))
        case .cinematic:
            // Slow ease with a soft overshoot illusion near the end.
            let t = triangle
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            return CGFloat(min(1, eased * 1.04))
        }
    }

    private func demoPath(in size: CGSize) -> Path {
        var path = Path()
        let inset: CGFloat = 8
        path.move(to: CGPoint(x: inset, y: size.height - inset))
        path.addQuadCurve(
            to: CGPoint(x: size.width - inset, y: inset),
            control: CGPoint(x: size.width * 0.55, y: size.height * 0.95)
        )
        return path
    }

    private func pointOnDemoPath(progress: CGFloat, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 8
        let start = CGPoint(x: inset, y: size.height - inset)
        let end = CGPoint(x: size.width - inset, y: inset)
        let control = CGPoint(x: size.width * 0.55, y: size.height * 0.95)
        let t = min(1, max(0, progress))
        let u = 1 - t
        // Quadratic Bezier.
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }
}

private struct CursorClickCard: View {
    let effect: CursorClickEffect
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ClickEffectDemo(effect: effect)
                    .frame(height: 36)
                Text(effect.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct ClickEffectDemo: View {
    let effect: CursorClickEffect

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Cursor dot
                let cursor = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: cursor), with: .color(.primary.opacity(0.85)))

                guard effect != .none else { return }
                let burst = min(1, max(0, (phase - 0.15) / 0.55))
                guard burst > 0, burst < 1 else { return }

                switch effect {
                case .none:
                    break
                case .ripple:
                    let radius = 4 + CGFloat(burst) * 14
                    let opacity = 0.75 * (1 - burst)
                    var circle = Path()
                    circle.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(circle, with: .color(.accentColor.opacity(opacity)), lineWidth: 1.5)
                case .ring:
                    let radius = 6 + CGFloat(burst) * 10
                    var circle = Path()
                    circle.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(circle, with: .color(.white.opacity(0.85 * (1 - burst))), lineWidth: 2)
                    context.stroke(circle, with: .color(.primary.opacity(0.35 * (1 - burst))), lineWidth: 1)
                case .pulse:
                    let scale = 1 + CGFloat(sin(burst * .pi)) * 0.7
                    let radius = 5 * scale
                    var circle = Path()
                    circle.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(circle, with: .color(.accentColor.opacity(0.35 * (1 - burst))))
                    context.stroke(circle, with: .color(.accentColor.opacity(0.9 * (1 - burst))), lineWidth: 1.5)
                }
            }
        }
    }
}

private struct ExportOverlay: View {
    let state: EditorModel.ExportState
    let dismiss: () -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case let .exporting(progress):
            VStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(width: 220)
                Text("Exporting \(Int(progress * 100))%")
                    .font(.callout)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .shadow(radius: 14)

        case let .completed(url):
            ExportMessage(
                symbol: "checkmark.circle.fill",
                color: .green,
                title: "Export complete",
                message: url.lastPathComponent,
                actionTitle: "Show in Finder",
                action: {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    dismiss()
                },
                dismiss: dismiss
            )

        case let .failed(message):
            ExportMessage(
                symbol: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Export failed",
                message: message,
                actionTitle: nil,
                action: nil,
                dismiss: dismiss
            )
        }
    }
}

private struct ExportMessage: View {
    let symbol: String
    let color: Color
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            HStack {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                }
                Button("Done", action: dismiss)
            }
        }
        .padding(20)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .shadow(radius: 14)
    }
}

func formattedDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "00:00" }
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

private func speedLabel(_ speed: Double) -> String {
    if speed.rounded() == speed {
        return String(format: "%.0fx", speed)
    }
    return String(format: "%.2gx", speed)
}
