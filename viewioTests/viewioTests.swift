//
//  viewioTests.swift
//  viewioTests
//

import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import viewio

@MainActor
final class viewioTests: XCTestCase {
    func testEditsAndExportsARealVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        let exportURL = directory.appendingPathComponent("edited.mp4")
        try await makeTestVideo(at: sourceURL)

        let model = EditorModel(sourceURL: sourceURL)
        try await waitUntil {
            if case .ready = model.loadState {
                true
            } else {
                false
            }
        }

        model.playhead = 0.5
        model.cutAtPlayhead()
        XCTAssertEqual(model.clips.count, 2)

        guard let secondClip = model.clips.last else {
            XCTFail("Expected the cut to create a second clip.")
            return
        }
        model.setSpeed(2, for: secondClip.id)
        XCTAssertEqual(model.clips.last?.speed, 2)

        // Deleting a V1 section removes it and keeps at least one clip.
        let firstClipID = try XCTUnwrap(model.clips.first?.id)
        model.selectClip(firstClipID)
        XCTAssertTrue(model.canDeleteSelectedClip)
        let durationBeforeDelete = model.duration
        model.deleteSelectedClip()
        XCTAssertEqual(model.clips.count, 1)
        XCTAssertEqual(model.clips.first?.speed, 2)
        XCTAssertLessThan(model.duration, durationBeforeDelete)
        XCTAssertFalse(model.canDeleteSelectedClip)
        model.deleteSelectedClip()
        XCTAssertEqual(model.clips.count, 1, "The last V1 section must not be deleted.")

        model.playhead = 0.2
        model.addZoomRange()
        XCTAssertEqual(model.zoomRanges.count, 1)
        let zoomID = try XCTUnwrap(model.zoomRanges.first?.id)
        model.setZoomAmount(1.8, for: zoomID)
        model.setZoomEntryAnimation(.easeIn, for: zoomID)
        model.setZoomExitAnimation(.easeOut, for: zoomID)
        XCTAssertEqual(model.selectedZoomRange?.amount, 1.8)
        XCTAssertEqual(model.selectedZoomRange?.entryAnimation, .easeIn)
        XCTAssertEqual(model.selectedZoomRange?.exitAnimation, .easeOut)

        model.export(to: exportURL)
        try await waitUntil(timeout: 20) {
            switch model.exportState {
            case .completed, .failed:
                true
            case .idle, .exporting:
                false
            }
        }

        if case let .failed(message) = model.exportState {
            XCTFail("Export failed: \(message)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func testSpeedChangeScalesZoomRangesWithClip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        try await makeTestVideo(at: sourceURL)

        let model = EditorModel(sourceURL: sourceURL)
        try await waitUntil {
            if case .ready = model.loadState {
                true
            } else {
                false
            }
        }

        let originalDuration = model.duration
        XCTAssertGreaterThan(originalDuration, 0.5)

        // Place a zoom over the middle of the single clip (explicit times).
        model.playhead = 0
        model.addZoomRange()
        let zoomID = try XCTUnwrap(model.zoomRanges.first?.id)
        let zoomStart = originalDuration * 0.2
        let zoomEnd = originalDuration * 0.8
        model.updateZoomRange(ZoomRange(id: zoomID, start: zoomStart, end: zoomEnd))
        let zoom = try XCTUnwrap(model.zoomRanges.first)
        XCTAssertEqual(zoom.start, zoomStart, accuracy: 0.02)
        XCTAssertEqual(zoom.end, zoomEnd, accuracy: 0.02)
        let zoomLength = zoom.end - zoom.start

        let clipID = try XCTUnwrap(model.clips.first?.id)
        model.setSpeed(2, for: clipID)

        XCTAssertEqual(try XCTUnwrap(model.clips.first).speed, 2, accuracy: 0.001)
        XCTAssertEqual(model.duration, originalDuration / 2, accuracy: 0.05)

        let scaled = try XCTUnwrap(model.zoomRanges.first)
        // Zoom times should compress with the clip (2x speed → half duration).
        XCTAssertEqual(scaled.start, zoomStart / 2, accuracy: 0.05)
        XCTAssertEqual(scaled.end, zoomEnd / 2, accuracy: 0.05)
        XCTAssertEqual(scaled.end - scaled.start, zoomLength / 2, accuracy: 0.05)
        XCTAssertLessThanOrEqual(scaled.end, model.duration + 0.02)
    }

    func testSpeedChangeOnLaterClipShiftsTrailingZoom() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        try await makeTestVideo(at: sourceURL)

        let model = EditorModel(sourceURL: sourceURL)
        try await waitUntil {
            if case .ready = model.loadState {
                true
            } else {
                false
            }
        }

        // Cut so we have two clips; zoom only on the second.
        model.playhead = model.duration * 0.5
        model.cutAtPlayhead()
        XCTAssertEqual(model.clips.count, 2)

        let secondLayout = try XCTUnwrap(model.timelineClips.last)
        model.addZoomRange()
        let zoomID = try XCTUnwrap(model.zoomRanges.first?.id)
        let oldZoomStart = secondLayout.start + secondLayout.duration * 0.2
        let oldZoomEnd = secondLayout.start + secondLayout.duration * 0.8
        model.updateZoomRange(ZoomRange(id: zoomID, start: oldZoomStart, end: oldZoomEnd))
        let zoom = try XCTUnwrap(model.zoomRanges.first)
        XCTAssertEqual(zoom.start, oldZoomStart, accuracy: 0.02)

        let secondClipID = try XCTUnwrap(model.clips.last?.id)
        let oldSecondStart = secondLayout.start
        let oldSecondDuration = secondLayout.duration

        model.setSpeed(2, for: secondClipID)

        let newSecond = try XCTUnwrap(model.timelineClips.last)
        XCTAssertEqual(newSecond.start, oldSecondStart, accuracy: 0.02)
        XCTAssertEqual(newSecond.duration, oldSecondDuration / 2, accuracy: 0.05)

        let scaled = try XCTUnwrap(model.zoomRanges.first)
        // Relative position inside the second clip should be preserved at half length.
        let oldRelStart = oldZoomStart - oldSecondStart
        let oldRelEnd = oldZoomEnd - oldSecondStart
        XCTAssertEqual(scaled.start, oldSecondStart + oldRelStart / 2, accuracy: 0.05)
        XCTAssertEqual(scaled.end, oldSecondStart + oldRelEnd / 2, accuracy: 0.05)
    }

    func testCropAppliesToPreviewAndExportSize() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let sourceURL = directory.appendingPathComponent("source.mp4")
        let exportURL = directory.appendingPathComponent("cropped.mp4")
        try await makeTestVideo(at: sourceURL) // 320 × 180

        let model = EditorModel(sourceURL: sourceURL)
        try await waitUntil {
            if case .ready = model.loadState {
                true
            } else {
                false
            }
        }
        XCTAssertEqual(model.videoRenderSize, CGSize(width: 320, height: 180))

        // Center half-frame crop → 160 × 90 render size.
        model.setCropRect(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(model.videoRenderSize, CGSize(width: 160, height: 90))

        // Crop editing shows the full frame again so the rect can be adjusted.
        model.setCropEditing(true)
        XCTAssertEqual(model.videoRenderSize, CGSize(width: 320, height: 180))
        model.setCropEditing(false)
        XCTAssertEqual(model.videoRenderSize, CGSize(width: 160, height: 90))

        model.export(to: exportURL)
        try await waitUntil(timeout: 20) {
            switch model.exportState {
            case .completed, .failed:
                true
            case .idle, .exporting:
                false
            }
        }

        if case let .failed(message) = model.exportState {
            XCTFail("Export failed: \(message)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        let exported = AVURLAsset(url: exportURL)
        let track = try await exported.loadTracks(withMediaType: .video).first
        let naturalSize = try await track?.load(.naturalSize) ?? .zero
        XCTAssertEqual(abs(naturalSize.width), 160, accuracy: 2)
        XCTAssertEqual(abs(naturalSize.height), 90, accuracy: 2)

        // Undo restores the full frame.
        model.undo()
        XCTAssertNil(model.cropRect)
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw TestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func makeTestVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = 320
        let height = 180
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else {
            throw TestError.couldNotCreateFixture
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? TestError.couldNotCreateFixture
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let buffer = makePixelBuffer(width: width, height: height, frame: frame) else {
                throw TestError.couldNotCreateFixture
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: 30)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? TestError.couldNotCreateFixture
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw writer.error ?? TestError.couldNotCreateFixture
        }
    }

    private func makePixelBuffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let blue = UInt8((frame * 7) % 255)
        let green = UInt8((120 + frame * 4) % 255)
        let red = UInt8((220 - frame * 5) % 255)

        for row in 0..<height {
            let rowStart = baseAddress.advanced(by: row * bytesPerRow)
            for column in 0..<width {
                let pixel = rowStart.advanced(by: column * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = blue
                pixel[1] = green
                pixel[2] = red
                pixel[3] = 255
            }
        }
        return pixelBuffer
    }
}

private enum TestError: Error {
    case timedOut
    case couldNotCreateFixture
}

final class CropGeometryTests: XCTestCase {
    func testClampedKeepsRectInsideUnitSquare() {
        let rect = CropGeometry.clamped(CGRect(x: -0.2, y: 0.8, width: 0.5, height: 0.5))
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 1)
        XCTAssertLessThanOrEqual(rect.maxY, 1)
    }

    func testClampedEnforcesMinimumSize() {
        let rect = CropGeometry.clamped(CGRect(x: 0.99, y: 0.99, width: 0.001, height: 0.001))
        XCTAssertEqual(rect.width, CropGeometry.minimumFraction, accuracy: 0.0001)
        XCTAssertEqual(rect.height, CropGeometry.minimumFraction, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(rect.maxX, 1)
        XCTAssertLessThanOrEqual(rect.maxY, 1)
    }

    func testPixelRectProducesEvenSizes() {
        // 0.5 of 333 = 166.5 → even-rounded to 166.
        let pixels = CropGeometry.pixelRect(
            for: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            in: CGSize(width: 333, height: 181)
        )
        XCTAssertEqual(pixels.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(pixels.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(pixels.minX, 83.25, accuracy: 0.001)
        XCTAssertEqual(pixels.minY, 45.25, accuracy: 0.001)
    }

    func testRemapToCropSpace() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let remapped = CropGeometry.remap(CGPoint(x: 0.5, y: 0.75), to: crop)
        XCTAssertEqual(remapped.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(remapped.y, 1.0, accuracy: 0.0001)
        // Outside the crop maps outside 0...1.
        let outside = CropGeometry.remap(CGPoint(x: 0.1, y: 0.5), to: crop)
        XCTAssertLessThan(outside.x, 0)
    }

    func testContainsInCrop() {
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertTrue(CropGeometry.contains(CGPoint(x: 0.5, y: 0.5), in: crop))
        XCTAssertTrue(CropGeometry.contains(CGPoint(x: 0.25, y: 0.75), in: crop))
        XCTAssertFalse(CropGeometry.contains(CGPoint(x: 0.1, y: 0.5), in: crop))
        XCTAssertFalse(CropGeometry.contains(CGPoint(x: 0.5, y: 0.9), in: crop))
    }

    func testAspectRectCentersAndFits() {
        let rect = CropGeometry.rect(
            aspect: 16.0 / 9.0,
            centeredOn: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rect.maxX, 1)
        XCTAssertLessThanOrEqual(rect.maxY, 1)
        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 0.5, accuracy: 0.001)
    }

    /// Pre-record region (Cocoa bottom-left) → video crop (top-left unit square).
    func testCropRectFromCocoaRegion() throws {
        // Display 1920×1080 at origin; region is center half, Cocoa coords.
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let region = CGRect(x: 480, y: 270, width: 960, height: 540)
        let crop = try XCTUnwrap(CropGeometry.cropRect(region: region, withinDisplay: display))
        XCTAssertEqual(crop.minX, 0.25, accuracy: 0.001)
        XCTAssertEqual(crop.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(crop.height, 0.5, accuracy: 0.001)
        // Cocoa y=270 is bottom of region; top of region is y=810.
        // From display top: 1080-810=270 → y = 270/1080 = 0.25.
        XCTAssertEqual(crop.minY, 0.25, accuracy: 0.001)
    }

    func testCropRectNearlyFullReturnsNil() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let almostFull = display.insetBy(dx: 2, dy: 2)
        XCTAssertNil(CropGeometry.cropRect(region: almostFull, withinDisplay: display))
    }
}

final class CropProjectPersistenceTests: XCTestCase {
    private func makeDocument(cropRect: CGRect?) -> ViewioProjectDocument {
        ViewioProjectDocument(
            version: ViewioProjectDocument.currentVersion,
            captureMode: .display,
            clips: [EditClip(sourceStart: 0, sourceEnd: 1, speed: 1)],
            zoomRanges: [],
            cursorSettings: .default,
            motionBlurSettings: .default,
            cameraSettings: .default,
            isBackgroundEnabled: false,
            backgroundCornerRadius: 28,
            backgroundPadding: 0.025,
            cropRect: cropRect,
            wallpaper: nil,
            musicRelativePath: nil,
            musicVolume: 0.5,
            isOriginalAudioMuted: false
        )
    }

    @MainActor
    func testDocumentRoundTripsWithCropRect() throws {
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        let data = try JSONEncoder().encode(makeDocument(cropRect: crop))
        let decoded = try JSONDecoder().decode(ViewioProjectDocument.self, from: data)
        XCTAssertEqual(decoded.cropRect, crop)
    }

    /// Projects saved before the crop feature have no cropRect key — they
    /// must still decode, defaulting to the full frame.
    @MainActor
    func testDocumentWithoutCropRectDecodesAsNil() throws {
        let data = try JSONEncoder().encode(makeDocument(cropRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "cropRect")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ViewioProjectDocument.self, from: legacyData)
        XCTAssertNil(decoded.cropRect)
    }
}

final class CursorTypingHiderTests: XCTestCase {
    private func track(_ samples: [(Double, Double, Double)]) -> [CursorPosition] {
        samples.map { CursorPosition(time: $0.0, x: $0.1, y: $0.2) }
    }

    func testNoKeysProducesNoSegments() {
        let segments = CursorTypingHider.segments(keyTimes: [], cursorTrack: [], duration: 10)
        XCTAssertTrue(segments.isEmpty)
        XCTAssertEqual(CursorTypingHider.opacity(at: 5, in: segments), 1)
    }

    func testKeystrokeHidesUntilMouseMoves() {
        let cursorTrack = track([
            (1.0, 0.5, 0.5),
            (1.25, 0.5, 0.5), // baseline once the reveal grace ends
            (2.0, 0.53, 0.5), // moved past the reveal distance
            (2.5, 0.53, 0.5)
        ])
        let segments = CursorTypingHider.segments(
            keyTimes: [1.0, 1.2],
            cursorTrack: cursorTrack,
            duration: 10
        )
        XCTAssertEqual(segments, [CursorHiddenSegment(start: 1.0, end: 2.0)])
    }

    func testNoMouseMoveStaysHiddenToEnd() {
        let cursorTrack = track([
            (1.0, 0.5, 0.5),
            (2.0, 0.5, 0.5)
        ])
        let segments = CursorTypingHider.segments(
            keyTimes: [1.0, 1.5],
            cursorTrack: cursorTrack,
            duration: 10
        )
        XCTAssertEqual(segments, [CursorHiddenSegment(start: 1.0, end: 10)])
    }

    func testMovementDuringGraceDoesNotReveal() {
        let cursorTrack = track([
            (1.0, 0.5, 0.5),
            (1.1, 0.53, 0.5), // still settling from reaching the keyboard
            (1.2, 0.53, 0.5), // baseline once the reveal grace ends
            (2.0, 0.53, 0.5)
        ])
        let segments = CursorTypingHider.segments(
            keyTimes: [1.0],
            cursorTrack: cursorTrack,
            duration: 10
        )
        XCTAssertEqual(segments, [CursorHiddenSegment(start: 1.0, end: 10)])
    }

    func testNewKeyAfterRevealStartsNewSegment() {
        let cursorTrack = track([
            (1.2, 0.5, 0.5),
            (2.0, 0.53, 0.5), // reveals the first segment
            (5.2, 0.53, 0.5), // baseline for the second segment
            (8.0, 0.53, 0.5)
        ])
        let segments = CursorTypingHider.segments(
            keyTimes: [1.0, 5.0],
            cursorTrack: cursorTrack,
            duration: 10
        )
        XCTAssertEqual(segments, [
            CursorHiddenSegment(start: 1.0, end: 2.0),
            CursorHiddenSegment(start: 5.0, end: 10)
        ])
    }

    func testKeysOutsideDurationAreIgnored() {
        let segments = CursorTypingHider.segments(keyTimes: [12.0], cursorTrack: [], duration: 10)
        XCTAssertTrue(segments.isEmpty)
    }

    func testOpacityFadesAtSegmentEdges() {
        let fade = CursorTypingHider.fadeDuration
        let segments = [CursorHiddenSegment(start: 1.0, end: 2.0)]
        XCTAssertEqual(CursorTypingHider.opacity(at: 1.0 - fade - 0.01, in: segments), 1)
        XCTAssertEqual(CursorTypingHider.opacity(at: 1.0 - fade / 2, in: segments), 0.5, accuracy: 0.001)
        XCTAssertEqual(CursorTypingHider.opacity(at: 1.5, in: segments), 0)
        XCTAssertEqual(CursorTypingHider.opacity(at: 2.0 + fade / 2, in: segments), 0.5, accuracy: 0.001)
        XCTAssertEqual(CursorTypingHider.opacity(at: 2.0 + fade + 0.01, in: segments), 1)
    }
}
