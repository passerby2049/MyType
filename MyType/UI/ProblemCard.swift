// Abstract:
// When a dictation doesn't end with its text typed, a small card in the
// overlay's smoked glass appears just above where the pill was and says what
// happened, where the text is, and the one next step (docs/design-ui-2026-10.md
// 「浮条」). The pill itself still never shows words. One card at a time; it
// fades after a few seconds, and stays while the pointer is on it.

import AppKit
import SwiftUI

@MainActor
final class ProblemCard {
    static let shared = ProblemCard()

    enum Problem: Equatable {
        case copied
        case insertFailed(String)
        case polishTimeout
        case polishArrived(String)
        case noSpeech
        case recordingFailed(String)
        case failed(String)
    }

    private var panel: NSPanel?
    private let model = ProblemCardModel()
    private var hideTask: Task<Void, Never>?

    func show(_ problem: Problem) {
        model.problem = problem
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.animations = [:]
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    /// The late polish came back while the timeout card is still up.
    func polishArrived(_ text: String) {
        guard panel?.isVisible == true, model.problem == .polishTimeout else { return }
        model.problem = .polishArrived(text)
        if let panel { place(panel) }
        scheduleHide()
    }

    func dismiss() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            if panel?.alphaValue == 0 { panel?.orderOut(nil) }
        })
    }

    fileprivate func hovering(_ inside: Bool) {
        if inside { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let seconds: Double = model.problem == .noSpeech ? 2.5 : 5
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: ProblemCardView(model: model, hover: { [weak self] in self?.hovering($0) }))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        return panel
    }

    /// Centered over the pill's spot (bottom of the screen with the mouse,
    /// above the Dock), its bottom 10 pt above the pill's top.
    private func place(_ panel: NSPanel) {
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let pillTop = frame.minY + 12 + 36
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: pillTop + 10, width: size.width, height: size.height), display: true)
    }
}

@MainActor @Observable
final class ProblemCardModel {
    var problem: ProblemCard.Problem = .noSpeech
}

struct ProblemCardView: View {
    var model: ProblemCardModel
    let hover: (Bool) -> Void

    private var content: (icon: String, tint: Color, title: String, detail: String?, actions: [(String, Bool, () -> Void)]) {
        switch model.problem {
        case .copied:
            return ("doc.on.clipboard", Theme.accent, "没有可以输入的地方，已复制", "在要放的地方按 ⌘V", [])
        case .insertFailed(let text):
            return ("exclamationmark", Theme.red, "没键入成功", "这句留在历史里", [("复制", true, { RecordActions.copy(text); ProblemCard.shared.dismiss() })])
        case .polishTimeout:
            return ("exclamationmark", Theme.red, "润色没回来，键入的是原文", "大模型 10 秒没回应；回来了会补进历史", [("历史", false, openHistory)])
        case .polishArrived(let text):
            return ("checkmark", Theme.green, "润色回来了", "键入的还是原文", [("复制润色后的", true, { RecordActions.copy(text); ProblemCard.shared.dismiss() })])
        case .noSpeech:
            return ("waveform", Color.white.opacity(0.6), "没听清，什么也没键入", nil, [])
        case .recordingFailed(let message):
            return ("mic.slash", Theme.red, "录音没开起来", message, [])
        case .failed(let message):
            return ("exclamationmark", Theme.red, "这句没处理完", message, [("历史", false, openHistory)])
        }
    }

    var body: some View {
        let c = content
        HStack(spacing: 11) {
            Image(systemName: c.icon)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(c.tint)
                .frame(width: 22, height: 22)
                .background(c.tint.opacity(0.22), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.system(size: 13, weight: .medium, design: .rounded))
                if let detail = c.detail {
                    Text(detail).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
            }
            if !c.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(c.actions.indices, id: \.self) { i in
                        let action = c.actions[i]
                        Button(action: action.2) {
                            Text(action.0)
                                .font(.system(size: 12, weight: action.1 ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(action.1 ? Color(white: 0.1) : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(action.1 ? Theme.accent : Color.white.opacity(0.12), in: .rect(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 13)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .fixedSize()
        .background(SmokedCard(radius: 13))
        .environment(\.colorScheme, .dark)
        .onHover(perform: hover)
    }

    private func openHistory() {
        MainWindowController.shared.show(.history)
        ProblemCard.shared.dismiss()
    }
}

/// The overlay's smoked glass as a rounded rectangle: behind-window blur
/// (HUD), 65 % smoke, a 0.5 pt rim and a faint top highlight.
struct SmokedCard: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            CardBlur(radius: radius)
            shape.fill(Color(red: 0.055, green: 0.055, blue: 0.07).opacity(0.65))
            shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.20), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct CardBlur: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        let d = radius * 2 + 2
        let mask = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        view.maskImage = mask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
