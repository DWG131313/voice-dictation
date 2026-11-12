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

- Task 2: launch the build, dictate once, and open `~/Library/Logs/VoiceDictation.log`. You should see a line like `[TIMING] keyDown→firstAudio=120ms keyUp→text=800ms text→pasted=15ms`.
- Task 2: in the menu bar menu, turn on "Keep recordings for comparison" (a checkmark appears), dictate once, and look in `~/Library/Application Support/VoiceDictation/comparison/`. You should see a `<unix-ms>.wav` and a `<unix-ms>.txt` (Unix time in milliseconds) with the same name; the text is what the current engine produced.

## Findings

