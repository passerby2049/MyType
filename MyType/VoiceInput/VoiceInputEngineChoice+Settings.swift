// Abstract:
// Settings-only display metadata and model-cache helpers for engines.

import FluidAudio
import Foundation

extension VoiceInputEngineChoice {
    var shortName: String {
        switch self {
        case .qwen3Int8: "Qwen3-ASR (int8)"
        case .qwen3F32: "Qwen3-ASR (f32)"
        case .parakeetV3: "Parakeet TDT v3"
        case .parakeetV2: "Parakeet TDT v2"
        case .appleSpeech: "Apple Speech"
        }
    }

    var detailLabel: String {
        switch self {
        case .qwen3Int8: "Recommended - Chinese + EN - ~900MB download"
        case .qwen3F32: "Faster - Chinese + EN - ~1.75GB download"
        case .parakeetV3: "Multilingual (25 EU langs) - ~500MB download"
        case .parakeetV2: "English only - highest EN accuracy - ~500MB download"
        case .appleSpeech: "Built-in - offline - no download"
        }
    }

    var iconName: String {
        switch self {
        case .qwen3Int8, .qwen3F32: "cpu"
        case .parakeetV3: "globe"
        case .parakeetV2: "bolt.fill"
        case .appleSpeech: "apple.logo"
        }
    }

    var requiresDownload: Bool {
        switch self {
        case .qwen3Int8, .qwen3F32, .parakeetV2, .parakeetV3: true
        case .appleSpeech: false
        }
    }

    var cacheDirectory: URL? {
        switch self {
        case .qwen3Int8: Qwen3AsrModels.defaultCacheDirectory(variant: .int8)
        case .qwen3F32: Qwen3AsrModels.defaultCacheDirectory(variant: .f32)
        case .parakeetV3: AsrModels.defaultCacheDirectory(for: .v3)
        case .parakeetV2: AsrModels.defaultCacheDirectory(for: .v2)
        case .appleSpeech: nil
        }
    }

    var modelsPresentOnDisk: Bool {
        switch self {
        case .appleSpeech:
            true
        case .qwen3Int8:
            Qwen3AsrModels.modelsExist(
                at: Qwen3AsrModels.defaultCacheDirectory(variant: .int8)
            )
        case .qwen3F32:
            Qwen3AsrModels.modelsExist(
                at: Qwen3AsrModels.defaultCacheDirectory(variant: .f32)
            )
        case .parakeetV3:
            AsrModels.modelsExist(
                at: AsrModels.defaultCacheDirectory(for: .v3),
                version: .v3
            )
        case .parakeetV2:
            AsrModels.modelsExist(
                at: AsrModels.defaultCacheDirectory(for: .v2),
                version: .v2
            )
        }
    }
}
