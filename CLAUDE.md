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
swift test                         # Run tests (4 test files)
./scripts/bundle-whisper.sh        # Bundle whisper-cpp binary + dylibs
.build/debug/VoiceDictation        # Run the app
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
```

## Key Files
- `Sources/VoiceDictationLib/` — 12 modules (~1,481 LOC)
- `Tests/VoiceDictationTests/` — 4 test files (~100 LOC)
- `scripts/bundle-whisper.sh` — Binary bundling for distribution
- `docs/superpowers/specs/` — Design spec + v2 plan + future roadmap
- `Resources/Info.plist` — Bundle config (LSUIElement=true for menu bar)

## Known Constraints
- Globe key requires "Press Globe key to: Do Nothing" in System Settings
- whisper-cpp must be installed (`brew install whisper-cpp`) or bundled
- Accidental taps < 0.5s are silently discarded
- Clipboard only saves/restores string content during paste

## Claude Code Knowledge Base

When you need to leverage Claude Code's advanced capabilities — hooks, custom agents, skills, permission patterns, multi-agent orchestration, or SDK usage — reference the central learnings at:

- **Architecture & capabilities (99 flags, 41 tools, 27 hooks, 100+ env vars):** `/Users/dannygross/CodingProjects/Claude Code codebase/learnings/CLAUDE_CODE_DEEP_DIVE.md`
- **Hook recipes & reference (all 27 events with I/O schemas):** `/Users/dannygross/CodingProjects/Claude Code codebase/learnings/HOOKS_REFERENCE.md`
- **Custom skill templates (8 production skills):** `/Users/dannygross/CodingProjects/Claude Code codebase/learnings/skills/`
- **Full Claude Code source:** `/Users/dannygross/CodingProjects/Claude Code codebase/src/`

Read these when the task involves configuring hooks, building skills, defining custom agents, optimizing permissions, setting up multi-agent workflows, or leveraging any Claude Code feature beyond basic usage. The source code is the definitive reference for how any feature actually works.

**Voice-dictation-specific patterns in the CC source:**
- **Subprocess management:** `src/utils/ShellCommand.ts` — StreamWrapper + TaskOutput + size watchdog for whisper-cpp subprocess
- **Status state machine:** `src/components/Spinner.tsx` — multi-mode states with minimum display duration; model for recording → transcribing → idle
- **Atomic file ops:** `src/utils/file.ts` — temp + pid + timestamp + rename for transcription history
- **Input sanitization:** `src/tools/BashTool/bashSecurity.ts` — concepts for sanitizing whisper-cpp arguments
- **Keyboard shortcuts:** `src/keybindings/` — context-aware chord resolution; model for hotkey management
- **Full pattern map:** `learnings/PROJECT_PATTERNS_MAP.md`
