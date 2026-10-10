// Abstract:
// Phase marks drawn inside the overlay capsule after transcription:
// the dotted ring shown while the LLM polishes, and the green seal that
// confirms the text reached the target app. Timings follow
// design/voice-overlay/handoff-2026-10-10.md.

import SwiftUI

// MARK: - Polishing Ring

/// Twelve dots that wind from a horizontal line into a ring (~450 ms),
/// then hold still while a soft highlight travels around them. It only
/// says "still working" — no progress, no remaining time.
struct VoiceInputPolishRing: View {
    /// When the polishing phase began; the winding is timed from here.
    let start: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { ctx, size in
                let age = reduceMotion ? 1 : context.date.timeIntervalSince(start)
                Self.draw(in: &ctx, size: size, age: age, reduceMotion: reduceMotion)
            }
        }
        .frame(width: Self.canvasWidth, height: 28)
        .accessibilityHidden(true)
    }

    static let dotCount = 12
    static let radius: CGFloat = 11
    static let dotDiameter: CGFloat = 2.9
    static let lineSpan: CGFloat = 68
    static let canvasWidth: CGFloat = lineSpan + 4
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.31)
    /// Dot i's place on the ring. The line's left end starts at the
    /// ring's left and the rest follow over the top, so the line rolls
    /// up into the ring instead of crossing itself.
    static func angle(of i: Int) -> Double {
        .pi + Double(i) / Double(dotCount) * 2 * .pi
    }
    /// Highlight phase speed: ~2.24 s per turn.
    private static let angularSpeed = 2.8

    private static func draw(
        in ctx: inout GraphicsContext,
        size: CGSize,
        age: TimeInterval,
        reduceMotion: Bool
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let winding = reduceMotion ? 1 : VoiceInputEasing.ease(age, from: 0, to: 0.45)
        let fadeIn = reduceMotion ? 1 : VoiceInputEasing.ease(age, from: 0.12, to: 0.38)
        let head = age * angularSpeed

        for i in 0..<dotCount {
            let angle = angle(of: i)
            let lineX = (CGFloat(i) / CGFloat(dotCount - 1) - 0.5) * lineSpan
            let x = lineX * (1 - winding) + cos(angle) * radius * winding
            let y = sin(angle) * radius * winding

            let opacity: Double
            if reduceMotion {
                opacity = 0.7
            } else {
                let delta = atan2(sin(angle - head), cos(angle - head))
                opacity = (0.2 + 0.8 * exp(-delta * delta / 1.1)) * fadeIn
            }

            let rect = CGRect(
                x: center.x + x - dotDiameter / 2,
                y: center.y + y - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter
            )
            ctx.fill(Path(ellipseIn: rect), with: .color(amber.opacity(opacity)))
        }
    }
}

// MARK: - Completion Mark

/// Shown only when the text was actually inserted: the ring's dots (if
/// polishing ran) gather into the center and fade, a thin green ring and
/// a center dot light up, and the ring widens slightly as it fades.
struct VoiceInputCompletionMark: View {
    let start: Date
    /// Whether the ring was on screen; its dots then gather into the center.
    let fromRing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let age = context.date.timeIntervalSince(start)
                draw(in: &ctx, size: size, age: age)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private static let green = Color(red: 0.42, green: 0.83, blue: 0.59)

    private func draw(in ctx: inout GraphicsContext, size: CGSize, age: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ease = { VoiceInputEasing.ease($0, from: $1, to: $2) }

        if fromRing {
            let gather = reduceMotion ? 1 : ease(age, 0, 0.25)
            let radius = VoiceInputPolishRing.radius * (1 - gather)
            let opacity = 0.6 * (1 - ease(age, 0, 0.18))
            let d = VoiceInputPolishRing.dotDiameter
            for i in 0..<VoiceInputPolishRing.dotCount {
                let angle = VoiceInputPolishRing.angle(of: i)
                let rect = CGRect(
                    x: center.x + cos(angle) * radius - d / 2,
                    y: center.y + sin(angle) * radius - d / 2,
                    width: d, height: d
                )
                ctx.fill(Path(ellipseIn: rect), with: .color(VoiceInputPolishRing.amber.opacity(opacity)))
            }
        }

        let sealOpacity = ease(age, 0.04, 0.18) * (1 - ease(age, 0.35, 0.65))
        let sealScale = reduceMotion ? 1 : 1 + 0.35 * ease(age, 0.3, 0.65)
        let sealDiameter = 19 * sealScale
        let seal = Path(ellipseIn: CGRect(
            x: center.x - sealDiameter / 2, y: center.y - sealDiameter / 2,
            width: sealDiameter, height: sealDiameter
        ))
        ctx.stroke(seal, with: .color(Self.green.opacity(sealOpacity)), lineWidth: 1.5)

        let dotOpacity = ease(age, 0.12, 0.28) * (1 - ease(age, 0.45, 0.72))
        let dot = Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
        ctx.fill(dot, with: .color(Self.green.opacity(dotOpacity)))
    }
}

// MARK: - Easing

enum VoiceInputEasing {
    /// Smoothstep of `t` across `from...to`: 0 before, 1 after.
    static func ease(_ t: TimeInterval, from: TimeInterval, to: TimeInterval) -> Double {
        let x = min(max((t - from) / (to - from), 0), 1)
        return x * x * (3 - 2 * x)
    }
}
