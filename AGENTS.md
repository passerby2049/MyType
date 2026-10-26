# MyType — AI Development Guidelines

## Project Overview

macOS menu bar voice input app. Press fn (Globe) to record, release to transcribe + LLM polish + paste into the active app. Built with SwiftUI + AppKit, deployment target **macOS 27.0**.

Core features: local on-device STT (Qwen3-ASR via speech-swift, Apple Speech), LLM-powered voice polish (Claude Code persistent session, Anthropic API, Google AI, OpenRouter), custom vocabulary, history with audio playback.

## Architecture

### App Lifecycle

**Not** a SwiftUI App — uses `NSApplication.shared.run()` directly (TypeFlux pattern) for reliable menu bar app behavior. `AppDelegate` owns the status bar item and kicks off `VoiceInputManager`.

### File Organization

```
MyType/
├── MyTypeApp.swift              — NSApplication entry + AppDelegate + status bar
├── AI/                          — LLM gateway
│   ├── AIProvider.swift         — Unified streaming for OpenRouter/Anthropic/Google/Claude Code
│   ├── AppPreferences.swift     — API key storage (UserDefaults)
│   └── ClaudeCodeVoicePolishSession.swift — Persistent claude -p session
├── VoiceInput/                  — Core voice input feature
│   ├── VoiceInputManager.swift  — Orchestrator: hotkey → record → transcribe → polish → inject
│   ├── VoiceInputPanel.swift    — Floating NSPanel host (show/hide)
│   ├── VoiceInputOverlayView.swift — Waveform capsule view
│   ├── GlobalHotkeyMonitor.swift — fn key interception via CGEventTap
│   ├── TextInjector.swift       — CGEvent-based text injection into focused app
│   ├── LLMRewriter.swift        — STT error correction (prompt in LLMRewriter+Prompt.swift)
│   ├── DictationOptimizer.swift — Post-transcription text cleanup
│   ├── VoiceInputRecord.swift   — Data model
│   ├── VoiceInputStore.swift    — JSON persistence
│   ├── VocabularyStore.swift    — Custom vocabulary
│   ├── VoiceInputTypes.swift    — Engine/language enums
│   ├── VoiceInputSettingsView.swift — Two-column settings (NavigationSplitView)
│   ├── VoiceInputHistoryView.swift  — History with audio playback
│   ├── MisreadCandidates.swift — Misread English words: raw vs polished, one word for another (LifeKit WordDiff)
│   ├── MisreadJudge.swift      — Its own warm Sonnet session: sound / newWord / wording / weak / unsure
│   ├── MisreadCoach.swift      — After typing: judge, record.misreads, the bar and sheet, practice takes, hotkey route
│   ├── MisreadPanels.swift / MisreadSheetView.swift / MisreadSheetModel.swift / MisreadAlignment.swift — the sheet
│   └── MisreadPractice.swift   — Take recorder; RecognitionRequest.practice (no context, no polish)
└── Transcription/               — STT engines
    ├── TranscriptionEngine.swift — Protocol + engine registry
    └── AppleSpeechEngine.swift   — Apple Speech backend
                                    (Qwen3-ASR runs in VoiceInputManager+Transcription.swift)
```

### Key Design Decisions

- **No dock icon**: `NSApp.setActivationPolicy(.accessory)` — pure menu bar app.
- **Persistent Claude session**: `ClaudeCodeVoicePolishSession` keeps a warm `claude -p --input-format stream-json` subprocess. The rules go in once as `--append-system-prompt`; each turn sends only the app and the transcript (~1.7s/turn).
- **Data directory**: `~/Library/Application Support/MyType/VoiceInput/`
- **Entitlements**: `com.apple.security.device.audio-input` required for microphone permission dialog. App Sandbox is OFF (needed for CGEventTap accessibility).

## UI

Avoid unnecessary secondary labels and descriptions. Let the layout do the explaining.

## Code Style

- SwiftUI views: prefer computed properties (`var xxx: some View`) over inline code in `body`.
- Use `@ViewBuilder` only when the computed property needs conditional returns.
- No `print()` or `NSLog()` in production. Use `os.Logger`.
- Prefer `Task { @MainActor in }` for UI updates from async contexts.
- **No file should exceed 500 lines.** Use extensions in separate files to split.
- **Deprecated APIs to avoid**: `.foregroundColor()` → `.foregroundStyle()`, single-parameter `.onChange(of:perform:)` → two-parameter form.
- **Don't return freshly-built collections from SwiftUI computed properties** — `allCases.filter { }` allocates on every body re-eval. Use `private static let` instead.

## Common Pitfalls

- **CGEventTap needs Accessibility permission** — `AXIsProcessTrustedWithOptions` returns false immediately when showing the prompt dialog. The code polls every 2s until granted, then upgrades from NSEvent fallback to CGEventTap.
- **Microphone permission needs entitlement** — Even without App Sandbox, `com.apple.security.device.audio-input` entitlement is required for the TCC dialog to appear.
- **`NSWindow.isReleasedWhenClosed`** — Must be set to `false` for windows managed by AppDelegate, otherwise the reference becomes dangling after the user closes the window.
- **VoiceInputPanel hide/show race** — `hidePanel` uses an animation with completion handler that calls `orderOut`. If `showPanel` is called during the animation, the completion handler must check `alphaValue` before ordering out.
- **Don't use SwiftUI App lifecycle for menu bar apps** — `@NSApplicationDelegateAdaptor` + `Settings {}` scene doesn't reliably call `applicationDidFinishLaunching` on macOS 26. Use `NSApplication.shared.run()` directly.
- **Menu bar apps need an Edit menu** — Without `NSApp.mainMenu` containing an Edit menu, Cmd+V paste doesn't work in text fields. Set up a minimal main menu in `applicationDidFinishLaunching`.
- **Don't put plain `nonisolated` on `@Observable` stored properties** — use `@ObservationIgnored nonisolated(unsafe)` for cross-actor access from CGEventTap callbacks.
- **Don't hardcode `@State` defaults that mirror persistent data** — derive from the source of truth: `@State private var provider = AIProvider.provider(for: LLMRewriter.resolvedModel)`.
- **Don't forget to reset progress fields between invocations** — `audioLevel`, `recordingDuration` must be zeroed in `stopRecorderAndTimer()` so stale values don't show on next recording.
- **Don't leave temp audio files behind on failure** — `cleanupCurrentRecording()` must delete the audio file. Track the recording ID and clean up in every error path.
- **Swift scripts: don't combine `@MainActor` + `DispatchSemaphore.wait()`** — use `Task.detached { ...; exit(0) }` + `RunLoop.main.run()` instead.
- **`--effort` flag requires full model name** — aliases like `sonnet` silently ignore `--effort`. Pass the full ID that `ClaudeCodeVoicePolishSession.fullModel` returns.
- **Trust `xcodebuild`, not SourceKit diagnostics** — filesystem-synchronized groups cause phantom errors.
