//
//  whisperTests.swift
//  whisperTests
//
//  Created by Marko Simic on 13-02-2026.
//

import Foundation
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

    @Test
    func vadPreservesContinuousSpeechWithSingleLoudSyllable() {
        let sampleRate = 16_000.0
        // 1.5s of continuous speech at RMS ~0.08 with one brief 0.05s loud plosive (RMS ~0.30).
        let totalSamples = Int(1.5 * sampleRate)
        let samples = (0..<totalSamples).map { i -> Float in
            let amp: Float = (i >= 11_200 && i < 12_000) ? 0.42 : 0.11
            return amp * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }

        let result = AudioProcessing.trimSilence(from: samples, sampleRate: sampleRate)
        switch result {
        case .indeterminate(let audio), .speech(let audio):
            #expect(audio.count == samples.count)
        case .silence:
            Issue.record("Expected continuous speech not to be classified as silence")
        }
    }

    @Test
    func vadTrimsLeadingAndTrailingSilence() {
        let sampleRate = 16_000.0
        let silence = [Float](repeating: 0.0005, count: Int(0.5 * sampleRate))
        let speech = (0..<Int(0.4 * sampleRate)).map { i -> Float in
            0.2 * sin(2 * .pi * 300 * Float(i) / Float(sampleRate))
        }
        let samples = silence + speech + silence

        let result = AudioProcessing.trimSilence(from: samples, sampleRate: sampleRate)
        switch result {
        case .speech(let trimmed):
            #expect(trimmed.count < samples.count)
            #expect(trimmed.count >= speech.count)
        default:
            Issue.record("Expected speech with trimmed silence")
        }
    }

    @Test
    func vadDetectsPureSilenceAndNormalizesGain() {
        let sampleRate = 16_000.0
        let quiet = [Float](repeating: 0.0001, count: Int(0.5 * sampleRate))
        if case .silence = AudioProcessing.trimSilence(from: quiet, sampleRate: sampleRate) {
            // expected
        } else {
            Issue.record("Expected pure silence")
        }

        let normalized = AudioProcessing.normalizeGain([0.1, -0.2, 0.05], targetPeak: 0.9)
        #expect(abs(normalized[1] - (-0.9)) < 1e-4)
        #expect(abs(normalized[0] - 0.45) < 1e-4)
    }

    @Test
    func resamplerDrainsFullOutputAndRejectsInvalidRates() throws {
        // 2 seconds at 48 kHz -> ~32,000 samples at 16 kHz.
        let src48k = (0..<96_000).map { i -> Float in
            0.5 * sin(2 * .pi * 440 * Float(i) / 48_000)
        }
        let dst16k = try AudioRecorder.resample(src48k, from: 48_000, to: 16_000)
        #expect(abs(dst16k.count - 32_000) <= 64)

        // 1 second at 44.1 kHz -> ~16,000 samples at 16 kHz.
        let src44k = (0..<44_100).map { i -> Float in
            0.5 * sin(2 * .pi * 440 * Float(i) / 44_100)
        }
        let dstFrom44k = try AudioRecorder.resample(src44k, from: 44_100, to: 16_000)
        #expect(abs(dstFrom44k.count - 16_000) <= 64)

        #expect(throws: AudioRecorderError.self) {
            _ = try AudioRecorder.resample([0.1, 0.2], from: 0, to: 16_000)
        }
    }

}
