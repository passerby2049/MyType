// Abstract:
// Recording lifecycle — start, finish, cleanup, audio level monitoring.

import AppKit
import AVFoundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

extension VoiceInputManager {

    // MARK: - Recording

    func startRecording() {
        logger.debug("setting up recorder")
        let id = UUID()
        currentRecordingID = id

        // Snapshot the target app NOW, before the overlay can steal focus.
        let frontApp = NSWorkspace.shared.frontmostApplication
        capturedTargetPID = frontApp?.processIdentifier
        capturedTargetName = frontApp?.localizedName
        logger.info("Captured target: \(self.capturedTargetName ?? "unknown") (pid=\(self.capturedTargetPID ?? -1))")

        let audioURL = VoiceInputStore.newAudioFileURL(id: id)

        // Ensure the audio directory exists before AVAudioRecorder tries to create the file.
        // VoiceInputStore.shared may not have been initialised yet (its ensureDirectories()
        // only runs in init), and the static newAudioFileURL() doesn't trigger it.
        try? FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Configure recorder for AAC/M4A
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            recorder.record(forDuration: recordingTimeout)

            audioRecorder = recorder
            recordingStartTime = .now
            state = .recording
            logger.debug("recording STARTED")
            // Tell the global hotkey monitor to swallow Esc presses
            // until the recording ends — gives the user a quick way out.
            hotkeyMonitor.shouldInterceptEscape = true

            // Play start sound with slight delay
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                startSound?.play()
            }

            // Show overlay
            showOverlay()

            // Start level monitoring
            startLevelMonitor()

            logger.info("Started recording: \(id)")
        } catch {
            logger.error("Failed to start recording: \(error) — dismissing silently")
            silentlyDismiss()
        }
    }

    func finishRecording() {
        guard state == .recording,
              let startTime = recordingStartTime
        else { return }

        let duration = Date.now.timeIntervalSince(startTime)

        // Check minimum duration
        if duration < minimumRecordingDuration {
            logger.info("Recording too short (\(duration)s), cancelling")
            cancelRecording()
            return
        }

        stopRecorderAndTimer()
        recordingDuration = duration

        // Play done sound
        doneSound?.play()

        // Process the recording — keep Esc interception active
        // so the user can cancel during transcription/polish.
        state = .processing
        hotkeyMonitor.shouldInterceptEscape = true
        updateOverlay()

        processingTask = Task {
            await processRecording()
        }
    }

    // MARK: - Cleanup

    func stopRecorderAndTimer() {
        audioRecorder?.stop()
        audioRecorder = nil
        levelTimer?.cancel()
        levelTimer = nil
        audioLevel = 0
        // Recording is over (success, cancel, or silent dismiss) —
        // release the Esc key back to the focused app.
        hotkeyMonitor.shouldInterceptEscape = false
    }

    func cleanupCurrentRecording() {
        if let id = currentRecordingID {
            let audioURL = VoiceInputStore.newAudioFileURL(id: id)
            try? FileManager.default.removeItem(at: audioURL)
        }
        currentRecordingID = nil
        recordingStartTime = nil
        recordingDuration = 0
    }

    // MARK: - Audio Level Monitoring

    func startLevelMonitor() {
        levelTimer = Task { @MainActor in
            while !Task.isCancelled, state == .recording {
                if let recorder = audioRecorder, recorder.isRecording {
                    recorder.updateMeters()
                    let level = recorder.averagePower(forChannel: 0)
                    // Normalize dB to 0.0 - 1.0 range
                    // Typical range: -160 (silence) to 0 (max)
                    let normalizedLevel = max(0, (level + 50) / 50)
                    audioLevel = normalizedLevel
                    recordingDuration = recorder.currentTime
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
