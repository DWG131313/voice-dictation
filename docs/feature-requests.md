# Feature requests

Ideas Danny wants once the native app is working. Nothing here is planned yet. When one is picked up, it starts with a design session and then gets a plan, like any other work.

## UI skins from the design library

*Asked 2026-11-12.*

Danny wants to switch the app between different looks, or skins, each built from his design library at `~/CodingProjects/design-reference`. A skin could reuse an aesthetic the library already has, or be a new one made for this app.

The app already takes its colours, fonts and spacing from one set of design tokens: `Theme` in the code, written from the Prism direction in `DESIGN.md`. So a skin is mostly another set of those tokens, plus a way to choose between them.

Questions for the design session:
- Which looks come first?
- Where does the choice live?
- Does the icon change with the skin?

## Show the text as you speak

*From the old app's future list; kept 2026-11-12.*

Show the words while Danny is still talking, instead of only after he lets go of the key. Today the whole recording is transcribed after the release. Whisper, the default engine, reads whole recordings, so live text would mean re-reading the latest audio every second or so while he talks.

## Install with Homebrew

*From the old app's future list; kept 2026-11-12.*

Install the app with `brew install --cask` instead of downloading a zip. The app isn't public, so this would be a cask in Danny's own Homebrew tap. It would point at the notarised zip that `scripts/release.sh` makes.
