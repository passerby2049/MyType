# MyType

macOS menu bar voice input app — press fn (Globe) to record, release to transcribe + AI polish + paste into any app.

Local STT → LLM polish → auto paste. Your data stays on your Mac.

## Features

- **One-key voice input** — Hold fn (Globe), speak, release. Text appears in your active app.
- **Local transcription** — Qwen3-ASR, Parakeet TDT, or Apple Speech. Audio never leaves your device.
- **AI text polish** — Fix STT errors (Chinese homophones, English terms transcribed as phonetics). Optional light polish mode for smoother output.
- **Persistent Claude session** — Reuses a warm `claude -p` subprocess for ~1.7s/turn polish (vs ~8s cold start).
- **Custom vocabulary** — Add domain-specific terms to improve recognition accuracy.
- **History** — Browse past transcripts with audio playback, processing time stats, and raw vs polished comparison.
- **Menu bar app** — No dock icon. Lives in the status bar, always ready.

## Requirements

- macOS 26.0+
- Apple Silicon recommended (for on-device STT acceleration)
- [Claude Code CLI](https://claude.ai/claude-code) (optional, for AI polish via Claude)

## Setup

1. Build and run from Xcode
2. Grant **Accessibility** permission (System Settings → Privacy & Security → Accessibility)
3. Grant **Microphone** permission (prompted on first recording)
4. Download an STT model in Settings → Engine (Qwen3-ASR recommended for Chinese)
5. Press fn to start!

## STT Models

| Model | Languages | Size |
|-------|-----------|------|
| Qwen3-ASR (int8) | Chinese + English | ~900 MB |
| Qwen3-ASR (f32) | Chinese + English | ~1.75 GB |
| Parakeet TDT v3 | 25 European languages | ~500 MB |
| Parakeet TDT v2 | English only | ~500 MB |
| Apple Speech | System languages | Built-in |

## AI Polish

Supports multiple LLM providers:

- **Claude Code** (cc-opus / cc-sonnet / cc-haiku) — persistent session, fastest
- **Google AI** (gemini-2.5-flash) — default, fast and cheap
- **OpenRouter** — access to many models
- **Anthropic API** — direct Claude API

Configure in Settings → AI Polish.

## License

Private project.
