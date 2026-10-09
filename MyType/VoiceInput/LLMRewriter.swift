// Abstract:
// Strict post-processor that asks the configured LLM to fix obvious
// speech recognition errors (Chinese homophones, English tech terms
// transcribed as Chinese phonetics, word-boundary mistakes) without
// rewriting the user's original wording or tone.

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "LLMRewriter"
)

enum LLMRewriter {

    // MARK: - UserDefaults Keys

    static let useLLMKey = "voiceInputUseLLM"
    /// Persisted model selection. Empty string means "never configured"
    /// and falls back to `defaultModel`.
    static let modelKey = "voiceInputLLMModel"
    /// Legacy boolean that toggled "light polish" before mode was a
    /// tri-state. Kept so old preferences migrate correctly on first launch.
    static let lightPolishKey = "voiceInputLightPolish"
    /// Polish mode — `"strict"` / `"light"` / `"medium"`.
    static let polishModeKey = "voiceInputPolishMode"
    /// Claude Code CLI effort level: low/medium/high.
    /// Lower = faster (less thinking), higher = better for complex fixes.
    static let effortKey = "voiceInputEffort"
    static let defaultEffort = "low"

    enum PolishMode: String {
        /// Recognition-error fixes only — no rephrasing, no filler removal.
        case strict
        /// + drop fillers + lightly smooth awkward phrasing. Meaning intact.
        case light
        /// + grammar / naturalness correction for English-as-second-language
        /// practice. Still meaning-preserving, no paraphrasing.
        case medium

        var displayName: String {
            switch self {
            case .strict: return "Strict"
            case .light:  return "Light"
            case .medium: return "Medium"
            }
        }
    }

    /// Resolved polish mode. Reads `polishModeKey`, falling back to the
    /// legacy `lightPolishKey` boolean for users upgrading from older
    /// builds (true → light, false → strict).
    static var polishMode: PolishMode {
        if let raw = UserDefaults.standard.string(forKey: polishModeKey),
           let mode = PolishMode(rawValue: raw) {
            return mode
        }
        return UserDefaults.standard.bool(forKey: lightPolishKey) ? .light : .strict
    }

    /// Back-compat shim used by surfaces that haven't been updated yet.
    static var lightPolishEnabled: Bool { polishMode != .strict }

    static var resolvedEffort: String {
        let v = UserDefaults.standard.string(forKey: effortKey) ?? ""
        return v.isEmpty ? defaultEffort : v
    }
    /// Default when the user hasn't picked a model yet. Fast + cheap is
    /// the right shape for STT post-correction.
    static let defaultModel = "cc-sonnet"

    /// Resolve the model the user configured for voice-input post-processing.
    static var resolvedModel: String {
        let voiceModel = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return voiceModel.isEmpty ? defaultModel : voiceModel
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: useLLMKey)
    }

    // MARK: - Rewrite

    /// Stream-collect the LLM's correction of the given STT output.
    ///
    /// Guardrails:
    /// - Empty / whitespace-only LLM output → return the original.
    /// - LLM output more than 3× the input length → likely a
    ///   hallucination or instruction-leakage; return the original.
    /// - Any thrown error (network, auth, model not available) is
    ///   propagated to the caller, which decides whether to fall back.
    ///
    /// Cost optimization: a fast-path heuristic skips the LLM entirely
    /// for inputs that almost certainly don't need correction (very
    /// short inputs, short pure-ASCII English). This cuts ~30% of
    /// calls in typical mixed-language usage.
    static func rewrite(
        rawText: String,
        language: VoiceInputLanguage,
        model: String,
        vocabularyTerms: [String] = [],
        frontApp: String? = nil
    ) async throws -> String {
        if let skipReason = shouldSkipReason(for: rawText, mode: polishMode) {
            logger.info("🤖 LLM skipped (\(skipReason, privacy: .public)) — input \(rawText.count) chars")
            return rawText
        }

        // Claude Code CLI models reuse a warm session for voice polish
        // (the rules are its cached system prompt; one transcript per turn).
        // All other providers still use the one-shot streaming path.
        if AIProvider.provider(for: model) == .claudeCode {
            return try await rewriteViaClaudeCodeSession(
                rawText: rawText,
                language: language,
                model: model,
                vocabularyTerms: vocabularyTerms,
                frontApp: frontApp
            )
        }

        let prompt = buildPrompt(
            text: rawText,
            language: language,
            vocabularyTerms: vocabularyTerms,
            frontApp: frontApp
        )

        logger.info("🤖 LLM stream START — model=\(model, privacy: .public) input=\(rawText.count) chars")

        let started = Date.now
        var collected = ""
        for try await chunk in AIProvider.stream(
            prompt: prompt,
            model: model,
            temperature: 0.1
        ) {
            collected += chunk
        }

        let elapsed = Date.now.timeIntervalSince(started)
        logger.info("🤖 LLM stream DONE — \(collected.count) chars, \(String(format: "%.2f", elapsed))s")

        return applyGuardrails(rawOutput: collected, rawText: rawText)
    }

    // MARK: - Claude Code Persistent Session

    /// Route one voice-input polish through the warm Claude Code session.
    /// Seeds the system prompt once, then ~1.7s/turn steady-state vs
    /// ~8s/turn for cold-spawn.
    private static func rewriteViaClaudeCodeSession(
        rawText: String,
        language: VoiceInputLanguage,
        model: String,
        vocabularyTerms: [String],
        frontApp: String?
    ) async throws -> String {
        let systemPrompt = buildSystemPrompt(
            language: language,
            vocabularyTerms: vocabularyTerms
        )

        logger.info("🤖 LLM session START — model=\(model, privacy: .public) input=\(rawText.count) chars")

        let started = Date.now
        let raw = try await ClaudeCodeVoicePolishSession.shared.polish(
            text: sessionMessage(text: rawText, frontApp: frontApp),
            systemPrompt: systemPrompt,
            model: model,
            effort: resolvedEffort
        )

        let elapsed = Date.now.timeIntervalSince(started)
        logger.info("🤖 LLM session DONE — \(raw.count) chars, \(String(format: "%.2f", elapsed))s")

        return applyGuardrails(rawOutput: raw, rawText: rawText)
    }

    // MARK: - Guardrails

    /// Shared post-processing for both streaming and session paths:
    /// strip wrappers, reject empty / suspiciously long output.
    private static func applyGuardrails(rawOutput: String, rawText: String) -> String {
        let cleaned = stripWrappers(rawOutput)

        if cleaned.isEmpty {
            logger.warning("🤖 LLM returned empty — keeping original")
            return rawText
        }
        if cleaned.count > rawText.count * 3 + 80 {
            logger.warning("🤖 LLM suspiciously long (\(cleaned.count) vs \(rawText.count)) — keeping original")
            return rawText
        }

        if cleaned != rawText {
            logger.info("🤖 LLM: \"\(rawText, privacy: .public)\" → \"\(cleaned, privacy: .public)\"")
        }
        return cleaned
    }

    // MARK: - Skip Heuristic

    /// Returns a short reason string if the input clearly doesn't need
    /// the LLM, otherwise nil. Conservative on purpose — when in doubt,
    /// run the LLM. The savings come from the long tail of one-word
    /// English commands and trivial utterances, not from being clever.
    private static func shouldSkipReason(for text: String, mode: PolishMode) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or single character — nothing to fix.
        if trimmed.count < 2 {
            return "too short"
        }

        // Light/Medium are opt-in. They both clean up content that the
        // user explicitly asked to fix (fillers, grammar) — short
        // utterances are exactly where those problems show. Never skip.
        if mode != .strict {
            return nil
        }

        // Strict mode: skip very short pure-ASCII commands like "yes",
        // "ok", "save". STT is solid here and there's nothing to clean.
        let isAsciiOnly = trimmed.unicodeScalars.allSatisfy(\.isASCII)
        if isAsciiOnly && trimmed.count < 10 {
            return "short ASCII"
        }

        return nil
    }

}
