#!/bin/bash
# Copies the Homebrew whisper-cli binary next to the built executable
# Usage: ./scripts/bundle-whisper.sh

set -e

WHISPER_SRC=""
for candidate in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do
    if [ -x "$candidate" ]; then
        WHISPER_SRC="$candidate"
        break
    fi
done

if [ -z "$WHISPER_SRC" ]; then
    echo "Error: whisper-cli not found. Install with: brew install whisper-cpp"
    exit 1
fi

DEST=".build/debug/whisper-cli"
cp "$WHISPER_SRC" "$DEST"
chmod +x "$DEST"
echo "Bundled $WHISPER_SRC -> $DEST"
