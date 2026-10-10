// Abstract:
// SwiftUI capsule UI for voice input overlay — waveform animation,
// control buttons, scan timer while transcribing, and the polishing
// ring / completion mark (VoiceInputPolishRing.swift).

import SwiftUI

// MARK: - SwiftUI Overlay View

struct VoiceInputOverlayView: View {
    var manager: VoiceInputManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cancelHovered = false
    @State private var doneHovered = false

    @State private var scanPosition: Int = -2
    @State private var scanDirection: Int = 1
    @State private var scanTimer: Task<Void, Never>?

    /// Which processing form is on screen. `.inserting` keeps the last
    /// one, so delivery doesn't flash a different shape.
    @State private var look: ProcessingLook = .scan
    @State private var ringStart = Date.distantPast
    @State private var doneStart = Date.distantPast
    /// Set when `.done` arrives: the capsule fades and shrinks away.
    @State private var exiting = false
    /// The width the capsule had when it was dismissed, held while it
    /// fades so it doesn't stretch back out; cleared once it's hidden.
    @State private var dismissedWidth: CGFloat?

    @State private var showsProcessingCancel = false
    @State private var processingCancelTask: Task<Void, Never>?

    private enum ProcessingLook { case scan, ring }

    private var state: VoiceInputState { manager.state }
    private static func isDismissed(_ state: VoiceInputState) -> Bool {
        switch state {
        case .idle, .failure: true
        case .recording, .transcribing, .polishing, .inserting, .done: false
        }
    }
    private var showsRing: Bool {
        state == .polishing || (state == .inserting && look == .ring)
    }
    private var showsScan: Bool {
        state == .transcribing || (state == .inserting && look == .scan)
    }
    /// Green mark only when the text really reached the target app —
    /// not for a clipboard fallback or a failed insert.
    private var delivered: Bool { manager.deliveryStatus == .inserted }

    private var capsuleWidth: CGFloat { width(for: state) }

    private func width(for state: VoiceInputState) -> CGFloat {
        switch state {
        case .polishing: 44
        case .inserting: look == .ring ? 44 : 140
        case .done: 36
        case .idle, .failure: dismissedWidth ?? 140
        case .recording, .transcribing: 140
        }
    }

    /// Recording ↔ transcription keep their original spring; the ring,
    /// completion and cancel use the design's calmer one (k=300, c=31).
    private var shellAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch state {
        case .recording, .transcribing:
            return .spring(response: 0.45, dampingFraction: 0.7)
        case .inserting where look == .scan:
            return .spring(response: 0.45, dampingFraction: 0.7)
        case .idle, .failure:
            return .easeOut(duration: 0.25)
        case .polishing, .inserting, .done:
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
        .frame(width: 200, height: 80)
        .onChange(of: manager.state) { oldState, newState in
            stateChanged(from: oldState, to: newState)
        }
        .onDisappear {
            stopScanning()
            processingCancelTask?.cancel()
        }
    }

    private var capsule: some View {
        ZStack {
            // Morphing background — Capsule auto-adjusts corner radius
            Capsule()
                .fill(Color.black)

            Capsule()
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)

            // ── All contents always present, animated via opacity ──

            let isRecording = state == .recording

            // Cancel button (left) — slides out left when processing
            cancelButton
                .opacity(isRecording ? 1 : 0)
                .offset(x: isRecording ? -48 : -80)

            // Waveform (center) — live while recording, scanning while
            // transcribing; fades as the ring winds in.
            VoiceInputWaveform(
                level: manager.audioLevel,
                scanning: state.isProcessing,
                scanPosition: scanPosition
            )
            .opacity(isRecording || showsScan ? 1 : 0)

            // Done button (right) — slides out right when processing
            doneButton
                .opacity(isRecording ? 1 : 0)
                .offset(x: isRecording ? 48 : 80)

            if showsRing {
                VoiceInputPolishRing(start: ringStart)
                    .transition(.opacity)
            }

            if state == .done && delivered {
                VoiceInputCompletionMark(start: doneStart, fromRing: look == .ring)
            }
        }
        .frame(width: capsuleWidth, height: 36)
        .clipShape(Capsule())
        .onHover { processingHover($0) }
    }

    // MARK: - State

    private func stateChanged(from oldState: VoiceInputState, to newState: VoiceInputState) {
        switch newState {
        case .transcribing:
            look = .scan
        case .polishing:
            look = .ring
            ringStart = .now
        case .idle, .failure:
            dismissedWidth = width(for: oldState)
            Task {
                // After the panel's 0.25s fade: back to the resting shape.
                try? await Task.sleep(for: .milliseconds(300))
                guard Self.isDismissed(manager.state) else { return }
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) {
                    dismissedWidth = nil
                    look = .scan
                }
            }
        case .recording:
            dismissedWidth = nil
            look = .scan
        case .inserting, .done:
            break
        }

        if showsScan { startScanning() } else { stopScanning() }

        if !newState.canCancelProcessing || look != .ring {
            processingCancelTask?.cancel()
            showsProcessingCancel = false
        }

        if newState == .done {
            doneStart = .now
            // Delivered: hold the mark, fade from ~0.5s to ~0.8s.
            // Otherwise: no success mark, just gather and fade.
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

    // MARK: - Scan Timer

    private func startScanning() {
        guard scanTimer == nil else { return }
        scanPosition = -2
        scanDirection = 1
        scanTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                scanPosition += scanDirection * 2
                // Ping-pong: reverse direction at edges
                if scanPosition >= 29 {
                    scanDirection = -1
                } else if scanPosition <= -2 {
                    scanDirection = 1
                }
            }
        }
    }

    private func stopScanning() {
        scanTimer?.cancel()
        scanTimer = nil
        scanPosition = -2
    }

    // MARK: - Processing Cancel

    /// While the ring is up, hovering the capsule reveals a separate
    /// cancel button to its left (~150 ms in, ~280 ms grace on leave so
    /// the pointer can reach it). Esc cancels as before.
    private func processingHover(_ inside: Bool) {
        processingCancelTask?.cancel()
        guard state.canCancelProcessing, look == .ring else { return }
        processingCancelTask = Task {
            try? await Task.sleep(for: .milliseconds(inside ? 150 : 280))
            guard !Task.isCancelled else { return }
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

/// Animated waveform bars that respond to audio level.
/// Supports a "scanning" mode: bars freeze and a highlight beam sweeps across.
struct VoiceInputWaveform: View {
    var level: Float
    var scanning: Bool = false
    var scanPosition: Int = -2
    private let liveBarCount = 14
    private let scanBarCount = 28

    private var barCount: Int { scanning ? scanBarCount : liveBarCount }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                VoiceInputWaveformBar(
                    index: i,
                    level: level,
                    barCount: barCount,
                    scanning: scanning,
                    scanPosition: scanPosition
                )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: scanning)
    }
}

struct VoiceInputWaveformBar: View {
    let index: Int
    let level: Float
    let barCount: Int
    var scanning: Bool = false
    var scanPosition: Int = -2

    @State private var randomOffset: Double = 0
    @State private var frozenHeight: Double = 8

    private func generateFrozenHeight() {
        let center = Double(barCount - 1) / 2.0
        let distFromCenter = abs(Double(index) - center) / center
        let envelope = 1.0 - pow(distFromCenter, 1.6) * 0.85
        let random = Double.random(in: 0.4...1.0)
        frozenHeight = 3.0 + 15.0 * envelope * random
    }

    /// Always-computed live height from audio level (never checks scanning).
    private var liveHeight: Double {
        let base = 3.0
        let maxHeight = 18.0
        let center = Double(barCount - 1) / 2.0
        let distFromCenter = abs(Double(index) - center) / center
        let envelope = 1.0 - pow(distFromCenter, 1.6) * 0.85

        let levelContribution = Double(level) * maxHeight * envelope
        let noise = sin(Double(index) * 1.7 + randomOffset) * 2.2 * Double(max(level, 0.15))

        return max(base, levelContribution + base + noise)
    }

    /// Display height: frozen snapshot when scanning, live otherwise.
    private var barHeight: Double {
        scanning ? frozenHeight : liveHeight
    }

    /// How bright this bar should be during scanning.
    /// Center of 3-bar beam = 1.0, edges = 0.6, outside = 0.15
    private var scanOpacity: Double {
        guard scanning else { return 1.0 }
        let dist = abs(index - scanPosition)
        switch dist {
        case 0: return 1.0   // center of beam
        case 1: return 0.6   // edge of beam
        default: return 0.15 // dimmed
        }
    }

    /// Glow radius: only the beam center gets a glow
    private var glowRadius: CGFloat {
        guard scanning else { return 2 }
        let dist = abs(index - scanPosition)
        return dist == 0 ? 4 : (dist == 1 ? 2 : 0)
    }

    var body: some View {
        Capsule()
            .fill(Color(red: 1.0, green: 0.624, blue: 0.039))
            .frame(width: 2, height: barHeight)
            .opacity(scanOpacity)
            .shadow(color: Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.6), radius: glowRadius)
            .animation(.easeOut(duration: 0.08), value: scanPosition)
            .animation(.easeInOut(duration: 0.1), value: level)
            .task {
                while !Task.isCancelled {
                    if !scanning {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            randomOffset += 0.8
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            .onAppear {
                if scanning { generateFrozenHeight() }
            }
            .onChange(of: scanning) { _, isScanning in
                if isScanning { generateFrozenHeight() }
            }
    }
}
