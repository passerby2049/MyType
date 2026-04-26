// Abstract:
// Unified AI interface supporting OpenRouter (cloud),
// Anthropic Messages-compatible endpoints, Google AI Studio (Gemini),
// and local Claude Code CLI.

import Foundation
import os

// MARK: - AI Provider

struct AIProvider {
    enum Provider: String, CaseIterable, Identifiable {
        case openRouter
        case anthropic
        case googleAI
        /// Local Claude Code CLI — piggybacks on the user's Pro/Max
        /// subscription via subprocess.
        case claudeCode

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openRouter: return "OpenRouter"
            case .anthropic: return "Anthropic"
            case .googleAI: return "Google AI Studio"
            case .claudeCode: return "Claude Code (Local CLI)"
            }
        }
    }

    static let prefs = AppPreferences()

    /// Remembers the last Google AI key that returned 200, so the next
    /// request starts from a known-good key instead of re-probing dead
    /// ones. In-memory only — clears on app restart, at which point we
    /// fall back to list order in `prefs.googleAIKeys`.
    static let lastGoodGoogleKey = OSAllocatedUnfairLock<UUID?>(
        initialState: nil
    )

    // Dedicated session for SSE streaming — URLSession.shared on iOS buffers
    // small-chunk text/event-stream responses, causing LLM streams to stall.
    static let streamingSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()

    // swiftlint:disable force_unwrapping — constant URL literals never fail
    private static let defaultAnthropicBase = URL(string: "https://api.anthropic.com")!
    static let openRouterBase = URL(string: "https://openrouter.ai/api/v1")!
    static let googleAIBase = URL(
        string: "https://generativelanguage.googleapis.com/v1beta"
    )!
    // swiftlint:enable force_unwrapping

    static var anthropicBase: URL {
        URL(string: prefs.anthropicBaseURL) ?? defaultAnthropicBase
    }

    static var openRouterKey: String { prefs.openRouterAPIKey }

    static var anthropicKey: String { prefs.anthropicAPIKey }

    static let anthropicModels = [
        "claude-opus-4-6",
        "claude-sonnet-4-6",
        "claude-haiku-4-5"
    ]

    static let openRouterModels = [
        "google/gemini-2.5-flash",
        "google/gemini-2.5-flash-lite",
        "google/gemini-3.1-flash-lite-preview",
        "deepseek/deepseek-v3.2",
        "minimax/minimax-m2.7",
        "qwen/qwen3.6-plus:free",
        "google/gemma-3-27b-it:free",
        "minimax/minimax-m2.5:free",
    ]

    /// Google AI Studio models — bare IDs without vendor prefix, which
    /// distinguishes them from OpenRouter's `google/gemini-*` entries.
    /// Text-chat capable models only; image/audio/TTS/embedding variants
    /// aren't applicable to MyType's LLM call sites.
    static let googleAIModels = [
        "gemini-3.1-pro-preview",
        "gemini-3-flash-preview",
        "gemini-3.1-flash-lite-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
    ]

    /// Claude Code CLI model shortcuts — prefixed `cc-` so
    /// `provider(for:)` can route them to the subprocess stream. The
    /// suffix (`opus` / `sonnet` / `haiku`) is passed through to the
    /// `claude -p --model` flag verbatim.
    static let claudeCodeModels = [
        "cc-opus",
        "cc-sonnet",
        "cc-haiku",
    ]

    static func provider(for model: String) -> Provider {
        if model.hasPrefix("cc-") { return .claudeCode }
        if googleAIModels.contains(model) || (model.hasPrefix("gemini-") && !model.contains("/")) {
            return .googleAI
        }
        if anthropicModels.contains(model) || model.hasPrefix("claude-") {
            return .anthropic
        }
        return .openRouter
    }

    static func models(for provider: Provider) -> [String] {
        switch provider {
        case .openRouter: return openRouterModels
        case .anthropic: return anthropicModels
        case .googleAI: return googleAIModels
        case .claudeCode: return claudeCodeModels
        }
    }

    static func anthropicMessagesURL(
        from baseURL: URL
    ) -> URL {
        let normalizedPath = baseURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath == "v1/messages" {
            return baseURL
        }
        if normalizedPath == "v1" {
            return baseURL.appendingPathComponent("messages")
        }
        return baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("messages")
    }

    static var anthropicMessagesURL: URL {
        anthropicMessagesURL(from: anthropicBase)
    }

    /// Stream a completion. `temperature` is optional — when nil, each
    /// provider uses its own default. Pass a low value (e.g. 0.1) for
    /// strict post-processing tasks like voice-input typo correction
    /// where creative rewriting would be a bug.
    ///
    /// Claude Code (`cc-*` models) is not routed here — callers must
    /// dispatch to `ClaudeCodeVoicePolishSession` themselves to reuse
    /// the warm subprocess.
    static func stream(
        prompt: String,
        model: String,
        temperature: Double? = nil
    ) -> AsyncThrowingStream<String, Error> {
        switch provider(for: model) {
        case .openRouter:
            return streamOpenRouter(prompt: prompt, model: model, temperature: temperature)
        case .anthropic:
            return streamAnthropic(prompt: prompt, model: model, temperature: temperature)
        case .googleAI:
            return streamGoogleAI(prompt: prompt, model: model, temperature: temperature)
        case .claudeCode:
            preconditionFailure("Claude Code models must go through ClaudeCodeVoicePolishSession, not AIProvider.stream")
        }
    }

    static func errorMessage(from responseBody: String) -> String? {
        guard let data = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return responseBody
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? nil : responseBody
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }

        if let message = json["message"] as? String,
           !message.isEmpty {
            return message
        }

        return responseBody
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? nil : responseBody
    }
}
