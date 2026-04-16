// Abstract:
// Shared types and helpers for Claude Code subprocess operations.
// Used by both AIProvider.streamClaudeCode and
// ClaudeCodeVoicePolishSession.

import Foundation

// MARK: - Claude Code Shared Helpers

/// Typed errors for Claude Code subprocess operations.
enum ClaudeCodeError: LocalizedError {
    case binaryNotFound
    case apiError(String)
    case processExited(Int32)
    case stdoutClosed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Claude Code CLI not found. Install from claude.com/claude-code."
        case .apiError(let msg):
            msg
        case .processExited(let code):
            "claude CLI exited with code \(code)"
        case .stdoutClosed:
            "claude CLI stdout closed before result"
        }
    }
}

/// Parsed event from `--output-format stream-json`.
enum ClaudeStreamEvent {
    case text(String)
    case result(isError: Bool, errorMessage: String?, apiMs: Int, inputTokens: Int, outputTokens: Int)
}

/// Parse one stream-json line into a typed event, or nil for
/// non-content events (system, rate_limit, etc).
func parseClaudeStreamLine(_ line: String) -> ClaudeStreamEvent? {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String
    else { return nil }

    switch type {
    case "assistant":
        guard let msg = json["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]]
        else { return nil }
        let texts = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined()
        return joined.isEmpty ? nil : .text(joined)

    case "result":
        let isError = (json["is_error"] as? Bool) ?? false
        let errorMsg = (json["error"] as? String) ?? (json["result"] as? String)
        let usage = json["usage"] as? [String: Any]
        return .result(
            isError: isError,
            errorMessage: isError ? errorMsg : nil,
            apiMs: json["duration_api_ms"] as? Int ?? 0,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0
        )

    default:
        return nil
    }
}

/// Minimal env for Claude Code subprocesses — strips Xcode debug vars
/// (DYLD_*, MallocNanoZone, CLAUDECODE_*) that slow or confuse Node.
func claudeCodeEnvironment() -> [String: String] {
    let parent = ProcessInfo.processInfo.environment
    var env: [String: String] = [:]
    for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL", "SSH_AUTH_SOCK"] {
        if let v = parent[key] { env[key] = v }
    }
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
    return env
}

/// Scratch cwd so claude doesn't scan the app bundle for CLAUDE.md / git state.
func claudeCodeScratchDir(_ name: String = "MyTypeClaude") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Bridge `FileHandle.readabilityHandler` into an AsyncStream of
/// `\n`-delimited lines. `FileHandle.bytes.lines` buffers subprocess
/// pipes until EOF on macOS, so we can't use it.
///
/// Shared by `AIProvider.streamClaudeCode` and `ClaudeCodeVoicePolishSession`.
func makeLineStream(from handle: FileHandle, label: String = "line-splitter") -> AsyncStream<String> {
    AsyncStream(bufferingPolicy: .unbounded) { continuation in
        let queue = DispatchQueue(label: "claude.\(label)")
        let buffer = SubprocessLineBuffer()
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                queue.async {
                    if let tail = buffer.drainTail() { continuation.yield(tail) }
                    continuation.finish()
                }
                h.readabilityHandler = nil
                return
            }
            queue.async {
                for line in buffer.append(data) { continuation.yield(line) }
            }
        }
        continuation.onTermination = { _ in handle.readabilityHandler = nil }
    }
}

/// Accumulates raw bytes from a pipe, splits on `\n`, emits complete lines.
final class SubprocessLineBuffer: @unchecked Sendable {
    private var bytes = Data()
    func append(_ data: Data) -> [String] {
        bytes.append(data)
        var lines: [String] = []
        while let nl = bytes.firstIndex(of: 0x0A) {
            let lineData = bytes[..<nl]
            bytes.removeSubrange(...nl)
            if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
        }
        return lines
    }
    func drainTail() -> String? {
        guard !bytes.isEmpty else { return nil }
        defer { bytes.removeAll() }
        return String(data: bytes, encoding: .utf8)
    }
}
