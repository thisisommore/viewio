//
//  viewioApp.swift
//  viewio
//
//  Created by Om More on 12/07/26.
//

import SwiftUI

@main
struct viewioApp: App {
    @StateObject private var recorder = RecordingController()

    var body: some Scene {
        WindowGroup("viewio") {
            ContentView()
                .environmentObject(recorder)
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
