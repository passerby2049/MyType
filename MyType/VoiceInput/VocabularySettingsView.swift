// Abstract:
// Custom vocabulary settings with presets, enable toggles, and usage stats.

import SwiftUI

struct VocabularySettingsView: View {
    private var vocabStore = VocabularyStore.shared

    @State private var newTerm = ""
    @State private var selectedPreset: VocabularyPreset = .developer
    @State private var searchText = ""

    private var filteredTerms: [VocabularyTerm] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return vocabStore.terms }
        return vocabStore.terms.filter { $0.term.localizedStandardContains(query) }
    }

    var body: some View {
        Form {
            summarySection
            addSection
            presetSection
            termsSection
        }
        .formStyle(.grouped)
        .searchable(text: $searchText, prompt: "Search vocabulary...")
    }

    private var summarySection: some View {
        Section("Vocabulary") {
            LabeledContent("Enabled") {
                Text("\(vocabStore.enabledTerms.count) / \(vocabStore.terms.count)")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Total Hits") {
                Text("\(vocabStore.terms.reduce(0) { $0 + $1.hitCount })")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addSection: some View {
        Section {
            HStack {
                TextField("Add term...", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", systemImage: "plus", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Text("Enabled terms are prompt hints: MyType prefers these spellings only when they match what was spoken.")
        }
    }

    private var presetSection: some View {
        Section("Presets") {
            Picker("Preset", selection: $selectedPreset) {
                ForEach(VocabularyPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Button("Apply Preset", systemImage: "tray.and.arrow.down", action: applyPreset)
        }
    }

    private var termsSection: some View {
        Section("Terms") {
            if filteredTerms.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Terms Yet" : "No Matching Terms",
                    systemImage: "character.book.closed",
                    description: Text("Add names, products, frameworks, and abbreviations you dictate often.")
                )
            } else {
                ForEach(filteredTerms) { term in
                    VocabularyTermRow(
                        term: term,
                        setEnabled: { vocabStore.setEnabled(term.id, enabled: $0) },
                        remove: { vocabStore.remove(term.id) }
                    )
                }
            }
        }
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        vocabStore.add(trimmed)
        newTerm = ""
    }

    private func applyPreset() {
        for term in selectedPreset.terms {
            vocabStore.add(term)
        }
    }
}

private struct VocabularyTermRow: View {
    let term: VocabularyTerm
    let setEnabled: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { term.enabled },
                    set: setEnabled
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                Text(term.term).font(.callout)
                metaLine
            }

            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Text(term.source.rawValue)
            if term.hitCount > 0 {
                Text("\(term.hitCount) hits")
            }
            if let lastUsedAt = term.lastUsedAt {
                Text(lastUsedAt, format: .relative(presentation: .named))
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

private enum VocabularyPreset: String, CaseIterable, Identifiable {
    case developer
    case aiCoding
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developer: "Developer"
        case .aiCoding: "AI Coding"
        case .apple: "Apple Platforms"
        }
    }

    var terms: [String] {
        switch self {
        case .developer:
            ["GitHub", "TypeScript", "JavaScript", "PostgreSQL", "Docker", "Kubernetes", "Redis"]
        case .aiCoding:
            ["Claude", "Codex", "prompt", "diff", "commit", "pull request", "OpenRouter", "Gemini"]
        case .apple:
            ["SwiftUI", "AppKit", "Xcode", "VoiceOver", "Core Graphics", "Accessibility", "AVFoundation"]
        }
    }
}
