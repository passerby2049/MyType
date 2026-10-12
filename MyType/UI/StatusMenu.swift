// Abstract:
// The menu bar menu is MyType's home (there is no home page): state and
// hotkey first — or the problem, if there is one — then today in one line,
// the last five dictations (click copies, ⌥-click types again), type the
// last one again, polish on/off, and the pages of the window. It's rebuilt
// just before it opens, never while open. The icon turns amber while
// recording.

import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    weak var statusItem: NSStatusItem?
    private var recent: [VoiceInputRecord] = []

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let issues = AppIssue.current()

        // State, or the first problem.
        let head = NSMenuItem()
        if let issue = issues.first {
            head.attributedTitle = twoLines("⚠︎ " + issue.title, issue.detail, firstColor: Theme.accentNS)
            head.target = self
            head.action = #selector(fixIssue)
            head.representedObject = issue.id
        } else {
            head.attributedTitle = twoLines("就绪 · 按 右⌃ 说话，esc 取消", engineLine)
        }
        menu.addItem(head)
        if let today = todayLine {
            let item = NSMenuItem()
            item.attributedTitle = NSAttributedString(string: today, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(item)
        }

        // The last five.
        recent = Array(VoiceInputStore.shared.records.sorted { $0.createdAt > $1.createdAt }.prefix(5))
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "刚才（点一下复制，按住 ⌥ 再键入）"))
            for (index, record) in recent.enumerated() {
                let time = record.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                let text = snippet(record.text.isEmpty ? record.rawTranscript : record.text)
                let copy = NSMenuItem(title: "", action: #selector(copyRecent(_:)), keyEquivalent: "")
                copy.attributedTitle = recentTitle(time: time, text: text, problem: record.hasProblem)
                copy.target = self
                copy.tag = index
                menu.addItem(copy)
                let retype = NSMenuItem(title: "", action: #selector(retypeRecent(_:)), keyEquivalent: "")
                retype.attributedTitle = recentTitle(time: time, text: "再键入：" + text, problem: false)
                retype.target = self
                retype.tag = index
                retype.isAlternate = true
                retype.keyEquivalentModifierMask = .option
                menu.addItem(retype)
            }
        }

        menu.addItem(.separator())
        let again = NSMenuItem(title: "再键入上一条", action: #selector(retypeLast), keyEquivalent: "v")
        again.keyEquivalentModifierMask = [.control, .option]
        again.target = self
        again.isEnabled = !recent.isEmpty
        menu.addItem(again)
        let polish = NSMenuItem(title: "润色", action: #selector(togglePolish), keyEquivalent: "")
        polish.state = LLMRewriter.isEnabled ? .on : .off
        polish.target = self
        menu.addItem(polish)

        menu.addItem(.separator())
        addPage(menu, "历史…", .history, key: "y")
        addPage(menu, "统计…", .stats)
        addPage(menu, "词表…", .vocabulary)
        addPage(menu, "设置…", .settings, key: ",")

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MyType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Lines

    private var engineLine: String {
        let engine = VoiceInputEngineChoice.current.shortName
        guard LLMRewriter.isEnabled else { return "\(engine) · 不润色" }
        return "\(engine) · \(AIModelNames.display(LLMRewriter.resolvedModel)) \(LLMRewriter.polishMode.chineseName)"
    }

    private var todayLine: String? {
        let start = Calendar.current.startOfDay(for: .now)
        let today = VoiceInputStore.shared.records.filter { $0.createdAt >= start }
        guard !today.isEmpty else { return nil }
        let chars = today.reduce(0) { $0 + $1.text.count }
        let saved = today.reduce(0.0) { acc, r in
            acc + Double(r.text.count) / TypingSpeed.charsPerMinute(for: LanguageKey(locale: r.language).raw) * 60 - r.duration
        }
        var parts = ["今天 \(chars.formatted()) 字"]
        if saved >= 60 { parts.append("省下 \(Int(saved / 60)) 分钟") }
        let latencies = today.compactMap(\.totalLatency).sorted()
        if !latencies.isEmpty { parts.append(String(format: "出字 %.1f 秒", latencies[latencies.count / 2])) }
        return parts.joined(separator: " · ")
    }

    private func twoLines(_ first: String, _ second: String, firstColor: NSColor = .labelColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: first, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: firstColor])
        result.append(NSAttributedString(string: "\n" + second, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        return result
    }

    private func recentTitle(time: String, text: String, problem: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: time + "   ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        result.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: problem ? NSColor.systemRed : NSColor.labelColor,
        ]))
        return result
    }

    private func snippet(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 34 ? String(flat.prefix(34)) + "…" : flat
    }

    private func addPage(_ menu: NSMenu, _ title: String, _ page: MainPage, key: String = "") {
        let item = NSMenuItem(title: title, action: #selector(openPage(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = page.rawValue
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard recent.indices.contains(sender.tag) else { return }
        RecordActions.copy(recent[sender.tag].text)
    }

    @objc private func retypeRecent(_ sender: NSMenuItem) {
        guard recent.indices.contains(sender.tag) else { return }
        VoiceInputManager.shared.retypeIntoFrontmost(recent[sender.tag])
    }

    @objc private func retypeLast() { VoiceInputManager.shared.retypeLast() }

    @objc private func togglePolish() {
        UserDefaults.standard.set(!LLMRewriter.isEnabled, forKey: LLMRewriter.useLLMKey)
    }

    @objc private func openPage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let page = MainPage(rawValue: raw) else { return }
        MainWindowController.shared.show(page)
    }

    @objc private func fixIssue(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let issue = AppIssue.current().first(where: { $0.id == id }) else { return }
        issue.perform()
    }

    // MARK: Icon

    /// Amber while recording, as the overlay; the usual template otherwise.
    func watchRecordingState() {
        withObservationTracking {
            _ = VoiceInputManager.shared.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem?.button?.contentTintColor = VoiceInputManager.shared.state == .recording ? Theme.accentNS : nil
                self.watchRecordingState()
            }
        }
    }
}
