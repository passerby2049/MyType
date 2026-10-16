// misread-check — misread English words, offline (docs/design-misread-words.md 二, step 2).
//   misread-check                          tests for the local candidate rules (MisreadCandidates) and the reply parser
//   misread-check judge <in> <out>         over an eval set ({"id", "raw", "polished", "context"} per line): the local
//                                          candidates, then MisreadJudge's warm session for the lines that have any;
//                                          writes {"id", "candidates", "verdicts", "seconds"} (lines already there skipped)
// Build: ./build.sh (LifeKit's WordDiff + Misreads as a module, then this with the app's Claude Code session files)
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL (line \(line)): \(what)") }
}
func pairs(_ raw: String, _ polished: String) -> [String] {
    MisreadCandidates.candidates(raw: raw, polished: polished).map { "\($0.heard)>\($0.meant)" }
}

func tests() {
    // One word for another counts
    check(pairs("The height of the two cars is not the same.", "The height of the two cards is not the same.") == ["cars>cards"], "cars → cards")
    check(pairs("Yes, let's do the Coco sample first.", "Yes, let's do the Kokoro sample first.") == ["coco>kokoro"], "Coco → Kokoro")
    check(pairs("Looked good, let's go.", "Looks good, let's go.") == ["looked>looks"], "Looked → Looks is a candidate (the judge says wording)")
    check(pairs("Let's enter the Japanese Go question first.", "Let's answer the Japanese Goal question first.") == ["enter>answer", "go>goal"],
          "two in one sentence, both listed")
    // Fillers and repeats don't
    check(pairs("Uh, yeah, I think uh, one hour is acceptable.", "Yeah, I think one hour is acceptable.") == [], "fillers")
    check(pairs("Um, actually, I want to improve the speed first. I want to, I want to. Can we improve it?",
                "Actually, I want to improve the speed first. Can we improve it?") == [], "repeats")
    check(pairs("Hey don't don't change it", "Hey, don't change it") == [], "a contraction repeated")
    check(MisreadCandidates.cleaned(["i", "want", "to", "i", "want", "to", "go"]) == ["i", "want", "to", "go"], "cleaned: three words twice")
    check(MisreadCandidates.cleaned(["uh", "go", "go", "go"]) == ["go"], "cleaned: filler out, three times kept once")
    // Left out and added don't
    check(pairs("I mean the clean the mini, not MacBook, right?", "I mean clean the mini, not the MacBook, right?") == [], "an article left out, one added")
    check(pairs("Can you check it", "Can you please check it") == [], "a word added by the polish")
    check(pairs("one hour is accept is acceptable", "one hour is acceptable") == [], "a restart is words added, not replaced")
    // Same sound, case, punctuation, contractions, numbers don't
    check(pairs("Put it over their.", "Put it over there.") == [], "there / their")
    check(pairs("I want two of them", "I want to of them") == [], "two / to")
    check(pairs("the colour is fine", "the color is fine") == [], "British spelling")
    check(pairs("let's test the parakeet model", "Let's test the Parakeet model.") == [], "case and punctuation")
    check(pairs("I'm not sure it's done", "I am not sure it is done") == [], "contractions")
    check(pairs("wait 2 seconds", "wait two seconds") == [], "a number as digits")
    check(pairs("ok let's go", "okay, let's go") == [], "ok / okay")
    // One for several, several for one: not one word for another
    check(pairs("use the work around here", "use the workaround here") == [], "two words for one")
    check(pairs("let's go to the gym tomorrow", "let's go to the gymnasium center tomorrow") == [], "one for two")
    // Two neighbouring words for two others: word by word
    check(pairs("we need the big rock here", "we need the pig lock here") == ["big>pig", "rock>lock"], "two for two")
    // Chinese and numbers are not English words
    check(pairs("Can you check the disk usage of the MacBook? 那个 Mac Mini.",
                "Can you check the disk usage of the MacBook? And clean the mini.") == [], "Chinese against English")
    // The whole sentence misheard: nothing
    check(pairs("Key seed oKay with us the same prome", "Is it okay if I use the same prompt") == [], "more than half off")
    check(pairs("", "Hello") == [] && pairs("uh um", "Hello") == [], "nothing said")
    check(pairs("Can we build and install the new version?", "Can we build and install the new version?") == [], "the same")
    // A candidate once per sentence
    check(pairs("the cars and the cars are", "the cards and the cards are") == ["cars>cards"], "the same pair twice, once")

    // The judge's reply
    let reply = """
        ```json
        [{"heard": "cars", "meant": "cards", "kind": "sound", "ipa": "/kɑrdz/", "tip": "词尾 d 没出来"},
         {"heard": "coco", "meant": "kokoro", "kind": "newWord", "ipa": "", "tip": ""}]
        ```
        """
    let verdicts = try? MisreadJudge.verdicts(from: reply)
    check(verdicts?.map(\.kind) == [.sound, .newWord], "parses a fenced array")
    check(verdicts?.first?.ipa == "/kɑrdz/", "keeps the IPA")
    check((try? MisreadJudge.verdicts(from: "no idea")) == nil, "no array throws")
    check((try? MisreadJudge.verdicts(from: #"[{"heard": "a", "meant": "b", "kind": "loud"}]"#)) == nil, "an unknown kind throws")
    let message = MisreadJudge.message(candidates: [.init(heard: "cars", meant: "cards")], raw: "r", polished: "p", conversation: "c")
    check(message.contains("<candidates>\ncars → cards\n</candidates>") && message.contains("<context>\nc\n</context>"), "the message")

    print(failures == 0 ? "all passed" : "\(failures) failed")
}

struct Item: Codable { let id: String; let raw: String; let polished: String; let context: String? }
struct Output: Codable {
    let id: String
    let candidates: [MisreadCandidates.Candidate]
    let verdicts: [MisreadJudge.Verdict]?
    let error: String?
    let seconds: Double?
}

func judge(_ input: String, _ output: String) async throws {
    let items = try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n")
        .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
    var done = Set<String>()
    if let existing = try? String(contentsOfFile: output, encoding: .utf8) {
        for line in existing.split(separator: "\n") {
            if let o = try? JSONDecoder().decode(Output.self, from: Data(line.utf8)), o.error == nil { done.insert(o.id) }
        }
    } else {
        FileManager.default.createFile(atPath: output, contents: nil)
    }
    let out = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
    out.seekToEndOfFile()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for item in items where !done.contains(item.id) {
        let candidates = MisreadCandidates.candidates(raw: item.raw, polished: item.polished)
        var result = Output(id: item.id, candidates: candidates, verdicts: nil, error: nil, seconds: nil)
        if !candidates.isEmpty, let context = item.context {
            let start = Date()
            do {
                let verdicts = try await MisreadJudge.judge(candidates: candidates, raw: item.raw, polished: item.polished, conversation: context)
                result = Output(id: item.id, candidates: candidates, verdicts: verdicts, error: nil, seconds: Date().timeIntervalSince(start))
            } catch {
                result = Output(id: item.id, candidates: candidates, verdicts: nil, error: "\(error)", seconds: Date().timeIntervalSince(start))
            }
            FileHandle.standardError.write("\(item.id.prefix(8)) \(candidates.count) → \(result.verdicts?.map(\.kind.rawValue) ?? [result.error ?? "?"]) \(String(format: "%.1f", result.seconds ?? 0))s\n".data(using: .utf8)!)
        }
        out.write(try encoder.encode(result) + Data([0x0A]))
    }
}

let args = CommandLine.arguments
if args.count == 4 && args[1] == "judge" {
    try await judge(args[2], args[3])
} else {
    tests()
    exit(failures == 0 ? 0 : 1)
}
