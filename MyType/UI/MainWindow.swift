// Abstract:
// The one window (docs/design-ui-2026-10.md): opened on demand from the menu
// bar, it holds history, statistics, vocabulary and settings behind a
// sidebar. There is no home page — the menu bar menu is that. While the
// window is open MyType shows in the Dock and ⌘Tab so the window can't get
// lost behind others; closing it returns to the menu-bar-only app.

import AppKit
import AVFoundation
import SwiftUI

enum MainPage: String, CaseIterable, Identifiable {
    case history, stats, vocabulary, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "历史"
        case .stats: "统计"
        case .vocabulary: "词表"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .history: "clock"
        case .stats: "chart.bar"
        case .vocabulary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recognition, polish, records
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "通用"
        case .recognition: "识别"
        case .polish: "润色"
        case .records: "记录"
        }
    }
}

/// Which page and settings tab the window shows; remembered between opens.
@MainActor @Observable
final class MainNavigation {
    static let shared = MainNavigation()
    private static let pageKey = "mainWindowPage"

    var page: MainPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: Self.pageKey) }
    }
    var settingsTab: SettingsTab = .general

    private init() {
        page = MainPage(rawValue: UserDefaults.standard.string(forKey: Self.pageKey) ?? "") ?? .history
    }
}

// MARK: - Problems

/// Something that stops MyType working as set up, shown where the user looks:
/// the window's sidebar, and the first line of the menu bar menu.
struct AppIssue: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let fix: Fix

    enum Fix: Equatable {
        case systemSettings(String)  // x-apple.systempreferences URL
        case settings(SettingsTab)
    }

    /// Checked fresh each time (cheap: a few system calls and a file test).
    @MainActor static func current() -> [AppIssue] {
        var issues: [AppIssue] = []
        if !AXIsProcessTrusted() {
            issues.append(AppIssue(
                id: "ax", title: "辅助功能没授权", detail: "快捷键和键入都要它 · 去系统设置",
                fix: .systemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            ))
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .denied || mic == .restricted {
            issues.append(AppIssue(
                id: "mic", title: "麦克风没授权", detail: "录不到声音 · 去系统设置",
                fix: .systemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            ))
        }
        if LLMRewriter.isEnabled,
           AIProvider.provider(for: LLMRewriter.resolvedModel) == .claudeCode,
           claudeCodeBinaryPath() == nil {
            issues.append(AppIssue(
                id: "claude", title: "找不到 claude", detail: "润色没法跑，键入的是原文 · 去设置",
                fix: .settings(.polish)
            ))
        }
        let folder = VoiceLog.ottoFolder
        if !folder.isEmpty, !FileManager.default.fileExists(atPath: folder) {
            issues.append(AppIssue(
                id: "otto", title: "Otto 文件夹找不到", detail: "每日记录先不写 · 去设置",
                fix: .settings(.records)
            ))
        }
        return issues
    }

    @MainActor func perform() {
        switch fix {
        case .systemSettings(let url):
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .settings(let tab):
            MainNavigation.shared.settingsTab = tab
            MainNavigation.shared.page = .settings
            MainWindowController.shared.show()
        }
    }
}

// MARK: - Window

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(_ page: MainPage? = nil) {
        if let page { MainNavigation.shared.page = page }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "MyType"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 540)
        window.contentView = NSHostingView(rootView: MainView())
        window.delegate = self
        if !window.setFrameUsingName("MyTypeMain") { window.center() }
        window.setFrameAutosaveName("MyTypeMain")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Root view

struct MainView: View {
    @State private var nav = MainNavigation.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(nav: nav)
                .frame(width: 204)
            Rectangle().fill(Theme.line).frame(width: 0.5)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ground)
        }
        .ignoresSafeArea(.container, edges: .top)
        .fontDesign(.rounded)
        .frame(minWidth: 860, minHeight: 540)
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .history: HistoryPage()
        case .stats: StatsPage()
        case .vocabulary: VocabularyPage()
        case .settings: SettingsPage(nav: nav)
        }
    }
}

private struct Sidebar: View {
    @Bindable var nav: MainNavigation
    @State private var issues: [AppIssue] = []
    private var store = VoiceInputStore.shared
    private var vocabulary = VocabularyStore.shared

    init(nav: MainNavigation) { self.nav = nav }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
                Text("MyType").font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 8)
            .padding(.top, 50)
            .padding(.bottom, 16)

            ForEach([MainPage.history, .stats, .vocabulary]) { page in
                row(page, count: count(for: page))
            }

            Spacer()

            ForEach(issues) { issue in
                Button { issue.perform() } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .semibold)).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(issue.detail).font(.system(size: 11.5, design: .rounded)).opacity(0.85)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.accentText)
                    .padding(9)
                    .background(Theme.accent.opacity(0.15), in: .rect(cornerRadius: 9, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }

            row(.settings, count: nil)
            Text("MyType \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(Theme.small)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9)
                .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .onAppear { issues = AppIssue.current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            issues = AppIssue.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let fresh = AppIssue.current()
            if fresh != issues { issues = fresh }
        }
    }

    private func count(for page: MainPage) -> String? {
        switch page {
        case .history:
            let today = Calendar.current.startOfDay(for: .now)
            let n = store.records.lazy.filter { $0.createdAt >= today }.count
            return n > 0 ? "\(n)" : nil
        case .vocabulary:
            return vocabulary.terms.isEmpty ? nil : "\(vocabulary.terms.count)"
        default:
            return nil
        }
    }

    private func row(_ page: MainPage, count: String?) -> some View {
        SidebarRow(page: page, count: count, selected: nav.page == page) {
            nav.page = page
        }
    }
}

private struct SidebarRow: View {
    let page: MainPage
    let count: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.accentText : .secondary)
                    .frame(width: 18)
                Text(page.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular, design: .rounded))
                Spacer()
                if let count {
                    Text(count).font(Theme.small).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(selected ? Theme.selection : (hovering ? Theme.hover : .clear), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.bottom, 2)
    }
}
