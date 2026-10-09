// Abstract:
// Enums describing the user-facing knobs for voice input — the
// transcription engine choice and the dictation language.
// Split out of VoiceInputManager.swift so that file stays under the
// 500-line limit (CLAUDE.md architecture rule).

import Foundation

// MARK: - Engine Choice

/// User-selectable transcription engine. Stored under UserDefaults key
/// `voiceInputEngine`; read via @AppStorage in settings, read directly
/// by VoiceInputManager at transcription time. A stored value from an
/// engine that's gone (FluidAudio's Qwen3, Parakeet) reads as the default.
enum VoiceInputEngineChoice: String, CaseIterable, Identifiable {
    /// Qwen3-ASR 1.7B (MLX 5-bit, speech-swift): Chinese, English and
    /// Japanese in one model, language detected, takes a context.
    /// ~2 GB in memory. Measured best (docs/eval-2026-10-09.md).
    case qwen3Large = "qwen3_1.7b"
    /// Qwen3-ASR 0.6B (MLX 8-bit): the same, smaller — ~1.3 GB, less
    /// accurate (Japanese most of all).
    case qwen3Small = "qwen3_0.6b"
    /// Apple's built-in Speech framework. No download, works offline,
    /// one language at a time.
    case appleSpeech = "apple_speech"

    static let defaultsKey = "voiceInputEngine"
    static let fallback: VoiceInputEngineChoice = .qwen3Large

    var id: String { rawValue }

    /// The Hugging Face model speech-swift downloads and loads.
    var modelID: String? {
        switch self {
        case .qwen3Large: "aufklarer/Qwen3-ASR-1.7B-MLX-5bit"
        case .qwen3Small: "aufklarer/Qwen3-ASR-0.6B-MLX-8bit"
        case .appleSpeech: nil
        }
    }

    /// Read the current choice from UserDefaults, falling back to the default.
    static var current: VoiceInputEngineChoice {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return VoiceInputEngineChoice(rawValue: raw) ?? fallback
    }
}

// MARK: - Language

/// Dictation language. Auto lets Qwen3-ASR tell Chinese, English and
/// Japanese apart (mixing them is fine); picking one only passes it as a
/// hint — the model stays the same. Polish rules follow the language of
/// the text that came back (`resolved(for:)`).
enum VoiceInputLanguage: String, CaseIterable, Identifiable {
    case auto
    case chinese = "zh"
    case english = "en"
    case japanese = "ja"

    static let defaultsKey = "voiceInputLanguage"
    static let fallback: VoiceInputLanguage = .auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "自动"
        case .chinese: "中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    /// BCP-47 locale identifier for Apple Speech (one language at a time:
    /// auto uses the Mac's first preferred language).
    var localeIdentifier: String {
        switch self {
        case .auto: Locale.preferredLanguages.first ?? "en-US"
        case .chinese: "zh-CN"
        case .english: "en-US"
        case .japanese: "ja-JP"
        }
    }

    /// The `language` hint for Qwen3-ASR; nil lets it detect.
    var qwen3Hint: String? {
        self == .auto ? nil : rawValue
    }

    /// The language of a transcript, for the polish rules: kana means
    /// Japanese, other CJK means Chinese, otherwise English. A language
    /// picked in settings stays as picked.
    func resolved(for text: String) -> VoiceInputLanguage {
        guard self == .auto else { return self }
        if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .japanese }
        if text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { return .chinese }
        return .english
    }

    /// Read the current choice from UserDefaults, falling back to auto.
    static var current: VoiceInputLanguage {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return VoiceInputLanguage(rawValue: raw) ?? fallback
    }
}
