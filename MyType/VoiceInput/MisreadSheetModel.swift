// Abstract:
// What the practice sheet shows for one sentence (docs/design-misread-words.md
// 三): the two aligned rows, a row per misread word, the takes said while
// practising; whether it's open, selected or recording. And where the hotkey
// goes: practice while the sheet is selected, dictation otherwise. No AppKit
// here, so eval/misread-check tests it as it is.

import Foundation
import LifeKit
import Observation

/// Where a press of the dictation hotkey goes (三「选中：同一个快捷键，看焦点在哪」).
enum HotkeyRoute: Equatable {
    case dictation
    case practice

    /// A take or a dictation already under way gets the press that ends it; otherwise the sheet's focus decides.
    static func route(sheetSelected: Bool, practising: Bool, dictationBusy: Bool) -> HotkeyRoute {
        if practising { return .practice }
        if dictationBusy { return .dictation }
        return sheetSelected ? .practice : .dictation
    }
}

@MainActor @Observable
final class MisreadSheetModel {
    /// One misread word's row.
    struct Word: Identifiable, Equatable {
        var id: String { misread.word }
        let misread: VoiceMisread
        /// Earlier days it was misread on (from the history), oldest first.
        let earlier: [Date]
    }

    /// One time it was said while practising.
    struct Take: Identifiable, Equatable {
        enum Mark: Equatable { case plain, right, heardAgain }
        let id: Int
        let text: String
        let audio: URL?
        /// The take's words, each marked: a sheet word said right is green, heard as before is red.
        let words: [(String, Mark)]

        static func == (a: Take, b: Take) -> Bool { a.id == b.id && a.text == b.text }
    }

    enum Phase: Equatable {
        /// Only the small bar.
        case bar
        /// The sheet is open.
        case sheet
    }

    let recordID: UUID
    let raw: String
    let polished: String
    let createdAt: Date
    private(set) var words: [Word]
    private(set) var columns: [MisreadAlignment.Column] = []
    private(set) var takes: [Take] = []
    var phase: Phase = .sheet
    /// The sheet has the keyboard: the hotkey practises.
    var selected = false
    /// A take is being recorded.
    var practising = false
    /// A take is being recognized.
    var recognizing = false
    /// The word row lit up (clicked in the sentence).
    var highlighted: String?
    /// The take or word playing.
    var playing: String?
    /// Loudness while a take is recorded, 0–1.
    var level: Float = 0

    init(recordID: UUID, raw: String, polished: String, createdAt: Date, words: [Word]) {
        (self.recordID, self.raw, self.polished, self.createdAt, self.words) = (recordID, raw, polished, createdAt, words)
        realign()
    }

    var isEmpty: Bool { words.isEmpty }

    /// 「读音 · cards」 / 「读音 · 3 个词」
    var barTitle: String {
        words.count == 1 ? "读音 · \(words[0].misread.word)" : "读音 · \(words.count) 个词"
    }

    /// The line at the bottom.
    var status: String {
        if practising { return "在听 · 再按一下热键停 · esc 不要这一遍" }
        if recognizing { return "识别中…" }
        if selected { return "练习中 · 按热键说一遍 · esc 收起" }
        return "点一下这张单子再按热键，是练这一句；不点，热键还是口述"
    }

    /// 「这个我没读错」: the word leaves the sheet; the label to keep.
    func notMisread(_ word: String, kind: String = "sound", at: Date = .now) -> MisreadLabels.Label? {
        guard let i = words.firstIndex(where: { $0.misread.word == word }) else { return nil }
        let m = words.remove(at: i).misread
        realign()
        if highlighted == word { highlighted = nil }
        return MisreadLabels.Label(record: recordID, word: m.word, heard: m.heard, kind: kind, ipa: m.ipa, tip: m.tip,
                                   label: "notMisread", at: at)
    }

    /// A take came back from recognition.
    @discardableResult
    func addTake(text: String, audio: URL?) -> Take {
        let take = Take(id: (takes.last?.id ?? 0) + 1, text: text, audio: audio, words: mark(text))
        takes.append(take)
        return take
    }

    /// Each word of a take, marked against the sheet's words and what they were heard as.
    func mark(_ text: String) -> [(String, Take.Mark)] {
        let right = Set(words.map { $0.misread.word.lowercased() })
        let heard = Set(words.map { $0.misread.heard.lowercased() })
        return MisreadAlignment.tokens(text).map { token in
            let key = MisreadAlignment.key(token)
            return (token, right.contains(key) ? .right : heard.contains(key) ? .heardAgain : .plain)
        }
    }

    private func realign() {
        columns = MisreadAlignment.columns(raw: raw, polished: polished,
                                           misreads: words.map { ($0.misread.heard.lowercased(), $0.misread.word.lowercased()) })
    }
}
