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
