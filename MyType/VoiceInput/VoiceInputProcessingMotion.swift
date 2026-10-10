// Abstract:
// What the overlay capsule shows once recording ends: one set of 14 marks
// that carries on from the recording's bars, lays out the real loudness of
// the whole recording while it is transcribed, rolls into the dotted ring
// while the LLM polishes, and gathers into the green completion mark.
// Timings follow design/voice-overlay/handoff-2026-10-10.md and
// transcribe-options-2026-10-10.html (version E).

import SwiftUI

// MARK: - Motion

/// The marks' state, stepped once per display frame by
/// `VoiceInputProcessingView`. Not observed: the timeline redraws it.
@MainActor
final class VoiceInputProcessingMotion {
    enum Phase: Equatable {
        /// Transcribing: the recording's loudness, a light reading across it.
        case reading
        /// Polishing: twelve dots on a ring, a highlight travelling round.
        case ring
        /// Delivered: the dots gather and a green ring lights up.
        case done
        /// Cancelled, failed or not inserted: the marks just fade.
        case fading
    }

    private(set) var phase: Phase = .reading
    private var phaseStart = Date()
    private var lastFrame: Date?
    private var marks: [Mark] = []
    private var loudness: [CGFloat] = []

    static let markCount = 14
    static let ringDotCount = 12
    static let ringRadius: CGFloat = 11
    static let dotDiameter: CGFloat = 2.9
    static let amber: (r: Double, g: Double, b: Double) = (1.0, 0.70, 0.31)
    static let warm: (r: Double, g: Double, b: Double) = (1.0, 0.89, 0.75)
    static let green = Color(red: 0.42, green: 0.83, blue: 0.59)

    /// Recording ended: start from the bars as the recording drew them
    /// (same places, heights from the last level), heading for the
    /// loudness of the whole recording.
    func beginReading(lastLevel: Float, history: [Float], at now: Date) {
        loudness = Self.buckets(history, count: Self.markCount).map { 3 + 15 * CGFloat($0) }
        marks = (0..<Self.markCount).map { i in
            let x = (CGFloat(i) - 6.5) * 4
            let h = max(3, 3 + CGFloat(lastLevel) * 18 * Self.recordingEnvelope(i))
            return Mark(x: x, y: 0, w: 2, h: h, opacity: 1, tone: 0)
        }
        phase = .reading
        phaseStart = now
        lastFrame = nil
    }

    func enter(_ next: Phase, at now: Date) {
        guard next != phase else { return }
        if marks.isEmpty { beginReading(lastLevel: 0, history: [], at: now) }
        phase = next
        phaseStart = now
    }

    // MARK: Frame

    func step(to now: Date, reduceMotion: Bool) {
        let dt = min(max(now.timeIntervalSince(lastFrame ?? now), 0), 0.05)
        lastFrame = now
        let age = now.timeIntervalSince(phaseStart)
        let opacityRate = phase == .reading || phase == .ring ? 30.0 : 22.0

        for i in marks.indices {
            let t = target(i, age: age, reduceMotion: reduceMotion)
            if reduceMotion {
                marks[i].snap(to: t)
            } else {
                marks[i].spring(toward: t, dt: dt, opacityRate: opacityRate)
            }
        }
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, now: Date, reduceMotion: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for mark in marks where mark.opacity > 0.01 {
            let w = max(2, mark.w), h = max(2, mark.h)
            let rect = CGRect(x: center.x + mark.x - w / 2, y: center.y + mark.y - h / 2, width: w, height: h)
            let a = Self.amber, b = Self.warm, k = Double(mark.tone)
            let color = Color(red: a.r + (b.r - a.r) * k, green: a.g + (b.g - a.g) * k, blue: a.b + (b.b - a.b) * k)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(w, h) / 2), with: .color(color.opacity(min(mark.opacity, 1))))
        }
        if phase == .done {
            drawSeal(in: &ctx, center: center, age: now.timeIntervalSince(phaseStart), reduceMotion: reduceMotion)
        }
    }

    // MARK: Targets

    private func target(_ i: Int, age: TimeInterval, reduceMotion: Bool) -> Mark {
        let ease = VoiceInputEasing.ease
        var t = marks[i]
        switch phase {
        case .reading:
            t.x = (CGFloat(i) - 6.5) * 4.6
            t.y = 0
            t.w = 2
            t.h = loudness.indices.contains(i) ? loudness[i] : 3
            t.tone = 0.2
            if reduceMotion {
                t.opacity = 0.75
            } else {
                // A light reads across the recording, start to end, every 1.9 s.
                let sweep = -48 + 96 * CGFloat((age / 1.9).truncatingRemainder(dividingBy: 1))
                let glow = Double(exp(-pow(t.x - sweep, 2) / 60))
                t.opacity = 0.32 + 0.68 * glow
                t.h *= 1 + 0.1 * glow
            }
        case .ring:
            t.w = Self.dotDiameter
            t.h = Self.dotDiameter
            t.tone = 0
            guard let slot = Self.ringSlot(of: i) else {
                t.opacity = 0
                break
            }
            let angle = Self.ringAngle(of: slot)
            t.x = cos(angle) * Self.ringRadius
            t.y = sin(angle) * Self.ringRadius
            if reduceMotion {
                t.opacity = 0.7
            } else {
                let head = age * 2.8
                let delta = atan2(sin(angle - head), cos(angle - head))
                let lit = 0.2 + 0.8 * exp(-delta * delta / 1.1)
                let settle = ease(age, 0.1, 0.38)
                t.opacity = lit * settle + 0.8 * (1 - settle)
            }
        case .done:
            t.x = 0
            t.y = 0
            t.w = 2
            t.h = 2
            t.opacity = 0.6 * (1 - ease(age, 0, 0.18))
        case .fading:
            t.opacity = 0
        }
        return t
    }

    private func drawSeal(in ctx: inout GraphicsContext, center: CGPoint, age: TimeInterval, reduceMotion: Bool) {
        let ease = VoiceInputEasing.ease
        let sealOpacity = ease(age, 0.04, 0.18) * (1 - ease(age, 0.35, 0.65))
        let diameter = 19 * (reduceMotion ? 1 : 1 + 0.35 * ease(age, 0.3, 0.65))
        let seal = Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
        ctx.stroke(seal, with: .color(Self.green.opacity(sealOpacity)), lineWidth: 1.5)

        let dotOpacity = ease(age, 0.12, 0.28) * (1 - ease(age, 0.45, 0.72))
        let dot = Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        ctx.fill(dot, with: .color(Self.green.opacity(dotOpacity)))
    }

    // MARK: Geometry

    /// The recording waveform's center-weighted envelope (VoiceInputWaveformBar).
    private static func recordingEnvelope(_ i: Int) -> CGFloat {
        let center = CGFloat(markCount - 1) / 2
        return 1 - pow(abs(CGFloat(i) - center) / center, 1.6) * 0.85
    }

    /// The two outer marks leave as the ring forms; the rest are its dots.
    private static func ringSlot(of i: Int) -> Int? {
        (1...ringDotCount).contains(i) ? i - 1 : nil
    }

    /// Dot `slot`'s place on the ring: the left end of the row takes the
    /// ring's left and the rest follow over the top, so the row rolls up.
    private static func ringAngle(of slot: Int) -> Double {
        .pi + Double(slot) / Double(ringDotCount) * 2 * .pi
    }

    /// The loudest level in each of `count` equal slices of the recording.
    static func buckets(_ levels: [Float], count: Int) -> [Float] {
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { i in
            let start = i * levels.count / count
            let end = max(start + 1, (i + 1) * levels.count / count)
            return levels[start..<min(end, levels.count)].max() ?? 0
        }
    }
}

// MARK: - Mark

private struct Mark {
    var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var opacity: Double
    var tone: CGFloat
    var vx: CGFloat = 0, vy: CGFloat = 0, vw: CGFloat = 0, vh: CGFloat = 0

    mutating func snap(to t: Mark) {
        (x, y, w, h, opacity, tone) = (t.x, t.y, t.w, t.h, t.opacity, t.tone)
        (vx, vy, vw, vh) = (0, 0, 0, 0)
    }

    /// Damped springs for place and size (k=250/c=29, height k=225/c=26),
    /// an exponential approach for opacity and colour.
    mutating func spring(toward t: Mark, dt: TimeInterval, opacityRate: Double) {
        (x, vx) = Spring.step(x, vx, to: t.x, dt: dt, k: 250, c: 29)
        (y, vy) = Spring.step(y, vy, to: t.y, dt: dt, k: 250, c: 29)
        (w, vw) = Spring.step(w, vw, to: t.w, dt: dt, k: 250, c: 29)
        (h, vh) = Spring.step(h, vh, to: t.h, dt: dt, k: 225, c: 26)
        opacity += (t.opacity - opacity) * min(dt * opacityRate, 1)
        tone += (t.tone - tone) * CGFloat(min(dt * 8, 1))
    }
}

private enum Spring {
    /// Exact step of an underdamped spring (unit mass) over `dt`.
    static func step(_ x: CGFloat, _ v: CGFloat, to target: CGFloat, dt: TimeInterval, k: Double, c: Double) -> (CGFloat, CGFloat) {
        let a = c / 2, w = (k - a * a).squareRoot(), e = exp(-a * dt)
        let r = Double(x - target), v = Double(v)
        let cs = cos(w * dt), sn = sin(w * dt)
        let nx = Double(target) + e * (r * cs + (v + a * r) / w * sn)
        let nv = e * (v * cs - (a * v + k * r) / w * sn)
        return (CGFloat(nx), CGFloat(nv))
    }
}

// MARK: - View

/// Draws the motion each display frame while something moves. With
/// Reduce Motion the timeline stops and each phase is drawn still.
struct VoiceInputProcessingView: View {
    let motion: VoiceInputProcessingMotion
    /// Redraws on a phase change even while the timeline is paused.
    let phase: VoiceInputProcessingMotion.Phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { ctx, size in
                _ = phase
                motion.step(to: context.date, reduceMotion: reduceMotion)
                motion.draw(in: &ctx, size: size, now: context.date, reduceMotion: reduceMotion)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Easing

enum VoiceInputEasing {
    /// Smoothstep of `t` across `from...to`: 0 before, 1 after.
    static func ease(_ t: TimeInterval, _ from: TimeInterval, _ to: TimeInterval) -> Double {
        let x = min(max((t - from) / (to - from), 0), 1)
        return x * x * (3 - 2 * x)
    }
}
