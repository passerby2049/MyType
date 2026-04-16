// Abstract:
// SwiftUI capsule UI for voice input overlay — waveform animation,
// control buttons, and scan timer for processing state.

import SwiftUI

// MARK: - SwiftUI Overlay View

struct VoiceInputOverlayView: View {
    var manager: VoiceInputManager
    @State private var cancelHovered = false
    @State private var doneHovered = false

    @State private var scanPosition: Int = -2
    @State private var scanDirection: Int = 1
    @State private var scanTimer: Task<Void, Never>?

    var body: some View {
        let isDone = manager.state == .done
        let isProcessing = manager.state == .processing
        let isVisible = manager.state == .recording || manager.state == .processing || manager.state == .done

        let capsuleWidth: CGFloat = isDone ? 36 : 140
        let capsuleHeight: CGFloat = 36

        ZStack {
            // Morphing background — Capsule auto-adjusts corner radius
            Capsule()
                .fill(Color.black)

            Capsule()
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5)

            // ── All contents always present, animated via opacity ──

            let isRecording = manager.state == .recording

            // Cancel button (left) — slides out left when processing
            cancelButton
                .opacity(isRecording ? 1 : 0)
                .offset(x: isRecording ? -48 : -80)

            // Waveform (center)
            VoiceInputWaveform(
                level: manager.audioLevel,
                scanning: isProcessing,
                scanPosition: scanPosition
            )
            .opacity(isDone ? 0 : 1)

            // Done button (right) — slides out right when processing
            doneButton
                .opacity(isRecording ? 1 : 0)
                .offset(x: isRecording ? 48 : 80)

            // Done checkmark — slides from right-button position to center
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(red: 0.20, green: 0.84, blue: 0.29))
                .offset(x: isDone ? 0 : 48)
                .opacity(isDone ? 1 : 0)
        }
        .frame(width: capsuleWidth, height: capsuleHeight)
        .clipShape(Capsule())
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: manager.state)
        // Match the NSPanel content size
        .frame(width: 200, height: 80)
        .opacity(isVisible ? 1 : 0)
        .onChange(of: manager.state) { _, newState in
            if newState == .processing {
                startScanning()
            } else {
                stopScanning()
            }
        }
    }

    // MARK: - Scan Timer

    private func startScanning() {
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
