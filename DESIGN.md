---
version: alpha
name: VoiceDictation
description: A macOS menu bar app that turns held-key speech into pasted text, with a quiet window for past dictations.
colors:
  bg: "#000000"
  bg-elevated: "#0A0A0A"
  text: "#F2F2F2"
  text-muted: "#8C8C8C"
  hairline: "#2A2A2A"
  beam: "#FFFFFF"
  primary: "{colors.beam}"
  on-beam: "#000000"
  spectrum-1: "#FF2D1F"
  spectrum-2: "#FF8A00"
  spectrum-3: "#FFE600"
  spectrum-4: "#27D14B"
  spectrum-5: "#1E8BFF"
  spectrum-6: "#7B3DFF"
typography:
  title:
    fontFamily: "Jost, Futura, sans-serif"
    fontSize: 26px
    fontWeight: 600
    lineHeight: 1.2
  body:
    fontFamily: "Work Sans, Helvetica Neue, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Work Sans, Helvetica Neue, sans-serif"
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.4
  mono:
    fontFamily: "DM Mono, ui-monospace, monospace"
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  none: 0px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 40px
components:
  button-primary:
    backgroundColor: "{colors.beam}"
    textColor: "{colors.on-beam}"
    typography: "{typography.title}"
    rounded: "{rounded.none}"
    padding: "8px 16px"
  button-secondary:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.beam}"
    typography: "{typography.label}"
    rounded: "{rounded.none}"
    padding: "8px 16px"
  transcript-row:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.none}"
    padding: "16px"
  panel:
    backgroundColor: "{colors.bg-elevated}"
    textColor: "{colors.text}"
    rounded: "{rounded.none}"
    padding: "{spacing.md}"
  divider:
    backgroundColor: "{colors.hairline}"
    height: 1px
  timestamp:
    backgroundColor: "{colors.bg}"
    textColor: "{colors.text-muted}"
    typography: "{typography.mono}"
---

<!--
  DESIGN.md — this project's design manifest.
  Format: https://github.com/google-labs-code/design.md (alpha spec)
  Convention: ~/CodingProjects/design-reference (see skill/SKILL.md)

  Rules for Claude sessions working in this project:
  - The YAML tokens above are AUTHORITATIVE. Use them. Do not invent new
    colors, fonts, radii, or spacing values without updating this file first.
  - The prose below explains WHY. Read it before changing any token.
  - Validate after edits: npx @google/design.md lint DESIGN.md
    (checks broken token references + WCAG contrast)
  - Code: Sources/VoiceDictationUI/Theme.swift and Fonts.swift implement these tokens.
-->

## Overview

VoiceDictation is a menu bar tool you hold a key to talk to. Its window is a quiet record of what you said: black, white type, and one band of colour where the beam leaves the prism.

**Direction:** Prism (see `~/CodingProjects/design-reference/design-directions/prism.md`), the first native macOS (SwiftUI) use of it.
**Signature move:** the spectrum underline, 2px, under the selected transcript. It is the only colour on any screen.

**One deliberate departure:** the direction's live indicator is a stepping heartbeat line. Here the floating indicator is a scrolling volume line, white on black, and it carries no colour. It shows how loud you are, which a single step cannot.

## Colors

Dark only; there is no light mode, the prism needs the dark. Text is `#F2F2F2` on black (18.8:1) and muted text is `#8C8C8C` (6.3:1). The spectrum runs red, orange, yellow, green, blue, violet (no indigo) and appears exactly once per screen, on the selected transcript row, and never in the floating indicator. The app icon is its one use outside the window. Status is told in words (`Failed`, `Skipped`), never in colour.

## Typography

Jost for the one title per screen, Work Sans for the interface, DM Mono for times and figures. All three ship inside the app (SIL OFL licences beside the files), so nothing is fetched at run time. Jost and Work Sans are variable fonts, and the code sets their weight axis explicitly: Jost 600 for titles, Work Sans 400 for text and 500 for labels, DM Mono 400. Never bold above 600.

## Layout

Low density, one object per region, lists of hairline-separated rows. The window is a single column of transcripts with a detail pane beside it. Spacing steps are 4, 8, 16, 24 and 40.

## Elevation & Depth

None. No shadows, no glows. Regions are separated by `bg-elevated` and a 1px `hairline`.

## Shapes

Radius 0 everywhere: buttons, rows, panels, the indicator. Corners are square. The app icon's rounded square is macOS's icon shape, not a Prism radius.

## Components

- **Primary button:** white fill, black Jost 600 label.
- **Secondary button:** 1px white outline, white Work Sans 500 label.
- **Selected transcript:** the 2px spectrum underline; every other row is white on black.
- **Selected text:** black on the text white (`bg` on `text`), caret white; never the system accent, so the spectrum stays the only colour.
- **Times and figures:** DM Mono, muted.
- **Floating indicator:** a scrolling white volume line, no colour, no spectrum.
- **App icon:** black, and a sharp-cornered waveform whose stroke is the spectrum, running along the line from red to violet; the only element.

## Do's and Don'ts

- DO reuse the tokens above for every new element.
- DO keep the spectrum to one element per screen.
- DON'T put the spectrum, or any colour, in the floating indicator.
- DON'T add shadows, glows, rounded corners or a light mode.
- DON'T introduce a new font family or accent colour casually; that is a design-direction change, so update this file deliberately.
