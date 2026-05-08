// Abstract:
// Statistics window — shows speaking time, total characters, and a
// per-language breakdown across configurable time ranges.

import SwiftUI

struct VoiceInputStatsView: View {
    private var store = VoiceInputStore.shared

    @State private var range: StatsRange = .allTime

    private var stats: VoiceInputStats {
        VoiceInputStats.compute(records: store.records, since: range.cutoff)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rangeSelector

                if stats.recordingCount == 0 {
                    ContentUnavailableView(
                        "No Data Yet",
                        systemImage: "chart.bar.xaxis",
                        description: Text("Records in this range will show up here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    timeSavedCard
                    overviewGrid
                    languageSection
                    if stats.totalDuration > 0 {
                        Text(paceSummary)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: - Range selector (native Liquid Glass segmented picker)

    private var rangeSelector: some View {
        Picker("Range", selection: $range) {
            ForEach(StatsRange.allCases) { r in
                Text(r.title).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Time saved hero

    private var timeSavedCard: some View {
        let saved = stats.timeSaved
        let positive = saved > 0
        return GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        positive ? "Time Saved vs Typing" : "Speaking Wasn't Faster",
                        systemImage: positive ? "bolt.fill" : "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(positive ? Color.yellow : .secondary)

                    Text(formatDurationLong(abs(saved)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)

                    Text(savedFootnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private var savedFootnote: String {
        let typing = formatDurationLong(stats.estimatedTypingDuration)
        let spoken = formatDurationLong(stats.totalDuration)
        return "Estimated typing: \(typing) · spoken: \(spoken). Assumes 中文 60 / English 200 chars/min."
    }

    // MARK: - Overview cards

    private var overviewGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            statCard(
                title: "Recordings",
                value: "\(stats.recordingCount)",
                systemImage: "mic.fill",
                tint: .blue
            )
            statCard(
                title: "Speaking Time",
                value: formatDuration(stats.totalDuration),
                systemImage: "clock",
                tint: .orange
            )
            statCard(
                title: "Total Characters",
                value: stats.totalChars.formatted(),
                systemImage: "text.alignleft",
                tint: .green
            )
        }
    }

    // MARK: - Per-language section

    private var languageSection: some View {
        let entries = stats.languagesByDuration
        let totalDuration = max(stats.totalDuration, 0.0001)
        return VStack(alignment: .leading, spacing: 10) {
            Text("By Language")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(spacing: 12) {
                    ForEach(entries, id: \.0) { key, bucket in
                        languageRow(
                            key: key,
                            bucket: bucket,
                            fraction: bucket.duration / totalDuration
                        )
                    }
                }
                .padding(8)
            }
        }
    }

    private func languageRow(
        key: LanguageKey,
        bucket: LanguageStats,
        fraction: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(key.displayName, systemImage: key.flagSymbol)
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(bucket.recordingCount) recs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Text(formatDuration(bucket.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("\(bucket.chars.formatted()) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            ProgressView(value: fraction.isFinite ? min(max(fraction, 0), 1) : 0)
                .tint(.blue)
        }
    }

    private var paceSummary: String {
        let charsPerMinute = Double(stats.totalChars) / (stats.totalDuration / 60)
        return String(
            format: "≈ %.0f characters per minute of speech",
            charsPerMinute
        )
    }

    // MARK: - Components

    private func statCard(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        }
        return String(format: "%.1fs", duration)
    }

    /// Same shape as `formatDuration` but tuned for the hero card —
    /// prefers larger units and rounds away the noisy fractional second.
    private func formatDurationLong(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

// MARK: - Range

private enum StatsRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 Days"
        case .month: "30 Days"
        case .allTime: "All Time"
        }
    }

    var cutoff: Date? {
        let now = Date()
        let calendar = Calendar.current
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .month:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .allTime:
            return nil
        }
    }
}
