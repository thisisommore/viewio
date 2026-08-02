//
//  RegionSelectionWindowController.swift
//  viewio
//
//  Fullscreen overlay that lets the user drag out a screen region to record.
//  One borderless panel per display dims the screen; the confirmed rect is
//  reported in Cocoa global point coordinates (NSEvent.mouseLocation space),
//  matching RecordingController.captureBounds.
//

import AppKit

@MainActor
final class RegionSelectionWindowController {
    /// Smallest selectable region edge, in points.
    static let minimumSize: CGFloat = 64

    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    private var onCompletion: ((CGRect?) -> Void)?

    init(onCompletion: @escaping (CGRect?) -> Void) {
        self.onCompletion = onCompletion
    }

    func show() {
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

            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.autoresizingMask = [.width, .height]
            view.onConfirm = { [weak self] localRect in
                // View space is bottom-left origin within the panel; the panel
                // covers exactly one screen, so a simple offset lands in
                // Cocoa global coordinates.
                self?.finish(localRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY))
            }
            view.onCancel = { [weak self] in
                self?.finish(nil)
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Panels are non-activating, so Esc is caught with a local monitor
        // instead of relying on key window status.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            Task { @MainActor [weak self] in
                self?.finish(nil)
            }
            return nil
        }

        NSCursor.crosshair.push()
    }

    private func finish(_ rect: CGRect?) {
        guard let onCompletion else { return } // already finished
        self.onCompletion = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        NSCursor.pop()
        for panel in panels {
            panel.close()
        }
        panels.removeAll()
        onCompletion(rect)
    }
}

/// Draws the dim layer + rubber-band selection for one display and reports
/// the confirmed rect in view (panel-local, bottom-left origin) coordinates.
private final class RegionSelectionView: NSView {
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = rect(from: dragStart, to: current).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection else {
            dragStart = nil
            return
        }
        dragStart = nil
        if selection.width >= RegionSelectionWindowController.minimumSize,
           selection.height >= RegionSelectionWindowController.minimumSize {
            onConfirm?(selection)
        } else {
            // Below the minimum: drop the rect and let the user drag again.
            self.selection = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)
        if let selection, !selection.isEmpty {
            // Dim everything except the selection by filling the four
            // surrounding bands (avoids compositing tricks for the hole).
            dim.setFill()
            let bands = [
                CGRect(x: bounds.minX, y: selection.maxY, width: bounds.width, height: bounds.maxY - selection.maxY),
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: selection.minY - bounds.minY),
                CGRect(x: bounds.minX, y: selection.minY, width: selection.minX - bounds.minX, height: selection.height),
                CGRect(x: selection.maxX, y: selection.minY, width: bounds.maxX - selection.maxX, height: selection.height)
            ]
            for band in bands where !band.isEmpty {
                band.fill()
            }

            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
            border.lineWidth = 1.5
            border.stroke()

            drawSizeLabel(for: selection)
        } else {
            dim.setFill()
            bounds.fill()
        }

        drawHint()
    }

    private func drawSizeLabel(for selection: CGRect) {
        let text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .shadow: textShadow()
        ]
        let size = text.size(withAttributes: attributes)
        // Above the selection by default; inside it when near the top edge.
        var origin = CGPoint(
            x: selection.midX - size.width / 2,
            y: selection.maxY + 8
        )
        if origin.y + size.height > bounds.maxY - 8 {
            origin.y = selection.maxY - size.height - 8
        }
        origin.x = max(8, min(bounds.maxX - size.width - 8, origin.x))
        text.draw(at: origin, withAttributes: attributes)
    }

    private func drawHint() {
        let text = "Drag to select a region — Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .shadow: textShadow()
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 48),
            withAttributes: attributes
        )
    }

    private func textShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        return shadow
    }
}
