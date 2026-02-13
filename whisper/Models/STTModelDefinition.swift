import Foundation

/// Available Qwen3 ASR model variants.
struct STTModelDefinition: Identifiable, Hashable {
    let id: String
    let displayName: String
    let repoID: String

    static let allModels: [STTModelDefinition] = [
        STTModelDefinition(
            id: "qwen3-0.6b-8bit",
            displayName: "Qwen3 ASR 0.6B (8-bit)",
            repoID: "mlx-community/Qwen3-ASR-0.6B-8bit"
        ),
        STTModelDefinition(
            id: "qwen3-1.7b-8bit",
            displayName: "Qwen3 ASR 1.7B (8-bit)",
            repoID: "mlx-community/Qwen3-ASR-1.7B-8bit"
        ),
        STTModelDefinition(
            id: "qwen3-1.7b-4bit",
            displayName: "Qwen3 ASR 1.7B (4-bit)",
            repoID: "mlx-community/Qwen3-ASR-1.7B-4bit"
        ),
    ]

    static let `default` = allModels[0]
}
