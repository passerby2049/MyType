// Abstract:
// The parts of VoiceInputManager around a dictation rather than in it:
// typing the last one again, the timing line, and saving the record.
// Split out so VoiceInputManager.swift stays under 500 lines.

import AppKit
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

extension VoiceInputManager {
    /// ⌃⌥V and the menu: type the last dictation again where the user is.
    func retypeLast() {
        guard let last = VoiceInputStore.shared.records.max(by: { $0.createdAt < $1.createdAt }) else { return }
        retypeIntoFrontmost(last)
    }

    /// Type a past dictation into the frontmost app (not into MyType). Waits
    /// for the hotkey's modifiers to come up so they don't join the typing.
    func retypeIntoFrontmost(_ record: VoiceInputRecord) {
        guard !state.isProcessing, state != .recording else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            let front = NSWorkspace.shared.frontmostApplication
            let ours = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            _ = await TextInjector.inject(
                record.text.isEmpty ? record.rawTranscript : record.text,
                targetPID: ours ? nil : front?.processIdentifier,
                targetName: ours ? nil : front?.localizedName
            )
        }
    }

    /// One line per dictation: where the time between letting go of the key
    /// and the text appearing went. Whether a slow polish was a cold session
    /// is the "turn N (spawned for it — cold)" line before it.
    func logTiming(stoppedAt: Date, stt: TimeInterval, polish: TimeInterval?) {
        let total = Date().timeIntervalSince(stoppedAt)
        let typing = total - stt - (polish ?? 0)
        let polishText = polish.map { String(format: "%.2f", $0) } ?? "-"
        logger.notice("Timing: stop→typed \(String(format: "%.2f", total), privacy: .public) s = stt \(String(format: "%.2f", stt), privacy: .public) + polish \(polishText, privacy: .public) + rest \(String(format: "%.2f", typing), privacy: .public)")
    }

    func errorCode(
        insertStatus: VoiceInputInsertStatus,
        polishTimedOut: Bool = false
    ) -> String? {
        if insertStatus == .failed {
            return "injectionFailed"
        }
        if polishTimedOut {
            return "polishTimeout"
        }
        return nil
    }

    func saveHistoryRecordIfNeeded(_ record: VoiceInputRecord) {
        if VoiceInputStore.isHistoryEnabled {
            VoiceInputStore.shared.add(record)
        } else {
            let audioURL = VoiceInputStore.audioDirectory.appending(path: record.audioFileName)
            try? FileManager.default.removeItem(at: audioURL)
            logger.info("History disabled — skipped voice input record: \(record.id)")
        }
    }

    func clearCurrentSessionAfterSuccess() {
        currentRecordingID = nil
        recordingStartTime = nil
    }
}
