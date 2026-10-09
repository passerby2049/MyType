// Abstract:
// The voice-input log, for Otto to learn from. Once a dictation has had
// time to be sent, looks up what was actually sent (SentTextAligner) and
// keeps it on the record; then writes each day's dictations to the Otto
// folder as _数据/语音输入/YYYY-MM-DD.md — recognized, polished, sent.
// Runs at launch and hourly; the files are rebuilt from the records.

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceLog"
)

@MainActor
final class VoiceLog {
    static let shared = VoiceLog()

    /// The Otto folder the daily files go into; empty turns them off.
    static let ottoFolderKey = "voiceLogOttoFolder"
    static let defaultOttoFolder = NSHomeDirectory()
        + "/Library/Mobile Documents/com~apple~CloudDocs/Otto"

    static var ottoFolder: String {
        UserDefaults.standard.string(forKey: ottoFolderKey) ?? defaultOttoFolder
    }

    private var timer: Timer?
    private var isRunning = false

    private init() {}

    func start() {
        Task { await run() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in await VoiceLog.shared.run() }
        }
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        await lookUpSent()
        await writeDays()
    }

    // MARK: - What was sent

    private func lookUpSent() async {
        let store = VoiceInputStore.shared
        let cutoff = Date.now.addingTimeInterval(-SentTextAligner.sendWindow)
        let dictations = store.records
            .filter { $0.createdAt < cutoff && Self.needsLookUp($0) }
            .map { SentTextAligner.Dictation(id: $0.id, text: $0.text, at: $0.createdAt, app: $0.targetApp) }
        guard !dictations.isEmpty else { return }

        let results = await Task.detached(priority: .utility) {
            SentTextAligner.lookUp(dictations, inputs: SentTextAligner.inputs(from:))
        }.value

        var changes: [UUID: (inout VoiceInputRecord) -> Void] = [:]
        for (id, lookup) in results {
            switch lookup {
            case .found(let text, let at):
                changes[id] = {
                    $0.sentLookup = .found
                    $0.sentText = text
                    $0.sentAt = at
                }
            case .notFound:
                changes[id] = { $0.sentLookup = .notFound }
            case .noSource:
                changes[id] = { $0.sentLookup = .noSource }
            }
        }
        store.update(changes)
        logger.info("Looked up what \(dictations.count) dictations were sent as")
    }

    /// Not looked up yet — or found to have no source before its app got one.
    private static func needsLookUp(_ record: VoiceInputRecord) -> Bool {
        switch record.sentLookup {
        case nil: true
        case .noSource: SentTextAligner.source(for: record.targetApp) != nil
        case .found, .notFound: false
        }
    }

    // MARK: - Daily files

    private func writeDays() async {
        let folder = Self.ottoFolder
        guard !folder.isEmpty else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            logger.notice("Otto folder not found, no daily files: \(folder, privacy: .public)")
            return
        }
        let directory = URL(fileURLWithPath: folder)
            .appending(path: "_数据")
            .appending(path: "语音输入")
        let days = Self.render(VoiceInputStore.shared.records)

        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var written = 0
            for (day, content) in days {
                let file = directory.appending(path: "\(day).md")
                if (try? String(contentsOf: file, encoding: .utf8)) == content { continue }
                do {
                    try content.write(to: file, atomically: true, encoding: .utf8)
                    written += 1
                } catch {
                    logger.error("Couldn't write \(file.path, privacy: .public): \(error)")
                }
            }
            if written > 0 {
                logger.info("Wrote \(written) daily voice-input files")
            }
        }.value
    }

    /// One Markdown file per day, keyed by "YYYY-MM-DD".
    static func render(_ records: [VoiceInputRecord]) -> [String: String] {
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        let timeFormat = DateFormatter()
        timeFormat.locale = Locale(identifier: "en_US_POSIX")
        timeFormat.dateFormat = "HH:mm"

        let byDay = Dictionary(grouping: records) { dayFormat.string(from: $0.createdAt) }
        return byDay.mapValues { dayRecords in
            let sorted = dayRecords.sorted { $0.createdAt < $1.createdAt }
            let found = sorted.filter { $0.sentLookup == .found }
            let edited = found.filter { $0.sentText != trimmed($0.text) }
            let day = dayFormat.string(from: sorted[0].createdAt)
            var lines = [
                "# 语音输入 \(day)",
                "",
                "\(sorted.count) 条 · 对上 \(found.count) · 改过 \(edited.count)",
                "",
            ]
            for record in sorted {
                lines += entry(record, time: timeFormat.string(from: record.createdAt))
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// "- 14:02 Warp · 改过" and its 识别 / 润色 / 发出 lines; a dictation
    /// sent as it was pasted is one line (plus 识别 when polish changed it).
    private static func entry(_ record: VoiceInputRecord, time: String) -> [String] {
        let raw = oneLine(record.rawTranscript)
        let text = oneLine(record.text)
        let sent = record.sentText.map(oneLine)
        let head = "- \(time) \(record.targetApp ?? "?")"
        let recognized = raw == text ? [] : ["  识别 \(raw)"]

        switch record.sentLookup {
        case .found where sent == text:
            return ["\(head) · 原样 · \(text)"] + recognized
        case .found:
            return ["\(head) · 改过"] + recognized + ["  润色 \(text)", "  发出 \(sent ?? "")"]
        case .notFound:
            return ["\(head) · 没对上"] + recognized + ["  润色 \(text)"]
        case .noSource:
            return ["\(head) · 没有来源"] + recognized + ["  润色 \(text)"]
        case nil:
            return ["\(head) · 待对"] + recognized + ["  润色 \(text)"]
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func oneLine(_ text: String) -> String {
        trimmed(text).replacingOccurrences(of: "\n", with: " ↵ ")
    }
}
