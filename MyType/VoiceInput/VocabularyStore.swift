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
    var enabled: Bool
    var hitCount: Int
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        term: String,
        source: VocabularyTermSource = .manual,
        enabled: Bool = true,
        hitCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.term = term
        self.source = source
        self.enabled = enabled
        self.hitCount = hitCount
        self.lastUsedAt = lastUsedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case term
        case source
        case enabled
        case hitCount
        case lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        term = try container.decode(String.self, forKey: .term)
        source = try container.decodeIfPresent(VocabularyTermSource.self, forKey: .source) ?? .manual
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hitCount = try container.decodeIfPresent(Int.self, forKey: .hitCount) ?? 0
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

@MainActor @Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var terms: [VocabularyTerm] = []

    var enabledTerms: [VocabularyTerm] {
        terms.filter(\.enabled)
    }

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

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[index].enabled = enabled
        save()
    }

    /// Remove a term by ID.
    func remove(_ id: UUID) {
        terms.removeAll { $0.id == id }
        save()
    }

    /// Count enabled vocabulary terms in the final output and update
    /// per-term usage stats. Returns total matched occurrences.
    func recordHits(in text: String) -> Int {
        guard !text.isEmpty, !terms.isEmpty else { return 0 }

        let haystack = text.lowercased()
        var total = 0
        var changed = false
        let now = Date()

        for index in terms.indices {
            guard terms[index].enabled else { continue }
            let needle = terms[index].term
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !needle.isEmpty else { continue }

            let count = Self.countOccurrences(of: needle, in: haystack)
            if count > 0 {
                terms[index].hitCount += count
                terms[index].lastUsedAt = now
                total += count
                changed = true
            }
        }

        if changed { save() }
        return total
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            // Seed with some defaults for first run
            seedDefaults()
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            terms = try decoder.decode([VocabularyTerm].self, from: data)
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
            encoder.dateEncodingStrategy = .iso8601
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

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
