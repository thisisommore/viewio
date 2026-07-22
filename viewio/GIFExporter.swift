//
//  GIFExporter.swift
//  viewio
//
//  Renders the edited composition to an animated GIF via AVAssetReader with a
//  video-composition output (the same engine as AVAssetExportSession, so the
//  custom compositor — wallpaper/camera/zoom/cursor — is baked in) and
//  ImageIO's CGImageDestination.
//
//  Note: AVAssetImageGenerator was tried first, but it fails to deliver source
//  frames to the custom compositor ("Missing source video frame").
//

import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum GIFExporter {
    enum ExportError: LocalizedError {
        case cannotCreateDestination
        case readerFailed(String)
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .cannotCreateDestination:
                return "Unable to create the GIF file."
            case .readerFailed(let message):
                return message
            case .finalizeFailed:
                return "Writing the GIF file failed."
            }
        }
    }

    /// Renders frames at the video composition's frame duration and writes
    /// them to `outputURL`. Progress and completion arrive on the main actor.
    static func export(
        composition: AVComposition,
        videoComposition: AVVideoComposition,
        to outputURL: URL,
        frameRate: Int,
        progress: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        Task.detached {
            do {
                let url = try await render(
                    composition: composition,
                    videoComposition: videoComposition,
                    to: outputURL,
                    frameRate: frameRate,
                    progress: progress
                )
                await completion(.success(url))
            } catch {
                await completion(.failure(error))
            }
        }
    }

    private static func render(
        composition: AVComposition,
        videoComposition: AVVideoComposition,
        to outputURL: URL,
        frameRate: Int,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let duration = try await composition.load(.duration).seconds
        guard duration > 0, frameRate > 0 else {
            throw ExportError.cannotCreateDestination
        }

        // CGImageDestination refuses to finalize if more images are added than
        // the declared capacity, and the reader can emit floor(frames) + 1
        // frames (one at pts 0 … up to one at exactly the duration). Add
        // slack so the real count always fits.
        let estimatedFrames = max(1, Int((duration * Double(frameRate)).rounded(.up)) + 2)
        let frameDelay = 1.0 / Double(frameRate)

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            estimatedFrames,
            nil
        ) else {
            throw ExportError.cannotCreateDestination
        }

        // Loop forever.
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]
        ]

        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ExportError.readerFailed("Unable to read this recording for GIF export.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "Could not start reading the recording.")
        }

        // Match the compositor's fixed sRGB pipeline so colors don't wash out.
        let ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { continue }
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)

            let position = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            await progress(min(1, max(0, position / duration)))
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "Reading the recording failed.")
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.finalizeFailed
        }
        return outputURL
    }
}
