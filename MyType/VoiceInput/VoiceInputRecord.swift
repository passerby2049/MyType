// Abstract:
// Data model for voice input records — independent of the Story model.

import Foundation

enum VoiceInputInsertStatus: String, Codable, CaseIterable {
    case inserted
    case copiedFallback
    case failed

    var displayName: String {
        switch self {
        case .inserted: "Inserted"
        case .copiedFallback: "Copied"
        case .failed: "Failed"
        }
    }
}

/// What came of looking up what a dictation was sent as (`VoiceLog`).
enum VoiceInputSentLookup: String, Codable {
    /// Found in what was sent (Claude Code, Otto's chat); `sentText` holds it.
    case found
    /// Went to an app we can look in, but nothing sent in the next 15 minutes has it.
    case notFound
    /// Went to an app with nothing to look in (WeChat, Notes…).
    case noSource
}

/// A single voice input record, completely decoupled from Story.
struct VoiceInputRecord: Codable, Identifiable {
    let id: UUID
    var text: String              // Final text (after rewrite or raw)
    let rawTranscript: String     // Raw transcript (before rewrite)
    let audioFileName: String     // Audio file name (relative path under audio/)
    let language: String          // Detected language
    let duration: TimeInterval    // Recording duration in seconds
    let targetApp: String?        // Name of the app text was injected into
    let insertStatus: VoiceInputInsertStatus?
    var errorCode: String?
    let vocabularyHitCount: Int?
    let createdAt: Date
    var wasRewritten: Bool        // Whether LLM rewrite was applied
    let lightPolished: Bool?      // Legacy: kept for old-record compat. New writes mirror polishMode != "strict".
    let polishMode: String?       // "strict" / "light" / "medium" (nil = old records)
    let transcriptionTime: TimeInterval?  // Seconds spent on STT
    var llmPolishTime: TimeInterval?      // Seconds spent on LLM polish
    let llmModel: String?                 // Model used for LLM polish (e.g. "cc-opus")
    var sentLookup: VoiceInputSentLookup? = nil  // Whether what was sent was looked up (nil = not yet)
    var sentText: String? = nil           // This dictation as it was sent (Claude Code, Otto), edits included
    var sentAt: Date? = nil               // When that input was submitted

    init(
        id: UUID = UUID(),
        text: String,
        rawTranscript: String,
        audioFileName: String,
        language: String = "zh-CN",
        duration: TimeInterval,
        targetApp: String? = nil,
        insertStatus: VoiceInputInsertStatus? = nil,
        errorCode: String? = nil,
        vocabularyHitCount: Int? = nil,
        createdAt: Date = .now,
        wasRewritten: Bool = false,
        lightPolished: Bool? = nil,
        polishMode: String? = nil,
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
        self.insertStatus = insertStatus
        self.errorCode = errorCode
        self.vocabularyHitCount = vocabularyHitCount
        self.createdAt = createdAt
        self.wasRewritten = wasRewritten
        self.lightPolished = lightPolished
        self.polishMode = polishMode
        self.transcriptionTime = transcriptionTime
        self.llmPolishTime = llmPolishTime
        self.llmModel = llmModel
    }
}
