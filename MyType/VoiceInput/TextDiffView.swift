// Abstract:
// Inline diff view — shows character-level differences between
// two strings with colored highlights (red strikethrough for
// deletions, green for insertions).

import SwiftUI

struct TextDiffView: View {
    let original: String
    let modified: String

    var body: some View {
        let ops = diffOps(from: original, to: modified)
        let attributed = buildAttributedString(from: ops)
        Text(attributed)
            .font(.callout)
            .textSelection(.enabled)
    }

    private func buildAttributedString(from ops: [DiffOp]) -> AttributedString {
        var result = AttributedString()
        for op in ops {
            var part: AttributedString
            switch op {
            case .equal(let s):
                part = AttributedString(s)
            case .delete(let s):
                part = AttributedString(s)
                part.foregroundColor = Color(red: 1.0, green: 0.42, blue: 0.42)
                part.backgroundColor = Color(red: 1.0, green: 0.23, blue: 0.19).opacity(0.12)
            case .insert(let s):
                part = AttributedString(s)
                part.foregroundColor = Color(red: 0.19, green: 0.82, blue: 0.35)
                part.backgroundColor = Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.12)
            }
            result.append(part)
        }
        return result
    }
}

// MARK: - Diff Algorithm (LCS-based, character level)

private enum DiffOp {
    case equal(String)
    case delete(String)
    case insert(String)
}

/// Simple LCS-based diff producing equal/delete/insert runs.
private func diffOps(from a: String, to b: String) -> [DiffOp] {
    let aChars = Array(a)
    let bChars = Array(b)
    let m = aChars.count
    let n = bChars.count

    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 1...max(m, 1) {
        for j in 1...max(n, 1) {
            guard i <= m, j <= n else { continue }
            if aChars[i - 1] == bChars[j - 1] {
                dp[i][j] = dp[i - 1][j - 1] + 1
            } else {
                dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
            }
        }
    }

    var ops: [DiffOp] = []
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

    // Merge consecutive same-type ops
    var merged: [DiffOp] = []
    for op in ops {
        if let last = merged.last {
            switch (last, op) {
            case (.equal(let a), .equal(let b)):
                merged[merged.count - 1] = .equal(a + b); continue
            case (.delete(let a), .delete(let b)):
                merged[merged.count - 1] = .delete(a + b); continue
            case (.insert(let a), .insert(let b)):
                merged[merged.count - 1] = .insert(a + b); continue
            default: break
            }
        }
        merged.append(op)
    }
    return merged
}
