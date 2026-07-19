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

extension FocusedValues {
    var exportModel: EditorModel? {
        get { self[ExportModelFocusedKey.self] }
        set { self[ExportModelFocusedKey.self] = newValue }
    }
}

final class ViewioAppDelegate: NSObject, NSApplicationDelegate {
    var unsavedChanges: UnsavedChangesGuard?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        unsavedChanges?.handleApplicationShouldTerminate() ?? .terminateNow
    }
}

@main
struct viewioApp: App {
    @NSApplicationDelegateAdaptor(ViewioAppDelegate.self) private var appDelegate
    @StateObject private var recorder = RecordingController()
    @StateObject private var wallpaperManager = WallpaperManager.shared
    @StateObject private var unsavedChanges = UnsavedChangesGuard()
    @FocusedValue(\.exportModel) private var exportModel

    var body: some Scene {
        // Single-window scene: WindowGroup would allow extra windows (⌘N /
        // Dock menu), and every window shares one RecordingController — which
        // is why the discard alert appeared on all of them.
        Window("viewio", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(wallpaperManager)
                .environmentObject(unsavedChanges)
                .onAppear {
                    appDelegate.unsavedChanges = unsavedChanges
                    unsavedChanges.onDiscard = { [weak recorder] in
                        recorder?.discardRecording()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording") {
                    recorder.requestNewRecording()
                }
                .keyboardShortcut("n")
                .disabled(!isEditing)
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
                get: { recorder.isRecording },
                set: { _ in }
            )
        ) {
            Text("Screen recording")
            Text(formattedDuration(recorder.elapsed))
                .font(.system(size: 12, design: .monospaced))

            Divider()

            Button("Stop Recording") {
                recorder.stopRecording()
            }
            .disabled(!canStopRecording)

            Button("Discard Recording", role: .destructive) {
                recorder.discardInProgressRecording()
            }
            .disabled(!canStopRecording)
        } label: {
            Label("Screen Recording", systemImage: "record.circle.fill")
        }
        .menuBarExtraStyle(.menu)
    }

    private var canStopRecording: Bool {
        switch recorder.state {
        case .preparing, .recording:
            true
        case .idle, .stopping, .failed, .finished, .project:
            false
        }
    }

    private var isEditing: Bool {
        switch recorder.state {
        case .finished, .project:
            true
        default:
            false
        }
    }

    private var canOpenProject: Bool {
        if case .idle = recorder.state { return true }
        return false
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
        recorder.openProject(url)
    }
}
