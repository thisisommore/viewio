//
//  ContentView.swift
//  viewio
//

import AppKit
import AVKit
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
                    elapsed: recorder.elapsed,
                    isStopping: false,
                    onStop: recorder.stopRecording
                )

            case .recording:
                RecordingProgressView(
                    elapsed: recorder.elapsed,
                    isStopping: false,
                    onStop: recorder.stopRecording
                )

            case .stopping:
                RecordingProgressView(
                    elapsed: recorder.elapsed,
                    isStopping: true,
                    onStop: {}
                )

            case let .finished(url):
                EditorWorkspace(sourceURL: url)
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
                VStack(alignment: .leading, spacing: 32) {
                    if let errorMessage {
                        errorBanner(message: errorMessage)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("New Recording")
                            .font(.system(size: 26, weight: .bold))
                        Text("Choose a display and audio sources, then start recording.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }

                    DisplayOptionsView(recorder: recorder, isPreparing: isPreparing)

                    AudioOptionsView(recorder: recorder, isPreparing: isPreparing)
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button(action: onRecord) {
                Text("Start Recording")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(RecordButtonStyle(isDisabled: isPreparing))
            .disabled(isPreparing)
        }
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
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .background {
                Rectangle()
                    .fill(isDisabled ? Color.red.opacity(0.4) : Color.red.opacity(configuration.isPressed ? 0.85 : 1))
            }
            .contentShape(Rectangle())
    }
}

private struct DisplayOptionsView: View {
    @ObservedObject var recorder: RecordingController
    let isPreparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Display")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(recorder.availableDisplays) { display in
                    SelectionCard(
                        title: display.name,
                        isSelected: recorder.selectedDisplayID == display.id,
                        isDisabled: isPreparing
                    ) {
                        recorder.selectedDisplayID = display.id
                    }
                }
            }
        }
    }
}

private struct AudioOptionsView: View {
    @ObservedObject var recorder: RecordingController
    let isPreparing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Audio")

            HStack(alignment: .top, spacing: 12) {
                SelectionCard(
                    title: "System",
                    isSelected: recorder.captureSystemAudio,
                    isDisabled: isPreparing
                ) {
                    recorder.captureSystemAudio.toggle()
                }
                .frame(width: 116)

                if !recorder.availableMicrophones.isEmpty {
                    Divider()
                        .frame(width: 1)
                        .background(Color.primary.opacity(0.15))

                    ForEach(recorder.availableMicrophones) { device in
                        let isSelected = recorder.captureMicrophone && recorder.selectedMicrophoneID == device.id
                        SelectionCard(
                            title: device.name,
                            isSelected: isSelected,
                            isDisabled: isPreparing
                        ) {
                            if isSelected {
                                recorder.captureMicrophone = false
                                recorder.selectedMicrophoneID = nil
                            } else {
                                recorder.captureMicrophone = true
                                recorder.selectedMicrophoneID = device.id
                            }
                        }
                        .frame(width: 116)
                    }
                }
            }
        }
    }
}

private struct SelectionCard: View {
    let title: String
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .padding(.horizontal, 12)
        }
        .buttonStyle(SelectionCardStyle(isSelected: isSelected))
        .disabled(isDisabled)
        .aspectRatio(1.25, contentMode: .fit)
    }
}

private struct SelectionCardStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(isSelected ? 0.6 : 0.1), lineWidth: isSelected ? 2 : 1)
            }
    }
}

private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 14, weight: .semibold))
}

private struct RecordingProgressView: View {
    let elapsed: TimeInterval
    let isStopping: Bool
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RecordingBar(
                title: isStopping ? "Finishing recording…" : "Recording",
                detail: isStopping ? "Saving your video" : formattedDuration(elapsed),
                actionTitle: isStopping ? "Stopping" : "Stop",
                actionIcon: isStopping ? "hourglass" : "stop.fill",
                action: onStop,
                isWorking: isStopping,
                isDestructive: true
            )

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !isStopping)

                Text(isStopping ? "Finishing your recording" : "Recording your screen")
                    .font(.system(size: 25, weight: .semibold))
                Text(isStopping ? "The editing workspace will open when the file is ready." : "Use the red recording icon in your menu bar to stop from anywhere.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
            }

            Spacer()
        }
    }
}

private struct RecordingBar: View {
    let title: String
    let detail: String
    let actionTitle: String
    let actionIcon: String
    let action: () -> Void
    var isWorking = false
    var isDestructive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isDestructive ? "record.circle.fill" : "video.badge.plus")
                .foregroundStyle(isDestructive ? Color.red : Color.accentColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: action) {
                Label(actionTitle, systemImage: actionIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(isDestructive ? .red : .accentColor)
            .disabled(isWorking)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct EditorWorkspace: View {
    @StateObject private var model: EditorModel

    init(sourceURL: URL) {
        _model = StateObject(wrappedValue: EditorModel(sourceURL: sourceURL))
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
                    .frame(width: 208)
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

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct VideoPreview: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: model.player)
                .background(Color.black)
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

private struct ClipInspector: View {
    @ObservedObject var model: EditorModel

    private let speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            Spacer()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Divider()
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
                    let trackWidth = max(1, proxy.size.width - 14)
                    let duration = max(0.01, model.duration)

                    ZStack(alignment: .topLeading) {
                        TimelineRuler(duration: duration, width: trackWidth)

                        ForEach(model.timelineClips) { layout in
                            let x = trackWidth * CGFloat(layout.start / duration)
                            let width = max(2, trackWidth * CGFloat(layout.duration / duration) - 2)

                            TimelineClipBlock(
                                title: model.clipTitle,
                                speed: layout.clip.speed,
                                isSelected: model.selectedClipID == layout.clip.id
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
                    .padding(.trailing, 14)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(formattedDuration(duration * Double(fraction)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 5)
            }
            .offset(x: width * fraction, y: 5)
        }
    }
}

private struct TimelineClipBlock: View {
    let title: String
    let speed: Double
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 1) {
                ForEach(0..<18, id: \.self) { index in
                    Color(
                        red: 0.22 + Double(index.isMultiple(of: 4) ? 0.09 : 0),
                        green: 0.33 + Double(index.isMultiple(of: 5) ? 0.08 : 0),
                        blue: 0.45 + Double(index.isMultiple(of: 3) ? 0.08 : 0)
                    )
                }
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
                .stroke(isSelected ? Color.accentColor : .black.opacity(0.45), lineWidth: isSelected ? 2 : 1)
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
