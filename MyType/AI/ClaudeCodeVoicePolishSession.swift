// Abstract:
// Long-lived `claude -p --input-format stream-json` subprocess dedicated
// to voice-input polish. Seeds the system prompt ONCE, then reuses the
// warm session for each polish turn — steady-state ~1.7s/request vs
// ~8s/request for cold-spawn. Unrelated Claude Code paths (reorg,
// translation) continue to use `AIProvider.streamClaudeCode` which
// spawns fresh each call.

import Foundation
import os

actor ClaudeCodeVoicePolishSession {
    static let shared = ClaudeCodeVoicePolishSession()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MyType",
        category: "CCVoicePolish"
    )

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutIterator: AsyncStream<String>.AsyncIterator?
    private var stderrTask: Task<Void, Never>?

    /// Seed prompt currently loaded. A mismatch means the vocabulary or
    /// language changed since last call — tear down and respawn.
    private var seededPrompt: String?
    private var seededModel: String?
    private var seededEffort: String?
    private var turnCount = 0
    /// Respawn after this many turns to keep context size bounded.
    private let maxTurnsBeforeRespawn = 100

    // MARK: - Public API

    /// Polish one raw transcript through the persistent session.
    /// Lazily spawns + seeds on first call. Respawns if the subprocess
    /// died or seed/model changed since last call.
    func polish(
        text: String,
        seedPrompt: String,
        model: String,
        effort: String = "low"
    ) async throws -> String {
        if process?.isRunning != true || seededPrompt != seedPrompt || seededModel != model || seededEffort != effort || turnCount >= maxTurnsBeforeRespawn {
            tearDown()
            try spawnProcess(model: model, effort: effort)
            try await sendAndDiscard(seedPrompt)
            seededPrompt = seedPrompt
            seededModel = model
            seededEffort = effort
            turnCount = 0
        }

        do {
            turnCount += 1
            return try await sendAndCollect(text)
        } catch {
            logger.warning("turn failed, tearing down: \(error.localizedDescription, privacy: .public)")
            tearDown()
            throw error
        }
    }

    /// Best-effort shutdown. Normally unnecessary — child is reaped on app exit.
    func shutdown() { tearDown() }

    // MARK: - Process Lifecycle

    private func spawnProcess(model: String, effort: String = "low") throws {
        guard let binary = AIProvider.claudeCodeBinaryPath() else {
            throw ClaudeCodeError.binaryNotFound
        }

        let modelArg = model.hasPrefix("cc-") ? String(model.dropFirst(3)) : model
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        // --effort low cuts thinking overhead ~40% for simple STT
        // correction tasks without quality loss. Requires full model
        // name (aliases like "sonnet" silently ignore --effort).
        let fullModel: String
        switch modelArg {
        case "opus": fullModel = "claude-opus-4-6"
        case "sonnet": fullModel = "claude-sonnet-4-6"
        case "haiku": fullModel = "claude-haiku-4-5"
        default: fullModel = modelArg
        }
        proc.arguments = [
            "-p", "--model", fullModel,
            "--effort", effort,
            "--allowedTools", "",
            "--tools", "", "--strict-mcp-config",
            "--disable-slash-commands", "--no-session-persistence",
            "--input-format", "stream-json",
            "--output-format", "stream-json", "--verbose",
        ]
        proc.currentDirectoryURL = claudeCodeScratchDir("MyTypeClaudeVoicePolish")
        proc.environment = claudeCodeEnvironment()

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

        logger.info("spawned pid=\(proc.processIdentifier, privacy: .public) model=\(modelArg, privacy: .public)")
    }

    private func tearDown() {
        stderrTask?.cancel()
        stderrTask = nil
        if let h = stdinHandle { try? h.close() }
        stdinHandle = nil
        stdoutIterator = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        seededPrompt = nil
        seededModel = nil
        seededEffort = nil
        turnCount = 0
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

    /// Send a message, discard the reply (used for seeding).
    private func sendAndDiscard(_ text: String) async throws {
        let t0 = Date()
        _ = try await sendAndCollect(text)
        logger.info("seeded in \(String(format: "%.2f", Date().timeIntervalSince(t0)), privacy: .public)s")
    }

    /// Send a stream-json user message, collect all text from the
    /// assistant reply, return it when the `result` event arrives.
    private func sendAndCollect(_ text: String) async throws -> String {
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
                stdoutIterator = iterator
                if isError {
                    throw ClaudeCodeError.apiError(errorMsg ?? "claude returned is_error")
                }
                return collected
            }
        }

        stdoutIterator = nil
        throw ClaudeCodeError.stdoutClosed
    }
}
