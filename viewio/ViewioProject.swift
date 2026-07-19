//
//  ViewioProject.swift
//  viewio
//
//  On-disk project package (`.viewioproj`) that keeps media + edit settings
//  so a recording can be reopened later with everything still editable.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
    static var viewioProject: UTType {
        UTType(exportedAs: "app.viewio.project")
    }
}

/// Wallpaper reference stored inside a project.
enum ProjectWallpaperRef: Codable, Equatable {
    case bundled(id: String)
    case custom(relativePath: String, id: String)

    private enum CodingKeys: String, CodingKey {
        case kind, id, relativePath
    }

    private enum Kind: String, Codable {
        case bundled
        case custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .bundled:
            self = .bundled(id: try container.decode(String.self, forKey: .id))
        case .custom:
            self = .custom(
                relativePath: try container.decode(String.self, forKey: .relativePath),
                id: try container.decode(String.self, forKey: .id)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bundled(id):
            try container.encode(Kind.bundled, forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .custom(relativePath, id):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
            try container.encode(id, forKey: .id)
        }
    }
}

/// Serializable edit document stored as `project.json` inside a `.viewioproj` package.
struct ViewioProjectDocument: Codable, Equatable {
    var version: Int
    var captureMode: CaptureMode
    var clips: [EditClip]
    var zoomRanges: [ZoomRange]
    var cursorSettings: CursorSettings
    var motionBlurSettings: MotionBlurSettings
    var cameraSettings: CameraSettings
    var isBackgroundEnabled: Bool
    var backgroundCornerRadius: Double
    var backgroundPadding: Double
    var wallpaper: ProjectWallpaperRef?
    var musicRelativePath: String?
    var musicVolume: Double
    var isOriginalAudioMuted: Bool

    static let currentVersion = 1
}

enum ViewioProject {
    static let pathExtension = "viewioproj"
    static let documentFileName = "project.json"
    static let mediaDirectoryName = "media"
    static let assetsDirectoryName = "assets"
    static let screenFileName = "screen.mp4"
    static let cameraFileName = "screen.camera.mp4"
    static let cursorFileName = "screen.cursor.json"
    static let clicksFileName = "screen.clicks.json"
    static let keysFileName = "screen.keys.json"
    static let cameraSettingsFileName = "screen.cameracorner.json"

    struct Loaded {
        let projectURL: URL
        let mediaURL: URL
        let document: ViewioProjectDocument
    }

    static func mediaDirectory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(mediaDirectoryName, isDirectory: true)
    }

    static func assetsDirectory(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(assetsDirectoryName, isDirectory: true)
    }

    static func screenMediaURL(in projectURL: URL) -> URL {
        mediaDirectory(in: projectURL).appendingPathComponent(screenFileName)
    }

    static func documentURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(documentFileName)
    }

    static func load(from projectURL: URL) throws -> Loaded {
        let docURL = documentURL(in: projectURL)
        let data = try Data(contentsOf: docURL)
        let document = try JSONDecoder().decode(ViewioProjectDocument.self, from: data)
        let mediaURL = screenMediaURL(in: projectURL)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw ViewioProjectError.missingScreenMedia
        }
        return Loaded(projectURL: projectURL, mediaURL: mediaURL, document: document)
    }

    /// Writes a self-contained project package at `projectURL`.
    static func save(
        to projectURL: URL,
        sourceMediaURL: URL,
        document: ViewioProjectDocument,
        musicSourceURL: URL?,
        customWallpaperURL: URL?,
        customWallpaperID: String?
    ) throws -> ViewioProjectDocument {
        let fm = FileManager.default
        // Write to a temp package first so Save over the open project doesn't
        // delete media we're still copying from.
        let tempURL = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)

        let mediaDir = mediaDirectory(in: tempURL)
        let assetsDir = assetsDirectory(in: tempURL)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        do {
            try copyIfPresent(from: sourceMediaURL, to: mediaDir.appendingPathComponent(screenFileName))

            let sourceBase = sourceMediaURL.deletingPathExtension()
            try copyIfPresent(
                from: sourceBase.appendingPathExtension("camera.mp4"),
                to: mediaDir.appendingPathComponent(cameraFileName)
            )
            try copyIfPresent(
                from: sourceBase.appendingPathExtension("cursor.json"),
                to: mediaDir.appendingPathComponent(cursorFileName)
            )
            try copyIfPresent(
                from: sourceBase.appendingPathExtension("clicks.json"),
                to: mediaDir.appendingPathComponent(clicksFileName)
            )
            try copyIfPresent(
                from: sourceBase.appendingPathExtension("keys.json"),
                to: mediaDir.appendingPathComponent(keysFileName)
            )

            var saved = document
            saved.version = ViewioProjectDocument.currentVersion

            if let musicSourceURL, fm.fileExists(atPath: musicSourceURL.path) {
                let name = "music.\(musicSourceURL.pathExtension)"
                let dest = assetsDir.appendingPathComponent(name)
                try copyReplacing(from: musicSourceURL, to: dest)
                saved.musicRelativePath = "\(assetsDirectoryName)/\(name)"
            } else {
                saved.musicRelativePath = nil
            }

            if case let .custom(_, id) = document.wallpaper,
               let customWallpaperURL,
               let customWallpaperID,
               customWallpaperID == id,
               fm.fileExists(atPath: customWallpaperURL.path) {
                let name = "wallpaper.\(customWallpaperURL.pathExtension)"
                let dest = assetsDir.appendingPathComponent(name)
                try copyReplacing(from: customWallpaperURL, to: dest)
                saved.wallpaper = .custom(relativePath: "\(assetsDirectoryName)/\(name)", id: id)
            }

            let cameraSettingsURL = mediaDir.appendingPathComponent(cameraSettingsFileName)
            let cameraData = try JSONEncoder().encode(saved.cameraSettings)
            try cameraData.write(to: cameraSettingsURL)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(saved)
            try data.write(to: documentURL(in: tempURL))

            if fm.fileExists(atPath: projectURL.path) {
                try fm.removeItem(at: projectURL)
            }
            try fm.moveItem(at: tempURL, to: projectURL)

            return saved
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }

    private static func copyIfPresent(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try copyReplacing(from: source, to: destination)
    }

    private static func copyReplacing(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        // Same path (already inside the package) — nothing to do.
        if source.standardizedFileURL == destination.standardizedFileURL {
            return
        }
        try fm.copyItem(at: source, to: destination)
    }
}

enum ViewioProjectError: LocalizedError {
    case missingScreenMedia
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingScreenMedia:
            "This project is missing its screen recording."
        case let .saveFailed(message):
            message
        }
    }
}
