// Abstract:
// Core singleton orchestrating the voice input flow:
// hotkey → record → transcribe → optimize → inject text.

import AVFoundation
import AppKit
import FluidAudio
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

/// Window state for the voice input overlay.
enum VoiceInputState: Equatable {
    case idle
    case recording
    case processing
    case done
    case failure(String)
}

// VoiceInputEngineChoice + VoiceInputLanguage live in
// VoiceInputTypes.swift.

@MainActor @Observable
final class VoiceInputManager {
    static let shared = VoiceInputManager()

    // MARK: - Public State

    var state: VoiceInputState = .idle
    var audioLevel: Float = 0  // 0.0 - 1.0
    var recordingDuration: TimeInterval = 0

    // MARK: - Configuration Constants

    /// Minimum recording duration to avoid accidental triggers.
    let minimumRecordingDuration: TimeInterval = 0.35
    /// Maximum recording duration (safety valve).
    let recordingTimeout: TimeInterval = 600 // 10 minutes

    // MARK: - Internal State

    let hotkeyMonitor = GlobalHotkeyMonitor()
    var audioRecorder: AVAudioRecorder?
    var recordingStartTime: Date?
    var currentRecordingID: UUID?
    var levelTimer: Task<Void, Never>?
    var processingTask: Task<Void, Never>?
    private var overlayPanel: VoiceInputPanel?

    /// Target app captured at recording start. We snapshot it BEFORE the
    /// user can interact with the overlay so clicks on the buttons don't
    /// shift what we consider "the app to inject into".
    var capturedTargetPID: pid_t?
    var capturedTargetName: String?

    /// Lazily-loaded Qwen3-ASR manager. Cached per variant — if the user
    /// switches between int8 and f32 mid-session, we discard and re-load.
    var qwen3Manager: Qwen3AsrManager?
    var qwen3LoadedVariant: VoiceInputEngineChoice?

    /// Lazily-loaded Parakeet manager. Keyed by variant so switching
    /// between v2 and v3 reloads the right models.
    var parakeetManager: AsrManager?
    var parakeetLoadedVariant: VoiceInputEngineChoice?

    // MARK: - Sound Effects

    var startSound: NSSound?
    var doneSound: NSSound?
    var errorSound: NSSound?

    // MARK: - Init

    private init() {
        loadSoundEffects()
    }

    // MARK: - Setup

    /// Call once the app is fully active to start listening for fn key.
    func activate() {
        guard !hotkeyMonitor.isMonitoring else { return }
        hotkeyMonitor.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }
        hotkeyMonitor.onCancelPressed = { [weak self] in
            Task { @MainActor in
                self?.cancelRecording()
            }
        }
        hotkeyMonitor.start()

        // Pre-warm STT model and LLM session in background so the
        // first recording doesn't pay the cold-start penalty.
        Task.detached(priority: .utility) { await self.prewarm() }
    }

    private func loadSoundEffects() {
        // Use system sounds
        // Use the same pleasant "Glass" tone for both start and end,
        // so pressing fn gives the same affordance as finishing.
        startSound = NSSound(named: "Glass")
        doneSound = NSSound(named: "Glass")
        errorSound = NSSound(named: "Basso")
    }

    // MARK: - Recording Toggle

    /// Toggle between recording and idle states.
    func toggleRecording() {
        logger.debug("toggleRecording state=\(String(describing: self.state))")
        switch state {
        case .idle, .failure, .done:
            startRecording()
        case .recording:
            finishRecording()
        case .processing:
            cancelProcessing()
        }
    }

    /// Cancel the current recording or processing.
    func cancelRecording() {
        if state == .processing {
            cancelProcessing()
            return
        }
        guard state == .recording else { return }

        stopRecorderAndTimer()
        cleanupCurrentRecording()
        state = .idle
        hideOverlay()
        logger.info("Recording cancelled by user")
    }

    /// Cancel in-progress transcription / LLM polish.
    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        cleanupCurrentRecording()
        hotkeyMonitor.shouldInterceptEscape = false
        state = .idle
        hideOverlay()
        logger.info("Processing cancelled by user")
    }

    /// Dismiss the overlay silently — used when transcription fails or
    /// produces no content. No popup, no error sound, nothing left on
    /// screen. The audio file is also cleaned up.
    func silentlyDismiss() {
        stopRecorderAndTimer()
        cleanupCurrentRecording()
        state = .idle
        hideOverlay()
    }

    // MARK: - Processing Pipeline

    func processRecording() async {
        guard let id = currentRecordingID else {
            logger.info("No recording to process — dismissing silently")
            silentlyDismiss()
            return
        }

        let audioURL = VoiceInputStore.newAudioFileURL(id: id)

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            logger.info("Recording file not found — dismissing silently")
            silentlyDismiss()
            return
        }

        do {
            // Step 1: Transcribe using the configured engine
            let sttStart = Date()
            let rawText = try await transcribeAudio(at: audioURL)
            let sttTime = Date().timeIntervalSince(sttStart)
            try Task.checkCancellation()

            guard !rawText.isEmpty else {
                logger.info("No speech detected — dismissing silently")
                silentlyDismiss()
                return
            }

            // Step 2: Post-process (DictationOptimizer)
            let optimizedText = DictationOptimizer.optimize(rawText)
            try Task.checkCancellation()

            // Step 3: Optional LLM polish — with timeout fallback.
            // If LLM takes longer than 8s, inject the raw STT text first
            // so the user isn't blocked. LLM result updates history later.
            let llmEnabled = LLMRewriter.isEnabled
            let model = llmEnabled ? LLMRewriter.resolvedModel : nil
            let lightPolish = llmEnabled ? LLMRewriter.lightPolishEnabled : nil
            let vocabTerms = VocabularyStore.shared.terms.map(\.term)
            logger.info("LLM polish enabled? \(llmEnabled, privacy: .public)")

            if llmEnabled, let model {
                logger.info("LLM polish using model: \(model, privacy: .public)")
                let llmStart = Date()

                // Race: LLM polish vs 8s timeout. If the LLM is
                // slow (thinking, network), inject raw text first.
                let llmTask = Task {
                    try await LLMRewriter.rewrite(
                        rawText: optimizedText,
                        language: VoiceInputLanguage.current,
                        model: model,
                        vocabularyTerms: vocabTerms
                    )
                }

                let polishResult: String?
                do {
                    polishResult = try await withThrowingTaskGroup(of: String?.self) { group in
                        group.addTask { try await llmTask.value }
                        group.addTask {
                            try await Task.sleep(for: .seconds(8))
                            return nil
                        }
                        let first = try await group.next() ?? nil
                        group.cancelAll()
                        return first
                    }
                } catch {
                    polishResult = nil
                }

                let llmTime = Date().timeIntervalSince(llmStart)
                try Task.checkCancellation()

                if let polished = polishResult {
                    // LLM finished in time
                    let wasRewritten = polished != optimizedText
                    logger.info("LLM polish OK in \(String(format: "%.1f", llmTime))s — wasRewritten=\(wasRewritten, privacy: .public)")

                    let targetApp = await TextInjector.inject(
                        polished,
                        targetPID: capturedTargetPID,
                        targetName: capturedTargetName
                    )
                    let record = VoiceInputRecord(
                        id: id, text: polished, rawTranscript: rawText,
                        audioFileName: VoiceInputStore.newAudioFileName(id: id),
                        language: VoiceInputLanguage.current.localeIdentifier,
                        duration: recordingDuration, targetApp: targetApp,
                        wasRewritten: wasRewritten, lightPolished: lightPolish,
                        transcriptionTime: sttTime, llmPolishTime: llmTime,
                        llmModel: model
                    )
                    VoiceInputStore.shared.add(record)
                } else {
                    // Timeout (or LLM errored): inject raw text now. Keep
                    // awaiting the LLM in the background — when/if it
                    // returns, update history so the polished version
                    // isn't lost just because we missed the 8s window.
                    logger.warning("LLM polish didn't return within 8s — injecting raw text first")

                    let targetApp = await TextInjector.inject(
                        optimizedText,
                        targetPID: capturedTargetPID,
                        targetName: capturedTargetName
                    )
                    let record = VoiceInputRecord(
                        id: id, text: optimizedText, rawTranscript: rawText,
                        audioFileName: VoiceInputStore.newAudioFileName(id: id),
                        language: VoiceInputLanguage.current.localeIdentifier,
                        duration: recordingDuration, targetApp: targetApp,
                        wasRewritten: false, lightPolished: lightPolish,
                        transcriptionTime: sttTime, llmPolishTime: nil,
                        llmModel: model
                    )
                    VoiceInputStore.shared.add(record)

                    Task { [logger] in
                        do {
                            let polished = try await llmTask.value
                            let totalTime = Date().timeIntervalSince(llmStart)
                            let wasRewritten = polished != optimizedText
                            logger.info("LLM polish late result in \(String(format: "%.1f", totalTime))s — updating history")
                            VoiceInputStore.shared.update(id) { rec in
                                rec.text = polished
                                rec.wasRewritten = wasRewritten
                                rec.llmPolishTime = totalTime
                            }
                        } catch is CancellationError {
                            // Parent was cancelled — the raw-text record is
                            // already saved; nothing more to do.
                        } catch {
                            let totalTime = Date().timeIntervalSince(llmStart)
                            logger.error("LLM polish failed after \(String(format: "%.1f", totalTime))s: \(error.localizedDescription, privacy: .public)")
                            VoiceInputStore.shared.update(id) { rec in
                                rec.llmPolishTime = totalTime
                            }
                        }
                    }
                }
            } else {
                logger.info("LLM polish skipped (toggle off in Voice Input Settings)")

                let targetApp = await TextInjector.inject(
                    optimizedText,
                    targetPID: capturedTargetPID,
                    targetName: capturedTargetName
                )
                let record = VoiceInputRecord(
                    id: id, text: optimizedText, rawTranscript: rawText,
                    audioFileName: VoiceInputStore.newAudioFileName(id: id),
                    language: VoiceInputLanguage.current.localeIdentifier,
                    duration: recordingDuration, targetApp: targetApp,
                    wasRewritten: false, lightPolished: nil,
                    transcriptionTime: sttTime, llmPolishTime: nil,
                    llmModel: nil
                )
                VoiceInputStore.shared.add(record)
            }

            // Done!
            state = .done
            hotkeyMonitor.shouldInterceptEscape = false
            updateOverlay()

            // Auto-hide overlay after a short delay
            Task {
                try? await Task.sleep(for: .seconds(1))
                if self.state == .done {
                    self.state = .idle
                    self.hideOverlay()
                }
            }

            logger.info("Voice input complete")

        } catch is CancellationError {
            logger.info("Processing cancelled")
        } catch {
            logger.error("Processing failed: \(error) — dismissing silently")
            silentlyDismiss()
        }
    }

    // MARK: - Overlay Panel

    func showOverlay() {
        if overlayPanel == nil {
            overlayPanel = VoiceInputPanel(manager: self)
        }
        overlayPanel?.showPanel()
    }

    func updateOverlay() {
        overlayPanel?.updateContent()
    }

    func hideOverlay() {
        overlayPanel?.hidePanel()
    }
}
