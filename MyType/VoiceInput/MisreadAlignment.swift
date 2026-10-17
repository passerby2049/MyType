// Abstract:
// The practice sheet's two aligned rows (docs/design-misread-words.md 三):
// 「你说」 is the raw transcript, 「应该」 the polished text, word under word,
// as written (case and punctuation kept), fillers and repeats left out. The
// misread words are marked; the polish's other changes show unmarked.

import Foundation
import LifeKit

enum MisreadAlignment {
    struct Column: Equatable, Sendable {
        /// The word as recognized, nil when the polish added one.
        let said: String?
        /// The word as polished, nil when the polish left one out.
        let meant: String?
        /// One of the sheet's misread words.
        let misread: Bool
    }

    /// Raw against polished, word by word. `misreads` are (heard, meant) pairs as WordDiff writes them.
    static func columns(raw: String, polished: String, misreads: [(heard: String, meant: String)]) -> [Column] {
        let said = cleaned(tokens(raw)), meant = cleaned(tokens(polished))
        let marked = Set(misreads.map { "\($0.heard)>\($0.meant)" })
        return align(said, meant).map { a, b in
            let misread = a.flatMap { a in b.map { b in
                WordDiff.words(a).contains { h in WordDiff.words(b).contains { marked.contains("\(h)>\($0)") } }
            } } ?? false
            return Column(said: a, meant: b, misread: misread)
        }
    }

    /// The words as written, punctuation that stands alone dropped.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !key($0).isEmpty }
    }

    /// What two written words are compared by: lowercase letters, digits and apostrophes.
    static func key(_ token: String) -> String {
        String(token.lowercased().replacingOccurrences(of: "’", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == "'" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    /// Fillers out and repeats kept once, the way `MisreadCandidates.cleaned` does it, on written words.
    static func cleaned(_ tokens: [String]) -> [String] {
        var w = tokens.filter { !MisreadCandidates.fillers.contains(key($0)) }
        for n in stride(from: 5, through: 1, by: -1) {
            var i = 0
            while i + 2 * n <= w.count {
                if w[i..<i + n].map(key) == w[i + n..<i + 2 * n].map(key) { w.removeSubrange(i + n..<i + 2 * n) } else { i += 1 }
            }
        }
        return w
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = key(a), y = key(b)
        return x == y || Misreads.sameSound(x, y)
    }

    /// Word edit distance (a different word costs as much as one left out plus one added), walked back.
    private static func align(_ a: [String], _ b: [String]) -> [(String?, String?)] {
        let n = a.count, m = b.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n { for j in 1...m {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (same(a[i - 1], b[j - 1]) ? 0 : 2))
            } }
        }
        var out: [(String?, String?)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (same(a[i - 1], b[j - 1]) ? 0 : 2) {
                out.append((a[i - 1], b[j - 1])); i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                out.append((a[i - 1], nil)); i -= 1
            } else {
                out.append((nil, b[j - 1])); j -= 1
            }
        }
        return out.reversed()
    }
}
