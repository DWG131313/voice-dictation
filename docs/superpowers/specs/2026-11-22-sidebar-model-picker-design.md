# The sidebar's box: a model picker and the Mini View switch

2026-11-22. A small change on branch `mini-view-organisation`, so it ships in 1.1 with the mini view.

## Why

Danny wants to turn Mini View on and off from the main window, not only from the menu bar. While he's there, the model names should make sense to someone brand new: today they are engine syntax, "whisper.cpp base.en".

## Goals

- Turn Mini View on and off from the main window.
- Choose the model from the main window.
- Model names a newcomer understands, all on one measure.

## Non-goals

- No change to how models download, load or transcribe.
- No engine is removed. WhisperKit's tiny, base and small stay on the Models page and can still re-transcribe and compare.
- No keyboard shortcut.
- No change to saved transcripts. They keep each model's key, and names are looked up when drawn.

## Anti-goals

- A name that hides the trade-off. Picking Fastest must say that it makes more mistakes.
- A switch that relies on the tab to show it worked. The tab never appears on VoiceDictation's own window, so the switch shows on or off itself.

## Approaches

- **The box.** One option stacked the picker and the switch; the other puts them side by side. Danny chose side by side.
- **The measure for names.** Size (Small to Largest), quality (Basic to Best) and speed (Fastest to Slowest) were the options. Danny chose speed. A mix such as Fast, Balanced and Accurate was turned down, because accuracy is a different measure from speed.
- **The two Whisper engines.** Danny chose (A).
  - (A) One speed ladder, with one engine per step.
  - (B) Two groups that repeat the ladder. The closed picker would show "Fast" for two different models.
  - (C) One ladder plus a Settings switch for the engine. It is more to build, and the largest model exists on only one engine.
- **What a checkmark means.** Danny chose (1).
  - (1) ✓ means downloaded, and the model in use says "in use" in its line.
  - (2) ✓ means in use, as in other Mac menus, and a downloaded model not in use has no mark.

## Decided

**The box** at the bottom of the sidebar, under its hairline, is one row:
- On the left, the model picker. Closed, it shows the name of the model in use.
- On the right, "Mini View" and a switch in Prism's style, as in Settings. The switch and the menu bar's Mini View toggle are the same saved setting.
- The line "Hold or double-tap Globe to dictate" goes.

**Names, and the line under each in the open picker.** The picker shows no download sizes.

| Model | Name | Line |
|---|---|---|
| whisper.cpp tiny.en | Fastest | more mistakes |
| whisper.cpp base.en | Fast | the default |
| whisper.cpp small.en | Slow | fewer mistakes |
| WhisperKit large-v3-turbo | Slowest | fewest mistakes |
| Apple Speech | Apple Speech | built into macOS |
| Apple Dictation | Apple Dictation | built into macOS |

**Marks and states in the open picker:**
- **✓ Downloaded.** Apple's two usually show ✓. Marks follow each model's real state, so an Apple model whose macOS files aren't installed shows ↓, and one click installs them.
- **Preparing.** A downloaded model that WhisperKit is getting ready for its first use shows ✓, and its line reads "preparing".
- **↓ Not downloaded.** One click starts the download, and dictation switches to the model when it finishes. This is what choosing such a model does today (`AppModel.choose`).
- **Downloading.** The line reads "downloading 40%".
- **In use.** The model in use reads "in use" in place of its usual line:
  ```
   ✓ Fastest           more mistakes
   ✓ Fast              in use
   ↓ Slow              fewer mistakes
   ↓ Slowest           fewest mistakes
   ─────
   ✓ Apple Speech      built into macOS
   ✓ Apple Dictation   built into macOS
  ```
- **Unavailable.** A model this Mac can't use (an Apple one without its system support, say) shows the reason in its line and can't be chosen, as the menu does today.

**Why this order.** Danny compared the models on 24 of his own dictations on 2026-11-13. These are the median waits after the model had loaded:

| Model | Median wait |
|---|---|
| WhisperKit tiny | 0.08 s |
| WhisperKit base | 0.12 s |
| Apple Speech | 0.14 s |
| whisper.cpp base | 0.16 s |
| Apple Dictation | 0.24 s |
| WhisperKit small | 0.36 s |
| WhisperKit large-v3-turbo | 1.69 s |

The same size runs at about the same speed on both engines. whisper.cpp fills the first three steps because it is built in, its downloads are smaller, and it needs no long first-time preparing.

## The builder's calls (Claude's, for Danny to check)

1. The menu bar's Model submenu lists the same six models with the same names, so there is one list everywhere.
2. (Replaced by Danny's marks above: ↓ for not downloaded, ✓ for downloaded, "in use" for the model in use.)
3. WhisperKit's tiny, base and small are now off the ladder. Wherever they still appear, they read "WhisperKit tiny", "WhisperKit base" and "WhisperKit small": the Models page, a transcript's details and the compare view.
4. If one of those three is the model in use, both pickers still list it at the end, reading "in use". A picker never hides what is in use.
5. The Models page shows the plain name, with the technical name and download size under it in small type.
6. A name too long for the box, probably Apple's two, ends in "…" there. The open list always shows the whole name.
7. If the system menu can't show a second line, the line follows the name instead: "✓ Fastest — more mistakes".
8. Where the app names a model inside a sentence, it says "the Fast model":
   - the menu bar's "Status: Preparing the Fast model..."
   - onboarding's "The Fast model is ready." and "Download the Fast model"
9. The engines' own error messages and the log keep the technical names ("whisper.cpp tiny.en could not be downloaded: …"). These are rare, and the exact name helps find the cause.
10. A state line (downloading, preparing, unavailable) replaces "in use" while it lasts. The model in use reads "in use" again once it is ready.

## Left to the builder

- Exact widths, and a compact style for the picker in the box, using DESIGN.md's tokens.
- Tests:
  - each model's name and line
  - the mark and line for each state: downloaded, not downloaded, downloading, in use and unavailable
  - the pickers' contents and order, including an off-ladder model in use
  - the switch bound to the saved setting
