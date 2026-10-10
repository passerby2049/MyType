// mem-bench <model-id> <input.jsonl> <count>
// Does emptying MLX's buffer cache after each transcription slow the next one? Each clip is transcribed twice, once
// with the cache the previous run left ("warm") and once right after Memory.clearCache() ("cleared"); the order
// alternates clip by clip. Prints per-clip times and the GPU memory MLX holds, then medians.
import AudioCommon
import Foundation
import MLX
import Qwen3ASR

struct Item: Codable { let id: String; let audio: String; let language: String?; let context: String? }

let args = CommandLine.arguments
guard args.count == 4, let count = Int(args[3]) else {
    FileHandle.standardError.write("usage: mem-bench <model-id> <input.jsonl> <count>\n".data(using: .utf8)!)
    exit(2)
}
let items = try String(contentsOf: URL(fileURLWithPath: args[2]), encoding: .utf8).split(separator: "\n")
    .prefix(count).map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }

let mb = { (bytes: Int) in bytes / 1_048_576 }
let model = try await Qwen3ASRModel.fromPretrained(modelId: args[1])
print("loaded: active \(mb(Memory.activeMemory)) MB, cache \(mb(Memory.cacheMemory)) MB, cacheLimit \(mb(Memory.cacheLimit)) MB")

func run(_ item: Item, _ samples: [Float]) -> (Double, String) {
    let start = Date()
    let text = model.transcribe(audio: samples, sampleRate: 16000,
                                options: Qwen3DecodingOptions(language: item.language, context: item.context))
    return (Date().timeIntervalSince(start), text)
}

// One untimed run so both modes start after Metal's first-use compilation.
_ = run(items[0], try AudioFileLoader.load(url: URL(fileURLWithPath: items[0].audio), targetSampleRate: 16000))

var warm: [Double] = [], cleared: [Double] = [], cacheAfter: [Int] = [], differ = 0
for (n, item) in items.enumerated() {
    let samples = try AudioFileLoader.load(url: URL(fileURLWithPath: item.audio), targetSampleRate: 16000)
    let audio = Double(samples.count) / 16000
    var w = (0.0, ""), c = (0.0, "")
    if n % 2 == 0 {
        w = run(item, samples)
        Memory.clearCache(); c = run(item, samples)
    } else {
        Memory.clearCache(); c = run(item, samples)
        w = run(item, samples)
    }
    cacheAfter.append(Memory.cacheMemory)
    warm.append(w.0); cleared.append(c.0)
    if w.1 != c.1 { differ += 1 }
    print(String(format: "%2d  audio %5.1fs  warm %.2fs  cleared %.2fs  cache %4d MB  peak %4d MB",
                 n, audio, w.0, c.0, mb(Memory.cacheMemory), mb(Memory.peakMemory)))
}
func pct(_ xs: [Double], _ p: Double) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
print(String(format: "median warm %.3fs cleared %.3fs | p90 warm %.3fs cleared %.3fs | total warm %.1fs cleared %.1fs",
             pct(warm, 0.5), pct(cleared, 0.5), pct(warm, 0.9), pct(cleared, 0.9),
             warm.reduce(0, +), cleared.reduce(0, +)))
print("max cache held after a run: \(mb(cacheAfter.max() ?? 0)) MB; peak \(mb(Memory.peakMemory)) MB; texts differing: \(differ)")
Memory.clearCache()
print("after clearCache: active \(mb(Memory.activeMemory)) MB, cache \(mb(Memory.cacheMemory)) MB")
