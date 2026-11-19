import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Records microphone audio and returns raw float32 samples at 16kHz.
final class AudioRecorder: @unchecked Sendable {
    static let defaultMaximumDuration: TimeInterval = 90

    struct CapturedSegment: Sendable {
        let samples: [Float]
        let sampleRate: Double
    }

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
    /// Audio from earlier segments of the current recording kept at their
    /// native sample rates so configuration recovery does not resample on the
    /// main thread. All segments are resampled together off-MainActor on stop.
    private var completedSegments: [CapturedSegment] = []
    private var completedDurationSeconds: Double = 0
    /// Identifies the live tap so a late buffer from a replaced engine can't
    /// be appended to a segment recorded at a different sample rate.
    private var segmentID: UInt64 = 0
    /// Device the current recording started on (main thread only).
    private var recordingDeviceID: AudioDeviceID?
    private let lock = NSLock()
    private var isRecording = false
    private var reachedSampleLimit = false
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

        lock.lock()
        completedSegments.removeAll()
        completedDurationSeconds = 0
        nativeSamples.removeAll()
        isRecording = true
        reachedSampleLimit = false
        self.onLevel = onLevel
        self.onInputConfigurationChange = onInputConfigurationChange
        lock.unlock()

        do {
            try installTapAndStartEngine(input: currentInput)
            recordingDeviceID = currentInput.deviceID
        } catch {
            cleanUpFailedStart()
            throw error
        }
    }

    /// Outcome of trying to continue a recording after the engine stopped
    /// itself for an input configuration change.
    enum ConfigurationRecovery {
        /// The engine is capturing again on the same device.
        case recovered
        /// The device isn't ready yet (still switching modes); try again shortly.
        case retry
        /// The recording can't continue: it ended, or the input device changed.
        case failed
    }

    /// Continue the current recording after a configuration change on the
    /// same input device. Bluetooth headsets (AirPods) switch into headset
    /// mode when their microphone opens, which changes the device's sample
    /// rate and makes the engine stop itself moments after it started.
    ///
    /// Audio captured so far is kept; capture resumes at the device's new
    /// format. Call on the main thread, outside the configuration-change
    /// callback.
    func recoverFromConfigurationChange() -> ConfigurationRecovery {
        lock.lock()
        let recording = isRecording
        let limitReached = reachedSampleLimit
        lock.unlock()

        guard recording, let recordingDeviceID else { return .failed }
        // Recording already hit the maximum duration — keep the captured audio
        // intact rather than restarting the engine or aborting the session.
        if limitReached {
            return .recovered
        }
        guard let currentInput = try? Self.currentInputFingerprint() else { return .retry }
        guard currentInput.deviceID == recordingDeviceID else { return .failed }

        // Seal the segment captured at the old sample rate (resampling happens
        // off the main thread once recording stops).
        lock.lock()
        let segment = nativeSamples
        let segmentRate = nativeSampleRate
        nativeSamples.removeAll()
        if !segment.isEmpty, segmentRate > 0 {
            completedSegments.append(CapturedSegment(samples: segment, sampleRate: segmentRate))
            completedDurationSeconds += Double(segment.count) / segmentRate
        }
        lock.unlock()

        removeTapIfInstalled()
        replaceEngine()

        do {
            try installTapAndStartEngine(input: currentInput)
            return .recovered
        } catch {
            removeTapIfInstalled()
            replaceEngine()
            return .retry
        }
    }

    /// Installs the capture tap for a new segment of the current recording
    /// and starts the engine. Recording state must already be set up.
    private func installTapAndStartEngine(input: InputFingerprint) throws {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw AudioRecorderError.noMicrophone
        }

        lock.lock()
        segmentID &+= 1
        let segment = segmentID
        nativeSampleRate = nativeFormat.sampleRate
        let remainingDuration = max(0, maximumDuration - completedDurationSeconds)
        // Reserve enough for a typical dictation up front so the audio-thread
        // tap doesn't repeatedly reallocate-and-copy while appending (a 90s
        // recording at 48kHz grows to ~4.3M floats). Longer recordings still
        // grow geometrically beyond this.
        nativeSamples.reserveCapacity(Int(nativeFormat.sampleRate * min(30, remainingDuration)))
        // Capture the callback and limit as locals so the tap closure doesn't
        // read instance properties from the audio thread without
        // synchronisation. Both are immutable for the lifetime of this segment.
        let capturedOnLevel = onLevel
        didReportInputConfigurationChange = false
        lock.unlock()

        let segmentSampleLimit = Int(nativeFormat.sampleRate * remainingDuration)

        // Reusable scratch buffer confined to the serial tap callback thread so
        // multi-channel or non-float32 downmixing does not allocate per buffer.
        var tapScratch: [Float] = []

        // Tap in the native format — no sample-rate conversion during recording
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            Self.withMonoSamples(from: buffer, scratch: &tapScratch) { bufferPointer in
                let count = bufferPointer.count
                guard count > 0, let baseAddress = bufferPointer.baseAddress else { return }

                // Compute RMS level (vectorised; this runs on the audio tap thread)
                if let onLevel = capturedOnLevel {
                    var rms: Float = 0
                    vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(count))
                    // Normalize: typical speech RMS is ~0.01–0.1, clamp and scale to 0–1
                    let normalized = min(rms * 5.0, 1.0)
                    onLevel(normalized)
                }

                self.lock.lock()
                if self.isRecording, !self.reachedSampleLimit, self.segmentID == segment {
                    let remaining = segmentSampleLimit - self.nativeSamples.count

                    if remaining > 0 {
                        if count <= remaining {
                            self.nativeSamples.append(contentsOf: bufferPointer)
                        } else {
                            self.nativeSamples.append(contentsOf: bufferPointer.prefix(remaining))
                            self.reachedSampleLimit = true
                        }
                    } else {
                        self.reachedSampleLimit = true
                    }
                }
                self.lock.unlock()
            }
        }
        tapInstalled = true

        try engine.start()
        engineInputFingerprint = input
    }

    private func removeTapIfInstalled() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    static func convertToTargetRate(
        _ samples: [Float],
        from rate: Double,
        to targetRate: Double = 16_000
    ) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard rate > 0, targetRate > 0 else {
            throw AudioRecorderError.resamplingFailed
        }
        if rate == targetRate {
            return samples
        }
        return try resample(samples, from: rate, to: targetRate)
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

    /// Stop recording immediately and return the raw captured segments without
    /// resampling on the calling thread. Call `finalizeSegments(_:)` off the
    /// main thread to produce 16 kHz mono Float32 audio.
    func stopCapturingSegments() -> [CapturedSegment] {
        lock.lock()
        isRecording = false
        reachedSampleLimit = false
        var segments = completedSegments
        let captured = nativeSamples
        let capturedRate = nativeSampleRate
        completedSegments.removeAll()
        completedDurationSeconds = 0
        nativeSamples.removeAll()
        onLevel = nil
        onInputConfigurationChange = nil
        didReportInputConfigurationChange = false
        lock.unlock()

        recordingDeviceID = nil
        removeTapIfInstalled()
        engine.stop()

        if !captured.isEmpty, capturedRate > 0 {
            segments.append(CapturedSegment(samples: captured, sampleRate: capturedRate))
        }
        return segments
    }

    /// Stop recording and discard any captured audio.
    func stopDiscarding() {
        _ = stopCapturingSegments()
    }

    /// Stop recording and return the captured audio samples resampled to 16kHz mono float32.
    func stop() throws -> [Float] {
        try Self.finalizeSegments(stopCapturingSegments(), targetSampleRate: targetSampleRate)
    }

    /// Resamples and concatenates captured segments into 16 kHz mono Float32 samples.
    /// Safe to invoke from any background thread.
    static func finalizeSegments(
        _ segments: [CapturedSegment],
        targetSampleRate: Double = 16_000
    ) throws -> [Float] {
        guard !segments.isEmpty else { return [] }
        if segments.count == 1 {
            return try convertToTargetRate(
                segments[0].samples,
                from: segments[0].sampleRate,
                to: targetSampleRate
            )
        }

        var combined: [Float] = []
        let estimatedCount = segments.reduce(0) { partial, segment in
            guard segment.sampleRate > 0 else { return partial }
            return partial + Int(ceil(Double(segment.samples.count) * (targetSampleRate / segment.sampleRate)))
        }
        combined.reserveCapacity(estimatedCount + 64)

        for segment in segments {
            let converted = try convertToTargetRate(
                segment.samples,
                from: segment.sampleRate,
                to: targetSampleRate
            )
            combined.append(contentsOf: converted)
        }
        return combined
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
        reachedSampleLimit = false
        completedSegments.removeAll()
        completedDurationSeconds = 0
        nativeSamples.removeAll()
        onLevel = nil
        onInputConfigurationChange = nil
        didReportInputConfigurationChange = false
        lock.unlock()

        recordingDeviceID = nil
        removeTapIfInstalled()
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
        if isRecording, !reachedSampleLimit, !didReportInputConfigurationChange {
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

    /// Extracts mono Float32 samples from any supported PCM buffer layout
    /// (mono/multi-channel, interleaved/non-interleaved, float32/int16/int32).
    /// Active channels are averaged so mics plugged into non-zero inputs on
    /// multi-channel audio interfaces are captured at full level.
    static func withMonoSamples(
        from buffer: AVAudioPCMBuffer,
        scratch: inout [Float],
        _ body: (UnsafeBufferPointer<Float>) -> Void
    ) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        let isInterleaved = buffer.format.isInterleaved

        // Fast path: non-interleaved Float32
        if let floatChannels = buffer.floatChannelData {
            if !isInterleaved {
                if channelCount == 1 {
                    body(UnsafeBufferPointer(start: floatChannels[0], count: frameCount))
                    return
                }

                // Measure per-channel RMS so silent/unplugged inputs don't dilute the active mic.
                var channelRMS = [Float](repeating: 0, count: channelCount)
                var maxRMS: Float = 0
                for ch in 0..<channelCount {
                    var rms: Float = 0
                    vDSP_rmsqv(floatChannels[ch], 1, &rms, vDSP_Length(frameCount))
                    channelRMS[ch] = rms
                    if rms > maxRMS { maxRMS = rms }
                }

                let activeThreshold = max(maxRMS * 0.05, 1e-6)
                var activeChannels: [Int] = []
                activeChannels.reserveCapacity(channelCount)
                for ch in 0..<channelCount where channelRMS[ch] >= activeThreshold {
                    activeChannels.append(ch)
                }

                if activeChannels.isEmpty {
                    body(UnsafeBufferPointer(start: floatChannels[0], count: frameCount))
                    return
                }
                if activeChannels.count == 1 {
                    body(UnsafeBufferPointer(start: floatChannels[activeChannels[0]], count: frameCount))
                    return
                }

                ensureScratchCapacity(&scratch, count: frameCount)
                scratch.withUnsafeMutableBufferPointer { dst in
                    guard let dstBase = dst.baseAddress else { return }
                    dstBase.update(from: floatChannels[activeChannels[0]], count: frameCount)
                    for ch in activeChannels.dropFirst() {
                        vDSP_vadd(dstBase, 1, floatChannels[ch], 1, dstBase, 1, vDSP_Length(frameCount))
                    }
                    var invCount = 1.0 / Float(activeChannels.count)
                    vDSP_vsmul(dstBase, 1, &invCount, dstBase, 1, vDSP_Length(frameCount))
                    body(UnsafeBufferPointer(start: dstBase, count: frameCount))
                }
                return
            }

            // Interleaved Float32
            let base = floatChannels[0]
            let stride = vDSP_Stride(channelCount)
            var channelRMS = [Float](repeating: 0, count: channelCount)
            var maxRMS: Float = 0
            for ch in 0..<channelCount {
                var rms: Float = 0
                vDSP_rmsqv(base + ch, stride, &rms, vDSP_Length(frameCount))
                channelRMS[ch] = rms
                if rms > maxRMS { maxRMS = rms }
            }
            let activeThreshold = max(maxRMS * 0.05, 1e-6)
            var activeChannels = (0..<channelCount).filter { channelRMS[$0] >= activeThreshold }
            if activeChannels.isEmpty { activeChannels = [0] }

            ensureScratchCapacity(&scratch, count: frameCount)
            scratch.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                var zero: Float = 0
                vDSP_vfill(&zero, dstBase, 1, vDSP_Length(frameCount))
                for ch in activeChannels {
                    vDSP_vadd(dstBase, 1, base + ch, stride, dstBase, 1, vDSP_Length(frameCount))
                }
                if activeChannels.count > 1 {
                    var invCount = 1.0 / Float(activeChannels.count)
                    vDSP_vsmul(dstBase, 1, &invCount, dstBase, 1, vDSP_Length(frameCount))
                }
                body(UnsafeBufferPointer(start: dstBase, count: frameCount))
            }
            return
        }

        // Int16 PCM (non-interleaved or interleaved)
        if let int16Channels = buffer.int16ChannelData {
            var scale: Float = 1.0 / 32768.0
            extractIntegerChannels(
                frameCount: frameCount,
                channelCount: channelCount,
                isInterleaved: isInterleaved,
                scratch: &scratch,
                convertChannel: { ch, dst in
                    let src = isInterleaved ? int16Channels[0] + ch : int16Channels[ch]
                    let stride: vDSP_Stride = isInterleaved ? vDSP_Stride(channelCount) : 1
                    vDSP_vflt16(src, stride, dst, 1, vDSP_Length(frameCount))
                    vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
                },
                body: body
            )
            return
        }

        // Int32 PCM (non-interleaved or interleaved)
        if let int32Channels = buffer.int32ChannelData {
            var scale: Float = 1.0 / 2_147_483_648.0
            extractIntegerChannels(
                frameCount: frameCount,
                channelCount: channelCount,
                isInterleaved: isInterleaved,
                scratch: &scratch,
                convertChannel: { ch, dst in
                    let src = isInterleaved ? int32Channels[0] + ch : int32Channels[ch]
                    let stride: vDSP_Stride = isInterleaved ? vDSP_Stride(channelCount) : 1
                    vDSP_vflt32(src, stride, dst, 1, vDSP_Length(frameCount))
                    vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
                },
                body: body
            )
        }
    }

    private static func extractIntegerChannels(
        frameCount: Int,
        channelCount: Int,
        isInterleaved: Bool,
        scratch: inout [Float],
        convertChannel: (Int, UnsafeMutablePointer<Float>) -> Void,
        body: (UnsafeBufferPointer<Float>) -> Void
    ) {
        _ = isInterleaved
        // Allocate space for accumulation + single-channel temp buffer.
        ensureScratchCapacity(&scratch, count: frameCount * 2)
        scratch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let acc = base
            let tmp = base + frameCount
            var zero: Float = 0
            vDSP_vfill(&zero, acc, 1, vDSP_Length(frameCount))

            var activeCount = 0
            for ch in 0..<channelCount {
                convertChannel(ch, tmp)
                var rms: Float = 0
                vDSP_rmsqv(tmp, 1, &rms, vDSP_Length(frameCount))
                if rms >= 1e-6 || channelCount == 1 {
                    vDSP_vadd(acc, 1, tmp, 1, acc, 1, vDSP_Length(frameCount))
                    activeCount += 1
                }
            }
            if activeCount > 1 {
                var invCount = 1.0 / Float(activeCount)
                vDSP_vsmul(acc, 1, &invCount, acc, 1, vDSP_Length(frameCount))
            }
            body(UnsafeBufferPointer(start: acc, count: frameCount))
        }
    }

    private static func ensureScratchCapacity(_ scratch: inout [Float], count: Int) {
        if scratch.count < count {
            scratch = [Float](repeating: 0, count: count)
        }
    }

    /// Resample audio offline using AVAudioConverter (not in a real-time callback).
    /// Drains the converter until `.endOfStream` so trailing filter-primed frames are not truncated.
    static func resample(_ samples: [Float], from srcRate: Double, to dstRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard srcRate > 0, dstRate > 0 else {
            throw AudioRecorderError.resamplingFailed
        }
        guard srcRate != dstRate else { return samples }

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
            throw AudioRecorderError.resamplingFailed
        }

        let srcFrameCount = AVAudioFrameCount(samples.count)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrameCount) else {
            throw AudioRecorderError.resamplingFailed
        }
        srcBuffer.frameLength = srcFrameCount
        guard let srcChannelData = srcBuffer.floatChannelData else {
            throw AudioRecorderError.resamplingFailed
        }
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            srcChannelData[0].update(from: base, count: samples.count)
        }

        let expectedFrames = Int(ceil(Double(samples.count) * (dstRate / srcRate)))
        let chunkCapacity = AVAudioFrameCount(max(4096, min(expectedFrames + 1024, 65_536)))
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: chunkCapacity) else {
            throw AudioRecorderError.resamplingFailed
        }

        var output: [Float] = []
        output.reserveCapacity(expectedFrames + 64)

        var consumed = false
        while true {
            dstBuffer.frameLength = 0
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
                throw AudioRecorderError.resamplingFailed
            }

            let produced = Int(dstBuffer.frameLength)
            if produced > 0, let channelData = dstBuffer.floatChannelData {
                output.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: produced))
            }

            if status == .endOfStream || produced == 0 {
                break
            }
        }

        guard !output.isEmpty else {
            throw AudioRecorderError.resamplingFailed
        }
        return output
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
    case resamplingFailed

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone available"
        case .alreadyRecording:
            return "A recording is already in progress"
        case .audioHardware(let status):
            return "Audio input is unavailable (Core Audio error \(status))"
        case .resamplingFailed:
            return "Failed to process recorded audio"
        }
    }
}
