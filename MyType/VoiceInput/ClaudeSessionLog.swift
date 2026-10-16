// Abstract:
// Claude Code's own files, read for the conversation the user dictates
// into (docs/design-misread-words.md 一): the Claude desktop app's
// session records (which Code session is on screen) and a session's
// transcript, ~/.claude/projects/*/<id>.jsonl (its last exchange, and
// what was typed into it). Both are the apps' internal formats — when
// they change, this follows.

import Foundation
import os

enum ClaudeSessionLog {

    // MARK: - Which session is on screen

    /// One Code session as the desktop app keeps it
    /// (claude-code-sessions/*/*/local_*.json).
    struct DesktopSession: Equatable, Sendable {
        let cliSessionId: String
        let title: String
        /// When it was last opened in the window (ms since 1970); 0 if never.
        let lastFocusedAt: Double
    }

    static let desktopSessionsFolder = URL(fileURLWithPath: NSHomeDirectory()
        + "/Library/Application Support/Claude/claude-code-sessions")
    static let projectsFolder = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")

    /// The window's web area is titled "<session title> - Claude Code".
    static let webAreaTitleSuffix = " - Claude Code"

    /// The session on screen: the one opened last, if the window shows its
    /// title and no other session has that title. Either source alone was
    /// not enough (picking by who answered last was right half the time,
    /// design-misread-words.md「挑会话」); anything less certain is nil.
    static func onScreen(_ sessions: [DesktopSession], webAreaTitle: String?) -> DesktopSession? {
        guard let webAreaTitle, webAreaTitle.hasSuffix(webAreaTitleSuffix),
              let newest = sessions.max(by: { $0.lastFocusedAt < $1.lastFocusedAt }),
              newest.lastFocusedAt > 0,
              String(webAreaTitle.dropLast(webAreaTitleSuffix.count)) == newest.title,
              sessions.count(where: { $0.title == newest.title }) == 1
        else { return nil }
        return newest
    }

    /// Every session record, each file parsed again only when it changed
    /// (~150 files, 2 MB: parsing them all every time cost more than the
    /// 50 ms budget).
    static func desktopSessions(in folder: URL = desktopSessionsFolder) -> [DesktopSession] {
        let fm = FileManager.default
        let accounts = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var files: [URL] = []
        for account in accounts {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let names = (try? fm.contentsOfDirectory(atPath: org.path)) ?? []
                files += names.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }
                    .map { org.appending(path: $0) }
            }
        }
        var sessions: [DesktopSession] = []
        for file in files {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            else { continue }
            let cached = sessionCache.withLock { $0[file.path] }
            let session: DesktopSession?
            if let cached, cached.modified == modified {
                session = cached.session
            } else {
                session = (try? Data(contentsOf: file)).flatMap(desktopSession(from:))
                sessionCache.withLock { $0[file.path] = (modified, session) }
            }
            if let session { sessions.append(session) }
        }
        return sessions
    }

    private static let sessionCache = OSAllocatedUnfairLock<[String: (modified: Date, session: DesktopSession?)]>(
        initialState: [:]
    )

    static func desktopSession(from data: Data) -> DesktopSession? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["cliSessionId"] as? String, !id.isEmpty
        else { return nil }
        return DesktopSession(
            cliSessionId: id,
            title: o["title"] as? String ?? "",
            lastFocusedAt: (o["lastFocusedAt"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    // MARK: - The last exchange

    /// The user's last prompt and Claude's last answer, as text.
    struct Exchange: Equatable, Sendable {
        var prompt: String?
        var answer: String?
        /// Whether the prompt came after the answer (Claude hasn't answered it yet).
        var promptIsLast = false

        /// Both, oldest first, each cut from its end: about `limit`
        /// characters, the prompt at most a third of it.
        func text(limit: Int = 1500) -> String? {
            let prompt = prompt.map { Self.tail($0, limit / 3) }
            let answer = answer.map { Self.tail($0, limit - (prompt?.count ?? 0)) }
            let parts = [
                prompt.map { "User: \($0)" },
                answer.map { "Claude: \($0)" },
            ]
            let ordered = (promptIsLast ? parts.reversed() : parts).compactMap { $0 }
            return ordered.isEmpty ? nil : ordered.joined(separator: "\n\n")
        }

        private static func tail(_ text: String, _ limit: Int) -> String {
            text.count <= limit ? text : "…" + text.suffix(max(limit - 1, 0))
        }
    }

    /// The transcript of a Claude Code session, wherever its project folder is.
    static func transcriptFile(session: String, in projects: URL = projectsFolder) -> URL? {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders.lazy
            .map { projects.appending(path: $0).appending(path: "\(session).jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// The last exchange in a session's transcript, from its last 256 KB.
    static func lastExchange(in file: URL, maxBytes: Int = 256 * 1024) -> Exchange? {
        let exchange = lastExchange(lines: tailLines(of: file, maxBytes: maxBytes))
        return exchange.prompt == nil && exchange.answer == nil ? nil : exchange
    }

    /// The whole lines in the last `maxBytes` of a file: the first is
    /// dropped when the read starts inside it, the last when it isn't
    /// finished (the app may be writing it right now).
    static func tailLines(of file: URL, maxBytes: Int) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return [] }

        // After the last newline: nothing, or a line still being written.
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.isEmpty }.map { Data($0) }
    }

    static func lastExchange(lines: [Data]) -> Exchange {
        var exchange = Exchange()
        var answerMessage: String?
        for line in lines {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let prompt = humanPrompt(o) {
                exchange.prompt = prompt
                exchange.promptIsLast = true
            } else if let text = assistantText(o) {
                // An answer can come as several lines of one message.
                let message = (o["message"] as? [String: Any])?["id"] as? String
                if let message, message == answerMessage, let answer = exchange.answer {
                    exchange.answer = answer + "\n\n" + text
                } else {
                    exchange.answer = text
                }
                answerMessage = message
                exchange.promptIsLast = false
            }
        }
        return exchange
    }

    // MARK: - Transcript lines

    /// What the user typed (or dictated), from a transcript line; nil for
    /// everything else: tool results, notes the app or other sessions
    /// inject, slash-command output.
    static func humanPrompt(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "user", o["isMeta"] as? Bool != true,
              let message = o["message"] as? [String: Any]
        else { return nil }
        let origin = (o["origin"] as? [String: Any])?["kind"] as? String
        if let origin, origin != "human" { return nil }

        var text: String
        if let content = message["content"] as? String {
            text = content
        } else if let blocks = message["content"] as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        text = withoutSystemReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // Older versions don't say where a line came from: their injected
        // lines start with a tag (<command-name>, <task-notification>…).
        if origin == nil, text.hasPrefix("<") || text.hasPrefix("[Request interrupted") { return nil }
        return text.isEmpty ? nil : text
    }

    /// Claude's words in a transcript line (no thinking, no tool calls).
    static func assistantText(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "assistant",
              let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return nil }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func withoutSystemReminders(_ text: String) -> String {
        guard text.contains("<system-reminder>") else { return text }
        var text = text
        while let start = text.range(of: "<system-reminder>"),
              let end = text.range(of: "</system-reminder>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text
    }

    // MARK: - What was typed into the desktop app

    /// The prompts typed into the desktop app's Code sessions since `date`,
    /// oldest first, with the session each went into. The desktop app
    /// doesn't write ~/.claude/history.jsonl (the terminal's `claude`
    /// does), so these come from the transcripts.
    static func desktopPrompts(
        since date: Date,
        in projects: URL = projectsFolder
    ) -> [(at: Date, text: String, session: String)] {
        let fm = FileManager.default
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let marker = Data("\"entrypoint\":\"claude-desktop\"".utf8)
        var prompts: [(at: Date, text: String, session: String)] = []
        for folder in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let dir = projects.appending(path: folder)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".jsonl") {
                let file = dir.appending(path: name)
                // A file last written before `date` has nothing after it.
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, modified >= date,
                      let data = try? Data(contentsOf: file, options: .mappedIfSafe)
                else { continue }
                for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
                    guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let text = humanPrompt(o),
                          let at = (o["timestamp"] as? String).flatMap(iso.date(from:)), at >= date,
                          let session = o["sessionId"] as? String
                    else { continue }
                    prompts.append((at, text, session))
                }
            }
        }
        return prompts.sorted { ($0.at, $0.text) < ($1.at, $1.text) }
    }
}
