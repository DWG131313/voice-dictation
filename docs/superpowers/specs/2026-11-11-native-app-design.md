# VoiceDictation: the native app

**Date:** 2026-11-11
**Status:** Design, awaiting Danny's approval. Nothing here is built yet.
**Replaces as the forward plan:** `future-features.md` and `bundling-design.md` (both stay for history).

## Why

VoiceDictation works. You hold the Globe key, speak, let go, and the text lands in whatever app you were using. But it is a menu bar utility wrapped around a command-line tool, and that shape now limits it in three ways.

1. **It is slower than it needs to be.** Every dictation starts a fresh `whisper-cli` process, which reloads a 148 MB model and sets up the GPU again before it can listen to a single word. The one timing in the log is 1.3 seconds to transcribe 2.5 seconds of speech.
2. **There is nowhere to look at your work.** Transcripts live in a 20-item menu. You cannot search them, replay them, or see what a different model would have made of the same audio.
3. **It is not really an app.** There is no signed bundle, so macOS keeps forgetting its permissions; settings are a hand-positioned panel with two controls; first run is a chain of alert boxes.

This design turns it into a full native macOS app that is faster, has a real window, and lets Danny choose and compare speech models, while keeping the one promise that matters: **nothing leaves the machine.**

## What Danny decided

These came from Danny directly and are not open for the builder to change.

- **Engine:** Apple's on-device speech framework is the default. WhisperKit models are selectable alongside it. If Apple's engine turns out worse than WhisperKit on quality or speed, the default changes.
- **A real window** that he can interact with, where transcripts load automatically as they happen and can be reviewed.
- **Model switching** inside the app.
- **Look:** the Prism direction from his design library (see "Look and feel").
- **Floating indicator:** "Listening", a sharp-cornered line that scrolls right to left and whose height follows his volume, a timer, and "esc to cancel". No prism/triangle graphic.
- **Cleanup with a language model is in the first version**, and does exactly three things: removes filler words, fixes punctuation, fixes capitalisation.
- **Live text while speaking is out** of the first version.
- **Transcripts are editable** in the window.
- **Only Danny uses the app**, on his two Macs.

## Goals

- Dictation feels immediate: the model stays loaded, audio stays in memory, and the microphone is ready the instant the key goes down.
- Every dictation is kept, searchable, and reviewable in a proper window.
- Any transcript can be re-run through another model and compared, so the "which engine is better" question is answered by Danny's own voice.
- Transcripts arrive cleaned of fillers, with correct punctuation and capitalisation, and the original is always recoverable.
- The app installs like an app: signed, notarised, keeps its permissions across updates, opens at login.
- Fully offline. No account, no network calls except downloading a model the user picked.

## Non-goals (not in the first version)

- Live text appearing while speaking.
- Rewriting, summarising, or changing wording during cleanup.
- Per-app behaviour (different rules for Terminal vs Mail).
- Languages other than English.
- Mac App Store distribution. (The app has to simulate Cmd+V into other apps, which the App Store sandbox is not expected to allow. The builder should confirm this once and move on.)
- Supporting macOS older than 26.

## Anti-goals (would make this a failure even if it works)

- Any audio or text sent to a server.
- Cleanup that changes what Danny said. A cleaned transcript that reads better but means something different is worse than the raw one.
- A slower key-release-to-paste time than today for an ordinary sentence with cleanup off. With cleanup on (the default), cleanup may add up to its time limit before the paste; that trade is accepted because Danny asked for cleaned text in the first version. *(Confirmed by Danny.)*
- Losing the "it just works with the window closed" quality. The window is somewhere to review; dictation must never depend on it being open.
- Design that drifts from Prism: colour used as decoration, glows, rounded cards.

## The app, as Danny will see it

### Dictating (unchanged in spirit)

Hold the hotkey, speak, release. Text is pasted into the frontmost app. The window does not need to be open and does not come forward.

While the key is held, a small floating indicator appears near the bottom centre of the screen (position is the builder's call; it must not take focus):

```
┌──────────────────────────────────────────────────┐
│ Listening   ─╱╲─╱╲╱╲──╱╲─   0:06   esc to cancel │
└──────────────────────────────────────────────────┘
```

- Black, 1px dark hairline border, square corners, white text.
- The line is 1px white, drawn as straight segments with hard (mitred) corners. A new point enters on the right roughly twenty times a second and travels left at a steady speed; points alternate above and below the centre. About two seconds of history is visible.
- Height follows loudness continuously (no on/off threshold): a small floor removes room hiss, a gentle curve keeps quiet speech visible, and it rises faster than it falls so it does not flicker. Silence settles to a flat line.
- With macOS "Reduce Motion" on, the line holds flat and only the words and timer change.
- After release it reads "Transcribing", then "Cleaning up" if cleanup is on, then disappears. Escape cancels at any of these stages (today it only cancels while recording).
- Working browser prototype of the motion: `.superpowers/brainstorm/30815-1794455251/content/prism-live-line-fluid.html`. Match its feel; the constants in it are a starting point, not a spec.

### The window

Three columns, as in the approved mockup (`.superpowers/brainstorm/30815-1794455251/content/main-window-six-directions.html`, option D):

- **Left, sections:** All transcripts, Today, Pinned; then Models, Vocabulary, Settings. At the bottom, the current model and the hotkey reminder.
- **Middle, transcript list:** search field on top. Each row shows the app the text was pasted into, the time, the length of the recording, and the first two lines. Newest first. A new dictation appears at the top by itself, without stealing selection if Danny is reading another one.
- **Right, the selected transcript:** title (app and time), a status word (Pasted, Copied, Failed), four facts (length, time to transcribe, model, word count), the text, and actions: Copy, Paste again, Play audio, Re-transcribe with…, Pin, Delete.
- **Under the transcript, comparison:** when a transcript has been run through more than one model, the results sit side by side with the time each took and the differing words marked. "Use this one" makes a result the transcript's main text.
- **Raw vs cleaned:** when cleanup changed the text, a toggle shows the raw version and "Revert to raw" makes it the main text.

**Models section:** one row per model: Apple Speech, then the WhisperKit models (builder picks a sensible short list from small to large-v3-turbo). Each shows size on disk, whether it is downloaded, a Download/Delete button with progress, and "Use for dictation". Apple Speech shows whether the system has its language assets installed and offers to install them.

**Vocabulary section:** a list of words and names the engines should favour (Tailscale, Vercel, people's names), and a list of replacements ("gv seventy" → "GV70") applied after transcription.

**Settings section:** hotkey; hands-free lock on/off; cleanup on/off; how many recordings to keep; microphone; start/stop sounds; open at login; where data lives, with a "Reveal in Finder" button.

### Menu bar

The icon stays and shows the same states as today (ready, recording, working, needs attention). Its menu is short: status line, Open VoiceDictation, Paste last transcript, the current model as a submenu to switch, Settings, Quit. Closing the window does not quit the app. Whether the app also shows in the Dock while the window is open is the builder's call; it must never take focus away from the app being dictated into.

### First run

One onboarding window instead of alert boxes: what the app does, then Microphone, Accessibility, and the Globe key setting, each with its current state and a button that opens the right System Settings pane. It updates live as each is granted and finishes on a "try it" step.

## Look and feel

Direction: **Prism** (`~/CodingProjects/design-reference/design-directions/prism.md`). The rules that matter here:

- Black ground, white text, dark only. Radius 0. No shadows, no glows. Regions are separated by a slightly lighter black and 1px hairlines.
- **Colour is refracted, never painted.** The six-band spectrum appears exactly once per screen. In the window it is the 2px underline beneath the selected transcript row. That is the signature move.
- Status is carried by words, not colour. Differences in a comparison are underlined, not tinted.
- Type: Jost for the one title per screen, Work Sans for interface text, DM Mono for times and figures. Fonts are bundled in the app (all three are open-licensed).
- Buttons: primary is white with black text; secondary is a 1px white outline.
- The floating indicator carries no colour at all, so the once-per-screen rule holds whether or not the window is open.

A `DESIGN.md` at the project root holds the exact tokens and is authoritative. In code they become one `Theme.swift`, as in the Continue? project. Standard macOS behaviour (window frame, traffic lights, keyboard navigation, focus rings, VoiceOver labels) is kept; Prism styles the content, not the operating system.

## How it works underneath

### One pipeline, swappable parts

```
Hotkey → Recorder → Engine → Vocabulary replacements → Cleanup → Paste
                       │                                  │
                       └────────── Transcript store ──────┘
                                 (text, raw text, audio, timings)
```

Each stage sits behind a small Swift protocol so it can be tested alone and swapped:

- **`TranscriptionEngine`**: given audio samples and a vocabulary list, returns text and how long it took. Two implementations: `AppleSpeechEngine` and `WhisperKitEngine`. A model is identified by engine plus model name, so the model picker is just a list of these.
- **`TextCleaner`**: given raw text, returns cleaned text. One implementation on Apple's on-device language model; a pass-through when cleanup is off or unavailable.
- **`TranscriptStore`**: saves and queries transcripts and their audio.

The existing delegate-callback style moves to Swift concurrency (`async`/`await`, actors for the recorder and engines) as each piece is rewritten. `whisper-cli`, `BundledBinary`, `ModelManager`'s download code, `bundle-whisper.sh` and the `whisper-cpp` Homebrew dependency all go away once the new engines pass their gate.

### Engines

- **Apple Speech** uses the on-device `SpeechAnalyzer`/`SpeechTranscriber` API (macOS 26+). The system manages its model. Vocabulary is passed as contextual strings if the API supports it for this transcriber; if not, replacements still apply.
- **WhisperKit** (Swift package from Argmax, Core ML) provides the downloadable models. Vocabulary is passed as the prompt. First use of each model compiles it, which can take a while; the Models screen shows that as a "Preparing" state so it never happens silently during a dictation.
- The selected model is loaded at launch and kept in memory. Switching models loads the new one before releasing the old.

**The gate.** Before any old code is deleted, Phase 1 ends with a measurement on real recordings of Danny's voice (at least 20, including technical vocabulary): time from key release to text, and a side-by-side read for accuracy, for Apple Speech, WhisperKit base, and WhisperKit large-v3-turbo, against today's `whisper-cli`. Results go in `docs/` and Danny picks the default. If Apple Speech loses on both quality and speed, WhisperKit becomes the default and Apple Speech stays as an option.

### Recording

- Audio is captured to memory as 16 kHz mono float samples and handed straight to the engine. No WAV round-trip on the dictation path.
- The capture engine is prepared ahead of time so the first syllable is not lost; it is rebuilt when the input device changes (today's reason for building a fresh one each press still applies).
- The same samples feed the indicator's level line.
- Kept from today: discard taps under 0.5 s, discard near-silent recordings, stop at 5 minutes, stop on device change.
- New: pressing any other key while Globe is held (Globe+arrow, Globe+Delete) cancels the recording, so using Globe as a modifier never dictates.

### Cleanup

- Runs on Apple's on-device language model (Foundation Models framework). Requires Apple Intelligence to be available and enabled; when it is not, cleanup turns itself off, Settings says why, and raw text is pasted.
- The instruction is narrow: remove filler words (um, uh, you know, like-as-filler, false starts), fix punctuation, fix capitalisation, change nothing else.
- **Guard against rewrites:** after cleanup, compare the words. If the cleaned text contains words that were not in the raw text (beyond capitalisation and punctuation changes), or has lost more than fillers would explain, discard it and paste the raw text. The exact rule is the builder's to design and must be unit tested.
- **Time limit:** if cleanup has not finished within a short limit (start at 2 seconds, tune after measuring), paste the raw text. The cleaned version is still saved to the transcript when it arrives.
- Both raw and cleaned text are stored. A transcript's main text (what Copy, Paste again and search use) is always what was actually pasted; if cleanup arrived late, the cleaned version is kept alongside and can be made the main text from the window. Very short transcripts (a few words) skip cleanup.
- Whole-transcript hallucination filtering (`"you"`, `"Thank you."`) stays, ahead of cleanup.

### What is kept, and where

Everything stays under `~/Library/Application Support/VoiceDictation/`.

- **Transcripts:** a local database (SwiftData is the default choice; the builder may choose otherwise with a reason). Per transcript: main text, raw text, cleaned text, time, recording length, app pasted into, model, transcription time, cleanup time, status, pinned flag, and any alternate results from re-transcription. Kept until deleted.
- **Audio:** the most recent 50 recordings as compressed files, linked to their transcripts. Older audio is deleted automatically; the transcript stays. The number is a setting, and 0 turns audio keeping off (which also disables Play and Re-transcribe for new transcripts). Pinned transcripts keep their audio.
- **Cancelled dictations are not kept at all:** pressing Escape means no transcript and no audio. A dictation that fails (the model could not run) is kept with its audio so it can be re-transcribed.
- **Transcripts can be edited in the window** (Danny's decision). Editing changes the transcript's main text, saves by itself, and marks the transcript "Edited". The raw and cleaned versions are never altered by an edit, so "Revert to raw" always works. Copy, Paste again and search use the edited text. An edit cannot leave the text empty; clearing it restores the previous text.
- **Existing history:** `history.json` is imported once on first launch of the new version, then left in place untouched.
- **Search:** over transcript text; simple substring search is enough at this scale.

### Paste

Unchanged in approach (clipboard snapshot, Cmd+V, restore unless the user copied something new). Two additions: the name of the frontmost app is recorded with the transcript, and "Paste last transcript" is available from the menu bar and as an optional second hotkey.

### Hotkey

- Globe stays the default. Settings offers a few alternatives (builder picks a short list such as right Option, right Command, or a custom combination).
- **Hands-free lock:** a quick double-tap of the hotkey starts a recording that continues until the hotkey is tapped again. Off by default.
- The event tap's self-healing (health timer, wake check) is kept.

## Becoming a real app

- **Project:** an Xcode project generated by XcodeGen (as in Continue?), containing a thin app target. All logic stays in the Swift package so `swift build` and `swift test` keep working from the command line. The UI is SwiftUI (`MenuBarExtra`, a `Window` scene, `Settings`), with AppKit only where SwiftUI cannot do the job (the non-activating floating panel, the event tap).
- **Minimum macOS 26.** Swift 6 language mode is the builder's call.
- **Signing:** Developer ID with Danny's paid team, hardened runtime, notarised. A stable signature is what makes Accessibility and Microphone grants survive rebuilds and updates, and makes "Open at login" safe. A stable development signature is used for local builds for the same reason.
- **Bundle identifier** stays `com.danny.VoiceDictation`. Today the app runs as a bare binary, so its preferences live in a `VoiceDictation` defaults domain; the new app copies them across once on first launch.
- **Updates:** Sparkle, with the feed hosted wherever the builder finds simplest (a GitHub release is fine). Checks happen only when Danny chooses "Check for Updates"; there is no background check, so the app makes no network call he did not start. This is the last phase and can slip without blocking anything.
- **App icon:** needed; a simple mark in the Prism spirit (white line on black). Builder proposes, Danny approves.
- **Both Macs:** no hard-coded `/Users/<name>` paths anywhere; the two machines have different usernames.

## Fixes carried in from the code review

These are small and ride along with the phase that touches the relevant code.

- The error state resets the icon to "Ready" after 5 seconds even when the app is not listening; it should return to the true state.
- Model downloads: cancel an in-flight download when the model changes; verify downloads properly (WhisperKit's own mechanism is fine).
- `timedOut` in `Transcriber` is written from two threads (goes away with the rewrite).
- A launch-time check that spawns a process on the main thread (goes away with `whisper-cli`).
- `CLAUDE.md` says tests cannot run on the laptop. They can: Xcode is installed, the shell just points at Command Line Tools. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passes all 34 tests. Fix the note.

## Phases

Each phase leaves a working app that Danny can use daily.

0. **Baseline.** Commit the ~630 lines of uncommitted hardening. Add timing logs for each stage (key down → audio flowing, key up → text, text → pasted) so every later claim is measured. Record a set of test recordings (with Danny's consent, kept locally, never committed).
1. **Engines.** The pipeline protocols, in-memory recording with pre-warm, `AppleSpeechEngine`, `WhisperKitEngine`, the measurement gate, then removal of the `whisper-cli` path. The menu bar UI still drives it.
2. **Real app.** XcodeGen project, signing and notarisation, SwiftUI shell with menu bar item, empty window and Settings, onboarding, the transcript store and the `history.json` import.
3. **The window.** `DESIGN.md` tokens into `Theme.swift`, the three-column transcript library, the floating indicator with the live line, the Models section, audio keeping, Play, Re-transcribe and comparison.
4. **Cleanup and comforts.** `TextCleaner` with its guard and time limit, raw/cleaned toggle, vocabulary and replacements, hotkey choice and hands-free lock, Paste last transcript, Escape during transcription, microphone picker.
5. **Polish.** Sparkle updates, app icon, an end-to-end test that feeds a recorded sample through the whole pipeline, README and `CLAUDE.md` rewritten for the new shape, the projects table in `~/CodingProjects/CLAUDE.md` updated.

## Testing

- Unit tests for everything pure: the cleanup guard, replacements, the level-line maths, store queries, retention, the history import.
- Engines and the cleaner are tested behind their protocols with fakes; one integration test per real engine runs a bundled short sample (a synthetic or freely licensed clip, not Danny's voice) and is skipped where the engine is unavailable.
- Hands-on checklist per phase for the things automation cannot reach: permissions flow, paste into Terminal/Messages/a browser, AirPods connecting mid-recording, sleep and wake, both Macs.

## Calls made on Danny's behalf (check these while reading)

1. The window layout follows the mockup, with Delete added to the actions.
2. The menu bar icon stays; closing the window does not quit.
3. 50 recordings of audio are kept by default; transcripts are kept until deleted.
4. Cleanup uses Apple's on-device model, never a cloud service, and falls back to raw text if it is slow, unavailable, or changes words.
5. Vocabulary, replacements, hotkey choice, hands-free lock, Paste last, Escape-to-cancel during transcription and a microphone picker are all in the first version (phase 4).
6. Minimum macOS becomes 26 on both Macs.
7. Developer ID distribution with Sparkle updates; no App Store.
8. SwiftData for storage, XcodeGen for the project, SwiftUI for the interface.
9. Phase order: speed and structure before the window.
10. Cleanup is on by default and may add up to 2 seconds before the paste. (Confirmed by Danny.)
11. Escape leaves no trace: no transcript, no audio.
13. Updates are checked only when asked, never in the background.
14. Releases are built on the laptop. (Danny confirmed only he uses the app, so the old install and packaging scripts are deleted at the end.)

## Open questions for Danny

None. Danny confirmed on 2026-11-11 that cleaned text arriving up to 2 seconds later is the right trade, and that the Mac mini runs macOS 27.

## Things to verify early (facts this design assumes)

- The exact `SpeechAnalyzer` API surface on the installed SDK, including whether custom vocabulary is supported and how language assets are installed.
- That Foundation Models is available on both Macs (Apple Intelligence enabled) and how long a cleanup of a typical sentence takes.
- WhisperKit's current model list, download mechanism and first-run compile time on an M2.
- That Apple Intelligence is switched on on the Mac mini (it runs macOS 27, so the OS requirement is met).
