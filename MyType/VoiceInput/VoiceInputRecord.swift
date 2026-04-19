// Abstract:
// Data model for voice input records — independent of the Story model.

import Foundation

/// A single voice input record, completely decoupled from Story.
struct VoiceInputRecord: Codable, Identifiable {
    let id: UUID
    var text: String              // Final text (after rewrite or raw)
    let rawTranscript: String     // Raw transcript (before rewrite)
    let audioFileName: String     // Audio file name (relative path under audio/)
    let language: String          // Detected language
    let duration: TimeInterval    // Recording duration in seconds
    let targetApp: String?        // Name of the app text was injected into
    let createdAt: Date
    var wasRewritten: Bool        // Whether LLM rewrite was applied
    let lightPolished: Bool?      // Whether light-polish mode was on (nil = old records)
    let transcriptionTime: TimeInterval?  // Seconds spent on STT
    var llmPolishTime: TimeInterval?      // Seconds spent on LLM polish
    let llmModel: String?                 // Model used for LLM polish (e.g. "cc-opus")

    init(
        id: UUID = UUID(),
        text: String,
        rawTranscript: String,
        audioFileName: String,
        language: String = "zh-CN",
        duration: TimeInterval,
        targetApp: String? = nil,
        createdAt: Date = .now,
        wasRewritten: Bool = false,
        lightPolished: Bool? = nil,
        transcriptionTime: TimeInterval? = nil,
        llmPolishTime: TimeInterval? = nil,
        llmModel: String? = nil
    ) {
        self.id = id
        self.text = text
        self.rawTranscript = rawTranscript
        self.audioFileName = audioFileName
        self.language = language
        self.duration = duration
        self.targetApp = targetApp
        self.createdAt = createdAt
        self.wasRewritten = wasRewritten
        self.lightPolished = lightPolished
        self.transcriptionTime = transcriptionTime
        self.llmPolishTime = llmPolishTime
        self.llmModel = llmModel
    }
}
