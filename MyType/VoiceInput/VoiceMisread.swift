// Abstract:
// A misread English word as the record keeps it (docs/design-misread-words.md
// 四), and the user's 「这个我没读错」 answers: kept on the record and in a
// jsonl beside the history, so the judge can be rescored against them later.

import Foundation

/// One word of a dictation the recognizer heard as another word, as the judge said.
struct VoiceMisread: Codable, Equatable, Hashable, Sendable {
    /// What was meant (the polished text's word).
    let word: String
    /// What the recognizer wrote.
    let heard: String
    /// American IPA of `word`.
    let ipa: String?
    /// Which sound didn't come out (Chinese).
    let tip: String?
    /// The user said they didn't misread it (「这个我没读错」); nil = not answered.
    var notMisread: Bool? = nil

    init(word: String, heard: String, ipa: String?, tip: String?, notMisread: Bool? = nil) {
        (self.word, self.heard, self.ipa, self.tip, self.notMisread) = (word, heard, ipa, tip, notMisread)
    }

    init(_ verdict: MisreadJudge.Verdict) {
        self.init(word: verdict.meant, heard: verdict.heard,
                  ipa: verdict.ipa.flatMap { $0.isEmpty ? nil : $0 }, tip: verdict.tip.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The user's answers to the judge: one line per 「这个我没读错」, never rewritten.
enum MisreadLabels {
    struct Label: Codable, Equatable, Sendable {
        let record: UUID
        let word: String
        let heard: String
        /// What the judge said ("sound": only those reach the sheet).
        let kind: String
        let ipa: String?
        let tip: String?
        /// "notMisread": the user says they said it right.
        let label: String
        let at: Date
    }

    static let fileName = "misread-labels.jsonl"
    static var file: URL { VoiceInputStore.baseDirectory.appending(path: fileName) }

    static func append(_ label: Label, to file: URL = file) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(label)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: file)
        }
    }

    static func all(in file: URL = file) -> [Label] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Label.self, from: Data($0.utf8)) }
    }
}
