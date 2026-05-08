// Abstract:
// Voice input history view — standalone window showing all past
// voice input records with audio playback and text preview.

import AVFoundation
import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputHistoryView"
)

struct VoiceInputHistoryView: View {
    private var store = VoiceInputStore.shared

    @State private var selectedRecord: VoiceInputRecord?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingID: UUID?
    @State private var searchText = ""
    @State private var filter: VoiceInputHistoryFilter = .all
    @State private var isReinserting = false

    private var filteredRecords: [VoiceInputRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records.filter { record in
            filter.includes(record)
                && (
                    query.isEmpty
                    || record.text.localizedStandardContains(query)
                    || record.rawTranscript.localizedStandardContains(query)
                    || (record.targetApp?.localizedStandardContains(query) ?? false)
                )
        }
    }

    var body: some View {
        NavigationSplitView {
            recordsList
        } detail: {
            if let record = selectedRecord {
                recordDetail(record)
            } else {
                ContentUnavailableView(
                    "Select a Record",
                    systemImage: "waveform",
                    description: Text("Choose a voice input record to view details.")
                )
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .searchable(text: $searchText, prompt: "Search transcripts...")
    }

    // MARK: - Records List

    private var recordsList: some View {
        VStack(spacing: 0) {
            filterMenu

            List(filteredRecords, selection: $selectedRecord) { record in
                VoiceInputRecordRow(
                    record: record,
                    isPlaying: playingID == record.id
                )
                .tag(record)
                .contextMenu {
                    Button("Copy Text", action: { copyToClipboard(record.text) })
                    Button("Delete", role: .destructive) {
                        delete(record)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 250)
        .overlay {
            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    store.records.isEmpty ? "No Records Yet" : "No Matching Records",
                    systemImage: "mic.badge.plus",
                    description: Text(store.records.isEmpty ? "Press fn (Globe) to start voice input." : "Try a different search or filter.")
                )
            }
        }
    }

    private var filterMenu: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(VoiceInputHistoryFilter.allCases) { option in
                    Button {
                        filter = option
                    } label: {
                        Label(option.title, systemImage: option == filter ? "checkmark" : option.iconName)
                    }
                }
            } label: {
                Label(filter.title, systemImage: filter.iconName)
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 8)

            Text("\(filteredRecords.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: - Record Detail

    private func recordDetail(_ record: VoiceInputRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.createdAt, format: .dateTime)
                            .font(.title3.bold())

                        HStack(spacing: 8) {
                            if let app = record.targetApp {
                                Label(app, systemImage: "app")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Label(
                                formatDuration(record.duration),
                                systemImage: "clock"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Label(
                                record.language,
                                systemImage: "globe"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if let modeLabel = polishModeLabel(record) {
                                Label(modeLabel, systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                            } else if record.wasRewritten {
                                Label("Rewritten", systemImage: "wand.and.stars")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                            }

                            if let status = record.insertStatus {
                                Label(status.displayName, systemImage: insertStatusIcon(status))
                                    .font(.caption)
                                    .foregroundStyle(insertStatusColor(status))
                            }
                        }

                        // Processing times
                        if record.transcriptionTime != nil || record.llmPolishTime != nil {
                            HStack(spacing: 12) {
                                if let stt = record.transcriptionTime {
                                    Label("STT \(formatLatency(stt))", systemImage: "waveform")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if let llm = record.llmPolishTime {
                                    let modelLabel = record.llmModel ?? "LLM"
                                    Label("\(modelLabel) \(formatLatency(llm))", systemImage: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        if let errorCode = record.errorCode {
                            Label(errorCode, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer()

                    // Playback button
                    Button {
                        togglePlayback(for: record)
                    } label: {
                        Image(systemName: playingID == record.id ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playingID == record.id ? "Stop playback" : "Play recording")
                }

                Divider()

                // Changes (Diff) — only when raw != final
                if record.rawTranscript != record.text, !record.rawTranscript.isEmpty {
                    sectionHeader("Changes")
                    GroupBox {
                        TextDiffView(
                            original: record.rawTranscript,
                            modified: record.text
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                } else if !record.rawTranscript.isEmpty {
                    Text("✓ No corrections")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Final Text
                sectionWithCopy("Final Text", text: record.text)

                // Raw Transcript
                if !record.rawTranscript.isEmpty {
                    sectionWithCopy("Raw Transcript", text: record.rawTranscript, muted: true)
                }

                if let vocabularyHitCount = record.vocabularyHitCount, vocabularyHitCount > 0 {
                    Label("\(vocabularyHitCount) vocabulary hits", systemImage: "character.book.closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Delete
                HStack {
                    Button("Insert Again", systemImage: "text.cursor") {
                        reinsert(record)
                    }
                    .disabled(isReinserting)

                    Button("Copy Final", systemImage: "doc.on.doc") {
                        copyToClipboard(record.text)
                    }

                    Spacer()
                    Button("Delete", role: .destructive) {
                        delete(record)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Section Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func sectionWithCopy(_ title: String, text: String, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    copyToClipboard(text)
                }
                .font(.caption)
                .foregroundStyle(.blue)
                .buttonStyle(.plain)
            }
            GroupBox {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(muted ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    // MARK: - Playback

    private func togglePlayback(for record: VoiceInputRecord) {
        if playingID == record.id {
            stopPlayback()
            return
        }

        stopPlayback()

        let url = store.audioURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            audioPlayer = player
            playingID = record.id

            // Auto-stop when done
            Task {
                while let player = audioPlayer, player.isPlaying {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if playingID == record.id {
                    playingID = nil
                }
            }
        } catch {
            logger.error("Failed to play recording \(record.id): \(error)")
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingID = nil
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func delete(_ record: VoiceInputRecord) {
        stopPlayback()
        store.delete(record.id)
        if selectedRecord?.id == record.id {
            selectedRecord = nil
        }
    }

    private func reinsert(_ record: VoiceInputRecord) {
        guard let targetName = record.targetApp,
              let targetApp = NSWorkspace.shared.runningApplications.first(where: {
                  $0.localizedName == targetName
              })
        else {
            copyToClipboard(record.text)
            return
        }

        isReinserting = true
        Task { @MainActor in
            _ = await TextInjector.inject(
                record.text,
                targetPID: targetApp.processIdentifier,
                targetName: targetName
            )
            isReinserting = false
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
    }

    /// Label for the polish-mode badge. Reads the new `polishMode` field
    /// when present, falls back to the legacy `lightPolished` bool for
    /// pre-mode records (true → "Light Polish").
    private func polishModeLabel(_ record: VoiceInputRecord) -> String? {
        if let raw = record.polishMode, let mode = LLMRewriter.PolishMode(rawValue: raw) {
            return mode == .strict ? nil : "\(mode.displayName) Polish"
        }
        return record.lightPolished == true ? "Light Polish" : nil
    }

    /// Latency for STT / LLM rows. Sub-second values get higher precision
    /// so a fast cached/skipped polish doesn't render as "0.0s".
    private func formatLatency(_ duration: TimeInterval) -> String {
        if duration < 0.1 {
            return String(format: "%.0fms", duration * 1000)
        }
        if duration < 10 {
            return String(format: "%.2fs", duration)
        }
        return String(format: "%.1fs", duration)
    }

    private func insertStatusIcon(_ status: VoiceInputInsertStatus) -> String {
        switch status {
        case .inserted: "text.cursor"
        case .copiedFallback: "doc.on.clipboard"
        case .failed: "xmark.octagon"
        }
    }

    private func insertStatusColor(_ status: VoiceInputInsertStatus) -> Color {
        switch status {
        case .inserted: .green
        case .copiedFallback: .orange
        case .failed: .red
        }
    }
}

// MARK: - Record Row

private struct VoiceInputRecordRow: View {
    let record: VoiceInputRecord
    let isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.text)
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(isPlaying ? .blue : .primary)

            HStack(spacing: 6) {
                Text(record.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let app = record.targetApp {
                    Text("→ \(app)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let status = record.insertStatus, status != .inserted {
                    Text(status.displayName)
                        .font(.caption2)
                        .foregroundStyle(status == .failed ? .red : .orange)
                }

                Spacer()

                Text(String(format: "%.0fs", record.duration))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// Make VoiceInputRecord Hashable so it can be used with List selection
extension VoiceInputRecord: Hashable {
    static func == (lhs: VoiceInputRecord, rhs: VoiceInputRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private enum VoiceInputHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case rewritten
    case copied
    case failed
    case vocabulary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .rewritten: "Rewritten"
        case .copied: "Copied"
        case .failed: "Failed"
        case .vocabulary: "Vocab"
        }
    }

    var iconName: String {
        switch self {
        case .all: "tray.full"
        case .rewritten: "sparkles"
        case .copied: "doc.on.clipboard"
        case .failed: "exclamationmark.triangle"
        case .vocabulary: "character.book.closed"
        }
    }

    func includes(_ record: VoiceInputRecord) -> Bool {
        switch self {
        case .all:
            true
        case .rewritten:
            record.wasRewritten
        case .copied:
            record.insertStatus == .copiedFallback
        case .failed:
            record.insertStatus == .failed || record.errorCode != nil
        case .vocabulary:
            (record.vocabularyHitCount ?? 0) > 0
        }
    }
}
