// Abstract:
// Settings-only display metadata and model-cache helpers for engines.

import AudioCommon
import Foundation

extension VoiceInputEngineChoice {
    var shortName: String {
        switch self {
        case .qwen3Large: "Qwen3-ASR 1.7B"
        case .qwen3Small: "Qwen3-ASR 0.6B"
        case .appleSpeech: "Apple Speech"
        }
    }

    var detailLabel: String {
        switch self {
        case .qwen3Large: "Recommended - 中文 + English + 日本語 - ~2.3GB download"
        case .qwen3Small: "Smaller, less accurate - ~0.9GB download"
        case .appleSpeech: "Built-in - offline - one language at a time"
        }
    }

    var iconName: String {
        switch self {
        case .qwen3Large: "cpu"
        case .qwen3Small: "cpu.fill"
        case .appleSpeech: "apple.logo"
        }
    }

    var requiresDownload: Bool { modelID != nil }

    /// Where speech-swift keeps the model (~/Library/Caches/qwen3-speech/…).
    var cacheDirectory: URL? {
        modelID.flatMap { try? HuggingFaceDownloader.getCacheDirectory(for: $0) }
    }

    var modelsPresentOnDisk: Bool {
        guard let dir = cacheDirectory else { return true }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") }
    }
}
