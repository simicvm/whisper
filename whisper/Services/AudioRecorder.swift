import AVFoundation
import Foundation

/// Records microphone audio and returns raw float32 samples at 16kHz.
final class AudioRecorder: @unchecked Sendable {
    static let defaultMaximumDuration: TimeInterval = 90

    private var engine: AVAudioEngine?
    private var nativeSamples: [Float] = []
    private var nativeSampleRate: Double = 0
    private let lock = NSLock()
    private var isRecording = false
    private var onLevel: (@Sendable (Float) -> Void)?

    /// Target sample rate for the STT model.
    private let targetSampleRate: Double = 16000
    private let maximumDuration: TimeInterval

    init(maximumDuration: TimeInterval = AudioRecorder.defaultMaximumDuration) {
        self.maximumDuration = max(1, maximumDuration)
    }

    /// Start recording from the default microphone.
    /// - Parameter onLevel: Called on every buffer with the current RMS level (0–1).
    func start(onLevel: (@Sendable (Float) -> Void)? = nil) throws {
        self.onLevel = onLevel

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0 else {
            throw AudioRecorderError.noMicrophone
        }

        nativeSampleRate = nativeFormat.sampleRate

        lock.lock()
        nativeSamples.removeAll()
        isRecording = true
        lock.unlock()

        // Tap in the native format — no conversion during recording
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            // Take first channel only
            let bufferPointer = UnsafeBufferPointer(start: channelData[0], count: count)

            // Compute RMS level
            if let onLevel = self.onLevel {
                var sumOfSquares: Float = 0
                for sample in bufferPointer {
                    sumOfSquares += sample * sample
                }
                let rms = sqrtf(sumOfSquares / Float(count))
                // Normalize: typical speech RMS is ~0.01–0.1, clamp and scale to 0–1
                let normalized = min(rms * 5.0, 1.0)
                onLevel(normalized)
            }

            self.lock.lock()
            if self.isRecording {
                let maxNativeSamples = Int(self.nativeSampleRate * self.maximumDuration)
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

        try engine.start()
    }

    /// Stop recording and return the captured audio samples resampled to 16kHz mono float32.
    func stop() -> [Float] {
        lock.lock()
        isRecording = false
        let captured = nativeSamples
        let capturedRate = nativeSampleRate
        nativeSamples.removeAll()
        lock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        onLevel = nil

        guard !captured.isEmpty else { return [] }

        // Resample to 16kHz if needed
        if capturedRate == targetSampleRate {
            return captured
        }

        return resample(captured, from: capturedRate, to: targetSampleRate)
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

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone available"
        }
    }
}
