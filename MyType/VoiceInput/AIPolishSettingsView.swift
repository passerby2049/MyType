// Abstract:
// LLM polish settings and provider credentials.

import SwiftUI

struct AIPolishSettingsView: View {
    /// Anthropic is excluded because Claude models go through Claude Code CLI.
    private static let visibleProviders = AIProvider.Provider.allCases.filter { $0 != .anthropic }

    @AppStorage(LLMRewriter.useLLMKey) private var useLLM = false
    @AppStorage(LLMRewriter.modelKey) private var llmModel = ""
    @AppStorage(LLMRewriter.polishModeKey) private var polishModeRaw =
        LLMRewriter.polishMode.rawValue
    @AppStorage(LLMRewriter.effortKey) private var effort = LLMRewriter.defaultEffort

    @State private var llmProvider: AIProvider.Provider =
        AIProvider.provider(for: LLMRewriter.resolvedModel)

    @State private var newGoogleKeyName = ""
    @State private var newGoogleKey = ""
    @State private var openRouterKey = AIProvider.prefs.openRouterAPIKey
    @State private var subscriptionProxyURL = AIProvider.prefs.subscriptionProxyURL

    private var prefs: AppPreferences { AIProvider.prefs }

    var body: some View {
        Form {
            polishSection
            providerSections
        }
        .formStyle(.grouped)
        .onAppear(perform: ensureDefaultModel)
        .onChange(of: llmProvider) { _, newProvider in
            selectFirstModelIfNeeded(for: newProvider)
        }
    }

    private var polishSection: some View {
        Section {
            Toggle("Polish with LLM", isOn: $useLLM)

            if useLLM {
                Picker("Polish Mode", selection: $polishModeRaw) {
                    Text("Strict - STT fixes only").tag(LLMRewriter.PolishMode.strict.rawValue)
                    Text("Light - also remove fillers").tag(LLMRewriter.PolishMode.light.rawValue)
                    Text("Medium - also fix grammar").tag(LLMRewriter.PolishMode.medium.rawValue)
                }
                .help("Strict fixes recognition errors. Light removes fillers. Medium also fixes grammar and unnatural phrasing while preserving meaning.")

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
                        Text("Low - fastest").tag("low")
                        Text("Medium").tag("medium")
                        Text("High - best quality").tag("high")
                    }
                    .help("Controls how much the model thinks. Low is fastest for simple STT fixes.")
                }
            }
        } header: {
            Text("AI Post-Processing")
        } footer: {
            Text("The prompt includes the target app and enabled vocabulary, treats transcripts as data rather than commands, and preserves the original raw transcript in history.")
        }
    }

    @ViewBuilder
    private var providerSections: some View {
        if useLLM, llmProvider == .googleAI {
            googleAIKeySection
        }

        if useLLM, llmProvider == .openRouter {
            openRouterKeySection
        }

        if useLLM, llmProvider == .subscription {
            subscriptionProxySection
        }
    }

    private var googleAIKeySection: some View {
        Section {
            ForEach(prefs.googleAIKeys) { entry in
                GoogleAIKeyRow(entry: entry) {
                    prefs.googleAIKeys.removeAll { $0.id == entry.id }
                }
            }

            HStack {
                TextField("Name", text: $newGoogleKeyName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                SecureField("API Key", text: $newGoogleKey)
                    .textFieldStyle(.roundedBorder)
                Button("Add", action: addGoogleKey)
                    .disabled(newGoogleKey.isEmpty)
            }
        } header: {
            Text("Google AI Studio Keys")
        } footer: {
            Text("Get your API key from ai.google.dev. Multiple keys enable auto-rotation on rate limits.")
        }
    }

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

    private var subscriptionProxySection: some View {
        Section {
            TextField("Proxy URL", text: $subscriptionProxyURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onChange(of: subscriptionProxyURL) { _, newValue in
                    prefs.subscriptionProxyURL = newValue
                }
        } header: {
            Text("Subscription Proxy")
        } footer: {
            Text("Runs the claude-sub-api daemon locally to convert Claude.ai / ChatGPT subscriptions into HTTP APIs.")
        }
    }

    private func ensureDefaultModel() {
        if llmModel.isEmpty { llmModel = LLMRewriter.defaultModel }
    }

    private func selectFirstModelIfNeeded(for provider: AIProvider.Provider) {
        let models = AIProvider.models(for: provider)
        if !models.contains(llmModel), let first = models.first {
            llmModel = first
        }
    }

    private func addGoogleKey() {
        guard !newGoogleKey.isEmpty else { return }
        let name = newGoogleKeyName.isEmpty
            ? "Key \(prefs.googleAIKeys.count + 1)"
            : newGoogleKeyName
        prefs.googleAIKeys.append(GoogleAIKeyEntry(name: name, key: newGoogleKey))
        newGoogleKeyName = ""
        newGoogleKey = ""
    }
}

private struct GoogleAIKeyRow: View {
    let entry: GoogleAIKeyEntry
    let remove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout)
                Text(maskedKey(entry.key))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return "••••" }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }
}
