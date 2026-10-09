// Abstract:
// General voice-input settings: readiness, hotkey, language, and retention.

import ApplicationServices
import AVFoundation
import SwiftUI

struct GeneralSettingsView: View {
    private static let retentionOptions = [0, 7, 30, 90]

    @AppStorage(VoiceInputManager.soundEffectsEnabledKey)
    private var soundEnabled = true

    @AppStorage(VoiceInputStore.saveHistoryKey)
    private var saveHistory = true

    @AppStorage(VoiceInputStore.historyRetentionDaysKey)
    private var historyRetentionDays = 0

    @AppStorage(VoiceInputLanguage.defaultsKey)
    private var languageRaw: String = VoiceInputLanguage.fallback.rawValue

    @AppStorage(VoiceLog.ottoFolderKey)
    private var ottoFolder = VoiceLog.defaultOttoFolder

    private var selectedLanguage: Binding<VoiceInputLanguage> {
        Binding(
            get: { VoiceInputLanguage(rawValue: languageRaw) ?? .fallback },
            set: { languageRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            readinessSection
            hotkeySection
            languageSection
            optionsSection
            voiceLogSection
        }
        .formStyle(.grouped)
        .onChange(of: ottoFolder) { _, _ in
            Task { await VoiceLog.shared.run() }
        }
    }

    private var readinessSection: some View {
        Section("Readiness") {
            PermissionStatusRow(
                title: "Accessibility",
                isReady: AXIsProcessTrusted(),
                readyText: "Granted",
                blockedText: "Required for hotkey and insertion"
            )
            PermissionStatusRow(
                title: "Microphone",
                isReady: microphoneReady,
                readyText: "Granted",
                blockedText: "Required for recording"
            )
            PermissionStatusRow(
                title: "Transcription",
                isReady: VoiceInputEngineChoice.current.modelsPresentOnDisk,
                readyText: VoiceInputEngineChoice.current.shortName,
                blockedText: "\(VoiceInputEngineChoice.current.shortName) downloads on first use"
            )
            PermissionStatusRow(
                title: "AI Polish",
                isReady: !LLMRewriter.isEnabled || !LLMRewriter.resolvedModel.isEmpty,
                readyText: LLMRewriter.isEnabled ? LLMRewriter.resolvedModel : "Off",
                blockedText: "Pick a model or turn polish off"
            )
        }
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            LabeledContent("Trigger") {
                Text("fn (Globe key) or right Control")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Monitor") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(VoiceInputManager.shared.hotkeyMonitor.isMonitoring ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(VoiceInputManager.shared.hotkeyMonitor.isMonitoring ? "Active" : "Starting")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var languageSection: some View {
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
            Text("自动: Qwen3-ASR tells Chinese, English and Japanese apart, mixed in one sentence too. Picking one only hints it.")
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Sound Effects", isOn: $soundEnabled)
            Toggle("Save History", isOn: $saveHistory)
                .help("Save audio and transcript for every voice input")

            Picker("History Retention", selection: $historyRetentionDays) {
                ForEach(Self.retentionOptions, id: \.self) { days in
                    Text(retentionLabel(days)).tag(days)
                }
            }
            .disabled(!saveHistory)
            .help("Keep Forever preserves the full local history. Other options delete older records and audio files.")
        }
    }

    private var voiceLogSection: some View {
        Section {
            LabeledContent("Otto Folder") {
                HStack(spacing: 8) {
                    Text(ottoFolder.isEmpty ? "Off" : (ottoFolder as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…", action: chooseOttoFolder)
                    if !ottoFolder.isEmpty {
                        Button("Off") { ottoFolder = "" }
                    }
                }
            }
        } header: {
            Text("Voice Log")
        } footer: {
            Text("Each day's dictations — recognized, polished, and as sent to Claude Code or Otto — go to _数据/语音输入/ in this folder, for Otto to learn from.")
        }
    }

    private func chooseOttoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !ottoFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: ottoFolder)
        }
        if panel.runModal() == .OK, let url = panel.url {
            ottoFolder = url.path
        }
    }

    private var microphoneReady: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: "Keep Forever"
        case 7: "7 Days"
        case 30: "30 Days"
        case 90: "90 Days"
        default: "\(days) Days"
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let isReady: Bool
    let readyText: String
    let blockedText: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isReady ? .green : .orange)
                Text(isReady ? readyText : blockedText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
