import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Records microphone audio and returns raw float32 samples at 16kHz.
final class AudioRecorder: @unchecked Sendable {
    static let defaultMaximumDuration: TimeInterval = 90

    private struct InputFingerprint: Equatable {
        let deviceID: AudioDeviceID
        let nominalSampleRate: Double
        let channelCount: UInt32
    }

    /// Reused across recordings: rebuilding the engine (and the input audio
    /// unit behind `inputNode`) on every key-down adds avoidable latency
    /// before capture starts. `stop()` halts the engine — releasing the
    /// microphone and its privacy indicator — but keeps the graph alive.
    private var engine = AVAudioEngine()
    private var engineInputFingerprint: InputFingerprint?
    private var configurationObserver: NSObjectProtocol?
    private let configurationLock = NSLock()
    private var configurationIsDirty = false
    private var configurationGeneration: UInt64 = 0
    private var configurationRevision: UInt64 = 0
    private var tapInstalled = false
    private var nativeSamples: [Float] = []
    private var nativeSampleRate: Double = 0
    private let lock = NSLock()
    private var isRecording = false
    private var onLevel: (@Sendable (Float) -> Void)?
    private var onInputConfigurationChange: (@MainActor @Sendable () -> Void)?
    private var didReportInputConfigurationChange = false

    /// Target sample rate for the STT model.
    private let targetSampleRate: Double = 16000
    private let maximumDuration: TimeInterval

    init(maximumDuration: TimeInterval = AudioRecorder.defaultMaximumDuration) {
        self.maximumDuration = max(1, maximumDuration)
        observeConfigurationChanges()
    }

    deinit {
        invalidateConfigurationObserver()
    }

    /// Start recording from the default microphone.
    /// - Parameter onLevel: Called on every buffer with the current RMS level (0–1).
    /// - Parameter onInputConfigurationChange: Called if the audio route changes while recording.
    func start(
        onLevel: (@Sendable (Float) -> Void)? = nil,
        onInputConfigurationChange: (@MainActor @Sendable () -> Void)? = nil
    ) throws {
        lock.lock()
        let recordingAlreadyActive = isRecording
        lock.unlock()

        guard !recordingAlreadyActive, !tapInstalled else {
            throw AudioRecorderError.alreadyRecording
        }

        let currentInput = try Self.currentInputFingerprint()
        if shouldReplaceEngine(for: currentInput) {
            replaceEngine()
        }

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw AudioRecorderError.noMicrophone
        }

        nativeSampleRate = nativeFormat.sampleRate

        lock.lock()
        nativeSamples.removeAll()
        // Reserve enough for a typical dictation up front so the audio-thread
        // tap doesn't repeatedly reallocate-and-copy while appending (a 90s
        // recording at 48kHz grows to ~4.3M floats). Longer recordings still
        // grow geometrically beyond this.
        nativeSamples.reserveCapacity(Int(nativeFormat.sampleRate * min(30, maximumDuration)))
        isRecording = true
        self.onLevel = onLevel
        self.onInputConfigurationChange = onInputConfigurationChange
        didReportInputConfigurationChange = false
        lock.unlock()

        // Capture callback and sample rate as locals so the tap closure
        // doesn't read instance properties from the audio thread without
        // synchronisation. Both values are immutable for the lifetime of
        // this recording session.
        let capturedOnLevel = onLevel
        let capturedRate = nativeSampleRate

        // Tap in the native format — no conversion during recording
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            // Take first channel only
            let bufferPointer = UnsafeBufferPointer(start: channelData[0], count: count)

            // Compute RMS level (vectorised; this runs on the audio tap thread)
            if let onLevel = capturedOnLevel {
                var rms: Float = 0
                vDSP_rmsqv(bufferPointer.baseAddress!, 1, &rms, vDSP_Length(count))
                // Normalize: typical speech RMS is ~0.01–0.1, clamp and scale to 0–1
                let normalized = min(rms * 5.0, 1.0)
                onLevel(normalized)
            }

            self.lock.lock()
            if self.isRecording {
                let maxNativeSamples = Int(capturedRate * self.maximumDuration)
                let remaining = maxNativeSamples - self.nativeSamples.count

                if remaining > 0 {
                    if count <= remaining {
                        self.nativeSamples.append(contentsOf: bufferPointer)
                    } else {
                        self.nativeSamples.append(contentsOf: bufferPointer.prefix(remaining))
                        self.isRecording = false
                    }
                } else {
                    self.isRecording = false
                }
            }
            self.lock.unlock()
        }
        tapInstalled = true

        do {
            try engine.start()
            engineInputFingerprint = currentInput
        } catch {
            cleanUpFailedStart()
            throw error
        }
    }

    /// Returns whether the engine is still running on the input used at start.
    /// A harmless configuration notification is cleared so later changes can
    /// still notify the app.
    func activeInputConfigurationIsValid() -> Bool {
        configurationLock.lock()
        let revision = configurationRevision
        configurationLock.unlock()

        guard engine.isRunning,
              let engineInputFingerprint,
              let currentInput = try? Self.currentInputFingerprint(),
              currentInput == engineInputFingerprint else {
            return false
        }

        configurationLock.lock()
        let noNewerChange = configurationRevision == revision
        if noNewerChange {
            configurationIsDirty = false
        }
        configurationLock.unlock()

        guard noNewerChange else { return false }

        lock.lock()
        didReportInputConfigurationChange = false
        lock.unlock()
        return true
    }

    /// Stop recording and return the captured audio samples resampled to 16kHz mono float32.
    func stop() -> [Float] {
        lock.lock()
        isRecording = false
        let captured = nativeSamples
        let capturedRate = nativeSampleRate
        nativeSamples.removeAll()
        onLevel = nil
        onInputConfigurationChange = nil
        didReportInputConfigurationChange = false
        lock.unlock()

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()

        guard !captured.isEmpty else { return [] }

        // Resample to 16kHz if needed
        if capturedRate == targetSampleRate {
            return captured
        }

        return resample(captured, from: capturedRate, to: targetSampleRate)
    }

    private func shouldReplaceEngine(for currentInput: InputFingerprint) -> Bool {
        configurationLock.lock()
        let isDirty = configurationIsDirty
        configurationLock.unlock()

        if isDirty {
            return true
        }

        guard let engineInputFingerprint else {
            return false
        }
        return engineInputFingerprint != currentInput
    }

    /// Replace the engine outside its configuration-change callback. Apple
    /// warns that releasing an engine from that callback can deadlock.
    private func replaceEngine() {
        invalidateConfigurationObserver()
        engine.stop()
        engine = AVAudioEngine()
        engineInputFingerprint = nil
        tapInstalled = false
        observeConfigurationChanges()
    }

    private func cleanUpFailedStart() {
        lock.lock()
        isRecording = false
        nativeSamples.removeAll()
        onLevel = nil
        onInputConfigurationChange = nil
        didReportInputConfigurationChange = false
        lock.unlock()

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        replaceEngine()
    }

    private func observeConfigurationChanges() {
        configurationLock.lock()
        configurationGeneration &+= 1
        let generation = configurationGeneration
        configurationIsDirty = false
        configurationLock.unlock()

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.markInputConfigurationDirty(generation: generation)
        }
    }

    private func invalidateConfigurationObserver() {
        configurationLock.lock()
        configurationGeneration &+= 1
        configurationIsDirty = false
        configurationLock.unlock()

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// This may run on AVAudioEngine's internal thread. It only marks state
    /// and wakes the app; engine teardown happens later on the main actor.
    private func markInputConfigurationDirty(generation: UInt64) {
        configurationLock.lock()
        guard generation == configurationGeneration else {
            configurationLock.unlock()
            return
        }
        configurationIsDirty = true
        configurationRevision &+= 1
        configurationLock.unlock()

        lock.lock()
        let callback: (@MainActor @Sendable () -> Void)?
        if isRecording, !didReportInputConfigurationChange {
            didReportInputConfigurationChange = true
            callback = onInputConfigurationChange
        } else {
            callback = nil
        }
        lock.unlock()

        if let callback {
            Task { @MainActor in
                callback()
            }
        }
    }

    private static func currentInputFingerprint() throws -> InputFingerprint {
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let defaultInputStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        )
        guard defaultInputStatus == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioRecorderError.audioHardware(defaultInputStatus)
        }

        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nominalSampleRate: Float64 = 0
        var sampleRateSize = UInt32(MemoryLayout<Float64>.size)
        let sampleRateStatus = AudioObjectGetPropertyData(
            deviceID,
            &sampleRateAddress,
            0,
            nil,
            &sampleRateSize,
            &nominalSampleRate
        )
        guard sampleRateStatus == noErr else {
            throw AudioRecorderError.audioHardware(sampleRateStatus)
        }
        guard nominalSampleRate > 0 else {
            throw AudioRecorderError.noMicrophone
        }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamConfigurationSize: UInt32 = 0
        let streamSizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamConfigurationSize
        )
        guard streamSizeStatus == noErr else {
            throw AudioRecorderError.audioHardware(streamSizeStatus)
        }
        guard streamConfigurationSize >= MemoryLayout<AudioBufferList>.size else {
            throw AudioRecorderError.noMicrophone
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(streamConfigurationSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let streamStatus = AudioObjectGetPropertyData(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamConfigurationSize,
            rawBufferList
        )
        guard streamStatus == noErr else {
            throw AudioRecorderError.audioHardware(streamStatus)
        }

        let audioBufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        let channelCount = UnsafeMutableAudioBufferListPointer(audioBufferList).reduce(UInt32(0)) {
            $0 + $1.mNumberChannels
        }
        guard channelCount > 0 else {
            throw AudioRecorderError.noMicrophone
        }

        return InputFingerprint(
            deviceID: deviceID,
            nominalSampleRate: nominalSampleRate,
            channelCount: channelCount
        )
    }

    /// Resample audio offline using AVAudioConverter (not in a real-time callback).
    private func resample(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcRate,
            channels: 1,
            interleaved: false
        ),
        let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: dstRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            return samples
        }

        let srcFrameCount = AVAudioFrameCount(samples.count)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrameCount) else {
            return samples
        }
        srcBuffer.frameLength = srcFrameCount
        if let channelData = srcBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        let ratio = dstRate / srcRate
        let dstFrameCount = AVAudioFrameCount(Double(srcFrameCount) * ratio) + 1
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrameCount) else {
            return samples
        }

        // Use the block-based API for offline conversion — works fine outside real-time callbacks
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: dstBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if status == .error {
            return samples
        }

        guard let channelData = dstBuffer.floatChannelData else { return samples }
        let count = Int(dstBuffer.frameLength)
        let result = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        return result
    }

    /// Check and request microphone permission.
    static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case noMicrophone
    case alreadyRecording
    case audioHardware(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone available"
        case .alreadyRecording:
            return "A recording is already in progress"
        case .audioHardware(let status):
            return "Audio input is unavailable (Core Audio error \(status))"
        }
    }
}
