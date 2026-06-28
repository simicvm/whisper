import Foundation

/// Model families supported by the transcription engine. The family decides
/// which MLXAudioSTT class loads the checkpoint and which repository files
/// make up a complete local snapshot.
enum STTModelFamily {
    case qwen3
    case nemotron
    case parakeet

    /// Hugging Face repository file patterns needed for local model loading.
    var downloadFilePatterns: [String] {
        ["*.safetensors", "*.json", "*.txt", "*.wav"]
    }

    /// Files, beyond weights and config.json, that must exist locally for a
    /// snapshot to count as downloaded.
    var requiredAuxiliaryFiles: [String] {
        switch self {
        case .qwen3:
            return ["merges.txt"]
        case .nemotron:
            return []
        case .parakeet:
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
        STTModelDefinition(
            id: "parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2",
            repoID: "mlx-community/parakeet-tdt-0.6b-v2",
            family: .parakeet
        ),
        STTModelDefinition(
            id: "parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3 (multilingual)",
            repoID: "mlx-community/parakeet-tdt-0.6b-v3",
            family: .parakeet
        ),
    ]

    static let `default` = allModels[0]

    static func find(repoID: String) -> STTModelDefinition? {
        allModels.first { $0.repoID == repoID }
    }
}
