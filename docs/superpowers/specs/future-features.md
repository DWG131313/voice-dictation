# VoiceDictation — Future Features (Post-v2)

> **Retired 2026-11-12.** This page is kept for history, because the v2 plan cites it. Open ideas now live in `docs/feature-requests.md`. Most of this list shipped in the native app. The Homebrew install moved to the backlog. Streaming text and other languages were dropped; the app is English only.

Features intentionally deferred to keep the build focused. Revisit after the current feature set is stable.

## Transcription
- **Streaming partial results** — show transcription as it processes rather than waiting for completion
- **Multiple language support** — allow selecting transcription language (whisper.cpp supports many)
- **Custom vocabulary / prompt context** — pass a prompt to whisper.cpp to improve accuracy for domain-specific terms (e.g., programming jargon)

## Distribution & Packaging
- **Homebrew cask formula** — `brew install --cask voice-dictation` for easy installation

## Clipboard
- **Deep clipboard restore** — save and restore complex clipboard contents (images, rich text, files, multiple pasteboard items) instead of string-only restore

## Cancellation
- **Cancel during transcription** — allow pressing Escape after releasing the hotkey but before paste to discard the result
