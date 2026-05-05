// Abstract:
// Streams against the local `claude-sub-api` proxy, which converts the user's
// Claude.ai or ChatGPT subscription into HTTP APIs.
// `sub-claude-*` → Anthropic Messages format on `/v1/messages`.
// `sub-gpt-*`    → OpenAI Responses format on `/v1/responses`.

import Foundation

extension AIProvider {

    static func streamSubscription(
        prompt: String,
        model: String,
        temperature: Double? = nil
    ) -> AsyncThrowingStream<String, Error> {
        let bare = String(model.dropFirst("sub-".count))
        if bare.hasPrefix("gpt-") {
            return streamSubscriptionResponses(prompt: prompt, model: bare, temperature: temperature)
        }
        return streamSubscriptionMessages(prompt: prompt, model: bare, temperature: temperature)
    }

    // MARK: - Anthropic Messages via proxy

    static func streamSubscriptionMessages(
        prompt: String,
        model: String,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let url = subscriptionURL(path: "/v1/messages") else {
                    continuation.finish(throwing: NSError(
                        domain: "Subscription",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid proxy URL"]
                    ))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                // temperature is deprecated on the OAuth-Claude-Code path
                // (claude-opus-4-7 returns 400 if you send it). Omit it
                // unconditionally — `_ = temperature` keeps the parameter
                // in the public API for parity with other providers.
                _ = temperature
                let body: [String: Any] = [
                    "model": model,
                    "max_tokens": 4096,
                    "stream": true,
                    "messages": [["role": "user", "content": prompt]]
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await streamingSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var responseBody = ""
                        for try await line in bytes.lines { responseBody += line }
                        let message = errorMessage(from: responseBody) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: NSError(
                            domain: "Subscription",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        ))
                        return
                    }

                    var currentEvent = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                            if currentEvent == "message_stop" { break }
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
                                domain: "Subscription",
                                code: 400,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            ))
                            return
                        }

                        let eventType = currentEvent.isEmpty
                            ? (json["type"] as? String ?? "")
                            : currentEvent
                        if eventType == "message_stop" { break }

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

    // MARK: - OpenAI Responses via proxy

    static func streamSubscriptionResponses(
        prompt: String,
        model: String,
        temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let url = subscriptionURL(path: "/v1/responses") else {
                    continuation.finish(throwing: NSError(
                        domain: "Subscription",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid proxy URL"]
                    ))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                var body: [String: Any] = [
                    "model": model,
                    "stream": true,
                    "input": [[
                        "role": "user",
                        "content": [["type": "input_text", "text": prompt]]
                    ]]
                ]
                if let temperature {
                    body["temperature"] = max(0.0, min(2.0, temperature))
                }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await streamingSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var responseBody = ""
                        for try await line in bytes.lines { responseBody += line }
                        let message = errorMessage(from: responseBody) ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: NSError(
                            domain: "Subscription",
                            code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        ))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization
                                  .jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            continuation.finish(throwing: NSError(
                                domain: "Subscription",
                                code: 400,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            ))
                            return
                        }

                        let type = json["type"] as? String ?? ""
                        switch type {
                        case "response.output_text.delta":
                            if let delta = json["delta"] as? String, !delta.isEmpty {
                                continuation.yield(delta)
                            }
                        case "response.completed", "response.done":
                            break
                        default:
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

    // MARK: - URL helpers

    private static func subscriptionURL(path: String) -> URL? {
        let raw = prefs.subscriptionProxyURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty, let base = URL(string: raw) else { return nil }
        return base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}
