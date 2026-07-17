//
//  WallpaperManager.swift
//  viewio
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    struct Wallpaper: Identifiable, Equatable {
        let id: String
        let name: String
        let localURL: URL
    }

    @Published private(set) var wallpapers: [Wallpaper] = []
    @Published private(set) var isLoading = false
    @Published private(set) var selectedWallpaperID: String?
    @Published private(set) var lastError: String?

    private let imageExtensions = Set(["jpg", "jpeg", "png", "heic"])
    private var hasLoaded = false

    private init() {}

    func loadWallpapersIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        loadWallpapers()
    }

    func selectWallpaper(_ wallpaper: Wallpaper) {
        guard selectedWallpaperID != wallpaper.id else { return }
        selectedWallpaperID = wallpaper.id
        lastError = nil
    }

    func wallpaper(withID id: String) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    private func loadWallpapers() {
        let urls = (bundledWallpaperURLs() + customWallpaperURLs())
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else {
            lastError = "No bundled wallpapers found."
            return
        }

        var usedIDs = Set<String>()
        wallpapers = urls.map { url in
            let filename = url.lastPathComponent
            var id = filename
            var suffix = 1
            while usedIDs.contains(id) {
                suffix += 1
                id = "\(filename)-\(suffix)"
            }
            usedIDs.insert(id)
            let name = filename
                .replacingOccurrences(of: ".\(url.pathExtension)", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Wallpaper(
                id: id,
                name: name.isEmpty ? filename : name,
                localURL: url
            )
        }

        if selectedWallpaperID == nil, let first = wallpapers.first {
            selectedWallpaperID = first.id
        }
    }

    private func bundledWallpaperURLs() -> [URL] {
        guard let resourcesDir = Bundle.main.resourceURL else { return [] }
        return (try? FileManager.default.contentsOfDirectory(
            at: resourcesDir,
            includingPropertiesForKeys: nil
        ))?
        .filter {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
            return !isDirectory.boolValue && imageExtensions.contains($0.pathExtension.lowercased())
        } ?? []
    }

    /// Images the user added, persisted in Application Support.
    private func customWallpaperURLs() -> [URL] {
        guard let directory = customWallpapersDirectory else { return [] }
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) } ?? []
    }

    private var customWallpapersDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("viewio", isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true)
    }

    /// Opens a file picker, copies the chosen image into the wallpaper store,
    /// and selects it.
    func addCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Background Image"
        panel.message = "Pick an image to use as a wallpaper behind your recording."
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            guard let directory = customWallpapersDirectory else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)

            let wallpaper = Wallpaper(
                id: uniqueWallpaperID(for: destination.lastPathComponent),
                name: destination.deletingPathExtension().lastPathComponent,
                localURL: destination
            )
            wallpapers.append(wallpaper)
            selectWallpaper(wallpaper)
        } catch {
            lastError = "Couldn't add that image: \(error.localizedDescription)"
        }
    }

    private func uniqueWallpaperID(for filename: String) -> String {
        var id = filename
        var suffix = 1
        while wallpapers.contains(where: { $0.id == id }) {
            suffix += 1
            id = "\(filename)-\(suffix)"
        }
        return id
    }
}
