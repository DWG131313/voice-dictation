# Releasing VoiceDictation

A release is a signed, notarised zip that opens on any Mac without a warning.
Two things must exist first, once. Together they are setup step D4.

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

## Releasing

```
./scripts/release.sh
```

The version comes from `CFBundleShortVersionString` in `project.yml`. The
script checks for the certificate first and stops with a plain message naming
D4 if it is missing; nothing is built or sent. Then it archives, exports,
uploads to Apple and waits for the verdict, staples the ticket, checks the
result with `spctl`, and writes `dist/VoiceDictation-<version>.zip`. Everything
under `dist/` is git-ignored.

One check cannot run early: `notarytool` has no offline way to see whether the
`voicedictation-notary` profile exists, so a missing profile only shows up when
the upload step starts, after the build. The error then comes from notarytool;
redo step 2 above and run the script again.

## Installing on the Mac mini

Copy `dist/VoiceDictation-<version>.zip` over (AirDrop or Dropbox), double-click
it, and drag `VoiceDictation.app` into Applications. Open it from there. The
first launch asks for the usual microphone and accessibility permissions.
