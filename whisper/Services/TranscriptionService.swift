import Foundation
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
    private var model: (any STTGenerationModel)?
    private var generationParameters: STTGenerateParameters?
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
        let model: any STTGenerationModel
        let parameters: STTGenerateParameters
        let audio: [Float]
    }

    /// Whether a model is currently loaded and ready.
    var isLoaded: Bool { model != nil }

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
        await acquireOperationTurn()
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
        await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        guard let definition = STTModelDefinition.find(repoID: repoID) else {
            throw TranscriptionError.unsupportedModel(repoID)
        }

        // Skip if already loaded with same model
        if currentRepoID == repoID && model != nil {
            return
        }

        // Unload previous model
        invalidateLoadedModel()
        let generation = loadGeneration

        try Task.checkCancellation()

        try await Self.ensureModelSnapshot(for: definition, updateHandler: updateHandler)

        try Task.checkCancellation()

        await updateHandler?(.initializing)

        let loaded = try await Self.loadPretrainedModel(for: definition)

        try Task.checkCancellation()
        guard generation == loadGeneration else {
            throw CancellationError()
        }

        model = loaded
        generationParameters = Self.generationParameters(for: definition.family)
        currentRepoID = repoID
    }

    private static func loadPretrainedModel(
        for definition: STTModelDefinition
    ) async throws -> any STTGenerationModel {
        switch definition.family {
        case .qwen3:
            return try await Qwen3ASRModel.fromPretrained(definition.repoID)
        case .nemotron:
            return try await NemotronASRModel.fromPretrained(definition.repoID)
        case .parakeet:
            return try await ParakeetModel.fromPretrained(definition.repoID)
        }
    }

    private static func generationParameters(for family: STTModelFamily) -> STTGenerateParameters {
        switch family {
        case .qwen3:
            return STTGenerateParameters(language: "English")
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

        let totalBytes = max(files.reduce(Int64(0)) { $0 + $1.weight }, 1)
        let progressThrottle = DownloadProgressThrottle()
        var completedBytes = files.reduce(Int64(0)) { partial, file in
            partial + (isCompleteLocalFile(file) ? file.weight : 0)
        }
        reportModelDownloadProgress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            throttle: progressThrottle,
            updateHandler: updateHandler
        )

        let bearerToken = await client.bearerToken

        for file in files where !isCompleteLocalFile(file) {
            try Task.checkCancellation()
            let completedBeforeFile = completedBytes
            var request = URLRequest(url: downloadURL(for: file.entry.path, repo: repo, host: client.host))
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let userAgent = client.userAgent {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            if let bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }

            try await ModelFileDownloader.download(request: request, to: file.destination) { downloadedBytes, _ in
                let currentBytes = min(max(downloadedBytes, 0), file.weight)
                reportModelDownloadProgress(
                    completedBytes: completedBeforeFile + currentBytes,
                    totalBytes: totalBytes,
                    throttle: progressThrottle,
                    updateHandler: updateHandler
                )
            }

            completedBytes += file.weight
            reportModelDownloadProgress(
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                throttle: progressThrottle,
                updateHandler: updateHandler
            )
        }
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

    private static func hasCompleteModelSnapshot(at modelDir: URL, family: STTModelFamily) async -> Bool {
        await withCheckedContinuation { continuation in
            cacheInspectionQueue.async {
                continuation.resume(returning: hasCompleteModelSnapshotSync(at: modelDir, family: family))
            }
        }
    }

    private static func hasCompleteModelSnapshotSync(at modelDir: URL, family: STTModelFamily) -> Bool {
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            return false
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: nil
        )) ?? []

        let hasWeights = files.contains { $0.pathExtension == "safetensors" }
        let hasAuxiliaryFiles = family.requiredAuxiliaryFiles.allSatisfy { fileName in
            FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent(fileName).path
            )
        }
        let configPath = modelDir.appendingPathComponent("config.json")
        let hasValidConfig =
            FileManager.default.fileExists(atPath: configPath.path)
            && {
                guard let data = try? Data(contentsOf: configPath) else {
                    return false
                }
                return (try? JSONSerialization.jsonObject(with: data)) != nil
            }()

        return hasWeights && hasAuxiliaryFiles && hasValidConfig
    }

    /// Transcribe raw audio samples to text.
    /// - Parameter audio: Float32 samples at 16kHz, mono.
    /// - Returns: Transcribed text string.
    func transcribe(audio: [Float]) async throws -> String {
        try Task.checkCancellation()
        await acquireOperationTurn()
        defer { releaseOperationTurn() }
        try Task.checkCancellation()

        guard let model, let generationParameters else {
            throw TranscriptionError.modelNotLoaded
        }

        guard !audio.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        try Task.checkCancellation()

        let text = await runInference(
            model: model,
            parameters: generationParameters,
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
        model = nil
        generationParameters = nil
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

    private func runInference(
        model: any STTGenerationModel,
        parameters: STTGenerateParameters,
        audio: [Float]
    ) async -> String {
        let request = InferenceRequest(model: model, parameters: parameters, audio: audio)

        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
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

private struct ModelDownloadFile: Sendable {
    let entry: Git.TreeEntry
    let destination: URL

    var expectedSize: Int64? {
        entry.size.map(Int64.init)
    }

    var weight: Int64 {
        max(expectedSize ?? 1, 1)
    }
}

private final class ModelFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progressHandler: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var finished = false
    private var cancelled = false

    private init(
        destination: URL,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.destination = destination
        self.progressHandler = progressHandler
    }

    static func download(
        request: URLRequest,
        to destination: URL,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let downloader = ModelFileDownloader(
            destination: destination,
            progressHandler: progressHandler
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.start(request: request, continuation: continuation)
            }
        } onCancel: {
            downloader.cancel()
        }
    }

    private func start(request: URLRequest, continuation: CheckedContinuation<URL, Error>) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)

        lock.lock()
        self.session = session
        self.task = task
        self.continuation = continuation
        lock.unlock()

        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()

        task?.cancel()
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let httpResponse = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(TranscriptionError.modelDownloadFailed(destination.lastPathComponent, -1)))
            return
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            finish(.failure(TranscriptionError.modelDownloadFailed(destination.lastPathComponent, httpResponse.statusCode)))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()

        finish(.failure(wasCancelled ? CancellationError() : error))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        let session = session
        self.continuation = nil
        self.session = nil
        task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
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
