//
//  viewioApp.swift
//  viewio
//
//  Created by Om More on 12/07/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets the File menu reach the EditorModel of the currently focused window.
private struct ExportModelFocusedKey: FocusedValueKey {
    typealias Value = EditorModel
}

/// Lets menus target the RecordingController for the focused window.
private struct RecordingControllerFocusedKey: FocusedValueKey {
    typealias Value = RecordingController
}

extension FocusedValues {
    var exportModel: EditorModel? {
        get { self[ExportModelFocusedKey.self] }
        set { self[ExportModelFocusedKey.self] = newValue }
    }

    var recordingController: RecordingController? {
        get { self[RecordingControllerFocusedKey.self] }
        set { self[RecordingControllerFocusedKey.self] = newValue }
    }
}

final class ViewioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            ViewioSessionRegistry.shared.handleApplicationShouldTerminate()
        }
    }
}

/// One independent document/recording session per window.
private struct WindowSessionRoot: View {
    @StateObject private var recorder = RecordingController()
    @StateObject private var unsavedChanges = UnsavedChangesGuard()
    @EnvironmentObject private var wallpaperManager: WallpaperManager

    var body: some View {
        ContentView()
            .environmentObject(recorder)
            .environmentObject(wallpaperManager)
            .environmentObject(unsavedChanges)
            .focusedSceneValue(\.recordingController, recorder)
            .onAppear {
                unsavedChanges.onDiscard = { [weak recorder] in
                    recorder?.discardRecording()
                }
                ViewioSessionRegistry.shared.register(
                    recorder: recorder,
                    unsaved: unsavedChanges
                )
            }
            .onDisappear {
                ViewioSessionRegistry.shared.unregister(recorder: recorder)
            }
    }
}

@main
struct viewioApp: App {
    @NSApplicationDelegateAdaptor(ViewioAppDelegate.self) private var appDelegate
    @StateObject private var wallpaperManager = WallpaperManager.shared
    @StateObject private var sessions = ViewioSessionRegistry.shared
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.exportModel) private var exportModel
    @FocusedValue(\.recordingController) private var focusedRecorder

    var body: some Scene {
        // Multi-window: each WindowGroup instance owns its own recorder +
        // unsaved-changes guard so you can edit/record in parallel.
        WindowGroup(id: "main") {
            WindowSessionRoot()
                .environmentObject(wallpaperManager)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") {
                    focusedRecorder?.requestNewRecording()
                }
                .keyboardShortcut("n")
                .disabled(!isEditingFocused)

                Button("New Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandGroup(after: .windowArrangement) {
                Button("New Window") {
                    openWindow(id: "main")
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    exportModel?.undo()
                }
                .keyboardShortcut("z")
                .disabled(exportModel?.canUndo != true)

                Button("Redo") {
                    exportModel?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(exportModel?.canRedo != true)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save Project") {
                    exportModel?.saveProject()
                }
                .keyboardShortcut("s")
                .disabled(exportModel == nil || exportModel?.canSaveProject != true)

                Button("Save Project As…") {
                    exportModel?.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(exportModel == nil || exportModel?.canSaveProject != true)

                Divider()

                Button("Open Project…") {
                    openProject()
                }
                .keyboardShortcut("o")
                .disabled(!canOpenProject)

                Divider()

                Button("Export…") {
                    exportModel?.export()
                }
                .keyboardShortcut("e")
                .disabled(exportModel == nil)
            }
        }

        MenuBarExtra(
            isInserted: Binding(
                get: { sessions.isAnyRecording },
                set: { _ in }
            )
        ) {
            Text("Screen recording")
            Text(formattedDuration(sessions.recordingElapsed))
                .font(.system(size: 12, design: .monospaced))

            Divider()

            Button("Stop Recording") {
                sessions.activeRecording?.stopRecording()
            }
            .disabled(!canStopActiveRecording)

            Button("Discard Recording", role: .destructive) {
                sessions.activeRecording?.discardInProgressRecording()
            }
            .disabled(!canStopActiveRecording)
        } label: {
            Label("Screen Recording", systemImage: "record.circle.fill")
        }
        .menuBarExtraStyle(.menu)
    }

    private var canStopActiveRecording: Bool {
        guard let recorder = sessions.activeRecording else { return false }
        switch recorder.state {
        case .preparing, .recording:
            return true
        case .idle, .stopping, .failed, .finished, .project:
            return false
        }
    }

    private var isEditingFocused: Bool {
        switch focusedRecorder?.state {
        case .finished, .project:
            return true
        default:
            return false
        }
    }

    private var canOpenProject: Bool {
        if case .idle = focusedRecorder?.state { return true }
        // No focused idle window: still allow opening into a new window.
        return true
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a viewio project to continue editing."
        panel.allowedContentTypes = [.viewioProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let recorder = focusedRecorder, case .idle = recorder.state {
            recorder.openProject(url)
            return
        }

        // Open in a fresh window so we don't clobber an active edit session.
        ViewioSessionRegistry.shared.openProjectInNewWindow(url)
        openWindow(id: "main")
    }
}
