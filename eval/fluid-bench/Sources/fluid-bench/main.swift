// fluid-bench <input.jsonl> <output.jsonl> — same lines as asr-bench ({"id", "audio", "language"?}); context is ignored
// (this engine has none). Language: "zh" / "en" / "ja" as in MyType's VoiceInputLanguage.qwen3Hint, or none.
import FluidAudio
import Foundation

struct Item: Codable { let id: String; let audio: String; let language: String? }
struct Result: Codable { let id: String; let text: String; let seconds: Double }

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: fluid-bench <input.jsonl> <output.jsonl>"); exit(2) }
let (inputURL, outputURL) = (URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]))
let items = try String(contentsOf: inputURL, encoding: .utf8).split(separator: "\n")
    .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
var done = Set<String>()
if let existing = try? String(contentsOf: outputURL, encoding: .utf8) {
    for line in existing.split(separator: "\n") {
        if let r = try? JSONDecoder().decode(Result.self, from: Data(line.utf8)) { done.insert(r.id) }
    }
} else {
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
}

let manager = Qwen3AsrManager()
try await manager.loadModels(from: try await Qwen3AsrModels.download(variant: ProcessInfo.processInfo.environment["VARIANT"] == "f32" ? .f32 : .int8))
let converter = AudioConverter()
let out = try FileHandle(forWritingTo: outputURL)
out.seekToEndOfFile()
for item in items where !done.contains(item.id) {
    let samples = try converter.resampleAudioFile(URL(fileURLWithPath: item.audio))
    let start = Date()
    let text = try await manager.transcribe(audioSamples: samples, language: item.language)
    out.write(try JSONEncoder().encode(Result(id: item.id, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                              seconds: Date().timeIntervalSince(start))) + Data("\n".utf8))
}
try out.close()
