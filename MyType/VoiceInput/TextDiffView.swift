// Abstract:
// Inline diff view — shows character-level differences between
// two strings with colored highlights (red strikethrough for
// deletions, green for insertions).

import SwiftUI

struct TextDiffView: View {
    let original: String
    let modified: String
    var font: Font = .system(size: 14, design: .rounded)

    var body: some View {
        Text(TextDiff.attributed(from: original, to: modified))
            .font(font)
            .lineSpacing(4)
            .textSelection(.enabled)
    }
}

enum TextDiff {
    enum Op: Equatable {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// Past this many character pairs the LCS table gets slow; show the
    /// new text as it is instead.
    private static let maxCells = 600_000

    static func attributed(from a: String, to b: String) -> AttributedString {
        var result = AttributedString()
        guard let ops = ops(from: a, to: b) else { return AttributedString(b) }
        for op in ops {
            switch op {
            case .equal(let s):
                result.append(AttributedString(s))
            case .delete(let s):
                var part = AttributedString(s)
                part.foregroundColor = Theme.red
                part.backgroundColor = Theme.red.opacity(0.13)
                part.strikethroughStyle = .single
                result.append(part)
            case .insert(let s):
                var part = AttributedString(s)
                part.foregroundColor = Theme.green
                part.backgroundColor = Theme.green.opacity(0.14)
                result.append(part)
            }
        }
        return result
    }

    /// What was replaced by what: each delete followed by an insert (or the
    /// other way round), trimmed, both sides short — "set bar" → "sidebar".
    static func replacements(from a: String, to b: String, maxLength: Int = 24) -> [(String, String)] {
        guard let ops = ops(from: a, to: b) else { return [] }
        var pairs: [(String, String)] = []
        var index = 0
        while index < ops.count {
            switch (ops[index], index + 1 < ops.count ? ops[index + 1] : nil) {
            case (.delete(let old), .insert(let new)?), (.insert(let new), .delete(let old)?):
                let o = old.trimmingCharacters(in: .whitespacesAndNewlines)
                let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if !o.isEmpty, !n.isEmpty, o.count <= maxLength, n.count <= maxLength {
                    pairs.append((o, n))
                }
                index += 2
            default:
                index += 1
            }
        }
        return pairs
    }

    /// LCS-based, character level, consecutive runs merged; nil when the
    /// texts are too long to compare quickly.
    static func ops(from a: String, to b: String) -> [Op]? {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        guard (m + 1) * (n + 1) <= maxCells else { return nil }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    dp[i][j] = aChars[i - 1] == bChars[j - 1]
                        ? dp[i - 1][j - 1] + 1
                        : max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var ops: [Op] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && aChars[i - 1] == bChars[j - 1] {
                ops.append(.equal(String(aChars[i - 1])))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                ops.append(.insert(String(bChars[j - 1])))
                j -= 1
            } else {
                ops.append(.delete(String(aChars[i - 1])))
                i -= 1
            }
        }
        ops.reverse()

        var merged: [Op] = []
        for op in ops {
            if let last = merged.last {
                switch (last, op) {
                case (.equal(let x), .equal(let y)):
                    merged[merged.count - 1] = .equal(x + y); continue
                case (.delete(let x), .delete(let y)):
                    merged[merged.count - 1] = .delete(x + y); continue
                case (.insert(let x), .insert(let y)):
                    merged[merged.count - 1] = .insert(x + y); continue
                default: break
                }
            }
            merged.append(op)
        }
        return merged
    }
}
