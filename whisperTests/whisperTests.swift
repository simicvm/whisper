//
//  whisperTests.swift
//  whisperTests
//
//  Created by Marko Simic on 13-02-2026.
//

import AVFoundation
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

    @Test
    func extractsMonoFromMultiChannelInterleavedAndInt16Buffers() throws {
        var scratch: [Float] = []

        // 1. Two-channel non-interleaved Float32 with mic only on channel 2 (index 1).
        let stereoFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let stereoBuffer = try #require(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4))
        stereoBuffer.frameLength = 4
        let ch0 = stereoBuffer.floatChannelData![0]
        let ch1 = stereoBuffer.floatChannelData![1]
        for i in 0..<4 {
            ch0[i] = 0
            ch1[i] = 0.5
        }
        var extracted: [Float] = []
        AudioRecorder.withMonoSamples(from: stereoBuffer, scratch: &scratch) { ptr in
            extracted = Array(ptr)
        }
        #expect(extracted.count == 4)
        #expect(extracted.allSatisfy { abs($0 - 0.5) < 1e-5 })

        // 2. Two-channel interleaved Float32 with both channels active.
        let interleavedFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let interleavedBuffer = try #require(AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 3))
        interleavedBuffer.frameLength = 3
        let interleavedPtr = interleavedBuffer.floatChannelData![0]
        let rawInterleaved: [Float] = [0.2, 0.6, 0.4, 0.8, -0.2, 0.2]
        for i in 0..<rawInterleaved.count {
            interleavedPtr[i] = rawInterleaved[i]
        }
        AudioRecorder.withMonoSamples(from: interleavedBuffer, scratch: &scratch) { ptr in
            extracted = Array(ptr)
        }
        #expect(extracted.count == 3)
        #expect(abs(extracted[0] - 0.4) < 1e-5)
        #expect(abs(extracted[1] - 0.6) < 1e-5)
        #expect(abs(extracted[2] - 0.0) < 1e-5)

        // 3. Mono Int16 buffer.
        let int16Format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let int16Buffer = try #require(AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 2))
        int16Buffer.frameLength = 2
        int16Buffer.int16ChannelData![0][0] = 16_384
        int16Buffer.int16ChannelData![0][1] = -16_384
        AudioRecorder.withMonoSamples(from: int16Buffer, scratch: &scratch) { ptr in
            extracted = Array(ptr)
        }
        #expect(extracted.count == 2)
        #expect(abs(extracted[0] - 0.5) < 1e-4)
        #expect(abs(extracted[1] - (-0.5)) < 1e-4)
    }

    @Test @MainActor
    func hotkeyMonitorReconcilesGhostModifiersFromFlags() {
        let monitor = HotkeyMonitor()
        monitor.binding = HotkeyBinding(keyCodes: [HotkeyKeyCode.leftCommand, HotkeyKeyCode.leftControl])

        var downCount = 0
        monitor.onKeyDown = { downCount += 1 }

        // Simulate a ghost Left Shift stuck after Secure Input.
        monitor.pressedKeyCodes = [HotkeyKeyCode.leftShift, HotkeyKeyCode.function]

        // Now user presses Left Command + Left Control (only those two bits set).
        let flags: UInt64 = 0x0000_0008 | 0x0000_0001 // leftCommand | leftControl
        monitor.reconcileModifiers(
            flagsRaw: flags,
            triggerType: .flagsChanged,
            triggerKeyCode: HotkeyKeyCode.leftControl
        )
        monitor.updateHeldStateAndCallbacks()

        #expect(monitor.pressedKeyCodes == [HotkeyKeyCode.leftCommand, HotkeyKeyCode.leftControl])
        #expect(monitor.isHeld)
        #expect(downCount == 1)
    }

}
