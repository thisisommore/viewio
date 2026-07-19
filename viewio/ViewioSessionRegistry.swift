//
//  ViewioSessionRegistry.swift
//  viewio
//
//  Tracks per-window recording sessions so multiple windows can edit
//  independently while app-level UI (menu bar extra, quit) still works.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ViewioSessionRegistry: ObservableObject {
    static let shared = ViewioSessionRegistry()

    /// Controller currently capturing (at most one).
    @Published private(set) var activeRecording: RecordingController?
    @Published private(set) var isAnyRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0

    /// Project to open in the next window that becomes idle (New Window + Open).
    private var pendingProjectURL: URL?

    private final class Entry {
        weak var recorder: RecordingController?
        weak var unsaved: UnsavedChangesGuard?
        var cancellables = Set<AnyCancellable>()
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    private init() {}

    /// Queue a project open for a newly created window, then call `openWindow`.
    func openProjectInNewWindow(_ url: URL) {
        pendingProjectURL = url
    }

    func register(recorder: RecordingController, unsaved: UnsavedChangesGuard) {
        let id = ObjectIdentifier(recorder)
        if let existing = entries[id] {
            existing.unsaved = unsaved
            return
        }

        let entry = Entry()
        entry.recorder = recorder
        entry.unsaved = unsaved

        recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshRecordingState()
            }
            .store(in: &entry.cancellables)

        recorder.$elapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] elapsed in
                guard let self, self.activeRecording === recorder else { return }
                self.recordingElapsed = elapsed
            }
            .store(in: &entry.cancellables)

        entries[id] = entry
        refreshRecordingState()

        // Deliver a deferred "Open Project" that targeted a new window.
        if case .idle = recorder.state, let url = pendingProjectURL {
            pendingProjectURL = nil
            recorder.openProject(url)
        }
    }

    func unregister(recorder: RecordingController) {
        // Closing a window mid-capture should not leave an orphan stream.
        if recorder.isRecording {
            recorder.discardInProgressRecording()
        }
        entries.removeValue(forKey: ObjectIdentifier(recorder))
        refreshRecordingState()
    }

    /// True when some *other* window is already capturing.
    func isRecordingElsewhere(than recorder: RecordingController) -> Bool {
        guard let active = activeRecording else { return false }
        return active !== recorder
    }

    /// Walk dirty sessions on quit so each window can confirm discard first.
    func handleApplicationShouldTerminate() -> NSApplication.TerminateReply {
        pruneDeadEntries()
        for entry in entries.values {
            if let unsaved = entry.unsaved, unsaved.isDirty {
                return unsaved.handleApplicationShouldTerminate()
            }
        }
        return .terminateNow
    }

    private func refreshRecordingState() {
        pruneDeadEntries()
        let active = entries.values
            .compactMap(\.recorder)
            .first(where: \.isRecording)
        activeRecording = active
        isAnyRecording = active != nil
        recordingElapsed = active?.elapsed ?? 0
    }

    private func pruneDeadEntries() {
        entries = entries.filter { $0.value.recorder != nil }
    }
}
