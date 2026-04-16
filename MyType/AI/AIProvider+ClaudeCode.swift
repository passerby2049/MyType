// Abstract:
// Claude Code (Local CLI) streaming implementation via subprocess.

import Foundation
import os

extension AIProvider {

    // MARK: - Claude Code (Local CLI) Streaming

    static let ccLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MyType",
        category: "ClaudeCode"
    )

    static func claudeCodeBinaryPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Spawn `claude -p` with a minimal env, pipe the prompt via stdin,
    /// parse `--output-format stream-json` from stdout, yield text as
    /// it arrives.
    static func streamClaudeCode(
        prompt: String,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let binary = claudeCodeBinaryPath() else {
                    continuation.finish(throwing: ClaudeCodeError.binaryNotFound)
                    return
                }

                let modelArg = model.hasPrefix("cc-") ? String(model.dropFirst(3)) : model

                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = [
                    "-p", "--model", modelArg,
                    "--tools", "", "--strict-mcp-config",
                    "--disable-slash-commands", "--no-session-persistence",
                    "--input-format", "text",
                    "--output-format", "stream-json", "--verbose",
                ]
                process.currentDirectoryURL = claudeCodeScratchDir()
                process.environment = claudeCodeEnvironment()

                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = stdin

                let spawnStart = Date()
                var stderrTask: Task<Void, Error>?

                do {
                    try process.run()

                    let stdoutLines = makeLineStream(from: stdout.fileHandleForReading)
                    stderrTask = Task {
                        for await line in makeLineStream(from: stderr.fileHandleForReading) {
                            ccLogger.error("🤖 stderr: \(line, privacy: .public)")
                        }
                    }

                    Task.detached(priority: .userInitiated) {
                        if let data = prompt.data(using: .utf8) {
                            try? stdin.fileHandleForWriting.write(contentsOf: data)
                        }
                        try? stdin.fileHandleForWriting.close()
                    }

                    var gotResult = false
                    var apiMs = 0
                    var inTok = 0
                    var outTok = 0

                    outer: for await line in stdoutLines {
                        try Task.checkCancellation()
                        guard let event = parseClaudeStreamLine(line) else { continue }
                        switch event {
                        case .text(let t):
                            continuation.yield(t)
                        case .result(let isError, let errorMsg, let ms, let inT, let outT):
                            if isError {
                                continuation.finish(throwing: ClaudeCodeError.apiError(errorMsg ?? "Unknown error"))
                                return
                            }
                            apiMs = ms; inTok = inT; outTok = outT
                            gotResult = true
                            break outer
                        }
                    }

                    if gotResult, process.isRunning { process.terminate() }
                    if process.isRunning { process.waitUntilExit() }
                    stderrTask?.cancel()

                    let totalMs = Int(Date().timeIntervalSince(spawnStart) * 1000)
                    ccLogger.info("🤖 \(modelArg, privacy: .public) done — total=\(totalMs, privacy: .public)ms api=\(apiMs, privacy: .public)ms in=\(inTok, privacy: .public) out=\(outTok, privacy: .public)")

                    if !gotResult, process.terminationStatus != 0, process.terminationStatus != 15 {
                        continuation.finish(throwing: ClaudeCodeError.processExited(process.terminationStatus))
                        return
                    }
                    continuation.finish()
                } catch {
                    if process.isRunning { process.terminate() }
                    stderrTask?.cancel()
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
