// Abstract:
// Finds what a dictation became once it was sent: the part of a later
// input that is this dictation, as the user sent it — edits included.
// Inputs come from Claude Code's input history (~/.claude/history.jsonl,
// kept for good) for coding apps, and from the Otto Mac app's copy of its
// chat for Otto. Matching mirrors eval/sent_align.py; eval/align-check
// runs both over the same records.

import Foundation

enum SentTextAligner {
    /// Apps whose dictations usually go to Claude Code.
    static let codingApps: Set<String> = ["Code", "Warp", "Zed", "Terminal", "Cursor", "Ghostty", "iTerm2"]

    enum Source: Sendable {
        case claude
        case otto
    }

    /// Where to look for what a dictation into `app` was sent as.
    static func source(for app: String?) -> Source? {
        guard let app else { return nil }
        if codingApps.contains(app) { return .claude }
        if app == "Otto" { return .otto }
        return nil
    }

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

    /// Each source's inputs are read only when a dictation needs them.
    static func lookUp(_ dictations: [Dictation], inputs: (Source) -> [Input]) -> [UUID: Lookup] {
        var read: [Source: [Input]] = [:]
        var results: [UUID: Lookup] = [:]
        for dictation in dictations {
            guard let source = source(for: dictation.app) else {
                results[dictation.id] = .noSource
                continue
            }
            if read[source] == nil {
                read[source] = inputs(source)
            }
            let text = dictation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            results[dictation.id] = firstSent(text, at: dictation.at, in: read[source] ?? []) ?? .notFound
        }
        return results
    }

    private static func firstSent(_ text: String, at: Date, in inputs: [Input]) -> Lookup? {
        let from = at.addingTimeInterval(-5)
        let until = at.addingTimeInterval(sendWindow)
        for input in inputs where input.at >= from {
            if input.at > until { break }
            if let part = sentPart(of: text, in: input.text) {
                return .found(text: part, at: input.at)
            }
        }
        return nil
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

    static func inputs(from source: Source) -> [Input] {
        switch source {
        case .claude: claudeInputs()
        case .otto: ottoInputs()
        }
    }

    /// What was said in Otto's chats, oldest first, from the Otto Mac app's
    /// own copy (ChatClient/): the daily conversation (chat.json, its
    /// archive chat-older.jsonl) and each goal's (Goals/*/chat.json). Lines
    /// are {"kind", "at" (seconds since 2001), "text"}; only "user" counts.
    static func ottoInputs(
        folder: URL = URL(fileURLWithPath: NSHomeDirectory()
            + "/Library/Application Support/com.yutian.cardiocoach.mac/ChatClient")
    ) -> [Input] {
        let fm = FileManager.default
        var chats = [folder]
        let goals = folder.appending(path: "Goals")
        chats += (try? fm.contentsOfDirectory(at: goals, includingPropertiesForKeys: nil)) ?? []

        var lines: [[String: Any]] = []
        for chat in chats {
            if let data = try? Data(contentsOf: chat.appending(path: "chat.json")),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                lines += o["records"] as? [[String: Any]] ?? []
            }
            if let older = try? String(contentsOf: chat.appending(path: "chat-older.jsonl"), encoding: .utf8) {
                lines += older.split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
            }
        }
        return lines.compactMap { line -> Input? in
            guard line["kind"] as? String == "user",
                  let at = line["at"] as? Double,
                  let text = line["text"] as? String
            else { return nil }
            return Input(at: Date(timeIntervalSinceReferenceDate: at), text: text)
        }
        .sorted { ($0.at, $0.text) < ($1.at, $1.text) }
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
