// asr-bench <model-id> <input.jsonl> <output.jsonl>
// Input: one JSON object per line {"id", "audio", "language"?, "context"?}. Output: the same id with "text" and
// "seconds" (transcription time, model already loaded). The model loads once; lines already in the output are skipped,
// so a stopped run picks up where it was.
import AudioCommon
import Foundation
import Qwen3ASR

struct Item: Codable { let id: String; let audio: String; let language: String?; let context: String? }
struct Result: Codable { let id: String; let text: String; let seconds: Double }

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: asr-bench <model-id> <input.jsonl> <output.jsonl>\n".data(using: .utf8)!)
    exit(2)
}
let (modelID, inputURL, outputURL) = (args[1], URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3]))

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

let loadStart = Date()
let model = try await Qwen3ASRModel.fromPretrained(modelId: modelID)
FileHandle.standardError.write("loaded \(modelID) in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s\n".data(using: .utf8)!)

let out = try FileHandle(forWritingTo: outputURL)
out.seekToEndOfFile()
for (n, item) in items.enumerated() where !done.contains(item.id) {
    let samples = try AudioFileLoader.load(url: URL(fileURLWithPath: item.audio), targetSampleRate: 16000)
    let start = Date()
    let text = model.transcribe(audio: samples, sampleRate: 16000,
                                options: Qwen3DecodingOptions(language: item.language, context: item.context))
    let result = Result(id: item.id, text: text, seconds: Date().timeIntervalSince(start))
    out.write(try JSONEncoder().encode(result) + Data("\n".utf8))
    if n % 25 == 0 { FileHandle.standardError.write("\(n + 1)/\(items.count)\n".data(using: .utf8)!) }
}
try out.close()
