// Just enough of MyType for LLMRewriter+Prompt.swift to compile on its own: the seed prompt, exactly as the app builds it.
import Foundation
enum LLMRewriter {
    enum PolishMode: String { case strict, light, medium }
    static var polishMode: PolishMode = PolishMode(rawValue: ProcessInfo.processInfo.environment["MODE"] ?? "medium") ?? .medium
}
struct VocabularyTerm { let term: String }
@MainActor final class VocabularyStore {
    static let shared = VocabularyStore()
    var enabledTerms: [VocabularyTerm] = []
}
