# VoiceDictation Native App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Execution method is the builder's choice.** Danny has left it to you: read the whole plan first, then pick one and say which and why in the notes file. The plan's author leaned towards a subagent per task (27 tasks sharing interfaces; permissions, audio and signing mistakes are expensive to find late), but that is a suggestion, not an instruction.

**Goal:** Turn VoiceDictation from a menu bar wrapper around `whisper-cli` into a signed native macOS app with in-process speech engines, a transcript library window in the Prism look, switchable models, and on-device transcript cleanup.

**Architecture:** One pipeline (`Hotkey → Recorder → Engine → Replacements → Cleaner → Paste`, with a `TranscriptStore` alongside) where every stage sits behind a small protocol. All logic stays in the Swift package (`VoiceDictationLib` for the pipeline, `VoiceDictationUI` for SwiftUI views) so `swift build` and `swift test` keep working; a thin XcodeGen app target only hosts the SwiftUI `App`. The old `whisper-cli` path stays one engine among the others until Danny picks a default from measurements. He picked whisper with base.en (D2), so whisper.cpp moves inside the app (Task 27) and the `whisper-cli` path is deleted (Task 27A).

**Tech Stack:** Swift 6.4 toolchain (Swift 5 language mode), SwiftPM, XcodeGen 2.46, SwiftUI + AppKit, AVFoundation, Speech (`SpeechAnalyzer` with `SpeechTranscriber` and `DictationTranscriber`), FoundationModels (`SystemLanguageModel`), WhisperKit (Argmax; SwiftPM package `argmax-oss-swift`, product `WhisperKit`), whisper.cpp v1.9.5 (upstream's XCFramework as a SwiftPM binary target), SwiftData, Sparkle, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-11-native-app-design.md`. Read it first; this plan argues from it. Approved mockups and the indicator prototype are on this laptop only (not in git) in `.superpowers/brainstorm/30815-1794455251/content/` (`main-window-six-directions.html` option D, `prism-live-line-fluid.html`).

**Revised 2026-11-12, after D2:** Danny chose the default engine: whisper (whisper.cpp) with base.en, built into the app with no Homebrew and no subprocess, and no ♪ filter. Task 27 now puts whisper.cpp inside the app and proves it matches whisper-cli word for word. New Task 27A makes it the default and retires whisper-cli, its scripts and the old downloader. Task 26's icon is Danny's own design (D7, pending his sign-off of a preview). New Task 28, a simplified view, starts with a design session (D11). Run order: 23, 24, 24A, 25, 27, 27A, 26, then 28 once its design is approved. The build stops before 28. Task 23 changed during review at Danny's request: a double tap also ends double-tap dictation, and the feature is named "Double-tap to dictate". Task 24's Settings row follows. D4 is done.

**Revised 2026-11-12:** Task 24A (a smoother live volume line) was added after Danny's first hands-on use. It runs after Task 24.

**Revised 2026-11-11 after review.** Danny decided three things: a dictation always goes ahead of a re-transcription (Global Constraints; Tasks 3, 5–8); a dictation skipped because three were already waiting is kept as Failed with its audio (Review Focus 4; Tasks 9, 19); cleanup leaves false starts in, a deliberate departure from the spec (Task 21). Also changed after checking the code and the libraries: the cleanup guard's rule (Task 21), WhisperKit's package, storage and network use (Task 7), and keeping the agent docs true during the build (Tasks 1, 13).

A second pass the same day: Apple Dictation (`DictationTranscriber`) joins the comparison as a second Apple model (Tasks 3, 6, 20); the four WhisperKit models are named by folder, and `.preparing` can come back after macOS updates (Task 7); D1 still works after Task 24 removes the comparison switch (D1, Task 24); a cleanup result that arrives after the paste now reaches the store (Task 21); a corrupt store is moved aside together with its `-wal` and `-shm` files (Task 11); the README is kept current from Task 13; and the plan and spec are committed on branch `native-app` before Task 1 starts (Task 1).

## Notes for the builder (read before Task 1)

You are picking this up cold. These are the things that are easy to get wrong.

1. **Never guess an Apple API.** `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory` and FoundationModels are newer than most training data. The installed SDK is the authority. Read the interface before writing a call:
   - `SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks`
   - `$SDK/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`
   - `$SDK/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`
   Confirmed present on this machine (Xcode 27.0, macOS 27 SDK): `SpeechAnalyzer(modules:options:)`, `prepareToAnalyze(in:)`, `analyzeSequence(_:)`, `finalizeAndFinishThroughEndOfInput()`, `setContext(_:)`, `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`, `SpeechAnalyzer.Options(priority:modelRetention:)` with `.processLifetime`; `SpeechTranscriber(locale:preset:)` with `.transcription`, `results` (async sequence of `Result` whose `text` is an `AttributedString`), `SpeechTranscriber.supportedLocale(equivalentTo:)`; `DictationTranscriber(locale:contentHints:transcriptionOptions:reportingOptions:attributeOptions:)` with `TranscriptionOption.punctuation`, presets such as `.shortDictation` and `.longDictation`, and the same `results`/`Result.text` shape as `SpeechTranscriber`; `AnalysisContext().contextualStrings[.general]`; `AssetInventory.status(forModules:)` and `assetInstallationRequest(supporting:)` → `downloadAndInstall()` with `progress`; `AnalyzerInput(buffer:)`. FoundationModels: `SystemLanguageModel.default`, `.availability` (`.available` / `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`), `LanguageModelSession(model:tools:instructions:)`, `prewarm(promptPrefix:)`, `respond(to:options:)` returning a response with `.content: String`, `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)`.
2. **Never use `PrivateCloudComputeLanguageModel`.** It exists in the same framework and sends text off the machine. Only `SystemLanguageModel.default`. Task 21 has a test that greps the sources for it.
3. **Third-party APIs (WhisperKit, Sparkle, whisper.cpp):** resolve the latest stable release, pin it with `exact:`, and read that version's README and public interface before calling it. Do not write calls from memory. whisper.cpp is pinned on purpose: it stays at v1.9.5, the version of the whisper-cli Danny chose (D2), until Task 27's golden text is recorded again. Read v1.9.5's `include/whisper.h` and `examples/cli/cli.cpp` before calling it.
4. **Running tests on this laptop:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Plain `swift test` fails with "no such module 'XCTest'" because the shell points at Command Line Tools. Use the same prefix for `swift build` and `xcodebuild`. Baseline today: 34 tests, 0 failures.
5. **Launching the app:** always in the background (`nohup … >/dev/null 2>&1 &` or `open`). A foreground launch from the terminal makes the terminal the paste target. Log: `tail -f ~/Library/Logs/VoiceDictation.log`.
6. **Never leave the microphone running.** Pre-warming means allocating and preparing the audio engine, not starting it. A started `AVAudioEngine` input lights the orange mic indicator permanently.
7. **Two Macs, two usernames** (`danny` here, `dannygross` on the Mac mini). No `/Users/<name>` in code, scripts, or config. Use `~`, `FileManager` URLs, or `$HOME`.
8. **Git:** work on branch `native-app`. One-line commit messages under 72 characters. Never push, never commit `.env`, recordings, or anything under `~/Library`. Commit after every task.
9. **When to stop and leave a note instead of pushing on:** anything in "Needs Danny" below; a verified SDK fact that contradicts this plan in a way that changes behaviour Danny would see; any test you would have to delete or weaken to pass. Write the note at the top of `docs/superpowers/plans/2026-11-11-native-app-notes.md` and continue with tasks that do not depend on it.
10. **Report honestly.** If something could not be verified by hand (permissions, paste into another app, audio hardware), say so in the notes file. Do not mark a hands-on check as done.

## Needs Danny (cannot be done by the builder)

| # | What | Blocks |
|---|---|---|
| D1 | Record at least 20 normal dictations, including technical words. Until Task 24 lands, turn on "Keep recordings for comparison" (Task 2); after it, just dictate: the newest 50 recordings are kept (Task 12) and `vd-bench --from-archive` reads them | Task 10 report, default-engine decision |
| D2 | Decided 2026-11-12: the default engine is whisper (whisper.cpp) with base.en, chosen over Apple Speech and WhisperKit after a clip-by-clip read of the comparison (best on technical words; Apple Speech ignores the custom vocabulary). Built into the app; no ♪ filter | Nothing; Tasks 27 and 27A carry it out |
| D3 | Confirm Apple Intelligence is switched on (both Macs) | Cleanup actually running (Task 21 degrades gracefully without it) |
| D4 | Done 2026-11-12: a "Developer ID Application" certificate for team F7DL4CTLLL is in this laptop's keychain, and the notarytool profile `voicedictation-notary` is saved and validated by Apple | Nothing |
| D5 | Grant Microphone and Accessibility to the new app bundle once (the old grants belonged to the dev binary) | Hands-on checks from Task 13 on |
| D6 | Nothing to confirm about the OS: the Mac mini runs macOS 27. It keeps running the current app from `main` until Danny installs a release there | — |
| D7 | Decided 2026-11-12: the icon is Danny's design, a microphone drawn as an outline whose stroke is the spectrum, on black (Task 26 Step 1). Left: sign off the preview `docs/icon-preview.png`, or say what to change | The icon's final form only; the rest of Task 26 goes on |
| D11 | A design session for the simplified view: brainstorm, then mockups to approve | Task 28 |


Nothing else waits on Danny, and nothing needs Homebrew's whisper any more: whisper.cpp is inside the app from Task 27, and Task 27A removes whisper-cli. Task 27 runs this laptop's whisper-cli once, to record the text the new engine must match.

## Global Constraints

- Minimum macOS 26. English only (`en-US`).
- Nothing leaves the machine. The only permitted network use is downloading a speech model the user chose, and an update check the user started by hand (Task 26). No background network activity of any kind. Building may fetch packages, whisper.cpp's XCFramework among them (pinned by checksum); the app itself never does.
- Cleanup does exactly three things: removes filler words, fixes punctuation, fixes capitalisation. It never adds or changes a word. On any doubt, error, or delay, the raw text is used.
- Dictation never depends on the window being open and the app never takes focus from the app being dictated into.
- Time from key release to paste for an ordinary sentence with cleanup off must not be slower than today's (measured in Task 2). With cleanup on, it may add at most the 2.0 s limit.
- A dictation never waits for a re-transcription. Re-transcriptions run one at a time and only while no dictation is being transcribed; a dictation that arrives during one stops it, and the re-transcription starts again by itself once the dictation is done.
- Escape leaves no trace: a cancelled dictation produces no transcript and keeps no audio. A failed one is kept with its audio. So is a dictation skipped because three were already waiting: it is not pasted, and it is saved as Failed with the reason "Skipped: too many dictations waiting".
- A transcript's main `text` starts as what was actually pasted. Danny can edit it in the window; `rawText` and `cleanedText` are never changed by an edit.
- Bundle identifier stays `com.danny.VoiceDictation`. Data stays under `~/Library/Application Support/VoiceDictation/`.
- Kept behaviour: discard recordings under 0.5 s; discard recordings whose peak is under 0.01; stop at 300 s; stop on audio device change; drop whole-transcript hallucinations (`OutputFilter.silenceHallucinations`; Task 5 moved the list there from `Transcriber`, which Task 27A deletes); full clipboard snapshot and restore; event-tap self-healing.
- Look: Prism. Colours `bg #000000`, `bg-elevated #0A0A0A`, `text #F2F2F2`, `text-muted #8C8C8C`, `hairline #2A2A2A`; spectrum `#FF2D1F, #FF8A00, #FFE600, #27D14B, #1E8BFF, #7B3DFF` used exactly once per screen (the 2px underline under the selected transcript row) and never in the floating indicator. The app icon (Task 26) is its one use outside the window: a microphone outline in the six bands, on black; the icon's rounded square is macOS's icon shape, not a Prism radius. Radius 0, no shadows, no glows. Fonts: Jost (one title per screen), Work Sans (interface), DM Mono (times and figures). Status is words, never colour.
- Live text while speaking, per-app behaviour, other languages and the App Store are out of scope. Do not build toward them.

## Review Focus

The spec is silent on these; each is pinned by a test in the task named.

1. **The model is not ready when the key goes down** (still loading, compiling, or downloading). Expected: recording proceeds. A model still loading or compiling produces the transcript when it is ready. A model still downloading refuses at once: the dictation is not pasted but saved as Failed with its audio, and the refusal reads "<model> is still downloading. This recording is kept: re-transcribe it from the window when it's ready." If the model fails, the transcript is saved as Failed with its audio so it can be re-transcribed. → Task 9 (the refusal's words: the final fix wave, E2).
2. **The audio device changes between pre-warm and key-down** (AirPods connect). Expected: the recorder rebuilds itself and records real audio, never silence. → Task 4.
3. **Cleanup misbehaves**: adds a word, returns an explanation instead of the text, refuses, errors, or exceeds its time limit. Expected: raw text is pasted, the transcript is saved, no error is shown. → Task 21.
4. **Several dictations in quick succession, or one during a re-transcription.** Expected: they are transcribed in order with at most 3 waiting; when another arrives while 3 are waiting, the oldest waiting one is not pasted but saved as Failed with its audio (today it is silently deleted); each is pasted at most once and every one reaches the store; a dictation never waits for a re-transcription. → Task 8, Task 9.
5. **The store cannot be opened** (corrupt file, schema mismatch). Expected: dictation still works with history unavailable, the bad file is moved aside (not deleted), and the window says so. → Task 11.
6. **whisper.cpp inside the app must say exactly what whisper-cli said** (Danny chose the default from whisper-cli's text). Expected: for the same audio and vocabulary, the same characters. That means the same ggml weights, cli.cpp's decoding settings, the 16-bit samples whisper-cli read from its WAV, and the segments joined as it printed them. A second clip in the same process decodes like a fresh run. Where the ggml version alone makes a clip differ, Danny accepted it (2026-11-12); the notes list each difference. → Task 27.

## File Structure

```
Package.swift                              tools 6.2, macOS 26, WhisperKit dep, whisper.cpp XCFramework (binary target), new targets
project.yml                                XcodeGen: app target only
App/VoiceDictationApp.swift                @main SwiftUI App (scenes only, no logic)
App/Info.plist, App/VoiceDictation.entitlements
App/Assets.xcassets/AppIcon.appiconset/    the icon, drawn by scripts/make-icon.swift (Task 26)
DESIGN.md                                  Prism tokens (authoritative)
Sources/ObjCHelpers/                       unchanged
Sources/VoiceDictationLib/
  Core/        ModelID.swift, AudioClip.swift, AudioClip+File.swift, StageTimer.swift
  Engine/      TranscriptionEngine.swift, AppleSpeechEngine.swift, WhisperKitEngine.swift,
               WhisperCppEngine.swift, GGMLModel.swift, GGMLDownload.swift,
               TranscriptionService.swift, OutputFilter.swift
  Cleanup/     TextCleaner.swift, CleanupGuard.swift, FoundationModelCleaner.swift
  Text/        Vocabulary.swift, Replacements.swift
  Store/       Transcript.swift, TranscriptStore.swift, HistoryImporter.swift, AudioArchive.swift
  Pipeline/    DictationPipeline.swift, DictationState.swift
  (existing)   AudioRecorder, HotkeyManager, PasteEngine, PermissionManager, PreferencesManager,
               LoginItemManager, SingleInstanceGuard, Log   — modified in place
  (deleted by the end) AppDelegate, StatusManager, PreferencesWindowController, Transcriber,
               BundledBinary, ModelManager, TranscriptionHistory, WhisperRun, Engine/WhisperCLIEngine
Sources/VoiceDictationUI/
  Theme.swift, Fonts.swift, Resources/Fonts/*.ttf
  Indicator/   LevelLine.swift, IndicatorView.swift, IndicatorPanel.swift
  Window/      MainWindow.swift, Sidebar.swift, TranscriptList.swift, TranscriptDetail.swift,
               ComparisonView.swift, ModelsView.swift, VocabularyView.swift, SettingsView.swift
  MenuBar/     MenuBarContent.swift
  Onboarding/  OnboardingView.swift
Sources/VDBench/main.swift                 engine comparison tool
Tests/VoiceDictationTests/                 existing + one file per new unit; Resources/golden/ holds
                                           whisper-cli's text for Task 27's golden test
Tests/VoiceDictationUITests/               LevelLineTests, ThemeTests
scripts/run-dev.sh, scripts/release.sh, scripts/make-icon.swift (Task 26)
                                           (bundle-whisper.sh, create-package.sh, install.sh deleted in Task 27A)
```

Names used across tasks are defined in the task that creates them and listed in its **Produces** block. If a later task needs something not listed, add it to the owning file rather than inventing a parallel type.

---

## Phase 0: Baseline

### Task 1: Branch, commit the pending work, fix the test note

**Files:** Modify `CLAUDE.md` and `AGENTS.md` (the "Known Constraints" line about XCTest and the `swift test` comment under Key Commands).

- [ ] **Step 1:** `git switch native-app` (the branch this plan was committed on; use `git switch -c native-app` if it does not exist).
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: `Executed 34 tests, with 0 failures`.
- [ ] **Step 3:** In `CLAUDE.md`, replace the claim that tests cannot run on the laptop with the working command from Step 2 and the reason (Xcode is installed; `xcode-select` points at Command Line Tools). Make the same change in `AGENTS.md`, which is a copy of `CLAUDE.md` for Codex (only its knowledge-base section differs); keep the two in step for the rest of the build.
- [ ] **Step 4:** Add `.superpowers/` to `.gitignore`.
- [ ] **Step 5:** Commit everything currently modified or untracked (`AGENTS.md`, `Log.swift`, `PasteEngineTests.swift` and the 13 modified files; the plan and the spec are already committed): `git add -A && git commit -m "chore: commit reliability hardening"`.

### Task 2: Stage timings and comparison recordings

**Files:** Create `Sources/VoiceDictationLib/Core/StageTimer.swift`, `Tests/VoiceDictationTests/StageTimerTests.swift`. Modify `AppDelegate.swift`, `AudioRecorder.swift`, `PreferencesManager.swift`, `StatusManager.swift`.

**Produces:**
- `public struct StageTimer { public mutating func mark(_ stage: Stage, at: Date = Date()); public func milliseconds(from: Stage, to: Stage) -> Int?; public var summary: String }` with `enum Stage { keyDown, firstAudio, keyUp, textReady, cleaned, pasted }`.
- `PreferencesManager.shared.keepComparisonRecordings: Bool` (default false).
- Directory `~/Library/Application Support/VoiceDictation/comparison/` holding `<unix-time>.wav` plus `<unix-time>.txt` (what the current engine produced).

- [ ] **Step 1: Failing tests.** `testMillisecondsBetweenMarks` (marks 250 ms apart → 250), `testMissingStageReturnsNil`, `testSummaryFormat` asserting the exact string `"keyDown→firstAudio=120ms keyUp→text=800ms text→pasted=15ms"` for those intervals.
- [ ] **Step 2:** Run them; expect failure (type missing).
- [ ] **Step 3:** Implement `StageTimer`. Mark `firstAudio` from the first tap callback in `AudioRecorder`. After each paste, log one line `[TIMING] <summary>`.
- [ ] **Step 4:** Add the preference and a menu item "Keep recordings for comparison" (checkmark toggle). When on, copy the WAV and write the transcript text before the WAV is deleted.
- [ ] **Step 5:** Tests pass. Build, launch in background, dictate once, confirm a `[TIMING]` line in the log. If the microphone cannot be exercised in this session, record that in the notes file.
- [ ] **Step 6:** Write the three numbers from a few real dictations into `docs/baseline-timings.md` (or note that Danny must supply them). Commit: `feat: stage timings and comparison recordings`.

---

## Phase 1: Engines

### Task 3: Package floor and core types

**Files:** Modify `Package.swift`. Create `Core/ModelID.swift`, `Core/AudioClip.swift`, `Engine/TranscriptionEngine.swift`, `Tests/VoiceDictationTests/Fakes.swift`, `Tests/VoiceDictationTests/CoreTypesTests.swift`.

**Produces:**
```swift
public enum EngineKind: String, Codable, Sendable, CaseIterable { case appleSpeech, whisperKit, whisperCLI }
public struct ModelID: Hashable, Codable, Sendable {
    public let engine: EngineKind; public let name: String
    public var storageKey: String            // "appleSpeech/en-US"
    public init?(storageKey: String)
    public static let appleSpeech = ModelID(engine: .appleSpeech, name: "en-US")                 // SpeechTranscriber
    public static let appleDictation = ModelID(engine: .appleSpeech, name: "en-US-dictation")    // DictationTranscriber (Task 6)
}
public struct ModelDescriptor: Sendable, Identifiable {
    public let id: ModelID; public let displayName: String; public let detail: String
    public enum State: Sendable, Equatable { case ready, notDownloaded, downloading(Double), preparing, unavailable(String) }
    public var state: State; public var bytesOnDisk: Int64?
}
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate: Double = 16_000
    public let samples: [Float]              // mono, -1...1
    public var duration: TimeInterval; public var peak: Float
}
public enum TranscriptionError: Error, Equatable { case modelNotReady(String), engineUnavailable(String), cancelled, failed(String) }
public protocol TranscriptionEngine: Sendable {
    var kind: EngineKind { get }
    func models() async -> [ModelDescriptor]
    func prepare(_ model: ModelID) async throws                 // load and keep warm
    func transcribe(_ clip: AudioClip, model: ModelID, vocabulary: [String]) async throws -> String   // stops promptly and throws CancellationError when its task is cancelled
    func download(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ model: ModelID) async throws
    func unload() async
}
```
`Fakes.swift`: `final class FakeEngine: TranscriptionEngine` with settable `result`, `delay`, `prepareDelay`, `prepareError`, a recorded call list, `cancelledCount` (calls cancelled during their `delay`), and an optional shared `ConcurrencyProbe` whose `maxRunning` is the most `transcribe` calls ever running at once across the fakes that share it.

- [ ] **Step 1:** `Package.swift`: `// swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v5]`. Add `Core/…` subfolders (SwiftPM picks them up). Build and run the 34+3 existing tests; fix any deprecation errors the new floor exposes (for example the `#available(macOS 13.0, *)` guards in `LoginItemManager` become unnecessary).
- [ ] **Step 2: Failing tests.** `testStorageKeyRoundTrip` (`ModelID(engine: .whisperKit, name: "large-v3-turbo").storageKey == "whisperKit/large-v3-turbo"` and back), `testStorageKeyRejectsGarbage` (`ModelID(storageKey: "nope") == nil`), `testClipDurationAndPeak` (16 000 samples with one value of 0.5 → duration 1.0, peak 0.5).
- [ ] **Step 3:** Implement. Tests pass. Commit: `feat: core engine types and macOS 26 floor`.

### Task 4: In-memory recording with pre-warm and levels

**Files:** Modify `AudioRecorder.swift`, `AppDelegate.swift`. Create `Core/AudioClip+File.swift`, `Tests/VoiceDictationTests/AudioClipFileTests.swift`, `Tests/VoiceDictationTests/AudioRecorderLogicTests.swift`.

**Produces:**
- `AudioRecorderDelegate.recordingDidFinish(clip: AudioClip)` (replaces `fileURL:duration:`).
- `AudioRecorder.prepare()` (allocate engine + converter, do not start), `AudioRecorder.onLevel: ((Float) -> Void)?` (peak of each converted buffer, delivered on the main queue), `AudioRecorder.inputDeviceUID: String?` (nil = system default; used by Task 24).
- `extension AudioClip { init(contentsOf url: URL) throws; func writeWAV(to: URL) throws; func writeALAC(to: URL) throws }` (any readable audio file → 16 kHz mono float).
- `enum RecordingVerdict { case keep, tooShort, silent }` and `static func AudioRecorder.verdict(duration: TimeInterval, peak: Float) -> RecordingVerdict`.

- [ ] **Step 1: Failing tests.** `testVerdictTooShort` (0.49 s → `.tooShort`), `testVerdictSilent` (2 s, peak 0.009 → `.silent`), `testVerdictKeep` (0.5 s, peak 0.01 → `.keep`); `testWAVRoundTrip` (write a 1 s 440 Hz sine, read it back, sample count 16 000 ± 1, peak within 0.01); `testALACRoundTripIsLossless` (max sample difference < 1/32768); `testReads44kStereoAsMono16k` (generate a 44.1 kHz stereo file with `AVAudioFile`, load, duration within 10 ms).
- [ ] **Step 2:** Implement the file helpers and `verdict`. Tests pass.
- [ ] **Step 3:** Rewrite the capture path to append converted float samples to an array guarded by the existing lock; build the `AudioClip` on stop. Remove the temp-WAV writing from the recorder. Keep the ObjC exception catcher around `installTap`, the 300 s timer, and the configuration-change observer.
- [ ] **Step 4: Pre-warm.** `prepare()` builds the engine and converter for the current input format and is called at launch, after each recording finishes, and from an `AVAudioEngineConfigurationChange` / default-input-device-change observer. `startRecording()` compares the prepared format with `inputNode.outputFormat(forBus: 0)`; if they differ it rebuilds before installing the tap. **Review Focus 2 test:** extract that decision as `static func needsRebuild(prepared: AVAudioFormat?, current: AVAudioFormat) -> Bool` and test nil, same, different sample rate, different channel count.
- [ ] **Step 5:** Until Task 5 lands, bridge in `AppDelegate`: write the clip to a temp WAV and call the existing `Transcriber`. Comparison recordings (Task 2) now use `writeWAV`.
- [ ] **Step 6:** Build, launch, dictate; confirm the `[TIMING] keyDown→firstAudio` figure is not worse than Task 2's baseline and the orange mic indicator is off when idle. Commit: `feat: in-memory recording with pre-warm and level callback`.

### Task 5: The old engine behind the new protocol

**Files:** Create `Engine/WhisperCLIEngine.swift`, `Engine/OutputFilter.swift`, `Tests/VoiceDictationTests/OutputFilterTests.swift`. Modify `TranscriberTests.swift`.

**Produces:** `public enum OutputFilter { public static func clean(_ engineOutput: String) -> String }` (the timestamp stripping, non-speech-line dropping and whole-transcript hallucination filter moved out of `Transcriber.parseOutput`, applied to every engine's output). `public final class WhisperCLIEngine: TranscriptionEngine` whose models are the three existing `ggml-*.en.bin` files in `models/` and whose `transcribe` writes a temp WAV, runs `whisper-cli` with `Transcriber.arguments`, and deletes the WAV.

- [ ] **Step 1:** Move the parse tests to `OutputFilterTests` unchanged in substance; add `testHallucinationAppliesToAnyEngine` (`OutputFilter.clean(" Thank you. ") == ""`) and `testCancellationStopsProcess` (skips unless whisper-cli and a model are installed: transcribe 30 s of silence, cancel the task after 100 ms, expect `CancellationError` within 1 s). Run; expect failure.
- [ ] **Step 2:** Implement `OutputFilter`; make `Transcriber.parseOutput` call it. Implement `WhisperCLIEngine` by reusing `Transcriber`'s process code as an `async` function (use a continuation; keep the concurrent pipe draining and the timeout). Vocabulary is passed with whisper's `--prompt` argument, comma-joined. Wrap the run in `withTaskCancellationHandler` so that cancelling the task terminates the process and throws `CancellationError` (Task 8 depends on this).
- [ ] **Step 3:** Tests pass. Commit: `refactor: whisper-cli as a TranscriptionEngine`.

### Task 6: Apple Speech engine

**Files:** Create `Engine/AppleSpeechEngine.swift`, `Tests/VoiceDictationTests/AppleSpeechEngineTests.swift`, test resource `Tests/VoiceDictationTests/Resources/sample.wav`.

**Produces:** `public actor AppleSpeechEngine: TranscriptionEngine` with two models, so the comparison (Task 10) can weigh Apple's two speech modules: `ModelID.appleSpeech`, display name "Apple Speech" (`SpeechTranscriber`, Apple's newer general-purpose model), and `ModelID.appleDictation`, display name "Apple Dictation" (`DictationTranscriber`, the module behind macOS dictation, which has a punctuation option and dictation presets).

- [ ] **Step 1:** Create the sample: `say -o /tmp/s.aiff "The quick brown fox jumps over the lazy dog."` then convert to 16 kHz mono WAV with `afconvert -f WAVE -d LEI16@16000 -c 1`. Commit it as a test resource (declare `resources: [.copy("Resources")]` on the test target).
- [ ] **Step 2: Failing test.** `testTranscribesSample`, once per model: skip with `XCTSkip` unless the module supports en-US (`supportedLocale(equivalentTo:)` is non-nil; Apple Speech also needs `SpeechTranscriber.isAvailable`) and its asset status is `.installed`; otherwise assert the lowercased result contains `"quick brown fox"`. `testModelStateReflectsAssets`: `models()` returns exactly two descriptors, each `.ready`, `.notDownloaded`, or `.unavailable` (never crashes).
- [ ] **Step 3: Implement**, reading the swiftinterface first (Note 1). Shape:
  - `prepare`: resolve the locale with `SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))`; build `SpeechTranscriber(locale:preset: .transcription)`; check `AssetInventory.status(forModules:)` and throw `.modelNotReady("<display name> language files are not installed")` (for example "Apple Speech language files are not installed") unless `.installed`; create `SpeechAnalyzer(modules:options: .init(priority: .userInitiated, modelRetention: .processLifetime))`; call `prepareToAnalyze(in:)` with `bestAvailableAudioFormat(compatibleWith:)`.
  - `transcribe`: build a fresh transcriber + analyzer per clip if the SDK does not allow reusing an analyzer after `finalizeAndFinish…` (find out; `processLifetime` retention keeps the model warm either way). Convert the clip to the analyzer's format in one `AVAudioPCMBuffer`, feed it as a one-element `AsyncStream<AnalyzerInput>`, call `analyzeSequence` then `finalizeAndFinishThroughEndOfInput()`, and concurrently collect `transcriber.results`, joining `String(result.text.characters)`. When the task is cancelled, call `analyzer.cancelAndFinishNow()` (present in the SDK) and throw `CancellationError`.
  - Vocabulary: `let ctx = AnalysisContext(); ctx.contextualStrings[.general] = vocabulary; try await analyzer.setContext(ctx)`.
  - `download`: `AssetInventory.assetInstallationRequest(supporting:)` → observe `progress.fractionCompleted` → `downloadAndInstall()`. `delete` throws `.failed("Managed by macOS")`.
  - Apple Dictation runs the same pipeline with `DictationTranscriber(locale:contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [])` in place of the `SpeechTranscriber`; `prepare`, `download`, vocabulary and cancellation work the same way, since both are modules on one `SpeechAnalyzer`.
- [ ] **Step 4:** Run tests. If the assets are not installed the sample test skips; say so in the notes file, do not count it as passing. Commit: `feat: Apple Speech engine`.

### Task 7: WhisperKit engine

**Files:** Modify `Package.swift`. Create `Engine/WhisperKitEngine.swift`, `Tests/VoiceDictationTests/WhisperKitEngineTests.swift`.

**Produces:** `public actor WhisperKitEngine: TranscriptionEngine` with `public init(root: URL)` (the app passes `~/Library/Application Support/VoiceDictation/whisperkit/`) and `static func loadConfig(for model: ModelID, root: URL) -> WhisperKitConfig`. Models offered, as `ModelID` name → folder on `argmaxinc/whisperkit-coreml`: `tiny.en` → `openai_whisper-tiny.en`, `base.en` → `openai_whisper-base.en`, `small.en` → `openai_whisper-small.en`, `large-v3-turbo` → `openai_whisper-large-v3-v20240930`. That last folder is OpenAI's large-v3-turbo (4 decoder layers) and WhisperKit's own default for M2–M4 Macs (checked 2026-11-11). Do not use `openai_whisper-large-v3_turbo`: despite its name it is full large-v3, with 32 decoder layers. Models and their tokenizers are stored under `root` and nowhere else.

- [ ] **Step 1:** Add the WhisperKit package pinned `exact:` to its latest stable release. The repository has moved to `https://github.com/argmaxinc/argmax-oss-swift`; depend on its `WhisperKit` product only. On 2026-11-11 the latest stable release was v1.1.1 (2026-10-08); use a newer stable one if there is one. Read its README and public API at that version (Note 3). Record the version in the notes file and confirm the four folders above still exist.
- [ ] **Step 2: Failing tests.** `testOffersFourModels` (ids as above, each `.notDownloaded` or `.ready`); `testTranscribeWithoutDownloadThrowsModelNotReady`; `testTranscribesSampleWhenTinyIsPresent` (skips unless tiny.en is on disk; asserts `"quick brown fox"`, that a `tokenizer.json` exists under `root`, and that `~/Documents/huggingface` does not exist afterwards unless it existed before the test); `testLoadConfigStaysLocal` (`loadConfig(for:root:)` names the model, puts `downloadBase`, `tokenizerFolder` and `modelFolder` inside `root`, and sets `download` to false).
- [ ] **Step 3: Implement.** `download` reports real progress and leaves no partial folder behind on failure or cancellation. `prepare` loads the model and reports `.preparing` through `models()` while Core ML compiles it (a load can take a long time, and not only the first one: Core ML throws its compiled copy away after every macOS update and after long disuse, per WhisperKit's `prewarm` documentation in `Configurations.swift`, so report `.preparing` whenever `prepare` is running; it must never happen silently inside a dictation). Vocabulary goes in as the decoding prompt. English, no timestamps. `bytesOnDisk` from the model folder.
  - **Storage and network** (checked in v1.1.1's source on 2026-11-11). Left at its defaults, WhisperKit breaks the storage and privacy rules three ways. Its Hub client stores everything in `~/Documents/huggingface` (`ArgmaxCore/External/Hub/HubApi.swift`), and a non-sandboxed app touching `~/Documents` also gets a macOS permission prompt. It fetches a remote config whenever no model name is given (`WhisperKit.setupModels`). It downloads the tokenizer the first time a model loads, because the model folders on `argmaxinc/whisperkit-coreml` contain no `tokenizer.json` (`ModelUtilities.loadTokenizer`). So: `download` calls `WhisperKit.download(variant:downloadBase: root, progressCallback:)`, then fetches the tokenizer into `root` with `ModelUtilities.loadTokenizer(for:tokenizerFolder: root)` and the model's `ModelVariant` (public; `import WhisperKit` re-exports `ArgmaxCore`). `prepare` builds `WhisperKit(loadConfig(for:root:))`, which names the model, sets `downloadBase`, `tokenizerFolder` and `modelFolder` under `root`, and sets `download: false`. Once a model is downloaded, loading it never touches the network.
  - **Cancellation** needs no extra code: WhisperKit calls `Task.checkCancellation()` before every decoder step (`TextDecoder.swift`), so a cancelled task stops within one token.
- [ ] **Step 4:** Download tiny.en once by running the skipped test locally with the model present, to prove the path end to end. Commit: `feat: WhisperKit engine`.

### Task 8: TranscriptionService

**Files:** Create `Engine/TranscriptionService.swift`, `Tests/VoiceDictationTests/TranscriptionServiceTests.swift`. Modify `PreferencesManager.swift`.

**Produces:**
```swift
public struct TranscriptionResult: Sendable, Equatable { public let text: String; public let model: ModelID; public let elapsed: TimeInterval }
public actor TranscriptionService {
    public init(engines: [TranscriptionEngine], selected: ModelID, idleUnloadDelay: TimeInterval = 60)
    public var selected: ModelID { get }
    public func allModels() async -> [ModelDescriptor]
    public func select(_ id: ModelID) async throws          // prepares the new model, then unloads the old engine if different
    public func prepareSelected() async                     // called at launch; errors are kept, not thrown
    public func transcribe(_ clip: AudioClip, vocabulary: [String]) async throws -> TranscriptionResult   // dictation: selected model, one at a time, never waits for a re-transcription
    public func transcribe(_ clip: AudioClip, with id: ModelID, vocabulary: [String]) async throws -> TranscriptionResult  // re-transcription: does not change selection; yields to dictations (see Two lanes)
    public func download(_ id: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws
    public func delete(_ id: ModelID) async throws          // refuses the selected model
}
```
`PreferencesManager.shared.selectedModelID: ModelID` (default `.appleSpeech`; migrates the old `selectedModel` string `"base.en"` → `ModelID(engine: .whisperCLI, name: "base.en")` so the app keeps working on first run if Apple assets are missing).

**Two lanes.** Dictations run one at a time, in call order. Re-transcriptions run one at a time, in call order, and only while no dictation is running or waiting. If a dictation arrives while a re-transcription is transcribing, the service cancels that task, waits for it to stop (engines stop promptly; see Task 3's protocol), runs the dictation, then runs the re-transcription again from the start; its caller just waits longer and never sees the cancellation. A dictation never waits for a model that is loading only for a re-transcription. A model loaded only for re-transcriptions is unloaded `idleUnloadDelay` seconds after the re-transcription lane empties, unless it is the selected model (the delay keeps it loaded across back-to-back re-transcriptions and `vd-bench` runs).

- [ ] **Step 1: Failing tests** with `FakeEngine`: `testResultCarriesModelAndElapsed`; `testOutputFilterApplied` (fake returns `"Thank you."` → text `""`); `testSerialOrder` (three concurrent calls complete in call order — **Review Focus 4**); `testWaitsForPrepareInFlight` (transcribe called while `prepare` is sleeping 200 ms succeeds after it — **Review Focus 1**); `testPrepareFailureSurfacesAsModelNotReady`; `testSelectLoadsNewBeforeUnloadingOld` (call order recorded by the fakes); `testDeleteSelectedRefused`; `testRetranscribeDoesNotChangeSelection`. For the two lanes (**Review Focus 4**): `testDictationPreemptsRetranscription` (a re-transcription on a WhisperKit fake with a 2 s `delay`; a dictation on the selected Apple Speech fake with a 50 ms `delay`, issued 100 ms later, returns within 0.5 s; the WhisperKit fake's `cancelledCount == 1`; the re-transcription still returns its result); `testRetranscriptionWaitsForQueuedDictations` (three dictations queued, then a re-transcription: it starts only after the third dictation returns); `testDictationDoesNotWaitForRetranscriptionLoad` (the re-transcription's model has a 2 s `prepareDelay`; a dictation on the ready selected model returns within 0.5 s); `testNeverTwoTranscriptionsAtOnce` (a shared `ConcurrencyProbe` reports `maxRunning == 1` across the cases above); `testRetranscriptionOnlyModelUnloadedAfterIdleDelay` (with `idleUnloadDelay` 0.1 s it is unloaded after the delay and not before; the selected model is never unloaded).
- [ ] **Step 2:** Implement. Tests pass. Commit: `feat: TranscriptionService with warm model and serial queue`.

### Task 9: DictationPipeline replaces the AppDelegate wiring

**Files:** Create `Pipeline/DictationState.swift`, `Pipeline/DictationPipeline.swift`, `Tests/VoiceDictationTests/DictationPipelineTests.swift`. Modify `AppDelegate.swift`, `StatusManager.swift`, `HotkeyManager.swift`, `PasteEngine.swift`. Delete `Transcriber`'s queue code if now unused.

**Produces:**
```swift
public enum DictationState: Equatable, Sendable {
    case idle, recording(since: Date), transcribing, cleaning
    case preparingModel(String), needsPermission(String), error(String)
}
public struct DictationOutcome: Sendable {            // one per finished dictation; Task 11 stores these
    public enum Status: String, Codable, Sendable { case pasted, copied, failed }   // cancelled dictations produce no outcome
    public let id: UUID; public let date: Date; public let clip: AudioClip?
    public let rawText: String; public let cleanedText: String?; public var text: String  // what was pasted
    public let model: ModelID; public let transcribeSeconds: Double; public let cleanupSeconds: Double?
    public let appName: String?; public let status: Status; public let failure: String?
}
@MainActor @Observable public final class DictationPipeline {
    public private(set) var state: DictationState
    public private(set) var level: Float                         // latest input peak, for the indicator
    public var onOutcome: ((DictationOutcome) -> Void)?
    public init(recorder: Recording, service: TranscriptionService, paster: Pasting,
                cleaner: TextCleaner?, replacements: @escaping () -> [Replacement], vocabulary: @escaping () -> [String])
    public func hotkeyDown(); public func hotkeyUp(); public func cancel()
    public func pasteLast()
}
public protocol Recording: AnyObject { /* startRecording, stopRecording, cancelRecording, prepare, delegate, onLevel */ }
public protocol Pasting { func paste(text: String) -> Bool; var frontmostAppName: String? { get } }
```
`TextCleaner` and `Replacement` do not exist yet: declare `public protocol TextCleaner: Sendable { func clean(_ raw: String) async throws -> String }` in `Cleanup/TextCleaner.swift` and `public struct Replacement: Codable, Equatable, Sendable { public var from: String; public var to: String }` in `Text/Replacements.swift` now; Tasks 21 and 22 fill them in. Until then the app passes `cleaner: nil` and empty lists.

- [ ] **Step 1: Failing tests** with fakes for recorder, service, paster: `testHappyPathPastesAndReportsOutcome` (states go recording → transcribing → idle; outcome status `.pasted`, `appName` from the fake); `testEmptyTextPastesNothingAndIsNotAnOutcome`; `testQueueSkipsOldestBeyondThree` (five rapid clips with a slow fake engine → clips 1, 3, 4 and 5 are pasted exactly once, in that order; clip 2 is never sent to the engine and produces a `.failed` outcome with `clip != nil` and `failure == "Skipped: too many dictations waiting"` — **Review Focus 4**); `testModelFailureProducesFailedOutcomeWithClip` (**Review Focus 1**: status `.failed`, `clip != nil`, `failure` non-empty); `testCancelLeavesNoTrace` (cancel while recording, and again while transcribing: nothing pasted, `onOutcome` never called, the clip is released); `testErrorStateReturnsToTrueState` (after an error with permissions missing, state settles on `.needsPermission`, not `.idle`); `testPasteFailureLeavesTextOnClipboardAsCopied`.
- [ ] **Step 2:** Implement the pipeline. `PasteEngine.paste` returns `false` when `AXIsProcessTrusted()` is false (text stays on the clipboard, no restore) and conforms to `Pasting`.
- [ ] **Step 3:** Shrink `AppDelegate` to construction and wiring; `StatusManager` renders `DictationState`. Replace the model line in the menu with a submenu of `service.allModels()` (checkmark on the selected one; choosing one calls `select`, showing `preparingModel` meanwhile; not-downloaded models read "Download …" and download then select).
- [ ] **Step 4: Globe as a modifier.** In `GlobeKeyStrategy.handleEvent`, a `keyDown` other than Escape while `isPressed` calls `hotkeyCancelled()` and passes the event through unconsumed. Test the decision as a pure function `static func action(forKeyDown keyCode: Int64, whilePressed: Bool) -> KeyAction` (`.none`, `.cancelAndConsume`, `.cancelAndPass`).
- [ ] **Step 5:** All tests pass. Build, launch, and check by hand: dictate with Apple Speech, switch to the whisper-cli model from the menu and dictate again, press Globe+Right Arrow and confirm nothing is dictated. Commit: `feat: DictationPipeline with switchable engines`.

### Task 10: Comparison tool and report

**Files:** Modify `Package.swift` (executable target `VDBench` depending on `VoiceDictationLib`). Create `Sources/VDBench/main.swift`, `Tests/VoiceDictationTests/BenchReportTests.swift`, and in the lib `Engine/BenchReport.swift`.

**Produces:** `swift run vd-bench [dir]` (default: the `comparison/` folder from Task 2). For each WAV and each ready model it prints the text and seconds, then writes `docs/engine-comparison.md`: a summary table (model, median seconds, median seconds per second of audio, clips) followed by one section per clip with every model's text side by side and the differing words in bold. `BenchReport.markdown(rows:) -> String` and `BenchReport.diffWords(_ a: String, _ b: String) -> (String, String)` are pure and tested.

- [ ] **Step 1: Failing tests.** `testMedian`, `testDiffMarksOnlyChangedWords` (`"set up Tailscale now"` vs `"set up tail scale now"` → `"set up **Tailscale** now"`, `"set up **tail scale** now"`), `testReportHasOneRowPerModel`.
- [ ] **Step 2:** Implement. The first transcription per model is run once and discarded so load time is not counted, and the load time is reported separately.
- [ ] **Step 3:** Run it on the bundled `sample.wav` to prove it works. If `comparison/` has 20 or more clips, run it for real and commit the report; if not, leave the report task open against D1 in the notes file. Commit: `feat: vd-bench engine comparison`.

---

## Phase 2: Real app

### Task 11: Transcript store and history import

**Files:** Create `Store/Transcript.swift`, `Store/TranscriptStore.swift`, `Store/HistoryImporter.swift`, `Tests/VoiceDictationTests/TranscriptStoreTests.swift`, `Tests/VoiceDictationTests/HistoryImporterTests.swift`.

**Produces:**
```swift
@Model public final class Transcript {
    @Attribute(.unique) public var id: UUID
    public var date: Date; public var text: String; public var rawText: String; public var cleanedText: String?
    public var appName: String?; public var modelKey: String; public var recordingSeconds: Double
    public var transcribeSeconds: Double; public var cleanupSeconds: Double?
    public var statusRaw: String; public var failure: String?; public var pinned: Bool
    public var isEdited: Bool                               // true once Danny has changed `text` by hand
    public var audioFileName: String?                       // set by Task 12
    @Relationship(deleteRule: .cascade) public var alternates: [AlternateResult]
}
@Model public final class AlternateResult { public var modelKey: String; public var text: String; public var seconds: Double; public var date: Date }
@MainActor @Observable public final class TranscriptStore {
    public enum Health: Equatable { case ok, unavailable(String) }
    public private(set) var health: Health
    public let container: ModelContainer?                   // nil when unavailable
    public init(directory: URL, inMemory: Bool = false)
    @discardableResult public func add(_ outcome: DictationOutcome) -> Transcript?
    public func search(_ query: String, scope: Scope) -> [Transcript]     // Scope: all, today, pinned; newest first; case-insensitive substring
    public func setPinned(_ t: Transcript, _ pinned: Bool); public func delete(_ t: Transcript)
    public func addAlternate(to t: Transcript, _ r: TranscriptionResult); public func promote(_ alt: AlternateResult, in t: Transcript)
    public func revertToRaw(_ t: Transcript); public var latest: Transcript? { get }
    public func updateText(_ t: Transcript, _ newText: String)   // hand edit: sets text and isEdited; ignores empty or whitespace-only text; never touches rawText or cleanedText
}
public enum HistoryImporter { public static func importIfNeeded(from jsonURL: URL, into store: TranscriptStore, defaults: UserDefaults) -> Int }
```
Store file: `~/Library/Application Support/VoiceDictation/transcripts.store`.

- [ ] **Step 1: Failing tests** (in-memory store): add/search round trip; `testSearchIsCaseInsensitiveSubstring`; `testTodayScope`; `testPinnedScope`; `testPromoteAlternateSwapsText` (old main text becomes an alternate so nothing is lost; when it was a hand edit the alternate's `modelKey` is `"edited"`); `testRevertToRaw` (also clears `isEdited`); `testUpdateTextMarksEditedAndKeepsRawAndCleaned`; `testUpdateTextIgnoresEmpty` (text and `isEdited` unchanged); `testSearchFindsEditedText`; **Review Focus 5** `testCorruptStoreIsMovedAsideAndHealthUnavailable` (write garbage bytes to `transcripts.store`, `transcripts.store-wal` and `transcripts.store-shm` in a temp dir; init → `health == .unavailable`; all three are renamed with the same `.broken-<timestamp>` suffix and none of the original names remain; `add` returns nil without crashing. SwiftData keeps a store as three files, so a leftover `-wal`/`-shm` pair must never meet the next store created at that path; a garbage file makes `ModelContainer` throw `SwiftDataError.loadIssueModelContainer` rather than crash; both checked 2026-11-11). Importer: `testImportsOnceAndLeavesFileUntouched` (20 entries in → 20 transcripts, status `.pasted`, `modelKey == "whisperCLI/<old id>"`, second call imports 0, JSON bytes unchanged).
- [ ] **Step 2:** Implement. Wire `pipeline.onOutcome → store.add` and replace the menu's history submenu source with `store.search("", scope: .all).prefix(10)`. Delete `TranscriptionHistory.swift` and its tests once the importer covers the format (keep the `TranscriptionEntry` decoding inside the importer).
- [ ] **Step 3:** Tests pass. Commit: `feat: SwiftData transcript store and history import`.

### Task 12: Audio keeping and retention

**Files:** Create `Store/AudioArchive.swift`, `Tests/VoiceDictationTests/AudioArchiveTests.swift`. Modify `TranscriptStore.swift`, `PreferencesManager.swift`.

**Produces:** `public struct AudioArchive { public init(directory: URL); public func save(_ clip: AudioClip, id: UUID) throws -> String; public func load(_ fileName: String) throws -> AudioClip; public func url(for fileName: String) -> URL; public func remove(_ fileName: String) }` writing ALAC `audio/<uuid>.m4a`. `TranscriptStore.prune(keeping: Int)`; `PreferencesManager.shared.keptRecordings: Int` (default 50; 0 = keep none).

- [ ] **Step 1: Failing tests.** `testSaveLoadRoundTrip`; `testPruneKeepsNewestN` (60 transcripts with audio, keep 50 → the oldest 10 have `audioFileName == nil` and their files are gone, transcripts remain); `testPinnedKeepAudioAndDoNotCountAgainstLimit`; `testZeroKeepsNoAudioForNewTranscripts`; `testDeletingTranscriptRemovesItsAudio`; `testOrphanFilesAreRemovedOnPrune` (a stray `.m4a` with no transcript is deleted).
- [ ] **Step 2:** Implement; `add` saves audio then prunes. Failed outcomes always keep their audio until re-transcribed or deleted (Review Focus 1).
- [ ] **Step 3:** Tests pass. Commit: `feat: keep recent recordings for replay and re-transcription`.

### Task 13: The app bundle

**Files:** Create `project.yml`, `App/VoiceDictationApp.swift`, `App/Info.plist`, `App/VoiceDictation.entitlements`, `scripts/run-dev.sh`, `Sources/VoiceDictationUI/MenuBar/MenuBarContent.swift`, `Sources/VoiceDictationUI/AppModel.swift`. Modify `Package.swift` (add library target `VoiceDictationUI` + test target `VoiceDictationUITests`; remove the `VoiceDictation` executable target and `Sources/VoiceDictation/`), `.gitignore` (`*.xcodeproj`), `LoginItemManager.swift`, `CLAUDE.md`, `AGENTS.md`, `README.md`. Delete `AppDelegate.swift`, `StatusManager.swift`, `PreferencesWindowController.swift`, `Resources/`.

**Produces:**
- `@MainActor @Observable public final class AppModel` in `VoiceDictationUI`: owns `pipeline`, `service`, `store`, `permissions`, `hotkeys`; `func start()`; `var models: [ModelDescriptor]`; `func refreshModels() async`. It is the single object the views read. All construction that `AppDelegate` did moves here.
- `project.yml`: one application target `VoiceDictation`, deployment target 26.0, sources `App/`, local package `.` with products `VoiceDictationLib` and `VoiceDictationUI`, bundle id `com.danny.VoiceDictation`, `DEVELOPMENT_TEAM: F7DL4CTLLL`, automatic signing for Debug, hardened runtime on, `LSUIElement: true`, `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` strings. Entitlements: `com.apple.security.device.audio-input` only. No sandbox.
- `scripts/run-dev.sh`: `xcodegen`, `xcodebuild -scheme VoiceDictation -configuration Debug -derivedDataPath .build/xcode build`, kill any running instance, `open` the built app.
- Scenes: `MenuBarExtra` (menu style) with status line, "Open VoiceDictation", "Paste Last Transcript", model submenu, "Settings…", "Quit"; `Window("VoiceDictation", id: "main")` showing a placeholder until Task 18; `Settings` scene showing a placeholder until Task 24.

- [ ] **Step 0: Preferences migration.** The current app runs as a bare binary, so its settings are in the `VoiceDictation` defaults domain, not `com.danny.VoiceDictation`. Add `PreferencesMigrator.migrateIfNeeded(from: UserDefaults(suiteName: "VoiceDictation"), to: .standard)` to the lib: copies `selectedModel`, `historyEnabled`, `maxHistoryItems`, `launchAtLogin`, `hasLaunchedBefore` once (guarded by a `didMigrateLegacyDefaults` flag), never overwriting a key already set. Tests: `testCopiesOnce`, `testDoesNotOverwriteExisting`, `testNoLegacyDomainIsANoOp`.
- [ ] **Step 1:** Move the single-instance guard into `VoiceDictationApp.init`. Keep `NSApp.setActivationPolicy(.accessory)` at launch; switch to `.regular` when the main window appears and back to `.accessory` when it closes, so there is a Dock icon and a normal menu only while the window is open. Closing the window must not quit (`applicationShouldTerminateAfterLastWindowClosed` → false via an `NSApplicationDelegateAdaptor`).
- [ ] **Step 2:** The menu bar icon keeps today's symbols with the `mic.fill` fallback, driven by `DictationState`; no colour tint beyond what the system applies (Prism: status is words) except the template image itself.
- [ ] **Step 3:** `LoginItemManager.isRunningFromAppBundle` additionally returns false when the path contains `/.build/`, so dev builds from DerivedData never register a login item.
- [ ] **Step 4:** `DEVELOPER_DIR=… swift test` still passes. `./scripts/run-dev.sh` builds and launches. `codesign -dv --verbose=2 <app>` shows `TeamIdentifier=F7DL4CTLLL` and `Identifier=com.danny.VoiceDictation`.
- [ ] **Step 5: Hands-on (D5).** Grant Microphone and Accessibility to the bundle, dictate into TextEdit with the window closed, rebuild, and confirm the grants survive the rebuild. If this session cannot do it, write the checklist into the notes file for Danny.
- [ ] **Step 6: Keep the docs true.** Every subagent gets `CLAUDE.md` in its context, and this task deletes the binary the docs' run commands launch. In `CLAUDE.md` and `AGENTS.md`, replace the `nohup .build/debug/VoiceDictation …` line under Key Commands with `./scripts/run-dev.sh` (builds and launches the app); keep the `DEVELOPER_DIR=… swift test` line and the log tail; start the Architecture block with `VoiceDictationApp → AppModel → DictationPipeline`. In `README.md`, replace the "Build and run" commands (`swift build`, `.build/debug/VoiceDictation`) with `./scripts/run-dev.sh`, and the requirement "macOS 13+ (Ventura)" with "macOS 26 or later; building needs Xcode". Task 27 still does the full rewrite.
- [ ] **Step 7:** Commit: `feat: native app bundle with SwiftUI shell`.

### Task 14: Onboarding

**Files:** Create `Sources/VoiceDictationUI/Onboarding/OnboardingView.swift`, `Tests/VoiceDictationUITests/OnboardingModelTests.swift`. Modify `PermissionManager.swift`, `VoiceDictationApp.swift`.

**Produces:** `@Observable final class OnboardingModel` with `steps: [Step]` (`microphone`, `accessibility`, `globeKey`, `speechModel`, `tryIt`), each `state: .done | .needed | .unavailable(String)`, `var isComplete: Bool`, and `func open(_ step:)` that opens the right System Settings pane. `PermissionManager` becomes `@Observable` (keep its 5 s polling) and loses its alert-driven prompts. A `Window("Welcome", id: "onboarding")` shown at launch when `!isComplete` or on first run; reachable later from Settings.

- [ ] **Step 1: Failing tests.** `testCompleteWhenAllDone`; `testGlobeKeyStepUsesHIToolboxSetting`; `testSpeechModelStepNeededWhenAssetsMissing` (offers a Download button that calls `service.download(.appleSpeech)`); `testTryItStepCompletesOnFirstPastedOutcome`.
- [ ] **Step 2:** Implement; remove `showGlobeKeyWarning` and `showReadyAlert` paths. The globe-key step only applies when the chosen hotkey is Globe.
- [ ] **Step 3:** Tests pass; run the app with a fresh defaults domain (`defaults delete com.danny.VoiceDictation hasLaunchedBefore`) and walk the flow. Commit: `feat: onboarding window replaces alerts`.

### Task 15: Release build script

**Files:** Create `scripts/release.sh`, `docs/release.md`.

- [ ] **Step 1:** `release.sh`: archive Release with `CODE_SIGN_IDENTITY="Developer ID Application"`, export, zip, `xcrun notarytool submit --keychain-profile voicedictation-notary --wait`, `xcrun stapler staple`, `spctl -a -vv` check, output to `dist/VoiceDictation-<version>.zip`. It fails early with a plain message naming D4 if the identity or profile is missing.
- [ ] **Step 2:** `docs/release.md`: the two one-time steps Danny does for D4, then "run `./scripts/release.sh`", then how to install on the Mac mini.
- [ ] **Step 3:** Run the script; with D4 not done the expected result is the early failure message. Commit: `feat: signed and notarised release script`.

---

## Phase 3: The window

### Task 16: Prism tokens

**Files:** Create `DESIGN.md`, `Sources/VoiceDictationUI/Theme.swift`, `Sources/VoiceDictationUI/Fonts.swift`, `Sources/VoiceDictationUI/Resources/Fonts/` (Jost, Work Sans, DM Mono TTFs with their OFL licence files, from the google/fonts repository), `Tests/VoiceDictationUITests/ThemeTests.swift`. Modify `Package.swift` (resources), `~/CodingProjects/design-reference/direction-log.md`.

**Produces:** `enum Theme { enum Color { static let bg, bgElevated, text, textMuted, hairline: SwiftUI.Color; static let spectrum: LinearGradient }; enum Font { static func title(_ size: CGFloat = 26) -> SwiftUI.Font; static func ui(_ size: CGFloat = 14, medium: Bool = false) -> SwiftUI.Font; static func mono(_ size: CGFloat = 12) -> SwiftUI.Font }; enum Space { static let xs: CGFloat = 4, sm = 8, md = 16, lg = 24, xl = 40 } }`, `Fonts.registerAll()` (called once at launch), view modifiers `.prismPrimaryButton()` (white fill, black text) and `.prismSecondaryButton()` (1px white outline), and `SpectrumUnderline` (2px).

- [ ] **Step 1:** Write `DESIGN.md` from `~/CodingProjects/design-reference/templates/DESIGN-template.md`, filled from `design-directions/prism.md` with the values in Global Constraints. Direction: Prism. Signature move: the spectrum underline on the selected transcript. Record the one deliberate departure: the live indicator is a scrolling volume line, not the direction's stepping heartbeat, and carries no colour. Run `npx @google/design.md lint DESIGN.md`; fix what it reports.
- [ ] **Step 2: Failing tests.** `testFontsRegister` (after `registerAll()`, `NSFont(name: "Jost-Regular", size: 12)`, Work Sans and DM Mono are non-nil; use the PostScript names found in the files); `testTokenValues` (bg is `#000000`, text `#F2F2F2`, hairline `#2A2A2A`); `testSpectrumHasSixStops`.
- [ ] **Step 3:** Implement. Append a row to the direction log: project "Voice Dictation", direction "Prism", date, signature move, the indicator departure, and "first native macOS (SwiftUI) use of Prism".
- [ ] **Step 4:** Tests pass. Commit here; commit the direction-log line separately in the design-reference repo: `log: Prism for Voice Dictation`.

### Task 17: The floating indicator

**Files:** Create `Indicator/LevelLine.swift`, `Indicator/IndicatorView.swift`, `Indicator/IndicatorPanel.swift`, `Tests/VoiceDictationUITests/LevelLineTests.swift`. Modify `AppModel.swift`.

**Produces:**
```swift
public struct LevelLine {
    public static let step: CGFloat = 5, interval: TimeInterval = 0.05, width: CGFloat = 170, height: CGFloat = 26
    public static let gain: Float = 5, floor: Float = 0.03, attack: Float = 0.75, release: Float = 0.35, exponent: Float = 0.7
    public mutating func add(peak: Float, at time: TimeInterval)     // keeps the max until the next interval boundary, then pushes one vertex
    public func points(at time: TimeInterval) -> [CGPoint]           // straight-segment polyline, newest on the right, scrolled by the fraction of the current interval
    public mutating func reset()
}
```
`IndicatorView(state:level:)` and `IndicatorPanel` (`NSPanel`, `.nonactivatingPanel`, borderless, `level = .statusBar`, `ignoresMouseEvents = true`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, never key or main, bottom centre of the screen containing the mouse, 80 pt above the visible frame's bottom).

The maths is the prototype's (`prism-live-line-fluid.html`): per interval, `loud = max(0, peak × gain − floor)`; `env += (loud − env) × (loud > env ? attack : release)`; `amp = min(1, env^exponent)`; vertex `y = mid ± amp × (mid − 1)` with the sign alternating per vertex.

- [ ] **Step 1: Failing tests.** `testSilenceIsFlat` (peaks of 0 for 1 s → every point's y equals `height/2`); `testLouderIsTaller` (steady 0.02 vs steady 0.1 → strictly greater max deviation); `testNeverExceedsBounds` (peak 1.0 → all y within `1...height−1`); `testVerticesAlternateSides`; `testScrollsLeft` (a single loud interval moves `step` points left per `interval`); `testRisesFasterThanFalls`; `testKeepsOnlyVisibleHistory` (after 60 s, vertex count ≤ `width/step + 3`).
- [ ] **Step 2:** Implement `LevelLine`. `IndicatorView` draws it in a `Canvas` inside `TimelineView(.animation)` with a 1px white stroke and mitre joins; text "Listening" (Work Sans medium 13), timer `m:ss` and "esc to cancel" (DM Mono 12, the latter muted); black fill, 1px hairline border, square corners. States: recording → "Listening" + line + timer; transcribing → "Transcribing"; cleaning → "Cleaning up"; anything else → hidden. With `accessibilityReduceMotion`, draw a flat line.
- [ ] **Step 3:** `AppModel` shows and hides the panel from `pipeline.state` and feeds `pipeline.level` into the line. Confirm by hand that showing it does not change the frontmost app (`NSWorkspace.shared.frontmostApplication` is the same before and after) and that it appears over a full-screen app. Commit: `feat: floating indicator with live volume line`.

### Task 18: Transcript library (read side)

**Files:** Create `Window/MainWindow.swift`, `Window/Sidebar.swift`, `Window/TranscriptList.swift`, `Window/TranscriptDetail.swift`, `Window/LibraryModel.swift`, `Tests/VoiceDictationUITests/LibraryModelTests.swift`.

**Produces:** `@MainActor @Observable final class LibraryModel` with `section: Section` (`all`, `today`, `pinned`, `models`, `vocabulary`, `settings`), `query: String`, `selection: Transcript.ID?`, `var rows: [Transcript]`, and `func noteNewTranscript(_:)`. Pure helpers: `static func rowMeta(_ t: Transcript, now: Date) -> (app: String, when: String)` and `static func facts(_ t: Transcript) -> [(label: String, value: String)]`.

Layout, from mockup D: three columns 220 / 340 / flexible, minimum window 1000×600. Sidebar groups "Transcripts" and "Setup" with counts in DM Mono; footer shows the selected model's name and "Hold Globe to dictate" (or the chosen hotkey). List: search field, rows with app name and `time · length` on one muted mono line and two lines of text; hairline between rows; the selected row gets `SpectrumUnderline` and no fill. Detail: Jost title "`<App> · <time>`", status word, four facts (Length, Transcribed in, Model, Words), the text at 16pt with 1.65 line height, selectable.

- [ ] **Step 1: Failing tests.** `testNewTranscriptAppearsFirst`; `testNewTranscriptDoesNotStealSelection` (selection unchanged when something was selected; selects the new one only when nothing was); `testWhenString` (today → `"7:42 PM"`, yesterday → `"Yesterday"`, older → `"Nov 3"`); `testLengthString` (14.2 → `"14s"`, 75 → `"1m 15s"`); `testFactsValues` (`"14.2s"`, `"0.3s"`, model display name, word count); `testEmptyStates` (no transcripts → "Nothing dictated yet. Hold Globe and speak."; no search results → "No transcripts match “<query>”."; store unavailable → the health message — Review Focus 5).
- [ ] **Step 2:** Implement with `Theme` only (no literal colours or fonts in views). Keyboard: up/down moves selection, ⌘F focuses search, ⌘C copies the selected transcript. Every control has an accessibility label.
- [ ] **Step 3:** Run the app, dictate with the window open, and compare with the mockup side by side; note differences in the notes file. Commit: `feat: transcript library window`.

### Task 19: Transcript actions and comparison

**Files:** Create `Window/ComparisonView.swift`, `Window/AudioPlayer.swift`, `Tests/VoiceDictationUITests/DetailActionsTests.swift`. Modify `TranscriptDetail.swift`, `LibraryModel.swift`, `DictationPipeline.swift`.

**Produces:** `LibraryModel` action `edit(_:text:)` (debounced autosave through `store.updateText`) and actions `copy(_:)`, `pasteAgain(_:)` (hides the window, waits for the previous app to be frontmost, then `paster.paste`), `togglePin(_:)`, `delete(_:)`, `retranscribe(_:with:) async`, `promote(_:in:)`; `var retranscribing: Set<ModelID>`. `AudioPlayer` (play/stop one clip via `AVAudioPlayer` on the archive URL).

- [ ] **Step 1: Failing tests.** `testRetranscribeAddsAlternateWithTiming`; `testRetranscribeSameModelTwiceReplacesNotDuplicates`; `testPromoteMakesAlternateMainAndKeepsOld`; `testActionsDisabledWithoutAudio` (Play and Re-transcribe unavailable when `audioFileName == nil`, with the reason "Audio no longer kept"); `testRetranscribeFailedTranscriptPromotesAutomatically` (a `.failed` transcript with audio gets the new text as its main text, the text is put on the clipboard, and its status becomes `.copied` — Review Focus 1); `testFailedTranscriptOffersItsOwnModel` (a dictation skipped while Apple Speech was selected offers Apple Speech under Re-transcribe with…); `testDeleteAsksOnlyForPinned`; `testEditSavesAndShowsEditedStatus` (after `edit`, the status word reads "Edited", Copy and Paste again use the new text); `testClearingTextRestoresPrevious`; `testEditSurvivesSelectionChange` (type, select another row before the debounce fires, come back: the edit is saved); `testLateCleanedTextCanBePromoted` (a transcript whose `text == rawText` but has a different `cleanedText` offers "Use cleaned", which sets `text = cleanedText`).
- [ ] **Step 2:** Implement. The transcript text in the detail view becomes an editable text view (Work Sans 16, same line height, no border; the hairline under the facts row is the only frame). Edits save by themselves about half a second after typing stops and immediately when the selection changes or the window closes; ⌘Z undoes within the session. An edited transcript shows the status word "Edited" and keeps "Revert to raw". "Re-transcribe with…" is a menu of ready models other than the one already used; for a Failed transcript (its model failed, or the dictation was skipped) it offers every ready model, including that one. The comparison panel appears when `alternates` is non-empty: columns side by side (two at a time, horizontally scrollable beyond that), each headed by model name and seconds, differing words underlined using `BenchReport.diffWords` (underline, not tint), and a "Use this one" secondary button.
- [ ] **Step 3:** Tests pass; check by hand that Paste again lands in the previously frontmost app. Commit: `feat: transcript actions, replay and model comparison`.

### Task 20: Models section

**Files:** Create `Window/ModelsView.swift`, `Tests/VoiceDictationUITests/ModelsModelTests.swift`. Modify `AppModel.swift`.

**Produces:** `AppModel.download(_:)`, `AppModel.cancelDownload(_:)`, `AppModel.deleteModel(_:)`, `AppModel.use(_:) async`.

One row per descriptor: name (Work Sans medium), detail line, size on disk (DM Mono), state word (Ready, Not downloaded, Downloading 42%, Preparing, Unavailable: reason), and buttons that fit the state (Download / Cancel / Delete, and "Use for dictation", which reads "In use" and is disabled for the selected model). The two Apple models have no Delete, and their Download installs the system language files. Order: Apple Speech, Apple Dictation, then WhisperKit smallest to largest, then the old whisper-cli models under a muted "Previous engine" label (removed in Task 27).

- [ ] **Step 1: Failing tests** against fake engines: `testUseSelectsAndPersists`; `testCannotDeleteSelected`; `testDownloadProgressUpdatesDescriptor`; `testCancelDownloadLeavesNotDownloaded`; `testChangingModelDuringDownloadDoesNotSwitchUntilUseIsPressed`.
- [ ] **Step 2:** Implement. Tests pass. By hand: download WhisperKit base.en from the UI, use it, dictate, switch back. Commit: `feat: models section`.

---

## Phase 4: Cleanup and comforts

### Task 21: Transcript cleanup

**Files:** Create `Cleanup/CleanupGuard.swift`, `Cleanup/FoundationModelCleaner.swift`, `Tests/VoiceDictationTests/CleanupGuardTests.swift`, `Tests/VoiceDictationTests/CleanupPipelineTests.swift`, `Tests/VoiceDictationTests/PrivacyTests.swift`. Modify `Cleanup/TextCleaner.swift`, `DictationPipeline.swift`, `PreferencesManager.swift`, `TranscriptDetail.swift`, `TranscriptStore.swift`, `AppModel.swift`, `Tests/VoiceDictationTests/TranscriptStoreTests.swift`.

**Produces:**
```swift
public enum CleanupGuard {
    public static let disfluencies: Set<String>       // um, uh, uhm, er, erm, ah, hmm, mm: deletable anywhere
    public static let discourseFillers: [[String]]    // you know, i mean, kind of, sort of, like, so, well, okay, ok, right, actually,
                                                      // basically, literally: deletable only when set off (rule 4); phrases listed first
    public struct Token: Equatable, Sendable { public let word: String; public let pauseBefore: Bool; public let pauseAfter: Bool }
    public static func tokens(_ s: String) -> [Token] // lowercased words; apostrophes and hyphens removed; other punctuation separates words.
                                                      // pauseBefore/pauseAfter: a comma, dash (— or –) or ellipsis (… or ...) between
                                                      // this word and the previous/next word; false at the start and end of the text
    public static func accepts(raw: String, cleaned: String) -> Bool
}
public enum CleanerAvailability: Equatable { case available, unavailable(String) }
public struct FoundationModelCleaner: TextCleaner { public init(); public static var availability: CleanerAvailability { get }; public func prewarm() }
// Added to DictationPipeline (Task 9). Called at most once per outcome, only for an accepted cleanup that finished after the paste:
public var onLateCleanup: ((_ id: UUID, _ cleanedText: String, _ cleanupSeconds: Double) -> Void)?
// Added to TranscriptStore (Task 11). Sets cleanedText and cleanupSeconds only; never text, rawText or isEdited; an unknown id is a no-op:
public func setLateCleanup(id: UUID, cleanedText: String, seconds: Double)
```
`PreferencesManager.shared.cleanupEnabled: Bool` (default true). Pipeline constants: `cleanupTimeLimit = 2.0` seconds, `cleanupMinimumWords = 4`.

**The guard's rule** (`accepts`): let `r = tokens(raw)`, `c = tokens(cleaned)`, compared by `word`. Accept only if all hold: (1) `c` is non-empty; (2) `c` is a subsequence of `r`, matched leftmost-first (cleanup may delete words, never add, change, or reorder them); (3) reading each run of consecutive deleted words left to right, every word is, checked in this order, a disfluency, a stammer (the same word repeated next to itself, skipping disfluencies in between, with at least one copy kept), or part of a discourse filler, and a multi-word filler counts only when the whole phrase is in the run; (4) a run that uses a discourse filler is set off: it also contains a disfluency, or its first word has `pauseBefore` or its last word has `pauseAfter`; (5) at most 40% of `r` is deleted.

Why this shape: "right", "so", "you" and "of" are fillers only some of the time, so they may be deleted only where the speech marks them as fillers, with a pause mark or a neighbouring "um". The stammer test looks at the raw words, not at which copy the match kept, because a leftmost match keeps the first copy.

**False starts stay in.** The spec lists false starts among what cleanup removes. Danny decided on 2026-11-11 to leave them in: removing one means deleting real words, which rule (3) exists to reject. The instructions in Step 5 already leave them out.

- [ ] **Step 1: Failing guard tests** (exact cases):
  - accepts `"um so i think we should uh ship it"` → `"I think we should ship it."`
  - accepts `"set up tailscale on the mac mini"` → `"Set up Tailscale on the Mac mini."` (case and punctuation only)
  - accepts `"the the build is is broken"` → `"The build is broken."`
  - accepts `"i don't know, it's e-mail"` → `"I don't know. It's email."`
  - accepts `"it was, like, really big and loud"` → `"It was really big and loud."` (a filler set off by commas)
  - accepts `"you know, i think it works"` → `"I think it works."` (a whole filler phrase, set off)
  - accepts `"So, I think we should, uh, ship it."` → `"I think we should ship it."` (engine output that is already punctuated)
  - accepts `"the uh the build is broken"` → `"The build is broken."` (a stammer across a disfluency)
  - rejects `"ship it friday"` → `"Ship it on Friday."` (added word)
  - rejects `"we should ship it"` → `"We must ship it."` (changed word)
  - rejects `"call sam then email pat"` → `"Email Pat, then call Sam."` (reordered)
  - rejects `"delete the old branch"` → `"Delete the branch."` (dropped a non-filler)
  - rejects `"um"` → `""` and any raw → `"Here is the cleaned text: …"`
  - rejects `"twenty five dollars"` → `"$25."` (reformatting is out of scope)
  - rejects `"turn right at the light"` → `"Turn at the light."` (a filler word that is not set off)
  - rejects `"i didn't say you were wrong"` → `"Didn't say were wrong."` (single words of a filler phrase)
  - rejects `"do you know the answer"` → `"Do the answer?"` (a filler phrase that is not set off)
  - rejects `"what kind of car is it"` → `"What car is it?"`
  - rejects `"turn right right now"` → `"Turn now."` (every copy of a repeat deleted)
  - rejects `"Turn right. Then left at the light."` → `"Turn. Then left at the light."` (a full stop is not a pause mark)
  - rejects `"i went to the, i drove to the store"` → `"I drove to the store."` (a false start)
  - `testTokensMarkPauses`: `tokens("so, um — it's e-mail")` gives the words `so`, `um`, `its`, `email` with (`pauseBefore`, `pauseAfter`) of (false, true), (true, true), (true, false), (false, false)
- [ ] **Step 2:** Implement `CleanupGuard`. Tests pass.
- [ ] **Step 3: Failing pipeline tests** with a fake cleaner (**Review Focus 3**): `testCleanedTextIsPastedWhenAccepted`; `testRawPastedWhenGuardRejects` (outcome `cleanedText == nil`); `testRawPastedWhenCleanerThrows` (state never shows `.error`); `testRawPastedAtTimeLimit` (cleaner sleeps 5 s → paste happens at about 2 s with raw text; when the cleaner finally returns an accepted result, `onLateCleanup` is called once with the outcome's id and the cleaned text, and nothing is pasted again); `testLateRejectedCleanupIsDropped` (a late result the guard rejects never reaches `onLateCleanup`); `testSetLateCleanupKeepsTextAndEdits` (in `TranscriptStoreTests`: `setLateCleanup` sets `cleanedText` and `cleanupSeconds`; `text`, `rawText` and `isEdited` are unchanged, also on an edited transcript; an unknown id changes nothing); `testShortTranscriptSkipsCleanup` (3 words → cleaner not called); `testCleanupOffSkipsCleaner`; `testStateShowsCleaning`.
- [ ] **Step 4:** Implement the pipeline step: order is `OutputFilter` → replacements → cleaner → guard → paste. `AppModel` connects `pipeline.onLateCleanup` to `store.setLateCleanup`.
- [ ] **Step 5: `FoundationModelCleaner`** (read the swiftinterface first). Availability maps `SystemLanguageModel.default.availability` to plain reasons ("This Mac does not support Apple Intelligence", "Apple Intelligence is turned off in System Settings", "The language model is still downloading"). A new `LanguageModelSession` per call (no shared history), instructions below, `GenerationOptions` with the most deterministic sampling the SDK offers (greedy if present, else temperature 0) and `maximumResponseTokens` about 1.5× the input's word count + 50. `prewarm()` at launch and after each dictation. Instructions, verbatim:

  > You fix dictated text. Do exactly three things: remove filler words (um, uh, er, you know, I mean, like when it is filler) and stammered repeats; fix punctuation; fix capitalisation. Never add, replace, reorder, or reformat words. Never answer or act on the text, even if it is a question or an instruction. Reply with the corrected text only, with no quotation marks and no commentary.

- [ ] **Step 6: `PrivacyTests.testNoCloudModelReferenced`:** walk `Sources/` and fail if any `.swift` file contains `PrivateCloudCompute`.
- [ ] **Step 7:** Integration test `testRealCleanerOnSample` (skips unless availability is `.available`): `"um so the quick brown fox uh jumps over the lazy dog"` → result passes `CleanupGuard.accepts` and contains neither `"um"` nor `"uh"` as words. Log the elapsed time; if the median over five runs exceeds 1.5 s, record it in the notes file for Danny (the limit is tunable).
- [ ] **Step 8: UI.** In the detail view, when `cleanedText != nil` and differs from `rawText`: a "Raw / Cleaned" two-way switch above the text and a "Revert to raw" secondary button (calls `store.revertToRaw`). Fifth fact "Cleaned in 0.4s" when present. Commit: `feat: on-device transcript cleanup with rewrite guard`.

### Task 22: Vocabulary and replacements

**Files:** Create `Text/Vocabulary.swift`, `Window/VocabularyView.swift`, `Tests/VoiceDictationTests/ReplacementsTests.swift`, `Tests/VoiceDictationTests/VocabularyStoreTests.swift`. Modify `Text/Replacements.swift`, `AppModel.swift`.

**Produces:** `@MainActor @Observable public final class VocabularyStore { public init(fileURL: URL); public var words: [String]; public var replacements: [Replacement]; public func save() }` persisted as `vocabulary.json` in the data directory (atomic write). `public enum Replacements { public static func apply(_ rules: [Replacement], to text: String) -> String }`.

Rule semantics: case-insensitive match on whole words or phrases (word boundaries), longest `from` first, each position replaced at most once, replacement text inserted exactly as written.

- [ ] **Step 1: Failing tests.** `"gv seventy" → "GV70"` in `"my GV Seventy is here"` → `"my GV70 is here"`; whole-word only (`"cat" → "dog"` leaves `"category"` alone); longest first (`"mac mini"` beats `"mac"`); no re-replacement (`a→b`, `b→c` on `"a"` gives `"b"`); empty `from` ignored; store round trip; `testBlankAndDuplicateWordsDropped` (case-insensitive duplicates).
- [ ] **Step 2:** Implement; wire the two closures the pipeline already takes. Vocabulary view: two plain lists with add/remove and inline editing, a one-line explanation over each ("Words the app should recognise" / "Always replace this with that").
- [ ] **Step 3:** Tests pass. By hand: add "Tailscale", dictate it with Apple Speech and with a WhisperKit model. Commit: `feat: custom vocabulary and replacements`.

### Task 23: Hotkey choice, double-tap dictation, Escape while working, Paste last

**Changed 2026-11-12 during review (Danny):**
- A double tap also ends double-tap dictation. While it runs, a single tap or a long press does nothing, and the stop fires on the second tap's release.
- A press with another key or a click during it is never a tap.
- A click cancels a held hotkey only for Right Option and Right Command.
- Paste last waits for Control and Option to be released.
- The user-facing name is "Double-tap to dictate", and "hands-free" appears in no user-facing text. The preference `handsFreeEnabled` becomes `doubleTapEnabled` in Task 24.
- These are Rulings T23-1 to T23-5 in the build ledger.

**Files:** Modify `HotkeyManager.swift`, `DictationPipeline.swift`, `PreferencesManager.swift`, `MenuBarContent.swift`. Create `Tests/VoiceDictationTests/HotkeyLogicTests.swift`.

**Produces:**
```swift
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable { case globe, rightOption, rightCommand
    public var displayName: String }           // "Globe", "Right Option", "Right Command"
public struct TapTracker {                      // pure press/release interpreter
    public static let doubleTapWindow: TimeInterval = 0.35, tapMaximum: TimeInterval = 0.25
    public var handsFreeEnabled: Bool
    public mutating func down(at: TimeInterval) -> HotkeyAction
    public mutating func up(at: TimeInterval) -> HotkeyAction
}
public enum HotkeyAction: Equatable { case none, start, stop, discardTap }
```
Preferences: `hotkey: HotkeyChoice` (default `.globe`), `handsFreeEnabled` (default false), `pasteLastHotkeyEnabled` (default false; when on, Control-Option-V).

- [ ] **Step 1: Failing tests.** Hold: `down` → `.start`, `up` after 1 s → `.stop`. Hands-free off: two quick taps → two short recordings that the 0.5 s rule discards (unchanged behaviour). Hands-free on: tap, tap within 0.35 s → recording stays on after the second `up`; next `down` → `.stop`. Hands-free on, single tap then nothing → `.discardTap`. Right Option is detected from `flagsChanged` with key code 61, Right Command with 54, and the left-hand keys (58, 55) do nothing.
- [ ] **Step 2:** Implement; `GlobeKeyStrategy` becomes `ModifierKeyStrategy(choice:)`. The "other key cancels" rule from Task 9 applies to every choice. While hands-free is locked, other keys do not cancel (the user is free to do anything) and Escape does.
- [ ] **Step 3: Escape while working.** The tap consumes Escape whenever `pipeline.state` is `.recording`, `.transcribing`, or `.cleaning`, and calls `pipeline.cancel()`. Test `testEscapeConsumedOnlyWhileBusy` on the pure decision function from Task 9, extended with the state.
- [ ] **Step 4: Paste last.** `pipeline.pasteLast()` pastes `store.latest?.text`; menu item disabled when there is none; optional Control-Option-V handled in the same event tap (consumed). Test `testPasteLastUsesLatestTranscript`.
- [ ] **Step 5:** Tests pass; exercise each by hand. Commit: `feat: hotkey choice, hands-free lock, escape and paste-last`.

### Task 24: Settings

**Files:** Create `Window/SettingsView.swift`, `Tests/VoiceDictationUITests/SettingsModelTests.swift`. Modify `AudioRecorder.swift`, `PreferencesManager.swift`, `VoiceDictationApp.swift`.

**Produces:** One `SettingsView` used both as the window's Settings section and as the `Settings` scene (⌘,). `PreferencesManager` becomes `@Observable`. New preferences: `inputDeviceUID: String?`, `soundsEnabled: Bool` (default true). Remove `keepComparisonRecordings` and the `comparison/` writer from Task 2 (kept audio replaces them); `vd-bench` gains `--from-archive` to read the audio archive. Without the flag it still reads `comparison/`, and that folder is left on disk, so clips recorded for D1 before this task still count.

Rows, in order: Hotkey (picker); Double-tap to dictate (toggle, off by default; its explanation: "Double-tap <key> to start, double-tap again to stop. Holding works as always.", with the hotkey's display name; rename `handsFreeEnabled` to `doubleTapEnabled` everywhere, the UserDefaults key included, with no migration); Paste last transcript shortcut (toggle); Clean up transcripts (toggle; when unavailable it is off and disabled with the reason beneath); Recordings to keep (stepper 0–500, with "0 turns off replay and re-transcription"); Microphone (System default + input devices); Start and stop sounds (toggle); Open at login (toggle; disabled with the existing explanation in dev builds); Data ("Reveal in Finder" button, and total size); "Show welcome guide".

- [ ] **Step 1: Failing tests.** `testCleanupRowDisabledWithReasonWhenUnavailable`; `testLoweringKeptRecordingsPrunesImmediately`; `testMissingMicrophoneFallsBackToDefault` (stored UID no longer present → recorder uses default and the row shows "System default"); `testHotkeyChangeRestartsTap`.
- [ ] **Step 2:** Implement. Input device selection sets the device on the engine's input unit before `prepare()`; a device change observer refreshes the list.
- [ ] **Step 3:** Tests pass; by hand, pick a second microphone if one is attached. Commit: `feat: settings`.

### Task 24A: Smoother live volume line

Added 2026-11-12 from Danny's first hands-on use. The indicator's line "is a little jittery and less fluid than I would like it to be. It looks like it may be hanging."

**Likely causes**, from facts the build already found:
- The tap delivers one peak per buffer of about 100 ms, because `installTap`'s buffer size is clamped to 100–400 ms (Task 4).
- `LevelLine` pushes a vertex every 50 ms and holds the last peak for the empty interval (Ruling T17-1), so the line moves in two-vertex steps.
- Peaks are stamped when they reach the main thread, so callbacks that arrive bunched make the scroll lurch.

It runs after Task 24, which also changes `AudioRecorder.swift`.

**Files:** Modify `AudioRecorder.swift`, `Indicator/LevelLine.swift`, `AppModel.swift`. Test in `Tests/VoiceDictationUITests/LevelLineTests.swift` and the recorder's existing test file.

**Produces:**
- `static func slicePeaks(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, startTime: TimeInterval, slice: TimeInterval = LevelLine.interval) -> [(peak: Float, at: TimeInterval)]` in `AudioRecorder`. This is pure: one peak per 50 ms slice of a buffer, each stamped with the time its first sample was captured.
- `onLevel` is called once per slice with that time: `onLevel: ((_ peak: Float, _ at: TimeInterval) -> Void)?`. The time is a monotonic clock derived from the buffer's host time, on the same clock `LevelLine` draws with.
- `LevelLine.add(peak:at:)` uses the slice's own time, never its arrival time, so the grid advances evenly however the callbacks bunch. Sample-and-hold (T17-1) stays only for an interval that got no slice, such as a dropped buffer.

- [ ] **Step 1: Failing tests.**
  - `testSlicesBufferIntoFiftyMillisecondPeaks`: a 100 ms buffer, loud first half and quiet second, gives two peaks, loud then quiet, stamped 50 ms apart.
  - `testBunchedArrivalsStillScrollEvenly`: slices arrive in bursts, with their own times 50 ms apart, and the vertices still advance exactly `step` per interval.
  - `testSlicedPeaksLeaveNoPlateaus`: alternating loud and quiet slices give a different amplitude on each vertex.
  - Every existing `LevelLineTests` case still passes, including the pinned amplitudes.
- [ ] **Step 2:** Implement. Keep the constants and maths of Task 17, and keep Reduce Motion's flat line.
- [ ] **Step 3: Hands-on** (Ruling P2, for Danny):
  - while speaking, the line scrolls without pauses or two-step jumps;
  - after the dictation, VoiceDictation is back near 0% CPU in Activity Monitor.
  Commit: `fix: smoother live volume line`.

---

## Phase 5: Polish

Run order in this phase: 25, 27, 27A, 26, then 28 once its design is approved. The build stops before 28. Tasks keep their numbers and their places in this file.

### Task 25: End-to-end test

**Files:** Create `Tests/VoiceDictationTests/EndToEndTests.swift`.

- [ ] **Step 1:** `testSampleFlowsFromClipToStore`: real `AppleSpeechEngine` (skip if unavailable), real `TranscriptionService`, real `CleanupGuard` with a pass-through cleaner, fake recorder that delivers `sample.wav` as a clip, fake paster capturing text, in-memory store. Assert: pasted text contains "quick brown fox" (case-insensitive); exactly one transcript stored with status `.pasted`, non-zero `transcribeSeconds`, and audio saved; pipeline state ends `.idle`.
- [ ] **Step 2:** `testSilentClipProducesNothing` (a clip of zeros is rejected by the recorder verdict before any engine call; nothing pasted, nothing stored).
- [ ] **Step 3:** Commit: `test: end-to-end dictation flow`.

### Task 26: Icon and updates

**Files:** Create `App/Assets.xcassets/Contents.json`, `App/Assets.xcassets/AppIcon.appiconset/` (`Contents.json` and ten PNGs), `scripts/make-icon.swift`, `docs/icon-preview.png`. Modify `DESIGN.md`, `project.yml`, `Package.swift` or `project.yml` for Sparkle, `App/VoiceDictationApp.swift`, `scripts/release.sh`, `docs/release.md`.

- [ ] **Step 1: Icon** (Danny's design; D7 is his sign-off of the preview). A black background and a microphone drawn as an outline whose stroke is the spectrum. The microphone is the only element: no glow, no shadow, no text, no other colour.
  - **Colours.** The stroke runs from `spectrum-1` to `spectrum-6` (red to violet, no indigo), top to bottom, blended smoothly as `Theme.Color.spectrum` blends them. The black is `bg` (`#000000`). `make-icon.swift` reads these seven values from DESIGN.md's front matter, so the icon follows the tokens. It stops with a message naming any value it cannot find.
  - **Shape.** Since macOS 26, the system puts an app icon on a grey plate when its pixels leave the system's icon shape (developer reports; Apple documents the shape only through Icon Composer). So the black is a rounded square on the standard macOS grid: 824 px wide, centred on the 1024 px canvas (100 px margin), with continuous corners of radius 185 (`RoundedRectangle(cornerRadius: 185, style: .continuous)`). The canvas is transparent outside it.
  - **The microphone.** A capsule head, a U-shaped holder below it, a stem and a base, centred, about 60% of the black square's height. One stroke width throughout, about 44 px at 1024, so it still reads at 32 px. Colour it by stroking the path, turning the stroke into a clip, and drawing the gradient from the top of the head to the base. Draw every size from the same paths at that size, never by shrinking the master.
  - **Files.**
    - The 1024 px master is the `512x512@2x` entry.
    - The appiconset holds the ten macOS entries (16, 32, 128, 256 and 512 pt at 1x and 2x), its `Contents.json`, and the catalog's own `Contents.json`.
    - `docs/icon-preview.png` shows the master beside the 256, 64, 32 and 16 px renders, on black and on mid-grey.
    - In `project.yml`, set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. `App/` is already a source folder, so the catalog is picked up.
  - **Run** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make-icon.swift`. Expected:
    - it lists the eleven PNGs it wrote;
    - `sips -g pixelWidth App/Assets.xcassets/AppIcon.appiconset/*.png` gives 16, 32, 32, 64, 128, 256, 256, 512, 512 and 1024, each matching its file name;
    - once the app is built, `plutil -extract CFBundleIconName raw <app>/Contents/Info.plist` prints `AppIcon`.
  - **DESIGN.md.** Under Components, add "**App icon:** black, and a microphone drawn as an outline whose stroke is the spectrum, the only element." Under Colors, after "appears exactly once per screen…", add that the app icon is its one use outside the window. Run `npx @google/design.md lint DESIGN.md` and fix what it reports.
  - **D7.** Write the preview's path into the notes file for Danny and go on to Step 2; the icon ships as rendered. If he asks for changes, change the script, render again and commit `fix: app icon after Danny's review`.
  - **Hands-on** (notes file): in the Dock and in Finder, the icon is its own black rounded square with no grey plate around it. If macOS puts it on a plate anyway, note it. The way out is an Icon Composer `.icon` file, which needs Danny's OK.
- [ ] **Step 2: Sparkle** (app target only, pinned `exact:`; read its documentation at that version). EdDSA key generated with Sparkle's tool and stored in the keychain, public key in `Info.plist`, `SUFeedURL` pointing at an appcast in the repo's GitHub releases; "Check for Updates…" in the menu bar menu; **automatic checks off** (`SUEnableAutomaticChecks` false, no first-launch permission prompt), so the app never contacts the network unless Danny asks. `release.sh` signs the zip and regenerates the appcast. Without a remote or D4, leave the feed URL as a clearly marked placeholder and note it; the app must run normally with no reachable feed.
- [ ] **Step 3:** Commit: `feat: app icon and Sparkle updates`.

### Task 27: whisper.cpp inside the app

Danny chose whisper with base.en as the default engine (D2, 2026-11-12), built into the app: no Homebrew, no subprocess. This task builds that engine and proves it gives exactly what whisper-cli gave. Task 27A makes it the default and removes whisper-cli.

**The route** (checked 2026-11-12):
- **Version.** Homebrew's whisper-cli here is whisper.cpp 1.9.5 (`whisper-cli --version`). The app pins the same release: tag `v1.9.5`, commit `d1be6fd`.
- **How it is built.** Upstream's prebuilt XCFramework goes into `Package.swift` as a binary target, pinned by URL and checksum. The `v1.9.5` release carries only source; its binaries sit on the build release `b5454`, which is the same commit. So there is no CMake step. Xcode, `swift test` and `vd-bench` all get whisper.cpp through SwiftPM.
- **What it contains** (v1.9.5's `build-xcframework.sh`): a dynamic `whisper.framework` for macOS 13.3 and later (arm64 and x86_64). Metal is on, with its shaders embedded (`GGML_METAL_EMBED_LIBRARY`); BLAS is on; Core ML is on with fallback; and it is unsigned.
- **Signing.** Xcode embeds the framework in `Contents/Frameworks` and signs it with the app's identity: Apple Development in Debug, Developer ID with a timestamp in `release.sh`'s archive and export. So library validation under the hardened runtime passes (same team), and notarisation checks the framework along with the app.
- **Hardened runtime.** It needs nothing new for Metal. With the shaders embedded, ggml compiles them at run time with `newLibraryWithSource:` (`ggml-metal-device.m`), through Metal's own compiler service, and nothing is loaded with `dlopen`. Homebrew's ggml loads its backends that way, as plug-ins; the XCFramework does not.
- **Why not `bundling-design.md`'s source build.** That design (2025) predates the XCFramework and was written for a bare SwiftPM binary with no signing. It stays the fallback if this route fails (Steps 2 and 6).

**The same decoding.** The app ran `whisper-cli -m <model> -f <wav> --no-timestamps --no-prints --suppress-nst --language en`, plus `--prompt "<words joined with ", ">"` when the vocabulary is not empty (`Transcriber.arguments`). Read from v1.9.5's `examples/cli/cli.cpp`, that is:
- **Context:** `whisper_context_default_params()`, opened with `whisper_init_from_file_with_params`. Its values are the ones cli.cpp passes: GPU on, flash attention on, device 0, no DTW.
- **Decoding:** start from `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`, as cli.cpp does, then set:
  - strategy `WHISPER_SAMPLING_BEAM_SEARCH` (cli.cpp switches to it because its beam size, 5, is above 1);
  - `beam_search.beam_size` 5 and `greedy.best_of` 5 (the temperature fallback samples with best-of decoders);
  - temperature 0.0, `temperature_inc` 0.2, `entropy_thold` 2.4, `logprob_thold` -1.0, `no_speech_thold` 0.6;
  - `language` "en", `translate` false, `detect_language` false, `no_timestamps` true, `suppress_nst` true;
  - `initial_prompt` the vocabulary joined with ", ", or "" when it is empty (cli.cpp passes an empty string, not null); `carry_initial_prompt` false;
  - every `print_*` false, `token_timestamps` false, `max_len` 0, `audio_ctx` 0, `offset_ms` 0, `duration_ms` 0;
  - `no_context` (true), `n_threads` and `n_max_text_ctx` left at their defaults, because cli.cpp leaves them alone or sets the same values.
- **One call per clip:** one `whisper_full`. cli.cpp's `whisper_full_parallel` with one processor returns exactly that call.
- **Text:** the segments' texts joined with nothing between, as cli.cpp prints them without timestamps. The service's `OutputFilter.clean` then does what it did to whisper-cli's output.
- **Audio:** whisper-cli read the 16-bit WAV that `AudioClip.writeWAV` wrote, so the engine rounds the clip's samples to 16 bits the same way first.
- **Repeated calls** decode like fresh processes. On every call, `whisper_full` re-seeds its samplers and, with `no_context`, clears the previous text (v1.9.5's `src/whisper.cpp`).

**Files:** Modify `Package.swift`, `Core/ModelID.swift`, `Sources/VDBench/main.swift`, `Sources/VoiceDictationUI/AppModel.swift`, `Window/ModelsView.swift`, `Tests/VoiceDictationUITests/ModelsModelTests.swift`. Create `Engine/WhisperCppEngine.swift`, `Engine/GGMLModel.swift`, `Tests/VoiceDictationTests/WhisperCppEngineTests.swift`, `Tests/VoiceDictationTests/WhisperCLIGoldenRecorder.swift` (Task 27A deletes it), and `whisper-cli-base.en-sample.txt`, `whisper-cli-base.en-sample-vocabulary.txt`, `whisper-cli-base.en-sample-40s.txt` in `Tests/VoiceDictationTests/Resources/golden/`.

**Produces:**
```swift
public enum EngineKind: String, Codable, Sendable, CaseIterable { case appleSpeech, whisperKit, whisperCLI, whisperCpp }
extension ModelID { public static let whisperCppBase = ModelID(engine: .whisperCpp, name: "base.en") }  // Task 27A's default (D2)

/// The ggml files on Hugging Face (`ggerganov/whisper.cpp`, branch main; sizes and SHA-256 read 2026-11-12).
public struct GGMLModel: Sendable, Equatable {
    public let name: String; public let fileName: String; public let displayName: String; public let detail: String
    public let bytes: Int64; public let sha256: String
    public var url: URL { get }              // https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<fileName>
    public static let all: [GGMLModel]       // tiny.en, base.en, small.en
}

public actor WhisperCppEngine: TranscriptionEngine {
    public init(directory: URL)              // the app and vd-bench pass ~/Library/Application Support/VoiceDictation/models/
    static func contextParams() -> whisper_context_params
    static func fullParams(prompt: UnsafePointer<CChar>, language: UnsafePointer<CChar>) -> whisper_full_params
    static func prompt(for vocabulary: [String]) -> String     // joined with ", "; "" when empty
    static func whisperInput(_ samples: [Float]) -> [Float]    // the samples whisper-cli read back from the 16-bit WAV
    var loadedModels: Set<ModelID> { get }
}
```

| `name` | `fileName` | `bytes` | `sha256` | `displayName` | `detail` |
|---|---|---|---|---|---|
| tiny.en | ggml-tiny.en.bin | 77704715 | 921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f | whisper.cpp tiny.en | 78 MB download — fastest, lower accuracy |
| base.en | ggml-base.en.bin | 147964211 | a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002 | whisper.cpp base.en | 148 MB download — good balance |
| small.en | ggml-small.en.bin | 487614201 | c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d | whisper.cpp small.en | 488 MB download — more accurate, slower |

These are the three files the old engine listed, in the same folder, where the old app also kept its model. Danny's `ggml-base.en.bin` on this laptop is 147,964,211 bytes with the SHA-256 above, so it is used as it is. A Mac that ran the old app already has the file.

A model's state:
- `.ready` when its file is there at exactly `bytes`, or the model is loaded;
- `.preparing` while `prepare` loads it;
- `.notDownloaded` otherwise.

`bytesOnDisk` comes from the file.

- [ ] **Step 1: Record what whisper-cli says, before any engine code.**
  - Run `whisper-cli --version`. Expected: `whisper.cpp version: 1.9.5`. If it is anything else, stop and leave a note: the pin below must be that version.
  - `WhisperCLIGoldenRecorder.testRecordGolden` skips unless three things hold:
    - `VD_RECORD_WHISPER_GOLDEN=1` is set;
    - `Transcriber.findBinaryPath()` is non-nil;
    - `ggml-base.en.bin` is in the models folder.
  - It runs today's `WhisperCLIEngine` with `ModelID(engine: .whisperCLI, name: "base.en")` on three clips. It writes each result into `Tests/VoiceDictationTests/Resources/golden/` (found from `#filePath`) exactly, with no newline added:
    - `whisper-cli-base.en-sample.txt`: `sample.wav`, no vocabulary;
    - `whisper-cli-base.en-sample-vocabulary.txt`: `sample.wav` with vocabulary `["Quick Brown Fox", "Lazy Dog"]` (the `--prompt` path);
    - `whisper-cli-base.en-sample-40s.txt`: `sample.wav`'s samples repeated 15 times, about 40 s, two of whisper's 30 s windows.
  - Run `VD_RECORD_WHISPER_GOLDEN=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WhisperCLIGoldenRecorder`. Expected:
    - `Executed 1 test, with 0 failures`;
    - `git status` lists the three files;
    - the first file contains "quick brown fox".
  - Commit: `test: record whisper-cli base.en's text for the golden test`.
- [ ] **Step 2: Add whisper.cpp.**
  - In `Package.swift`, add the binary target below, and add `"whisper"` to the dependencies of `VoiceDictationLib` and of `VoiceDictationTests`. The tests read the C types.
    ```swift
    // whisper.cpp v1.9.5 (commit d1be6fd), the version of the whisper-cli Danny
    // chose (D2), built by upstream from that commit as release b5454. Do not
    // bump it without recording Task 27's golden text again.
    .binaryTarget(
        name: "whisper",
        url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
        checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
    ),
    ```
  - First test, `testLinksWhisperCpp195`: `String(cString: whisper_version()) == "1.9.5"`.
  - Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter WhisperCppEngineTests/testLinksWhisperCpp195`. Expected: SwiftPM fetches the zip once and checks its checksum, then `Executed 1 test, with 0 failures`.
  - If SwiftPM reports a checksum mismatch, or the test process cannot load `whisper.framework`, stop and leave a note (Note 9). The fallback is `bundling-design.md`'s Approach 1, a source build, and the controller decides on it.
- [ ] **Step 3: Failing tests** in `WhisperCppEngineTests`. The tests that need the real model skip unless `ggml-base.en.bin` is in the app's models folder, naming the path in the message, as `WhisperKitEngineTests` skips without tiny.en.
  - **Models and the catalog:**
    - `testOffersThreeModels`: in an empty folder the ids are `whisperCpp/tiny.en`, `whisperCpp/base.en` and `whisperCpp/small.en`, each `.notDownloaded`. A file of exactly 147,964,211 bytes (made sparse with `FileHandle.truncate(atOffset:)`) makes base.en `.ready` with `bytesOnDisk == 147_964_211`. One byte short reads `.notDownloaded`.
    - `testCatalogMatchesHuggingFace`: the three rows in the table above, exactly, URLs included.
  - **Before loading:**
    - `testTranscribeWithoutModelThrowsModelNotReady`.
    - `testEmptyClipGivesNoTextWithoutLoading`: `""`, and `loadedModels` stays empty.
  - **Matching whisper-cli's settings:**
    - `testContextParamsMatchWhisperCLI`: `use_gpu` true, `flash_attn` true, `gpu_device` 0, `dtw_token_timestamps` false.
    - `testFullParamsMatchWhisperCLI`:
      - strategy `WHISPER_SAMPLING_BEAM_SEARCH`, `beam_search.beam_size` 5, `greedy.best_of` 5;
      - `temperature` 0, `temperature_inc` 0.2, `entropy_thold` 2.4, `logprob_thold` -1, `no_speech_thold` 0.6;
      - `no_timestamps` true, `suppress_nst` true, `no_context` true;
      - `translate`, `detect_language`, `carry_initial_prompt`, `token_timestamps` and `single_segment` all false;
      - `max_len`, `audio_ctx`, `offset_ms` and `duration_ms` all 0, and all four `print_*` false;
      - `n_threads` and `n_max_text_ctx` equal to `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`'s;
      - `language` "en", and `initial_prompt` the string passed in.
    - `testPromptJoinsVocabularyAsWhisperCLIDid`: `["Tailscale", "GV70"]` gives `"Tailscale, GV70"`; `[]` gives `""`.
    - `testInputIsRoundedTo16BitsAsTheWAVWas`: for the samples `[0.123456789, -0.5, 0.99999, 1.2, -1.3, 0.00001, -0.00001]`, `whisperInput` equals what `writeWAV` writes, read back as Int16 and turned into floats the way whisper-cli's reader does. That reader is miniaudio, asked for `ma_format_f32` in `examples/common-whisper.cpp`; read its 16-bit-to-float conversion in v1.9.5's `examples/miniaudio.h` before writing the test (expected: × 1/32768).
  - **The golden text:**
    - `testMatchesWhisperCLIOnSample`, `testMatchesWhisperCLIWithVocabulary`, `testMatchesWhisperCLIAcrossTwoWindows`: `OutputFilter.clean(text)` equals the golden file exactly, the same characters and not just the same words.
    - `testSameTextTwice`: the sample, twice, on one loaded engine gives the same text both times.
  - **Cancellation and unloading:**
    - `testCancellationStopsPromptly`: two minutes of speech (`sample.wav` × 45); cancel after 100 ms. Expect `CancellationError` within 1 s, after which the sample still transcribes to its golden text.
    - `testUnloadDuringTranscriptionIsSafe`: start the 40 s clip and call `unload()` after 50 ms. The transcription still returns the golden text, and afterwards `loadedModels` is empty.
    - `testPrepareReportsPreparing`: with a test loader that waits 200 ms and then fails, `models()` reports base.en `.preparing` while it waits, and `prepare` throws `.modelNotReady`.
    - `testDecodeStopsAtItsDeadline`: with an injected deadline of 0.1 s, the 40 s clip throws the CLI path's timeout error within 1 s.

  Run them; expect failures (types missing). `testLinksWhisperCpp195` passes already.
- [ ] **Step 4: Implement.** Read v1.9.5's `include/whisper.h` and `examples/cli/cli.cpp` first (Note 3); the settings above come from them. Shape:
  - **`WhisperContext`:** a small final class that owns one `whisper_context` and calls `whisper_free` in `deinit`. A transcription in flight holds its own reference, so `unload()` never frees a context in use.
  - **Threads:** loads and decodes run on a global dispatch queue reached through a continuation, never on a Swift concurrency thread. Three things keep any context from being used by two calls at once:
    - a context is published only after its warm-up;
    - the service never runs two transcriptions at once;
    - a context is freed only when nothing holds it.

    A load for a re-transcription never holds up a dictation's decode (Task 8).
  - **`prepare`:** loads with `whisper_init_from_file_with_params(path, contextParams())` and reports `.preparing` meanwhile. As in `WhisperKitEngine`, loads in flight are shared, and preparing one model never evicts another. It then decodes one second of silence and throws the text away, so Metal builds its pipelines before the first dictation instead of during it.
  - **`transcribe`:** keeps the prompt and `"en"` as C strings for the length of the call, and calls `whisper_full` with `fullParams` on `whisperInput(clip.samples)`. It joins `whisper_full_get_segment_text` over every segment with nothing between. A non-zero result throws `.failed("<display name> failed (whisper.cpp error <n>)")`.
  - **Cancellation:**
    - `withTaskCancellationHandler` sets a lock-protected flag.
    - `abort_callback` returns the flag. whisper.cpp checks it after the encoder and after every decoder step, and v1.9.5 then returns -6, -8 or -9.
    - `encoder_begin_callback` returns its negation. That path returns 0, with the text decoded so far.
    - After `whisper_full` returns, a set flag throws `CancellationError` whatever the result.
  - **Timeout:** keep whisper-cli's limit.
    - Use the formula in `Transcriber.calculateTimeout(recordingDuration:)`; read it. Move it into the engine, since Task 27A deletes `Transcriber`.
    - The abort callback also returns true once that deadline passes.
    - Report it with the same error and message the CLI path gave on a timeout; read `WhisperRun.swift`.
    - A deadline that passes is not a cancellation, so it never throws `CancellationError`.
  - **Logs:** `whisper_log_set` sends whisper's and ggml's lines nowhere, except errors, which go to `Log.info` as `[WHISPER] …`. Drop the error every load prints because the XCFramework is built with Core ML ("failed to load Core ML model from '…-encoder.mlmodelc'"). whisper then uses its own encoder, as whisper-cli does.
  - **`download`** throws `.failed("whisper.cpp models cannot be downloaded yet")` until Task 27A.
  - **`delete`** refuses while the model loads, drops it from the loaded models and removes its file. Until Task 27A the old engine reads the same files, so deleting a whisper.cpp model also deletes the whisper-cli model of that name.
  - **`unload`** drops every loaded model. One still transcribing is freed when it finishes.
- [ ] **Step 5:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Expected: `Executed N tests, with 0 failures`, with the golden tests run, not skipped: base.en is on this Mac, so a skip here counts as a failure. Say so in the notes if one skipped.
  - If a golden case differs from whisper-cli's text:
    - put both texts in the notes file (it is the test sample, not Danny's dictation);
    - record that golden file again from the in-app engine, with a comment naming the ggml difference;
    - go on.
  - The settings tests still pin whisper-cli's decoding, and the golden tests then guard later whisper.cpp bumps.
- [ ] **Step 6: In the app and vd-bench.**
  - Add `WhisperCppEngine(directory: <data dir>/models)` to `AppModel.engines()` after WhisperKit and before whisper-cli, and to vd-bench's list.
  - `ModelsView.sections` lists `.whisperCpp` after WhisperKit; whisper-cli stays last under "Previous engine" until Task 27A. Update `testSectionsKeepApplesFirstThenWhisperKitThenThePreviousEngine` to that order.
  - Run vd-bench on Danny's archive. The report goes outside git, because it holds his dictated text: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run vd-bench --from-archive --output .superpowers/sdd/2026-11-11-native-app/engine-comparison-task27.md`. Expected: a `LOAD whisperCpp/base.en: …` line, one line per clip and model, then `Wrote …`.
  - For every clip, compare whisperCpp/base.en's text with whisperCLI/base.en's. They are expected to match (see the last bullet).
  - Record in the notes file, with no dictated text:
    - the number of clips and how many differ (expected 0);
    - both models' median seconds and seconds per second of audio (whisper-cli base.en was 0.34 s and 0.036 s/s in the D1 rerun).
  - If any clip differs, note the clip names and the number of differing words per clip in the notes file, with no dictated text, and go on. Danny accepted on 2026-11-12 that the same whisper.cpp release, the same base.en weights and the same settings are good enough. The likely cause is ggml: 0.26.0 in the XCFramework against 0.28.0 under Homebrew's whisper-cli.
- [ ] **Step 7: The app bundle** (built, not launched; Ruling P2).
  - `xcodegen && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme VoiceDictation -configuration Debug -derivedDataPath .build/xcode build` prints `** BUILD SUCCEEDED **`.
  - `.build/xcode/Build/Products/Debug/VoiceDictation.app/Contents/Frameworks/whisper.framework` exists.
  - `codesign -dv --verbose=2` on it shows `TeamIdentifier=F7DL4CTLLL`. That is the app's team, so library validation passes under the hardened runtime.
  - `codesign --verify --deep --strict --verbose=2` on the app prints `valid on disk` and `satisfies its Designated Requirement`.
  - Hands-on for Danny (notes file):
    - choose "whisper.cpp base.en" in the menu bar's Model submenu and dictate a sentence with a technical word; it pastes what whisper-cli base.en pastes for the same sentence;
    - the first dictation after launch has no long pause;
    - Escape while it says Transcribing cancels;
    - Activity Monitor shows no `whisper-cli` process;
    - the next `./scripts/release.sh` notarises the framework with the app: expect `Accepted`.
  - Commit: `feat: whisper.cpp inside the app, matched to whisper-cli`.

### Task 27A: whisper as the default

The app's own whisper.cpp becomes the default, and whisper-cli goes: its engine, the code that found and ran it, the old downloader, and the old install and packaging scripts. Danny has confirmed nobody else uses the app, so the scripts go without a migration path.

**Files:** Create `Engine/GGMLDownload.swift`, `Tests/VoiceDictationTests/GGMLDownloadTests.swift`. Modify:
- engine and app: `Engine/WhisperCppEngine.swift`, `Core/ModelID.swift` (a comment on the retired kind), `PreferencesManager.swift`, `Store/HistoryImporter.swift` (a comment), `Sources/VDBench/main.swift`, `Sources/VoiceDictationUI/AppModel.swift`, `MenuBar/MenuBarContent.swift`, `Window/ModelsView.swift`, `Window/LibraryModel.swift`;
- tests: `Tests/VoiceDictationTests/WhisperCppEngineTests.swift`, `TranscriptionServiceTests.swift`, `OutputFilterTests.swift`, `EndToEndTests.swift`, and in `Tests/VoiceDictationUITests/`: `OnboardingModelTests.swift`, `MenuBarContentTests.swift`, `ModelsModelTests.swift`, `LibraryModelTests.swift`;
- docs: `README.md`, `CLAUDE.md`, `AGENTS.md`, `~/CodingProjects/CLAUDE.md` (projects table row).

Delete:
- `Engine/WhisperCLIEngine.swift`, `WhisperRun.swift`, `Transcriber.swift`, `BundledBinary.swift`, `ModelManager.swift`;
- `Tests/VoiceDictationTests/TranscriberTests.swift`, `BundledBinaryTests.swift`, `ModelManagerTests.swift`, `WhisperCLIGoldenRecorder.swift`;
- `scripts/bundle-whisper.sh`, `scripts/create-package.sh`, `scripts/install.sh`, `docs/install-instructions.txt`.

**Produces:**
```swift
public enum GGMLDownload {
    /// Fetches `model.url` into `directory` as `<fileName>.partial`, reporting 0…1 as bytes arrive. Then it checks
    /// the HTTP status, the size and the SHA-256 against the catalog and renames the file to `<fileName>`. A failure
    /// or a cancellation leaves neither file behind. It never retries: the row shows the failure.
    public static func fetch(_ model: GGMLModel, into directory: URL, session: URLSession = .shared,
                             progress: @escaping @Sendable (Double) -> Void) async throws
}
// PreferencesManager: replaces selectedModelID(saved:legacy:)
static func selectedModelID(saved: String?) -> ModelID
```
- `WhisperCppEngine.download` uses `GGMLDownload`. Tests pass a fake fetcher, as `WhisperKitEngine`'s tests do. `models()` reports `.downloading(fraction)` while it runs.
- Hugging Face URLs use branch `main` (no tag is checked). The SHA-256 check means a file changed upstream fails the download instead of changing the weights.
- `EngineKind.whisperCLI` stays as a retired kind that no engine runs. Old transcripts carry it, and so does the old app's `history.json`, which `HistoryImporter` has yet to import on the Mac mini. `TranscriptionService` already answers it with "No engine runs whisperCLI/…".

- [ ] **Step 1: Failing tests.**
  - `GGMLDownloadTests`. A `URLProtocol` stub serves each response, so there is no network.
    - `testDownloadReportsProgressAndInstallsTheFile`: a 300 kB body in three chunks, for a test catalog entry whose `bytes` and `sha256` match it. Progress rises and ends at 1, `<fileName>` holds the body, and no `.partial` is left.
    - `testWrongChecksumLeavesNothing`: throws `.failed` naming the checksum; neither file exists.
    - `testHTTPErrorLeavesNothing`: a 404 throws `.failed` containing "HTTP 404"; neither file exists.
    - `testCancelLeavesNothing`: cancel after the first chunk; `CancellationError`, not `URLError`; neither file exists.
    - `testCatalogUsesMainBranch`: every URL is `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<fileName>`.
  - `WhisperCppEngineTests`:
    - `testDownloadShowsProgressThenReady`: with a fake fetcher, `.downloading(0.5)` while it runs and `.ready` after.
    - `testDownloadOfAPresentModelReturnsAtOnce`: progress 1, and the fetcher is not called.
    - `testDeleteWhileDownloadingIsRefused`.
    - `testPrepareWhileDownloadingIsRefused`: `.modelNotReady`.
  - `TranscriptionServiceTests`, replacing the three saved-selection tests:
    - `testSelectedModelIDDefaultsToWhisperCppBase`: nil and `"garbage"` give `.whisperCppBase`.
    - `testSelectedModelIDMovesWhisperCLIChoicesToWhisperCppBase`: `"whisperCLI/tiny.en"`, `"whisperCLI/base.en"` and `"whisperCLI/small.en"` give `.whisperCppBase`.
    - `testSelectedModelIDKeepsOtherChoices`: `"appleSpeech/en-US"`, `"whisperKit/base.en"` and `"whisperCpp/small.en"` come back unchanged.
    - `testSelectedModelIDIsSavedAsItsStorageKey`: the old app's `selectedModel` key alone no longer counts and gives `.whisperCppBase`. After setting WhisperKit base.en, the store holds `"whisperKit/base.en"`.
  - `OnboardingModelTests.testSpeechModelStepDownloadsWhisperCppBase`:
    - with `.whisperCppBase` selected and `.notDownloaded`, the step is `.needed` with the action "Download whisper.cpp base.en";
    - `downloadSelectedModel()` asks the service for `.whisperCppBase`;
    - at 0.42 the detail reads "Downloading… 42%";
    - once the model is `.ready`, the step is `.done` with "whisper.cpp base.en is ready.".
  - `MenuBarContentTests.testModelsAreGroupedByEngineWithNoHeadings` and `ModelsModelTests.testSectionsPutWhisperCppFirst`, replacing the two "Previous engine" tests: sections `[.whisperCpp, .appleSpeech, .whisperKit]`, with no header or title.
  - `LibraryModelTests.testRetiredWhisperCLIModelReadsAsWords`: `modelName("whisperCLI/base.en", in: [])` gives `"whisper-cli base.en"`.
  - `EndToEndTests.testSampleFlowsFromClipToStoreWithWhisperCppBase`: Task 25's test run with `WhisperCppEngine` and `.whisperCppBase`. It skips unless base.en is on the Mac.
- [ ] **Step 2: Implement.**
  - **`GGMLDownload`:**
    - It uses a download task and reports progress as bytes arrive. Read the URLSession interface in the SDK; do not guess which callback carries progress.
    - It moves the finished file into the models folder as `<fileName>.partial`, hashes it in 1 MB chunks with CryptoKit's `SHA256`, and renames it.
    - It removes a stale `.partial` before it starts.
    - A cancelled task throws `CancellationError`.
  - **Preferences:**
    - `selectedModelID` is the saved choice when it names an engine that still runs. A saved `whisperCLI/…` choice, an unreadable one, or none at all gives `.whisperCppBase`.
    - Delete `WhisperModel`, `selectedModelId`, `selectedModel` and the `selectedModel` key. `PreferencesMigrator` keeps copying old keys (Ruling P6).
  - **Engines:**
    - `AppModel.engines()` becomes `WhisperCppEngine`, `AppleSpeechEngine`, `WhisperKitEngine`, in that order, so the default comes first in the menu and the Models section.
    - vd-bench drops `WhisperCLIEngine()`.
  - **Headings and names:**
    - `MenuBarContent.ModelSection.header` and `ModelsView.Group.title` go, with their "Previous engine" comments. `ModelsView.sections` uses the new order.
    - In `LibraryModel.modelName`, a key that no model matches and that starts `whisperCLI/` reads `whisper-cli <name>`.
    - `HistoryImporter` keeps `ModelID(engine: .whisperCLI, …)`; add a comment saying why.
  - **The golden tests** stay. They now run with no whisper-cli anywhere, and they guard any later whisper.cpp bump.
- [ ] **Step 3: Delete** the files listed above.
  - `grep -rnE "WhisperCLIEngine|WhisperRun|BundledBinary|ModelManager|Transcriber\.|findWhisperCLI|bundle-whisper|create-package|install\.sh" Sources Tests scripts` returns nothing.
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` gives `Executed N tests, with 0 failures`, with the golden tests run.
- [ ] **Step 4: Docs**, in Danny's style: short, story-driven, no granular breakdowns.
  - **README:** says what the app is, how to install it, how to dictate, and what stays on the machine. Carry in what the build left for this rewrite (notes file):
    - building needs Xcode and XcodeGen (`brew install xcodegen`, D9);
    - the speech model downloads only when Danny presses Download in the Welcome window's Speech model step (whisper.cpp base.en, 148 MB), never by itself;
    - Escape cancels while recording, transcribing or cleaning up;
    - hold the hotkey to dictate, or double-tap it with "Double-tap to dictate" on.
  - **`CLAUDE.md`:**
    - gets the new architecture diagram;
    - gets the commands: `run-dev.sh`, the `DEVELOPER_DIR` test command, `release.sh`;
    - gets the constraints: macOS 26, Apple Intelligence for cleanup, never start the mic engine when idle, never the cloud model, whisper.cpp pinned at v1.9.5 with its golden test, models in `~/Library/Application Support/VoiceDictation/models/`;
    - loses the whisper-cli material and the hard-coded `/Users/dannygross/...` paths (use `~/`).
    - points to `docs/feature-requests.md`, Danny's backlog of ideas not yet planned.
  - **`AGENTS.md`:** keep it in step with `CLAUDE.md` (Task 1).
  - **`~/CodingProjects/CLAUDE.md`:** update the Voice Dictation row.
- [ ] **Step 5: Last checks.**
  - `grep -rn "brew install whisper\|whisper-cpp\|bundle-whisper" README.md CLAUDE.md AGENTS.md` returns nothing.
  - `xcodegen && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme VoiceDictation -configuration Debug -derivedDataPath .build/xcode build` prints `** BUILD SUCCEEDED **`.
  - Hands-on for Danny (notes file):
    - after `./scripts/run-dev.sh`, the Model submenu lists whisper.cpp base.en first and checked, with no "Previous engine" group, and dictation pastes;
    - in the Models section, Download whisper.cpp tiny.en shows "Downloading N%" and then "Ready", Cancel part-way leaves no `.partial` file in the models folder, and Delete removes it;
    - with Wi-Fi off, dictation still works;
    - on the Mac mini after installing a release: base.en is already there (the old app's file), the history imports, and old transcripts name their model "whisper-cli base.en";
    - if he wants, `brew uninstall whisper-cpp` on both Macs; nothing uses it now.
  - Commit: `feat: whisper.cpp base.en is the default; whisper-cli retired`.

### Task 28: A simplified view (design first)

Added 2026-11-12 at Danny's request: a "simplified" view of the app itself that creates a minimalist view. Nothing about it is designed yet. This plan decides nothing about what it shows, where it lives or how it is reached. The build stops before this task (D11).

**Files:** decided by the design.

- [ ] **Step 1: Design session with Danny** (D11), before any code. First brainstorm it with him (superpowers:brainstorming), then make mockups for him to choose from and approve. Record what he approves in the spec, `docs/superpowers/specs/2026-11-11-native-app-design.md`.
- [ ] **Step 2: Plan it.** Replace this placeholder with the real task, written from the approved design: Files, Produces, failing tests with exact values, commands with expected output, and a commit message. Have the plan change reviewed like any other. Commit: `docs: plan Task 28 from the simplified-view design`.
- [ ] **Step 3:** Build it from those steps.
---

## Done means

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passes with no skipped test that could have run on this machine.
- `./scripts/run-dev.sh` builds and launches the app; dictation works with the window closed.
- The notes file lists every hands-on check that was and was not performed, and every item still waiting on Danny.
- Nothing was pushed.
- Task 28 has not started: it waits on its design session (D11).
