// Abstract:
// Post-transcription optimizer for dictation text.
// Cleans up common STT artifacts: trailing punctuation
// on short phrases, whitespace normalization.

import Foundation

enum DictationOptimizer {

    /// Apply all post-processing steps to raw transcribed text.
    static func optimize(_ text: String) -> String {
        var result = text

        // Step 1: Normalize whitespace
        result = normalizeWhitespace(result)

        // Step 2: Remove trailing punctuation on short phrases
        result = removeTrailingPunctuationIfShort(result)

        return result
    }

    // MARK: - Trailing Punctuation Removal

    /// Short phrases (≤80 chars) with trailing sentence punctuation
    /// are likely STT artifacts — the user said "hello world" but
    /// the engine transcribed "Hello world." Remove the trailing
    /// punctuation for dictation use cases. Multi-sentence text is
    /// left as-is.
    private static func removeTrailingPunctuationIfShort(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 80 else { return text }

        // Check if it's multi-sentence (contains sentence enders mid-text)
        let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let body = trimmed.dropLast()
        let hasMidSentenceEnder = body.contains(where: { sentenceEnders.contains($0) })
        if hasMidSentenceEnder { return text }

        // Remove trailing sentence punctuation
        if let lastChar = trimmed.last, sentenceEnders.contains(lastChar) {
            return String(trimmed.dropLast())
        }

        return text
    }

    // MARK: - Whitespace Normalization

    /// Remove excess whitespace while preserving meaningful newlines.
    private static func normalizeWhitespace(_ text: String) -> String {
        // Replace multiple spaces with single space
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cleaned = lines.map { line -> String in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.joined(separator: " ")
        }

        // Remove consecutive empty lines (keep at most one)
        var result: [String] = []
        var lastWasEmpty = false
        for line in cleaned {
            let isEmpty = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty {
                if !lastWasEmpty {
                    result.append("")
                }
                lastWasEmpty = true
            } else {
                result.append(line)
                lastWasEmpty = false
            }
        }

        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
