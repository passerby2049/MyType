// Abstract:
// Core singleton orchestrating the voice input flow:
// hotkey → record → transcribe → optimize → inject text.

import AVFoundation
import AppKit
import Qwen3ASR
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
    case transcribing
    case polishing
    case inserting
    case done
    case failure(String)

    var isProcessing: Bool {
        switch self {
        case .transcribing, .polishing, .inserting:
            true
        case .idle, .recording, .done, .failure:
            false
        }
    }

    var canCancelProcessing: Bool {
        switch self {
        case .transcribing, .polishing:
            true
        case .idle, .recording, .inserting, .done, .failure:
            false
        }
    }
}

// VoiceInputEngineChoice + VoiceInputLanguage live in
// VoiceInputTypes.swift.

@MainActor @Observable
final class VoiceInputManager {
    static let shared = VoiceInputManager()
    static let soundEffectsEnabledKey = "voiceInputSoundEffects"

    // MARK: - Public State

    var state: VoiceInputState = .idle
    var audioLevel: Float = 0  // 0.0 - 1.0
    var recordingDuration: TimeInterval = 0
    /// How the last dictation was delivered. The overlay shows its
    /// success mark only for `.inserted`; nil until a delivery returns.
    var deliveryStatus: VoiceInputInsertStatus?
    /// Every level read while recording (one per ~33 ms), so the overlay
    /// can draw the whole recording's loudness while it is transcribed.
    @ObservationIgnored var levelHistory: [Float] = []
    @ObservationIgnored var levelMeter = VoiceLevelMeter()

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
    /// This round's polish missed the timeout (raw text typed).
    @ObservationIgnored private var polishTimedOutThisRound = false

    /// Target app captured at recording start. We snapshot it BEFORE the
    /// user can interact with the overlay so clicks on the buttons don't
    /// shift what we consider "the app to inject into".
    var capturedTargetPID: pid_t?
    var capturedTargetName: String?

    /// Lazily-loaded Qwen3-ASR model (speech-swift), kept for the engine
    /// it was loaded for — switching 1.7B / 0.6B loads the other.
    var qwen3Model: Qwen3ASRModel?
    var qwen3LoadedEngine: VoiceInputEngineChoice?

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
                guard let self else { return }
                // While the misread sheet is selected the hotkey practises (MisreadCoach).
                let busy = self.state == .recording || self.state.isProcessing
                if MisreadCoach.shared.handleHotkey(dictationBusy: busy) == .dictation { self.toggleRecording() }
            }
        }
        hotkeyMonitor.onCancelPressed = { [weak self] in
            Task { @MainActor in
                self?.cancelRecording()
            }
        }
        hotkeyMonitor.onRetypeLastPressed = { [weak self] in
            Task { @MainActor in
                self?.retypeLast()
            }
        }
        hotkeyMonitor.onPolishHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.polishSelectedText()
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

    var soundEffectsEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.soundEffectsEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.soundEffectsEnabledKey)
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
        case .transcribing, .polishing, .inserting:
            // A second tap while the last one is still being worked on is a
            // bounce or an early start on the next — it used to cancel and
            // throw away what was just said. Esc and the overlay's ✕ cancel.
            logger.info("Hotkey ignored — still finishing (\(String(describing: self.state)))")
        }
    }

    /// Cancel the current recording or processing.
    func cancelRecording() {
        if state.canCancelProcessing {
            cancelProcessing()
            return
        }
        if state == .inserting {
            logger.info("Cancel ignored — text insertion is already in progress")
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

    /// Dismiss the overlay — used when transcription fails or produces no
    /// content. The audio file is cleaned up. With a `problem`, the card
    /// above the pill says what happened (nothing for a tap too short).
    func silentlyDismiss(_ problem: ProblemCard.Problem? = nil) {
        stopRecorderAndTimer()
        cleanupCurrentRecording()
        state = .idle
        hideOverlay()
        if let problem { ProblemCard.shared.show(problem) }
    }

    /// The card above the pill when the text didn't end up typed as polished.
    private func showDeliveryProblem(_ status: VoiceInputInsertStatus, text: String) {
        let timedOut = polishTimedOutThisRound
        polishTimedOutThisRound = false
        switch status {
        case .copiedFallback: ProblemCard.shared.show(.copied)
        case .failed: ProblemCard.shared.show(.insertFailed(text))
        case .inserted: if timedOut { ProblemCard.shared.show(.polishTimeout) }
        }
    }

    // MARK: - Processing Pipeline

    func processRecording() async {
        guard let id = currentRecordingID else {
            logger.info("No recording to process — dismissing silently")
            silentlyDismiss()
            return
        }

        let audioURL = VoiceInputStore.newAudioFileURL(id: id)
        let stoppedAt = Date()

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            logger.info("Recording file not found — dismissing silently")
            silentlyDismiss()
            return
        }

        let conversationTask = readConversation()

        do {
            // Step 1: Transcribe using the configured engine
            deliveryStatus = nil
            state = .transcribing
            updateOverlay()
            let sttStart = Date()
            let rawText = try await transcribeAudio(at: audioURL)
            let sttTime = Date().timeIntervalSince(sttStart)
            try Task.checkCancellation()

            guard !rawText.isEmpty else {
                logger.info("No speech detected — dismissing")
                silentlyDismiss(.noSpeech)
                return
            }

            // Step 2: Post-process (DictationOptimizer)
            let optimizedText = DictationOptimizer.optimize(rawText)
            try Task.checkCancellation()

            // Step 3: Optional LLM polish — with timeout fallback.
            // If LLM takes longer than 10s, inject the raw STT text first
            // so the user isn't blocked. LLM result updates history later.
            let llmEnabled = LLMRewriter.isEnabled
            let model = llmEnabled ? LLMRewriter.resolvedModel : nil
            let mode: LLMRewriter.PolishMode? = llmEnabled ? LLMRewriter.polishMode : nil
            let lightPolish = mode.map { $0 != .strict }
            let polishModeRaw = mode?.rawValue
            let vocabTerms = VocabularyStore.shared.enabledTerms.map(\.term)
            logger.info("LLM polish enabled? \(llmEnabled, privacy: .public)")

            if llmEnabled, let model {
                state = .polishing
                updateOverlay()
                logger.info("LLM polish using model: \(model, privacy: .public)")
                let conversation = await conversationIfReady(conversationTask)
                let llmStart = Date()

                // Race: LLM polish vs a 10 s timeout. If the LLM is slow
                // (thinking, network, a stuck session), inject raw text first.
                // Was 60 s; since the 10/09 engine change 175 polishes took
                // p50 2.0 s, p99 5.9 s, max 6.6 s (a cold Opus session).
                let llmTask = Task {
                    try await LLMRewriter.rewrite(
                        rawText: optimizedText,
                        language: VoiceInputLanguage.current,
                        model: model,
                        vocabularyTerms: vocabTerms,
                        frontApp: capturedTargetName,
                        conversation: conversation?.text
                    )
                }

                let polishResult: String?
                do {
                    polishResult = try await withThrowingTaskGroup(of: String?.self) { group in
                        group.addTask { try await llmTask.value }
                        group.addTask {
                            try await Task.sleep(for: .seconds(10))
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

                    state = .inserting
                    updateOverlay()
                    let insertStart = Date()
                    let injection = await TextInjector.inject(
                        polished,
                        targetPID: capturedTargetPID,
                        targetName: capturedTargetName
                    )
                    deliveryStatus = injection.status
                    showDeliveryProblem(injection.status, text: injection.typedText)
                    logTiming(stoppedAt: stoppedAt, stt: sttTime, polish: llmTime)
                    let vocabularyHitCount = VocabularyStore.shared.recordHits(in: polished)
                    var record = VoiceInputRecord(
                        id: id, text: polished, rawTranscript: rawText,
                        audioFileName: VoiceInputStore.newAudioFileName(id: id),
                        language: VoiceInputLanguage.current.resolved(for: rawText).localeIdentifier, duration: recordingDuration,
                        targetApp: injection.targetApp, insertStatus: injection.status,
                        errorCode: errorCode(insertStatus: injection.status),
                        vocabularyHitCount: vocabularyHitCount,
                        wasRewritten: wasRewritten, lightPolished: lightPolish, polishMode: polishModeRaw,
                        transcriptionTime: sttTime, llmPolishTime: llmTime,
                        llmModel: model
                    )
                    record.insertTime = injection.finishedAt.timeIntervalSince(insertStart)
                    record.polishCold = LLMRewriter.lastPolishCold
                    record.contextSession = conversation?.session
                    saveHistoryRecordIfNeeded(record)
                    if injection.status == .inserted {
                        MisreadCoach.shared.consider(id: id, raw: rawText, polished: polished, conversation: conversation?.text, typedAt: injection.finishedAt)
                    }
                } else {
                    // Timeout (or LLM errored): inject raw text now. Keep
                    // awaiting the LLM in the background — when/if it
                    // returns, update history so the polished version
                    // isn't lost just because we missed the 10s window.
                    logger.warning("LLM polish didn't return within 10s — injecting raw text first")
                    polishTimedOutThisRound = true

                    state = .inserting
                    updateOverlay()
                    let insertStart = Date()
                    let injection = await TextInjector.inject(
                        optimizedText,
                        targetPID: capturedTargetPID,
                        targetName: capturedTargetName
                    )
                    deliveryStatus = injection.status
                    showDeliveryProblem(injection.status, text: injection.typedText)
                    logTiming(stoppedAt: stoppedAt, stt: sttTime, polish: llmTime)
                    let vocabularyHitCount = VocabularyStore.shared.recordHits(in: optimizedText)
                    var record = VoiceInputRecord(
                        id: id, text: optimizedText, rawTranscript: rawText,
                        audioFileName: VoiceInputStore.newAudioFileName(id: id),
                        language: VoiceInputLanguage.current.resolved(for: rawText).localeIdentifier, duration: recordingDuration,
                        targetApp: injection.targetApp, insertStatus: injection.status,
                        errorCode: errorCode(insertStatus: injection.status, polishTimedOut: true),
                        vocabularyHitCount: vocabularyHitCount,
                        wasRewritten: false, lightPolished: lightPolish, polishMode: polishModeRaw,
                        transcriptionTime: sttTime, llmPolishTime: llmTime,
                        llmModel: model
                    )
                    record.insertTime = injection.finishedAt.timeIntervalSince(insertStart)
                    record.polishCold = LLMRewriter.lastPolishCold
                    record.contextSession = conversation?.session
                saveHistoryRecordIfNeeded(record)

                    if VoiceInputStore.isHistoryEnabled {
                        Task { [logger] in
                            do {
                                let polished = try await llmTask.value
                                let totalTime = Date().timeIntervalSince(llmStart)
                                let wasRewritten = polished != optimizedText
                                logger.info("LLM polish late result in \(String(format: "%.1f", totalTime))s — updating history")
                                if wasRewritten { ProblemCard.shared.polishArrived(polished) }
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
                    } else {
                        llmTask.cancel()
                    }
                }
            } else {
                logger.info("LLM polish skipped (toggle off in Voice Input Settings)")

                state = .inserting
                updateOverlay()
                let insertStart = Date()
                let injection = await TextInjector.inject(
                    optimizedText,
                    targetPID: capturedTargetPID,
                    targetName: capturedTargetName
                )
                deliveryStatus = injection.status
                showDeliveryProblem(injection.status, text: injection.typedText)
                logTiming(stoppedAt: stoppedAt, stt: sttTime, polish: nil)
                let vocabularyHitCount = VocabularyStore.shared.recordHits(in: optimizedText)
                var record = VoiceInputRecord(
                    id: id, text: optimizedText, rawTranscript: rawText,
                    audioFileName: VoiceInputStore.newAudioFileName(id: id),
                    language: VoiceInputLanguage.current.resolved(for: rawText).localeIdentifier, duration: recordingDuration,
                    targetApp: injection.targetApp, insertStatus: injection.status,
                    errorCode: errorCode(insertStatus: injection.status),
                    vocabularyHitCount: vocabularyHitCount,
                    wasRewritten: false, lightPolished: nil,
                    transcriptionTime: sttTime, llmPolishTime: nil,
                    llmModel: nil
                )
                record.insertTime = injection.finishedAt.timeIntervalSince(insertStart)
                saveHistoryRecordIfNeeded(record)
            }

            // Done!
            clearCurrentSessionAfterSuccess()
            state = .done
            hotkeyMonitor.shouldInterceptEscape = false
            updateOverlay()

            // Hide once the overlay's completion feedback has played
            // (it fades itself out by ~0.8s; see VoiceInputCompletionMark).
            Task {
                try? await Task.sleep(for: .milliseconds(850))
                if self.state == .done {
                    self.state = .idle
                    self.hideOverlay()
                }
            }

            logger.info("Voice input complete")

        } catch is CancellationError {
            logger.info("Processing cancelled")
        } catch {
            logger.error("Processing failed: \(error) — dismissing")
            silentlyDismiss(.failed(error.localizedDescription))
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
