// Abstract:
// Finds what a dictation became once it was sent: the part of a later
// Claude Code input (~/.claude/history.jsonl, kept for good) that is this
// dictation, as the user sent it — edits included. Matching mirrors
// eval/sent_align.py; eval/align-check runs both over the same records.

import Foundation

enum SentTextAligner {
    /// Apps whose dictations usually go to Claude Code.
    static let codingApps: Set<String> = ["Code", "Warp", "Zed", "Terminal", "Cursor", "Ghostty", "iTerm2"]

    /// How long after a dictation its input may be submitted.
    static let sendWindow: TimeInterval = 15 * 60

    struct Dictation: Sendable {
        let id: UUID
        let text: String
        let at: Date
        let app: String?
    }

    enum Lookup: Sendable {
        case found(text: String, at: Date)
        case notFound
        case noSource
    }

    struct Input: Sendable {
        let at: Date
        let text: String
    }

    static func lookUp(_ dictations: [Dictation], in inputs: [Input]) -> [UUID: Lookup] {
        var results: [UUID: Lookup] = [:]
        for dictation in dictations {
            guard let app = dictation.app, codingApps.contains(app) else {
                results[dictation.id] = .noSource
                continue
            }
            let text = dictation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let from = dictation.at.addingTimeInterval(-5)
            let until = dictation.at.addingTimeInterval(sendWindow)
            results[dictation.id] = .notFound
            for input in inputs where input.at >= from {
                if input.at > until { break }
                if let part = sentPart(of: text, in: input.text) {
                    results[dictation.id] = .found(text: part, at: input.at)
                    break
                }
            }
        }
        return results
    }

    /// Everything submitted to Claude Code, oldest first, with pasted
    /// text (shown as "[Pasted text #N +M lines]") put back in.
    static func claudeInputs(
        file: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/history.jsonl")
    ) -> [Input] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var inputs: [Input] = []
        for line in contents.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ms = o["timestamp"] as? Double
            else { continue }
            var text = o["display"] as? String ?? ""
            for (key, value) in o["pastedContents"] as? [String: Any] ?? [:] {
                guard let pasted = (value as? [String: Any])?["content"] as? String, !pasted.isEmpty,
                      let start = text.range(of: "[Pasted text #\(key)"),
                      let end = text.range(of: "]", range: start.upperBound..<text.endIndex)
                else { continue }
                text.replaceSubrange(start.lowerBound..<end.upperBound, with: pasted)
            }
            inputs.append(Input(at: Date(timeIntervalSince1970: ms / 1000), text: text))
        }
        return inputs.sorted { ($0.at, $0.text) < ($1.at, $1.text) }
    }

    /// The part of `sent` that is `dictated`, or nil when it isn't in
    /// there: 70% of the dictation must appear in order, in runs of 4+
    /// characters, one of them long (half the dictation, or 12) — so a
    /// short "But this" can't match on stray letters.
    static func sentPart(of dictated: String, in sent: String) -> String? {
        let a = Array(dictated.unicodeScalars)
        let b = Array(sent.unicodeScalars)
        let blocks = matchingBlocks(a, b).filter { $0.size >= 4 }
        guard let first = blocks.first, let last = blocks.last,
              let longest = blocks.map(\.size).max(),
              Double(longest) >= min(12, Double(a.count) * 0.5),
              Double(blocks.reduce(0) { $0 + $1.size }) >= 0.7 * Double(a.count)
        else { return nil }

        // From where the dictation would start to where it would end,
        // widened to whole English words (Chinese isn't widened: the
        // next dictation often follows without a space).
        var lo = max(first.b - first.a, 0)
        var hi = min(last.b + last.size + a.count - last.a - last.size, b.count)
        while lo > 0, isWord(b[lo - 1]), isWord(b[lo]) { lo -= 1 }
        while hi > 0, hi < b.count, isWord(b[hi - 1]), isWord(b[hi]) { hi += 1 }
        guard lo < hi else { return nil }

        var view = String.UnicodeScalarView()
        view.append(contentsOf: b[lo..<hi])
        let part = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(part.unicodeScalars.count) <= 1.5 * Double(a.count) + 10 ? part : nil
    }

    private static func isWord(_ c: Unicode.Scalar) -> Bool {
        c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "'")
    }

    // MARK: - Matching blocks (Python's difflib.SequenceMatcher, no junk)

    struct Block {
        let a: Int
        let b: Int
        let size: Int
    }

    static func matchingBlocks(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> [Block] {
        var b2j: [Unicode.Scalar: [Int]] = [:]
        for (j, scalar) in b.enumerated() {
            b2j[scalar, default: []].append(j)
        }
        var queue = [(0, a.count, 0, b.count)]
        var found: [Block] = []
        while let range = queue.popLast() {
            let (alo, ahi, blo, bhi) = range
            let m = longestMatch(a, b2j, alo, ahi, blo, bhi)
            guard m.size > 0 else { continue }
            found.append(m)
            if alo < m.a, blo < m.b {
                queue.append((alo, m.a, blo, m.b))
            }
            if m.a + m.size < ahi, m.b + m.size < bhi {
                queue.append((m.a + m.size, ahi, m.b + m.size, bhi))
            }
        }
        found.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        var merged: [Block] = []
        for block in found {
            if let last = merged.last, last.a + last.size == block.a, last.b + last.size == block.b {
                merged[merged.count - 1] = Block(a: last.a, b: last.b, size: last.size + block.size)
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    /// The longest common run in a[alo..<ahi] and b[blo..<bhi]; the
    /// earliest in a, then in b, when several are as long.
    private static func longestMatch(
        _ a: [Unicode.Scalar],
        _ b2j: [Unicode.Scalar: [Int]],
        _ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int
    ) -> Block {
        var best = Block(a: alo, b: blo, size: 0)
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > best.size {
                    best = Block(a: i - k + 1, b: j - k + 1, size: k)
                }
            }
            j2len = newj2len
        }
        return best
    }
}
