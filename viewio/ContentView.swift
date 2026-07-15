//
//  ContentView.swift
//  viewio
//
//  Created by Om More on 12/07/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isPlaying = false
    @State private var playhead: Double = 4.0
    @State private var hasMockVideo = true
    @State private var zoomRanges: [ZoomRange] = [ZoomRange(start: 2, end: 4)]
    @State private var cuts: [Double] = []

    var body: some View {
        VStack(spacing: 0) {
            PreviewWorkspace(
                isPlaying: $isPlaying,
                hasVideo: hasMockVideo,
                zoomRanges: zoomRanges,
                playhead: playhead,
                onCut: cutAtPlayhead
            )

            Divider()

            Timeline(playhead: $playhead, cuts: $cuts)
                .frame(height: 208)

            Divider()

            ZoomTimeline(ranges: $zoomRanges)
                .frame(height: 118)
        }
        .frame(minWidth: 920, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cutAtPlayhead() {
        guard playhead > 0.05, playhead < 11.95 else { return }
        guard !cuts.contains(where: { abs($0 - playhead) < 0.05 }) else { return }
        cuts.append(playhead)
    }
}

private struct PreviewWorkspace: View {
    @Binding var isPlaying: Bool
    let hasVideo: Bool
    let zoomRanges: [ZoomRange]
    let playhead: Double
    let onCut: () -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 28) {
                if hasVideo {
                    VideoPreview(isZoomed: zoomRanges.contains { $0.start...$0.end ~= playhead })
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView(
                        "No video selected",
                        systemImage: "film",
                        description: Text("Import a video to begin editing."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                PlaybackControls(isPlaying: $isPlaying, onCut: onCut)
                    .padding(.bottom, 4)
            }
            .padding(.trailing, 26)
            .padding(.bottom, 28)
        }
    }
}

private struct VideoPreview: View {
    let isZoomed: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(white: 0.04), Color(white: 0.17)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height * 0.68))
                    path.addCurve(
                        to: CGPoint(x: proxy.size.width, y: proxy.size.height * 0.56),
                        control1: CGPoint(x: proxy.size.width * 0.21, y: proxy.size.height * 0.40),
                        control2: CGPoint(x: proxy.size.width * 0.64, y: proxy.size.height * 0.84)
                    )
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(.white.opacity(0.13))

                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height * 0.75))
                    path.addCurve(
                        to: CGPoint(x: proxy.size.width, y: proxy.size.height * 0.64),
                        control1: CGPoint(x: proxy.size.width * 0.25, y: proxy.size.height * 0.55),
                        control2: CGPoint(x: proxy.size.width * 0.72, y: proxy.size.height * 0.91)
                    )
                }
                .stroke(.white.opacity(0.48), lineWidth: 1)

                HStack {
                    Label("Aerial coastline.mov", systemImage: "film")
                    Spacer()
                    Text("00:12:16")
                        .fontDesign(.monospaced)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .padding(16)
            }
            .scaleEffect(isZoomed ? 1.28 : 1, anchor: .center)
            .clipped()
            .shadow(color: .black.opacity(0.16), radius: 16, y: 5)
        }
    }
}

private struct PlaybackControls: View {
    @Binding var isPlaying: Bool
    let onCut: () -> Void

    var body: some View {
        ControlGroup {
            Button(action: {}) {
                Image(systemName: "gobackward.10")
            }
            .help("Back 10 seconds")

            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .help(isPlaying ? "Pause" : "Play")

            Button(action: {}) {
                Image(systemName: "goforward.10")
            }
            .help("Forward 10 seconds")

            Button(action: onCut) {
                Image(systemName: "scissors")
            }
            .help("Cut at playhead")
        }
        .controlSize(.large)
    }
}

private struct Timeline: View {
    @Binding var playhead: Double
    @Binding var cuts: [Double]
    private let duration = 12.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TIMELINE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(timecode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 38)

            Divider()

            HStack(spacing: 0) {
                Text("V1")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 100, alignment: .top)
                    .padding(.top, 47)

                GeometryReader { proxy in
                    let trackWidth = max(1, proxy.size.width - 20)
                    let currentPosition = trackWidth * CGFloat(playhead / duration)

                    ZStack(alignment: .topLeading) {
                        ForEach(0...6, id: \.self) { marker in
                            let position = trackWidth * CGFloat(marker) / 6
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(marker * 2)s")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Rectangle()
                                    .fill(.black.opacity(0.18))
                                    .frame(width: 1, height: 6)
                            }
                            .offset(x: position, y: 8)
                        }

                        ForEach(Array(segmentBoundaries.dropLast().enumerated()), id: \.offset) { index, start in
                            let end = segmentBoundaries[index + 1]
                            TimelineClip()
                                .frame(
                                    width: max(1, trackWidth * CGFloat((end - start) / duration) - 2),
                                    height: 58
                                )
                                .offset(
                                    x: trackWidth * CGFloat(start / duration),
                                    y: 42
                                )
                        }

                        Rectangle()
                            .fill(.black)
                            .frame(width: 1.5, height: proxy.size.height)
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 9, height: 9)
                                    .offset(y: -2)
                            }
                            .offset(x: currentPosition, y: 0)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                playhead = min(duration, max(0, Double(value.location.x / trackWidth) * duration))
                            }
                    )
                    .padding(.trailing, 20)
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var timecode: String {
        let frames = Int((playhead - floor(playhead)) * 24)
        return String(format: "00:00:%02d:%02d", Int(playhead), frames)
    }

    private var segmentBoundaries: [Double] {
        [0] + cuts.sorted() + [duration]
    }
}

private struct TimelineClip: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 1) {
                ForEach(0..<16, id: \.self) { index in
                    Color(white: index.isMultiple(of: 4) ? 0.31 : 0.23)
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )

            Text("Aerial coastline.mov")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(.black.opacity(0.55), lineWidth: 1)
        }
    }
}

private struct ZoomRange: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
}

private struct ZoomTimeline: View {
    @Binding var ranges: [ZoomRange]
    private let duration = 12.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ZOOM")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    let start = min(duration - 2, (ranges.last?.end ?? 0) + 0.5)
                    ranges.append(ZoomRange(start: start, end: min(duration, start + 2)))
                } label: {
                    Label("Add zoom range", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Add zoom range")
            }
            .padding(.horizontal, 20)
            .frame(height: 38)

            Divider()

            HStack(spacing: 0) {
                Text("ZOOM")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .top)

                GeometryReader { proxy in
                    let trackWidth = max(1, proxy.size.width - 20)

                    ZStack(alignment: .leading) {
                        ForEach($ranges) { $range in
                            let x = trackWidth * CGFloat(range.start / duration)
                            let width = max(20, trackWidth * CGFloat((range.end - range.start) / duration))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.22))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.accentColor, lineWidth: 1.5)
                                }
                                .frame(width: width, height: 42)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: 5, height: 24)
                                        .padding(.leading, 4)
                                        .gesture(
                                            DragGesture()
                                                .onEnded { value in
                                                    let delta = Double(value.translation.width / trackWidth) * duration
                                                    range.start = min(range.end - 0.25, max(0, range.start + delta))
                                                }
                                        )
                                }
                                .overlay(alignment: .trailing) {
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: 5, height: 24)
                                        .padding(.trailing, 4)
                                        .gesture(
                                            DragGesture()
                                                .onEnded { value in
                                                    let delta = Double(value.translation.width / trackWidth) * duration
                                                    range.end = min(duration, max(range.start + 0.25, range.end + delta))
                                                }
                                        )
                                }
                                .offset(x: x)
                                .gesture(
                                    DragGesture()
                                        .onEnded { value in
                                            let delta = Double(value.translation.width / trackWidth) * duration
                                            let length = range.end - range.start
                                            let newStart = min(duration - length, max(0, range.start + delta))
                                            range.start = newStart
                                            range.end = newStart + length
                                        }
                                )
                        }
                    }
                    .frame(height: 48)
                    .padding(.trailing, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

#Preview {
    ContentView()
        .frame(width: 1180, height: 760)
}
