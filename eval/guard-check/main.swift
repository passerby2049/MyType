// guard-check <inputs.jsonl> <outputs.jsonl> — runs MyType's PolishOutputGuard over polish replies ({"id", "text"} per
// line in both files) and prints them back with each rejected reply replaced by its input, as the app would paste it.
// Rejections go to stderr. Build: swiftc -O -o guard-check main.swift ../../MyType/VoiceInput/PolishOutputGuard.swift
import Foundation

func load(_ path: String) -> [(id: String, text: String)] {
    (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").compactMap { line in
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = o["id"] as? String, let text = o["text"] as? String else { return nil }
        return (id, text)
    } ?? []
}

let a = CommandLine.arguments
let inputs = Dictionary(load(a[1]).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
var rejected = 0
let outputs = load(a[2])
for (id, text) in outputs {
    guard let input = inputs[id] else { continue }
    var kept = text
    if let reason = PolishOutputGuard.rejection(output: text, input: input) {
        rejected += 1
        FileHandle.standardError.write(Data("rejected \(id): \(reason)\n  \(text.prefix(120))\n".utf8))
        kept = input
    }
    let line = try JSONSerialization.data(withJSONObject: ["id": id, "text": kept])
    print(String(decoding: line, as: UTF8.self))
}
FileHandle.standardError.write(Data("\(rejected) of \(outputs.count) rejected\n".utf8))
