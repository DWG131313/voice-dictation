#!/bin/bash
# Creates a self-contained VoiceDictation install package.
# Run this on the machine that already has everything set up.
# Output: ~/Dropbox/VoiceDictation-package.tar.gz

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_NAME="VoiceDictation-package"
STAGING_DIR="/tmp/$PACKAGE_NAME"
OUTPUT_DIR="${1:-$HOME/Dropbox}"
OUTPUT_FILE="$OUTPUT_DIR/$PACKAGE_NAME.tar.gz"

echo "=== VoiceDictation Packager ==="

# Clean staging area
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# 1. Copy source code (excluding build artifacts and git)
echo "Copying source code..."
rsync -a \
    --exclude='.build/' \
    --exclude='.git/' \
    --exclude='.claude/' \
    --exclude='docs/superpowers/' \
    "$PROJECT_DIR/" "$STAGING_DIR/source/"

# 2. Build the project
echo "Building VoiceDictation..."
cd "$PROJECT_DIR"
swift build

# 3. Bundle whisper-cli + dylibs
echo "Bundling whisper-cli..."
"$PROJECT_DIR/scripts/bundle-whisper.sh"

# 4. Copy built binary + bundled whisper into package
echo "Copying built binaries..."
mkdir -p "$STAGING_DIR/bin"
cp "$PROJECT_DIR/.build/debug/VoiceDictation" "$STAGING_DIR/bin/"
cp "$PROJECT_DIR/.build/debug/whisper-cli" "$STAGING_DIR/bin/"
cp "$PROJECT_DIR/.build/debug/libwhisper.1.dylib" "$STAGING_DIR/bin/"
cp "$PROJECT_DIR/.build/debug/libggml.0.dylib" "$STAGING_DIR/bin/"
cp "$PROJECT_DIR/.build/debug/libggml-base.0.dylib" "$STAGING_DIR/bin/"

# 5. Copy install script
cp "$PROJECT_DIR/scripts/install.sh" "$STAGING_DIR/"
chmod +x "$STAGING_DIR/install.sh"

# 6. Create the archive
echo "Creating archive..."
mkdir -p "$OUTPUT_DIR"
cd /tmp
tar czf "$OUTPUT_FILE" "$PACKAGE_NAME/"

# Cleanup
rm -rf "$STAGING_DIR"

echo ""
echo "=== Package created ==="
echo "Location: $OUTPUT_FILE"
echo "Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""
echo "To install on another Mac:"
echo "  1. Copy $PACKAGE_NAME.tar.gz to the target machine"
echo "  2. tar xzf $PACKAGE_NAME.tar.gz"
echo "  3. cd $PACKAGE_NAME"
echo "  4. ./install.sh"
