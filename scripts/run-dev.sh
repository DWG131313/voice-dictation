#!/bin/bash
# Builds the app bundle and launches it: how to run VoiceDictation while
# developing. The Xcode project is generated from project.yml every time, and
# the app lands in .build/xcode, where it never registers a login item.

set -euo pipefail

cd "$(dirname "$0")/.."

# xcode-select may point at the Command Line Tools, which cannot build an app.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP=".build/xcode/Build/Products/Debug/VoiceDictation.app"

xcodegen
xcodebuild -scheme VoiceDictation -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build

# One copy at a time. Quit the running one (an older bare binary too) and wait
# for it to go: a new copy will not start while the old one holds the
# single-instance lock.
if pkill -x VoiceDictation; then
    for _ in $(seq 50); do
        pgrep -x VoiceDictation >/dev/null || break
        sleep 0.1
    done
    if pgrep -x VoiceDictation >/dev/null; then
        echo "VoiceDictation is still running; quit it from its menu, then run this again." >&2
        exit 1
    fi
fi

# `open` starts it in the background, so the terminal never becomes the app
# a dictation pastes into.
open "$APP"
