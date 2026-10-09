// Abstract:
// Anthropic Messages API streaming implementation.

import Foundation

extension AIProvider {

    // MARK: - Anthropic Messages Streaming

    static func streamAnthropic(
        prompt: String,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var request = URLRequest(url: anthropicMessagesURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(anthropicKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                var body: [String: Any] = [
                    "model": model,
                    "max_tokens": 16000,
                    "stream": true,
                    "messages": [["role": "user", "content": prompt]]
                ]
                // Polish is latency-bound: low effort, as on the Claude Code
                // path. Haiku 4.5 predates effort and rejects it.
                if !model.hasPrefix("claude-haiku-4") {
                    body["output_config"] = ["effort": "low"]
                }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await streamingSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var responseBody = ""
                        for try await line in bytes.lines { responseBody += line }
                        let message = errorMessage(from: responseBody) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: NSError(
                            domain: "Anthropic",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        ))
                        return
                    }

                    var currentEvent = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            if currentEvent == "message_stop" {
                                break
                            }
                            continue
                        }

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization
                                  .jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            continuation.finish(throwing: NSError(
                                domain: "Anthropic",
                                code: 400,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            ))
                            return
                        }

                        let eventType = currentEvent.isEmpty
                            ? (json["type"] as? String ?? "")
                            : currentEvent
                        if eventType == "message_stop" {
                            break
                        }

                        // A cut-off or declined reply must not be pasted as if
                        // it were the polished text; the caller keeps the original.
                        if eventType == "message_delta",
                           let delta = json["delta"] as? [String: Any],
                           let stop = delta["stop_reason"] as? String,
                           stop == "max_tokens" || stop == "refusal" {
                            continuation.finish(throwing: NSError(
                                domain: "Anthropic",
                                code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "stop_reason \(stop)"]
                            ))
                            return
                        }

                        if eventType == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String,
                           !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
