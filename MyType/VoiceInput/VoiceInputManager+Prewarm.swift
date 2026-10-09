// Abstract:
// Background pre-warming of STT models and LLM sessions so the first
// voice input doesn't pay the cold-start penalty.

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

extension VoiceInputManager {

    // MARK: - Prewarm

    /// Load the STT model and warm the LLM session in the background.
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

    func prewarmSTT() async {
        let choice = VoiceInputEngineChoice.current
        logger.notice("Pre-warm STT: \(choice.rawValue, privacy: .public)")
        guard choice.modelID != nil else { return } // Apple Speech: nothing to load
        do {
            _ = try await qwen3Model(for: choice)
            logger.info("Pre-warmed \(choice.shortName, privacy: .public)")
        } catch {
            logger.warning("Qwen3 pre-warm failed: \(error.localizedDescription)")
        }
    }

    func prewarmLLMSession() async {
        // Read MainActor-isolated settings on the main actor.
        let (enabled, model, systemPrompt) = await MainActor.run {
            (
                LLMRewriter.isEnabled,
                LLMRewriter.resolvedModel,
                LLMRewriter.buildSystemPromptForPrewarm()
            )
        }
        guard enabled, AIProvider.provider(for: model) == .claudeCode else { return }

        // Spawn the session and send one turn so the first real polish call is fast.
        do {
            _ = try await ClaudeCodeVoicePolishSession.shared.polish(
                text: LLMRewriter.sessionMessage(text: "test", frontApp: nil),
                systemPrompt: systemPrompt,
                model: model
            )
            logger.info("Pre-warmed Claude Code session (model=\(model))")
        } catch {
            logger.warning("Claude session pre-warm failed: \(error.localizedDescription)")
        }
    }
}
