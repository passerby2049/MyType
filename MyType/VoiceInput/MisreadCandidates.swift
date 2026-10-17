// Abstract:
// The local first pass of finding misread English words (docs/design-misread-words.md 二 2): the raw transcript
// against the polished text, word by word (LifeKit WordDiff, nihongo's), keeping only one word written as another.
// Most sentences end here with nothing; the rest go to `MisreadJudge`.

import Foundation
import LifeKit

enum MisreadCandidates {
    /// A word the recognizer wrote (`heard`) where the polish has another (`meant`), both as WordDiff writes them.
    struct Candidate: Equatable, Hashable, Sendable, Codable {
        let heard: String
        let meant: String
    }

    /// Fillers: not words the speaker meant, so not compared.
    static let fillers: Set<String> = ["uh", "um", "uhm", "umm", "er", "erm", "ah", "eh", "hmm", "mm", "mhm"]

    /// The longest repeat collapsed ("I want to, I want to" → "I want to").
    private static let longestRepeat = 5

    /// The one-word-for-another changes from raw to polished. Left out, added, the same sound spelled differently
    /// (`Misreads.sameSound`), case, punctuation and contractions don't count; a run of several words for the same
    /// number of others is taken word by word, a run of one for several is not taken. Nothing when more than half of
    /// the words don't line up: the whole sentence was misheard (noise, too fast), not one word.
    static func candidates(raw: String, polished: String) -> [Candidate] {
        let said = cleaned(WordDiff.words(raw)), meant = cleaned(WordDiff.words(polished))
        guard !said.isEmpty, !meant.isEmpty else { return [] }
        let diff = WordDiff.compare(said: said.joined(separator: " "), reference: meant.joined(separator: " "))
        if diff.columns.count(where: \.off) * 2 > diff.columns.count { return [] }

        var out: [Candidate] = []
        var run: [WordDiff.Column] = []
        func flush() {
            defer { run = [] }
            let heard = run.compactMap(\.said), wanted = run.compactMap(\.reference)
            guard !heard.isEmpty, heard.count == wanted.count else { return }
            for (h, m) in zip(heard, wanted) where isWord(h) && isWord(m) && !Misreads.sameSound(m, h) {
                out.append(Candidate(heard: h, meant: m))
            }
        }
        for column in diff.columns {
            if column.off { run.append(column) } else { flush() }
        }
        flush()
        var seen = Set<Candidate>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Fillers out, then each word sequence said twice in a row kept once (longest first).
    static func cleaned(_ words: [String]) -> [String] {
        var w = words.filter { !fillers.contains($0) }
        for n in stride(from: longestRepeat, through: 1, by: -1) {
            var i = 0
            while i + 2 * n <= w.count {
                if w[i..<i + n] == w[i + n..<i + 2 * n] { w.removeSubrange(i + n..<i + 2 * n) } else { i += 1 }
            }
        }
        return w
    }

    /// An English word: Latin letters (and an apostrophe), not a number or Chinese.
    private static func isWord(_ w: String) -> Bool {
        w.contains(where: \.isLetter) && w.allSatisfy { ($0.isASCII && $0.isLetter) || $0 == "'" }
    }
}
