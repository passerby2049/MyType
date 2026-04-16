// Abstract:
// Google AI Studio (Gemini) streaming implementation.

import Foundation

extension AIProvider {

    // MARK: - Google AI Studio (Gemini) Streaming

    static func streamGoogleAI(
        prompt: String,
        model: String,
        temperature: Double? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var keys = prefs.googleAIKeys
                guard !keys.isEmpty else {
                    continuation.finish(throwing: NSError(
                        domain: "GoogleAI", code: -1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "No Google AI Studio key configured. " +
                            "Add one in Settings → Google AI Studio."]
                    ))
                    return
                }
                // Start from the last known-good key (if any), else from
                // list order. On 429 we rotate to the next key for this
                // request only — no cooldown state.
                if let hintID = lastGoodGoogleKey.withLock({ $0 }),
                   let idx = keys.firstIndex(where: { $0.id == hintID }),
                   idx != 0 {
                    keys.swapAt(0, idx)
                }

                for entry in keys {
                    let urlStr = "\(googleAIBase.absoluteString)"
                        + "/models/\(model)"
                        + ":streamGenerateContent?alt=sse"
                    guard let url = URL(string: urlStr) else {
                        continuation.finish(throwing: NSError(
                            domain: "GoogleAI", code: -1,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Invalid URL for model \(model)"]
                        ))
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(entry.key, forHTTPHeaderField: "x-goog-api-key")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    var body: [String: Any] = [
                        "contents": [
                            ["role": "user", "parts": [["text": prompt]]]
                        ]
                    ]
                    if let temperature {
                        body["generationConfig"] = [
                            "temperature": max(0.0, min(2.0, temperature))
                        ]
                    }
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                    do {
                        let (bytes, response) = try await streamingSession.bytes(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                            // 429: rotate without reading the body — we're
                            // not going to surface the error if another
                            // key works.
                            if http.statusCode == 429 {
                                continue
                            }
                            var responseBody = ""
                            for try await line in bytes.lines { responseBody += line }
                            let message = errorMessage(from: responseBody)
                                ?? "HTTP \(http.statusCode)"
                            continuation.finish(throwing: NSError(
                                domain: "GoogleAI", code: http.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            ))
                            return
                        }
                        // HTTP 200 — this key is working. Remember it so
                        // subsequent requests skip re-probing dead keys.
                        lastGoodGoogleKey.withLock { $0 = entry.id }
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            guard let data = payload.data(using: .utf8),
                                  let json = try? JSONSerialization
                                      .jsonObject(with: data) as? [String: Any]
                            else { continue }

                            if let error = json["error"] as? [String: Any],
                               let message = error["message"] as? String {
                                // Mid-stream error — can't cleanly restart a
                                // partially-yielded stream on another key,
                                // so surface it to the caller.
                                continuation.finish(throwing: NSError(
                                    domain: "GoogleAI", code: 400,
                                    userInfo: [NSLocalizedDescriptionKey: message]
                                ))
                                return
                            }

                            guard let candidates = json["candidates"] as? [[String: Any]],
                                  let content = candidates.first?["content"] as? [String: Any],
                                  let parts = content["parts"] as? [[String: Any]]
                            else { continue }

                            for part in parts {
                                if let text = part["text"] as? String, !text.isEmpty {
                                    continuation.yield(text)
                                }
                            }
                        }
                        continuation.finish()
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                // Every key returned 429.
                continuation.finish(throwing: NSError(
                    domain: "GoogleAI", code: 429,
                    userInfo: [NSLocalizedDescriptionKey:
                        "All \(keys.count) Google AI Studio key(s) returned 429. " +
                        "Add more keys in Settings → Google AI Studio, " +
                        "or switch to a different provider."]
                ))
            }
        }
    }
}
