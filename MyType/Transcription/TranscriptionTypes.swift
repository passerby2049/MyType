// Abstract:
// Shared types for transcription engines.

import Foundation

struct RawTokenTiming: Codable {
    var token: String
    var startTime: Double
    var endTime: Double
}
