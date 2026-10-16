// Abstract:
// The recording meter as a waveform height: a noise gate that sits just above
// the room's own sound (learned from the recordings), then a 0.7 power so soft
// syllables show and loud ones don't pin the bars.

import Foundation

struct VoiceLevelMeter {
    static let floorKey = "voiceInputMeterNoiseFloor"
    /// The gate sits this far above the room's quiet: an air conditioner's
    /// 33 ms reads wander about ±6 dB around its quietest tenth.
    static let gateMargin: Float = 7
    /// Loud speech; the bars top out here. The meter reads 8–10 dB above the
    /// file's 33 ms RMS (2026-10-16): at -14 normal speech sat at the top 14%
    /// of the time, loud 30%; at -8 that's 3% and 11%.
    static let ceilingDB: Float = -8
    /// However loud the room, keep this much range between gate and top.
    static let minimumSpan: Float = 12
    /// A recording without pauses has a "quiet tenth" that's speech: let one
    /// raise the floor only this much, a quieter room lowers it at once.
    static let maximumRise: Float = 3

    /// The room's quietest tenth, dBFS, from the last recordings.
    private(set) var floor: Float
    private(set) var powers: [Float] = []

    init() {
        // Until a recording says otherwise: a quiet room's quiet tenth on the meter.
        floor = UserDefaults.standard.object(forKey: Self.floorKey) as? Float ?? -42
    }

    var gate: Float { floor + Self.gateMargin }

    /// Meter power (dBFS) as a bar height, 0…1.
    mutating func level(power: Float) -> Float {
        // The recorder's first reads are digital silence (-160).
        guard power > -80 else { return 0 }
        powers.append(power)
        let ceiling = max(Self.ceilingDB, gate + Self.minimumSpan)
        let gated = max(0, power - gate) / (ceiling - gate)
        return min(1, pow(gated, 0.7))
    }

    /// Learn the room from this recording for the next one. Returns the
    /// floor it heard (nil when too short to tell).
    mutating func learnFloor() -> Float? {
        guard powers.count >= 30 else { return nil }
        let quiet = powers.sorted()[powers.count / 10]
        floor = min(max(quiet, -70), floor + Self.maximumRise, -25)
        UserDefaults.standard.set(floor, forKey: Self.floorKey)
        return quiet
    }
}
