// Abstract:
// Misread English words, from a typed dictation to the practice sheet
// (docs/design-misread-words.md 二–三). After an English dictation into a
// conversation has been typed, in the background: the local candidates, the
// judge for those, `misreads` on the record; the words judged "sound" go on
// the sheet, unless the setting is off. While the sheet is selected the
// dictation hotkey records a take instead, recognized as said.

import AppKit
import AVFoundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "MisreadCoach"
)

@MainActor @Observable
final class MisreadCoach {
    static let shared = MisreadCoach()
    /// 设置 · 润色「英语读音提示」. Off: no bar or sheet; the judging and the record go on.
    static let enabledKey = "misreadHintsEnabled"
    /// Without a take for this long, the sheet gives the keyboard back.
    static let idleSeconds: Double = 30

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private(set) var model: MisreadSheetModel?
    @ObservationIgnored private let panels = MisreadPanels()
    @ObservationIgnored private let recorder = MisreadPracticeRecorder()
    @ObservationIgnored private let speech = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var dayTask: Task<Void, Never>?
    /// Seconds from typed to the bar on screen, for the log (完成标准: p90 ≤ 5 s).
    @ObservationIgnored private(set) var lastDelay: TimeInterval?

    private init() {
        panels.onSelection = { [weak self] in self?.selectionChanged($0) }
        panels.onEscape = { [weak self] in self?.escape() }
        MisreadPracticeRecorder.clearEarlierDays()
    }

    // MARK: - Judging

    /// Have the judge's session up while the user speaks into Claude.
    func prepare(targetApp: String?) {
        guard targetApp == "Claude" else { return }
        Task.detached(priority: .utility) {
            try? await MisreadJudge.session.prepare(systemPrompt: MisreadJudge.systemPrompt, model: MisreadJudge.model, effort: MisreadJudge.effort)
        }
    }

    /// A dictation was typed as polished. Only English with a conversation is judged; nothing here delays typing.
    func consider(id: UUID, raw: String, polished: String, conversation: String?, typedAt: Date) {
        guard let conversation, VoiceInputLanguage.auto.resolved(for: raw) == .english else { return }
        let candidates = MisreadCandidates.candidates(raw: raw, polished: polished)
        guard !candidates.isEmpty else {
            VoiceInputStore.shared.update(id) { $0.misreads = [] }
            return
        }
        Task { @MainActor in
            let start = Date()
            do {
                let verdicts = try await MisreadJudge.judge(candidates: candidates, raw: raw, polished: polished, conversation: conversation)
                defer { MisreadJudge.lastFinished = id }
                let misreads = verdicts.filter { $0.kind == .sound }.map(VoiceMisread.init)
                logger.info("judged \(candidates.count) candidates in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(verdicts.map(\.kind.rawValue).joined(separator: ","), privacy: .public)")
                VoiceInputStore.shared.update(id) { $0.misreads = misreads }
                guard !misreads.isEmpty, Self.isEnabled else { return }
                present(id: id, raw: raw, polished: polished, misreads: misreads, typedAt: typedAt)
            } catch {
                logger.error("judge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Put a sentence on the sheet: opened once, not selected.
    func present(id: UUID, raw: String, polished: String, misreads: [VoiceMisread], typedAt: Date = .now) {
        if model?.practising == true { recorder.cancel() }
        let words = misreads.map { MisreadSheetModel.Word(misread: $0, earlier: earlierDays(of: $0.word, before: id)) }
        let model = MisreadSheetModel(recordID: id, raw: raw, polished: polished, createdAt: .now, words: words)
        self.model = model
        panels.show(model, coach: self)
        lastDelay = Date().timeIntervalSince(typedAt)
        logger.notice("Misread bar: typed→shown \(String(format: "%.2f", self.lastDelay ?? 0), privacy: .public) s, \(words.count) words")
        scheduleDayEnd()
    }

    /// Days this word was misread on before, from the history (ignoring the user's 「没读错」).
    private func earlierDays(of word: String, before id: UUID) -> [Date] {
        let calendar = Calendar.current
        let days = VoiceInputStore.shared.records
            .filter { $0.id != id && ($0.misreads ?? []).contains { $0.word.lowercased() == word.lowercased() && $0.notMisread != true } }
            .map { calendar.startOfDay(for: $0.createdAt) }
            .filter { !calendar.isDateInToday($0) }
        return Array(Set(days)).sorted()
    }

    // MARK: - Hotkey

    /// Where a press of the dictation hotkey goes now.
    func route(dictationBusy: Bool) -> HotkeyRoute {
        HotkeyRoute.route(sheetSelected: model?.selected == true, practising: model?.practising == true, dictationBusy: dictationBusy)
    }

    /// A press of the dictation hotkey; a practice press is handled here.
    func handleHotkey(dictationBusy: Bool) -> HotkeyRoute {
        let route = route(dictationBusy: dictationBusy)
        if route == .practice { togglePractice() }
        return route
    }

    /// A dictation starts: the sheet shrinks back to its bar.
    func dictationStarted() {
        guard let model, model.phase == .sheet else { return }
        model.phase = .bar
        panels.update(model)
    }

    // MARK: - Practice

    func togglePractice() {
        guard let model, !model.recognizing else { return }
        if model.practising { finishTake(model) } else { startTake(model) }
    }

    private func startTake(_ model: MisreadSheetModel) {
        do {
            try recorder.start(recordID: model.recordID, take: (model.takes.last?.id ?? 0) + 1) { [weak model] level in
                model?.level = level
            }
            model.practising = true
            idleTask?.cancel()
            panels.relayout()
        } catch {
            logger.error("take didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finishTake(_ model: MisreadSheetModel) {
        model.practising = false
        model.level = 0
        guard let take = recorder.stop(), take.seconds >= 0.35 else {
            recorder.cancel()
            panels.relayout()
            scheduleIdle()
            return
        }
        model.recognizing = true
        panels.relayout()
        Task { @MainActor in
            let text = (try? await VoiceInputManager.shared.transcribe(at: take.url, request: .practice)) ?? ""
            model.recognizing = false
            model.addTake(text: text, audio: take.url)
            panels.relayout()
            scheduleIdle()
        }
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled else { return }
            self?.panels.deselect()
        }
    }

    // MARK: - Sheet

    private func selectionChanged(_ selected: Bool) {
        guard let model else { return }
        model.selected = selected
        if selected { scheduleIdle() } else {
            idleTask?.cancel()
            if model.practising { recorder.cancel(); model.practising = false; model.level = 0 }
        }
    }

    /// esc: a take being recorded is dropped; otherwise the sheet gives the keyboard back.
    func escape() {
        guard let model else { return }
        if model.practising {
            recorder.cancel()
            model.practising = false
            model.level = 0
            return
        }
        panels.deselect()
    }

    func expand() {
        guard let model else { return }
        model.phase = .sheet
        panels.update(model)
    }

    func collapse() {
        guard let model else { return }
        model.phase = .bar
        panels.update(model)
    }

    /// 「练完」 / ×: the sentence leaves.
    func done() {
        if model?.practising == true { recorder.cancel() }
        idleTask?.cancel()
        panels.hide()
        model = nil
    }

    /// 「这个我没读错」: off the sheet, on the record, in the labels.
    func notMisread(_ word: String) {
        guard let model, let label = model.notMisread(word) else { return }
        do { try MisreadLabels.append(label) } catch {
            logger.error("label not saved: \(error.localizedDescription, privacy: .public)")
        }
        VoiceInputStore.shared.update(model.recordID) { record in
            record.misreads = record.misreads?.map { $0.word == word ? VoiceMisread(word: $0.word, heard: $0.heard, ipa: $0.ipa, tip: $0.tip, notMisread: true) : $0 }
        }
        if model.isEmpty { done() } else { panels.relayout() }
    }

    func wordTapped(_ token: String) {
        guard let model else { return }
        let key = MisreadAlignment.key(token)
        guard let word = model.words.first(where: { $0.misread.word.lowercased() == key }) else { return }
        model.highlighted = word.misread.word
        speak(word.misread.word, slow: false)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if model.highlighted == word.misread.word { model.highlighted = nil }
        }
    }

    /// Where the bar and the sheet are (MisreadTrial).
    var panelFrames: (bar: CGRect, sheet: CGRect) { (panels.bar?.frame ?? .zero, panels.sheet?.frame ?? .zero) }

    /// What a click on the sheet does to it (MisreadTrial).
    func selectForTrial() { panels.select() }

    /// Resize after the trial changed the model.
    func relayoutForTrial() { panels.relayout() }

    // MARK: - Sound

    /// The system's American voice (Heart's word clips aren't on the Mac yet).
    func speak(_ text: String, slow: Bool) {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        if slow { utterance.rate = 0.35 }
        speech.speak(utterance)
    }

    func speakSentence() {
        guard let model else { return }
        speak(model.polished, slow: false)
    }

    func play(_ take: MisreadSheetModel.Take) {
        guard let url = take.audio else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    /// The sentence leaves at the end of the day; its takes go at the next launch.
    private func scheduleDayEnd() {
        dayTask?.cancel()
        let calendar = Calendar.current
        guard let midnight = calendar.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) else { return }
        dayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(midnight.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.done()
            MisreadPracticeRecorder.clearEarlierDays()
        }
    }
}
