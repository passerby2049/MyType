// Abstract:
// STT engine dispatch — Qwen3-ASR (speech-swift, MLX) and Apple Speech.

import AVFoundation
import AudioCommon
import Foundation
import MLX
import Qwen3ASR
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
        case .qwen3Large, .qwen3Small:
            return try await transcribeWithQwen3(at: url, engine: choice, language: language)
        case .appleSpeech:
            return try await transcribeWithAppleSpeech(at: url, language: language)
        }
    }

    /// The loaded model for `engine`, loading (and on first use downloading)
    /// it if needed.
    func qwen3Model(for engine: VoiceInputEngineChoice) async throws -> Qwen3ASRModel {
        if let model = qwen3Model, qwen3LoadedEngine == engine { return model }
        guard let modelID = engine.modelID else { throw TranscriptionError.couldNotDownloadModel }
        qwen3Model = nil
        // Download and weight loading off the main thread (~2 GB for 1.7B).
        let model = try await Task.detached(priority: .userInitiated) {
            try await Qwen3ASRModel.fromPretrained(modelId: modelID)
        }.value
        qwen3Model = model
        qwen3LoadedEngine = engine
        return model
    }

    /// Transcribe with Qwen3-ASR. The vocabulary goes in as context: the
    /// model leans toward those spellings while it listens (measured:
    /// mixed-in terms 18/28 → 28/28, docs/eval-2026-10-09.md).
    func transcribeWithQwen3(
        at url: URL,
        engine: VoiceInputEngineChoice,
        language: VoiceInputLanguage
    ) async throws -> String {
        let model = try await qwen3Model(for: engine)
        let options = Qwen3DecodingOptions(language: language.qwen3Hint, context: Self.recognitionContext())
        let (text, audioSeconds, loadSeconds) = try await Task.detached(priority: .userInitiated) {
            // MLX keeps the decode's scratch buffers for reuse, up to Qwen3ASR's 4 GB cap: 1–2.5 GB on top of the
            // ~1.8 GB of weights for as long as the app runs. Emptying it after each run costs nothing measurable
            // (40 recordings: median 0.548 → 0.550 s, same text; eval/asr-bench mem-bench).
            defer { Memory.clearCache() }
            let loadStart = Date()
            let samples = try AudioFileLoader.load(url: url, targetSampleRate: 16000)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            let text = try model.transcribeCheckingCancellation(audio: samples, sampleRate: 16000, options: options)
            return (text, Double(samples.count) / 16000, loadSeconds)
        }.value
        // Capture gap: how much of the time the user held the key isn't in
        // the file — a slow microphone start eats the first words.
        let gapMs = Int((recordingDuration - audioSeconds) * 1000)
        let line = "Audio \(String(format: "%.2f", audioSeconds)) s of \(String(format: "%.2f", recordingDuration)) s held (gap \(gapMs) ms), decode+resample \(Int(loadSeconds * 1000)) ms"
        if gapMs >= 350 { logger.warning("\(line, privacy: .public)") } else { logger.info("\(line, privacy: .public)") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The vocabulary as Qwen3-ASR's context: a short list works best (a
    /// long one is slower and no more accurate).
    static func recognitionContext() -> String? {
        let terms = VocabularyStore.shared.enabledTerms.map(\.term).prefix(60)
        return terms.isEmpty ? nil : "Vocabulary: " + terms.joined(separator: ", ")
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
