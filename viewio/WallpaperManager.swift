//
//  WallpaperManager.swift
//  viewio
//

import AppKit
import Combine
import Foundation

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
        loadBundledWallpapers()
    }

    func selectWallpaper(_ wallpaper: Wallpaper) {
        guard selectedWallpaperID != wallpaper.id else { return }
        selectedWallpaperID = wallpaper.id
        lastError = nil
    }

    func wallpaper(withID id: String) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    private func loadBundledWallpapers() {
        let urls = bundledWallpaperURLs().sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else {
            lastError = "No bundled wallpapers found."
            return
        }

        wallpapers = urls.map { url in
            let filename = url.lastPathComponent
            let name = filename
                .replacingOccurrences(of: ".\(url.pathExtension)", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Wallpaper(
                id: filename,
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
}
