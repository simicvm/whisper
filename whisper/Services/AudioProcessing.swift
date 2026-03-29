import Accelerate
import Foundation

/// Audio preprocessing utilities applied between recording and transcription.
///
/// These operations improve transcription accuracy and reduce inference time
/// by removing silence and normalising levels before the audio reaches the model.
enum AudioProcessing {

    // MARK: - Voice Activity Detection (silence trimming)

    /// Trim leading and trailing silence from recorded audio using an
    /// adaptive energy-based voice activity detector.
    ///
    /// The algorithm:
    /// 1. Splits the audio into short overlapping windows.
    /// 2. Computes the RMS energy of each window.
    /// 3. Estimates a noise floor from the quietest windows.
    /// 4. Marks windows whose energy exceeds a threshold above the noise floor.
    /// 5. Returns the audio between the first and last active windows,
    ///    plus a small pre-roll and post-roll to preserve natural onset/offset.
    ///
    /// If no speech is detected the original audio is returned unchanged so
    /// the downstream model can make the final decision.
    ///
    /// - Parameters:
    ///   - samples: Mono float32 audio samples.
    ///   - sampleRate: Sample rate of `samples` (e.g. 16 000).
    /// - Returns: A (possibly shorter) slice of the input.
    static func trimSilence(
        from samples: [Float],
        sampleRate: Double
    ) -> [Float] {
        let config = VADConfig()
        let windowSamples = Int(config.windowDuration * sampleRate)
        let hopSamples = Int(config.hopDuration * sampleRate)

        guard windowSamples > 0, hopSamples > 0, samples.count >= windowSamples else {
            return samples
        }

        // 1. Compute per-window RMS energy.
        let energies = windowEnergies(
            samples: samples,
            windowSize: windowSamples,
            hopSize: hopSamples
        )
        guard !energies.isEmpty else { return samples }

        // 2. Estimate the noise floor from the lowest-energy windows.
        let noiseFloor = estimateNoiseFloor(energies: energies, config: config)

        // 3. Determine the speech threshold.
        let threshold = max(
            noiseFloor * config.thresholdMultiplier,
            config.minimumThreshold
        )

        // 4. Find first and last windows above the threshold.
        guard let firstActive = energies.firstIndex(where: { $0 > threshold }),
              let lastActive = energies.lastIndex(where: { $0 > threshold }) else {
            // No speech detected — return unchanged.
            return samples
        }

        // 5. Convert window indices to sample indices with pre/post roll.
        let preRollSamples = Int(config.preRollDuration * sampleRate)
        let postRollSamples = Int(config.postRollDuration * sampleRate)

        let startSample = max(firstActive * hopSamples - preRollSamples, 0)
        let endSample = min(lastActive * hopSamples + windowSamples + postRollSamples, samples.count)

        guard startSample < endSample else { return samples }

        return Array(samples[startSample..<endSample])
    }

    // MARK: - Gain Normalisation

    /// Normalise audio so the peak amplitude reaches a target level.
    ///
    /// This ensures consistent input levels to the transcription model
    /// regardless of microphone gain settings or distance.
    ///
    /// - Parameters:
    ///   - samples: Mono float32 audio samples.
    ///   - targetPeak: Desired peak amplitude (0–1). Default 0.9 to leave headroom.
    /// - Returns: Amplitude-scaled copy of the input.
    static func normalizeGain(
        _ samples: [Float],
        targetPeak: Float = 0.9
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }

        // Find absolute peak using vDSP for efficiency.
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        // Don't amplify near-silence — it would just boost noise.
        let minimumPeakForNormalisation: Float = 0.001
        guard peak >= minimumPeakForNormalisation else { return samples }

        // Already at or above target — no need to scale up.
        guard peak < targetPeak else { return samples }

        var scale = targetPeak / peak
        var result = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &scale, &result, 1, vDSP_Length(samples.count))
        return result
    }

    // MARK: - Internals

    /// Configuration for the voice activity detector.
    private struct VADConfig {
        /// Duration of each analysis window in seconds.
        let windowDuration: Double = 0.03  // 30 ms
        /// Hop between consecutive windows in seconds.
        let hopDuration: Double = 0.01     // 10 ms
        /// Multiplier above the noise floor to set the speech threshold.
        let thresholdMultiplier: Float = 3.0
        /// Absolute minimum RMS threshold — prevents false positives in pure silence.
        let minimumThreshold: Float = 0.005
        /// Audio to keep before the first detected speech.
        let preRollDuration: Double = 0.1  // 100 ms
        /// Audio to keep after the last detected speech.
        let postRollDuration: Double = 0.2 // 200 ms
        /// Fraction of lowest-energy windows used to estimate the noise floor.
        let noiseFloorPercentile: Double = 0.10 // bottom 10%
    }

    /// Compute the RMS energy for each sliding window.
    private static func windowEnergies(
        samples: [Float],
        windowSize: Int,
        hopSize: Int
    ) -> [Float] {
        var energies: [Float] = []
        energies.reserveCapacity((samples.count - windowSize) / hopSize + 1)

        var offset = 0
        while offset + windowSize <= samples.count {
            var sumOfSquares: Float = 0
            // Use vDSP for the dot product (sum of squares).
            samples.withUnsafeBufferPointer { buf in
                let ptr = buf.baseAddress! + offset
                vDSP_dotpr(ptr, 1, ptr, 1, &sumOfSquares, vDSP_Length(windowSize))
            }
            let rms = sqrtf(sumOfSquares / Float(windowSize))
            energies.append(rms)
            offset += hopSize
        }

        return energies
    }

    /// Estimate the noise floor as the average energy of the quietest windows.
    private static func estimateNoiseFloor(energies: [Float], config: VADConfig) -> Float {
        guard !energies.isEmpty else { return 0 }

        let sorted = energies.sorted()
        let count = max(Int(Double(sorted.count) * config.noiseFloorPercentile), 1)
        let sum = sorted.prefix(count).reduce(Float(0), +)
        return sum / Float(count)
    }
}
