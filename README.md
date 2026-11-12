# VoiceDictation

A macOS menu bar app for system-wide push-to-talk voice transcription. Hold the Globe key, speak, release — your words are transcribed and pasted into whatever app has focus.

Built for dictating prompts to Claude Code, but works anywhere.

## Requirements

- macOS 13+ (Ventura)
- whisper-cpp: `brew install whisper-cpp`

## Setup

1. Build and run:
   ```bash
   swift build
   .build/debug/VoiceDictation
   ```

2. Grant permissions when prompted:
   - **Accessibility** (System Settings > Privacy & Security > Accessibility)
   - **Microphone** (prompted automatically)

3. Set Globe key to "Do Nothing":
   - System Settings > Keyboard > "Press Globe key to" > "Do Nothing"

4. The app will download the Whisper base.en model (~150MB) on first launch.

## Usage

- **Hold Globe key** to record
- **Release** to transcribe and paste
- **Escape** while holding to cancel
- **Click menu bar icon** to see status, recent transcriptions, and preferences

## Model Selection

Open **Preferences** (click menu bar icon > Preferences..., or Cmd+,) to switch between Whisper models:

- **Tiny (English)** — ~75 MB, fastest, lower accuracy
- **Base (English)** — ~150 MB, good balance (default)
- **Small (English)** — ~500 MB, best accuracy, slower

Models are downloaded automatically when selected.

## Transcription History

Recent transcriptions appear in the menu bar dropdown under "Recent Transcriptions." Click any entry to copy it to the clipboard. History can be toggled on/off in Preferences.

## Bundling whisper-cli

To bundle the whisper-cli binary with the build (eliminates Homebrew dependency at runtime):

```bash
swift build && ./scripts/bundle-whisper.sh
```

The app will look for a bundled binary first, then fall back to Homebrew.

## How It Works

Records audio via AVAudioEngine, transcribes with whisper.cpp (locally, on-device), and pastes via clipboard simulation. No data leaves your machine.

A few things happen quietly to keep it dependable:

- Taps shorter than half a second, and recordings that are effectively silent, are discarded instead of sent to whisper (which otherwise invents words like "you" from silence).
- A recording stops on its own after five minutes, or if your audio device changes mid-sentence, so a lost key-up can never leave the mic open.
- Whatever was on your clipboard before a paste (text, images, files) is put back half a second later, unless you copied something new in between.
- The Globe key listener checks itself every 15 seconds and after the Mac wakes from sleep, and re-arms if macOS has quietly disabled it.

## Troubleshooting

The app writes a log to `~/Library/Logs/VoiceDictation.log` (open it in Console.app or `tail -f` it). Every key event, recording, whisper run, and error lands there.
