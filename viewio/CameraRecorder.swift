//
//  CameraRecorder.swift
//  viewio
//
//  Records the user's camera to a sidecar MP4 while ScreenCaptureKit
//  records the screen. Also exposes a preview layer for the recording UI.
//

import AppKit
import AVFoundation
import Foundation

final class CameraRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case noCamera
        case setupFailed(String)
        case alreadyRecording
        case notRecording
        case sessionInterrupted

        var errorDescription: String? {
            switch self {
            case .noCamera:
                return "No camera is available."
            case let .setupFailed(reason):
                return reason
            case .alreadyRecording:
                return "The camera is already recording."
            case .notRecording:
                return "The camera is not recording."
            case .sessionInterrupted:
                return "The camera session was interrupted."
            }
        }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.viewio.camera-session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var stopContinuation: CheckedContinuation<URL, Error>?
    private var configurationTask: Task<Void, Never>?
    private let selectedDeviceID: String?

    /// Expose the preview layer for the recording UI. Created lazily.
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    init(selectedDeviceID: String? = nil) {
        self.selectedDeviceID = selectedDeviceID
        super.init()
        configurationTask = Task { [weak self] in
            await self?.configureSession()
        }
    }

    /// Start recording to the given sidecar URL. Returns when recording has begun.
    func startRecording(to outputURL: URL) async throws {
        if let configurationTask {
            _ = await configurationTask.result
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecorderError.notRecording)
                    return
                }
                guard !self.session.inputs.isEmpty else {
                    continuation.resume(throwing: RecorderError.setupFailed("Camera input is not available."))
                    return
                }
                guard !self.movieOutput.isRecording else {
                    continuation.resume(throwing: RecorderError.alreadyRecording)
                    return
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.beginRecording(to: outputURL, continuation: continuation)
            }
        }
    }

    /// Stop recording and return the file URL once the file is finalized.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecorderError.notRecording)
                    return
                }
                guard self.movieOutput.isRecording else {
                    continuation.resume(throwing: RecorderError.notRecording)
                    return
                }
                self.stopContinuation = continuation
                self.movieOutput.stopRecording()
            }
        }
    }

    /// Tear down the session.
    func invalidate() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            self.session.stopRunning()
        }
    }

    // MARK: - Configuration

    private func configureSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                defer { continuation.resume() }
                guard let self else { return }
                self.session.beginConfiguration()
                defer { self.session.commitConfiguration() }

                self.session.sessionPreset = .high

                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera, .external],
                    mediaType: .video,
                    position: .unspecified
                )
                let device: AVCaptureDevice?
                if let selectedDeviceID {
                    device = discovery.devices.first { $0.uniqueID == selectedDeviceID }
                } else {
                    device = AVCaptureDevice.default(for: .video) ?? discovery.devices.first
                }
                guard let device else { return }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input) else { return }
                    self.session.addInput(input)
                    self.videoDeviceInput = input

                    guard self.session.canAddOutput(self.movieOutput) else { return }
                    self.session.addOutput(self.movieOutput)
                } catch {
                    return
                }
            }
        }
    }

    private func beginRecording(
        to outputURL: URL,
        continuation: CheckedContinuation<Void, Error>
    ) {
        try? FileManager.default.removeItem(at: outputURL)
        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        continuation.resume()
    }

    // MARK: - Authorization

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess() async -> Bool {
        let status = authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
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

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        // Nothing extra needed; startRecording already resumed.
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let continuation = self.stopContinuation {
                self.stopContinuation = nil
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: outputFileURL)
                }
            }
        }
    }
}

// MARK: - SwiftUI preview

import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let recorder: CameraRecorder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let previewLayer = recorder.previewLayer
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = previewLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        recorder.previewLayer.frame = nsView.bounds
    }
}
