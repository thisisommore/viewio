import AppKit
import Combine
import SwiftUI

/// App-wide theme override. System follows macOS setting, Light/Dark force that appearance.
/// Persisted in UserDefaults so it survives relaunches.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// SwiftUI override — nil means follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// AppKit override — nil means follow system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    static let storageKey = "appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
            apply()
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey)
        let initial = raw.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        self.mode = initial
        apply()
    }

    func apply() {
        let appearance = mode.nsAppearance
        // NSApp.appearance alone does not immediately invalidate existing windows
        // (they cache effectiveAppearance until next event). Push to every window
        // so System → Dark → System snaps back without a click/delay.
        let applyBlock = {
            NSApp.appearance = appearance
            for window in NSApp.windows {
                window.appearance = appearance
            }
            // Also ensure any window created just after this call inherits correctly
            // (new windows read NSApp.appearance on creation).
        }
        if Thread.isMainThread {
            // Defer one tick so SwiftUI's preferredColorScheme(nil) transaction
            // and AppKit's appearance both commit in the same runloop pass.
            // Immediate assignment caused `System` (nil) to coalesce and stay dark.
            DispatchQueue.main.async(execute: applyBlock)
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }
}
