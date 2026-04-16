// Abstract:
// Utilities for extracting typed data from LLM responses that may
// be wrapped in markdown code fences.

import Foundation

// MARK: - LLM Response Parsing

/// Extract and decode a JSON array from an LLM response that may be wrapped in markdown fences.
func parseLLMJSON<T: Decodable>(_ raw: String) -> [T]? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "["), let e = jsonStr.lastIndex(of: "]") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode([T].self, from: data)
}

/// Extract and decode a JSON object from an LLM response that may be wrapped in markdown fences.
func parseLLMJSONObject<T: Decodable>(_ raw: String) -> T? {
    var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if jsonStr.hasPrefix("```") {
        if let s = jsonStr.firstIndex(of: "\n"), let e = jsonStr.lastIndex(of: "`") {
            let after = jsonStr.index(after: s)
            if after < e {
                jsonStr = String(jsonStr[after..<e])
                while jsonStr.hasSuffix("`") { jsonStr.removeLast() }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
    if let s = jsonStr.firstIndex(of: "{"), let e = jsonStr.lastIndex(of: "}") {
        jsonStr = String(jsonStr[s...e])
    }
    guard let data = jsonStr.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
