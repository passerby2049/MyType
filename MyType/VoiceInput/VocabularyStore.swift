// Abstract:
// Custom vocabulary store for voice input — improves STT accuracy
// for domain-specific terms, proper nouns, and abbreviations.

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VocabularyStore"
)

/// Source of a vocabulary term.
enum VocabularyTermSource: String, Codable {
    case manual     // User-added
    case automatic  // System-learned from corrections (v2)
}

struct VocabularyTerm: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var source: VocabularyTermSource

    init(
        id: UUID = UUID(),
        term: String,
        source: VocabularyTermSource = .manual
    ) {
        self.id = id
        self.term = term
        self.source = source
    }
}

@MainActor @Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var terms: [VocabularyTerm] = []

    // nonisolated so the background save Task.detached can read it
    // without a Swift 6 strict-concurrency violation.
    nonisolated private static let fileURL: URL = {
        VoiceInputStore.baseDirectory.appending(path: "vocabulary.json")
    }()

    private init() {
        load()
    }

    // MARK: - Public API

    /// Add a new term.
    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Avoid duplicates
        if terms.contains(where: {
            $0.term.lowercased() == trimmed.lowercased()
        }) { return }

        terms.append(VocabularyTerm(term: trimmed))
        save()
    }

    /// Remove a term by ID.
    func remove(_ id: UUID) {
        terms.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            // Seed with some defaults for first run
            seedDefaults()
            return
        }
        do {
            terms = try JSONDecoder().decode([VocabularyTerm].self, from: data)
            logger.info("Loaded \(self.terms.count) vocabulary terms")
        } catch {
            logger.error("Failed to load vocabulary: \(error)")
            seedDefaults()
        }
    }

    private func save() {
        let terms = self.terms
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(terms)
                try data.write(to: Self.fileURL, options: .atomic)
            } catch {
                logger.error("Failed to save vocabulary: \(error)")
            }
        }
    }

    private func seedDefaults() {
        let defaults = [
            "ListenWise", "SwiftUI", "Xcode",
            "Claude", "Karpathy",
        ]
        for term in defaults {
            terms.append(VocabularyTerm(term: term))
        }
        save()
    }
}
