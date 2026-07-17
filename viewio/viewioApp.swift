//
//  viewioApp.swift
//  viewio
//
//  Created by Om More on 12/07/26.
//

import SwiftUI

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

@main
struct viewioApp: App {
    @StateObject private var recorder = RecordingController()
    @StateObject private var wallpaperManager = WallpaperManager.shared
    @FocusedValue(\.exportModel) private var exportModel

    var body: some Scene {
        WindowGroup("viewio") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(wallpaperManager)
        }
        .commands {
            CommandGroup(after: .saveItem) {
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

            Button("Stop Recording", role: .destructive) {
                recorder.stopRecording()
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
        case .idle, .stopping, .failed, .finished:
            false
        }
    }
}
