// Abstract:
// FluidAudio transcription engine -- uses Parakeet TDT v3/v2
// via FluidAudio SDK for high-speed on-device speech
// recognition on Apple Silicon.

import AVFoundation
import FluidAudio
import Foundation

// MARK: - Parakeet Model Variant

enum ParakeetModelVariant: String {
    case v3 = "parakeet-tdt-v3"
    case v2 = "parakeet-tdt-v2"

    var displayName: String {
        switch self {
        case .v3: return "Parakeet TDT v3 (Multilingual)"
        case .v2: return "Parakeet TDT v2 (English Only)"
        }
    }

    var asrVersion: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .v2: return .v2
        }
    }
}

// MARK: - FluidAudio Engine

final class FluidAudioEngine: TranscriptionEngine {
    let modelVariant: ParakeetModelVariant

    var displayName: String { modelVariant.displayName }
    var id: String { modelVariant.rawValue }

    var isAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private var asrManager: AsrManager?

    init(modelVariant: ParakeetModelVariant = .v3) {
        self.modelVariant = modelVariant
    }

    func prepare(
        locale: Locale,
        progressHandler: ((Double) -> Void)?
    ) async throws {
        guard isAvailable else {
            throw TranscriptionError
                .failedToSetupRecognitionStream
        }

        progressHandler?(0.05)

        // Download and load CoreML models from HuggingFace
        // (cached after first download). Pass through download
        // progress from FluidAudio SDK (0.05 -> 0.85 range).
        let models = try await AsrModels.downloadAndLoad(
            version: modelVariant.asrVersion
        ) { downloadProgress in
            let mapped = 0.05
                + downloadProgress.fractionCompleted * 0.80
            progressHandler?(min(mapped, 0.85))
        }
        progressHandler?(0.90)

        // Initialize the ASR manager and load models
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        progressHandler?(1.0)
    }

    func transcribe(
        audioFileURL url: URL,
        locale: Locale
    ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if self.asrManager == nil {
                        try await self.prepare(
                            locale: locale,
                            progressHandler: nil
                        )
                    }
                    guard let manager = self.asrManager else {
                        continuation.finish(
                            throwing: TranscriptionError
                                .failedToSetupRecognitionStream
                        )
                        return
                    }

                    let audioURL = url

                    // Transcribe the file using FluidAudio
                    let result = try await manager
                        .transcribe(audioURL)
                    let text = result.text
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )

                    guard !text.isEmpty else {
                        continuation.finish()
                        return
                    }

                    // Emit the whole transcription as a single
                    // final segment — MyType doesn't need
                    // subtitle-level splitting.
                    let rawTimings: [RawTokenTiming] = (
                        result.tokenTimings ?? []
                    ).map {
                        RawTokenTiming(
                            token: $0.token,
                            startTime: $0.startTime,
                            endTime: $0.endTime
                        )
                    }
                    continuation.yield(
                        TranscriptionSegment(
                            text: AttributedString(text),
                            isFinal: true,
                            rawTokenTimings: rawTimings
                        )
                    )

                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: error
                    )
                }
            }
        }
    }

}
