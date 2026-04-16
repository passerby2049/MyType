// Abstract:
// Background pre-warming of STT models and LLM sessions so the first
// voice input doesn't pay the cold-start penalty.

import FluidAudio
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

extension VoiceInputManager {

    // MARK: - Prewarm

    /// Load the STT model and seed the LLM session in the background.
    /// Runs at app launch so the first voice input is fast.
    func prewarm() async {
        let start = Date()

        // 1. Pre-warm STT engine
        await prewarmSTT()

        // 2. Pre-warm Claude Code session (if configured)
        await prewarmLLMSession()

        let elapsed = Date().timeIntervalSince(start)
        logger.info("Pre-warm complete in \(String(format: "%.1f", elapsed))s")
    }

    @available(macOS 15, *)
    func prewarmQwen3() async {
        let choice = VoiceInputEngineChoice.current
        guard choice == .qwen3Int8 || choice == .qwen3F32 else { return }
        let variant: Qwen3AsrVariant = (choice == .qwen3F32) ? .f32 : .int8
        do {
            let modelsURL = try await Qwen3AsrModels.download(variant: variant)
            let m = Qwen3AsrManager()
            try await m.loadModels(from: modelsURL)
            qwen3Manager = m
            qwen3LoadedVariant = choice
            logger.info("Pre-warmed Qwen3-ASR (\(choice.rawValue))")
        } catch {
            logger.warning("Qwen3 pre-warm failed: \(error.localizedDescription)")
        }
    }

    func prewarmSTT() async {
        let choice = VoiceInputEngineChoice.current
        switch choice {
        case .qwen3Int8, .qwen3F32:
            if #available(macOS 15, *) {
                await prewarmQwen3()
            }
        case .parakeetV2, .parakeetV3:
            await prewarmParakeet()
        case .appleSpeech:
            break // No model to load
        }
    }

    private func prewarmParakeet() async {
        let choice = VoiceInputEngineChoice.current
        let version: AsrModelVersion = (choice == .parakeetV2) ? .v2 : .v3
        do {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            parakeetManager = m
            parakeetLoadedVariant = choice
            logger.info("Pre-warmed Parakeet (\(choice.rawValue))")
        } catch {
            logger.warning("Parakeet pre-warm failed: \(error.localizedDescription)")
        }
    }

    func prewarmLLMSession() async {
        // Read MainActor-isolated settings on the main actor.
        let (enabled, model, seed) = await MainActor.run {
            (
                LLMRewriter.isEnabled,
                LLMRewriter.resolvedModel,
                LLMRewriter.buildSeedPromptForPrewarm()
            )
        }
        guard enabled, AIProvider.provider(for: model) == .claudeCode else { return }

        // Spawn + seed the session so the first real polish call is fast.
        do {
            _ = try await ClaudeCodeVoicePolishSession.shared.polish(
                text: "test",
                seedPrompt: seed,
                model: model
            )
            logger.info("Pre-warmed Claude Code session (model=\(model))")
        } catch {
            logger.warning("Claude session pre-warm failed: \(error.localizedDescription)")
        }
    }
}
