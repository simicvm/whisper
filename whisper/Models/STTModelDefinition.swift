import Foundation

/// Model families supported by the transcription engine. The family decides
/// which MLXAudioSTT class loads the checkpoint and which repository files
/// make up a complete local snapshot.
enum STTModelFamily {
    case qwen3
    case nemotron

    /// Glob patterns passed to the HuggingFace snapshot download.
    var downloadFilePatterns: [String] {
        switch self {
        case .qwen3:
            return ["*.safetensors", "*.json", "merges.txt"]
        case .nemotron:
            // The vocabulary and prompt tables are embedded in config.json;
            // there is no separate tokenizer artifact to fetch.
            return ["*.safetensors", "*.json"]
        }
    }

    /// Files, beyond weights and config.json, that must exist locally for a
    /// snapshot to count as downloaded.
    var requiredAuxiliaryFiles: [String] {
        switch self {
        case .qwen3:
            return ["merges.txt"]
        case .nemotron:
            return []
        }
    }
}

/// Available speech-to-text model variants.
struct STTModelDefinition: Identifiable, Hashable {
    let id: String
    let displayName: String
    let repoID: String
    let family: STTModelFamily

    static let allModels: [STTModelDefinition] = [
        STTModelDefinition(
            id: "qwen3-0.6b-8bit",
            displayName: "Qwen3 ASR 0.6B (8-bit)",
            repoID: "mlx-community/Qwen3-ASR-0.6B-8bit",
            family: .qwen3
        ),
        STTModelDefinition(
            id: "qwen3-1.7b-8bit",
            displayName: "Qwen3 ASR 1.7B (8-bit)",
            repoID: "mlx-community/Qwen3-ASR-1.7B-8bit",
            family: .qwen3
        ),
        STTModelDefinition(
            id: "qwen3-1.7b-4bit",
            displayName: "Qwen3 ASR 1.7B (4-bit)",
            repoID: "mlx-community/Qwen3-ASR-1.7B-4bit",
            family: .qwen3
        ),
        STTModelDefinition(
            id: "nemotron-3.5-0.6b-8bit",
            displayName: "Nemotron 3.5 ASR 0.6B (8-bit)",
            repoID: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
            family: .nemotron
        ),
    ]

    static let `default` = allModels[0]

    static func find(repoID: String) -> STTModelDefinition? {
        allModels.first { $0.repoID == repoID }
    }
}
