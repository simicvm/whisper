import Accelerate
import Foundation

/// Audio preprocessing utilities applied between recording and transcription.
///
/// These operations improve transcription accuracy and reduce inference time
/// by removing silence and normalising levels before the audio reaches the model.
nonisolated enum AudioProcessing {

    /// Outcome of voice-activity analysis on a recording.
    enum SpeechDetectionResult: Sendable {
        /// Speech was found. The associated audio is trimmed to the active
        /// region (plus pre/post roll) and is safe to gain-normalise.
        case speech([Float])
        /// No window cleared the relative speech threshold, but enough signal
        /// is present that quiet, noisy, or dynamics-compressed speech can't
        /// be ruled out. The original audio is passed through untouched so
        /// the model can make the final call; it should not be normalised,
        /// as that would amplify what may be pure noise.
        case indeterminate([Float])
        /// The recording is near-absolute silence (muted or dead microphone,
        /// nobody speaking). Safe to reject without involving the model.
        case silence
    }

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
    /// When no window exceeds the speech threshold, the result distinguishes
    /// near-absolute silence (`.silence`, safe to reject — feeding it to the
    /// model invites hallucinated text) from a merely uncertain recording
    /// (`.indeterminate`, e.g. low SNR or compressed dynamics, where the
    /// relative threshold can sit above genuine speech and the model should
    /// make the final call on the unmodified audio).
    ///
    /// - Parameters:
    ///   - samples: Mono float32 audio samples.
    ///   - sampleRate: Sample rate of `samples` (e.g. 16 000).
    static func trimSilence(
        from samples: [Float],
        sampleRate: Double
    ) -> SpeechDetectionResult {
        let config = VADConfig()
        let windowSamples = Int(config.windowDuration * sampleRate)
        let hopSamples = Int(config.hopDuration * sampleRate)

        // Too short to analyse — pass through and let the model decide.
        guard windowSamples > 0, hopSamples > 0, samples.count >= windowSamples else {
            return .indeterminate(samples)
        }

        // 1. Compute per-window RMS energy.
        let energies = windowEnergies(
            samples: samples,
            windowSize: windowSamples,
            hopSize: hopSamples
        )
        guard !energies.isEmpty else { return .indeterminate(samples) }

        // 2. Estimate the noise floor from the lowest-energy windows.
        let noiseFloor = estimateNoiseFloor(energies: energies, config: config)

        // If the quietest 10% of windows are already loud, there is no reliable
        // silence floor in this clip (either the user spoke continuously from
        // start to finish, or ambient noise is very high). Pass the audio
        // through untouched rather than risking slicing off speech or boosting
        // loud background noise.
        guard noiseFloor <= config.maxNoiseFloor else {
            return .indeterminate(samples)
        }

        // 3. Determine speech detection (high) and boundary (low/hysteresis)
        // thresholds. Using a lower boundary threshold keeps softer word onsets
        // and offsets intact once speech is confirmed.
        let highThreshold = max(
            noiseFloor * config.thresholdMultiplier,
            config.minimumThreshold
        )
        let lowThreshold = max(
            noiseFloor * config.boundaryThresholdMultiplier,
            config.minimumThreshold
        )

        // 4. Confirm at least one window clears the speech threshold.
        guard energies.contains(where: { $0 > highThreshold }),
              let firstActive = energies.firstIndex(where: { $0 > lowThreshold }),
              let lastActive = energies.lastIndex(where: { $0 > lowThreshold }) else {
            // No window cleared the relative threshold. Reject only when the
            // signal is near-absolute silence; otherwise the recording may be
            // quiet, noisy, or compressed speech the VAD can't certify — for
            // a user whose setup always lands here, rejecting would make every
            // attempt fail, so hand the audio to the model unchanged instead.
            let maxEnergy = energies.max() ?? 0
            if maxEnergy < config.absoluteSilenceFloor {
                return .silence
            }
            return .indeterminate(samples)
        }

        // 5. Convert window indices to sample indices with pre/post roll.
        let preRollSamples = Int(config.preRollDuration * sampleRate)
        let postRollSamples = Int(config.postRollDuration * sampleRate)

        let startSample = max(firstActive * hopSamples - preRollSamples, 0)
        let endSample = min(lastActive * hopSamples + windowSamples + postRollSamples, samples.count)

        guard startSample < endSample else { return .speech(samples) }

        return .speech(Array(samples[startSample..<endSample]))
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
        let count = samples.count
        return [Float](unsafeUninitializedCapacity: count) { buffer, initializedCount in
            samples.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = buffer.baseAddress else { return }
                vDSP_vsmul(srcBase, 1, &scale, dstBase, 1, vDSP_Length(count))
            }
            initializedCount = count
        }
    }

    // MARK: - Internals

    /// Configuration for the voice activity detector.
    private struct VADConfig {
        /// Duration of each analysis window in seconds.
        let windowDuration: Double = 0.03  // 30 ms
        /// Hop between consecutive windows in seconds.
        let hopDuration: Double = 0.01     // 10 ms
        /// Multiplier above the noise floor to confirm speech is present.
        let thresholdMultiplier: Float = 3.0
        /// Multiplier above the noise floor used to locate speech boundaries
        /// once speech is confirmed (hysteresis preserves soft word edges).
        let boundaryThresholdMultiplier: Float = 1.6
        /// Maximum RMS that can still represent a silence floor. Above this,
        /// the clip either has continuous speech with no silence or very loud
        /// ambient noise, so trimming is skipped.
        let maxNoiseFloor: Float = 0.025
        /// Absolute minimum RMS threshold — prevents false positives in pure silence.
        let minimumThreshold: Float = 0.005
        /// Window RMS below which the whole recording counts as silent when
        /// no window clears the speech threshold. Kept well under
        /// `minimumThreshold` so quiet-but-real speech is handed to the model
        /// (as `.indeterminate`) rather than rejected.
        let absoluteSilenceFloor: Float = 0.002
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
        let windowCount = (samples.count - windowSize) / hopSize + 1
        guard windowCount > 0 else { return [] }

        let invWindowSize = 1.0 / Float(windowSize)
        var meanSquares = [Float](unsafeUninitializedCapacity: windowCount) { buffer, initializedCount in
            samples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress, let dst = buffer.baseAddress else { return }

                if windowSize % hopSize == 0 {
                    // Compute non-overlapping hop-sized block energies once and
                    // combine adjacent blocks per window (3x fewer multiplies).
                    let blocksPerWindow = windowSize / hopSize
                    let blockCount = windowCount + blocksPerWindow - 1
                    var blockSums = [Float](repeating: 0, count: blockCount)
                    for b in 0..<blockCount {
                        var sumSq: Float = 0
                        vDSP_svesq(base + b * hopSize, 1, &sumSq, vDSP_Length(hopSize))
                        blockSums[b] = sumSq
                    }
                    for w in 0..<windowCount {
                        var sumSq: Float = 0
                        for k in 0..<blocksPerWindow {
                            sumSq += blockSums[w + k]
                        }
                        dst[w] = sumSq * invWindowSize
                    }
                } else {
                    for w in 0..<windowCount {
                        var sumSq: Float = 0
                        vDSP_svesq(base + w * hopSize, 1, &sumSq, vDSP_Length(windowSize))
                        dst[w] = sumSq * invWindowSize
                    }
                }
            }
            initializedCount = windowCount
        }

        var countInt32 = Int32(windowCount)
        var rms = [Float](unsafeUninitializedCapacity: windowCount) { buffer, initializedCount in
            meanSquares.withUnsafeBufferPointer { src in
                guard let srcBase = src.baseAddress, let dstBase = buffer.baseAddress else { return }
                vvsqrtf(dstBase, srcBase, &countInt32)
            }
            initializedCount = windowCount
        }
        return rms
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
