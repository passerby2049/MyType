// Abstract:
// OpenRouter (OpenAI-compatible) streaming implementation.

import Foundation

extension AIProvider {

    // MARK: - OpenRouter Streaming (OpenAI-compatible)

    static func streamOpenRouter(
        prompt: String,
        model: String,
        temperature: Double? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var request = URLRequest(
                    url: openRouterBase.appendingPathComponent("chat/completions")
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(openRouterKey)", forHTTPHeaderField: "Authorization")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                var body: [String: Any] = [
                    "model": model,
                    "messages": [["role": "user", "content": prompt]],
                    "stream": true
                ]
                if let temperature {
                    body["temperature"] = temperature
                }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await streamingSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var responseBody = ""
                        for try await line in bytes.lines { responseBody += line }
                        let message = errorMessage(from: responseBody) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: NSError(
                            domain: "OpenRouter",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        ))
                        return
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else {
                            if line.contains("\"error\""),
                               let message = errorMessage(from: line) {
                                continuation.finish(throwing: NSError(
                                    domain: "OpenRouter",
                                    code: 400,
                                    userInfo: [NSLocalizedDescriptionKey: message]
                                ))
                                return
                            }
                            continue
                        }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization
                                  .jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            continuation.finish(throwing: NSError(
                                domain: "OpenRouter",
                                code: 400,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            ))
                            return
                        }

                        guard let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any]
                        else { continue }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(content)
                        }

                        if let finish = choices.first?["finish_reason"] as? String,
                           !finish.isEmpty {
                            break
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
