// Abstract:
// The practice sheet and its small bar (docs/design-misread-words.md 三, mockup
// docs/misread-words-ui.html), in frosted Liquid Glass: the two aligned rows,
// a row per misread word (IPA, what it was heard as, ▶, 慢, 这个我没读错),
// the takes said while practising, and a status line. Text follows the
// system's light or dark; amber marks the misread words and the selection.

import SwiftUI

struct MisreadSheetView: View {
    var model: MisreadSheetModel
    var coach: MisreadCoach

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                header
                sentence
                VStack(spacing: 6) {
                    ForEach(model.words) { MisreadWordRow(word: $0, model: model, coach: coach) }
                }
                if !model.takes.isEmpty || model.practising || model.recognizing { takes }
                Text(model.status)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(model.selected ? Theme.accentText : .secondary)
            }
            .padding(16)
            .frame(width: MisreadPanels.sheetWidth, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            // Selection is only a glow outside its edge; the sheet itself stays as it was.
            .overlay { glow }
        }
        .padding(MisreadPanels.margin)
        .animation(Theme.ease, value: model.selected)
        // MyType is never the active app; without this every control draws as inactive (grey).
        .environment(\.controlActiveState, .key)
    }

    /// An amber glow around the sheet while it's selected, kept off the sheet so the text stays as clear.
    private var glow: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return shape
            .stroke(Theme.accent, lineWidth: 2)
            .shadow(color: Theme.accent.opacity(0.9), radius: 3)
            .shadow(color: Theme.accent.opacity(0.6), radius: 6)
            .mask {
                Rectangle().padding(-MisreadPanels.margin)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .opacity(model.selected ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
            Text("读音 · 错 \(model.words.count) 个词")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            Spacer()
            Button("练完") { coach.done() }
                .buttonStyle(.glass)
                .controlSize(.small)
            Button { coach.collapse() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("收成小条")
        }
    }

    /// 「你说」 over 「应该」, word under word; wraps in pairs of lines.
    private var sentence: some View {
        HStack(alignment: .top, spacing: 8) {
            MisreadFlow(spacing: 5, lineSpacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("你说"); Text("应该")
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                ForEach(model.columns.indices, id: \.self) { i in
                    MisreadColumnView(column: model.columns[i]) {
                        if let meant = model.columns[i].meant { coach.wordTapped(meant) }
                    }
                }
            }
            Spacer(minLength: 0)
            Button { coach.speakSentence() } label: { Image(systemName: "play.fill") }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("读正确的整句")
        }
        .padding(10)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 14))
    }

    private var takes: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.takes) { MisreadTakeRow(take: $0, coach: coach) }
                    if model.practising || model.recognizing {
                        HStack(spacing: 8) {
                            Text(MisreadTakeRow.circled((model.takes.last?.id ?? 0) + 1)).foregroundStyle(Theme.accent)
                            if model.practising {
                                MisreadLevelBars(level: model.level)
                            } else {
                                Text("识别中…").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 13, design: .rounded))
                        .id("live")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 5 * 24)
            .onChange(of: model.takes.count) { _, _ in proxy.scrollTo(model.takes.last?.id, anchor: .bottom) }
            .onChange(of: model.practising) { _, now in if now { proxy.scrollTo("live", anchor: .bottom) } }
        }
    }
}

/// One word of the aligned rows. A misread word: struck through in red above, bold on amber below.
private struct MisreadColumnView: View {
    let column: MisreadAlignment.Column
    let tap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(column.said ?? " ")
                .strikethrough(column.misread, color: Theme.red)
                .foregroundStyle(column.misread ? AnyShapeStyle(Theme.red) : AnyShapeStyle(.secondary))
            Text(column.meant ?? " ")
                .fontWeight(column.misread ? .bold : .regular)
                .padding(.horizontal, column.misread ? 3 : 0)
                .background(column.misread ? Theme.accent.opacity(0.32) : .clear, in: .rect(cornerRadius: 4))
        }
        .font(.system(size: 13.5, design: .rounded))
        .contentShape(.rect)
        .onTapGesture(perform: tap)
    }
}

private struct MisreadWordRow: View {
    let word: MisreadSheetModel.Word
    var model: MisreadSheetModel
    var coach: MisreadCoach

    private var lit: Bool { model.highlighted == word.misread.word }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(word.misread.word).font(.system(size: 17, weight: .bold, design: .rounded))
                    if let ipa = word.misread.ipa { Text(ipa).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                }
                Text(heardLine).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)
                if !word.earlier.isEmpty {
                    Text(earlierLine).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.accentText)
                }
            }
            Spacer(minLength: 4)
            Button("这个我没读错") { coach.notMisread(word.misread.word) }
                .buttonStyle(.glass)
                .controlSize(.small)
            Button("慢") { coach.speak(word.misread.word, slow: true) }
                .buttonStyle(.glass)
                .controlSize(.small)
            Button { coach.speak(word.misread.word, slow: false) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    // Solid: a tinted glass greys out while the sheet doesn't have the keyboard.
                    .background(Theme.accent, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.accent.opacity(lit ? 0.18 : 0), in: .rect(cornerRadius: 12))
        .animation(Theme.ease, value: lit)
    }

    private var heardLine: AttributedString {
        var heard = AttributedString(word.misread.heard)
        heard.strikethroughStyle = .single
        var line = AttributedString("听成了 ") + heard
        if let tip = word.misread.tip { line += AttributedString(" · \(tip)") }
        return line
    }

    private var earlierLine: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        let days = (word.earlier + [model.createdAt]).map(f.string(from:))
        return "第 \(days.count) 次（\(days.joined(separator: "、"))）"
    }
}

private struct MisreadTakeRow: View {
    let take: MisreadSheetModel.Take
    var coach: MisreadCoach

    static func circled(_ n: Int) -> String {
        (1...20).contains(n) ? String(UnicodeScalar(0x2460 + n - 1)!) : "(\(n))"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.circled(take.id)).foregroundStyle(.secondary)
            Text(marked).lineLimit(2)
            Spacer(minLength: 4)
            if take.audio != nil {
                Button { coach.play(take) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
            }
        }
        .font(.system(size: 13, design: .rounded))
        .id(take.id)
    }

    private var marked: AttributedString {
        var out = AttributedString()
        for (i, (word, mark)) in take.words.enumerated() {
            var piece = AttributedString((i > 0 ? " " : "") + word)
            switch mark {
            case .right: piece.foregroundColor = Theme.green; piece.font = .system(size: 13, weight: .bold, design: .rounded)
            case .heardAgain: piece.foregroundColor = Theme.red; piece.font = .system(size: 13, weight: .bold, design: .rounded)
            case .plain: break
            }
            out += piece
        }
        return take.words.isEmpty ? AttributedString("（没听到）") : out
    }
}

/// The amber bars of the take being recorded.
private struct MisreadLevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<14, id: \.self) { i in
                let wave = 0.55 + 0.45 * sin(Double(i) * 1.3)
                Capsule().fill(Theme.accent)
                    .frame(width: 3, height: max(3, CGFloat(level) * 16 * wave))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// The small bar right of the pill: 「读音 · cards」, click to open, × to drop it.
struct MisreadBarView: View {
    var model: MisreadSheetModel
    var coach: MisreadCoach

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 7) {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                Text(model.barTitle).font(.system(size: 12.5, weight: .medium, design: .rounded)).lineLimit(1)
                Button { coach.done() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("不练了")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
            .onTapGesture { coach.expand() }
        }
        .padding(8)
        .fixedSize()
        .environment(\.controlActiveState, .key)
    }
}

/// Lays its children out in lines, wrapping when the width runs out.
struct MisreadFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = lines(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in line.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var out: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, height: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !items.isEmpty, x + size.width > width {
                out.append((items, x - spacing, height))
                items = []; x = 0; height = 0
            }
            items.append(i); x += size.width + spacing; height = max(height, size.height)
        }
        if !items.isEmpty { out.append((items, x - spacing, height)) }
        return out
    }
}
