// Abstract:
// Transcription engine settings and local model cache controls.

import SwiftUI

struct EngineSettingsView: View {
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
                    EngineSettingsRow(
                        engine: engine,
                        isActive: selectedEngine.wrappedValue == engine,
                        isDownloaded: modelStatus[engine] ?? !engine.requiresDownload,
                        activate: { selectedEngine.wrappedValue = engine },
                        deleteModel: { deleteModel(engine) }
                    )
                }
            } header: {
                Text("Transcription Engine")
            } footer: {
                Text("Qwen3-ASR: Chinese + English code-switching. Parakeet: English-only (v2) or 25 European languages (v3). Apple Speech: built-in fallback.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshModelStatus)
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

private struct EngineSettingsRow: View {
    let engine: VoiceInputEngineChoice
    let isActive: Bool
    let isDownloaded: Bool
    let activate: () -> Void
    let deleteModel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: engine.iconName)
                .font(.title3)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.shortName).font(.body)
                Text(engine.detailLabel).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
            statusControl
            deleteControl
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusControl: some View {
        if isActive {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Button("Activate", action: activate)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var deleteControl: some View {
        if engine.requiresDownload && isDownloaded {
            Button(action: deleteModel) {
                Image(systemName: "trash").foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .help("Delete downloaded model")
        }
    }
}
