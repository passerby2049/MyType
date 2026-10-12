// Abstract:
// Vocabulary: the words recognition leans toward, as small tiles with an
// icon for where each came from (added by you / learned), how often it was
// heard, and a ✕ on hover. "加词" opens a field at the top; presets are a
// menu next to it. The foot says how many of them recognition actually takes.

import SwiftUI

struct VocabularyPage: View {
    private var store = VocabularyStore.shared
    @State private var filter: VocabularyFilter = .all
    @State private var search = ""
    @State private var adding = false
    @State private var newTerm = ""
    @FocusState private var fieldFocused: Bool

    private var shown: [VocabularyTerm] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.terms.filter { term in
            filter.includes(term) && (query.isEmpty || term.term.localizedStandardContains(query))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "词表", subtitle: "识别时偏向这些写法；润色时也照着写。") {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(VocabularyPreset.allCases) { preset in
                                Button(preset.title) { preset.terms.forEach { store.add($0) } }
                            }
                        } label: {
                            Text("从预设加")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.secondary)
                        .fixedSize()
                        Button {
                            withAnimation(Theme.ease) { adding = true }
                            fieldFocused = true
                        } label: {
                            Label("加词", systemImage: "plus")
                        }
                        .buttonStyle(.primary)
                    }
                    .padding(.top, 6)
                }

                if adding { addField }

                HStack {
                    Pills(options: VocabularyFilter.allCases.map { ($0, "\($0.title) \(store.terms.filter($0.includes).count)") }, selection: $filter)
                    Spacer()
                    SearchField(text: $search, prompt: "搜索").frame(width: 200)
                }

                if shown.isEmpty {
                    EmptyState(
                        systemImage: "character.book.closed",
                        title: store.terms.isEmpty ? "还没有词" : "没有找到",
                        message: store.terms.isEmpty ? "常说的名字、产品、框架、缩写，加进来识别得更准。" : nil
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(shown) { term in
                            TermTile(term: term,
                                     toggle: { store.setEnabled(term.id, enabled: !term.enabled) },
                                     remove: { withAnimation(Theme.ease) { store.remove(term.id) } })
                        }
                    }
                }

                Text(contextNote)
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 34)
            .padding(.top, 42)
            .padding(.bottom, 34)
        }
    }

    private var addField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
            TextField("输入一个词，回车加入；esc 收起", text: $newTerm)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused($fieldFocused)
                .onSubmit(add)
                .onExitCommand { withAnimation(Theme.ease) { adding = false; newTerm = "" } }
            if !newTerm.isEmpty {
                Button("加入", action: add).buttonStyle(.primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .card(radius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
    }

    private func add() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.add(trimmed)
        newTerm = ""
    }

    private var contextNote: String {
        let enabled = store.enabledTerms.count
        let limit = VoiceInputManager.recognitionContextLimit
        if enabled == 0 { return "识别时不带词。" }
        if enabled <= limit { return "识别一次最多带 \(limit) 个词，现在启用的 \(enabled) 个都带上了。" }
        return "识别一次最多带 \(limit) 个词：启用了 \(enabled) 个，带上的是前 \(limit) 个。"
    }
}

private enum VocabularyFilter: String, CaseIterable {
    case all, manual, learned

    var title: String {
        switch self {
        case .all: "全部"
        case .manual: "你加的"
        case .learned: "学到的"
        }
    }

    func includes(_ term: VocabularyTerm) -> Bool {
        switch self {
        case .all: true
        case .manual: term.source == .manual
        case .learned: term.source == .automatic
        }
    }
}

private struct TermTile: View {
    let term: VocabularyTerm
    let toggle: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: term.source == .automatic ? "sparkle" : "pencil")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(term.source == .automatic ? Theme.accent : Color.secondary.opacity(0.6))
                .frame(width: 13)
            Text(term.term)
                .font(.system(size: 13, design: .rounded))
                .lineLimit(1)
                .strikethrough(!term.enabled, color: .secondary)
                .foregroundStyle(term.enabled ? .primary : .secondary)
            Spacer(minLength: 4)
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Theme.hover, in: .circle)
                }
                .buttonStyle(.plain)
                .help("删除")
            } else if !term.enabled {
                Text("停用").font(Theme.small).foregroundStyle(.tertiary)
            } else if term.hitCount > 0 {
                Text("\(term.hitCount) 次").font(Theme.small).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(Theme.card, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.8) : Theme.line, lineWidth: hovering ? 1 : 0.5)
        )
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(term.enabled ? "停用" : "启用", action: toggle)
            Button("删除", role: .destructive, action: remove)
        }
        .help(term.lastUsedAt.map { "上次听到：\($0.formatted(.relative(presentation: .named)))" } ?? "还没听到过")
    }
}

enum VocabularyPreset: String, CaseIterable, Identifiable {
    case developer
    case aiCoding
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developer: "开发常用"
        case .aiCoding: "AI 编程"
        case .apple: "Apple 平台"
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
