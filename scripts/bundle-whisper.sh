#!/bin/bash
# Copies the Homebrew whisper-cli binary and its dylib dependencies
# next to the built executable, rewriting paths so it runs standalone.
# Usage: ./scripts/bundle-whisper.sh

set -e

DEST_DIR=".build/debug"

# Find whisper-cli
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

HOMEBREW_PREFIX="$(brew --prefix)"

# Copy binary and libs. Homebrew's files are read-only, so a previous copy
# can't be overwritten in place — remove it first, then make the copies writable.
for f in whisper-cli libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib; do
    rm -f "$DEST_DIR/$f"
done
cp "$WHISPER_SRC" "$DEST_DIR/whisper-cli"
cp "$HOMEBREW_PREFIX/opt/whisper-cpp/lib/libwhisper.1.dylib" "$DEST_DIR/"
cp "$HOMEBREW_PREFIX/opt/ggml/lib/libggml.0.dylib" "$DEST_DIR/"
cp "$HOMEBREW_PREFIX/opt/ggml/lib/libggml-base.0.dylib" "$DEST_DIR/"
chmod u+w "$DEST_DIR"/whisper-cli "$DEST_DIR"/lib*.dylib
chmod +x "$DEST_DIR/whisper-cli"

# Rewrite whisper-cli to find all libs via @rpath
install_name_tool -add_rpath @executable_path "$DEST_DIR/whisper-cli" 2>/dev/null || true
install_name_tool -change "$HOMEBREW_PREFIX/opt/ggml/lib/libggml.0.dylib" @rpath/libggml.0.dylib "$DEST_DIR/whisper-cli"
install_name_tool -change "$HOMEBREW_PREFIX/opt/ggml/lib/libggml-base.0.dylib" @rpath/libggml-base.0.dylib "$DEST_DIR/whisper-cli"

# Rewrite libwhisper to find ggml libs via @loader_path
install_name_tool -add_rpath @loader_path "$DEST_DIR/libwhisper.1.dylib" 2>/dev/null || true
install_name_tool -change "$HOMEBREW_PREFIX/opt/ggml/lib/libggml.0.dylib" @rpath/libggml.0.dylib "$DEST_DIR/libwhisper.1.dylib" 2>/dev/null || true
install_name_tool -change "$HOMEBREW_PREFIX/opt/ggml/lib/libggml-base.0.dylib" @rpath/libggml-base.0.dylib "$DEST_DIR/libwhisper.1.dylib" 2>/dev/null || true

# Rewrite libggml to find libggml-base via @loader_path
install_name_tool -add_rpath @loader_path "$DEST_DIR/libggml.0.dylib" 2>/dev/null || true

# install_name_tool invalidates the original signatures. Apple Silicon
# refuses to run unsigned arm64 code at all (the process is SIGKILLed with
# status 9 before main), so re-sign everything ad hoc. Stripping the
# signature, as this script used to do, is exactly what produced that kill.
for f in libggml-base.0.dylib libggml.0.dylib libwhisper.1.dylib whisper-cli; do
    chmod u+w "$DEST_DIR/$f"
    codesign --force --sign - "$DEST_DIR/$f"
done

# Prove it actually launches; a bad bundle would otherwise shadow Homebrew.
if ! "$DEST_DIR/whisper-cli" --help >/dev/null 2>&1; then
    echo "Error: bundled whisper-cli does not run after signing (exit $?)."
    exit 1
fi

echo "Bundled whisper-cli + 3 dylibs to $DEST_DIR/"
