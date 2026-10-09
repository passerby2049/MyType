// Abstract:
// Transcription engine settings and local model cache controls.

import SwiftUI

struct EngineSettingsView: View {
    @AppStorage(VoiceInputEngineChoice.defaultsKey)
    private var engineRaw: String = VoiceInputEngineChoice.fallback.rawValue

    @State private var modelStatus: [VoiceInputEngineChoice: Bool] = [:]

    private var selectedEngine: Binding<VoiceInputEngineChoice> {
        Binding(
            get: { VoiceInputEngineChoice(rawValue: engineRaw) ?? .fallback },
            set: { engineRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                ForEach(VoiceInputEngineChoice.allCases) { engine in
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
                Text("Qwen3-ASR: Chinese, English and Japanese in one model, mixed freely; your vocabulary is passed to it while it listens. Apple Speech: built-in fallback.")
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
