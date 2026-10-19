// Abstract:
// Long-lived `claude -p --input-format stream-json` subprocess dedicated
// to voice-input polish. The rules go in as the appended system prompt
// (cached, as Otto's chat does), then the warm session takes one
// transcript per turn — no cold start per request.

import Foundation
import os

actor ClaudeCodeVoicePolishSession {
    /// Session dedicated to STT post-correction (raw voice transcripts).
    static let shared = ClaudeCodeVoicePolishSession()
    /// Separate session for general text polish (fn+space flow). Kept
    /// separate so the two system prompts don't fight and force respawns.
    static let textPolish = ClaudeCodeVoicePolishSession()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MyType",
        category: "CCVoicePolish"
    )

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutIterator: AsyncStream<String>.AsyncIterator?
    private var stderrTask: Task<Void, Never>?

    /// System prompt currently loaded. A mismatch means the vocabulary or
    /// language changed since last call — tear down and respawn.
    private var systemPromptInUse: String?
    private var modelInUse: String?
    private var effortInUse: String?
    private var turnCount = 0
    /// A turn is waiting for its reply. A turn the caller gave up on (past
    /// the 10 s timeout) can still be running when the next transcript
    /// comes; two turns reading one stdout could take each other's reply.
    private var turnInFlight = false
    /// Bumped per spawn, so a turn from a session already replaced doesn't
    /// tear down or touch its successor.
    private var generation = 0
    /// Whether the last turn had to start its session (for the history's
    /// "冷 / 热" and the statistics).
    private(set) var lastTurnCold = false
    /// Respawn after this many turns to keep context size bounded.
    private let maxTurnsBeforeRespawn = 100

    // MARK: - Public API

    /// Polish one raw transcript through the persistent session.
    /// Lazily spawns on first call. Respawns if the subprocess died or the
    /// system prompt, model or effort changed since last call.
    func polish(
        text: String,
        systemPrompt: String,
        model: String,
        effort: String = "low"
    ) async throws -> String {
        let spawned = try prepare(systemPrompt: systemPrompt, model: model, effort: effort)
        let turnGeneration = generation
        lastTurnCold = spawned
        turnInFlight = true
        defer { if generation == turnGeneration { turnInFlight = false } }
        do {
            turnCount += 1
            logger.info("turn \(self.turnCount, privacy: .public)\(spawned ? " (spawned for it — cold)" : "", privacy: .public)")
            return try await sendAndCollect(text, generation: turnGeneration)
        } catch {
            if generation == turnGeneration {
                logger.warning("turn failed, tearing down: \(error.localizedDescription, privacy: .public)")
                tearDown()
            }
            throw error
        }
    }

    /// Make sure a session with these rules is running, without sending a
    /// turn (no tokens). Called when recording starts, so a session that
    /// died, has new rules (vocabulary, language) or reached its turn limit
    /// is started while the user speaks, not after — a cold start after
    /// speaking cost ~6 s against ~2 s warm. Returns whether it spawned.
    @discardableResult
    func prepare(systemPrompt: String, model: String, effort: String) throws -> Bool {
        guard process?.isRunning != true || turnInFlight || systemPromptInUse != systemPrompt || modelInUse != model || effortInUse != effort || turnCount >= maxTurnsBeforeRespawn else {
            return false
        }
        if turnInFlight { logger.warning("a turn is still running — replacing the session") }
        tearDown()
        try spawnProcess(model: model, effort: effort, systemPrompt: systemPrompt)
        systemPromptInUse = systemPrompt
        modelInUse = model
        effortInUse = effort
        turnCount = 0
        return true
    }

    /// The model `cc-opus` / `cc-sonnet` stands for.
    static func fullModel(_ model: String) -> String {
        switch model.hasPrefix("cc-") ? String(model.dropFirst(3)) : model {
        case "opus": "claude-opus-5-5"
        case "sonnet": "claude-sonnet-5-5"
        case let other: other
        }
    }

    /// Started the way Otto starts its chat (Driver/ChatEngine.swift): the rules
    /// are the appended system prompt — the same for the whole session, so
    /// they're cached and a new app or language doesn't respawn it; none of
    /// the user's own Claude Code settings, hooks, plugins or CLAUDE.md; no
    /// tools; stream-json both ways.
    private func spawnProcess(model: String, effort: String, systemPrompt: String) throws {
        guard let binary = claudeCodeBinaryPath() else {
            throw ClaudeCodeError.binaryNotFound
        }
        generation += 1
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-p", "--model", Self.fullModel(model),
            "--effort", effort,
            "--append-system-prompt", systemPrompt,
            "--setting-sources", "project,local",
            "--tools", "", "--strict-mcp-config",
            "--disable-slash-commands", "--no-session-persistence",
            "--input-format", "stream-json",
            "--output-format", "stream-json", "--verbose",
        ]
        proc.currentDirectoryURL = claudeCodeScratchDir("MyTypeClaudeVoicePolish")
        var environment = claudeCodeEnvironment()
        environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        // Since 2.1.302 each turn ends with a model-written summary, and the
        // result waits for it: +3–4 s a turn, once 12 s (measured 10/19).
        // Off, the summary is the reply itself and comes with it.
        environment["CLAUDE_CODE_CLASSIFIER_SUMMARY"] = "0"
        proc.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe
        try proc.run()
        let stderrLogger = self.logger
        stderrTask = Task {
            for await line in makeLineStream(from: stderrPipe.fileHandleForReading, label: "cc-voice-stderr") {
                stderrLogger.error("stderr: \(line, privacy: .public)")
            }
        }
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutIterator = makeLineStream(from: stdoutPipe.fileHandleForReading, label: "cc-voice-stdout")
            .makeAsyncIterator()
        logger.info("spawned pid=\(proc.processIdentifier, privacy: .public) model=\(Self.fullModel(model), privacy: .public)")
    }

    private func tearDown() {
        stderrTask?.cancel()
        stderrTask = nil
        if let h = stdinHandle { try? h.close() }
        stdinHandle = nil
        stdoutIterator = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        systemPromptInUse = nil
        modelInUse = nil
        effortInUse = nil
        turnCount = 0
        turnInFlight = false
        cleanupSessionFiles()
    }

    /// Remove leftover session .jsonl files that Claude Code creates
    /// despite --no-session-persistence (only contains metadata titles).
    private func cleanupSessionFiles() {
        let scratchDir = claudeCodeScratchDir("MyTypeClaudeVoicePolish")
        let projectPath = scratchDir.path
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects/\(projectPath)")
        try? FileManager.default.removeItem(at: sessionsDir)
    }

    // MARK: - Turn I/O

    /// Send one message and collect the reply's text.
    private func sendAndCollect(_ text: String, generation turnGeneration: Int) async throws -> String {
        guard let handle = stdinHandle, var iterator = stdoutIterator else {
            throw ClaudeCodeError.stdoutClosed
        }

        // Build envelope and write in one shot.
        let envelope: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        var payload = try JSONSerialization.data(withJSONObject: envelope)
        payload.append(0x0A)
        try handle.write(contentsOf: payload)

        var collected = ""
        while let line = await iterator.next() {
            try Task.checkCancellation()
            guard let event = parseClaudeStreamLine(line) else { continue }
            switch event {
            case .text(let t):
                collected += t
            case .result(let isError, let errorMsg, _, _, _):
                if generation == turnGeneration { stdoutIterator = iterator }
                if isError {
                    throw ClaudeCodeError.apiError(errorMsg ?? "claude returned is_error")
                }
                return collected
            }
        }

        if generation == turnGeneration { stdoutIterator = nil }
        throw ClaudeCodeError.stdoutClosed
    }
}
