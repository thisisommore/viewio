//
//  CameraOverlayWindow.swift
//  viewio
//
//  Floating camera picture-in-picture that lives above all other windows
//  during recording so the user can see it while sharing the screen.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class CameraOverlayWindowController: NSObject {
    private var panel: CameraOverlayPanel?
    private let recorder: CameraRecorder
    private var displayFrame: CGRect = .zero
    private var sizeFraction: Double = CameraOverlayGeometry.defaultSize
    private var onCornerChanged: ((CameraCorner) -> Void)?

    /// The window number of the floating panel, used to exclude it from screen capture.
    var windowNumber: Int? { panel?.windowNumber }

    init(
        recorder: CameraRecorder,
        displayID: CGDirectDisplayID,
        corner: CameraCorner,
        onCornerChanged: @escaping (CameraCorner) -> Void
    ) {
        self.recorder = recorder
        self.onCornerChanged = onCornerChanged
        super.init()

        self.displayFrame = Self.frameForDisplay(displayID: displayID)
        let frame = Self.cameraFrame(for: corner, displayFrame: displayFrame, sizeFraction: sizeFraction)

        let panel = CameraOverlayPanel(
            contentRect: frame,
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = .none
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let hostingView = NSHostingView(rootView: CameraPreviewView(recorder: recorder))
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: frame.size)

        let contentView = CameraOverlayContentView(frame: NSRect(origin: .zero, size: frame.size))
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = CameraOverlayGeometry.cornerRadius
        contentView.layer?.masksToBounds = true
        contentView.panel = panel

        contentView.addSubview(hostingView)
        panel.contentView = contentView

        panel.corner = corner
        panel.displayFrame = displayFrame
        panel.sizeFraction = sizeFraction
        panel.onCornerChanged = { [weak self] corner in
            self?.onCornerChanged?(corner)
        }

        self.panel = panel
    }

    func show() {
        guard let panel else { return }
        // Force the frame onto the correct display before ordering front.
        panel.setFrame(panel.frame, display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
    }

    func moveTo(corner: CameraCorner) {
        guard let panel else { return }
        let frame = Self.cameraFrame(for: corner, displayFrame: displayFrame, sizeFraction: sizeFraction)
        panel.setFrame(frame, display: true)
        panel.corner = corner
    }

    private static func frameForDisplay(displayID: CGDirectDisplayID) -> CGRect {
        let cgBounds = CGDisplayBounds(displayID)
        let mainCGBounds = CGDisplayBounds(CGMainDisplayID())
        // CGDisplayBounds uses a top-left origin global space; Cocoa NSScreen.frame
        // uses a bottom-left origin global space. Convert so the panel lands on the
        // correct display regardless of which screen is currently "main".
        let cocoaY = mainCGBounds.height - (cgBounds.origin.y + cgBounds.size.height)
        return CGRect(
            x: cgBounds.origin.x,
            y: cocoaY,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    fileprivate static func cameraFrame(
        for corner: CameraCorner,
        displayFrame: CGRect,
        sizeFraction: Double
    ) -> CGRect {
        guard displayFrame.width > 1, displayFrame.height > 1 else { return displayFrame }
        let safe = min(0.45, max(0.08, sizeFraction))
        let width = displayFrame.width * CGFloat(safe)
        let height = width * (9.0 / 16.0)
        let padding = CameraOverlayGeometry.padding
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeft:
            x = displayFrame.minX + padding
            y = displayFrame.maxY - height - padding
        case .topRight:
            x = displayFrame.maxX - width - padding
            y = displayFrame.maxY - height - padding
        case .bottomLeft:
            x = displayFrame.minX + padding
            y = displayFrame.minY + padding
        case .bottomRight:
            x = displayFrame.maxX - width - padding
            y = displayFrame.minY + padding
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private final class CameraOverlayPanel: NSPanel {
    var onCornerChanged: ((CameraCorner) -> Void)?
    var corner: CameraCorner = .bottomRight
    var displayFrame: CGRect = .zero
    var sizeFraction: Double = CameraOverlayGeometry.defaultSize

    private var dragStartOrigin: NSPoint?
    private var dragStartLocation: NSPoint?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartOrigin = frame.origin
        dragStartLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartOrigin, let dragStartLocation else { return }
        let current = NSEvent.mouseLocation
        let origin = NSPoint(
            x: dragStartOrigin.x + (current.x - dragStartLocation.x),
            y: dragStartOrigin.y + (current.y - dragStartLocation.y)
        )
        setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        snap()
        dragStartOrigin = nil
        dragStartLocation = nil
    }

    func snap() {
        guard displayFrame.width > 1, displayFrame.height > 1 else { return }
        // CameraOverlayGeometry works in a top-left origin space; convert from Cocoa coords.
        let relFrame = CGRect(
            x: frame.minX - displayFrame.minX,
            y: displayFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let snapped = CameraOverlayGeometry.snappedCorner(for: relFrame, in: displayFrame.size)
        let newFrame = CameraOverlayWindowController.cameraFrame(
            for: snapped,
            displayFrame: displayFrame,
            sizeFraction: sizeFraction
        )
        setFrame(newFrame, display: true)
        corner = snapped
        onCornerChanged?(snapped)
    }
}

private final class CameraOverlayContentView: NSView {
    weak var panel: CameraOverlayPanel?

    override func mouseDown(with event: NSEvent) {
        panel?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        panel?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        panel?.mouseUp(with: event)
    }
}
