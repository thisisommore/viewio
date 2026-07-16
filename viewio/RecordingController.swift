//
//  RecordingController.swift
//  viewio
//

import AppKit
import AVFoundation
import Combine
import Foundation
@preconcurrency import ScreenCaptureKit

struct AudioDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let isDefault: Bool
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let size: CGSize

    var idValue: UInt32 { id }
}

/// Output resolution for screen capture (scaled to fit the display aspect ratio).
enum RecordingResolution: String, CaseIterable, Identifiable {
    case native
    case uhd4k
    case qhd
    case fullHD
    case hd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: "Native"
        case .uhd4k: "4K"
        case .qhd: "1440p"
        case .fullHD: "1080p"
        case .hd: "720p"
        }
    }

    var subtitle: String {
        switch self {
        case .native: "Full display"
        case .uhd4k: "3840×2160"
        case .qhd: "2560×1440"
        case .fullHD: "1920×1080"
        case .hd: "1280×720"
        }
    }

    /// Target long-edge / short-edge caps. `nil` means use the display as-is.
    var maxSize: CGSize? {
        switch self {
        case .native: nil
        case .uhd4k: CGSize(width: 3840, height: 2160)
        case .qhd: CGSize(width: 2560, height: 1440)
        case .fullHD: CGSize(width: 1920, height: 1080)
        case .hd: CGSize(width: 1280, height: 720)
        }
    }

    /// Scales `native` to fit inside this preset while preserving aspect ratio.
    /// Never upscales past the native pixel size.
    func outputSize(forNative native: CGSize) -> CGSize {
        let width = max(2, native.width)
        let height = max(2, native.height)
        guard let maxSize else {
            return evenSize(CGSize(width: width, height: height))
        }

        let scale = min(
            1,
            min(maxSize.width / width, maxSize.height / height)
        )
        return evenSize(CGSize(width: width * scale, height: height * scale))
    }

    /// True when this preset would not change capture size for `native`.
    func isLimitedByDisplay(_ native: CGSize) -> Bool {
        guard maxSize != nil else { return false }
        let out = outputSize(forNative: native)
        return abs(out.width - native.width) < 1 && abs(out.height - native.height) < 1
    }

    private func evenSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(2, (size.width / 2).rounded(.down) * 2),
            height: max(2, (size.height / 2).rounded(.down) * 2)
        )
    }
}

enum RecordingFrameRate: Int, CaseIterable, Identifiable {
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var title: String { "\(rawValue) fps" }

    var subtitle: String {
        switch self {
        case .fps15: "Smaller files"
        case .fps24: "Cinematic"
        case .fps30: "Standard"
        case .fps60: "Smooth"
        }
    }

    var timescale: CMTimeScale { CMTimeScale(rawValue) }
}

struct CursorPosition: Codable, Equatable {
    let time: TimeInterval
    let x: Double
    let y: Double
}

/// On-disk cursor track. v2 stores normalized video coords (origin top-left).
/// Legacy files are a bare `[CursorPosition]` array in Cocoa space (origin bottom-left).
struct CursorTrackFile: Codable, Equatable {
    var version: Int
    /// "videoTopLeft" (v2+) or "cocoaBottomLeft" (legacy).
    var coordinateSpace: String
    var samples: [CursorPosition]

    static let currentVersion = 2
    static let videoTopLeft = "videoTopLeft"
    static let cocoaBottomLeft = "cocoaBottomLeft"
}

struct ClickEvent: Codable, Equatable {
    let time: TimeInterval
    let button: Int
}

@MainActor
final class RecordingController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case stopping
        case failed(String)
        case finished(URL)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var captureSystemAudio = true
    @Published var captureMicrophone = false
    @Published var selectedMicrophoneID: String?
    @Published private(set) var availableMicrophones: [AudioDevice] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var availableDisplays: [DisplayInfo] = []
    @Published var selectedResolution: RecordingResolution = .native
    @Published var selectedFrameRate: RecordingFrameRate = .fps60

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private var cursorTimer: Timer?
    private var cursorTrack: [CursorPosition] = []
    private var clickEvents: [ClickEvent] = []
    private var recordedDisplayID: CGDirectDisplayID?
    /// Global Cocoa bounds (points, origin bottom-left) of the captured display.
    private var captureBounds: CGRect = .zero
    private var wasLeftButtonDown = false
    /// Host time when capture is considered started (aligns cursor track to video).
    private var recordingHostStart: TimeInterval?

    var isRecording: Bool {
        switch state {
        case .preparing, .recording, .stopping:
            true
        case .idle, .failed, .finished:
            false
        }
    }

    override init() {
        super.init()
        discoverDisplays()
        discoverMicrophones()
    }

    func startRecording() {
        guard !isRecording else { return }

        state = .preparing
        elapsed = 0

        Task {
            do {
                if captureMicrophone {
                    let authorized = await requestMicrophoneAuthorization()
                    guard authorized else {
                        throw RecordingError.microphoneDenied
                    }
                }
                try await configureAndStartCapture()
            } catch {
                finishWithError(error)
            }
        }
    }

    func stopRecording() {
        guard let stream, isRecording else { return }
        state = .stopping
        stopTimer()

        Task {
            do {
                try await stream.stopCapture()
            } catch {
                finishWithError(error)
            }
        }
    }

    func dismissError() {
        if case .failed = state {
            state = .idle
        }
    }

    func discardRecording() {
        if case let .finished(url) = state {
            try? FileManager.default.removeItem(at: url)
        }
        resetCaptureReferences()
        state = .idle
    }

    private func configureAndStartCapture() async throws {
        let content = try await SCShareableContent.current
        let displays = content.displays
        guard !displays.isEmpty else {
            throw RecordingError.noDisplay
        }

        let display: SCDisplay
        if let selectedDisplayID,
           let selected = displays.first(where: { $0.displayID == selectedDisplayID }) {
            display = selected
        } else {
            display = displays[0]
        }
        recordedDisplayID = display.displayID
        // Prefer NSScreen.frame (same space as NSEvent.mouseLocation) for tracking.
        captureBounds = displayBoundsInCocoaSpace(displayID: display.displayID)

        let outputURL = try makeOutputURL()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()

        // Prefer filter metrics (points × pixel scale) so Retina displays capture
        // at true pixel density, not the SCStream default 1920×1080.
        let scale = CGFloat(filter.pointPixelScale)
        let nativeFromFilter = CGSize(
            width: filter.contentRect.width * scale,
            height: filter.contentRect.height * scale
        )
        let nativeFromDisplay = CGSize(
            width: CGDisplayPixelsWide(display.displayID),
            height: CGDisplayPixelsHigh(display.displayID)
        )
        // Use the larger of the two estimates (guards against odd filter rects).
        let nativeSize = CGSize(
            width: max(nativeFromFilter.width, nativeFromDisplay.width),
            height: max(nativeFromFilter.height, nativeFromDisplay.height)
        )
        let outputSize = selectedResolution.outputSize(forNative: nativeSize)
        // Keep exact aspect of the display so scalesToFit never letterboxes
        // (letterboxing would desync normalized cursor coords from pixels).
        configuration.width = max(2, Int(outputSize.width.rounded()) & ~1)
        configuration.height = max(2, Int(outputSize.height.rounded()) & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: selectedFrameRate.timescale)
        configuration.queueDepth = 8
        // BGRA keeps sharp UI text better than subsampled YUV for screen content.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        // Hide the system cursor in the captured frames so the editor can redraw
        // a custom, animated cursor from the separately tracked path.
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.capturesAudio = captureSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = captureMicrophone
        configuration.microphoneCaptureDeviceID = selectedMicrophoneID

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        // HEVC is much sharper than H.264 at ScreenCaptureKit's default bitrates.
        let hevc = AVVideoCodecType.hevc
        if recordingConfiguration.availableVideoCodecTypes.contains(hevc) {
            recordingConfiguration.videoCodecType = hevc
        } else {
            recordingConfiguration.videoCodecType = .h264
        }

        let recordingOutput = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: self
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        try stream.addRecordingOutput(recordingOutput)

        self.outputURL = outputURL
        self.recordingOutput = recordingOutput
        self.stream = stream

        try await stream.startCapture()

        if case .preparing = state {
            recordingDidStart()
        }
    }

    private func makeOutputURL() throws -> URL {
        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("viewio", isDirectory: true)
        .appendingPathComponent("Recordings", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "Screen Recording \(formatter.string(from: .now)).mp4"
        return directory.appendingPathComponent(filename)
    }

    private func recordingDidStart() {
        guard case .preparing = state else { return }
        state = .recording
        let now = Date()
        startedAt = now
        recordingHostStart = ProcessInfo.processInfo.systemUptime
        startTimer()
        startCursorTracking()
    }

    /// Global display bounds in the same Cocoa point space as `NSEvent.mouseLocation`.
    private func displayBoundsInCocoaSpace(displayID: CGDirectDisplayID) -> CGRect {
        if let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }) {
            return screen.frame
        }
        return CGDisplayBounds(displayID)
    }

    private func recordingDidFinish() {
        stopTimer()
        stopCursorTracking()
        guard let outputURL else {
            state = .failed("The recording finished without creating a video file.")
            resetCaptureReferences()
            return
        }

        saveCursorTrack(for: outputURL)
        resetCaptureReferences(keepingOutputURL: true)
        state = .finished(outputURL)
    }

    private func finishWithError(_ error: Error) {
        stopTimer()
        stopCursorTracking()
        resetCaptureReferences()
        state = .failed(error.localizedDescription)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startCursorTracking() {
        stopCursorTracking()
        cursorTrack = []
        clickEvents = []
        wasLeftButtonDown = false
        guard recordedDisplayID != nil, captureBounds.width > 1, captureBounds.height > 1 else { return }
        let bounds = captureBounds

        // Sample cursor at least as often as capture FPS (capped for overhead).
        let cursorHz = min(60.0, max(30.0, Double(selectedFrameRate.rawValue)))
        // Main run loop + common modes so tracking continues during UI tracking loops.
        let timer = Timer(timeInterval: 1.0 / cursorHz, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleCursor(bounds: bounds)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
        // Immediate sample at t≈0 so the first frame is aligned.
        sampleCursor(bounds: bounds)
    }

    private func sampleCursor(bounds: CGRect) {
        guard let hostStart = recordingHostStart else { return }
        // NSEvent.mouseLocation is the cursor *hotspot* in global Cocoa points.
        let location = NSEvent.mouseLocation
        let relativeX = (location.x - bounds.origin.x) / bounds.width
        // Cocoa Y is bottom-up; store already flipped to video top-left (0 = top)
        // so playback never double-flips or mixes conventions.
        let relativeYFromTop = 1 - (location.y - bounds.origin.y) / bounds.height
        let time = ProcessInfo.processInfo.systemUptime - hostStart
        let position = CursorPosition(
            time: max(0, time),
            x: max(0, min(1, relativeX)),
            y: max(0, min(1, relativeYFromTop))
        )
        cursorTrack.append(position)
        recordClickIfNeeded(at: position.time)
    }

    private func recordClickIfNeeded(at time: TimeInterval) {
        let isDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if isDown && !wasLeftButtonDown {
            clickEvents.append(ClickEvent(time: time, button: 0))
        }
        wasLeftButtonDown = isDown
    }

    private func stopCursorTracking() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func saveCursorTrack(for videoURL: URL) {
        guard !cursorTrack.isEmpty else { return }
        let trackURL = videoURL.deletingPathExtension().appendingPathExtension("cursor.json")
        do {
            let file = CursorTrackFile(
                version: CursorTrackFile.currentVersion,
                coordinateSpace: CursorTrackFile.videoTopLeft,
                samples: cursorTrack
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: trackURL)
        } catch {
            print("Failed to save cursor track: \(error)")
        }

        guard !clickEvents.isEmpty else { return }
        let clicksURL = videoURL.deletingPathExtension().appendingPathExtension("clicks.json")
        do {
            let data = try JSONEncoder().encode(clickEvents)
            try data.write(to: clicksURL)
        } catch {
            print("Failed to save click events: \(error)")
        }
    }

    private func resetCaptureReferences(keepingOutputURL: Bool = false) {
        stream = nil
        recordingOutput = nil
        startedAt = nil
        recordingHostStart = nil
        elapsed = 0
        cursorTrack = []
        clickEvents = []
        recordedDisplayID = nil
        captureBounds = .zero
        wasLeftButtonDown = false
        if !keepingOutputURL {
            outputURL = nil
        }
    }

    private func discoverMicrophones() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        availableMicrophones = session.devices.map { device in
            AudioDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultDevice?.uniqueID
            )
        }
    }

    private func discoverDisplays() {
        availableDisplays = NSScreen.screens.map { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = number.uint32Value
            return DisplayInfo(
                id: displayID,
                name: screen.localizedName,
                size: screen.frame.size
            )
        }.compactMap { $0 }

        if selectedDisplayID == nil, let first = availableDisplays.first {
            selectedDisplayID = first.id
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

extension RecordingController: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.recordingDidStart()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.recordingDidFinish()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.finishWithError(error)
        }
    }
}

extension RecordingController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard self?.isRecording == true else { return }
            self?.finishWithError(error)
        }
    }
}

private enum RecordingError: LocalizedError {
    case noDisplay
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display is available to record."
        case .microphoneDenied:
            "Microphone access was denied. Enable it in System Settings to record microphone audio."
        }
    }
}
