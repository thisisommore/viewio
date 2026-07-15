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

struct CursorPosition: Codable, Equatable {
    let time: TimeInterval
    let x: Double
    let y: Double
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

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var startedAt: Date?
    private var timer: Timer?
    private var cursorTimer: Timer?
    private var cursorTrack: [CursorPosition] = []
    private var recordedDisplayID: CGDirectDisplayID?

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

        let outputURL = try makeOutputURL()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = CGDisplayPixelsWide(display.displayID)
        configuration.height = CGDisplayPixelsHigh(display.displayID)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.capturesAudio = captureSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = captureMicrophone
        configuration.microphoneCaptureDeviceID = selectedMicrophoneID

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264

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
        startedAt = .now
        startTimer()
        startCursorTracking()
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
        guard let recordedDisplayID else { return }
        let bounds = CGDisplayBounds(recordedDisplayID)

        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                let location = NSEvent.mouseLocation
                let relativeX = (location.x - bounds.origin.x) / bounds.width
                let relativeY = (location.y - bounds.origin.y) / bounds.height
                let position = CursorPosition(
                    time: Date().timeIntervalSince(startedAt),
                    x: max(0, min(1, relativeX)),
                    y: max(0, min(1, relativeY))
                )
                self.cursorTrack.append(position)
            }
        }
    }

    private func stopCursorTracking() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func saveCursorTrack(for videoURL: URL) {
        guard !cursorTrack.isEmpty else { return }
        let trackURL = videoURL.deletingPathExtension().appendingPathExtension("cursor.json")
        do {
            let data = try JSONEncoder().encode(cursorTrack)
            try data.write(to: trackURL)
        } catch {
            print("Failed to save cursor track: \(error)")
        }
    }

    private func resetCaptureReferences(keepingOutputURL: Bool = false) {
        stream = nil
        recordingOutput = nil
        startedAt = nil
        elapsed = 0
        cursorTrack = []
        recordedDisplayID = nil
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
