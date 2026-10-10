// Abstract:
// SwiftUI capsule UI for voice input overlay — the live waveform and
// control buttons while recording; after that, one continuous motion
// (VoiceInputProcessingMotion): the recording's real loudness while it
// is transcribed, the polishing ring, and the completion mark.

import SwiftUI

// MARK: - SwiftUI Overlay View

struct VoiceInputOverlayView: View {
    var manager: VoiceInputManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cancelHovered = false
    @State private var doneHovered = false

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

    @State private var showsProcessingCancel = false
    @State private var processingCancelTask: Task<Void, Never>?

    private var state: VoiceInputState { manager.state }
    /// Green mark only when the text really reached the target app —
    /// not for a clipboard fallback or a failed insert.
    private var delivered: Bool { manager.deliveryStatus == .inserted }

    private var capsuleWidth: CGFloat { width(for: state) }

    private func width(for state: VoiceInputState) -> CGFloat {
        switch state {
        case .recording: 140
        case .transcribing: 104
        case .polishing: 44
        case .inserting: polished ? 44 : 104
        case .done: 36
        case .idle, .failure: dismissedWidth ?? 140
        }
    }

    private var shellAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch state {
        case .recording:
            return .spring(response: 0.45, dampingFraction: 0.7)
        case .idle, .failure:
            return .easeOut(duration: 0.25)
        case .transcribing, .polishing, .inserting, .done:
            // The design's spring (k=300, c=31), shared with the marks.
            return .spring(response: 0.36, dampingFraction: 0.89)
        }
    }

    var body: some View {
        let isVisible = state == .recording || state.isProcessing || state == .done

        ZStack {
            capsule
            processingCancelButton
                .offset(x: -(capsuleWidth / 2 + 43))
        }
        .opacity(isVisible && !exiting ? 1 : 0)
        .scaleEffect(isVisible && !exiting ? 1 : (state == .done && delivered ? 0.9 : 0.88))
        .animation(shellAnimation, value: state)
        // Match the NSPanel content size
        .frame(width: VoiceInputPanel.contentSize.width, height: VoiceInputPanel.contentSize.height)
        .onChange(of: manager.state) { oldState, newState in
            stateChanged(from: oldState, to: newState)
        }
        .onDisappear { processingCancelTask?.cancel() }
    }

    private var capsule: some View {
        ZStack {
            // Morphing background — Capsule auto-adjusts corner radius
            Capsule()
                .fill(Color.black)

            Capsule()
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)

            let isRecording = state == .recording

            // Cancel button (left) — slides out left when processing
            cancelButton
                .opacity(isRecording ? 1 : 0)
                .offset(x: isRecording ? -48 : -80)

            // Live waveform. Leaves at once when recording ends: the
            // motion's marks take over in the same places.
            if isRecording {
                VoiceInputWaveform(level: manager.audioLevel)
                    .transition(.identity)
            }

            if showsMotion {
                VoiceInputProcessingView(motion: motion, phase: motionPhase)
                    .frame(width: 140, height: 36)
            }

            // Done button (right) — slides out right when processing
            doneButton
                .opacity(isRecording ? 1 : 0)
                .offset(x: isRecording ? 48 : 80)
        }
        .frame(width: capsuleWidth, height: 36)
        .clipShape(Capsule())
        .onHover { processingHover($0) }
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

        if !newState.canCancelProcessing {
            processingCancelTask?.cancel()
            showsProcessingCancel = false
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

    // MARK: - Processing Cancel

    /// While transcribing or polishing, hovering the capsule reveals a
    /// separate cancel button to its left (~150 ms in, ~280 ms grace on
    /// leave so the pointer can reach it). Esc cancels as before.
    private func processingHover(_ inside: Bool) {
        processingCancelTask?.cancel()
        guard state.canCancelProcessing else { return }
        processingCancelTask = Task {
            try? await Task.sleep(for: .milliseconds(inside ? 150 : 280))
            guard !Task.isCancelled, manager.state.canCancelProcessing else { return }
            withAnimation(.easeOut(duration: 0.15)) { showsProcessingCancel = inside }
        }
    }

    private var processingCancelButton: some View {
        Button {
            manager.cancelRecording()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(white: 0.69))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { processingHover($0) }
        .help("取消 · Esc")
        .accessibilityLabel("Cancel processing")
        .opacity(showsProcessingCancel ? 1 : 0)
        .offset(x: showsProcessingCancel ? 0 : 5)
        .allowsHitTesting(showsProcessingCancel)
        .disabled(!showsProcessingCancel)
    }

    // MARK: - Buttons

    private var cancelButton: some View {
        Button {
            manager.cancelRecording()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.23))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color(red: 1.0, green: 0.27, blue: 0.23).opacity(cancelHovered ? 0.15 : 0))
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { cancelHovered = $0 }
        .accessibilityLabel("Cancel recording")
        // Stop clicks when hidden
        .disabled(manager.state != .recording)
    }

    private var doneButton: some View {
        Button {
            manager.toggleRecording()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 0.20, green: 0.84, blue: 0.29))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color(red: 0.20, green: 0.84, blue: 0.29).opacity(doneHovered ? 0.15 : 0))
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { doneHovered = $0 }
        .accessibilityLabel("Finish recording")
        .disabled(manager.state != .recording)
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
        let noise = sin(Double(index) * 1.7 + randomOffset) * 2.2 * Double(max(level, 0.15))

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
