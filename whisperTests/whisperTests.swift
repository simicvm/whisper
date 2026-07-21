//
//  whisperTests.swift
//  whisperTests
//
//  Created by Marko Simic on 13-02-2026.
//

import Testing
@testable import whisper

struct whisperTests {

    @Test @MainActor
    func recordingStartsOnlyAfterMicrophoneStartup() {
        let appState = AppState()

        #expect(appState.transition(to: .starting))
        #expect(appState.phase == .starting)
        #expect(appState.statusText == "Starting microphone...")
        #expect(appState.menuBarIcon == "waveform.circle")

        #expect(appState.transition(to: .recording))
        #expect(appState.phase == .recording)
        #expect(appState.menuBarIcon == "waveform.circle.fill")
    }

    @Test @MainActor
    func microphoneStartupErrorCanReturnToIdle() {
        let appState = AppState()

        #expect(appState.transition(to: .starting))
        #expect(appState.transition(to: .error("Audio input changed. Try again.")))
        #expect(appState.transition(to: .idle))
        #expect(appState.phase == .idle)
    }

}
