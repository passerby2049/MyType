// Abstract:
// Minimal app preferences for AI provider configuration.
// UserDefaults-backed, same keys as ListenWise for data portability.

import SwiftUI

struct GoogleAIKeyEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var key: String

    init(id: UUID = UUID(), name: String, key: String) {
        self.id = id
        self.name = name
        self.key = key
    }
}

@Observable
final class AppPreferences {
    var openRouterAPIKey: String {
        get { UserDefaults.standard.string(forKey: "openRouterAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openRouterAPIKey") }
    }

    var anthropicBaseURL: String {
        get {
            UserDefaults.standard.string(forKey: "anthropicBaseURL")
                ?? "https://api.anthropic.com"
        }
        set { UserDefaults.standard.set(newValue, forKey: "anthropicBaseURL") }
    }

    var anthropicAPIKey: String {
        get { UserDefaults.standard.string(forKey: "anthropicAPIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "anthropicAPIKey") }
    }

    var googleAIKeys: [GoogleAIKeyEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "googleAIKeys"),
                  let decoded = try? JSONDecoder().decode([GoogleAIKeyEntry].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "googleAIKeys")
            }
        }
    }
}
