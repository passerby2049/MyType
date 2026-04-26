// Abstract:
// Enums describing the user-facing knobs for voice input — the
// transcription engine choice and the primary dictation language.
// Split out of VoiceInputManager.swift so that file stays under the
// 500-line limit (CLAUDE.md architecture rule).

import Foundation

// MARK: - Engine Choice

/// User-selectable transcription engine. Stored under UserDefaults key
/// `voiceInputEngine`; read via @AppStorage in settings, read directly
/// by VoiceInputManager at transcription time.
enum VoiceInputEngineChoice: String, CaseIterable, Identifiable {
    /// FluidAudio Qwen3-ASR, int8 variant (~900MB). Recommended default —
    /// same quality as f32 with half the RAM.
    case qwen3Int8 = "qwen3_int8"
    /// FluidAudio Qwen3-ASR, f32 variant (~1.75GB). Faster inference, more RAM.
    case qwen3F32 = "qwen3_f32"
    /// NVIDIA Parakeet TDT v3 via FluidAudio — 25 European languages.
    /// English is the strongest; no Chinese support.
    case parakeetV3 = "parakeet_v3"
    /// NVIDIA Parakeet TDT v2 via FluidAudio — English only, highest
    /// accuracy for pure-English dictation.
    case parakeetV2 = "parakeet_v2"
    /// Apple's built-in Speech framework. No download, works offline.
    case appleSpeech = "apple_speech"

    static let defaultsKey = "voiceInputEngine"
    static let fallback: VoiceInputEngineChoice = .qwen3Int8

    var id: String { rawValue }

    /// Which language(s) this engine actually handles well. Used by the
    /// settings view to filter the engine list based on the user's
    /// chosen input language. Qwen3 speaks Chinese + English natively,
    /// Parakeet doesn't do Chinese at all.
    func supports(language: VoiceInputLanguage) -> Bool {
        switch (self, language) {
        case (.appleSpeech, _): true
        case (.qwen3Int8, _), (.qwen3F32, _): true
        case (.parakeetV3, .english), (.parakeetV2, .english): true
        case (.parakeetV3, .chinese), (.parakeetV2, .chinese): false
        }
    }

    /// Read the current choice from UserDefaults, falling back to the default.
    static var current: VoiceInputEngineChoice {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return VoiceInputEngineChoice(rawValue: raw) ?? fallback
    }
}

// MARK: - Language

/// Primary dictation language. The user picks this in settings; it
/// drives both the engine list filtering and the language hint we
/// pass to the underlying transcriber at runtime.
enum VoiceInputLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh"
    case english = "en"

    static let defaultsKey = "voiceInputLanguage"
    static let fallback: VoiceInputLanguage = .chinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    /// BCP-47 locale identifier for AppleSpeech and hinting Qwen3.
    var localeIdentifier: String {
        switch self {
        case .chinese: "zh-CN"
        case .english: "en-US"
        }
    }

    /// Short two-letter code Qwen3 expects for its `language` parameter.
    var qwen3Hint: String {
        switch self {
        case .chinese: "zh"
        case .english: "en"
        }
    }

    /// Read the current choice from UserDefaults, falling back to Chinese.
    static var current: VoiceInputLanguage {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return VoiceInputLanguage(rawValue: raw) ?? fallback
    }
}
