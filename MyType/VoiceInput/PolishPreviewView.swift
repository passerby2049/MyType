// Abstract:
// SwiftUI content of the polish preview panel. Two states:
//   - .loading: 3 pulsing dots, sized to fit
//   - .content: polished text, sized to fit (caps at 480pt wide)
// The Liquid Glass material comes from `.glassEffect` (macOS 26+),
// matching the Jot project's HUD pattern. The hosting NSPanel is a
// fully transparent shell — all visuals live in this view.

import SwiftUI

// MARK: - View Model

@MainActor @Observable
final class PolishPreviewViewModel {
    enum State: Equatable {
        case loading
        case content(String)
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
        VStack(spacing: 0) {
            switch model.state {
            case .loading:
                LoadingDots()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            case .content(let text):
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: maxWidth, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Loading Dots

private struct LoadingDots: View {
    @State private var phase: Int = -1

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(red: 1.0, green: 0.624, blue: 0.039))
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
