// Abstract:
// Two-column settings view — sidebar categories on the left,
// detail pane on the right, matching macOS System Settings style.

import FluidAudio
import SwiftUI

struct VoiceInputSettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Settings") {
                    ForEach(SettingsTab.allCases) { tab in
                        SettingsSidebarRow(tab: tab).tag(tab)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 240)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Color.clear.frame(width: 1, height: 22)
                }
            }
        } detail: {
            selectedTab.detailView
                .navigationSplitViewColumnWidth(min: 440, ideal: 520)
                .navigationTitle(selectedTab.title)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

// MARK: - Tab Enum

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case engine
    case aiPolish
    case vocabulary
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .engine: "Engine"
        case .aiPolish: "AI Polish"
        case .vocabulary: "Vocabulary"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .engine: "cpu.fill"
        case .aiPolish: "sparkles"
        case .vocabulary: "character.book.closed.fill"
        case .about: "info.circle.fill"
        }
    }

    /// Tint for the colored icon tile — slightly desaturated to match
    /// macOS System Settings' refined palette.
    var tint: Color {
        switch self {
        case .general:    Color(red: 0.55, green: 0.55, blue: 0.58) // system gray
        case .engine:     Color(red: 0.28, green: 0.68, blue: 0.66) // sea teal
        case .aiPolish:   Color(red: 0.55, green: 0.40, blue: 0.82) // muted violet
        case .vocabulary: Color(red: 0.94, green: 0.62, blue: 0.18) // amber
        case .about:      Color(red: 0.40, green: 0.60, blue: 0.85) // soft blue
        }
    }

    @ViewBuilder var detailView: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .engine: EngineSettingsView()
        case .aiPolish: AIPolishSettingsView()
        case .vocabulary: VocabularySettingsView()
        case .about: AboutSettingsView()
        }
    }
}

/// Sidebar row matching macOS System Settings style — white SF Symbol
/// on a small rounded colored tile with a subtle gradient.
private struct SettingsSidebarRow: View {
    let tab: SettingsTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tab.tint.opacity(0.95),
                                    tab.tint.opacity(0.78),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @State private var soundEnabled = true
    @State private var saveHistory = true

    @AppStorage(VoiceInputLanguage.defaultsKey)
    private var languageRaw: String = VoiceInputLanguage.fallback.rawValue

    private var selectedLanguage: Binding<VoiceInputLanguage> {
        Binding(
            get: { VoiceInputLanguage(rawValue: languageRaw) ?? .fallback },
            set: { languageRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Trigger") {
                    Text("🌐 fn (Globe key)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Active").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Language", selection: selectedLanguage) {
                    ForEach(VoiceInputLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Language")
            } footer: {
                Text("Primary dictation language. Qwen3-ASR handles Chinese/English code-switching either way.")
            }

            Section("Options") {
                Toggle("Sound Effects", isOn: $soundEnabled)
                Toggle("Save History", isOn: $saveHistory)
                    .help("Save audio and transcript for every voice input")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Engine

private struct EngineSettingsView: View {
    @AppStorage(VoiceInputEngineChoice.defaultsKey)
    private var engineRaw: String = VoiceInputEngineChoice.fallback.rawValue

    @AppStorage(VoiceInputLanguage.defaultsKey)
    private var languageRaw: String = VoiceInputLanguage.fallback.rawValue

    @State private var modelStatus: [VoiceInputEngineChoice: Bool] = [:]

    private var selectedEngine: Binding<VoiceInputEngineChoice> {
        Binding(
            get: { VoiceInputEngineChoice(rawValue: engineRaw) ?? .fallback },
            set: { engineRaw = $0.rawValue }
        )
    }

    private var visibleEngines: [VoiceInputEngineChoice] {
        let lang = VoiceInputLanguage(rawValue: languageRaw) ?? .fallback
        return VoiceInputEngineChoice.allCases.filter { $0.supports(language: lang) }
    }

    var body: some View {
        Form {
            Section {
                ForEach(visibleEngines) { engine in
                    engineRow(engine)
                }
            } header: {
                Text("Transcription Engine")
            } footer: {
                Text("Qwen3-ASR: Chinese + English code-switching. "
                    + "Parakeet: English-only (v2) or 25 European languages (v3). "
                    + "Apple Speech: built-in fallback.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshModelStatus() }
    }

    private func engineRow(_ engine: VoiceInputEngineChoice) -> some View {
        let isActive = selectedEngine.wrappedValue == engine
        let isDownloaded = modelStatus[engine] ?? !engine.requiresDownload
        return HStack(spacing: 12) {
            Image(systemName: engine.iconName)
                .font(.title3)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.shortName).font(.body)
                Text(engine.detailLabel).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Button("Activate") { selectedEngine.wrappedValue = engine }
                    .controlSize(.small)
            }

            if engine.requiresDownload && isDownloaded {
                Button {
                    deleteModel(engine)
                } label: {
                    Image(systemName: "trash").foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .help("Delete downloaded model")
            }
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }

    private func refreshModelStatus() {
        for engine in VoiceInputEngineChoice.allCases {
            modelStatus[engine] = engine.modelsPresentOnDisk
        }
    }

    private func deleteModel(_ engine: VoiceInputEngineChoice) {
        guard let cacheDir = engine.cacheDirectory else { return }
        try? FileManager.default.removeItem(at: cacheDir)
        if selectedEngine.wrappedValue == engine {
            selectedEngine.wrappedValue = .appleSpeech
        }
        refreshModelStatus()
    }
}

// MARK: - AI Polish

private struct AIPolishSettingsView: View {
    /// Providers visible in the picker — Anthropic excluded because
    /// we use Claude Code CLI for Claude models instead of direct API.
    private static let visibleProviders = AIProvider.Provider.allCases.filter { $0 != .anthropic }

    @AppStorage(LLMRewriter.useLLMKey) private var useLLM: Bool = false
    @AppStorage(LLMRewriter.modelKey) private var llmModel: String = ""
    @AppStorage(LLMRewriter.lightPolishKey) private var lightPolish: Bool = false
    @AppStorage(LLMRewriter.effortKey) private var effort: String = LLMRewriter.defaultEffort

    @State private var llmProvider: AIProvider.Provider =
        AIProvider.provider(for: LLMRewriter.resolvedModel)

    // API Keys
    @State private var newGoogleKeyName = ""
    @State private var newGoogleKey = ""
    @State private var openRouterKey = AIProvider.prefs.openRouterAPIKey

    private var prefs: AppPreferences { AIProvider.prefs }

    var body: some View {
        Form {
            Section {
                Toggle("Polish with LLM", isOn: $useLLM)

                if useLLM {
                    Toggle("Light Polish", isOn: $lightPolish)
                        .help("Remove fillers (嗯、呃、啊), stuttering, and lightly smooth phrasing")

                    Picker("Provider", selection: $llmProvider) {
                        ForEach(Self.visibleProviders) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    Picker("Model", selection: $llmModel) {
                        let models = AIProvider.models(for: llmProvider)
                        if !models.contains(llmModel) {
                            Text(llmModel).tag(llmModel)
                        }
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }

                    if llmProvider == .claudeCode {
                        Picker("Effort", selection: $effort) {
                            Text("Low — fastest").tag("low")
                            Text("Medium").tag("medium")
                            Text("High — best quality").tag("high")
                        }
                        .help("Controls how much the model 'thinks'. Low is fastest for simple STT fixes. High is better for complex corrections but slower.")
                    }
                }
            } header: {
                Text("AI Post-Processing")
            } footer: {
                Text("Fix STT errors (Chinese homophones, English terms as 配森/杰森). "
                    + "Adds 1–3s of latency. Original transcript is preserved in history.")
            }

            // API Keys — only show for providers that need them
            if useLLM, llmProvider == .googleAI {
                googleAIKeySection
            }

            if useLLM, llmProvider == .openRouter {
                openRouterKeySection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if llmModel.isEmpty { llmModel = LLMRewriter.defaultModel }
        }
        .onChange(of: llmProvider) { _, newProvider in
            let models = AIProvider.models(for: newProvider)
            if !models.contains(llmModel), let first = models.first {
                llmModel = first
            }
        }
    }

    // MARK: - Google AI Key Section

    private var googleAIKeySection: some View {
        Section {
            ForEach(prefs.googleAIKeys) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.callout)
                        Text(maskedKey(entry.key))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        prefs.googleAIKeys.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("Name", text: $newGoogleKeyName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                SecureField("API Key", text: $newGoogleKey)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    guard !newGoogleKey.isEmpty else { return }
                    let name = newGoogleKeyName.isEmpty ? "Key \(prefs.googleAIKeys.count + 1)" : newGoogleKeyName
                    prefs.googleAIKeys.append(GoogleAIKeyEntry(name: name, key: newGoogleKey))
                    newGoogleKeyName = ""
                    newGoogleKey = ""
                }
                .disabled(newGoogleKey.isEmpty)
            }
        } header: {
            Text("Google AI Studio Keys")
        } footer: {
            Text("Get your API key from ai.google.dev. Multiple keys enable auto-rotation on rate limits.")
        }
    }

    // MARK: - OpenRouter Key Section

    private var openRouterKeySection: some View {
        Section {
            SecureField("API Key", text: $openRouterKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: openRouterKey) { _, newValue in
                    prefs.openRouterAPIKey = newValue
                }
        } header: {
            Text("OpenRouter API Key")
        } footer: {
            Text("Get your API key from openrouter.ai/keys.")
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return "••••" }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }
}

// MARK: - Vocabulary

private struct VocabularySettingsView: View {
    private var vocabStore = VocabularyStore.shared
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section {
                Text("Terms added here help the LLM prefer correct spellings for domain-specific words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Add term...", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !vocabStore.terms.isEmpty {
                    ForEach(vocabStore.terms) { term in
                        HStack {
                            Text(term.term).font(.callout)
                            Spacer()
                            Text(term.source.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button {
                                vocabStore.remove(term.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Custom Vocabulary (\(vocabStore.terms.count))")
            }
        }
        .formStyle(.grouped)
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        vocabStore.add(trimmed)
        newTerm = ""
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("Data") {
                Button {
                    NotificationCenter.default.post(name: .openHistory, object: nil)
                } label: {
                    LabeledContent("Records") {
                        HStack(spacing: 6) {
                            Text("\(VoiceInputStore.shared.records.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                LabeledContent("Data Location") {
                    Text(VoiceInputStore.baseDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Section("App") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Engine Choice Extensions

private extension VoiceInputEngineChoice {
    var shortName: String {
        switch self {
        case .qwen3Int8: "Qwen3-ASR (int8)"
        case .qwen3F32: "Qwen3-ASR (f32)"
        case .parakeetV3: "Parakeet TDT v3"
        case .parakeetV2: "Parakeet TDT v2"
        case .appleSpeech: "Apple Speech"
        }
    }

    var detailLabel: String {
        switch self {
        case .qwen3Int8: "Recommended · Chinese + EN · ~900MB download"
        case .qwen3F32: "Faster · Chinese + EN · ~1.75GB download"
        case .parakeetV3: "Multilingual (25 EU langs) · ~500MB download"
        case .parakeetV2: "English only · Highest EN accuracy · ~500MB download"
        case .appleSpeech: "Built-in · Offline · No download"
        }
    }

    var iconName: String {
        switch self {
        case .qwen3Int8, .qwen3F32: "cpu"
        case .parakeetV3: "globe"
        case .parakeetV2: "bolt.fill"
        case .appleSpeech: "apple.logo"
        }
    }

    var requiresDownload: Bool {
        switch self {
        case .qwen3Int8, .qwen3F32, .parakeetV2, .parakeetV3: true
        case .appleSpeech: false
        }
    }

    var cacheDirectory: URL? {
        switch self {
        case .qwen3Int8: Qwen3AsrModels.defaultCacheDirectory(variant: .int8)
        case .qwen3F32: Qwen3AsrModels.defaultCacheDirectory(variant: .f32)
        case .parakeetV3: AsrModels.defaultCacheDirectory(for: .v3)
        case .parakeetV2: AsrModels.defaultCacheDirectory(for: .v2)
        case .appleSpeech: nil
        }
    }

    var modelsPresentOnDisk: Bool {
        switch self {
        case .appleSpeech: true
        case .qwen3Int8: Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory(variant: .int8))
        case .qwen3F32: Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory(variant: .f32))
        case .parakeetV3: AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
        case .parakeetV2: AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
        }
    }
}
