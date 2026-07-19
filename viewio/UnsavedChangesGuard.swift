//
//  UnsavedChangesGuard.swift
//  viewio
//
//  Blocks window close / app quit while the editor has unsaved changes,
//  and shows Cancel / Discard.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class UnsavedChangesGuard: NSObject, ObservableObject {
    @Published var showsAlert = false

    /// Latest editor dirty flag (updated from EditorWorkspace).
    private(set) var isDirty = false
    /// Called when the user chooses Discard — should close the editor session.
    var onDiscard: (() -> Void)?

    private enum Pending {
        case none
        case quit
        case closeWindow(NSWindow)
    }

    private var pending: Pending = .none
    private var proxies: [ObjectIdentifier: WindowDelegateProxy] = [:]

    func updateDirty(_ dirty: Bool) {
        isDirty = dirty
    }

    /// Installs a close interceptor on the view's window (idempotent).
    func attach(to window: NSWindow?) {
        guard let window else { return }
        let id = ObjectIdentifier(window)
        if proxies[id] != nil { return }

        let proxy = WindowDelegateProxy(owner: self)
        // Keep SwiftUI's existing delegate so toolbar / traffic-light behavior still works.
        if let existing = window.delegate as? AnyObject, existing !== proxy {
            proxy.previous = window.delegate
        }
        proxies[id] = proxy
        window.delegate = proxy
    }

    func handleApplicationShouldTerminate() -> NSApplication.TerminateReply {
        guard isDirty else { return .terminateNow }
        pending = .quit
        showsAlert = true
        return .terminateCancel
    }

    func cancel() {
        pending = .none
        showsAlert = false
    }

    func discard() {
        let action = pending
        pending = .none
        showsAlert = false
        isDirty = false
        onDiscard?()

        switch action {
        case .quit:
            NSApp.terminate(nil)
        case let .closeWindow(window):
            window.close()
        case .none:
            break
        }
    }

    fileprivate func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        pending = .closeWindow(sender)
        showsAlert = true
        return false
    }
}

/// Forwards NSWindowDelegate calls to the previous SwiftUI delegate.
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var owner: UnsavedChangesGuard?
    weak var previous: NSWindowDelegate?

    init(owner: UnsavedChangesGuard) {
        self.owner = owner
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if owner?.windowShouldClose(sender) == false {
            return false
        }
        return previous?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return previous?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        previous
    }
}

/// Hooks the guard into the hosting window once the SwiftUI view appears.
struct WindowCloseGuardInstaller: NSViewRepresentable {
    let guardObject: UnsavedChangesGuard

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guardObject.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guardObject.attach(to: nsView.window)
        }
    }
}
