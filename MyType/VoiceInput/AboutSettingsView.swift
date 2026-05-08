// Abstract:
// App metadata and data-management settings.

import SwiftUI

struct AboutSettingsView: View {
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Form {
            dataSection
            appSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all voice input history?",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Delete All History", role: .destructive) {
                VoiceInputStore.shared.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes saved transcripts and audio files.")
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button(action: openHistory) {
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

            Button("Delete All History", systemImage: "trash", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(VoiceInputStore.shared.records.isEmpty)
        }
    }

    private var appSection: some View {
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

    private func openHistory() {
        NotificationCenter.default.post(name: .openHistory, object: nil)
    }
}
