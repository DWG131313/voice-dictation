# Native app: builder notes

## Execution method

Subagent-driven development, Danny's choice on 2026-11-11: a fresh implementer per task and a task review after each, then a whole-branch review. Chosen because the 27 tasks share interfaces, and permission, audio and signing mistakes are expensive to find late.

## Needs Danny

- D8 (Task 2): Dictate a few ordinary sentences with the Task 2 build, then copy the three `[TIMING]` numbers (keyDown→firstAudio, keyUp→text, text→pasted) from `~/Library/Logs/VoiceDictation.log` into a new `docs/baseline-timings.md`. Task 4 compares against these. Status: open.
- D1: Record at least 20 normal dictations, including technical words (until Task 24, turn on "Keep recordings for comparison"). Status: open.
- D2: Read `docs/engine-comparison.md` and choose the default engine. Status: open.
- D3: Confirm Apple Intelligence is switched on (both Macs). Status: open.
- D4: Create a "Developer ID Application" certificate and a notarytool keychain profile named `voicedictation-notary`. Status: open.
- D5: Grant Microphone and Accessibility to the new app bundle once. Status: open.
- D6: Nothing to confirm about the OS; the Mac mini runs macOS 27 and keeps the current app from `main` until Danny installs a release. Status: open.
- D7: Choose the app icon from the options in Task 26. Status: open.

## Hands-on checks not performed

Implementers do not launch the app (controller ruling P2), so checks that need the running app, a microphone, permissions or a human are listed here for Danny.

- Task 4: dictate a few ordinary sentences and compare all three figures in the `[TIMING]` lines of `~/Library/Logs/VoiceDictation.log` with your Task 2 baseline (D8, `docs/baseline-timings.md`). `keyDown→firstAudio` should be the same or lower. `keyUp→text` and `text→pasted` should be no higher: after each key release the app now writes the recording to a WAV before transcribing and readies the microphone for the next dictation, and neither should show up in these figures. The line `[AUDIO] Input changed since it was prepared — rebuilding` should not appear for ordinary dictations; if it appears every time, the microphone is not being readied ahead and `keyDown→firstAudio` will match the old figure.
- Task 4: watch the orange microphone indicator in the menu bar. It should be off right after launch, on only while you hold Globe, and off again as soon as each recording ends, including one you cancel with Escape.
- Task 4: dictate once on the built-in mic, connect AirPods, wait a couple of seconds and dictate again, then disconnect them and dictate once more. Each time your real words should be pasted, and the log should show `[AUDIO] Default input device changed — preparing again` (or `[AUDIO] Input format changed while idle — preparing again`) followed by one `[AUDIO] Prepared input` line. While the app sits idle with AirPods connected, music should keep its normal quality (it may drop to call quality only while you hold Globe). If two `Input format changed while idle — preparing again` lines appear within a second of each other and are followed by `keeping the prepared engine (rebuilt 2 of 2 times since the last recording)`, the cap stopped a rebuild loop: readying the microphone is changing the AirPods' format by itself. Please mention it if you see this.
- Task 2: launch the build, dictate once, and open `~/Library/Logs/VoiceDictation.log`. You should see a line like `[TIMING] keyDown→firstAudio=120ms keyUp→text=800ms text→pasted=15ms`.
- Task 2: in the menu bar menu, turn on "Keep recordings for comparison" (a checkmark appears), dictate once, and look in `~/Library/Application Support/VoiceDictation/comparison/`. You should see a `<unix-ms>.wav` and a `<unix-ms>.txt` (Unix time in milliseconds) with the same name; the text is what the current engine produced.

## Findings

- Task 4: Core Audio listener blocks added from Swift cannot be removed. `AudioObjectRemovePropertyListenerBlock` returns `noErr`, but the listener keeps firing, whether the block is stored as `AudioObjectPropertyListenerBlock` or as `@convention(block)`: Swift hands Core Audio a new block on every call (tested on macOS 27 with a per-process property). The recorder registers its default-input listener once and captures `self` weakly. Task 24's device-list observer should do the same, or use the function-pointer API (`AudioObjectAddPropertyListener`).
- Task 4: `installTap`'s buffer size is clamped to 100–400 ms (`AVAudioNode.h`), so `onLevel` fires about 10 times a second and the first buffer arrives about 100 ms after the engine starts. Task 17's `LevelLine` pushes a vertex every 50 ms, so roughly every other interval gets no new peak.
- Task 4: `AVAudioEngineConfigurationChange` is posted on the engine's internal queue, and tearing the engine down from the handler can deadlock (`AVAudioEngine.h`). The Task 2 recorder observed on `.main` and tore down inside the handler; the recorder now observes with `queue: nil` and does the work in a `DispatchQueue.main.async` block.

