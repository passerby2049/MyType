// Abstract:
// STT engine dispatch — Qwen3-ASR, Parakeet, and Apple Speech backends.

import AVFoundation
import FluidAudio
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

extension VoiceInputManager {

    // MARK: - Transcription

    func transcribeAudio(at url: URL) async throws -> String {
        let choice = VoiceInputEngineChoice.current
        let language = VoiceInputLanguage.current

        switch choice {
        case .qwen3Int8, .qwen3F32:
            if #available(macOS 15, *) {
                return try await transcribeWithQwen3(
                    at: url,
                    variantChoice: choice,
                    language: language
                )
            } else {
                // Qwen3 requires macOS 15+ — silently fall back.
                return try await transcribeWithAppleSpeech(at: url, language: language)
            }
        case .parakeetV2, .parakeetV3:
            return try await transcribeWithParakeet(at: url, variantChoice: choice)
        case .appleSpeech:
            return try await transcribeWithAppleSpeech(at: url, language: language)
        }
    }

    @available(macOS 15, *)
    func transcribeWithQwen3(
        at url: URL,
        variantChoice: VoiceInputEngineChoice,
        language: VoiceInputLanguage
    ) async throws -> String {
        let sdkVariant: Qwen3AsrVariant = (variantChoice == .qwen3F32) ? .f32 : .int8


        // Reuse the cached manager if it's already loaded the requested
        // variant; otherwise load fresh.
        let manager: Qwen3AsrManager
        if let existing = qwen3Manager, qwen3LoadedVariant == variantChoice {
            manager = existing
        } else {
            let modelsURL = try await Qwen3AsrModels.download(variant: sdkVariant)
            let m = Qwen3AsrManager()
            try await m.loadModels(from: modelsURL)
            qwen3Manager = m
            qwen3LoadedVariant = variantChoice
            manager = m
        }

        // Convert m4a (44.1kHz AAC) to the 16kHz mono Float32 samples
        // Qwen3 expects.
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)

        // Hint the model with the user's selected language. Qwen3 still
        // handles code-switching correctly with either hint, but the
        // hint nudges ambiguous short utterances in the right direction.
        let text = try await manager.transcribe(
            audioSamples: samples,
            language: language.qwen3Hint
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribe with Parakeet TDT (v2 = English only, v3 = 25 EU
    /// languages). No Chinese support — the settings UI only exposes
    /// these engines when language == english, so we don't branch on
    /// language here.
    func transcribeWithParakeet(
        at url: URL,
        variantChoice: VoiceInputEngineChoice
    ) async throws -> String {
        let version: AsrModelVersion = (variantChoice == .parakeetV2) ? .v2 : .v3


        let manager: AsrManager
        if let existing = parakeetManager, parakeetLoadedVariant == variantChoice {
            manager = existing
        } else {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            parakeetManager = m
            parakeetLoadedVariant = variantChoice
            manager = m
        }

        // Resample to 16kHz mono Float32 — same format Qwen3 uses.
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)

        let result = try await manager.transcribe(samples)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fallback: transcribe with Apple Speech using the selected
    /// language's locale.
    func transcribeWithAppleSpeech(
        at url: URL,
        language: VoiceInputLanguage
    ) async throws -> String {
        let engine = AppleSpeechEngine()
        let locale = Locale(identifier: language.localeIdentifier)

        try await engine.prepare(locale: locale, progressHandler: nil)

        var fullText = ""
        let stream = engine.transcribe(
            audioFileURL: url,
            locale: locale
        )

        for try await segment in stream where segment.isFinal {
            let text = String(segment.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if !fullText.isEmpty { fullText += " " }
                fullText += text
            }
        }

        return fullText
    }
}
