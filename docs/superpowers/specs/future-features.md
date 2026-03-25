# VoiceDictation — Future Features (Post-v2)

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
