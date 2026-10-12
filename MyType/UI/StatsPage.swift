// Abstract:
// Statistics: how much was said, how much time it saved, how fast text
// appears and where that time goes, how often the result was changed before
// sending, where and in what language. Each card is one number (sometimes
// two), one chart and, where it helps, one sentence. No streaks, heat maps
// or rankings.

import Charts
import SwiftUI

struct StatsPage: View {
    private var store = VoiceInputStore.shared
    private var vocabulary = VocabularyStore.shared
    @State private var range: StatsRange = .week

    var body: some View {
        let model = StatsModel(records: store.records, range: range)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "统计", subtitle: model.subtitle) {
                    Pills(options: StatsRange.allCases.map { ($0, $0.title) }, selection: $range)
                        .padding(.top, 6)
                }
                if model.records.isEmpty {
                    EmptyState(systemImage: "chart.bar", title: "这段时间还没有记录", message: "说几句之后，这里会画出来。")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        charsCard(model)
                        savedCard(model)
                        latencyCard(model)
                        breakdownCard(model)
                        editedCard(model)
                        polishCard(model)
                        appsCard(model)
                        languagesCard(model)
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 34)
        }
    }

    // MARK: Cards

    private func charsCard(_ m: StatsModel) -> some View {
        StatCard(title: "每天说了多少", unit: "字",
                 numbers: [(m.totalChars.formatted(), "字", "合计"), ((m.totalChars / max(m.dayCount, 1)).formatted(), "字/天", "平均")]) {
            Chart(m.days) { day in
                BarMark(x: .value("日", day.date, unit: .day), y: .value("字", day.chars))
                    .foregroundStyle(Theme.accent.opacity(Calendar.current.isDateInToday(day.date) ? 1 : 0.4))
                    .cornerRadius(2.5)
            }
            .dayAxis(m)
        }
    }

    private func savedCard(_ m: StatsModel) -> some View {
        StatCard(title: "省下的时间", unit: "分钟",
                 numbers: [(formatHours(m.savedSeconds), m.savedSeconds >= 3600 ? "小时" : "分钟", "合计"),
                           (m.speedup > 0 ? String(format: "%.1f", m.speedup) : "–", "×", "说比打字快")],
                 insight: "按你的打字速度算：中文 \(Int(TypingSpeed.charsPerMinute(for: "zh"))) 字/分、英文 \(Int(TypingSpeed.charsPerMinute(for: "en")))、日文 \(Int(TypingSpeed.charsPerMinute(for: "ja")))（设置 · 通用里改）。") {
            Chart(m.days) { day in
                BarMark(x: .value("日", day.date, unit: .day), y: .value("分钟", max(day.savedSeconds, 0) / 60))
                    .foregroundStyle(Theme.green.opacity(Calendar.current.isDateInToday(day.date) ? 1 : 0.4))
                    .cornerRadius(2.5)
            }
            .dayAxis(m)
        }
    }

    private func latencyCard(_ m: StatsModel) -> some View {
        StatCard(title: "停录到出字", unit: "秒",
                 numbers: [(m.latencyP50.map { String(format: "%.1f", $0) } ?? "–", "秒", "中位数"),
                           (m.latencyP90.map { String(format: "%.1f", $0) } ?? "–", "秒", "慢的那一成")],
                 insight: m.latencyInsight) {
            Chart {
                ForEach(m.days.filter { $0.p50 != nil }) { day in
                    LineMark(x: .value("日", day.date, unit: .day), y: .value("秒", day.p50 ?? 0), series: .value("", "中位数"))
                        .foregroundStyle(Theme.blue)
                        .interpolationMethod(.monotone)
                }
                ForEach(m.days.filter { $0.p90 != nil }) { day in
                    LineMark(x: .value("日", day.date, unit: .day), y: .value("秒", day.p90 ?? 0), series: .value("", "慢的一成"))
                        .foregroundStyle(Theme.blue.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        .interpolationMethod(.monotone)
                }
            }
            .dayAxis(m)
        }
    }

    private func breakdownCard(_ m: StatsModel) -> some View {
        let current = m.weeks.last
        let previous = m.weeks.dropLast().last
        let delta = (current?.total).flatMap { c in (previous?.total).map { c - $0 } }
        return StatCard(title: "时间花在哪", unit: "每条平均 · 秒",
                        numbers: [(current.map { String(format: "%.2f", $0.total) } ?? "–", "秒", "这一周"),
                                  (delta.map { String(format: "%+.2f", $0) } ?? "–", "秒", "比上一周")],
                        numberTint: delta.map { $0 <= 0 ? Theme.green : Theme.red }) {
            Chart(m.weeks) { week in
                BarMark(x: .value("周", week.label), y: .value("秒", week.stt), width: .fixed(44)).foregroundStyle(by: .value("段", "识别"))
                BarMark(x: .value("周", week.label), y: .value("秒", week.polish), width: .fixed(44)).foregroundStyle(by: .value("段", "润色"))
                BarMark(x: .value("周", week.label), y: .value("秒", week.insert), width: .fixed(44)).foregroundStyle(by: .value("段", "键入"))
            }
            .chartForegroundStyleScale(["识别": Theme.blue, "润色": Theme.accent, "键入": Theme.green])
            .chartLegend(position: .bottom, alignment: .leading)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(Theme.small).foregroundStyle(.tertiary) }
            }
        }
    }

    private func editedCard(_ m: StatsModel) -> some View {
        StatCard(title: "发出前改过", unit: "% · 越低越好",
                 numbers: [(m.editedRate.map { "\(Int(($0 * 100).rounded()))" } ?? "–", "%", "\(m.edited) / \(m.found) 条"),
                           ("\(m.notFound + m.noSource)", "条", "没对上或没有来源")],
                 insight: m.topReplacements.isEmpty ? nil : "最常改的：" + m.topReplacements.map { "\($0.0) → \($0.1)（\($0.2) 次）" }.joined(separator: "、")) {
            Chart(m.days.filter { $0.editedRate != nil }) { day in
                LineMark(x: .value("日", day.date, unit: .day), y: .value("%", (day.editedRate ?? 0) * 100))
                    .foregroundStyle(Theme.violet)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("日", day.date, unit: .day), y: .value("%", (day.editedRate ?? 0) * 100))
                    .foregroundStyle(Theme.violet)
                    .symbolSize(14)
            }
            .dayAxis(m)
        }
    }

    private func polishCard(_ m: StatsModel) -> some View {
        StatCard(title: "润色动了多少", unit: "% 的条目被改过",
                 numbers: [(m.rewriteRate.map { "\(Int(($0 * 100).rounded()))" } ?? "–", "%", "被润色改过"),
                           ("\(m.timeouts)", "次", "没回来、键入了原文")],
                 insight: m.coldStarts > 0 ? "其中 \(m.coldStarts) 次润色会话是刚启动的（冷）。" : nil) {
            Chart(m.days.filter { $0.rewriteRate != nil }) { day in
                LineMark(x: .value("日", day.date, unit: .day), y: .value("%", (day.rewriteRate ?? 0) * 100))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
            }
            .dayAxis(m)
        }
    }

    private func appsCard(_ m: StatsModel) -> some View {
        StatCard(title: "用在哪", unit: "字") {
            ShareBars(rows: m.apps, tint: Theme.accent, unit: "字")
        }
    }

    private func languagesCard(_ m: StatsModel) -> some View {
        let top = vocabulary.terms.filter { $0.hitCount > 0 }.sorted { $0.hitCount > $1.hitCount }.prefix(3).map(\.term)
        return StatCard(title: "什么语言", unit: "条",
                        insight: m.vocabularyHits > 0
                            ? "词表命中 \(m.vocabularyHits) 次" + (top.isEmpty ? "" : "，一直以来最多的是 \(top.joined(separator: "、"))") + "。"
                            : nil) {
            ShareBars(rows: m.languages, tint: Theme.blue, unit: "条")
        }
    }

    private func formatHours(_ seconds: TimeInterval) -> String {
        seconds >= 3600 ? String(format: "%.1f", seconds / 3600) : "\(Int((seconds / 60).rounded()))"
    }
}

// MARK: - Card

private struct StatCard<ChartView: View>: View {
    let title: String
    let unit: String
    var numbers: [(String, String, String)] = []
    var numberTint: Color?
    var insight: String?
    @ViewBuilder var chart: () -> ChartView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Text(unit).font(Theme.small).foregroundStyle(.tertiary)
            }
            if !numbers.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(numbers.indices, id: \.self) { i in
                        if i > 0 { Rectangle().fill(Theme.line).frame(width: 0.5, height: 38) }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(numbers[i].0).font(Theme.bigNumber).foregroundStyle(i == 1 ? (numberTint ?? .primary) : .primary)
                                Text(numbers[i].1).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                            }
                            Text(numbers[i].2).font(Theme.small).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            chart()
                .frame(height: 110)
                .padding(.top, numbers.isEmpty ? 10 : 0)
            if let insight {
                Divider().overlay(Theme.line).padding(.top, 10)
                Text(insight)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

private struct ShareBars: View {
    let rows: [(String, Int)]
    let tint: Color
    let unit: String

    var body: some View {
        let total = max(rows.reduce(0) { $0 + $1.1 }, 1)
        VStack(spacing: 9) {
            ForEach(rows.indices, id: \.self) { i in
                let share = Double(rows[i].1) / Double(total)
                HStack(spacing: 10) {
                    Text(rows[i].0).font(.system(size: 12.5, design: .rounded)).lineLimit(1).frame(width: 64, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hover)
                            Capsule().fill(tint.opacity(max(0.35, 1 - Double(i) * 0.2))).frame(width: max(4, geo.size.width * share))
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int((share * 100).rounded()))% · \(rows[i].1.formatted()) \(unit)")
                        .font(.system(size: 11.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 112, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    /// Three date labels (first, middle, last day), no grid noise.
    func dayAxis(_ m: StatsModel) -> some View {
        chartYAxis(.hidden)
            .chartXScale(domain: m.firstDay...m.domainEnd)
            .chartXAxis {
                AxisMarks(values: m.axisDays) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Calendar.current.isDateInToday(date) ? "今天" : DayLabel.monthDay(date))
                                .font(Theme.small)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
    }
}

// MARK: - Model

private enum StatsRange: String, CaseIterable {
    case week, twoWeeks, month, all

    var title: String {
        switch self {
        case .week: "7 天"
        case .twoWeeks: "14 天"
        case .month: "30 天"
        case .all: "全部"
        }
    }

    var days: Int? {
        switch self {
        case .week: 7
        case .twoWeeks: 14
        case .month: 30
        case .all: nil
        }
    }
}

private struct DayStats: Identifiable {
    let date: Date
    var chars = 0
    var savedSeconds: TimeInterval = 0
    var p50: Double?
    var p90: Double?
    var editedRate: Double?
    var rewriteRate: Double?
    var id: Date { date }
}

private struct WeekStats: Identifiable {
    let label: String
    let stt: Double
    let polish: Double
    let insert: Double
    var total: Double { stt + polish + insert }
    var id: String { label }
}

private struct StatsModel {
    let records: [VoiceInputRecord]
    let days: [DayStats]
    let weeks: [WeekStats]
    let firstDay: Date
    let lastDay: Date
    let dayCount: Int

    let totalChars: Int
    let totalDuration: TimeInterval
    let savedSeconds: TimeInterval
    let speedup: Double
    let latencyP50: Double?
    let latencyP90: Double?
    let latencyInsight: String?
    let found: Int
    let edited: Int
    let notFound: Int
    let noSource: Int
    let editedRate: Double?
    let topReplacements: [(String, String, Int)]
    let rewriteRate: Double?
    let timeouts: Int
    let coldStarts: Int
    let apps: [(String, Int)]
    let languages: [(String, Int)]
    let vocabularyHits: Int

    var subtitle: String {
        let minutes = Int(totalDuration / 60)
        let spoken = minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
        return "\(records.count) 条 · 录音共 \(spoken)"
    }

    /// Bars take a whole day; the scale runs to the end of today.
    var domainEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay }

    var axisDays: [Date] {
        guard dayCount > 2 else { return [firstDay, lastDay] }
        let mid = Calendar.current.date(byAdding: .day, value: dayCount / 2, to: firstDay) ?? firstDay
        return [firstDay, mid, lastDay]
    }

    init(records all: [VoiceInputRecord], range: StatsRange) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let earliest = all.map(\.createdAt).min().map { cal.startOfDay(for: $0) } ?? today
        let first = range.days.flatMap { cal.date(byAdding: .day, value: -($0 - 1), to: today) } ?? earliest
        firstDay = first
        lastDay = today
        dayCount = (cal.dateComponents([.day], from: first, to: today).day ?? 0) + 1
        records = all.filter { $0.createdAt >= first }

        func saved(_ r: VoiceInputRecord) -> TimeInterval {
            Double(r.text.count) / TypingSpeed.charsPerMinute(for: LanguageKey(locale: r.language).raw) * 60 - r.duration
        }
        func percentile(_ values: [Double], _ p: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }

        var byDay: [Date: [VoiceInputRecord]] = [:]
        for r in records { byDay[cal.startOfDay(for: r.createdAt), default: []].append(r) }
        days = (0..<dayCount).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: first) else { return nil }
            let rs = byDay[date] ?? []
            var d = DayStats(date: date)
            d.chars = rs.reduce(0) { $0 + $1.text.count }
            d.savedSeconds = rs.reduce(0) { $0 + saved($1) }
            let lat = rs.compactMap(\.totalLatency)
            d.p50 = percentile(lat, 0.5)
            d.p90 = lat.count >= 4 ? percentile(lat, 0.9) : nil
            let found = rs.filter { $0.sentLookup == .found }
            d.editedRate = found.count >= 2 ? Double(found.filter(\.wasEditedBeforeSending).count) / Double(found.count) : nil
            let polished = rs.filter { $0.llmModel != nil }
            d.rewriteRate = polished.count >= 2 ? Double(polished.filter(\.wasRewritten).count) / Double(polished.count) : nil
            return d
        }

        totalChars = records.reduce(0) { $0 + $1.text.count }
        totalDuration = records.reduce(0) { $0 + $1.duration }
        savedSeconds = max(records.reduce(0) { $0 + saved($1) }, 0)
        let typing = savedSeconds + totalDuration
        speedup = totalDuration > 0 ? typing / totalDuration : 0

        let latencies = records.compactMap(\.totalLatency)
        latencyP50 = percentile(latencies, 0.5)
        latencyP90 = percentile(latencies, 0.9)
        let timed = records.filter { $0.transcriptionTime != nil }
        if !timed.isEmpty {
            let stt = timed.compactMap(\.transcriptionTime).reduce(0, +) / Double(timed.count)
            let pol = timed.compactMap { $0.polishTimedOut ? nil : $0.llmPolishTime }
            let polish = pol.isEmpty ? 0 : pol.reduce(0, +) / Double(pol.count)
            let slow = polish > stt ? "润色" : "识别"
            latencyInsight = String(format: "慢在%@：识别平均 %.2f 秒，润色 %.2f 秒。", slow, stt, polish)
        } else {
            latencyInsight = nil
        }

        // Last three weeks, averages per dictation of the parts we time.
        weeks = (0..<3).reversed().compactMap { back -> WeekStats? in
            guard let end = cal.date(byAdding: .day, value: -7 * back + 1, to: today),
                  let start = cal.date(byAdding: .day, value: -7, to: end) else { return nil }
            let rs = all.filter { $0.createdAt >= start && $0.createdAt < end && $0.transcriptionTime != nil }
            guard !rs.isEmpty else { return nil }
            let n = Double(rs.count)
            let label = back == 0 ? "这一周" : (back == 1 ? "上一周" : "两周前")
            let polish = rs.compactMap { $0.polishTimedOut ? nil : $0.llmPolishTime }.reduce(0, +) / n
            let inserts = rs.compactMap(\.insertTime)
            return WeekStats(label: label,
                             stt: rs.compactMap(\.transcriptionTime).reduce(0, +) / n,
                             polish: polish,
                             insert: inserts.isEmpty ? 0 : inserts.reduce(0, +) / Double(inserts.count))
        }

        let foundRecords = records.filter { $0.sentLookup == .found }
        found = foundRecords.count
        let editedRecords = foundRecords.filter(\.wasEditedBeforeSending)
        edited = editedRecords.count
        notFound = records.filter { $0.sentLookup == .notFound }.count
        noSource = records.filter { $0.sentLookup == .noSource }.count
        editedRate = found > 0 ? Double(edited) / Double(found) : nil
        var counts: [String: (String, String, Int)] = [:]
        for r in editedRecords {
            for (old, new) in TextDiff.replacements(from: r.text, to: r.sentText ?? "") {
                let key = old + "→" + new
                counts[key] = (old, new, (counts[key]?.2 ?? 0) + 1)
            }
        }
        topReplacements = counts.values.filter { $0.2 >= 2 }.sorted { $0.2 > $1.2 }.prefix(3).map { $0 }

        let polished = records.filter { $0.llmModel != nil }
        rewriteRate = polished.isEmpty ? nil : Double(polished.filter(\.wasRewritten).count) / Double(polished.count)
        timeouts = records.filter(\.polishTimedOut).count
        coldStarts = records.filter { $0.polishCold == true }.count

        var appChars: [String: Int] = [:]
        for r in records { appChars[r.targetApp ?? "其他", default: 0] += r.text.count }
        let sortedApps = appChars.sorted { $0.value > $1.value }
        var appRows = Array(sortedApps.prefix(4)).map { ($0.key, $0.value) }
        let rest = sortedApps.dropFirst(4).reduce(0) { $0 + $1.value }
        if rest > 0 { appRows.append(("其他", rest)) }
        apps = appRows

        var langCounts: [String: Int] = [:]
        for r in records { langCounts[LanguageKey(locale: r.language).displayName, default: 0] += 1 }
        languages = langCounts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        vocabularyHits = records.reduce(0) { $0 + ($1.vocabularyHitCount ?? 0) }
    }
}
