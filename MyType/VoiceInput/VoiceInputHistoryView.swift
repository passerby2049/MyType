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

    private var filteredRecords: [VoiceInputRecord] {
        if searchText.isEmpty {
            return store.records
        }
        return store.records.filter {
            $0.text.localizedStandardContains(searchText)
                || ($0.targetApp?.localizedStandardContains(searchText) ?? false)
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
        List(filteredRecords, selection: $selectedRecord) { record in
            VoiceInputRecordRow(
                record: record,
                isPlaying: playingID == record.id
            )
            .tag(record)
            .contextMenu {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.text, forType: .string)
                }
                Button("Delete", role: .destructive) {
                    stopPlayback()
                    store.delete(record.id)
                    if selectedRecord?.id == record.id {
                        selectedRecord = nil
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 250)
        .overlay {
            if store.records.isEmpty {
                ContentUnavailableView(
                    "No Records Yet",
                    systemImage: "mic.badge.plus",
                    description: Text("Press fn (Globe) to start voice input.")
                )
            }
        }
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

                            if record.lightPolished == true {
                                Label("Light Polish", systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                            } else if record.wasRewritten {
                                Label("Rewritten", systemImage: "wand.and.stars")
                                    .font(.caption)
                                    .foregroundStyle(.purple)
                            }
                        }

                        // Processing times
                        if record.transcriptionTime != nil || record.llmPolishTime != nil {
                            HStack(spacing: 12) {
                                if let stt = record.transcriptionTime {
                                    Label(String(format: "STT %.1fs", stt), systemImage: "waveform")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if let llm = record.llmPolishTime {
                                    let modelLabel = record.llmModel ?? "LLM"
                                    Label(String(format: "%@ %.1fs", modelLabel, llm), systemImage: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
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

                // Delete
                HStack {
                    Spacer()
                    Button("Delete", role: .destructive) {
                        stopPlayback()
                        store.delete(record.id)
                        selectedRecord = nil
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
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

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
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
