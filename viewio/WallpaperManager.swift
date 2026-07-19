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

    /// Restores a wallpaper when opening a project (bundled id or custom file).
    /// Only publishes when the selection actually changes.
    func restoreProjectWallpaper(bundledID: String?, customURL: URL?, customID: String?) {
        loadWallpapersIfNeeded()
        if let customURL, let customID, FileManager.default.fileExists(atPath: customURL.path) {
            if let existing = wallpapers.first(where: { $0.id == customID }) {
                setSelectedWallpaperIDIfNeeded(existing.id)
                return
            }
            let wallpaper = Wallpaper(
                id: customID,
                name: customURL.deletingPathExtension().lastPathComponent,
                localURL: customURL
            )
            wallpapers.append(wallpaper)
            setSelectedWallpaperIDIfNeeded(wallpaper.id)
            return
        }
        if let bundledID, wallpapers.contains(where: { $0.id == bundledID }) {
            setSelectedWallpaperIDIfNeeded(bundledID)
            return
        }
        if let first = wallpapers.first {
            setSelectedWallpaperIDIfNeeded(first.id)
        }
    }

    private func setSelectedWallpaperIDIfNeeded(_ id: String) {
        guard selectedWallpaperID != id else { return }
        selectedWallpaperID = id
    }

    func wallpaper(withID id: String) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    private func loadWallpapers() {
        // Custom images used to be copied into Application Support; they're
        // session-only now, so clear any leftovers from older versions.
        if let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("viewio", isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }

        let urls = bundledWallpaperURLs()
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

    /// Opens a file picker and adds the chosen image to the wallpaper list.
    /// Session-only: the file is used in place, never copied or persisted.
    func addCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Background Image"
        panel.message = "Pick an image to use as a wallpaper behind your recording."
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        let wallpaper = Wallpaper(
            id: uniqueWallpaperID(for: sourceURL.lastPathComponent),
            name: sourceURL.deletingPathExtension().lastPathComponent,
            localURL: sourceURL
        )
        wallpapers.append(wallpaper)
        selectWallpaper(wallpaper)
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
