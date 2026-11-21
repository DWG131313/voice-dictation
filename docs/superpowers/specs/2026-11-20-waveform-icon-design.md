# Waveform app icon: design

Approved by Danny on 2026-11-20. A small change; this replaces the microphone icon from Task 26 (D7).

## Intent

The app icon should feel like the recording indicator: a line that moves with your voice. Danny tried the spectrum along a microphone outline, liked a waveform cord best, and dropped the microphone altogether.

## The design

- A black rounded square, as now (824 px in the 1024 canvas, continuous corners of radius 185, transparent outside).
- On it, one sharp-cornered waveform, the only element. It is a single open line of 15 straight segments through 16 points.
- In the 1024 space, y down: point k (0 to 15) is at x = 212 + 40k, y = 512 − 210 × h, with h, in order:
  `0, 0.25, −0.55, 0.35, −0.9, 0.6, −0.4, 1, −0.75, 0.3, −0.95, 0.55, −0.25, 0.45, −0.2, 0`
- The spectrum runs along the line by distance travelled: `spectrum-1` at the left end, `spectrum-6` at the right, the six tokens evenly spaced and blended in sRGB, read from DESIGN.md as now.
- Stroke 24 at 1024 (about 1.5 px in the Dock), round caps and round joins.
- Small sizes (builder's call, Danny informed): at 16 and 32 px the stroke is widened so it is never under 1 px.

## Goals and non-goals

- Goal: the icon Danny picked ("A, varied heights") in `options-sheet.png`, round 4 of the spike.
- Non-goals: the menu bar symbol, the recording indicator, the square's shape and the spectrum colours do not change. No Icon Composer file.
- Anti-goal: a seam, or any colour that is not a DESIGN.md token.

## Approaches

1. Change `scripts/make-icon.swift` (chosen). The icon keeps following DESIGN.md's tokens, every size is still drawn by the script, and the tests keep guarding it.
2. A hand-exported image. Loses the token link and the tests.
3. An Icon Composer `.icon` file. Only needed if macOS puts the icon on a grey plate, and it did not.

## What it touches

- `scripts/make-icon.swift`: the wave instead of the microphone; colour along the line (Core Graphics has no gradient along a path, so the line is drawn in short steps, each in the colour for its distance).
- `App/Assets.xcassets/AppIcon.appiconset/*.png` and `docs/icon-preview.png`: redrawn by the script.
- `Tests/VoiceDictationUITests/AppIconTests.swift`: red at the left end and violet at the right, in place of red at the head's top and violet at the base.
- `DESIGN.md`: the app icon lines describe the waveform.
- `docs/superpowers/plans/2026-11-11-native-app-notes.md`: D7 closed with the new design.

## Left to the builder

How the steps are drawn so the small sizes stay clean, and the exact small-size stroke widths.
