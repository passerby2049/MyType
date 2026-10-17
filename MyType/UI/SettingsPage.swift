// Abstract:
// Settings, one page with four tabs (通用 / 识别 / 润色 / 记录). Every row is
// "name + one line saying what it does + control" in rounded groups; the
// polish levels are shown as the same sentence three ways, not explained.

import AppKit
import SwiftUI

struct SettingsPage: View {
    @Bindable var nav: MainNavigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置").font(Theme.pageTitle)
                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        let on = nav.settingsTab == tab
                        Text(tab.title)
                            .font(.system(size: 13, weight: on ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(on ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(on ? Theme.selection : .clear, in: .rect(cornerRadius: 7, style: .continuous))
                            .contentShape(.rect)
                            .onTapGesture { nav.settingsTab = tab }
                    }
                }
                .padding(.top, -6)

                switch nav.settingsTab {
                case .general: GeneralSettings()
                case .recognition: RecognitionSettings()
                case .polish: PolishSettings()
                case .records: RecordsSettings()
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 34)
        }
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @AppStorage(VoiceInputLanguage.defaultsKey) private var languageRaw = VoiceInputLanguage.fallback.rawValue
    @AppStorage(VoiceInputManager.soundEffectsEnabledKey) private var sound = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "快捷键") {
                SettingsRow(title: "开始 / 结束说话", detail: "点一下开始，再点一下结束；说话或处理时按 esc 取消。") {
                    HStack(spacing: 5) { KeyCap(key: "右 ⌃"); Text("或").font(Theme.caption).foregroundStyle(.secondary); KeyCap(key: "fn") }
                }
                SettingsRow(title: "润色选中的文字", detail: "先选中一段，再按；⏎ 替换，esc 取消。") {
                    HStack(spacing: 4) { KeyCap(key: "fn"); KeyCap(key: "空格") }
                }
                SettingsRow(title: "再键入上一条", detail: "上一句没打进去，或者想再用一次。") {
                    HStack(spacing: 4) { KeyCap(key: "⌃"); KeyCap(key: "⌥"); KeyCap(key: "V") }
                }
            }

            SettingsGroup(title: "说话") {
                SettingsRow(title: "语言", detail: "自动：中文、英文、日文混着说也分得清；选一种只当提示。") {
                    Picker("语言", selection: $languageRaw) {
                        ForEach(VoiceInputLanguage.allCases) { lang in
                            Text(lang.chineseName).tag(lang.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow(title: "提示音", detail: "开始和结束时响一声。") {
                    Toggle("提示音", isOn: $sound).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
            }

            SettingsGroup(title: "统计") {
                SettingsRow(title: "你的打字速度", detail: "算「省下的时间」用，每分钟打多少字（英文按字母算）。") {
                    HStack(spacing: 10) {
                        ForEach(TypingSpeed.languages, id: \.self) { lang in
                            TypingSpeedField(language: lang)
                        }
                    }
                }
            }
        }
    }
}

private struct TypingSpeedField: View {
    let language: String
    @State private var value: Int

    init(language: String) {
        self.language = language
        _value = State(initialValue: Int(TypingSpeed.charsPerMinute(for: language)))
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(LanguageKey(locale: language).displayName).font(Theme.caption).foregroundStyle(.secondary)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
                .onChange(of: value) { _, new in
                    if new > 0 { UserDefaults.standard.set(Double(new), forKey: TypingSpeed.key(language)) }
                }
        }
    }
}

// MARK: - 识别

private struct RecognitionSettings: View {
    @AppStorage(VoiceInputEngineChoice.defaultsKey) private var engineRaw = VoiceInputEngineChoice.fallback.rawValue
    @State private var present: [VoiceInputEngineChoice: Bool] = [:]
    @State private var deleting: VoiceInputEngineChoice?

    private var selected: VoiceInputEngineChoice { VoiceInputEngineChoice(rawValue: engineRaw) ?? .fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "识别引擎") {
                ForEach(VoiceInputEngineChoice.allCases) { engine in
                    SettingsRow(title: engine.shortName, detail: engine.chineseDetail) {
                        HStack(spacing: 8) {
                            if engine.requiresDownload {
                                Text(present[engine] == true ? "已下载" : "第一次用时下载")
                                    .font(Theme.small)
                                    .foregroundStyle(.tertiary)
                            }
                            if engine == selected {
                                Tag(text: "在用", tint: .accent)
                            } else {
                                Button("用这个") { engineRaw = engine.rawValue }.buttonStyle(.secondary)
                            }
                            if engine.requiresDownload, present[engine] == true {
                                IconButton(systemImage: "trash", help: "删掉下载的模型", role: .destructive) { deleting = engine }
                            }
                        }
                    }
                }
            }
            Text("Qwen3-ASR 在本机跑，中文、英文、日文一个模型；词表在它听的时候就带进去。Apple 语音是系统自带的备用。")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
        }
        .onAppear(perform: refresh)
        .alert("删掉 \(deleting?.shortName ?? "") 的模型？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let engine = deleting, let dir = engine.cacheDirectory {
                    try? FileManager.default.removeItem(at: dir)
                    if selected == engine { engineRaw = VoiceInputEngineChoice.appleSpeech.rawValue }
                    refresh()
                }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("下次用它时要重新下载。")
        }
    }

    private func refresh() {
        for engine in VoiceInputEngineChoice.allCases { present[engine] = engine.modelsPresentOnDisk }
    }
}

// MARK: - 润色

private struct PolishSettings: View {
    private static let providers = AIProvider.Provider.allCases.filter { $0 != .anthropic }

    @AppStorage(LLMRewriter.useLLMKey) private var useLLM = false
    @AppStorage(LLMRewriter.modelKey) private var model = ""
    @AppStorage(LLMRewriter.polishModeKey) private var modeRaw = LLMRewriter.polishMode.rawValue
    @AppStorage(LLMRewriter.effortKey) private var effort = LLMRewriter.defaultEffort
    @AppStorage(MisreadCoach.enabledKey) private var misreadHints = true
    @State private var provider = AIProvider.provider(for: LLMRewriter.resolvedModel)
    @State private var trial: String?
    @State private var trying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsRow(title: "润色", detail: "识别出来的文字先交给大模型改错字、去口头语，再键入。原文一直留在历史里。") {
                    Toggle("润色", isOn: $useLLM).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                if useLLM {
                    SettingsRow(title: "服务", detail: provider == .claudeCode ? "经本机的 Claude Code 常驻会话，通常 2 秒左右。" : "直接调用它的接口，要填密钥。") {
                        Picker("服务", selection: $provider) {
                            ForEach(Self.providers) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow(title: "模型") {
                        Picker("模型", selection: $model) {
                            let models = AIProvider.models(for: provider)
                            if !models.contains(model) { Text(AIModelNames.display(model)).tag(model) }
                            ForEach(models, id: \.self) { Text(AIModelNames.display($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsRow(title: "超过多久先键入原文", detail: "润色回来以后会补进历史，不会白跑。") {
                        Text("10 秒").font(Theme.body).foregroundStyle(.secondary)
                    }
                    SettingsRow(title: "英语读音提示", detail: "在 Claude 里说英语时，被听成别的词的那个词，键入后在浮条旁边显示，可以点开练。关了只是不显示，判断照做、照记。") {
                        Toggle("英语读音提示", isOn: $misreadHints).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                    }
                }
            }

            if useLLM {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "改多少")
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach([LLMRewriter.PolishMode.strict, .light, .medium], id: \.rawValue) { mode in
                                LevelCard(mode: mode, selected: modeRaw == mode.rawValue) { modeRaw = mode.rawValue }
                            }
                        }
                        (Text("原话：").foregroundStyle(.secondary) + Text(LevelCard.spoken).fontWeight(.medium))
                            .font(Theme.caption)
                    }
                    .padding(14)
                    .card(radius: 12)
                }

                SettingsGroup {
                    if provider == .claudeCode {
                        SettingsRow(title: "推理强度", detail: "高一档更稳，也更慢。") {
                            Picker("推理强度", selection: $effort) {
                                Text("低").tag("low"); Text("中").tag("medium"); Text("高").tag("high")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                    SettingsRow(title: "试一句", detail: trial ?? "拿最近一条录音的原文，按现在的设置润色一遍，看结果和耗时。") {
                        Button(trying ? "润色中…" : "试一句", action: tryOne)
                            .buttonStyle(.secondary)
                            .disabled(trying || VoiceInputStore.shared.records.isEmpty)
                    }
                }

                if provider == .googleAI { GoogleKeys() }
                if provider == .openRouter { OpenRouterKey() }
            }
        }
        .onAppear { if model.isEmpty { model = LLMRewriter.defaultModel } }
        .onChange(of: provider) { _, new in
            let models = AIProvider.models(for: new)
            if !models.contains(model), let first = models.first { model = first }
        }
    }

    private func tryOne() {
        guard let latest = VoiceInputStore.shared.records.max(by: { $0.createdAt < $1.createdAt }) else { return }
        trying = true
        Task {
            let start = Date()
            do {
                let out = try await LLMRewriter.rewrite(
                    rawText: DictationOptimizer.optimize(latest.rawTranscript),
                    language: VoiceInputLanguage.current,
                    model: LLMRewriter.resolvedModel,
                    vocabularyTerms: VocabularyStore.shared.enabledTerms.map(\.term),
                    frontApp: latest.targetApp
                )
                trial = String(format: "%.1f 秒：", Date().timeIntervalSince(start)) + out
            } catch {
                trial = "没成功：\(error.localizedDescription)"
            }
            trying = false
        }
    }
}

private struct LevelCard: View {
    static let spoken = "嗯那个把 side bar 的宽度改成二零四吧然后就是那个 detail 加个计时条"

    let mode: LLMRewriter.PolishMode
    let selected: Bool
    let select: () -> Void

    private var detail: String {
        switch mode {
        case .strict: "只改识别错"
        case .light: "再去掉口头语、补标点"
        case .medium: "再理顺句子"
        }
    }

    private var example: String {
        switch mode {
        case .strict: "嗯那个把 sidebar 的宽度改成 204 吧然后就是那个 detail 加个计时条"
        case .light: "把 sidebar 的宽度改成 204，然后 detail 加个计时条。"
        case .medium: "把 sidebar 宽度改为 204，并在 detail 中加一个计时条。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(mode.chineseName).font(.system(size: 13, weight: .semibold, design: .rounded))
                if selected { Tag(text: "在用", tint: .accent) }
            }
            Text(detail).font(Theme.small).foregroundStyle(.secondary)
            Text(example)
                .font(.system(size: 12.5, design: .rounded))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Theme.card2, in: .rect(cornerRadius: 7, style: .continuous))
                .padding(.top, 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.line2, lineWidth: selected ? 2 : 0.5)
        )
        .contentShape(.rect)
        .onTapGesture(perform: select)
    }
}

private struct GoogleKeys: View {
    @State private var name = ""
    @State private var key = ""
    private var prefs: AppPreferences { AIProvider.prefs }

    var body: some View {
        SettingsGroup(title: "Google AI Studio 密钥") {
            ForEach(prefs.googleAIKeys) { entry in
                SettingsRow(title: entry.name, detail: masked(entry.key)) {
                    IconButton(systemImage: "trash", help: "删掉这个密钥", role: .destructive) {
                        prefs.googleAIKeys.removeAll { $0.id == entry.id }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("名字", text: $name).textFieldStyle(.roundedBorder).frame(width: 110)
                SecureField("密钥（ai.google.dev 申请；多个会轮换）", text: $key).textFieldStyle(.roundedBorder)
                Button("加入") {
                    prefs.googleAIKeys.append(GoogleAIKeyEntry(name: name.isEmpty ? "密钥 \(prefs.googleAIKeys.count + 1)" : name, key: key))
                    name = ""; key = ""
                }
                .buttonStyle(.secondary)
                .disabled(key.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func masked(_ key: String) -> String {
        key.count > 8 ? String(key.prefix(4)) + "••••" + String(key.suffix(4)) : "••••"
    }
}

private struct OpenRouterKey: View {
    @State private var key = AIProvider.prefs.openRouterAPIKey

    var body: some View {
        SettingsGroup(title: "OpenRouter 密钥") {
            SettingsRow(title: "密钥", detail: "在 openrouter.ai/keys 申请。") {
                SecureField("sk-or-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onChange(of: key) { _, new in AIProvider.prefs.openRouterAPIKey = new }
            }
        }
    }
}

// MARK: - 记录

private struct RecordsSettings: View {
    @AppStorage(VoiceInputStore.saveHistoryKey) private var saveHistory = true
    @AppStorage(VoiceInputStore.historyRetentionDaysKey) private var retention = 0
    @AppStorage(VoiceLog.ottoFolderKey) private var ottoFolder = VoiceLog.defaultOttoFolder
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: "历史") {
                SettingsRow(title: "留下历史", detail: "每一句的录音、原文和润色后的文字都存在本机。") {
                    Toggle("留下历史", isOn: $saveHistory).labelsHidden().toggleStyle(.switch).tint(Theme.accent)
                }
                SettingsRow(title: "保留多久", detail: "过期的记录和录音会删掉。") {
                    Picker("保留多久", selection: $retention) {
                        Text("一直").tag(0); Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!saveHistory)
                }
                SettingsRow(title: "存在哪", detail: (VoiceInputStore.baseDirectory.path as NSString).abbreviatingWithTildeInPath) {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([VoiceInputStore.baseDirectory]) }
                        .buttonStyle(.secondary)
                }
                SettingsRow(title: "全部删除", detail: "\(VoiceInputStore.shared.records.count) 条记录和它们的录音。") {
                    Button("全部删除") { confirmDelete = true }
                        .buttonStyle(.secondary)
                        .foregroundStyle(Theme.red)
                        .disabled(VoiceInputStore.shared.records.isEmpty)
                }
            }

            SettingsGroup(title: "每日记录") {
                SettingsRow(
                    title: "Otto 文件夹",
                    detail: ottoFolder.isEmpty
                        ? "关着。打开后每天说的话（识别的、润色的、发出去的）写进这个文件夹的 _数据/语音输入/，给 Otto 学。"
                        : (ottoFolder as NSString).abbreviatingWithTildeInPath + (FileManager.default.fileExists(atPath: ottoFolder) ? "" : " · 找不到这个文件夹")
                ) {
                    HStack(spacing: 6) {
                        Button("选择…", action: choose).buttonStyle(.secondary)
                        if !ottoFolder.isEmpty { Button("关掉") { ottoFolder = "" }.buttonStyle(.secondary) }
                    }
                }
            }

            SettingsGroup(title: "关于") {
                SettingsRow(title: "MyType", detail: "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")）") {
                    EmptyView()
                }
            }
        }
        .onChange(of: ottoFolder) { _, _ in Task { await VoiceLog.shared.run() } }
        .alert("删除全部历史？", isPresented: $confirmDelete) {
            Button("全部删除", role: .destructive) { VoiceInputStore.shared.deleteAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("记录和录音都会删掉，找不回来。")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if !ottoFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: ottoFolder) }
        if panel.runModal() == .OK, let url = panel.url { ottoFolder = url.path }
    }
}

// MARK: - Labels

extension VoiceInputLanguage {
    var chineseName: String {
        switch self {
        case .auto: "自动"
        case .chinese: "中文"
        case .english: "英文"
        case .japanese: "日文"
        }
    }
}

extension VoiceInputEngineChoice {
    var chineseDetail: String {
        switch self {
        case .qwen3Large: "推荐 · 中英日一个模型 · 下载约 2.3 GB"
        case .qwen3Small: "小一些、准确度低一些（日语尤其）· 约 0.9 GB"
        case .appleSpeech: "系统自带 · 离线 · 一次只认一种语言"
        }
    }
}
