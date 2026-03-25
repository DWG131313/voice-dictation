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
- **Click menu bar icon** to see status

## How It Works

Records audio via AVAudioEngine, transcribes with whisper.cpp (locally, on-device), and pastes via clipboard simulation. No data leaves your machine.
