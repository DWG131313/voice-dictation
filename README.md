# VoiceDictation

Hold a key, say what you mean, let go: your words appear in whatever app you are typing in. VoiceDictation lives in the menu bar and turns speech into text on the Mac itself. It was built for talking to Claude Code, and it works anywhere you can type.

## Install

VoiceDictation needs macOS 26 or later.

A release is a signed, notarised zip that opens without a warning. `./scripts/release.sh` makes one as `dist/VoiceDictation-<version>.zip` (the one-time setup is in `docs/release.md`). Unzip it, drag VoiceDictation into Applications and open it.

To build it yourself you need Xcode and XcodeGen (`brew install xcodegen`). Then `./scripts/run-dev.sh` builds the app and opens it.

The first time it opens, the Welcome window walks through what it needs, with a button for each: the microphone, Accessibility (so it can hear the hotkey and paste), the Globe key set to "Do Nothing", and the speech model. That model is whisper.cpp base.en, 148 MB, and it downloads only when you press Download in the Speech model step, never by itself. A Mac that ran the old VoiceDictation already has it, and its history comes across too.

## Dictate

Hold the hotkey to dictate, or double-tap it with "Double-tap to dictate" on. The hotkey is Globe unless you choose Right Option or Right Command in Settings. Speak, let go, and the text pastes where your cursor is. Escape cancels while recording, transcribing or cleaning up.

The menu bar icon has the rest: the window with every transcript, Paste Last Transcript, the model in use, Settings, and Check for Updates.

## What stays on your Mac

All of it. whisper.cpp runs inside the app, so your voice becomes text without going anywhere, and so do Apple's speech models and WhisperKit's if you pick one in Models. Cleanup, which drops filler words and fixes punctuation and capitals, runs on Apple Intelligence's on-device model, never the cloud one. Transcripts and recent recordings stay in `~/Library/Application Support/VoiceDictation/`. The app goes online only when you ask it to: to download a speech model you picked, or to look for a new version when you choose Check for Updates in the menu. It never checks by itself.

If something seems off, the app keeps a log at `~/Library/Logs/VoiceDictation.log`.
