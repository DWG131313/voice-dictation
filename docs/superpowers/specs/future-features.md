# VoiceDictation — Future Features (Post-v1)

Features intentionally deferred from v1 to keep the initial build focused. Revisit these after the core push-to-talk flow is working.

## UI & Settings
- **Preferences window** — settings UI for hotkey configuration, model selection, audio device picker
- **Model picker** — allow switching between whisper.cpp models (tiny, base, small, medium) from the menu bar

## Transcription
- **Streaming partial results** — show transcription as it processes rather than waiting for completion
- **Multiple language support** — allow selecting transcription language (whisper.cpp supports many)
- **Custom vocabulary / prompt context** — pass a prompt to whisper.cpp to improve accuracy for domain-specific terms (e.g., programming jargon)
- **Transcription history** — keep a log of recent transcriptions, accessible from menu bar dropdown

## Distribution & Packaging
- **Bundle whisper.cpp binary** — eliminate Homebrew dependency by shipping the binary inside the app bundle
- **Homebrew cask formula** — `brew install --cask voice-dictation` for easy installation

## Clipboard
- **Deep clipboard restore** — save and restore complex clipboard contents (images, rich text, files, multiple pasteboard items) instead of string-only restore

## Cancellation
- **Cancel during transcription** — allow pressing Escape after releasing the hotkey but before paste to discard the result
