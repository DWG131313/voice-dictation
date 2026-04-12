#!/bin/bash
# Installs VoiceDictation on a new Mac.
# Run from inside the unpacked VoiceDictation-package directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/bin/voice-dictation"

echo "=== VoiceDictation Installer ==="
echo ""

# Check macOS version
SW_VERS=$(sw_vers -productVersion)
MAJOR=$(echo "$SW_VERS" | cut -d. -f1)
if [ "$MAJOR" -lt 13 ]; then
    echo "Error: macOS 13 (Ventura) or later is required. You have $SW_VERS."
    exit 1
fi

echo "macOS $SW_VERS — OK"

# Check architecture
ARCH=$(uname -m)
echo "Architecture: $ARCH"

# Decide: use pre-built binary or build from source?
USE_PREBUILT=false
if [ "$ARCH" = "arm64" ] && [ -f "$SCRIPT_DIR/bin/VoiceDictation" ]; then
    USE_PREBUILT=true
    echo "Pre-built ARM64 binary found — will use it"
elif [ -d "$SCRIPT_DIR/source" ]; then
    echo "Will build from source (different architecture or no pre-built binary)"
    # Check for Swift
    if ! command -v swift &>/dev/null; then
        echo "Error: Swift is required to build from source."
        echo "Install Xcode Command Line Tools: xcode-select --install"
        exit 1
    fi
else
    echo "Error: No binary or source code found in package."
    exit 1
fi

# Create install directory
echo ""
echo "Installing to: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [ "$USE_PREBUILT" = true ]; then
    # Copy pre-built binaries
    cp "$SCRIPT_DIR/bin/VoiceDictation" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/bin/whisper-cli" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/bin/"*.dylib "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/VoiceDictation" "$INSTALL_DIR/whisper-cli"
else
    # Build from source
    echo "Building from source (this may take a minute)..."
    cd "$SCRIPT_DIR/source"
    swift build

    cp .build/debug/VoiceDictation "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/VoiceDictation"

    # Try to bundle whisper-cli if available
    if command -v whisper-cli &>/dev/null || [ -x /opt/homebrew/bin/whisper-cli ] || [ -x /usr/local/bin/whisper-cli ]; then
        echo "Bundling whisper-cli..."
        ./scripts/bundle-whisper.sh
        cp .build/debug/whisper-cli "$INSTALL_DIR/"
        cp .build/debug/*.dylib "$INSTALL_DIR/"
    elif [ -f "$SCRIPT_DIR/bin/whisper-cli" ]; then
        echo "Copying packaged whisper-cli..."
        cp "$SCRIPT_DIR/bin/whisper-cli" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/bin/"*.dylib "$INSTALL_DIR/"
    else
        echo ""
        echo "WARNING: whisper-cli not found. Install it with:"
        echo "  brew install whisper-cpp"
        echo "The app will look for it in /opt/homebrew/bin/whisper-cli"
    fi
fi

# Also keep source for future rebuilds
if [ -d "$SCRIPT_DIR/source" ]; then
    echo "Copying source to $INSTALL_DIR/source/ for future rebuilds..."
    rsync -a "$SCRIPT_DIR/source/" "$INSTALL_DIR/source/"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "To run:  $INSTALL_DIR/VoiceDictation"
echo ""
echo "MANUAL STEPS REQUIRED:"
echo ""
echo "1. Grant Accessibility permission:"
echo "   System Settings > Privacy & Security > Accessibility"
echo "   Click '+' and add: $INSTALL_DIR/VoiceDictation"
echo ""
echo "2. Microphone permission will be prompted on first launch."
echo ""
echo "3. Set Globe key to 'Do Nothing':"
echo "   System Settings > Keyboard > 'Press Globe key to' > 'Do Nothing'"
echo ""
echo "4. The app downloads the Whisper model (~150MB) on first launch."
echo ""
echo "5. The app registers itself as a login item automatically."
echo "   If it doesn't appear in Login Items, add it manually:"
echo "   System Settings > General > Login Items > click '+'"
echo ""
echo "TIP: To start right now, run:"
echo "  $INSTALL_DIR/VoiceDictation &"
