// context-check — tests for the conversation context the polish gets (docs/design-misread-words.md 一): the transcript
// tail reader, the last exchange, the on-screen session pick, the desktop app's prompts and where a dictation went, and
// the record's new fields; then times the pick + read against the real Claude desktop app if it is running.
// Build: swiftc -O -o context-check main.swift ../../MyType/VoiceInput/ClaudeSessionLog.swift \
//   ../../MyType/VoiceInput/ConversationContext.swift ../../MyType/VoiceInput/SentTextAligner.swift \
//   ../../MyType/VoiceInput/VoiceInputRecord.swift
import AppKit

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL (line \(line)): \(what)") }
}

let temp = FileManager.default.temporaryDirectory.appending(path: "context-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

func json(_ o: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
}
func human(_ text: String, session: String = "S1", at: String = "2026-10-16T10:00:00.000Z") -> String {
    json(["type": "user", "origin": ["kind": "human"], "entrypoint": "claude-desktop", "sessionId": session,
          "timestamp": at, "message": ["role": "user", "content": text]])
}
func answer(_ text: String, id: String) -> String {
    json(["type": "assistant", "message": ["id": id, "role": "assistant", "content": [["type": "text", "text": text]]]])
}
let toolUse = json(["type": "assistant", "message": ["id": "m-tool", "content": [["type": "tool_use", "name": "Bash"]]]])
let toolResult = json(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ls"]]]])
let notification = json(["type": "user", "origin": ["kind": "task-notification"],
                         "message": ["role": "user", "content": "<task-notification>done</task-notification>"]])
let reminderOnly = json(["type": "user", "origin": ["kind": "human"],
                         "message": ["role": "user", "content": "<system-reminder>\nLinked sessions\n</system-reminder>"]])
let oldCommand = json(["type": "user", "message": ["role": "user", "content": "<command-name>/model</command-name>"]])

func write(_ lines: [String], to name: String, trailingNewline: Bool = true, extra: String = "") -> URL {
    let url = temp.appending(path: name)
    try! (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "") + extra).write(to: url, atomically: true, encoding: .utf8)
    return url
}

// MARK: - Tail reader

do {
    // Under 256 KB: every line, the half-written last one dropped.
    let small = write([human("first"), answer("one", id: "a")], to: "small.jsonl", extra: "{\"type\":\"assist")
    let lines = ClaudeSessionLog.tailLines(of: small, maxBytes: 256 * 1024)
    check(lines.count == 2, "small file: 2 whole lines, got \(lines.count)")
    let first = (try? JSONSerialization.jsonObject(with: lines[0])) as? [String: Any]
    check(first.flatMap(ClaudeSessionLog.humanPrompt) == "first", "small file: the first line is kept whole")

    // Ending in a newline: nothing dropped at the end.
    let whole = write([human("first"), answer("one", id: "a")], to: "whole.jsonl")
    check(ClaudeSessionLog.tailLines(of: whole, maxBytes: 256 * 1024).count == 2, "file ending in newline: 2 lines")

    // Bigger than the window: the line the read starts inside is dropped.
    let padding = (0..<40).map { answer(String(repeating: "x", count: 100) + "\($0)", id: "p\($0)") }
    let big = write(padding + [human("last prompt"), answer("last answer", id: "z")], to: "big.jsonl", extra: "{\"half")
    let tail = ClaudeSessionLog.tailLines(of: big, maxBytes: 1000)
    check(!tail.isEmpty && tail.allSatisfy { (try? JSONSerialization.jsonObject(with: $0)) != nil },
          "big file: every line in the tail parses (\(tail.count) lines)")
    check(ClaudeSessionLog.lastExchange(in: big, maxBytes: 1000)
          == .init(prompt: "last prompt", answer: "last answer", promptIsLast: false), "big file: last exchange from the tail")

    let empty = write([], to: "empty.jsonl", trailingNewline: false)
    check(ClaudeSessionLog.tailLines(of: empty, maxBytes: 1000).isEmpty, "empty file: no lines")
    check(ClaudeSessionLog.lastExchange(in: empty) == nil, "empty file: no exchange")
    check(ClaudeSessionLog.tailLines(of: temp.appending(path: "missing.jsonl"), maxBytes: 1000).isEmpty, "missing file")
}

// MARK: - Last exchange

do {
    let lines = [
        human("earlier"), answer("old answer", id: "m0"),
        human("<system-reminder>\nnote\n</system-reminder>\nthe real prompt"),
        toolUse, toolResult, notification, reminderOnly, oldCommand,
        answer("part one", id: "m1"), answer("part two", id: "m1"),
    ].map { Data($0.utf8) }
    let exchange = ClaudeSessionLog.lastExchange(lines: lines)
    check(exchange.prompt == "the real prompt", "prompt skips tool results, notes and reminders: \(exchange.prompt ?? "nil")")
    check(exchange.answer == "part one\n\npart two", "an answer in two lines of one message: \(exchange.answer ?? "nil")")
    check(exchange.text() == "User: the real prompt\n\nClaude: part one\n\npart two", "text, oldest first")

    // Claude hasn't answered the last prompt yet: its previous answer, then the prompt.
    let waiting = ClaudeSessionLog.lastExchange(lines: [answer("previous", id: "a"), human("new question")].map { Data($0.utf8) })
    check(waiting.text() == "Claude: previous\n\nUser: new question", "unanswered prompt comes last: \(waiting.text() ?? "nil")")

    // Cut from the end: about 1500 characters, the prompt at most a third.
    let long = ClaudeSessionLog.Exchange(prompt: String(repeating: "p", count: 2000) + "END",
                                         answer: String(repeating: "a", count: 3000) + "FIN")
    let text = long.text()!
    check(text.count <= 1500 + 20, "capped at ~1500: \(text.count)")
    check(text.contains("END") && text.hasSuffix("FIN"), "each part keeps its end")
}

// MARK: - Session pick

do {
    func session(_ id: String, _ title: String, _ focused: Double) -> ClaudeSessionLog.DesktopSession {
        .init(cliSessionId: id, title: title, lastFocusedAt: focused)
    }
    let sessions = [session("a", "高效提升英语能力", 300), session("b", "MyType work", 200), session("c", "Disk usage", 0)]
    check(ClaudeSessionLog.onScreen(sessions, webAreaTitle: "高效提升英语能力 - Claude Code")?.cliSessionId == "a",
          "agree: the last opened session, titled as the window")
    check(ClaudeSessionLog.onScreen(sessions, webAreaTitle: "MyType work - Claude Code") == nil,
          "disagree: window shows another session")
    check(ClaudeSessionLog.onScreen(sessions + [session("d", "高效提升英语能力", 10)],
                                    webAreaTitle: "高效提升英语能力 - Claude Code") == nil,
          "duplicate title: no context")
    check(ClaudeSessionLog.onScreen(sessions, webAreaTitle: nil) == nil, "Claude not front / no Code page: no context")
    check(ClaudeSessionLog.onScreen(sessions, webAreaTitle: "高效提升英语能力") == nil, "web area without the Code suffix")
    check(ClaudeSessionLog.onScreen([session("c", "Disk usage", 0)], webAreaTitle: "Disk usage - Claude Code") == nil,
          "never opened (lastFocusedAt 0)")
    check(ClaudeSessionLog.onScreen([], webAreaTitle: "x - Claude Code") == nil, "no sessions")

    // Not Claude: nothing is read.
    check(ConversationContext.read(pid: ProcessInfo.processInfo.processIdentifier) == nil, "front app isn't Claude")
    check(ConversationContext.read(pid: nil) == nil, "no front app")

    // Session records on disk, re-read when they change.
    let org = temp.appending(path: "sessions/acct/org")
    try FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
    let record = org.appending(path: "local_1.json")
    try json(["cliSessionId": "cli-1", "title": "One", "lastFocusedAt": 1792162266746, "cwd": "/x"])
        .write(to: record, atomically: true, encoding: .utf8)
    try json(["title": "no cli id"]).write(to: org.appending(path: "local_2.json"), atomically: true, encoding: .utf8)
    try "{}".write(to: org.appending(path: "other.json"), atomically: true, encoding: .utf8)
    let parsed = ClaudeSessionLog.desktopSessions(in: temp.appending(path: "sessions"))
    check(parsed == [session("cli-1", "One", 1792162266746)], "session records parsed: \(parsed)")
    try json(["cliSessionId": "cli-1", "title": "Renamed", "lastFocusedAt": 5])
        .write(to: record, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: record.path)
    check(ClaudeSessionLog.desktopSessions(in: temp.appending(path: "sessions")).first?.title == "Renamed",
          "a changed record is read again")
}

// MARK: - Desktop prompts and where a dictation went

do {
    let projects = temp.appending(path: "projects")
    let folder = projects.appending(path: "-Users-me-dev-app")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try ([human("Can you look at the cards view?", session: "S1", at: "2026-10-16T10:00:05.000Z"),
          answer("Sure", id: "a"), toolResult, notification,
          human("too early", session: "S1", at: "2026-10-16T09:00:00.000Z")].joined(separator: "\n") + "\n")
        .write(to: folder.appending(path: "S1.jsonl"), atomically: true, encoding: .utf8)
    try (human("And the sidebar too", session: "S2", at: "2026-10-16T10:01:00.000Z") + "\n")
        .write(to: folder.appending(path: "S2.jsonl"), atomically: true, encoding: .utf8)
    check(ClaudeSessionLog.transcriptFile(session: "S2", in: projects)?.lastPathComponent == "S2.jsonl", "transcript found")
    check(ClaudeSessionLog.transcriptFile(session: "S9", in: projects) == nil, "no transcript")

    let iso = ISO8601DateFormatter()
    let since = iso.date(from: "2026-10-16T09:59:00Z")!
    let prompts = ClaudeSessionLog.desktopPrompts(since: since, in: projects)
    check(prompts.map(\.text) == ["Can you look at the cards view?", "And the sidebar too"]
          && prompts.map(\.session) == ["S1", "S2"], "desktop prompts since: \(prompts.map(\.text))")

    let inputs = prompts.map { SentTextAligner.Input(at: $0.at, text: $0.text, session: $0.session) }
    let now = iso.date(from: "2026-10-16T12:00:00Z")!
    let dictations = [
        SentTextAligner.Dictation(id: UUID(), text: "Can you look at the cards view?", at: iso.date(from: "2026-10-16T10:00:00Z")!, app: "Claude"),
        SentTextAligner.Dictation(id: UUID(), text: "Can you look at the cards view?", at: iso.date(from: "2026-09-01T10:00:00Z")!, app: "Claude"),
    ]
    var asked: [(SentTextAligner.Source, Date)] = []
    let results = SentTextAligner.lookUp(dictations, now: now) { source, since in
        asked.append((source, since))
        return inputs
    }
    if case .found(_, _, let session) = results[dictations[0].id] {
        check(session == "S1", "found in session S1")
    } else {
        check(false, "Claude dictation found")
    }
    if case .noSource = results[dictations[1].id] {} else { check(false, "older than the transcripts: no source") }
    check(asked.count == 1 && asked[0].0 == .claudeDesktop && asked[0].1 == dictations[0].at.addingTimeInterval(-5),
          "inputs read once, from the earliest dictation that needs them")
}

// MARK: - Record

do {
    let old = """
    {"id":"20D4E86C-30A3-46BD-954C-AD337F176422","text":"t","rawTranscript":"r","audioFileName":"a.m4a","language":"en-US",
     "duration":1.5,"createdAt":"2026-10-16T10:00:00Z","wasRewritten":false}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(VoiceInputRecord.self, from: Data(old.utf8))
    check(record.contextSession == nil && record.sentSession == nil, "old record decodes with no context session")

    var new = record
    new.contextSession = "877e8871-1703-4a19-bb48-3e0a1d54c8b2"
    new.sentSession = "877e8871-1703-4a19-bb48-3e0a1d54c8b2"
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let again = try decoder.decode(VoiceInputRecord.self, from: encoder.encode(new))
    check(again.contextSession == new.contextSession && again.sentSession == new.sentSession, "fields round-trip")
}

try? FileManager.default.removeItem(at: temp)
print(failures == 0 ? "All checks passed" : "\(failures) failed")

// MARK: - Timing against the real app

if let claude = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == ConversationContext.claudeBundleID }) {
    var times: [Double] = []
    var picked: String?
    let coldStart = Date()
    _ = ConversationContext.read(pid: claude.processIdentifier)
    let cold = Date().timeIntervalSince(coldStart) * 1000
    for _ in 0..<30 {
        let start = Date()
        picked = ConversationContext.read(pid: claude.processIdentifier).map { "\($0.session) (\($0.text.count) chars)" }
        times.append(Date().timeIntervalSince(start) * 1000)
    }
    times.sort()
    print(String(format: "Claude desktop: first read %.1f ms; then median %.1f ms, p90 %.1f ms, max %.1f ms — %@",
                 cold, times[15], times[27], times[29], picked ?? "no context"))
}
exit(failures == 0 ? 0 : 1)
