import Foundation

/// Model families supported by the transcription engine. The family decides
/// which inference backend loads the checkpoint and which repository files
/// make up a complete local snapshot.
enum STTModelFamily {
    case qwen3
    case nemotron
    case parakeet
    case fluidSpeechCoreML

    /// Hugging Face repository file patterns needed for local model loading.
    /// Supports leading `*` suffix matches, trailing `*` prefix matches, and exact paths.
    nonisolated var downloadFilePatterns: [String] {
        switch self {
        case .qwen3, .nemotron, .parakeet:
            return ["*.safetensors", "*.json", "*.txt", "*.wav"]
        case .fluidSpeechCoreML:
            return [
                "Preprocessor.mlmodelc/*",
                "Encoder.mlmodelc/*",
                "Decoder.mlmodelc/*",
                "JointDecision.mlmodelc/*",
                "config.json",
                "parakeet_vocab.json",
                "parakeet_v3_vocab.json",
            ]
        }
    }

    /// Files, beyond weights and config.json, that must exist locally for a
    /// snapshot to count as downloaded.
    nonisolated var requiredAuxiliaryFiles: [String] {
        switch self {
        case .qwen3:
            return ["vocab.json", "merges.txt", "tokenizer_config.json"]
        case .nemotron, .parakeet:
            return []
        case .fluidSpeechCoreML:
            return [
                "Preprocessor.mlmodelc/model.mil",
                "Preprocessor.mlmodelc/weights/weight.bin",
                "Encoder.mlmodelc/model.mil",
                "Encoder.mlmodelc/weights/weight.bin",
                "Decoder.mlmodelc/model.mil",
                "Decoder.mlmodelc/weights/weight.bin",
                "JointDecision.mlmodelc/model.mil",
                "JointDecision.mlmodelc/weights/weight.bin",
                "parakeet_vocab.json",
            ]
        }
    }

    nonisolated var usesSafetensorsWeights: Bool {
        switch self {
        case .qwen3, .nemotron, .parakeet:
            return true
        case .fluidSpeechCoreML:
            return false
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
            displayName: "Parakeet TDT 0.6B v3",
            repoID: "mlx-community/parakeet-tdt-0.6b-v3",
            family: .parakeet
        ),
        STTModelDefinition(
            id: "fluid-speech-pro-coreml",
            displayName: "Fluid Speech Pro (Core ML)",
            repoID: "FluidVoice-Labs/fluid-speech-pro-coreml",
            family: .fluidSpeechCoreML
        ),
    ]

    static let `default` = allModels[0]

    static func find(repoID: String) -> STTModelDefinition? {
        allModels.first { $0.repoID == repoID }
    }
}
