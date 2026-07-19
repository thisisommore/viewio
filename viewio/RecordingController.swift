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

struct CameraDevice: Identifiable, Equatable {
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

struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    /// Frame in Core Graphics global space (top-left origin).
    let frame: CGRect
    let isOnScreen: Bool

    var idValue: UInt32 { id }
}

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case display
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Full Screen"
        case .window: "Window"
        }
    }
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
    /// Point size of the captured region on screen, so the redrawn cursor can
    /// match the real cursor's size (pixels per point = render px / points).
    var captureSizePoints: CGSize?

    static let currentVersion = 2
    static let videoTopLeft = "videoTopLeft"
    static let cocoaBottomLeft = "cocoaBottomLeft"
}

struct ClickEvent: Codable, Equatable {
    let time: TimeInterval
    let button: Int
}

/// Keystroke timestamp captured during recording, used by the editor's
/// "hide cursor when typing" option. Only the time is stored — never the key.
struct KeyEvent: Codable, Equatable {
    let time: TimeInterval
}

@MainActor
final class RecordingController: NSObject, ObservableObject {
    /// Which controller last presented the shared system content picker.
    private static weak var activePickerClient: RecordingController?

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case stopping
        case failed(String)
        case finished(URL)
        /// Editing a saved `.viewioproj` package.
        case project(URL)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var captureSystemAudio = true
    @Published var captureMicrophone = false
    @Published var captureCamera = false
    @Published var selectedCameraID: String?
    @Published private(set) var availableCameras: [CameraDevice] = []
    @Published var selectedMicrophoneID: String?
    @Published private(set) var availableMicrophones: [AudioDevice] = []
    @Published var captureMode: CaptureMode = .display {
        didSet {
            if captureMode == .window {
                discoverWindows()
            }
        }
    }
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var availableDisplays: [DisplayInfo] = []
    @Published var selectedWindowID: CGWindowID?
    @Published private(set) var availableWindows: [WindowInfo] = []
    @Published var selectedResolution: RecordingResolution = .native
    @Published var selectedFrameRate: RecordingFrameRate = .fps60
    @Published var cameraCorner: CameraCorner = .bottomRight
    /// Filter chosen in the native system content picker. When set, recording
    /// captures exactly this content; the display/window selection below is
    /// then synced only as a best effort for the UI.
    @Published private(set) var pickedFilter: SCContentFilter?
    /// Best-effort display name of the picked content.
    @Published private(set) var pickedContentName: String?
    /// Shows the confirmation alert before discarding a finished recording.
    @Published var showsDiscardRecordingConfirmation = false
    /// True while an in-progress recording is being torn down without saving.
    @Published private(set) var isDiscarding = false

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private(set) var cameraRecorder: CameraRecorder?
    private var cameraOutputURL: URL?
    private var cameraCornerURL: URL?
    private var overlayWindow: CameraOverlayWindowController?
    private var startedAt: Date?
    private var timer: Timer?
    private var cursorTimer: Timer?
    private var cursorEventMonitor: Any?
    private var keyEventMonitor: Any?
    /// Thread-safe buffer so global mouse/key monitors don't flood MainActor
    /// (which froze playhead-driven cursor overlays in other editor windows).
    private let cursorBuffer = CursorTrackBuffer()
    private var recordedDisplayID: CGDirectDisplayID?
    /// Global Cocoa bounds (points, origin bottom-left) of the captured display.
    private var captureBounds: CGRect = .zero
    /// Live Accessibility trust state, refreshed so the start page can warn
    /// that typing detection ("hide cursor while typing") won't capture keys.
    @Published private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    private var accessibilityTimer: Timer?
    /// Host time when capture is considered started (aligns cursor track to video).
    private var recordingHostStart: TimeInterval?
    /// When set, stop/finish callbacks delete partial files and return to idle.
    private var discardRequested = false
    /// Ensures discard/finalize teardown runs only once per capture session.
    private var captureTeardownHandled = false

    var isRecording: Bool {
        switch state {
        case .preparing, .recording, .stopping:
            true
        case .idle, .failed, .finished, .project:
            false
        }
    }

    override init() {
        super.init()
        discoverDisplays()
        discoverWindows()
        discoverCameras()
        discoverMicrophones()
        configureContentPicker()
        if !AXIsProcessTrusted() {
            // Registers the app in System Settings → Accessibility so the
            // toggle exists to flip (the system prompt is shown at most once;
            // later calls are silent no-ops while untrusted).
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityTrust()
            }
        }
    }

    private func refreshAccessibilityTrust() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
    }

    /// Asks the system for Accessibility access. macOS shows its own modal
    /// (with an "Open System Settings" shortcut) — no need to open the pane.
    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func startRecording() {
        guard !isRecording else { return }
        // Screen capture + global input monitors are single-owner in practice.
        if ViewioSessionRegistry.shared.isRecordingElsewhere(than: self) {
            state = .failed("Another window is already recording. Stop that recording first.")
            return
        }

        discardRequested = false
        isDiscarding = false
        captureTeardownHandled = false
        state = .preparing
        elapsed = 0

        Task {
            do {
                if shouldAbortStart() { return }
                if captureMicrophone {
                    let authorized = await requestMicrophoneAuthorization()
                    guard authorized else {
                        throw RecordingError.microphoneDenied
                    }
                }
                if shouldAbortStart() { return }
                if captureCamera {
                    let authorized = await CameraRecorder.requestAccess()
                    guard authorized else {
                        throw RecordingError.cameraDenied
                    }
                }
                if shouldAbortStart() { return }
                try await configureAndStartCapture()
                if discardRequested {
                    await stopCaptureForDiscard()
                    return
                }
                if captureTeardownHandled { return }
            } catch is CancellationError {
                if discardRequested || isDiscarding {
                    completeInProgressDiscard()
                }
            } catch {
                if discardRequested || isDiscarding {
                    completeInProgressDiscard()
                } else if !captureTeardownHandled {
                    finishWithError(error)
                }
            }
        }
    }

    /// Returns true when the start task should exit because the user discarded
    /// mid-prepare (or teardown already ran). Completes discard if still pending.
    private func shouldAbortStart() -> Bool {
        if captureTeardownHandled { return true }
        if discardRequested {
            completeInProgressDiscard()
            return true
        }
        return false
    }

    func stopRecording() {
        guard let stream, isRecording, !discardRequested else { return }
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

    /// Abandons an in-progress capture, deletes any partial files, and returns
    /// to the new-recording setup UI.
    func discardInProgressRecording() {
        switch state {
        case .preparing, .recording:
            break
        default:
            return
        }

        discardRequested = true
        isDiscarding = true
        state = .stopping
        stopTimer()
        stopCursorTracking()

        Task {
            await stopCaptureForDiscard()
        }
    }

    func dismissError() {
        if case .failed = state {
            state = .idle
        }
    }

    /// Presents the native macOS content picker (live display/window thumbnails).
    /// The choice is mapped back onto `captureMode` + selection IDs in `applyPickedFilter`.
    func presentContentPicker() {
        Self.activePickerClient = self
        let picker = SCContentSharingPicker.shared
        // The daemon rejects present() unless the picker is in the active state.
        picker.isActive = true
        picker.present()
    }

    private func configureContentPicker() {
        let picker = SCContentSharingPicker.shared
        var configuration = picker.configuration ?? SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        picker.configuration = configuration
        picker.add(self)
    }

    deinit {
        // Timers / picker cleanup: RecordingController lives on the main actor;
        // window teardown also runs there for StateObject.
        accessibilityTimer?.invalidate()
        SCContentSharingPicker.shared.remove(self)
    }

    /// Records exactly what the user picked in the system picker. The legacy
    /// display/window selection is synced only as a best effort for the UI.
    private func applyPickedFilter(_ filter: SCContentFilter) async {
        pickedFilter = filter
        captureMode = filter.style == .window ? .window : .display

        // The filter's own included content is the only reliable identity —
        // contentRect can lack the global origin for display picks.
        if let window = filter.includedWindows.first {
            let appName = window.owningApplication?.applicationName ?? "Unknown"
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pickedContentName = title.isEmpty ? appName : "\(appName) — \(title)"
            selectedWindowID = window.windowID
            return
        }
        if let display = filter.includedDisplays.first {
            pickedContentName = availableDisplays.first(where: { $0.id == display.displayID })?.name
            selectedDisplayID = display.displayID
            return
        }

        // Fallback: match live shareable content by frame (best effort, UI only).
        guard let content = try? await SCShareableContent.current else {
            pickedContentName = nil
            return
        }
        switch filter.style {
        case .window:
            if let window = content.windows.first(where: { framesMatch($0.frame, filter.contentRect) }) {
                let appName = window.owningApplication?.applicationName ?? "Unknown"
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                pickedContentName = title.isEmpty ? appName : "\(appName) — \(title)"
                selectedWindowID = window.windowID
            } else {
                pickedContentName = nil
            }
        case .display:
            if let display = content.displays.first(where: { framesMatch($0.frame, filter.contentRect) }) {
                pickedContentName = availableDisplays.first(where: { $0.id == display.displayID })?.name
                selectedDisplayID = display.displayID
            } else {
                pickedContentName = nil
            }
        default:
            pickedContentName = nil
        }
    }

    /// The picker's contentRect can drift from the live frame by a fraction of
    /// a point, so frames are matched with tolerance instead of exact equality.
    private func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// Asks for confirmation before discarding a finished recording; the
    /// alert lives in ContentView and calls `discardRecording()` on confirm.
    func requestNewRecording() {
        switch state {
        case .finished, .project:
            showsDiscardRecordingConfirmation = true
        default:
            break
        }
    }

    /// Deletes a finished recording (or closes a project without deleting it)
    /// and returns to the new-recording setup UI.
    func discardRecording() {
        switch state {
        case let .finished(url):
            removeRecordingFiles(at: url)
        case .project:
            break
        default:
            break
        }
        resetCaptureReferences()
        state = .idle
    }

    /// Opens a saved project from the idle screen.
    func openProject(_ url: URL) {
        guard case .idle = state else { return }
        state = .project(url)
    }

    /// After Save Project from a fresh recording, switch to project mode and
    /// remove the temporary Application Support capture files.
    func adoptSavedProject(_ projectURL: URL) {
        if case let .finished(mediaURL) = state {
            // Only delete App Support temps — never a file already inside the project.
            let projectPath = projectURL.standardizedFileURL.path
            if !mediaURL.standardizedFileURL.path.hasPrefix(projectPath) {
                removeRecordingFiles(at: mediaURL)
            }
        }
        state = .project(projectURL)
    }

    /// Stops the live stream (if any) after a discard request. Finish callbacks
    /// or this method itself then delete partial files and return to idle.
    private func stopCaptureForDiscard() async {
        cameraRecorder?.invalidate()
        cameraRecorder = nil

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // Stream may already be stopped; still finish the discard path.
            }
        }

        // Finish delegate usually runs first; this covers discard while still
        // preparing (no stream yet) or when the finish callback never arrives.
        completeInProgressDiscard()
    }

    /// Idempotent: safe if both the stream finish callback and discard path run.
    private func completeInProgressDiscard() {
        guard !captureTeardownHandled else { return }
        captureTeardownHandled = true

        let url = outputURL
        cameraRecorder?.invalidate()
        if let url {
            removeRecordingFiles(at: url)
        }
        discardRequested = false
        isDiscarding = false
        resetCaptureReferences()
        state = .idle
    }

    private func removeRecordingFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: cameraSidecarURL(for: url))
        try? FileManager.default.removeItem(at: cameraCornerSidecarURL(for: url))
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("cursor.json"))
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("clicks.json"))
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("keys.json"))
    }

    private func configureAndStartCapture() async throws {
        if discardRequested || captureTeardownHandled {
            throw CancellationError()
        }
        let content = try await SCShareableContent.current
        if discardRequested || captureTeardownHandled {
            throw CancellationError()
        }
        let displays = content.displays
        guard !displays.isEmpty else {
            throw RecordingError.noDisplay
        }

        // Resolve the target display and the content filter up front. For window
        // capture we lock the cursor bounds to the window frame; for display
        // capture we use the selected display.
        let targetDisplayID: CGDirectDisplayID
        let capturedWindow: SCWindow?
        if let pickedFilter {
            // The picker filter is authoritative — bounds come straight from it.
            capturedWindow = nil
            captureBounds = cocoaFrame(forWindowFrame: pickedFilter.contentRect)
            targetDisplayID = displayIDContainingWindow(frameInCGSpace: pickedFilter.contentRect) ?? displays[0].displayID
        } else if captureMode == .window {
            guard let selectedWindowID,
                  let window = content.windows.first(where: { $0.windowID == selectedWindowID }) else {
                throw RecordingError.noWindow
            }
            capturedWindow = window
            captureBounds = cocoaFrame(forWindowFrame: window.frame)
            targetDisplayID = displayIDContainingWindow(frameInCGSpace: window.frame) ?? displays[0].displayID
        } else {
            capturedWindow = nil
            let display: SCDisplay
            if let selectedDisplayID,
               let selected = displays.first(where: { $0.displayID == selectedDisplayID }) {
                display = selected
            } else {
                display = displays[0]
            }
            targetDisplayID = display.displayID
            captureBounds = displayBoundsInCocoaSpace(displayID: display.displayID)
        }
        recordedDisplayID = targetDisplayID

        let outputURL = try makeOutputURL()
        let cameraOutputURL = captureCamera ? cameraSidecarURL(for: outputURL) : nil
        let cameraCornerURL = captureCamera ? cameraCornerSidecarURL(for: outputURL) : nil
        self.outputURL = outputURL
        self.cameraOutputURL = cameraOutputURL
        self.cameraCornerURL = cameraCornerURL

        // Pick the screen codec early (camera sidecar uses AVCapture defaults).
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        let hevc = AVVideoCodecType.hevc
        if recordingConfiguration.availableVideoCodecTypes.contains(hevc) {
            recordingConfiguration.videoCodecType = hevc
        } else {
            recordingConfiguration.videoCodecType = .h264
        }

        // Start the camera session early so its preview layer is ready, and
        // create the on-screen floating overlay before capturing content so we
        // can exclude that window from a full-screen recording.
        if captureCamera {
            let cameraRecorder = CameraRecorder(selectedDeviceID: selectedCameraID)
            self.cameraRecorder = cameraRecorder
            let overlay = CameraOverlayWindowController(
                recorder: cameraRecorder,
                displayID: targetDisplayID,
                corner: cameraCorner
            ) { [weak self] corner in
                self?.cameraCorner = corner
            }
            self.overlayWindow = overlay
            overlay.show()
        }

        // Build the content filter. Full-screen capture needs a fresh lookup so
        // the camera overlay window can be excluded; window capture records only
        // the chosen window, so the overlay is naturally omitted.
        let filter: SCContentFilter
        let nativeSize: CGSize
        if let pickedFilter {
            let scale = CGFloat(pickedFilter.pointPixelScale)
            nativeSize = CGSize(
                width: pickedFilter.contentRect.width * scale,
                height: pickedFilter.contentRect.height * scale
            )
            // Rebuild display filters so the camera overlay stays excluded;
            // other filter styles never include it anyway. Identity comes from
            // the filter's own includedDisplays — never frame matching.
            if pickedFilter.style == .display, let display = pickedFilter.includedDisplays.first {
                let excludedWindows: [SCWindow]
                if let overlayWindow,
                   let windowNumber = overlayWindow.windowNumber,
                   let overlaySCWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) {
                    excludedWindows = [overlaySCWindow]
                } else {
                    excludedWindows = []
                }
                filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            } else {
                filter = pickedFilter
            }
        } else if captureMode == .window, let window = capturedWindow {
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let nativeFromFilter = CGSize(
                width: filter.contentRect.width * scale,
                height: filter.contentRect.height * scale
            )
            let nativeFromWindow = CGSize(
                width: window.frame.width * scale,
                height: window.frame.height * scale
            )
            nativeSize = CGSize(
                width: max(nativeFromFilter.width, nativeFromWindow.width),
                height: max(nativeFromFilter.height, nativeFromWindow.height)
            )
        } else {
            let captureContent = try await SCShareableContent.current
            let excludedWindows: [SCWindow]
            if let overlayWindow,
               let windowNumber = overlayWindow.windowNumber,
               let overlaySCWindow = captureContent.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) {
                excludedWindows = [overlaySCWindow]
            } else {
                excludedWindows = []
            }
            let display: SCDisplay
            if let selectedDisplayID,
               let selected = captureContent.displays.first(where: { $0.displayID == selectedDisplayID }) {
                display = selected
            } else {
                display = captureContent.displays[0]
            }
            filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let scale = CGFloat(filter.pointPixelScale)
            let nativeFromFilter = CGSize(
                width: filter.contentRect.width * scale,
                height: filter.contentRect.height * scale
            )
            let nativeFromDisplay = CGSize(
                width: CGDisplayPixelsWide(display.displayID),
                height: CGDisplayPixelsHigh(display.displayID)
            )
            nativeSize = CGSize(
                width: max(nativeFromFilter.width, nativeFromDisplay.width),
                height: max(nativeFromFilter.height, nativeFromDisplay.height)
            )
        }
        let configuration = SCStreamConfiguration()

        let outputSize = selectedResolution.outputSize(forNative: nativeSize)
        // Keep exact aspect of the source so scalesToFit never letterboxes
        // (letterboxing would desync normalized cursor coords from pixels).
        configuration.width = max(2, Int(outputSize.width.rounded()) & ~1)
        configuration.height = max(2, Int(outputSize.height.rounded()) & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: selectedFrameRate.timescale)
        configuration.queueDepth = 8
        // BGRA keeps sharp UI text better than subsampled YUV for screen content.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Capture in sRGB so P3 display content is color-managed at the source
        // instead of shifting later in the pipeline.
        configuration.colorSpaceName = CGColorSpace.sRGB
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

        let recordingOutput = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: self
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        try stream.addRecordingOutput(recordingOutput)

        self.outputURL = outputURL
        self.recordingOutput = recordingOutput
        self.stream = stream

        if discardRequested || captureTeardownHandled {
            throw CancellationError()
        }

        try await stream.startCapture()

        if discardRequested || captureTeardownHandled {
            // Stream is live but the user already discarded — caller stops it.
            return
        }

        if captureCamera, let cameraRecorder, let cameraOutputURL {
            try await cameraRecorder.startRecording(to: cameraOutputURL)
        }

        // Do not start the cursor clock here. `startCapture()` only means the
        // stream is live; SCRecordingOutput can begin writing its first video
        // frame a little later. `recordingOutputDidStartRecording` is the
        // matching zero point for the movie timeline.
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

    private func cameraSidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("camera.mp4")
    }

    private func cameraCornerSidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("cameracorner.json")
    }

    private func saveCameraCorner(for videoURL: URL) {
        let url = cameraCornerSidecarURL(for: videoURL)
        let settings = CameraSettings(isEnabled: true, corner: cameraCorner, size: CameraOverlayGeometry.defaultSize)
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: url)
        } catch {
            print("Failed to save camera corner: \(error)")
        }
    }

    private func recordingDidStart() {
        guard case .preparing = state else {
            // Discard was requested before the first frame landed — stop now.
            if discardRequested {
                Task { await stopCaptureForDiscard() }
            }
            return
        }
        if discardRequested {
            Task { await stopCaptureForDiscard() }
            return
        }
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

    /// Converts a Core Graphics window frame (top-left origin global space) to
    /// the Cocoa global point space used by `NSEvent.mouseLocation`.
    private func cocoaFrame(forWindowFrame frame: CGRect) -> CGRect {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let cocoaY = mainBounds.height - (frame.origin.y + frame.size.height)
        return CGRect(
            x: frame.origin.x,
            y: cocoaY,
            width: frame.size.width,
            height: frame.size.height
        )
    }

    /// Returns the display ID that contains the given window frame.
    private func displayIDContainingWindow(frameInCGSpace frame: CGRect) -> CGDirectDisplayID? {
        let maxDisplays: UInt32 = 8
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var matchingCount: UInt32 = 0
        let error = CGGetDisplaysWithRect(frame, maxDisplays, &displayIDs, &matchingCount)
        guard error == .success, matchingCount > 0 else { return nil }
        return displayIDs[0]
    }

    private func recordingDidFinish() {
        stopTimer()
        stopCursorTracking()
        let shouldDiscard = discardRequested || isDiscarding
        Task {
            if shouldDiscard {
                completeInProgressDiscard()
                return
            }
            if captureTeardownHandled { return }
            if let cameraRecorder {
                _ = try? await cameraRecorder.stopRecording()
            }
            await finalizeRecording()
        }
    }

    private func finalizeRecording() async {
        if discardRequested || isDiscarding {
            completeInProgressDiscard()
            return
        }
        guard !captureTeardownHandled else { return }
        captureTeardownHandled = true

        guard let outputURL else {
            state = .failed("The recording finished without creating a video file.")
            resetCaptureReferences()
            return
        }

        saveCursorTrack(for: outputURL)
        saveKeyEvents(for: outputURL)
        saveCameraCorner(for: outputURL)
        resetCaptureReferences(keepingOutputURL: true)
        state = .finished(outputURL)
    }

    private func finishWithError(_ error: Error) {
        if discardRequested || isDiscarding {
            completeInProgressDiscard()
            return
        }
        guard !captureTeardownHandled else { return }
        captureTeardownHandled = true
        stopTimer()
        stopCursorTracking()
        cameraRecorder?.invalidate()
        discardRequested = false
        isDiscarding = false
        resetCaptureReferences()
        state = .failed(error.localizedDescription)
    }

    private func startTimer() {
        stopTimer()
        // Fire on the main run loop directly — no Task hop (keeps elapsed
        // updates from contending with editor playhead under load).
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startCursorTracking() {
        stopCursorTracking()
        guard recordedDisplayID != nil, captureBounds.width > 1, captureBounds.height > 1 else { return }
        guard let hostStart = recordingHostStart else { return }
        let bounds = captureBounds
        cursorBuffer.begin(hostStart: hostStart, bounds: bounds)

        // Sample cursor at least as often as capture FPS (capped for overhead).
        let cursorHz = min(60.0, max(30.0, Double(selectedFrameRate.rawValue)))
        // Main run loop + common modes so tracking continues during UI tracking loops.
        // Work stays in the buffer (lock-based) so we never enqueue MainActor Tasks.
        let timer = Timer(timeInterval: 1.0 / cursorHz, repeats: true) { [weak self] _ in
            self?.cursorBuffer.sampleMouse()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
        // Polling alone can be a frame late while the pointer is moving. Listen
        // to the real global mouse events as well, so the track contains the
        // exact position and timestamp used for a move or click.
        // Monitors deliver off-main; CursorTrackBuffer is thread-safe.
        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown
        ]
        cursorEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.cursorBuffer.recordMouseEvent(event)
        }
        // Keystroke times feed the editor's "hide cursor when typing" option.
        // Global key monitors only fire when the app is trusted for
        // Accessibility — without it this recording just has no typing data
        // (only timestamps are captured, never key identities). The start
        // page surfaces the missing permission with a request button.
        keyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.cursorBuffer.recordKeyEvent(event)
        }
        // Immediate sample at t≈0 so the first frame is aligned.
        cursorBuffer.sampleMouse()
    }

    private func stopCursorTracking() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        if let cursorEventMonitor {
            NSEvent.removeMonitor(cursorEventMonitor)
            self.cursorEventMonitor = nil
        }
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func saveCursorTrack(for videoURL: URL) {
        let snapshot = cursorBuffer.snapshot()
        guard !snapshot.positions.isEmpty else { return }
        let trackURL = videoURL.deletingPathExtension().appendingPathExtension("cursor.json")
        do {
            let file = CursorTrackFile(
                version: CursorTrackFile.currentVersion,
                coordinateSpace: CursorTrackFile.videoTopLeft,
                samples: snapshot.positions,
                captureSizePoints: captureBounds.size
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: trackURL)
        } catch {
            print("Failed to save cursor track: \(error)")
        }

        guard !snapshot.clicks.isEmpty else { return }
        let clicksURL = videoURL.deletingPathExtension().appendingPathExtension("clicks.json")
        do {
            let data = try JSONEncoder().encode(snapshot.clicks)
            try data.write(to: clicksURL)
        } catch {
            print("Failed to save click events: \(error)")
        }
    }

    private func saveKeyEvents(for videoURL: URL) {
        let keys = cursorBuffer.snapshot().keys
        guard !keys.isEmpty else { return }
        let keysURL = videoURL.deletingPathExtension().appendingPathExtension("keys.json")
        do {
            // Monitor callbacks can arrive slightly out of order.
            let data = try JSONEncoder().encode(keys.sorted { $0.time < $1.time })
            try data.write(to: keysURL)
        } catch {
            print("Failed to save key events: \(error)")
        }
    }

    private func resetCaptureReferences(keepingOutputURL: Bool = false) {
        stream = nil
        recordingOutput = nil
        startedAt = nil
        recordingHostStart = nil
        elapsed = 0
        cursorBuffer.reset()
        recordedDisplayID = nil
        captureBounds = .zero
        overlayWindow?.close()
        overlayWindow = nil
        cameraRecorder?.invalidate()
        cameraRecorder = nil
        if !keepingOutputURL {
            outputURL = nil
            cameraOutputURL = nil
            cameraCornerURL = nil
        }
    }

    private func discoverCameras() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let defaultDevice = AVCaptureDevice.default(for: .video)
        availableCameras = session.devices.map { device in
            CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultDevice?.uniqueID
            )
        }
        if selectedCameraID == nil, let first = availableCameras.first {
            selectedCameraID = first.id
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

    func discoverWindows() {
        Task {
            do {
                let content = try await SCShareableContent.current
                let ownBundleID = Bundle.main.bundleIdentifier
                let windows = content.windows.compactMap { window -> WindowInfo? in
                    guard window.isOnScreen else { return nil }
                    let frame = window.frame
                    guard frame.width > 32, frame.height > 32 else { return nil }
                    if let app = window.owningApplication,
                       app.bundleIdentifier == ownBundleID {
                        return nil
                    }
                    return WindowInfo(
                        id: window.windowID,
                        title: window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled",
                        appName: window.owningApplication?.applicationName ?? "Unknown",
                        frame: frame,
                        isOnScreen: window.isOnScreen
                    )
                }
                await MainActor.run {
                    self.availableWindows = windows
                    if self.selectedWindowID == nil, let first = windows.first {
                        self.selectedWindowID = first.id
                    }
                }
            } catch {
                await MainActor.run {
                    self.availableWindows = []
                }
            }
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

    func requestCameraAuthorizationIfNeeded() async -> Bool {
        await CameraRecorder.requestAccess()
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

extension RecordingController: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            picker.isActive = false
            guard let self else { return }
            // Shared picker notifies every observer — only the presenter applies.
            guard Self.activePickerClient === self else { return }
            Self.activePickerClient = nil
            await self.applyPickedFilter(filter)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            picker.isActive = false
            if let self, Self.activePickerClient === self {
                Self.activePickerClient = nil
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        print("Content picker failed to start: \(error.localizedDescription)")
    }
}

private enum RecordingError: LocalizedError {
    case noDisplay
    case noWindow
    case microphoneDenied
    case cameraDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display is available to record."
        case .noWindow:
            "The selected window is no longer available. Choose another window and try again."
        case .microphoneDenied:
            "Microphone access was denied. Enable it in System Settings to record microphone audio."
        case .cameraDenied:
            "Camera access was denied. Enable it in System Settings to record camera video."
        }
    }
}

// MARK: - Cursor track buffer

/// Collects cursor/click/key samples from timers and global event monitors
/// without hopping onto MainActor for every mouse move. That keeps editor
/// playhead updates (and the live cursor overlay) responsive while another
/// window is recording.
private final class CursorTrackBuffer: @unchecked Sendable {
    struct Snapshot {
        var positions: [CursorPosition]
        var clicks: [ClickEvent]
        var keys: [KeyEvent]
    }

    private let lock = NSLock()
    private var hostStart: TimeInterval?
    private var bounds: CGRect = .zero
    private var positions: [CursorPosition] = []
    private var clicks: [ClickEvent] = []
    private var keys: [KeyEvent] = []
    private var wasLeftButtonDown = false

    func begin(hostStart: TimeInterval, bounds: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        self.hostStart = hostStart
        self.bounds = bounds
        positions = []
        clicks = []
        keys = []
        wasLeftButtonDown = false
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        hostStart = nil
        bounds = .zero
        positions = []
        clicks = []
        keys = []
        wasLeftButtonDown = false
    }

    func sampleMouse() {
        lock.lock()
        guard let hostStart, bounds.width > 1, bounds.height > 1 else {
            lock.unlock()
            return
        }
        let bounds = self.bounds
        let start = hostStart
        lock.unlock()

        let time = ProcessInfo.processInfo.systemUptime - start
        appendSample(at: NSEvent.mouseLocation, time: time, bounds: bounds)
        recordClickIfNeeded(at: time)
    }

    func recordMouseEvent(_ event: NSEvent) {
        lock.lock()
        guard let hostStart, bounds.width > 1, bounds.height > 1 else {
            lock.unlock()
            return
        }
        let bounds = self.bounds
        let start = hostStart
        lock.unlock()

        // Global-monitor events normally have no window, in which case AppKit
        // provides a screen-space point. Convert defensively if one does.
        let location: CGPoint
        if let window = event.window {
            location = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            location = event.locationInWindow
        }
        let time = max(0, event.timestamp - start)
        appendSample(at: location, time: time, bounds: bounds)

        if event.type == .leftMouseDown {
            recordClick(at: time)
            lock.lock()
            wasLeftButtonDown = true
            lock.unlock()
        }
    }

    func recordKeyEvent(_ event: NSEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard let hostStart else { return }
        let time = max(0, event.timestamp - hostStart)
        keys.append(KeyEvent(time: time))
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(positions: positions, clicks: clicks, keys: keys)
    }

    private func appendSample(at location: CGPoint, time: TimeInterval, bounds: CGRect) {
        let relativeX = (location.x - bounds.origin.x) / bounds.width
        // Cocoa Y is bottom-up; store already flipped to video top-left (0 = top)
        // so playback never double-flips or mixes conventions.
        let relativeYFromTop = 1 - (location.y - bounds.origin.y) / bounds.height
        let position = CursorPosition(
            time: max(0, time),
            x: max(0, min(1, relativeX)),
            y: max(0, min(1, relativeYFromTop))
        )

        lock.lock()
        defer { lock.unlock() }
        // Event monitors are asynchronous, so an event can arrive just after a
        // timer sample. Keep the timeline ordered for interpolation in preview.
        if let last = positions.last, position.time < last.time {
            let index = positions.firstIndex { $0.time > position.time } ?? positions.endIndex
            positions.insert(position, at: index)
        } else {
            positions.append(position)
        }
    }

    private func recordClickIfNeeded(at time: TimeInterval) {
        let isDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        lock.lock()
        let wasDown = wasLeftButtonDown
        wasLeftButtonDown = isDown
        lock.unlock()
        if isDown && !wasDown {
            recordClick(at: time)
        }
    }

    private func recordClick(at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        // A timer sample and the matching mouse-down event can arrive together.
        // Keep one click at the event's precise timestamp.
        guard clicks.last.map({ abs($0.time - time) > 0.04 }) ?? true else { return }
        clicks.append(ClickEvent(time: time, button: 0))
    }
}
