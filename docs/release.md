# Releasing VoiceDictation

A release is a signed, notarised zip that opens on any Mac without a warning,
and a Sparkle feed, `appcast.xml`, that offers it to the copies already
installed. Some things must exist first, once: setup step D4, then Sparkle's
key and feed.

## One-time setup (D4)

1. **A Developer ID Application certificate.** In Xcode, open Settings,
   Accounts, pick the team (F7DL4CTLLL), Manage Certificates, and add
   "Developer ID Application". It lands in your login keychain.
2. **A notarytool profile named `voicedictation-notary`.** Make an
   app-specific password at appleid.apple.com, then run:

   ```
   xcrun notarytool store-credentials voicedictation-notary \
       --apple-id <your Apple ID> --team-id F7DL4CTLLL \
       --password <app-specific password>
   ```

   This contacts Apple once to check the password, then saves the profile in
   your keychain.

## One-time setup: Sparkle (D13)

Installed copies update through Sparkle, and only when you choose "Check for
Updates…" in the menu: the app never checks by itself. Until this setup is
done, `project.yml` holds placeholders for the feed and the key. The app runs
normally, a check says it cannot reach the feed, and `release.sh` refuses to
run.

1. **The signing key.** Build the app once with `./scripts/run-dev.sh`, which
   fetches Sparkle and its tools, then run:

   ```
   .build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   It saves a private key in your login keychain and prints the public key.
   Keep the private key safe: without it no update can be signed. For the Mac
   mini, export it with `generate_keys -x <file>`, import it there with
   `generate_keys -f <file>` and delete the file. Do not make a second key.
2. **The public key.** In `project.yml`, replace the `SUPublicEDKey`
   placeholder with the key it printed (the text between `<string>` and
   `</string>`).
3. **The feed.** In `project.yml`, set `SUFeedURL` to
   `https://github.com/DWG131313/voice-dictation/releases/latest/download/appcast.xml`,
   the newest release of this repository. Sparkle can read it only if the
   repository is public.
4. Run `xcodegen` (or `./scripts/run-dev.sh`), which writes both into
   `App/Info.plist`, and commit `project.yml` and `App/Info.plist`.

## Releasing

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`.
   Sparkle compares `CFBundleVersion`, so it must grow with every release.
2. Run:

   ```
   ./scripts/release.sh
   ```

3. On GitHub, make a release tagged `v<version>` (for example `v1.0.1`) and
   attach `dist/VoiceDictation-<version>.zip` and `dist/appcast.xml`. The feed
   is always read from the newest release, and its download link already
   points at this tag, so an installed copy finds the update the next time you
   choose "Check for Updates…".

The version comes from `CFBundleShortVersionString` in `project.yml`. The
script checks for the certificate and the Sparkle setup first and stops with a
plain message naming what is missing; nothing is built or sent. Then it
archives, checks that the app carries the public half of your Sparkle key,
exports, uploads to Apple and waits for the verdict, staples the ticket,
checks the result with `spctl`, and writes `dist/VoiceDictation-<version>.zip`.
Last, Sparkle's `generate_appcast` signs that zip with your key and writes
`dist/appcast.xml`. The keychain may ask whether Sparkle's tools may use the
key; allow it. Everything under `dist/` is git-ignored.

One check cannot run early: `notarytool` has no offline way to see whether the
`voicedictation-notary` profile exists, so a missing profile only shows up when
the upload step starts, after the build. The error then comes from notarytool;
redo step 2 of the D4 setup and run the script again.

## Installing on the Mac mini

Copy `dist/VoiceDictation-<version>.zip` over (AirDrop or Dropbox), double-click
it, and drag `VoiceDictation.app` into Applications. Open it from there. The
first launch asks for the usual microphone and accessibility permissions.
