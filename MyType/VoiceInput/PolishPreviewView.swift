// Abstract:
// SwiftUI content of the polish preview panel, in the overlay's smoked
// glass (it read as white text on a light material in light mode before).
// Two states:
//   - .loading: 3 pulsing dots, sized to fit
//   - .content: the polished text with what changed marked against the
//     selection, and a footer saying the keys (⏎ replace · esc cancel) and
//     which model took how long. Caps at 480pt wide.
// The hosting NSPanel is a fully transparent shell — all visuals live here.

import SwiftUI

// MARK: - View Model

@MainActor @Observable
final class PolishPreviewViewModel {
    enum State: Equatable {
        case loading
        case content(String, original: String, footnote: String)
    }

    var state: State = .loading
}

// MARK: - View

struct PolishPreviewView: View {
    @Bindable var model: PolishPreviewViewModel

    /// Hard cap on card width — beyond this, text wraps. The view's
    /// natural fitting size is whatever's smaller than this.
    private let maxWidth: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .loading:
                LoadingDots()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            case .content(let text, let original, let footnote):
                Text(PreviewDiff.attributed(from: original, to: text))
                    .font(.system(size: 14.5, design: .rounded))
                    .lineSpacing(3)
                    .foregroundStyle(Color.white.opacity(0.95))
                    .textSelection(.enabled)
                    .frame(maxWidth: maxWidth - 30, alignment: .leading)
                    .padding(.horizontal, 15)
                    .padding(.top, 12)
                    .padding(.bottom, 9)
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.horizontal, 15)
                HStack(spacing: 6) {
                    Key("⏎"); Text("替换选中的文字")
                    Spacer().frame(width: 8)
                    Key("esc"); Text("取消")
                    Spacer().frame(width: 18)
                    Text(footnote)
                }
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(SmokedCard(radius: 14))
        .environment(\.colorScheme, .dark)
    }
}

private struct Key: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(Color.white.opacity(0.14), in: .rect(cornerRadius: 5, style: .continuous))
    }
}

/// The diff in colours that read on the dark glass.
private enum PreviewDiff {
    static func attributed(from a: String, to b: String) -> AttributedString {
        guard let ops = TextDiff.ops(from: a, to: b) else { return AttributedString(b) }
        var result = AttributedString()
        for op in ops {
            switch op {
            case .equal(let s):
                result.append(AttributedString(s))
            case .delete(let s):
                var part = AttributedString(s)
                part.foregroundColor = Color(red: 1, green: 0.61, blue: 0.62)
                part.backgroundColor = Color(red: 0.9, green: 0.28, blue: 0.3).opacity(0.25)
                part.strikethroughStyle = .single
                result.append(part)
            case .insert(let s):
                var part = AttributedString(s)
                part.foregroundColor = Color(red: 0.55, green: 0.88, blue: 0.64)
                part.backgroundColor = Color(red: 0.18, green: 0.66, blue: 0.31).opacity(0.28)
                result.append(part)
            }
        }
        return result
    }
}

// MARK: - Loading Dots

private struct LoadingDots: View {
    @State private var phase: Int = -1

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
                    .opacity(phase == i ? 1 : 0.28)
                    .scaleEffect(phase == i ? 1 : 0.82)
                    .animation(.easeOut(duration: 0.18), value: phase)
            }
        }
        .task {
            while !Task.isCancelled {
                for i in 0..<3 {
                    phase = i
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }
}
