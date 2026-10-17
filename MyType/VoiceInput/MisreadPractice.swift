// Abstract:
// Saying a misread sentence again (docs/design-misread-words.md 三「练习怎么识别」):
// recorded like a dictation, recognized as it was said — no context, no
// vocabulary, no polish — and kept out of the history. The takes are kept
// under the day and the sentence, and earlier days are cleared.

import AVFoundation
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "MisreadPractice"
)

/// What recognition is given. Dictation leans on the vocabulary; practice leans on nothing, or it would hear the
/// right word whatever was said.
struct RecognitionRequest: Equatable, Sendable {
    /// The language hint (nil: detect).
    let language: String?
    /// Words for the recognizer to lean towards.
    let context: String?
    /// Whether the text goes through the polish afterwards.
    let polish: Bool

    static let practice = RecognitionRequest(language: "en", context: nil, polish: false)
}

@MainActor
final class MisreadPracticeRecorder {
    private var recorder: AVAudioRecorder?
    private var meter = VoiceLevelMeter()
    private var levelTask: Task<Void, Never>?
    private var startedAt: Date?

    static var directory: URL { VoiceInputStore.baseDirectory.appending(path: "practice") }

    static func dayDirectory(_ date: Date) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return directory.appending(path: f.string(from: date))
    }

    /// Takes from before today go (三「当天结束清掉」).
    static func clearEarlierDays(now: Date = .now) {
        let today = dayDirectory(now).lastPathComponent
        let days = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for day in days where day < today {
            try? FileManager.default.removeItem(at: directory.appending(path: day))
        }
    }

    var isRecording: Bool { recorder?.isRecording == true }

    /// Start a take of sentence `recordID`; `onLevel` gets the loudness about 30 times a second.
    func start(recordID: UUID, take: Int, onLevel: @escaping @MainActor (Float) -> Void) throws {
        let folder = Self.dayDirectory(.now).appending(path: recordID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(take).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: 60) else { throw CocoaError(.fileWriteUnknown) }
        self.recorder = recorder
        startedAt = .now
        meter = VoiceLevelMeter()
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, let recorder = self.recorder, recorder.isRecording {
                recorder.updateMeters()
                onLevel(self.meter.level(power: recorder.averagePower(forChannel: 0)))
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        logger.info("take \(take) started")
    }

    /// Stop; the file and how long it ran, nil when nothing was recorded.
    func stop() -> (url: URL, seconds: TimeInterval)? {
        levelTask?.cancel()
        levelTask = nil
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        let seconds = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        return FileManager.default.fileExists(atPath: url.path) ? (url, seconds) : nil
    }

    func cancel() {
        if let url = stop()?.url { try? FileManager.default.removeItem(at: url) }
    }
}
