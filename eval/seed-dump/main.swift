// seed-dump <language> <vocabulary.json> — prints the polish system prompt MyType's warm Claude Code session runs with.
import Foundation
let a = CommandLine.arguments
let terms = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[2])))) as? [[String: Any]] ?? [])
    .compactMap { $0["term"] as? String }
print(LLMRewriter.buildSystemPrompt(language: VoiceInputLanguage(rawValue: a[1]) ?? .auto, vocabularyTerms: terms))
