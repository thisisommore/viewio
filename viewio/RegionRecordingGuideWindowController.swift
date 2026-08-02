//
//  RegionRecordingGuideWindowController.swift
//  viewio
//
//  Lightweight dim overlay shown while a region recording is active so the
//  user can see the intended soft crop. The full display is still recorded;
//  this guide only previews the crop. The crop rect stays clear; everything
//  outside is lightly darkened. Panels are click-through and excluded from
//  capture (`sharingType = .none`).
//

import AppKit

@MainActor
final class RegionRecordingGuideWindowController {
    /// Window numbers of the guide panels (for ScreenCaptureKit exclusion).
    var windowNumbers: [Int] {
        panels.compactMap { $0.windowNumber > 0 ? $0.windowNumber : nil }
    }

    private var panels: [NSPanel] = []

    /// `region` is in Cocoa global coordinates (NSEvent.mouseLocation space).
    init(region: CGRect) {
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isFloatingPanel = true
            panel.ignoresMouseEvents = true
            // Keep the guide out of screen recordings even if exclusion fails.
            panel.sharingType = .none
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true

            // Convert global region into this panel's local (bottom-left) space.
            let localHole = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                .intersection(NSRect(origin: .zero, size: screen.frame.size))

            let view = RegionRecordingGuideView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                hole: localHole.isEmpty ? nil : localHole
            )
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            panels.append(panel)
        }
    }

    func show() {
        for panel in panels {
            panel.orderFrontRegardless()
        }
    }

    /// Bring guide panels back above other UI (e.g. after capture actually starts).
    func orderFront() {
        for panel in panels {
            panel.orderFrontRegardless()
        }
    }

    func close() {
        for panel in panels {
            panel.close()
        }
        panels.removeAll()
    }
}

/// Dims the view except for an optional clear hole (the active recording region).
private final class RegionRecordingGuideView: NSView {
    private let hole: CGRect?

    init(frame: NSRect, hole: CGRect?) {
        self.hole = hole
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dark enough to read the soft-crop bounds while recording; still
        // translucent so the desktop remains usable outside the hole.
        let dim = NSColor.black.withAlphaComponent(0.42)
        dim.setFill()

        guard let hole, !hole.isEmpty else {
            bounds.fill()
            return
        }

        // Four bands around the hole — no compositing tricks needed.
        let bands = [
            CGRect(x: bounds.minX, y: hole.maxY, width: bounds.width, height: bounds.maxY - hole.maxY),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: hole.minY - bounds.minY),
            CGRect(x: bounds.minX, y: hole.minY, width: hole.minX - bounds.minX, height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: bounds.maxX - hole.maxX, height: hole.height)
        ]
        for band in bands where band.width > 0.5 && band.height > 0.5 {
            band.fill()
        }

        // Border just outside the hole; panels use sharingType.none so the
        // guide is not baked into the full-display recording.
        let borderRect = hole.insetBy(dx: -1.5, dy: -1.5)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: borderRect)
        path.lineWidth = 2
        path.stroke()
    }
}
