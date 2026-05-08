// Abstract:
// Two-column settings view — sidebar categories on the left,
// detail pane on the right, matching macOS System Settings style.

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
