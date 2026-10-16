// Abstract:
// The second pass of finding misread English words (docs/design-misread-words.md 二 3): only when the local pass
// (`MisreadCandidates`) found candidates, a warm Claude Code session of its own — Sonnet, low effort, built like the
// fn+space text polish — says what each one is. It runs after the text is typed; nobody waits on it.

import Foundation

enum MisreadJudge {
    /// What the model says about one candidate.
    struct Verdict: Equatable, Sendable, Codable {
        enum Kind: String, Sendable, Codable {
            /// Said unclearly, heard as another real word: the only kind that is a misread.
            case sound
            /// A name or a word the recognizer doesn't know: for the vocabulary.
            case newWord
            /// The polish changed the wording, or the raw word is what was said.
            case wording
            /// A reduced function word, or words that sound the same.
            case weak
            case unsure
        }

        let heard: String
        let meant: String
        let kind: Kind
        /// American IPA of `meant` (sound only).
        let ipa: String?
        /// Which sound didn't come out, Chinese, 16 characters at most (sound only).
        let tip: String?
    }

    static let session = ClaudeCodeVoicePolishSession()
    static let model = "cc-sonnet"
    static let effort = "low"

    /// The verdicts for these candidates, in their order; unknown kinds or a reply that isn't the array throw.
    static func judge(
        candidates: [MisreadCandidates.Candidate],
        raw: String,
        polished: String,
        conversation: String
    ) async throws -> [Verdict] {
        guard !candidates.isEmpty else { return [] }
        let reply = try await session.polish(
            text: message(candidates: candidates, raw: raw, polished: polished, conversation: conversation),
            systemPrompt: systemPrompt,
            model: model,
            effort: effort
        )
        return try verdicts(from: reply)
    }

    static func message(candidates: [MisreadCandidates.Candidate], raw: String, polished: String, conversation: String) -> String {
        """
        <context>
        \(conversation)
        </context>
        <raw>\(raw)</raw>
        <polished>\(polished)</polished>
        <candidates>
        \(candidates.map { "\($0.heard) → \($0.meant)" }.joined(separator: "\n"))
        </candidates>
        """
    }

    /// The JSON array in the reply (a ```json fence or words around it are tolerated).
    static func verdicts(from reply: String) throws -> [Verdict] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end else {
            throw ClaudeCodeError.apiError("misread judge: no JSON array in the reply")
        }
        return try JSONDecoder().decode([Verdict].self, from: Data(reply[start...end].utf8))
    }

    static let systemPrompt = """
        You check English dictations for words the speech recognizer heard as other words because of the speaker's \
        pronunciation. The speaker is a native Chinese speaker practising spoken English; they dictate messages to an \
        AI coding assistant. Each message has:
        <context>: the conversation on screen just before they spoke (their previous message and the assistant's last \
        answer, often in Chinese).
        <raw>: what the recognizer wrote.
        <polished>: the same text after an automatic cleanup that fixed recognition errors, removed fillers and \
        sometimes reworded. The cleanup can be wrong too.
        <candidates>: one per line, "heard → meant": a word in <raw> and the word <polished> has in its place.

        For each candidate choose one kind:
        - "sound": the speaker meant the polished word, said it unclearly, and the recognizer wrote another real \
        English word that sounds close (cards heard as cars: the final d was lost; goal heard as go; answer heard as \
        enter). Only when the context or the sentence shows that the polished word is what they meant, the raw \
        word doesn't fit there, and no other similar-sounding word would fit as well (if "the rope" could as \
        well be "the road" or "the robe", it's "unsure").
        - "newWord": the meant word is a name, product, project, technical term or a word a recognizer may not know \
        (Kokoro heard as Coco). That's the recognizer's vocabulary, not the speaker.
        - "wording": the cleanup changed wording or grammar (tense, plural, articles, a better word), or the raw \
        word fits the sentence and is probably what was said.
        - "weak": either word is a function word — pronoun, article, preposition, conjunction, auxiliary or modal \
        verb, there / here (or / of, a / the, she / it, them / then, were / where, can / could) — these are reduced \
        in normal fast speech; or the two words sound the same. Never "sound".
        - "unsure": you can't tell.
        Telling the speaker they mispronounced a word they said right is worse than missing a mispronunciation: when \
        in doubt between "sound" and anything else, don't choose "sound".

        Reply with only a JSON array, one object per candidate, in the given order:
        {"heard": "<heard>", "meant": "<meant>", "kind": "<kind>", "ipa": "<ipa>", "tip": "<tip>"}
        "ipa": General American IPA of the meant word in slashes (/kɑrdz/), for "sound" only, otherwise "".
        "tip": for "sound" only: in Chinese, at most 16 characters, which sound didn't come out (词尾 dz 没出来), \
        otherwise "".
        """
}
