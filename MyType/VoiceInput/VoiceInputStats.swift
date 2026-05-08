// Abstract:
// Aggregate statistics over voice input records — recordings, speaking time,
// total characters, plus per-language sub-totals.

import Foundation

struct VoiceInputStats {
    var recordingCount: Int = 0
    var totalDuration: TimeInterval = 0
    var totalChars: Int = 0

    /// Per-language buckets keyed by canonical key (`zh`, `en`, or raw locale).
    var byLanguage: [LanguageKey: LanguageStats] = [:]

    /// Build stats from records filtered by an optional cutoff date (inclusive).
    static func compute(records: [VoiceInputRecord], since: Date? = nil) -> VoiceInputStats {
        var stats = VoiceInputStats()
        for record in records {
            if let since, record.createdAt < since { continue }
            stats.recordingCount += 1
            stats.totalDuration += record.duration
            stats.totalChars += record.text.count

            let key = LanguageKey(locale: record.language)
            var bucket = stats.byLanguage[key] ?? LanguageStats()
            bucket.recordingCount += 1
            bucket.duration += record.duration
            bucket.chars += record.text.count
            stats.byLanguage[key] = bucket
        }
        return stats
    }

    /// Languages sorted by total speaking time, descending.
    var languagesByDuration: [(LanguageKey, LanguageStats)] {
        byLanguage.sorted { $0.value.duration > $1.value.duration }
    }

    /// Estimated time it would have taken to type the same text by hand,
    /// using a per-language average typing rate (chars per minute).
    /// Unknown languages fall back to the English rate.
    var estimatedTypingDuration: TimeInterval {
        byLanguage.reduce(0) { acc, pair in
            let rate = pair.key.typingCharsPerMinute
            return acc + Double(pair.value.chars) / rate * 60
        }
    }

    /// Speaking is faster than typing — this is the difference in seconds.
    /// Negative would mean typing would have been faster (rare, very short
    /// recordings); we surface it raw so the UI can decide how to render.
    var timeSaved: TimeInterval {
        estimatedTypingDuration - totalDuration
    }
}

/// Per-language sub-totals.
struct LanguageStats {
    var recordingCount: Int = 0
    var duration: TimeInterval = 0
    var chars: Int = 0
}

/// Canonical language identity. Folds `zh-CN`, `zh-Hans`, etc. into `zh`.
struct LanguageKey: Hashable {
    let raw: String

    init(locale: String) {
        let primary = locale.split(separator: "-").first.map(String.init) ?? locale
        self.raw = primary.lowercased()
    }

    var displayName: String {
        switch raw {
        case "zh": return "中文"
        case "en": return "English"
        case "":   return "Unknown"
        default:
            let locale = Locale(identifier: raw)
            return locale.localizedString(forLanguageCode: raw)?.capitalized ?? raw
        }
    }

    var flagSymbol: String {
        switch raw {
        case "zh": return "character.bubble"
        case "en": return "textformat.abc"
        default:   return "globe"
        }
    }

    /// Average typing rate used to estimate "time saved." Pinyin input on
    /// Chinese is roughly 60 cpm; English typing averages ~40 WPM ≈ 200 cpm.
    var typingCharsPerMinute: Double {
        switch raw {
        case "zh": return 60
        case "en": return 200
        default:   return 200
        }
    }
}
