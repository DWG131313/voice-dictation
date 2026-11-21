# Waveform App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the microphone app icon with Danny's sharp waveform, the spectrum running along the line.

**Architecture:** `scripts/make-icon.swift` keeps its shape (tokens from DESIGN.md, every size drawn from paths, ten PNGs and a preview). Only the drawing changes: a 16-point polyline, coloured by distance along it.

**Tech Stack:** Swift script (Core Graphics), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-20-waveform-icon-design.md`

## Global Constraints

- Colours come only from DESIGN.md's `bg` and `spectrum-1` to `spectrum-6`.
- The rounded square is unchanged: 824 px at (100, 100), continuous corners of radius 185, transparent outside.
- Run Swift with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Commit messages: one line, under 72 characters. Commit only when Danny asks.

## Review Focus

- The 16 px render: the line must still show (never under 1 px wide), not fade into the black.
- Steps drawn one after another can leave hairline gaps or dark joints at corners; look at the 1024 master at full size.
- A DESIGN.md with a missing token must still write nothing (existing test `testTheScriptStopsNamingEveryTokenItCannotFind`).

---

### Task 1: The waveform icon

**Files:**
- Modify: `scripts/make-icon.swift` (header comment, lines 116-199: the drawing)
- Modify: `Tests/VoiceDictationUITests/AppIconTests.swift` (the two microphone tests, the class comment)
- Modify: `DESIGN.md` (lines 107 and 133, the app icon)
- Modify: `docs/superpowers/plans/2026-11-11-native-app-notes.md` (D7)
- Regenerate: `App/Assets.xcassets/AppIcon.appiconset/*.png`, `docs/icon-preview.png`

- [ ] **Step 1: Rewrite the two failing tests**

Rename `testTheMasterIsTheMicrophoneOutlineInTheSpectrumOnBg` to `testTheMasterIsTheWaveformInTheSpectrumOnBg`. Keep its transparent-corner and `bg` assertions. Replace the head and base assertions with:

```swift
// The line's left end is spectrum-1, its right end spectrum-6.
XCTAssertTrue(master.pixel(212, 512).isNear(r: 0xFF, g: 0x00, b: 0x00), "left end: \(master.pixel(212, 512))")
XCTAssertTrue(master.pixel(812, 512).isNear(r: 0x00, g: 0x00, b: 0xFF), "right end: \(master.pixel(812, 512))")
// The tallest peak (point 7) is at x 492, y 302; the stroke is 24.
let peak = try XCTUnwrap((100..<512).first { !master.pixel(492, $0).isOpaque(bg) })
XCTAssertTrue((280...300).contains(peak), "the tallest peak starts at y \(peak)")
// Above the wave and beside it is bg.
XCTAssertTrue(master.pixel(492, 250).isOpaque(bg))
XCTAssertTrue(master.pixel(150, 512).isOpaque(bg))
```

In `testTheCommittedMasterMatchesTheCurrentTokens`, replace the head and base lookups with `master.pixel(212, 512)` near `spectrum-1` and `master.pixel(812, 512)` near `spectrum-6`.

Add `testTheSmallestSizeStillShowsTheLine`: run the script with `Self.tokens`, read `icon_16x16.png`, and assert at least one pixel in row 8 has a channel 100 or more away from `bg`'s.

- [ ] **Step 2: Run them and see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppIconTests`
Expected: the three tests above FAIL (the microphone is still drawn).

- [ ] **Step 3: Draw the waveform in `scripts/make-icon.swift`**

Replace the microphone geometry, `spectrumStart`/`spectrumEnd` and the stroke-clip-gradient in `render(pixels:)` with:

- `let heights: [CGFloat] = [0, 0.25, -0.55, 0.35, -0.9, 0.6, -0.4, 1, -0.75, 0.3, -0.95, 0.55, -0.25, 0.45, -0.2, 0]`; point k is `(212 + 40k, 512 - 210 * heights[k])`.
- `func strokeWidth(pixels: Int) -> CGFloat`: 24, or wider so the line is at least 1 px at that size (`max(24, 1024 / CGFloat(pixels))`).
- `func spectrumColor(at t: CGFloat) -> CGColor`: the six tokens evenly spaced, blended linearly in sRGB.
- The line is drawn in steps of about one unit, each stroked with round caps in `spectrumColor(at: distance so far / total length)`.

Update the header comment and the stroke comment to describe the waveform.

- [ ] **Step 4: Run the script and the tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make-icon.swift`
Expected: `make-icon: wrote 11 PNGs`.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppIconTests`
Expected: all AppIconTests PASS.

Open `docs/icon-preview.png` and compare it with the spike's option A (Review Focus).

- [ ] **Step 5: Update the docs**

- `DESIGN.md` line 133: "**App icon:** black, and a sharp-cornered waveform whose stroke is the spectrum, running along the line from red to violet; the only element."
- `DESIGN.md` line 107 stays true ("The app icon is its one use outside the window"); change nothing else.
- Notes, D7: status "decided 2026-11-20: Danny replaced the microphone with a waveform (spec `docs/superpowers/specs/2026-11-20-waveform-icon-design.md`)".
- `AppIconTests` class comment: "a waveform in the spectrum" in place of the microphone.

- [ ] **Step 6: Run the full suite, then lint DESIGN.md**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 0 failures.

Run: `npx @google/design.md lint DESIGN.md`
Expected: no errors.

- [ ] **Step 7: Commit when Danny asks**

```bash
git add scripts/make-icon.swift Tests/VoiceDictationUITests/AppIconTests.swift DESIGN.md docs App/Assets.xcassets/AppIcon.appiconset
git commit -m "feat: waveform app icon with the spectrum along the line"
```
