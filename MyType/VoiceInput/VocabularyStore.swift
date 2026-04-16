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

/// A vocabulary term with optional weight.
struct VocabularyTerm: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var weight: Double  // 0.0 - 1.0, higher = more emphasis
    var source: VocabularyTermSource
    var createdAt: Date

    init(
        id: UUID = UUID(),
        term: String,
        weight: Double = 1.0,
        source: VocabularyTermSource = .manual,
        createdAt: Date = .now
    ) {
        self.id = id
        self.term = term
        self.weight = weight
        self.source = source
        self.createdAt = createdAt
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
    func add(_ term: String, weight: Double = 1.0) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Avoid duplicates
        if terms.contains(where: {
            $0.term.lowercased() == trimmed.lowercased()
        }) { return }

        terms.append(VocabularyTerm(term: trimmed, weight: weight))
        save()
    }

    /// Remove a term by ID.
    func remove(_ id: UUID) {
        terms.removeAll { $0.id == id }
        save()
    }

    /// Update an existing term.
    func update(_ id: UUID, term: String? = nil, weight: Double? = nil) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        if let term {
            terms[index].term = term
        }
        if let weight {
            terms[index].weight = weight
        }
        save()
    }

    /// Generate the XML hints string for STT engines.
    /// Format follows the spec's vocabulary_hints structure.
    func generateHints() -> String {
        guard !terms.isEmpty else { return "" }

        let termsList = terms
            .sorted { $0.weight > $1.weight }
            .map(\.term)
            .joined(separator: ", ")

        return """
        <vocabulary_hints>
        <instruction>
        Recognize these words and phrases accurately, preserving their spelling \
        and casing when possible. Do not emit any term unless it is actually \
        spoken in the audio.
        </instruction>
        <terms>
        \(termsList)
        </terms>
        </vocabulary_hints>
        """
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
