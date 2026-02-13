import Foundation
import MLX
import MLXAudioSTT
import MLXAudioCore
import HuggingFace

/// Wraps Qwen3ASRModel for loading and transcribing audio.
///
/// The actor isolates model ownership and serializes operations.
/// Inference itself runs on a dedicated queue so long synchronous
/// `model.generate(...)` work does not execute on Swift's cooperative executor.
actor TranscriptionService {
    private var model: Qwen3ASRModel?
    private var currentRepoID: String?

    /// Guards stale completions for actor-owned model state.
    /// Kept separate from `WhisperApp.modelLoadGeneration`, which protects UI updates.
    private var loadGeneration: UInt64 = 0

    private var hasActiveOperation = false
    private var waitingOperations: [CheckedContinuation<Void, Never>] = []
    private static let cacheInspectionQueue = DispatchQueue(
        label: "shoki.whisper.transcription.cache-inspection",
        qos: .utility
    )
    private let inferenceQueue = DispatchQueue(
        label: "shoki.whisper.transcription.inference",
        qos: .userInitiated
    )

    // Safe: immutable payload; model access is serialized by acquireOperationTurn.
    private struct InferenceRequest: @unchecked Sendable {
        let model: Qwen3ASRModel
        let audio: [Float]
    }

    /// Whether a model is currently loaded and ready.
    var isLoaded: Bool { model != nil }

    /// Returns repo IDs that have a complete local snapshot.
    func downloadedModelRepoIDs(for repoIDs: [String]) async -> Set<String> {
        var downloaded: Set<String> = []
        for repoID in repoIDs {
            let modelDir = Self.modelDirectory(for: repoID)
            if await Self.hasCompleteModelSnapshot(at: modelDir) {
                downloaded.insert(repoID)
            }
        }
        return downloaded
    }

    /// Deletes a specific local model snapshot.
    func deleteLocalModel(repoID: String) async throws {
        try Task.checkCancellation()
        await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        if currentRepoID == repoID {
            invalidateLoadedModel()
        }

        let modelDir = Self.modelDirectory(for: repoID)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            return
        }

        try FileManager.default.removeItem(at: modelDir)
    }

    /// Load a Qwen3 ASR model from a HuggingFace repo.
    /// Downloads on first use, cached locally for subsequent launches.
    func loadModel(
        repoID: String,
        updateHandler: (@MainActor @Sendable (ModelLoadUpdate) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        // Skip if already loaded with same model
        if currentRepoID == repoID && model != nil {
            return
        }

        // Unload previous model
        invalidateLoadedModel()
        let generation = loadGeneration

        try Task.checkCancellation()

        try await Self.ensureModelSnapshot(repoID: repoID, updateHandler: updateHandler)

        try Task.checkCancellation()

        await updateHandler?(.initializing)

        let loaded = try await Qwen3ASRModel.fromPretrained(repoID)

        try Task.checkCancellation()
        guard generation == loadGeneration else {
            throw CancellationError()
        }

        model = loaded
        currentRepoID = repoID
    }

    /// Ensures required model files exist in the model cache directory.
    /// This emits explicit download progress so UI can distinguish download
    /// from later model initialization.
    private static func ensureModelSnapshot(
        repoID: String,
        updateHandler: (@MainActor @Sendable (ModelLoadUpdate) -> Void)? = nil
    ) async throws {
        let modelDir = modelDirectory(for: repoID)
        guard !(await hasCompleteModelSnapshot(at: modelDir)) else { return }

        guard let hfRepoID = Repo.ID(rawValue: repoID) else {
            throw TranscriptionError.invalidRepositoryID(repoID)
        }

        await updateHandler?(.downloading(progress: 0))

        // Create directory if needed (first-time download case)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let client = HubClient.default
        _ = try await client.downloadSnapshot(
            of: hfRepoID,
            kind: .model,
            to: modelDir,
            revision: "main",
            matching: ["*.safetensors", "*.json", "merges.txt"],
            progressHandler: { progress in
                let fraction = progress.fractionCompleted
                let normalized =
                    fraction.isFinite ? min(max(fraction, 0), 1) : 0
                if let updateHandler {
                    Task { @MainActor in
                        updateHandler(.downloading(progress: normalized))
                    }
                }
            }
        )

        // Keep going even if our local snapshot predicate fails so upstream
        // fromPretrained() can resolve/download via its own cache strategy.
        _ = await hasCompleteModelSnapshot(at: modelDir)

        await updateHandler?(.downloading(progress: 1))
    }

    private static func modelDirectory(for repoID: String) -> URL {
        // Keep this convention aligned with MLXAudioCore.ModelUtils.
        // If upstream cache layout changes, ensureModelSnapshot falls back to
        // fromPretrained()'s resolver instead of failing hard.
        let modelSubdir = repoID.replacingOccurrences(of: "/", with: "_")
        return URL.cachesDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelSubdir)
    }

    private static func hasCompleteModelSnapshot(at modelDir: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            cacheInspectionQueue.async {
                continuation.resume(returning: hasCompleteModelSnapshotSync(at: modelDir))
            }
        }
    }

    private static func hasCompleteModelSnapshotSync(at modelDir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            return false
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: nil
        )) ?? []

        let hasWeights = files.contains { $0.pathExtension == "safetensors" }
        let hasMerges = FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("merges.txt").path
        )
        let configPath = modelDir.appendingPathComponent("config.json")
        let hasValidConfig =
            FileManager.default.fileExists(atPath: configPath.path)
            && {
                guard let data = try? Data(contentsOf: configPath) else {
                    return false
                }
                return (try? JSONSerialization.jsonObject(with: data)) != nil
            }()

        return hasWeights && hasMerges && hasValidConfig
    }

    /// Transcribe raw audio samples to text.
    /// - Parameter audio: Float32 samples at 16kHz, mono.
    /// - Returns: Transcribed text string.
    func transcribe(audio: [Float]) async throws -> String {
        try Task.checkCancellation()
        await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        guard let model else {
            throw TranscriptionError.modelNotLoaded
        }

        guard !audio.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        try Task.checkCancellation()

        let text = await runInference(model: model, audio: audio)

        try Task.checkCancellation()

        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        return text
    }

    private func invalidateLoadedModel() {
        loadGeneration &+= 1
        model = nil
        currentRepoID = nil
        Memory.clearCache()
    }

    private func acquireOperationTurn() async {
        if !hasActiveOperation {
            hasActiveOperation = true
            return
        }

        await withCheckedContinuation { continuation in
            waitingOperations.append(continuation)
        }
    }

    private func releaseOperationTurn() {
        if waitingOperations.isEmpty {
            hasActiveOperation = false
            return
        }

        let next = waitingOperations.removeFirst()
        next.resume()
    }

    private func runInference(model: Qwen3ASRModel, audio: [Float]) async -> String {
        let request = InferenceRequest(model: model, audio: audio)

        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
                let mlxAudio = MLXArray(request.audio)
                let output = request.model.generate(
                    audio: mlxAudio,
                    language: "English"
                )
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
        }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case emptyResult
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "STT model not loaded"
        case .emptyAudio:
            return "No audio recorded"
        case .emptyResult:
            return "No speech detected"
        case .invalidRepositoryID(let repoID):
            return "Invalid model repository ID: \(repoID)"
        }
    }
}

enum ModelLoadUpdate: Sendable {
    case downloading(progress: Double)
    case initializing
}
