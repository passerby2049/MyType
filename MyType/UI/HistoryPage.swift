// Abstract:
// History: a day-grouped list on the left (time in the left column, text
// with its line breaks, tags saying what came of it), one dictation in full
// on the right — polished / raw / the two compared, what was actually sent,
// the recording, and where the time went. Actions sit in the detail header.

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Shared record helpers (history, menu, statistics)

extension VoiceInputRecord {
    /// Sent (found in Claude Code / Otto) after the user changed it.
    var wasEditedBeforeSending: Bool {
        guard sentLookup == .found, let sentText else { return false }
        return sentText.trimmingCharacters(in: .whitespacesAndNewlines)
            != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polish didn't come back in time and the raw text was typed.
    var polishTimedOut: Bool { errorCode == "polishTimeout" }

    var hasProblem: Bool {
        polishTimedOut || insertStatus == .failed || insertStatus == .copiedFallback
    }

    /// Stop → typed, from the parts we measured.
    var totalLatency: TimeInterval? {
        guard let stt = transcriptionTime else { return nil }
        return stt + (polishTimedOut ? 0 : (llmPolishTime ?? 0)) + (insertTime ?? 0)
    }

    /// Short tags for a list row, most telling first.
    var tags: [(String, Tag.Tint)] {
        var tags: [(String, Tag.Tint)] = []
        if let app = targetApp { tags.append((app, .neutral)) }
        if insertStatus == .failed { tags.append(("没键入", .red)) }
        else if insertStatus == .copiedFallback { tags.append(("只复制了", .accent)) }
        if polishTimedOut { tags.append(("润色没回来", .red)) }
        if wasEditedBeforeSending { tags.append(("发出前改过", .accent)) }
        if let hits = vocabularyHitCount, hits > 0 { tags.append(("词表命中 \(hits)", .green)) }
        return tags
    }

    var languageName: String {
        switch LanguageKey(locale: language).raw {
        case "zh": "中文"
        case "en": "英文"
        case "ja": "日文"
        default: language
        }
    }
}

enum DayLabel {
    /// "10月12日".
    static func monthDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func title(for day: Date) -> String {
        let cal = Calendar.current
        let date = monthDay(day)
        if cal.isDateInToday(day) { return "今天 · \(date)" }
        if cal.isDateInYesterday(day) { return "昨天 · \(date)" }
        let weekday = day.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
        return "\(date) \(weekday)"
    }

    /// "今天 11:42" / "昨天 23:05" / "10月9日 14:02".
    static func moment(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 \(time)" }
        if cal.isDateInYesterday(date) { return "昨天 \(time)" }
        return monthDay(date) + " " + time
    }
}

/// Things done to a record from the history, the menu and the overlay.
@MainActor
enum RecordActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Type it again into the app it went to (if running), else into
    /// whatever is frontmost once our window is out of the way.
    static func retype(_ record: VoiceInputRecord) {
        let app = record.targetApp.flatMap { name in
            NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
        }
        Task { @MainActor in
            _ = await TextInjector.inject(record.text, targetPID: app?.processIdentifier, targetName: app?.localizedName)
        }
    }

    /// Polish the raw transcript again with today's settings.
    static func repolish(_ record: VoiceInputRecord) async throws {
        let started = Date()
        let polished = try await LLMRewriter.rewrite(
            rawText: DictationOptimizer.optimize(record.rawTranscript),
            language: VoiceInputLanguage.current,
            model: LLMRewriter.resolvedModel,
            vocabularyTerms: VocabularyStore.shared.enabledTerms.map(\.term),
            frontApp: record.targetApp
        )
        let elapsed = Date().timeIntervalSince(started)
        VoiceInputStore.shared.update(record.id) { rec in
            rec.text = polished
            rec.wasRewritten = polished != record.rawTranscript
            rec.llmPolishTime = elapsed
            rec.errorCode = nil
        }
    }
}

/// App icons by name, looked up once.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var url = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
        if url == nil {
            for dir in ["/Applications", "/System/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; break }
            }
        }
        if name == "Code", url == nil {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
        }
        guard let url else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[name] = image
        return image
    }
}

// MARK: - Page

struct HistoryPage: View {
    private var store = VoiceInputStore.shared
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var filter: HistoryFilter = .all

    private var filtered: [VoiceInputRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.records
            .filter { record in
                filter.includes(record) && (query.isEmpty
                    || record.text.localizedStandardContains(query)
                    || record.rawTranscript.localizedStandardContains(query)
                    || (record.sentText?.localizedStandardContains(query) ?? false)
                    || (record.targetApp?.localizedStandardContains(query) ?? false))
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var days: [(Date, [VoiceInputRecord])] {
        let cal = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [VoiceInputRecord]] = [:]
        for record in filtered {
            let day = cal.startOfDay(for: record.createdAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(record)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 330)
            Rectangle().fill(Theme.line).frame(width: 0.5)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedID == nil { selectedID = filtered.first?.id }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("历史").font(Theme.pageTitle).padding(.top, 42)
                SearchField(text: $search, prompt: "搜索原文、润色后、发出的文字")
                Pills(options: HistoryFilter.allCases.map { ($0, $0.title) }, selection: $filter)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)

            if filtered.isEmpty {
                Spacer()
                if store.records.isEmpty {
                    VStack(spacing: 10) {
                        EmptyState(systemImage: "waveform", title: "还没有记录", message: "说的每一句都会留在这里。")
                        HStack(spacing: 5) {
                            Text("按").foregroundStyle(.secondary)
                            KeyCap(key: "右 ⌃")
                            Text("或").foregroundStyle(.secondary)
                            KeyCap(key: "fn")
                            Text("开始说话").foregroundStyle(.secondary)
                        }
                        .font(Theme.caption)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    EmptyState(systemImage: "magnifyingglass", title: "没有找到", message: "换个词，或者看看「全部」。")
                        .frame(maxWidth: .infinity)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(days, id: \.0) { day, records in
                            HStack {
                                Text(DayLabel.title(for: day)).font(.system(size: 12, weight: .semibold, design: .rounded))
                                Spacer()
                                Text("\(records.count) 条").font(Theme.small).foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                            .padding(.bottom, 5)
                            ForEach(records) { record in
                                HistoryRow(record: record, selected: record.id == selectedID)
                                    .onTapGesture { selectedID = record.id }
                                    .contextMenu {
                                        Button("复制") { RecordActions.copy(record.text) }
                                        Button("再键入") { RecordActions.retype(record) }
                                        Divider()
                                        Button("删除", role: .destructive) { delete(record) }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(Theme.ground)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = selectedID, let record = store.records.first(where: { $0.id == id }) {
            RecordDetail(record: record, onDelete: { delete(record) })
                .id(record.id)
        } else {
            EmptyState(systemImage: "text.alignleft", title: "选一条看看")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func delete(_ record: VoiceInputRecord) {
        let list = filtered
        if selectedID == record.id, let index = list.firstIndex(where: { $0.id == record.id }) {
            let next = index + 1 < list.count ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
            selectedID = next?.id
        }
        store.delete(record.id)
    }
}

private enum HistoryFilter: String, CaseIterable {
    case all, edited, unpolished, problems

    var title: String {
        switch self {
        case .all: "全部"
        case .edited: "改过"
        case .unpolished: "没润色"
        case .problems: "出问题"
        }
    }

    func includes(_ r: VoiceInputRecord) -> Bool {
        switch self {
        case .all: true
        case .edited: r.wasEditedBeforeSending
        case .unpolished: !r.wasRewritten
        case .problems: r.hasProblem
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Theme.card, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line2, lineWidth: 0.5))
    }
}

private struct HistoryRow: View {
    let record: VoiceInputRecord
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(record.createdAt, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.text.isEmpty ? record.rawTranscript : record.text)
                    .font(.system(size: 13, design: .rounded))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let tags = record.tags
                if !tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(tags.indices, id: \.self) { i in Tag(text: tags[i].0, tint: tags[i].1) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line2, lineWidth: 0.5))
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover)
            }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Detail

private enum TextView: String, CaseIterable {
    case compare, polished, raw
    var title: String {
        switch self {
        case .compare: "对比"
        case .polished: "润色后"
        case .raw: "原文"
        }
    }
}

private struct RecordDetail: View {
    let record: VoiceInputRecord
    let onDelete: () -> Void
    @State private var view: TextView
    @State private var repolishing = false
    @State private var repolishError: String?
    @State private var copied = false

    init(record: VoiceInputRecord, onDelete: @escaping () -> Void) {
        self.record = record
        self.onDelete = onDelete
        let differs = !record.rawTranscript.isEmpty && record.rawTranscript != record.text
        _view = State(initialValue: differs ? .compare : .polished)
    }

    private var hasRaw: Bool { !record.rawTranscript.isEmpty && record.rawTranscript != record.text }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if hasRaw {
                    Pills(options: TextView.allCases.map { ($0, $0.title) }, selection: $view)
                        .padding(.top, 4)
                }
                textCard
                sentCard
                RecordingCard(record: record)
                timingCard
                footnote
            }
            .padding(.horizontal, 28)
            .padding(.top, 42)
            .padding(.bottom, 28)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            appTile
            VStack(alignment: .leading, spacing: 2) {
                Text(record.targetApp ?? "未知 App").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("\(DayLabel.moment(record.createdAt)) · 录了 \(String(format: "%.1f", record.duration)) 秒 · \(record.languageName)")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "复制") {
                    RecordActions.copy(view == .raw ? record.rawTranscript : record.text)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                IconButton(systemImage: "arrow.right.to.line", help: "再键入到 \(record.targetApp ?? "前台 App")") {
                    RecordActions.retype(record)
                }
                if !record.rawTranscript.isEmpty, LLMRewriter.isEnabled {
                    IconButton(systemImage: repolishing ? "ellipsis" : "arrow.clockwise", help: "用现在的设置重新润色") {
                        guard !repolishing else { return }
                        repolishing = true
                        repolishError = nil
                        Task {
                            do { try await RecordActions.repolish(record) } catch { repolishError = error.localizedDescription }
                            repolishing = false
                        }
                    }
                }
                IconButton(systemImage: "trash", help: "删除这条", role: .destructive, action: onDelete)
            }
        }
    }

    @ViewBuilder private var appTile: some View {
        if let name = record.targetApp, let icon = AppIcons.icon(for: name) {
            Image(nsImage: icon).resizable().frame(width: 30, height: 30)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.hover)
                .frame(width: 28, height: 28)
                .overlay(Text(String((record.targetApp ?? "?").prefix(1))).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary))
        }
    }

    private var textCard: some View {
        Group {
            switch view {
            case .compare where hasRaw:
                TextDiffView(original: record.rawTranscript, modified: record.text)
            case .raw:
                Text(record.rawTranscript).foregroundStyle(.secondary)
            default:
                Text(record.text)
            }
        }
        .font(.system(size: 14.5, design: .rounded))
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .card()
        .overlay(alignment: .bottomTrailing) {
            if let repolishError {
                Text(repolishError).font(Theme.small).foregroundStyle(Theme.red).padding(8)
            }
        }
    }

    @ViewBuilder private var sentCard: some View {
        switch record.sentLookup {
        case .found where record.wasEditedBeforeSending:
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Tag(text: "发出前改过", tint: .accent)
                    Text("你在 \(record.targetApp ?? "那里") 发出的是").font(Theme.caption).foregroundStyle(.secondary)
                }
                TextDiffView(original: record.text, modified: record.sentText ?? "", font: .system(size: 13.5, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .card()
        case .found:
            HStack(spacing: 7) {
                Tag(text: "原样发出", tint: .green)
                if let at = record.sentAt {
                    Text(at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute()).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        case .notFound:
            Text("在 \(record.targetApp ?? "那里") 发出的内容里没找到这句").font(Theme.caption).foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var timingCard: some View {
        if let total = record.totalLatency, total > 0 {
            let stt = record.transcriptionTime ?? 0
            let polish = record.polishTimedOut ? 0 : (record.llmPolishTime ?? 0)
            let insert = record.insertTime ?? 0
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("停录到出字").font(Theme.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f 秒", total)).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                }
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.blue).frame(width: geo.size.width * stt / total)
                        Rectangle().fill(Theme.accent).frame(width: geo.size.width * polish / total)
                        Rectangle().fill(Theme.green).frame(width: geo.size.width * insert / total)
                    }
                }
                .frame(height: 8)
                .background(Theme.hover)
                .clipShape(.rect(cornerRadius: 4))
                HStack(spacing: 14) {
                    legend("识别", stt, Theme.blue)
                    if polish > 0 { legend("润色", polish, Theme.accent) }
                    if record.polishTimedOut { Text("润色没回来，键入的是原文").font(Theme.small).foregroundStyle(Theme.red) }
                    if record.insertTime != nil { legend("键入", insert, Theme.green) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .card()
        }
    }

    private func legend(_ name: String, _ value: TimeInterval, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(name).foregroundStyle(.secondary)
            Text(String(format: "%.2f", value)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 11.5, design: .rounded))
    }

    private var footnote: some View {
        var parts: [String] = []
        if let model = record.llmModel { parts.append(AIModelNames.display(model)) }
        if let mode = record.polishMode.flatMap(LLMRewriter.PolishMode.init(rawValue:)) { parts.append(mode.chineseName) }
        if let cold = record.polishCold { parts.append(cold ? "会话刚启动（冷）" : "会话已热") }
        if record.llmModel == nil { parts.append("没润色") }
        if let hits = record.vocabularyHitCount, hits > 0 { parts.append("词表命中 \(hits)") }
        return Text(parts.joined(separator: " · "))
            .font(Theme.caption)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Recording

private struct RecordingCard: View {
    let record: VoiceInputRecord
    @State private var bars: [Float] = []
    @State private var player: AVAudioPlayer?
    @State private var progress: Double = 0
    @State private var missing = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: player?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(missing ? Color.secondary.opacity(0.4) : Theme.accent, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(missing)
            .accessibilityLabel(player?.isPlaying == true ? "暂停" : "播放录音")

            if missing {
                Text("录音文件已经不在了").font(Theme.caption).foregroundStyle(.tertiary)
                Spacer()
            } else {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(bars.indices, id: \.self) { i in
                        let played = Double(i) / Double(max(bars.count, 1)) < progress
                        RoundedRectangle(cornerRadius: 1)
                            .fill(played ? Theme.accent : Color.secondary.opacity(0.35))
                            .frame(height: max(3, CGFloat(bars[i]) * 28))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 30)
            }
            Text(String(format: "%d:%02d", Int(record.duration) / 60, Int(record.duration.rounded()) % 60))
                .font(.system(size: 11.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card()
        .task { await loadBars() }
        .onDisappear { player?.stop() }
    }

    private func loadBars() async {
        let url = VoiceInputStore.shared.audioURL(for: record)
        guard FileManager.default.fileExists(atPath: url.path) else { missing = true; return }
        bars = await Task.detached(priority: .utility) { Waveform.bars(url: url, count: 64) }.value
    }

    private func toggle() {
        if let player, player.isPlaying {
            player.pause()
            self.player = player
            return
        }
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: VoiceInputStore.shared.audioURL(for: record))
        }
        guard let player else { missing = true; return }
        player.play()
        self.player = player
        Task { @MainActor in
            while player.isPlaying {
                progress = player.currentTime / max(player.duration, 0.01)
                try? await Task.sleep(for: .milliseconds(100))
            }
            progress = player.currentTime >= player.duration - 0.05 ? 0 : progress
            self.player = player.currentTime == 0 ? nil : player
        }
    }
}

enum Waveform {
    /// `count` loudness bars (0…1) for an audio file, peak per slice.
    static func bars(url: URL, count: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData?[0]
        else { return [] }
        let n = Int(buffer.frameLength)
        let slice = max(n / count, 1)
        var out: [Float] = []
        out.reserveCapacity(count)
        for b in 0..<count {
            let start = b * slice
            guard start < n else { out.append(0); continue }
            var peak: Float = 0
            var i = start
            let end = min(start + slice, n)
            while i < end { peak = max(peak, abs(data[i])); i += 4 }
            out.append(peak)
        }
        let top = max(out.max() ?? 1, 0.0001)
        return out.map { sqrt($0 / top) }
    }
}

enum AIModelNames {
    /// "cc-sonnet" → "Claude Sonnet", "cc-opus" → "Claude Opus"; others as they are.
    static func display(_ model: String) -> String {
        switch model {
        case "cc-sonnet": "Claude Sonnet"
        case "cc-opus": "Claude Opus"
        case "cc-haiku": "Claude Haiku"
        default: model
        }
    }
}

extension LLMRewriter.PolishMode {
    var chineseName: String {
        switch self {
        case .strict: "严格"
        case .light: "轻度"
        case .medium: "中度"
        }
    }
}
