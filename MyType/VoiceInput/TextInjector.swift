// Abstract:
// Text injector — writes transcribed text into the focused text field
// by synthesizing CGEvents whose payload is a Unicode string. This
// avoids both the clipboard pollution of Cmd+V paste and the
// "bracketed paste" highlight some Electron apps apply.

import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "TextInjector"
)

struct TextInjectionResult {
    let targetApp: String?
    let status: VoiceInputInsertStatus
    /// When typing finished, for the record's typing time.
    var finishedAt = Date()
}

enum TextInjector {

    /// Inject text into the focused text field of the captured target app.
    ///
    /// `targetPID` / `targetName` are snapshotted by the caller BEFORE the
    /// overlay was shown, so they reliably identify the user's intended
    /// destination even after the user clicked the overlay's ✓ button.
    ///
    /// Strategy:
    ///   1. Re-activate the captured target app (in case clicking the
    ///      overlay shifted focus).
    ///   2. Wait for the activation to settle.
    ///   3. Synthesize keyboard events carrying the text as a Unicode
    ///      string payload via CGEventKeyboardSetUnicodeString. We do
    ///      NOT use Cmd+V paste because:
    ///        - It pollutes the user's clipboard (need save/restore).
    ///        - Electron terminals (Antigravity, VS Code, Cursor) apply
    ///          a yellow "bracketed paste" highlight that lingers.
    ///        - Some apps strip plain text in favor of RTF on paste.
    ///      Typing via unicode payload is invisible to autocomplete
    ///      because we don't emit real key codes — IDEs only fire
    ///      autocomplete on character-keycode sequences.
    @MainActor
    static func inject(
        _ text: String,
        targetPID: pid_t?,
        targetName: String?
    ) async -> TextInjectionResult {
        guard !text.isEmpty else {
            return TextInjectionResult(targetApp: targetName, status: .failed)
        }

        // Re-activate the captured target app so it's the key window when we
        // synthesize keystrokes at the HID layer — only if it isn't frontmost
        // already. The overlay is a non-activating panel, so usually it still
        // is, and the wait below was 120 ms spent on every dictation.
        if let pid = targetPID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
            // Wait for activation. Electron apps (Antigravity, VS Code, Cursor)
            // need ~120ms to re-attach key handling to the focused webview.
            try? await Task.sleep(for: .milliseconds(120))
        }

        logger.info("Typing into \(targetName ?? "unknown") (pid=\(targetPID ?? -1)): \(text.count) chars")
        if typeUnicodeString(text) {
            return TextInjectionResult(targetApp: targetName, status: .inserted)
        }

        logger.warning("Unicode typing failed — copied text to clipboard fallback")
        return TextInjectionResult(
            targetApp: targetName,
            status: copyFallback(text) ? .copiedFallback : .failed
        )
    }

    // MARK: - Unicode String Typing

    /// Maximum UTF-16 code units per CGEvent payload. The official cap
    /// for `CGEventKeyboardSetUnicodeString` is around 125 in practice;
    /// 64 is a comfortable, well-tested chunk size that covers a normal
    /// dictation utterance in one event.
    private static let maxUnicodeChunk = 64

    /// "Type" the given string by synthesizing keyboard events whose
    /// payload is the Unicode string itself. Long strings are split into
    /// chunks of `maxUnicodeChunk` UTF-16 code units. We post at the HID
    /// event tap so the WindowServer routes the events to the current
    /// key window (works for Electron renderers — postToPid does not).
    private static func typeUnicodeString(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility permission is not granted — cannot type via CGEvent")
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)

        // Clear any held modifiers (e.g. fn / option from the hotkey) so
        // they don't get interpreted as part of the synthetic typing.
        if let flagsClear = CGEvent(source: source) {
            flagsClear.type = .flagsChanged
            flagsClear.flags = []
            flagsClear.post(tap: .cghidEventTap)
        }

        for chunk in unicodeChunks(text) {
            guard postChunk(chunk, source: source) else {
                return false
            }
        }

        return true
    }

    /// Split into chunks of at most `maxUnicodeChunk` UTF-16 code units
    /// (what CGEventKeyboardSetUnicodeString consumes), cut only between
    /// characters: a cut inside a surrogate pair or a composed emoji typed
    /// two halves that showed up as garbage.
    static func unicodeChunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUnicodeChunk {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Post a single keyDown/keyUp pair carrying the given UTF-16 chunk
    /// as its Unicode string payload. The virtual key code is irrelevant
    /// (we use 0); apps insert the unicode string directly without
    /// triggering any autocomplete/IME behavior tied to real key codes.
    private static func postChunk(_ utf16Chunk: [UniChar], source: CGEventSource?) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }

        keyDown.flags = []
        keyUp.flags = []

        var posted = false
        utf16Chunk.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                keyDown.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                keyUp.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                posted = true
            }
        }

        guard posted else { return false }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func copyFallback(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
