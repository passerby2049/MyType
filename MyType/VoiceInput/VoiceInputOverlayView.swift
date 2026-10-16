// Abstract:
// SwiftUI capsule UI for voice input overlay: a small smoked-glass pill
// holding only the waveform while recording, then one continuous motion
// (VoiceInputProcessingMotion): the recording's real loudness while it
// is transcribed, the polishing ring, and the completion mark. Cancel
// and stop bud out of the pill's sides on hover.

import AppKit
import SwiftUI

// MARK: - SwiftUI Overlay View

struct VoiceInputOverlayView: View {
    var manager: VoiceInputManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var motion = VoiceInputProcessingMotion()
    @State private var motionPhase: VoiceInputProcessingMotion.Phase = .reading
    /// From the end of recording until the capsule has faded away.
    @State private var showsMotion = false
    /// Polishing ran this round: `.inserting` keeps the ring's width.
    @State private var polished = false
    /// Set when `.done` arrives: the capsule fades and shrinks away.
    @State private var exiting = false
    /// The width the capsule had when it was dismissed, held while it
    /// fades so it doesn't stretch back out; cleared once it's hidden.
    @State private var dismissedWidth: CGFloat?

    @State private var showsControls = false
    @State private var hoverTask: Task<Void, Never>?

    private var state: VoiceInputState { manager.state }
    /// Green mark only when the text really reached the target app —
    /// not for a clipboard fallback or a failed insert.
    private var delivered: Bool { manager.deliveryStatus == .inserted }
    /// Cancel is offered while recording, transcribing or polishing;
    /// stop only while recording.
    private var controlsAvailable: Bool { state == .recording || state.canCancelProcessing }

    private var capsuleWidth: CGFloat { width(for: state) }

    private func width(for state: VoiceInputState) -> CGFloat {
        switch state {
        case .recording: 96
        case .transcribing: 88
        case .polishing: 44
        case .inserting: polished ? 44 : 88
        case .done: 36
        case .idle, .failure: dismissedWidth ?? 96
        }
    }

    private var shellAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch state {
        case .idle, .failure:
            return .easeOut(duration: 0.25)
        case .recording, .transcribing, .polishing, .inserting, .done:
            // The design's spring (k=300, c=31), shared with the marks.
            return .spring(response: 0.36, dampingFraction: 0.89)
        }
    }

    var body: some View {
        let isVisible = state == .recording || state.isProcessing || state == .done

        ZStack {
            pill

            if showsControls {
                controlButton("xmark", label: "Cancel") { manager.cancelRecording() }
                    .transition(Self.bud(fromRight: true))
                    .offset(x: -(capsuleWidth / 2 + 20))
                if state == .recording {
                    controlButton("stop.fill", label: "Finish recording") { manager.toggleRecording() }
                        .transition(Self.bud(fromRight: false))
                        .offset(x: capsuleWidth / 2 + 20)
                }
            }
        }
        .opacity(isVisible && !exiting ? 1 : 0)
        .scaleEffect(isVisible && !exiting ? 1 : (state == .done && delivered ? 0.9 : 0.88))
        .animation(shellAnimation, value: state)
        // Match the NSPanel content size
        .frame(width: VoiceInputPanel.contentSize.width, height: VoiceInputPanel.contentSize.height)
        .onChange(of: manager.state) { oldState, newState in
            stateChanged(from: oldState, to: newState)
        }
        .onDisappear { hoverTask?.cancel() }
    }

    private var pill: some View {
        ZStack {
            // Live waveform. Leaves at once when recording ends: the
            // motion's marks take over in the same places.
            if state == .recording {
                VoiceInputWaveform(level: manager.audioLevel)
                    .transition(.identity)
            }

            if showsMotion {
                VoiceInputProcessingView(motion: motion, phase: motionPhase)
                    .frame(width: 140, height: 36)
            }
        }
        .frame(width: capsuleWidth, height: 36)
        .clipShape(Capsule())
        .background(SmokedGlass(diameter: 36))
        .contentShape(Capsule())
        .onHover { hover($0) }
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "xmark" ? 10 : 9, weight: .semibold))
                .foregroundStyle(Color(white: 0.78))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background(SmokedGlass(diameter: 28))
        .onHover { hover($0) }
        .help(symbol == "xmark" ? "取消 · Esc" : "结束 · fn")
        .accessibilityLabel(label)
    }

    /// A button buds out of the pill's edge: from small, near the pill,
    /// to its place beside it.
    private static func bud(fromRight: Bool) -> AnyTransition {
        .scale(scale: 0.45).combined(with: .offset(x: fromRight ? 22 : -22)).combined(with: .opacity)
    }

    // MARK: - Hover

    /// Hovering the pill buds cancel (and, while recording, stop) out of
    /// its sides after ~150 ms; leaving gives ~280 ms of grace so the
    /// pointer can reach them. Esc and fn work as before.
    private func hover(_ inside: Bool) {
        hoverTask?.cancel()
        guard controlsAvailable || !inside else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(inside ? 150 : 280))
            guard !Task.isCancelled else { return }
            let show = inside && controlsAvailable
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.8)) {
                showsControls = show
            }
        }
    }

    // MARK: - State

    private func stateChanged(from oldState: VoiceInputState, to newState: VoiceInputState) {
        switch newState {
        case .recording:
            dismissedWidth = nil
            polished = false
            showsMotion = false
        case .transcribing:
            motion.beginReading(lastLevel: manager.audioLevel, history: manager.levelHistory, at: .now)
            setMotion(.reading)
            showsMotion = true
        case .polishing:
            polished = true
            motion.enter(.ring, at: .now)
            setMotion(.ring)
        case .inserting:
            break
        case .done:
            let phase: VoiceInputProcessingMotion.Phase = delivered ? .done : .fading
            motion.enter(phase, at: .now)
            setMotion(phase)
        case .idle, .failure:
            dismissedWidth = width(for: oldState)
            motion.enter(.fading, at: .now)
            setMotion(.fading)
            Task {
                // After the panel's 0.25s fade: back to the resting shape,
                // and the motion stops drawing.
                try? await Task.sleep(for: .milliseconds(300))
                guard Self.isDismissed(manager.state) else { return }
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) {
                    dismissedWidth = nil
                    showsMotion = false
                    polished = false
                }
            }
        }

        // Stop leaves with recording; cancel leaves once nothing can be
        // cancelled (inserting, done, dismissed).
        if !(newState == .recording || newState.canCancelProcessing) {
            hoverTask?.cancel()
            showsControls = false
        }

        if newState == .done {
            // Delivered: hold the mark, fade from ~0.5s to ~0.8s.
            // Otherwise: no success mark, just shrink and fade.
            let exit: Animation = delivered
                ? .easeInOut(duration: 0.3).delay(0.5)
                : .easeOut(duration: 0.25)
            withAnimation(exit) { exiting = true }
        } else if exiting {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { exiting = false }
        }
    }

    private func setMotion(_ phase: VoiceInputProcessingMotion.Phase) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { motionPhase = phase }
    }

    private static func isDismissed(_ state: VoiceInputState) -> Bool {
        switch state {
        case .idle, .failure: true
        case .recording, .transcribing, .polishing, .inserting, .done: false
        }
    }
}

// MARK: - Smoked Glass

/// The pill's material: what's behind the window, blurred
/// (NSVisualEffectView, behind-window), under a smoked tint dark enough
/// that the amber marks stay clear over a white window; a hairline rim
/// and a faint top highlight. Ends are round: `diameter` is the height.
/// Under Reduce Transparency the blur turns opaque on its own.
private struct SmokedGlass: View {
    let diameter: CGFloat
    /// How much of the smoke covers the blur (the design page's ① is 0.8
    /// over a plain blur; the HUD material is already dark itself).
    static let tint = 0.65

    var body: some View {
        ZStack {
            BehindWindowBlur(diameter: diameter)
            Capsule().fill(Color(red: 0.055, green: 0.055, blue: 0.07).opacity(Self.tint))
            Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
            Capsule().strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.20), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1
            )
        }
        .allowsHitTesting(false)
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    let diameter: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        // SwiftUI clipping doesn't reach a behind-window blur; a
        // stretchable round mask keeps it a capsule at any width.
        view.maskImage = Self.capsuleMask(diameter)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    private static func capsuleMask(_ d: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: d / 2, left: d / 2, bottom: d / 2, right: d / 2)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Waveform View

/// Live waveform bars that respond to the recording level.
struct VoiceInputWaveform: View {
    var level: Float
    private let barCount = VoiceInputProcessingMotion.markCount

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                VoiceInputWaveformBar(index: i, level: level, barCount: barCount)
            }
        }
    }
}

struct VoiceInputWaveformBar: View {
    let index: Int
    let level: Float
    let barCount: Int

    @State private var randomOffset: Double = 0

    private var barHeight: Double {
        let base = 3.0
        let maxHeight = 18.0
        let center = Double(barCount - 1) / 2.0
        let distFromCenter = abs(Double(index) - center) / center
        let envelope = 1.0 - pow(distFromCenter, 1.6) * 0.85

        let levelContribution = Double(level) * maxHeight * envelope
        // Wobble only while there's sound: at the gate's 0 the bars stand still.
        let noise = sin(Double(index) * 1.7 + randomOffset) * 2.2 * Double(level)

        return max(base, levelContribution + base + noise)
    }

    var body: some View {
        Capsule()
            .fill(Color(red: 1.0, green: 0.624, blue: 0.039))
            .frame(width: 2, height: barHeight)
            .shadow(color: Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.6), radius: 2)
            .animation(.easeInOut(duration: 0.1), value: level)
            .task {
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        randomOffset += 0.8
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }
}
