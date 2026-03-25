# VoiceDictation Design Spec

## Overview

VoiceDictation is a macOS menu bar app (Swift) that provides system-wide push-to-talk voice transcription. Hold a hotkey to record, release to transcribe via whisper.cpp, and the transcribed text is pasted into whatever app has focus. Designed primarily for dictating prompts to Claude Code but works anywhere.

## Core Interaction

1. User holds hotkey (Globe key by default)
2. App starts recording audio, menu bar icon turns red
3. User releases hotkey
4. App stops recording, transcribes via whisper.cpp CLI, menu bar icon shows spinner
5. Transcribed text is pasted into the frontmost app via clipboard paste (Cmd+V)
6. Menu bar icon returns to idle

## Architecture

```
+-----------------------------------------------+
|              Menu Bar Agent                    |
|                                                |
|  +-------------+   +--------------+            |
|  | Permission  |   | Status       |            |
|  | Manager     |   | Manager      |            |
|  +-------------+   +--------------+            |
|                                                |
|  +-------------+   +--------------+  +-------+ |
|  | Hotkey      |-->| Audio        |->| Paste | |
|  | Manager     |   | Recorder     |  | Engine| |
|  +-------------+   +------+-------+  +---^---+ |
|                           |              |      |
|                           v              |      |
|                    +--------------+      |      |
|                    | Transcriber  |------+      |
|                    +--------------+             |
|                           |                     |
|                    +--------------+             |
|                    | Model        |             |
|                    | Manager      |             |
|                    +--------------+             |
+-----------------------------------------------+
```

## Components

### AppDelegate
- Menu bar setup with `NSStatusItem`
- No dock icon (`LSUIElement = true`)
- No main window
- Coordinates all components at launch
- Login item via `SMAppService.mainApp.register()` (macOS 13+)

### PermissionManager
- Checks Accessibility permission via `AXIsProcessTrustedWithOptions`
- Requests Microphone permission via `AVCaptureDevice.requestAccess(for: .audio)`
- Exposes permission state for StatusManager to display
- Guides user through granting permissions on first launch
- App must be re-launched after granting Accessibility permission

### HotkeyManager
- Designed with a protocol so hotkey strategies can be swapped
- **Primary strategy (v1): Globe key**
  - Uses `CGEvent.tapCreate` with `.cgSessionEventTap` to intercept keycode 63 (kVK_Function)
  - Globe key is a modifier, so we receive `flagsChanged` events, not keyDown/keyUp
  - Track Fn flag transitions: flag appeared = "key down", flag disappeared = "key up"
  - Known risk: macOS Ventura+ may intercept Globe key before our event tap for emoji picker/dictation
  - User must set "Press Globe key to: Do Nothing" in System Settings > Keyboard
  - Alternative detection: `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` if CGEvent tap fails
- **Fallback strategy: configurable hotkey**
  - Default: `Cmd+Shift+Space`
  - Standard keyDown/keyUp detection via CGEvent tap
  - Switch to this if Globe key proves unreliable
- **Cancel mechanism:** pressing Escape while recording discards the recording and returns to idle
- Requires Accessibility permission

### AudioRecorder
- `AVAudioEngine` with `inputNode`
- Records at 16kHz mono PCM 16-bit (whisper.cpp's expected format)
  - Mac hardware runs at 44.1/48kHz — `installTap` with desired format lets the engine handle resampling
  - If resampling fails on some hardware, fall back to native rate + `AVAudioConverter` post-recording
- Writes to temp file via `AVAudioFile` at `FileManager.default.temporaryDirectory`
- Plays subtle system tick sound (`NSSound`) on record start and stop for feedback
- Discards recordings shorter than 0.5 seconds (accidental taps)
- Handles audio session conflicts gracefully (e.g., if another app has exclusive microphone access)
- Cleans up temp WAV files after transcription completes

### Transcriber
- Runs whisper.cpp CLI via `Process` (Foundation)
- Binary location resolution order:
  1. Bundled binary in app resources (if we bundle it)
  2. `/opt/homebrew/bin/whisper-cpp` (Homebrew, Apple Silicon)
  3. `/usr/local/bin/whisper-cpp` (Homebrew, Intel)
- Invocation: `whisper-cpp -m <model-path> -f <wav-file> --no-timestamps -nt`
- Parses stdout for transcribed text, stderr for errors
- Timeout: `max(10, recordingDuration * 3)` seconds — scales with recording length
- Queues transcription requests — if user records again while transcribing, queue it (don't kill previous)
- Error handling:
  - Binary not found: surface in menu bar, suggest Homebrew install
  - Model corrupted/missing: trigger re-download
  - Empty result: no paste, no error (silence is valid)
  - Timeout: kill process, show error icon

### PasteEngine
- Clipboard paste with save/restore approach:
  1. Save current `NSPasteboard.general` contents (all types/data from all items)
  2. Clear pasteboard, set transcribed text as `.string`
  3. Simulate `Cmd+V` via `CGEvent` (keycode `0x09` = kVK_ANSI_V, with `.maskCommand`)
  4. After 100ms delay, restore previous clipboard contents
- Requires Accessibility permission (same as hotkey detection)
- Handles edge case: if pasteboard restore is complex (images, rich text, files), v1 accepts briefly overwriting clipboard with a TODO to improve deep-copy in v2

### ModelManager
- Model: `ggml-base.en.bin` (~150MB)
- Storage: `~/Library/Application Support/VoiceDictation/models/`
- Downloads from Hugging Face on first launch
- Uses `URLSession` with delegate for download progress tracking
- Progress displayed in menu bar dropdown during download
- Validates model file integrity after download (file size check)
- If model is missing or corrupted at runtime, triggers re-download

### StatusManager
- Manages menu bar icon state machine:
  - **Idle:** `mic.fill` (SF Symbol, monochrome) — ready to record
  - **Recording:** `mic.fill` with red tint — hotkey held
  - **Transcribing:** `mic.badge.ellipsis` — processing audio
  - **Error:** `mic.slash.fill` — clears after 5 seconds
- Menu bar dropdown contents:
  - Status line: "Ready" / "Recording..." / "Transcribing..." / error message
  - Permission warnings (if Accessibility or Microphone not granted)
  - Model download progress (during first-launch download)
  - Separator
  - "Model: base.en" (informational)
  - Separator
  - "Quit VoiceDictation"

## App Lifecycle

### First Launch
1. Check and request Accessibility permission (show guidance dialog if not granted)
2. Request Microphone permission
3. Check for whisper-cpp binary, show install guidance if missing
4. Download whisper base.en model with progress indicator
5. Show notification: "VoiceDictation is ready — hold Globe key to dictate"

### Normal Launch
1. Verify permissions still granted
2. Verify whisper-cpp binary and model present
3. Install hotkey listener
4. Show idle menu bar icon

### Login Item
- Register via `SMAppService.mainApp.register()` (macOS 13+)
- No LaunchAgent plist needed

## Project Structure

```
VoiceDictation/
+-- VoiceDictation.xcodeproj
+-- VoiceDictation/
|   +-- AppDelegate.swift          # Menu bar setup, component coordination
|   +-- HotkeyManager.swift        # Globe key / configurable hotkey detection
|   +-- AudioRecorder.swift        # AVAudioEngine recording to WAV
|   +-- Transcriber.swift          # whisper-cpp CLI wrapper
|   +-- PasteEngine.swift          # Clipboard paste with save/restore
|   +-- ModelManager.swift         # Model download and path management
|   +-- PermissionManager.swift    # Accessibility + Microphone permission checks
|   +-- StatusManager.swift        # Menu bar icon state machine + dropdown
|   +-- Info.plist                 # LSUIElement = true
|   +-- VoiceDictation.entitlements
|   +-- Assets.xcassets/
+-- README.md
```

## Permissions & Distribution

- **Not sandboxed** — CGEvent taps, Process spawning, and microphone access require it
- **Cannot distribute via Mac App Store** — direct distribution only (notarized DMG or Homebrew cask)
- **Hardened Runtime** enabled with entitlements:
  - `com.apple.security.device.audio-input`
  - `com.apple.security.automation.apple-events`
- **Notarization** via `notarytool` for distribution

## Requirements

- macOS 13+ (Ventura) — for `SMAppService` and modern SF Symbols
- Apple Silicon or Intel Mac
- whisper-cpp installed via Homebrew (`brew install whisper-cpp`)
- Accessibility permission granted in System Settings
- Microphone permission granted

## Out of Scope (v1)

- Preferences window / settings UI
- Model picker (locked to base.en)
- Transcription history
- Streaming partial transcription results
- Multiple language support
- Custom vocabulary / prompt context
- Bundling whisper.cpp binary (require Homebrew for v1)
- Deep clipboard restore (rich text, images, files)

## Known Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Globe key intercepted by macOS before our event tap | High | Require user to set "Press Globe key to: Do Nothing" in System Settings. Fall back to configurable hotkey if unreliable. |
| AVAudioEngine resampling to 16kHz fails on some hardware | Low | Fall back to native rate recording + AVAudioConverter |
| whisper-cpp binary not found or wrong version | Medium | Clear error messaging, install guidance in menu dropdown |
| Clipboard restore loses complex content (images, files) | Low | Accept for v1, improve in v2 |
