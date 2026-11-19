import Foundation
import os
import MLX
import MLXAudioSTT
import MLXAudioCore
import HuggingFace

/// Loads MLXAudioSTT speech-to-text models and transcribes audio with them.
///
/// The actor isolates model ownership and serializes operations.
/// Inference itself runs on a dedicated queue so long synchronous
/// `model.generate(...)` work does not execute on Swift's cooperative executor.
actor TranscriptionService {
    private static let metalCacheLimitBytes = 64 * 1024 * 1024

    private var model: (any STTGenerationModel)?
    private var currentFamily: STTModelFamily?
    private var currentRepoID: String?
    private var didConfigureMetalCacheLimit = false

    /// Guards stale completions for actor-owned model state.
    /// Kept separate from `WhisperApp.modelLoadGeneration`, which protects UI updates.
    private var loadGeneration: UInt64 = 0

    private var hasActiveOperation = false
    private var waitingOperations: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var warmupTask: Task<Void, Never>?
    private static let maxConcurrentDownloads = 4
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
        let model: any STTGenerationModel
        let parameters: STTGenerateParameters
        let audio: [Float]
    }

    private struct LoadedModelBox: @unchecked Sendable {
        let model: any STTGenerationModel
    }

    private struct NemotronModelBox: @unchecked Sendable {
        let model: NemotronASRModel
    }

    private struct NemotronStreamBox: @unchecked Sendable {
        let session: NemotronASRStreamSession
    }

    /// Whether a model is currently loaded and ready.
    var isLoaded: Bool { model != nil }

    /// Whether the currently loaded model supports incremental streaming during recording.
    var supportsLiveStreaming: Bool { model is NemotronASRModel }

    /// Starts an incremental streaming session for Nemotron 3.5 ASR models so
    /// audio chunks can be encoded while the user is still speaking.
    /// Returns `nil` for models that use offline post-recording transcription.
    func beginStreamingSession() async throws -> LiveTranscriptionSession? {
        try Task.checkCancellation()
        try await acquireOperationTurn()

        guard let nemotronModel = model as? NemotronASRModel else {
            releaseOperationTurn()
            return nil
        }

        let language = Self.generationParameters(for: .nemotron).language
        let box = NemotronModelBox(model: nemotronModel)
        let queue = inferenceQueue

        let streamSession: NemotronStreamBox = await withCheckedContinuation { continuation in
            queue.async {
                let session = box.model.makeStreamSession(language: language)
                continuation.resume(returning: NemotronStreamBox(session: session))
            }
        }

        return LiveTranscriptionSession(
            inferenceQueue: queue,
            streamSession: streamSession.session,
            onReleaseTurn: { [weak self] in
                await self?.finishStreamingTurn()
            }
        )
    }

    private func finishStreamingTurn() {
        releaseOperationTurn()
    }

    /// Returns repo IDs that have a complete local snapshot.
    func downloadedModelRepoIDs(for repoIDs: [String]) async -> Set<String> {
        var downloaded: Set<String> = []
        for repoID in repoIDs {
            guard let definition = STTModelDefinition.find(repoID: repoID) else { continue }
            let modelDir = Self.modelDirectory(for: repoID)
            if await Self.hasCompleteModelSnapshot(at: modelDir, family: definition.family) {
                downloaded.insert(repoID)
            }
        }
        return downloaded
    }

    /// Returns repo IDs that have any app-managed cache artifacts to remove.
    func removableModelRepoIDs(for repoIDs: [String]) async -> Set<String> {
        var removable: Set<String> = []
        for repoID in repoIDs where await Self.hasRemovableCache(for: repoID) {
            removable.insert(repoID)
        }
        return removable
    }

    /// Deletes a specific local model snapshot and any Hugging Face cache entries
    /// that may have been created by older download paths.
    func deleteLocalModel(repoID: String) async throws {
        try Task.checkCancellation()
        try await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        if currentRepoID == repoID {
            invalidateLoadedModel()
        }

        for cachePath in Self.cachePathsToDelete(for: repoID) {
            try Self.removeItemIfExists(at: cachePath)
        }
    }

    /// Load an STT model from a HuggingFace repo.
    /// Downloads on first use, cached locally for subsequent launches.
    func loadModel(
        repoID: String,
        updateHandler: (@MainActor @Sendable (ModelLoadUpdate) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        try await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        guard let definition = STTModelDefinition.find(repoID: repoID) else {
            throw TranscriptionError.unsupportedModel(repoID)
        }

        // Skip if already loaded with same model
        if currentRepoID == repoID && model != nil {
            return
        }

        if !didConfigureMetalCacheLimit {
            Memory.cacheLimit = Self.metalCacheLimitBytes
            didConfigureMetalCacheLimit = true
        }

        // Unload previous model
        invalidateLoadedModel()
        let generation = loadGeneration

        try Task.checkCancellation()

        try await Self.ensureModelSnapshot(for: definition, updateHandler: updateHandler)

        try Task.checkCancellation()

        await updateHandler?(.initializing)

        let loaded = try await loadPretrainedModel(for: definition)

        try Task.checkCancellation()
        guard generation == loadGeneration else {
            throw CancellationError()
        }

        model = loaded
        currentFamily = definition.family
        currentRepoID = repoID
        scheduleShaderWarmup(generation: generation)
    }

    private func loadPretrainedModel(
        for definition: STTModelDefinition
    ) async throws -> any STTGenerationModel {
        let modelDir = Self.modelDirectory(for: definition.repoID)
        let hasLocalSnapshot = await Self.hasCompleteModelSnapshot(
            at: modelDir,
            family: definition.family
        )

        switch definition.family {
        case .qwen3:
            if hasLocalSnapshot {
                return try await Qwen3ASRModel.fromModelDirectory(modelDir)
            }
            return try await Qwen3ASRModel.fromPretrained(definition.repoID)
        case .nemotron:
            if hasLocalSnapshot {
                return try await loadOnInferenceQueue {
                    try NemotronASRModel.fromDirectory(modelDir)
                }
            }
            return try await NemotronASRModel.fromPretrained(definition.repoID)
        case .parakeet:
            if hasLocalSnapshot {
                return try await loadOnInferenceQueue {
                    try ParakeetModel.fromDirectory(modelDir)
                }
            }
            return try await ParakeetModel.fromPretrained(definition.repoID)
        }
    }

    /// Runs synchronous model deserialisation and weight `eval` on `inferenceQueue`
    /// so heavy disk/Metal work does not block Swift's cooperative thread pool.
    private func loadOnInferenceQueue(
        _ loader: @escaping @Sendable () throws -> any STTGenerationModel
    ) async throws -> any STTGenerationModel {
        let box: LoadedModelBox = try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async {
                do {
                    let loaded = try loader()
                    continuation.resume(returning: LoadedModelBox(model: loaded))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return box.model
    }

    /// Pre-compiles Metal inference pipelines with a tiny silent clip right
    /// after model load so the very first dictation does not pay shader
    /// compilation latency.
    private func scheduleShaderWarmup(generation: UInt64) {
        warmupTask?.cancel()
        warmupTask = Task(priority: .utility) {
            await performShaderWarmup(generation: generation)
        }
    }

    private func performShaderWarmup(generation: UInt64) async {
        do {
            try await acquireOperationTurn()
        } catch {
            return
        }
        defer { releaseOperationTurn() }

        guard !Task.isCancelled,
              generation == loadGeneration,
              let model,
              let currentFamily else {
            return
        }

        let warmupSamples = [Float](repeating: 0, count: max(1, model.sampleRate / 4))
        let parameters: STTGenerateParameters
        switch currentFamily {
        case .qwen3:
            parameters = STTGenerateParameters(maxTokens: 1, language: "English")
        case .nemotron, .parakeet:
            parameters = STTGenerateParameters(language: "en")
        }

        _ = await runInference(model: model, parameters: parameters, audio: warmupSamples)
    }

    internal static func qwen3MaxTokens(
        audioSampleCount: Int?,
        sampleRate: Double = 16_000
    ) -> Int {
        guard let audioSampleCount, sampleRate > 0 else { return 2048 }
        let audioSeconds = Double(audioSampleCount) / sampleRate
        return min(2048, max(64, Int((audioSeconds * 12.0).rounded(.up)) + 64))
    }

    internal static func generationParameters(
        for family: STTModelFamily,
        audioSampleCount: Int? = nil,
        sampleRate: Double = 16_000
    ) -> STTGenerateParameters {
        switch family {
        case .qwen3:
            // Cap maxTokens proportionally to audio length (~3-5 spoken tokens/s
            // with ~3x headroom) so a repetition hallucination cannot run up to
            // the 8,192-token default and stall for minutes.
            let maxTokens = qwen3MaxTokens(
                audioSampleCount: audioSampleCount,
                sampleRate: sampleRate
            )
            return STTGenerateParameters(maxTokens: maxTokens, language: "English")
        case .nemotron:
            // Must be a prompt_dictionary key from the checkpoint config
            // ("en", not "English"); unrecognized keys silently fall back
            // to "auto" language detection.
            return STTGenerateParameters(language: "en")
        case .parakeet:
            return STTGenerateParameters(language: "en")
        }
    }

    /// Ensures required model files exist in the model cache directory.
    /// This emits explicit download progress so UI can distinguish download
    /// from later model initialization.
    private static func ensureModelSnapshot(
        for definition: STTModelDefinition,
        updateHandler: (@MainActor @Sendable (ModelLoadUpdate) -> Void)? = nil
    ) async throws {
        let modelDir = modelDirectory(for: definition.repoID)
        guard !(await hasCompleteModelSnapshot(at: modelDir, family: definition.family)) else { return }

        guard let hfRepoID = Repo.ID(rawValue: definition.repoID) else {
            throw TranscriptionError.invalidRepositoryID(definition.repoID)
        }

        await updateHandler?(.downloading(progress: 0))

        // Create directory if needed (first-time download case)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        try await downloadModelFiles(
            for: definition,
            repo: hfRepoID,
            to: modelDir,
            updateHandler: updateHandler
        )

        // Keep going even if our local snapshot predicate fails so upstream
        // fromPretrained() can resolve/download via its own cache strategy.
        _ = await hasCompleteModelSnapshot(at: modelDir, family: definition.family)

        await updateHandler?(.downloading(progress: 1))
    }

    private static func modelDirectory(for repoID: String) -> URL {
        // Keep this convention aligned with MLXAudioCore.ModelUtils.
        // If upstream cache layout changes, ensureModelSnapshot falls back to
        // fromPretrained()'s resolver instead of failing hard.
        let modelSubdir = repoID.replacingOccurrences(of: "/", with: "_")
        return HubCache.default.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelSubdir)
    }

    private static func legacyModelDirectory(for repoID: String) -> URL {
        let modelSubdir = repoID.replacingOccurrences(of: "/", with: "_")
        return URL.cachesDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelSubdir)
    }

    private static func cachePathsToDelete(for repoID: String) -> [URL] {
        var paths = [
            modelDirectory(for: repoID),
            legacyModelDirectory(for: repoID),
        ]

        if let hfRepoID = Repo.ID(rawValue: repoID) {
            let cache = HubCache.default
            let repoDirectory = cache.repoDirectory(repo: hfRepoID, kind: .model)
            paths.append(repoDirectory)
            paths.append(cache.metadataDirectory(repo: hfRepoID, kind: .model))
            paths.append(cache.lockPath(for: repoDirectory))
        }

        var seen = Set<String>()
        return paths.filter { url in
            seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func hasRemovableCache(for repoID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            cacheInspectionQueue.async {
                let hasCache = cachePathsToDelete(for: repoID).contains { cachePath in
                    FileManager.default.fileExists(atPath: cachePath.path)
                }
                continuation.resume(returning: hasCache)
            }
        }
    }

    private static func downloadModelFiles(
        for definition: STTModelDefinition,
        repo: Repo.ID,
        to modelDir: URL,
        updateHandler: (@MainActor @Sendable (ModelLoadUpdate) -> Void)?
    ) async throws {
        let client = HubClient.default
        let entries = try await client.listFiles(
            in: repo,
            kind: .model,
            revision: "main",
            recursive: true
        )
        let files = try entries
            .filter { entry in
                entry.type == .file && matchesDownloadPatterns(
                    path: entry.path,
                    patterns: definition.family.downloadFilePatterns
                )
            }
            .map { entry in
                try ModelDownloadFile(
                    entry: entry,
                    destination: modelFileDestination(for: entry.path, in: modelDir)
                )
            }

        guard !files.isEmpty else {
            throw TranscriptionError.noDownloadableModelFiles(definition.repoID)
        }

        // Remove any previous snapshot manifest before modifying files so an
        // interrupted download cannot be mistaken for a complete snapshot.
        let manifestURL = snapshotManifestURL(in: modelDir)
        try? FileManager.default.removeItem(at: manifestURL)

        let totalBytes = max(files.reduce(Int64(0)) { $0 + $1.weight }, 1)
        let progressThrottle = DownloadProgressThrottle()
        let initialCompleted = files.map { isCompleteLocalFile($0) ? $0.weight : Int64(0) }
        let progressAccumulator = DownloadProgressAccumulator(initialBytes: initialCompleted)
        reportModelDownloadProgress(
            completedBytes: progressAccumulator.totalCompleted(),
            totalBytes: totalBytes,
            throttle: progressThrottle,
            updateHandler: updateHandler
        )

        let bearerToken = await client.bearerToken
        let userAgent = client.userAgent
        let host = client.host
        let pendingIndices = files.indices.filter { !isCompleteLocalFile(files[$0]) }

        if !pendingIndices.isEmpty {
            let downloadSession = SharedModelDownloader()
            defer { downloadSession.finishAndInvalidate() }

            try await withThrowingTaskGroup(of: Void.self) { group in
                var nextPending = 0

                func enqueueNext() {
                    guard nextPending < pendingIndices.count else { return }
                    let fileIndex = pendingIndices[nextPending]
                    nextPending += 1
                    let file = files[fileIndex]

                    group.addTask {
                        try Task.checkCancellation()
                        var request = URLRequest(url: downloadURL(for: file.entry.path, repo: repo, host: host))
                        request.httpMethod = "GET"
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        if let userAgent {
                            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                        }
                        if let bearerToken {
                            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                        }

                        _ = try await downloadSession.download(request: request, to: file.destination) { downloadedBytes, _ in
                            let currentBytes = min(max(downloadedBytes, 0), file.weight)
                            let aggregate = progressAccumulator.update(index: fileIndex, bytes: currentBytes)
                            reportModelDownloadProgress(
                                completedBytes: aggregate,
                                totalBytes: totalBytes,
                                throttle: progressThrottle,
                                updateHandler: updateHandler
                            )
                        }

                        let aggregate = progressAccumulator.update(index: fileIndex, bytes: file.weight)
                        reportModelDownloadProgress(
                            completedBytes: aggregate,
                            totalBytes: totalBytes,
                            throttle: progressThrottle,
                            updateHandler: updateHandler
                        )
                    }
                }

                let initialBatch = min(maxConcurrentDownloads, pendingIndices.count)
                for _ in 0..<initialBatch {
                    enqueueNext()
                }

                do {
                    while try await group.next() != nil {
                        enqueueNext()
                    }
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        // Record the full set of expected files and sizes atomically once all
        // downloads have succeeded so future launches can verify completeness.
        let manifest = LocalSnapshotManifest(
            files: files.map { file in
                LocalSnapshotManifest.FileEntry(
                    path: file.entry.path,
                    size: file.expectedSize ?? localFileSize(at: file.destination)
                )
            }
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
    }

    private static func matchesDownloadPatterns(path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { pattern in
            if pattern.hasPrefix("*") {
                return path.hasSuffix(String(pattern.dropFirst()))
            }
            return path == pattern
        }
    }

    private static func modelFileDestination(for path: String, in modelDir: URL) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"),
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw TranscriptionError.unsafeModelFilePath(path)
        }

        return components.reduce(modelDir) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private static func downloadURL(for path: String, repo: Repo.ID, host: URL) -> URL {
        host
            .appending(path: repo.namespace)
            .appending(path: repo.name)
            .appending(path: "resolve")
            .appending(component: "main")
            .appending(path: path)
    }

    private static func isCompleteLocalFile(_ file: ModelDownloadFile) -> Bool {
        guard let localSize = localFileSize(at: file.destination) else { return false }
        guard let expectedSize = file.expectedSize else { return false }
        return localSize == expectedSize
    }

    private static func localFileSize(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private static func reportModelDownloadProgress(
        completedBytes: Int64,
        totalBytes: Int64,
        throttle: DownloadProgressThrottle,
        updateHandler: (@MainActor @Sendable (ModelLoadUpdate) -> Void)?
    ) {
        let fraction = Double(completedBytes) / Double(max(totalBytes, 1))
        let normalized = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        guard let updateHandler, throttle.shouldReport(normalized) else { return }
        Task { @MainActor in
            updateHandler(.downloading(progress: normalized))
        }
    }

    private static let snapshotManifestFilename = ".whisper-snapshot.json"

    private static func snapshotManifestURL(in modelDir: URL) -> URL {
        modelDir.appendingPathComponent(snapshotManifestFilename)
    }

    private static func hasCompleteModelSnapshot(at modelDir: URL, family: STTModelFamily) async -> Bool {
        await withCheckedContinuation { continuation in
            cacheInspectionQueue.async {
                continuation.resume(returning: hasCompleteModelSnapshotSync(at: modelDir, family: family))
            }
        }
    }

    internal static func hasCompleteModelSnapshotSync(at modelDir: URL, family: STTModelFamily) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelDir.path) else {
            return false
        }

        // If a manifest exists, verify every listed file is present with its expected size.
        let manifestURL = snapshotManifestURL(in: modelDir)
        if fm.fileExists(atPath: manifestURL.path) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(LocalSnapshotManifest.self, from: data),
                  !manifest.files.isEmpty else {
                return false
            }
            for entry in manifest.files {
                guard let fileURL = try? modelFileDestination(for: entry.path, in: modelDir),
                      let actualSize = localFileSize(at: fileURL) else {
                    return false
                }
                if let expectedSize = entry.size {
                    guard actualSize == expectedSize else { return false }
                } else {
                    guard actualSize > 0 else { return false }
                }
            }
        }

        let files = (try? fm.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        let hasWeights = files.contains { file in
            guard file.pathExtension == "safetensors" else { return false }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
        guard hasWeights else { return false }

        // For sharded checkpoints, verify every shard referenced by the index exists and is non-empty.
        let indexURL = modelDir.appendingPathComponent("model.safetensors.index.json")
        if fm.fileExists(atPath: indexURL.path) {
            guard let indexData = try? Data(contentsOf: indexURL),
                  let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
                  let weightMap = indexJSON["weight_map"] as? [String: String] else {
                return false
            }
            let requiredShards = Set(weightMap.values)
            guard !requiredShards.isEmpty else { return false }
            for shardName in requiredShards {
                guard let shardURL = try? modelFileDestination(for: shardName, in: modelDir),
                      let shardSize = localFileSize(at: shardURL),
                      shardSize > 0 else {
                    return false
                }
            }
        }

        let hasAuxiliaryFiles = family.requiredAuxiliaryFiles.allSatisfy { fileName in
            let url = modelDir.appendingPathComponent(fileName)
            guard let size = localFileSize(at: url), size > 0 else { return false }
            return true
        }
        guard hasAuxiliaryFiles else { return false }

        let configPath = modelDir.appendingPathComponent("config.json")
        let hasValidConfig =
            fm.fileExists(atPath: configPath.path)
            && {
                guard let data = try? Data(contentsOf: configPath) else {
                    return false
                }
                return (try? JSONSerialization.jsonObject(with: data)) != nil
            }()

        return hasValidConfig
    }

    /// Transcribe raw audio samples to text.
    /// - Parameter audio: Float32 samples at 16kHz, mono.
    /// - Returns: Transcribed text string.
    func transcribe(audio: [Float]) async throws -> String {
        try Task.checkCancellation()
        try await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        guard let model, let currentFamily else {
            throw TranscriptionError.modelNotLoaded
        }

        guard !audio.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        try Task.checkCancellation()

        let parameters = Self.generationParameters(
            for: currentFamily,
            audioSampleCount: audio.count,
            sampleRate: Double(model.sampleRate)
        )

        let text = await runInference(
            model: model,
            parameters: parameters,
            audio: audio
        )

        try Task.checkCancellation()

        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        return text
    }

    private func invalidateLoadedModel() {
        loadGeneration &+= 1
        warmupTask?.cancel()
        warmupTask = nil
        model = nil
        currentFamily = nil
        currentRepoID = nil
        Memory.clearCache()
    }

    private func acquireOperationTurn() async throws {
        try Task.checkCancellation()
        if !hasActiveOperation {
            hasActiveOperation = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waitingOperations.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaitingOperation(id: waiterID) }
        }
    }

    private func cancelWaitingOperation(id: UUID) {
        guard let index = waitingOperations.firstIndex(where: { $0.id == id }) else { return }
        let removed = waitingOperations.remove(at: index)
        removed.continuation.resume(throwing: CancellationError())
    }

    private func releaseOperationTurn() {
        if waitingOperations.isEmpty {
            hasActiveOperation = false
            return
        }

        let next = waitingOperations.removeFirst()
        next.continuation.resume()
    }

    private func runInference(
        model: any STTGenerationModel,
        parameters: STTGenerateParameters,
        audio: [Float]
    ) async -> String {
        let request = InferenceRequest(model: model, parameters: parameters, audio: audio)

        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
                defer { Memory.clearCache() }
                let mlxAudio = MLXArray(request.audio)
                let output = request.model.generate(
                    audio: mlxAudio,
                    generationParameters: request.parameters
                )
                let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
        }
    }
}

/// Incremental streaming session for Nemotron 3.5 ASR.
/// Resamples incoming microphone chunks and feeds them into `NemotronASRStreamSession`
/// on `TranscriptionService.inferenceQueue` while recording is in progress.
final class LiveTranscriptionSession: @unchecked Sendable {
    /// Step size at 16 kHz (~320 ms) before pushing into the streaming encoder.
    private static let stepSampleThreshold = 5_120

    private let inferenceQueue: DispatchQueue
    private let onReleaseTurn: @Sendable () async -> Void
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var closed = false
        var turnReleased = false
    }

    // Queue-confined state (accessed exclusively on `inferenceQueue`).
    private var streamSession: NemotronASRStreamSession?
    private let resampler = AudioRecorder.StreamingResampler(targetRate: 16_000)
    private var pendingSamples: [Float] = []

    init(
        inferenceQueue: DispatchQueue,
        streamSession: NemotronASRStreamSession,
        onReleaseTurn: @escaping @Sendable () async -> Void
    ) {
        self.inferenceQueue = inferenceQueue
        self.streamSession = streamSession
        self.onReleaseTurn = onReleaseTurn
        self.pendingSamples.reserveCapacity(Self.stepSampleThreshold * 2)
    }

    /// Enqueues a raw mono microphone chunk for resampling and incremental decoding.
    /// Safe to call from the audio tap thread.
    nonisolated func feed(samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        guard !stateLock.withLock({ $0.closed }) else { return }

        inferenceQueue.async { [self] in
            guard !stateLock.withLock({ $0.closed }), let streamSession else { return }

            let converted = resampler.process(samples, sampleRate: sampleRate)
            guard !converted.isEmpty else { return }

            pendingSamples.append(contentsOf: converted)
            if pendingSamples.count >= Self.stepSampleThreshold {
                let batch = pendingSamples
                pendingSamples.removeAll(keepingCapacity: true)
                streamSession.step(batch)
            }
        }
    }

    /// Flushes remaining buffered audio and finishes decoding, returning the final transcript.
    func finish() async throws -> String {
        let alreadyClosed = stateLock.withLock { state -> Bool in
            if state.closed { return true }
            state.closed = true
            return false
        }
        guard !alreadyClosed else {
            throw TranscriptionError.emptyResult
        }

        let text: String = await withCheckedContinuation { continuation in
            inferenceQueue.async { [self] in
                defer {
                    streamSession = nil
                    pendingSamples.removeAll()
                    Memory.clearCache()
                }
                guard let streamSession else {
                    continuation.resume(returning: "")
                    return
                }

                let tail = resampler.flush()
                if !tail.isEmpty {
                    pendingSamples.append(contentsOf: tail)
                }
                if !pendingSamples.isEmpty {
                    streamSession.step(pendingSamples)
                    pendingSamples.removeAll()
                }
                streamSession.finish()
                let decoded = streamSession.text.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: decoded)
            }
        }

        await releaseTurnOnce()

        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return text
    }

    /// Aborts the streaming session and frees carried encoder/decoder caches.
    func cancel() async {
        stateLock.withLock { $0.closed = true }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            inferenceQueue.async { [self] in
                _ = resampler.flush()
                streamSession = nil
                pendingSamples.removeAll()
                Memory.clearCache()
                continuation.resume()
            }
        }

        await releaseTurnOnce()
    }

    private func releaseTurnOnce() async {
        let shouldRelease = stateLock.withLock { state -> Bool in
            if state.turnReleased { return false }
            state.turnReleased = true
            return true
        }
        if shouldRelease {
            await onReleaseTurn()
        }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case emptyResult
    case invalidRepositoryID(String)
    case unsupportedModel(String)
    case noDownloadableModelFiles(String)
    case unsafeModelFilePath(String)
    case modelDownloadFailed(String, Int)

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
        case .unsupportedModel(let repoID):
            return "Unsupported model: \(repoID)"
        case .noDownloadableModelFiles(let repoID):
            return "No downloadable model files found for \(repoID)"
        case .unsafeModelFilePath(let path):
            return "Unsafe model file path: \(path)"
        case .modelDownloadFailed(let path, let statusCode):
            return "Failed to download \(path) (HTTP \(statusCode))"
        }
    }
}

enum ModelLoadUpdate: Sendable {
    case downloading(progress: Double)
    case initializing
}

private struct LocalSnapshotManifest: Codable, Sendable {
    struct FileEntry: Codable, Sendable {
        let path: String
        let size: Int64?
    }

    let files: [FileEntry]
}

private struct ModelDownloadFile: Sendable {
    let entry: Git.TreeEntry
    let destination: URL

    var expectedSize: Int64? {
        entry.effectiveSize.map(Int64.init)
    }

    var weight: Int64 {
        max(expectedSize ?? 1, 1)
    }
}

/// Reuses a single `URLSession` across concurrent file downloads for a model
/// snapshot so HTTP/2 connections and TLS sessions are shared.
private final class SharedModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private final class ActiveDownload {
        let destination: URL
        let progressHandler: @Sendable (Int64, Int64) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        var task: URLSessionDownloadTask?
        var finished = false
        var cancelled = false

        init(destination: URL, progressHandler: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.progressHandler = progressHandler
        }
    }

    private let lock = NSLock()
    private var session: URLSession!
    private var activeDownloads: [Int: ActiveDownload] = [:]

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func finishAndInvalidate() {
        session.finishTasksAndInvalidate()
    }

    func download(
        request: URLRequest,
        to destination: URL,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let entry = ActiveDownload(destination: destination, progressHandler: progressHandler)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if entry.cancelled {
                    entry.finished = true
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let task = session.downloadTask(with: request)
                entry.task = task
                entry.continuation = continuation
                activeDownloads[task.taskIdentifier] = entry
                lock.unlock()

                task.resume()
            }
        } onCancel: {
            lock.lock()
            entry.cancelled = true
            let task = entry.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let handler = activeDownloads[downloadTask.taskIdentifier]?.progressHandler
        lock.unlock()
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard let entry = activeDownloads[downloadTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let destination = entry.destination
        lock.unlock()

        guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
            finish(taskIdentifier: downloadTask.taskIdentifier, result: .failure(
                TranscriptionError.modelDownloadFailed(destination.lastPathComponent, -1)
            ))
            return
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            finish(taskIdentifier: downloadTask.taskIdentifier, result: .failure(
                TranscriptionError.modelDownloadFailed(destination.lastPathComponent, httpResponse.statusCode)
            ))
            return
        }

        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: location)
            } else {
                try fm.moveItem(at: location, to: destination)
            }
            finish(taskIdentifier: downloadTask.taskIdentifier, result: .success(destination))
        } catch {
            finish(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        lock.lock()
        let wasCancelled = activeDownloads[task.taskIdentifier]?.cancelled ?? false
        lock.unlock()

        finish(
            taskIdentifier: task.taskIdentifier,
            result: .failure(wasCancelled ? CancellationError() : error)
        )
    }

    private func finish(taskIdentifier: Int, result: Result<URL, Error>) {
        lock.lock()
        guard let entry = activeDownloads.removeValue(forKey: taskIdentifier), !entry.finished else {
            lock.unlock()
            return
        }
        entry.finished = true
        let continuation = entry.continuation
        entry.continuation = nil
        entry.task = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}

/// Thread-safe byte counter across concurrent file downloads.
private final class DownloadProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesByIndex: [Int64]
    private var total: Int64

    init(initialBytes: [Int64]) {
        self.bytesByIndex = initialBytes
        self.total = initialBytes.reduce(0, +)
    }

    func totalCompleted() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    func update(index: Int, bytes: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard bytesByIndex.indices.contains(index) else { return total }
        total += bytes - bytesByIndex[index]
        bytesByIndex[index] = bytes
        return total
    }
}

/// Rate-limits byte progress callbacks so a multi-gigabyte download does not
/// spawn thousands of main-actor UI updates.
private final class DownloadProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported: Double = -1

    /// Whether `fraction` is worth forwarding to the UI: completion, or a
    /// change of at least one percentage point since the last report.
    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard fraction != lastReported else { return false }
        guard fraction >= 1 || abs(fraction - lastReported) >= 0.01 else { return false }

        lastReported = fraction
        return true
    }
}
