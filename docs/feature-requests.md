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

## Rename the app

*Asked 2026-11-20, for after the mini view and organisation batch.*

Danny wants to give the app another name. The name he sees (menu bar menu, window titles, the Dock, Finder) is cheap to change: `CFBundleDisplayName` and `CFBundleName` in `App/Info.plist`, the product name in `project.yml`, and the words in the app and docs.

Changing more than the name he sees costs something, so the design session should decide how deep the rename goes:
- **The bundle identifier** (`com.danny.VoiceDictation`): macOS ties Accessibility and Microphone permission to it, so both would need granting again on both Macs. Saved settings live under it too, so they'd need moving (`PreferencesMigrator` already does this for an older domain).
- **The data folder** (`~/Library/Application Support/VoiceDictation/`, with the transcripts, recordings and models): moving it means a one-time migration at launch.
- **Updates**: installed copies check the feed in `SUFeedURL` (the `voice-dictation` GitHub repo). A renamed repo needs the old feed to keep working, or one last release that points at the new one.
- **The log** (`~/Library/Logs/VoiceDictation.log`) and the repo folders on both Macs (`Voice Dictation/`, `voice-dictation/`).

Questions for the design session:
- What's the new name?
- Only the name he sees, or the identifier and folders too?

## Install with Homebrew

*From the old app's future list; kept 2026-11-12.*

Install the app with `brew install --cask` instead of downloading a zip. The app isn't public, so this would be a cask in Danny's own Homebrew tap. It would point at the notarised zip that `scripts/release.sh` makes.
