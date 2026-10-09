// Abstract:
// Decides whether an LLM reply can stand in for the text it polished.
// A polish only fixes words, so a reply that grew, or that talks about
// the task, is the model answering or thinking out loud — the original
// goes in instead.

import Foundation

enum PolishOutputGuard {
    /// Why the reply can't replace the input, or nil when it can.
    ///
    /// Measured on 1,224 polishes (history plus eval runs): the reply's
    /// word count stayed within 0.67–1.33× of the input's. The one leak
    /// ("…Hmm, wait — I should keep it minimal. Correct output: …") was
    /// 2.5× and the only reply with a task phrase the input didn't have.
    static func rejection(output: String, input: String) -> String? {
        if output.isEmpty {
            return "empty"
        }
        let inputWords = words(in: input)
        let outputWords = words(in: output)
        if Double(outputWords) > Double(inputWords) * 1.6 + 4 {
            return "\(outputWords) words for \(inputWords)"
        }
        if let phrase = taskPhrase(in: output), taskPhrase(in: input) == nil {
            return "talks about the task (\"\(phrase)\")"
        }
        return nil
    }

    /// Latin words and digits count one each, every CJK or kana character
    /// counts one — so Chinese and English text compare on the same scale.
    static func words(in text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.lowercased().unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
    }

    // swiftlint:disable:next force_try — constant pattern
    private static let taskPattern = try! NSRegularExpression(
        pattern: #"correct(?:ed)? (?:output|text|version|transcript)|here(?:'s| is) the (?:corrected|cleaned|polished|fixed)|\bi should\b|\blet me\b|\bthe (?:raw )?transcript\b|整理如下|以下是|润色后|修正后|纠正后|输出[:：]"#,
        options: [.caseInsensitive]
    )

    private static func taskPhrase(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = taskPattern.firstMatch(in: text, range: range),
              let found = Range(match.range, in: text)
        else { return nil }
        return String(text[found])
    }
}
