# VoiceDictation

## Project Overview
A native macOS menu bar app for push-to-talk dictation. Hold the hotkey, speak, let go: the words paste into the app in front. The speech becomes text on the Mac, with whisper.cpp built into the app (base.en by default), and Apple Intelligence's on-device model can tidy the text before it pastes. Nothing leaves the machine except a speech model Danny chooses to download.

The repo folder is `voice-dictation/` on the Mac mini and `Voice Dictation/` on the laptop. Write paths with `~/`, never `/Users/<name>/`: the two Macs have different user names.

## Owner
Danny (daniel.gross85@gmail.com) — personal use, MacMini.

## Tech Stack
- macOS 26 or later; the Swift 6 toolchain in Swift 5 language mode
- Swift Package Manager holds all the code; XcodeGen (`project.yml`) makes the thin app target in `App/`
- SwiftUI and AppKit, AVFoundation, SwiftData, Speech (`SpeechAnalyzer`), FoundationModels (`SystemLanguageModel`)
- whisper.cpp v1.9.5, upstream's XCFramework (release b5454) pinned by checksum in `Package.swift`; WhisperKit 1.1.1 (Argmax)

## Key Commands
```bash
./scripts/run-dev.sh                                  # Builds the app into .build/xcode and opens it; needs Xcode and XcodeGen (brew install xcodegen)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # Runs the tests; xcode-select points at Command Line Tools, which has no XCTest
./scripts/release.sh                                  # Signed, notarised zip in dist/; one-time setup in docs/release.md
tail -f ~/Library/Logs/VoiceDictation.log             # Watch the app log
```

## Architecture
```
App/VoiceDictationApp (scenes only) → AppLifecycle → AppModel
  → DictationPipeline: hotkey → recorder → engine → replacements → cleanup → paste
      HotkeyManager + ModifierKeyStrategy    event tap: Globe, Right Option or Right Command
      AudioRecorder                          AVAudioEngine, 16 kHz mono; prepared while idle, never started
      TranscriptionService                   one dictation at a time, always ahead of re-transcriptions
        → WhisperCppEngine                   the default: whisper.cpp in this process; GGMLDownload fetches its models
        → AppleSpeechEngine                  SpeechAnalyzer: Apple Speech and Apple Dictation
        → WhisperKitEngine                   Whisper on Core ML
      OutputFilter + Replacements            drops silence hallucinations; Danny's rules (VocabularyStore)
      FoundationModelCleaner + CleanupGuard  on-device cleanup; the raw text on any doubt
      PasteEngine                            clipboard + tagged Cmd+V, the clipboard put back after
  → TranscriptStore (SwiftData) + AudioArchive (kept recordings); HistoryImporter brings in the old history.json
  → MenuBarContent, the main window (LibraryModel; Models, Vocabulary, Settings), Welcome (OnboardingModel), IndicatorPanel
  → Log (~/Library/Logs/VoiceDictation.log)
```

## Key Files
- `Sources/VoiceDictationLib/`: the pipeline, the engines and the store; `Sources/VoiceDictationUI/`: `AppModel` and the SwiftUI views; `App/`: the app target
- `Sources/VDBench/`: `vd-bench`, which compares every ready model on the kept recordings
- `DESIGN.md`: the Prism look, authoritative for anything on screen
- `docs/superpowers/`: the native app's plan, spec and builder notes
- `docs/release.md`: signing and notarising a release
- `docs/feature-requests.md`: Danny's backlog of ideas not yet planned

## Known Constraints
- macOS 26 or later, English only
- Cleanup needs Apple Intelligence switched on; without it the raw text pastes. Use only `SystemLanguageModel.default`, never the cloud model (`PrivateCloudComputeLanguageModel`), which sends text off the Mac
- Never start the microphone's engine while idle. Preparing it is fine; starting it lights the orange mic indicator
- whisper.cpp is pinned at v1.9.5. Its golden tests (`WhisperCppEngineTests`) check that it gives whisper-cli's text exactly. A bump must keep them passing. To record new golden text on purpose, restore `WhisperCLIGoldenRecorder.swift` and the whisper-cli engine from commit `a604041`, and run Homebrew's whisper-cli at the target version
- The ggml models live in `~/Library/Application Support/VoiceDictation/models/`. They download only when Danny presses Download, and only a file matching the catalog's size and SHA-256 (`GGMLModel`) is kept
- Globe as the hotkey needs "Press Globe key to: Do Nothing" in System Settings
- Taps under 0.5 s and near-silent recordings (peak < 0.01) are discarded; a recording stops at 5 minutes or on an audio device change
- Whole-transcript whisper hallucinations ("you", "Thank you.") are dropped (`OutputFilter`)
- The clipboard is snapshotted and put back after a paste, unless something new was copied meanwhile
- The event tap heals itself: a 15 s health check and a wake notification (`HotkeyManager`)
- Menu bar SF Symbols fall back to `mic.fill`, so the icon never blanks (`MenuBarLabel.symbolName`)
- `xcode-select` points at the Command Line Tools, so prefix `swift` and `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

## Codex Knowledge Base

When you need to leverage Codex's advanced capabilities — hooks, custom agents, skills, permission patterns, multi-agent orchestration, or SDK usage — reference the central learnings, on the Mac mini, at:

- **Architecture & capabilities (99 flags, 41 tools, 27 hooks, 100+ env vars):** `~/CodingProjects/Codex codebase/learnings/CLAUDE_CODE_DEEP_DIVE.md`
- **Hook recipes & reference (all 27 events with I/O schemas):** `~/CodingProjects/Codex codebase/learnings/HOOKS_REFERENCE.md`
- **Custom skill templates (8 production skills):** `~/CodingProjects/Codex codebase/learnings/skills/`
- **Full Codex source:** `~/CodingProjects/Codex codebase/src/`

Read these when the task involves configuring hooks, building skills, defining custom agents, optimizing permissions, setting up multi-agent workflows, or leveraging any Codex feature beyond basic usage. The source code is the definitive reference for how any feature actually works.

**Voice-dictation-specific patterns in the CC source:**
- **Status state machine:** `src/components/Spinner.tsx` — multi-mode states with minimum display duration; model for recording → transcribing → idle
- **Atomic file ops:** `src/utils/file.ts` — temp + pid + timestamp + rename; the app writes `vocabulary.json` atomically and lands each model download as a `.partial` file before renaming it
- **Keyboard shortcuts:** `src/keybindings/` — context-aware chord resolution; model for hotkey management
- **Full pattern map:** `learnings/PROJECT_PATTERNS_MAP.md`
