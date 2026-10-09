// align-check — runs MyType's SentTextAligner over the saved records (history.json), Claude Code's input history and Otto's chat,
// one line per record: id, result (sent as pasted / edited / not matched / no source), what was sent. Same output as
// `python3 sent_align.py --ids`, so the two can be diffed.
// Build: swiftc -O -o align-check main.swift ../../MyType/VoiceInput/SentTextAligner.swift
import Foundation

let historyFile = NSHomeDirectory() + "/Library/Application Support/MyType/VoiceInput/history.json"
let records = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: historyFile)))) as? [[String: Any]] ?? []
let iso = ISO8601DateFormatter()
let dictations = records.compactMap { r -> SentTextAligner.Dictation? in
    guard let id = (r["id"] as? String).flatMap(UUID.init(uuidString:)), let text = r["text"] as? String,
          let at = (r["createdAt"] as? String).flatMap(iso.date(from:)) else { return nil }
    return SentTextAligner.Dictation(id: id, text: text, at: at, app: r["targetApp"] as? String)
}
let results = SentTextAligner.lookUp(dictations, inputs: SentTextAligner.inputs(from:))
for d in dictations {
    switch results[d.id] {
    case .found(let sent, _):
        let kind = sent == d.text.trimmingCharacters(in: .whitespacesAndNewlines) ? "sent as pasted" : "edited"
        print("\(d.id.uuidString)\t\(kind)\t\(sent.replacingOccurrences(of: "\n", with: "\\n"))")
    case .notFound: print("\(d.id.uuidString)\tnot matched\t")
    case .noSource, nil: print("\(d.id.uuidString)\tno source\t")
    }
}
