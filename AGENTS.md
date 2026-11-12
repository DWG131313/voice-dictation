# VoiceDictation

## Project Overview
macOS menu bar app for system-wide push-to-talk voice transcription. Hold Globe key, speak, release — transcribed text pastes into the frontmost app. Fully offline via whisper.cpp. No data leaves the machine.

## Owner
Danny (daniel.gross85@gmail.com) — personal use, MacMini.

## Tech Stack
- Swift 5.9+ / macOS 13+ (Ventura)
- Swift Package Manager (no external dependencies)
- AVFoundation (audio), AppKit (menu bar UI), Carbon.HIToolbox (Globe key)
- whisper.cpp via Homebrew (`brew install whisper-cpp`) or bundled binary

## Key Commands
```bash
swift build                        # Debug build
swift build -c release             # Release build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # Run tests; xcode-select points at Command Line Tools, which has no XCTest
./scripts/bundle-whisper.sh        # Bundle whisper-cpp binary + dylibs
nohup .build/debug/VoiceDictation >/dev/null 2>&1 &   # Run the app (always background it)
tail -f ~/Library/Logs/VoiceDictation.log             # Watch the app log
```

## Architecture
```
main.swift → AppDelegate (orchestrator)
  → HotkeyManager (Globe key event tap)
  → AudioRecorder (AVAudioEngine, 16kHz mono)
  → Transcriber (whisper-cpp CLI subprocess)
  → PasteEngine (clipboard Cmd+V simulation)
  → StatusManager (menu bar icon + dropdown)
  → ModelManager (Whisper model download/cache)
  → PermissionManager (Accessibility + Mic checks)
  → PreferencesManager (UserDefaults)
  → TranscriptionHistory (JSON persistence)
  → Log (stdout + rotating ~/Library/Logs/VoiceDictation.log)
```

## Key Files
- `Sources/VoiceDictationLib/` — 15 modules
- `Tests/VoiceDictationTests/` — 7 test files
- `scripts/bundle-whisper.sh` — Binary bundling for distribution
- `docs/superpowers/specs/` — Design spec + v2 plan + future roadmap
- `Resources/Info.plist` — Bundle config (LSUIElement=true for menu bar)

## Known Constraints
- Globe key requires "Press Globe key to: Do Nothing" in System Settings
- whisper-cpp must be installed (`brew install whisper-cpp`) or bundled
- A bundled `whisper-cli` must be ad-hoc signed (`bundle-whisper.sh` does this). Unsigned arm64 binaries are SIGKILLed (status 9) on launch. `BundledBinary.findWhisperCLI()` test-launches each candidate with `--help` and skips ones that can't run
- Menu bar SF Symbols must exist on the target macOS; `StatusManager.symbol()` falls back to `mic.fill` so the icon never blanks
- Accidental taps < 0.5s and near-silent recordings (peak < 0.01) are silently discarded
- Recordings auto-stop at 5 minutes or on an audio device change
- Whole-transcript whisper hallucinations ("you", "Thank you.") are dropped; see `Transcriber.silenceHallucinations`
- Clipboard is fully snapshotted and restored after paste (all pasteboard types), skipped if the user copied something new meanwhile
- The event tap self-heals: 15s health timer + wake notification (`HotkeyManager`)
- Xcode is installed on the laptop, but `xcode-select` points at Command Line Tools, so a plain `swift test` fails with "no such module 'XCTest'". Prefix `swift` and `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (34 tests pass that way)

## Codex Knowledge Base

When you need to leverage Codex's advanced capabilities — hooks, custom agents, skills, permission patterns, multi-agent orchestration, or SDK usage — reference the central learnings at:

- **Architecture & capabilities (99 flags, 41 tools, 27 hooks, 100+ env vars):** `/Users/dannygross/CodingProjects/Codex codebase/learnings/CLAUDE_CODE_DEEP_DIVE.md`
- **Hook recipes & reference (all 27 events with I/O schemas):** `/Users/dannygross/CodingProjects/Codex codebase/learnings/HOOKS_REFERENCE.md`
- **Custom skill templates (8 production skills):** `/Users/dannygross/CodingProjects/Codex codebase/learnings/skills/`
- **Full Codex source:** `/Users/dannygross/CodingProjects/Codex codebase/src/`

Read these when the task involves configuring hooks, building skills, defining custom agents, optimizing permissions, setting up multi-agent workflows, or leveraging any Codex feature beyond basic usage. The source code is the definitive reference for how any feature actually works.

**Voice-dictation-specific patterns in the CC source:**
- **Subprocess management:** `src/utils/ShellCommand.ts` — StreamWrapper + TaskOutput + size watchdog for whisper-cpp subprocess
- **Status state machine:** `src/components/Spinner.tsx` — multi-mode states with minimum display duration; model for recording → transcribing → idle
- **Atomic file ops:** `src/utils/file.ts` — temp + pid + timestamp + rename for transcription history
- **Input sanitization:** `src/tools/BashTool/bashSecurity.ts` — concepts for sanitizing whisper-cpp arguments
- **Keyboard shortcuts:** `src/keybindings/` — context-aware chord resolution; model for hotkey management
- **Full pattern map:** `learnings/PROJECT_PATTERNS_MAP.md`
