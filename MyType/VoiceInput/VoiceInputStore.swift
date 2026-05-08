// Abstract:
// Persistent storage for voice input records — independent of StoryStore.
// Data lives under ~/Library/Application Support/MyType/VoiceInput/

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputStore"
)

@MainActor @Observable
final class VoiceInputStore {
    static let shared = VoiceInputStore()
    static let saveHistoryKey = "voiceInputSaveHistory"
    static let historyRetentionDaysKey = "voiceInputHistoryRetentionDays"

    private(set) var records: [VoiceInputRecord] = []

    // MARK: - Directories

    // These are pure path computations — no main-actor state is touched
    // inside the initializers — so we mark them `nonisolated` to let the
    // background save task read `historyFile` without tripping Swift 6's
    // "main actor-isolated static property accessed from outside" error.

    /// Root directory: ~/Library/Application Support/MyType/VoiceInput/
    nonisolated static let baseDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appending(path: "MyType")
            .appending(path: "VoiceInput")
    }()

    /// Audio files directory: .../VoiceInput/audio/
    nonisolated static let audioDirectory: URL = {
        baseDirectory.appending(path: "audio")
    }()

    /// History JSON file: .../VoiceInput/history.json
    nonisolated private static let historyFile: URL = {
        baseDirectory.appending(path: "history.json")
    }()

    // MARK: - Init

    private init() {
        ensureDirectories()
        load()
    }

    // MARK: - Public API

    static var isHistoryEnabled: Bool {
        if UserDefaults.standard.object(forKey: saveHistoryKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: saveHistoryKey)
    }

    /// Add a new record and persist immediately.
    func add(_ record: VoiceInputRecord) {
        records.insert(record, at: 0) // Newest first
        pruneRecords()
        save()
        logger.info("Added voice input record: \(record.id)")
    }

    /// Mutate an existing record in place and persist. No-op if the id
    /// no longer exists (e.g. the user deleted it while the late LLM
    /// polish was still flying in).
    func update(_ id: UUID, mutate: (inout VoiceInputRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        save()
        logger.info("Updated voice input record: \(id)")
    }

    /// Delete a record by ID, removing its audio file too.
    func delete(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[index]
        // Remove audio file
        let audioURL = Self.audioDirectory.appending(path: record.audioFileName)
        try? FileManager.default.removeItem(at: audioURL)
        records.remove(at: index)
        save()
        logger.info("Deleted voice input record: \(id)")
    }

    /// Delete all records and their audio files.
    func deleteAll() {
        let removed = records
        records.removeAll()
        for record in removed {
            let audioURL = Self.audioDirectory.appending(path: record.audioFileName)
            try? FileManager.default.removeItem(at: audioURL)
        }
        save()
        logger.info("Deleted all voice input records: \(removed.count)")
    }

    /// Full path to a record's audio file.
    func audioURL(for record: VoiceInputRecord) -> URL {
        Self.audioDirectory.appending(path: record.audioFileName)
    }

    /// Generate a unique audio file name for a new recording.
    static func newAudioFileName(id: UUID = UUID()) -> String {
        "\(id.uuidString).m4a"
    }

    /// Full path for a new recording file.
    static func newAudioFileURL(id: UUID = UUID()) -> URL {
        audioDirectory.appending(path: newAudioFileName(id: id))
    }

    // MARK: - Persistence

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: Self.baseDirectory,
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: Self.audioDirectory,
            withIntermediateDirectories: true
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.historyFile) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([VoiceInputRecord].self, from: data)
            let loadedCount = records.count
            pruneRecords()
            if records.count != loadedCount {
                save()
            }
            logger.info("Loaded \(self.records.count) voice input records")
        } catch {
            logger.error("Failed to load voice input history: \(error)")
        }
    }

    private func save() {
        let records = self.records
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(records)
                try data.write(to: Self.historyFile, options: .atomic)
            } catch {
                logger.error("Failed to save voice input history: \(error)")
            }
        }
    }

    private func pruneRecords() {
        let retentionDays = UserDefaults.standard.integer(forKey: Self.historyRetentionDaysKey)
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: .now)
        else { return }

        var kept: [VoiceInputRecord] = []
        var removed: [VoiceInputRecord] = []

        for record in records {
            if record.createdAt < cutoff {
                removed.append(record)
            } else {
                kept.append(record)
            }
        }

        guard !removed.isEmpty else { return }

        records = kept
        for record in removed {
            let audioURL = Self.audioDirectory.appending(path: record.audioFileName)
            try? FileManager.default.removeItem(at: audioURL)
        }
        logger.info("Pruned \(removed.count) voice input records")
    }
}
