# Bundling whisper-cli: Design Approaches

**Date:** 2025-03-25
**Status:** Proposal
**Problem:** Copying Homebrew's `whisper-cli` binary and rewriting rpaths causes SIGKILL (exit 137) because `install_name_tool` invalidates the code signature, and macOS enforces signature integrity via `com.apple.provenance` extended attributes.

---

## Background

The current approach copies the Homebrew-installed `whisper-cli` and its dylibs, rewrites load paths with `install_name_tool`, then tries to strip signatures. This fails because:

1. `install_name_tool` modifications invalidate the existing ad-hoc code signature
2. The binary has `com.apple.provenance` xattr (set by macOS when downloaded/installed binaries are copied) which triggers stricter Gatekeeper enforcement
3. `codesign --remove-signature` alone is insufficient; macOS still kills unsigned binaries with provenance markers

The dependency chain includes runtime-loaded ggml backends (`libggml-metal.so`, `libggml-blas.so`, `libggml-cpu-*.so`) that are `dlopen`'d at runtime and not visible via `otool -L`, making the bundling problem even harder.

---

## Approach 1: Build whisper.cpp from Source as a C Library, Link Directly into Swift (RECOMMENDED)

### Overview

Instead of shelling out to `whisper-cli`, compile whisper.cpp as a static library and call its C API directly from Swift via a system library target in Package.swift. This completely eliminates the external binary, the dylib chain, and the code signing problem.

### Why This Works

whisper.cpp exposes a clean C API in `whisper.h` with these key functions:

```c
// Initialize a context from a model file
struct whisper_context * whisper_init_from_file(const char * path_model);

// Run full transcription pipeline
int whisper_full(struct whisper_context * ctx, struct whisper_full_params params, const float * samples, int n_samples);

// Get default parameters for a strategy (greedy or beam search)
struct whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy strategy);

// Get results
int whisper_full_n_segments(struct whisper_context * ctx);
const char * whisper_full_get_segment_text(struct whisper_context * ctx, int i_segment);

// Cleanup
void whisper_free(struct whisper_context * ctx);
```

This is everything VoiceDictation needs. The current `Transcriber.swift` shells out to `whisper-cli` with `-m model -f audio.wav --no-timestamps` and parses stdout. The C API does the same thing with a few function calls.

### Implementation Steps

#### Step 1: Build whisper.cpp + ggml as static libraries

Clone and build from source with CMake, producing static `.a` libraries:

```bash
#!/bin/bash
# scripts/build-whisper-lib.sh
set -e

WHISPER_VERSION="v1.7.5"  # pin to a known-good release
BUILD_DIR="$(pwd)/vendor/whisper-build"
INSTALL_DIR="$(pwd)/vendor/whisper-install"

# Clone if needed
if [ ! -d "$BUILD_DIR/whisper.cpp" ]; then
    git clone --depth 1 --branch "$WHISPER_VERSION" \
        https://github.com/ggerganov/whisper.cpp.git "$BUILD_DIR/whisper.cpp"
fi

cd "$BUILD_DIR/whisper.cpp"

cmake -B build \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_ACCELERATE=ON \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"

cmake --build build --config Release -j $(sysctl -n hw.ncpu)
cmake --install build
```

Key flags explained:
- `BUILD_SHARED_LIBS=OFF` — produces `libwhisper.a`, `libggml.a`, `libggml-base.a` etc. as static archives
- `GGML_METAL=ON` — enables Metal GPU acceleration
- `GGML_METAL_EMBED_LIBRARY=ON` — **critical**: embeds the Metal shader library (`.metallib`) directly into the static library as a C array, so there is no separate `.metallib` file to bundle at runtime. Without this, whisper would need to find a `.metallib` file at runtime.
- `GGML_BLAS=ON` + `GGML_ACCELERATE=ON` — uses Apple's Accelerate framework for BLAS operations (CPU fallback)
- `WHISPER_BUILD_EXAMPLES=OFF` — skips building `whisper-cli` and other example binaries (we don't need them)

After this, `$INSTALL_DIR` will contain:
```
vendor/whisper-install/
├── include/
│   ├── whisper.h
│   └── ggml.h (and other ggml headers)
└── lib/
    ├── libwhisper.a
    ├── libggml.a
    ├── libggml-base.a
    ├── libggml-metal.a
    ├── libggml-blas.a
    └── libggml-cpu.a
```

#### Step 2: Add a C system library target to Package.swift

SPM can link against pre-built static libraries using a `systemLibrary` target or, more practically, a C target with a `module.modulemap`:

```
Sources/
└── CWhisper/
    ├── include/
    │   ├── module.modulemap
    │   └── whisper-shim.h
    └── empty.c          # SPM requires at least one source file
```

**`module.modulemap`:**
```
module CWhisper {
    header "whisper-shim.h"
    link "whisper"
    link "ggml"
    link "ggml-base"
    link "ggml-metal"
    link "ggml-blas"
    link "ggml-cpu"
    export *
}
```

**`whisper-shim.h`:**
```c
#ifndef WHISPER_SHIM_H
#define WHISPER_SHIM_H
#include "../../vendor/whisper-install/include/whisper.h"
#endif
```

Note: The header path may need adjustment. An alternative is to copy `whisper.h` into `Sources/CWhisper/include/` during the build step.

**Updated `Package.swift`:**
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceDictation",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "vendor/whisper-install/lib",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "VoiceDictationLib",
            dependencies: ["CWhisper"],
            path: "Sources/VoiceDictationLib"
        ),
        .executableTarget(
            name: "VoiceDictation",
            dependencies: ["VoiceDictationLib"],
            path: "Sources/VoiceDictation"
        ),
        .testTarget(
            name: "VoiceDictationTests",
            dependencies: ["VoiceDictationLib"],
            path: "Tests/VoiceDictationTests"
        ),
    ]
)
```

#### Step 3: Replace Transcriber to use the C API directly

Create a new `WhisperEngine.swift` that wraps the C API:

```swift
import Foundation
import CWhisper

public class WhisperEngine {
    private var context: OpaquePointer?

    public init(modelPath: String) throws {
        context = whisper_init_from_file(modelPath)
        guard context != nil else {
            throw WhisperError.modelLoadFailed(modelPath)
        }
    }

    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
    }

    /// Transcribe a WAV file and return the text.
    public func transcribe(wavURL: URL) throws -> String {
        // Load WAV audio as Float32 PCM samples at 16kHz
        let samples = try loadWAVAsFloat32(url: wavURL)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.n_threads = 4

        let result = samples.withUnsafeBufferPointer { buf in
            whisper_full(context, params, buf.baseAddress, Int32(buf.count))
        }

        guard result == 0 else {
            throw WhisperError.transcriptionFailed(code: Int(result))
        }

        let nSegments = whisper_full_n_segments(context)
        var text = ""
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(context, i) {
                text += String(cString: cStr)
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Load a 16kHz mono WAV file as Float32 samples.
    private func loadWAVAsFloat32(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)

        // WAV header: first 44 bytes (standard PCM)
        // Verify RIFF header
        guard data.count > 44 else {
            throw WhisperError.invalidAudioFile
        }

        // Skip 44-byte WAV header, read 16-bit PCM samples
        let pcmData = data.subdata(in: 44..<data.count)
        let sampleCount = pcmData.count / 2  // 16-bit = 2 bytes per sample

        var floats = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawBuf in
            let int16Buf = rawBuf.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floats[i] = Float(int16Buf[i]) / 32768.0
            }
        }

        return floats
    }

    public enum WhisperError: Error, LocalizedError {
        case modelLoadFailed(String)
        case transcriptionFailed(code: Int)
        case invalidAudioFile

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let path):
                return "Failed to load whisper model: \(path)"
            case .transcriptionFailed(let code):
                return "Transcription failed with code \(code)"
            case .invalidAudioFile:
                return "Invalid or empty audio file"
            }
        }
    }
}
```

Then update `Transcriber.swift` to use `WhisperEngine` instead of `Process`:

```swift
// In Transcriber.swift, replace runTranscription with:
private func runTranscription(fileURL: URL, recordingDuration: TimeInterval) {
    isTranscribing = true

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            let engine = try WhisperEngine(modelPath: self.modelPath)
            let text = try engine.transcribe(wavURL: fileURL)

            DispatchQueue.main.async {
                self.isTranscribing = false
                if !text.isEmpty {
                    self.delegate?.transcriptionCompleted(text: text)
                }
                self.processQueue()
            }
        } catch {
            DispatchQueue.main.async {
                self.isTranscribing = false
                self.delegate?.transcriptionFailed(error: error.localizedDescription)
                self.processQueue()
            }
        }
    }
}
```

**Optimization:** For repeated transcriptions, keep a single `WhisperEngine` instance alive (it holds the loaded model in memory) rather than re-creating it each time. This avoids reloading the model from disk on every recording.

### Metal GPU Acceleration

Fully preserved. The `GGML_METAL=ON` and `GGML_METAL_EMBED_LIBRARY=ON` flags compile Metal shaders and embed them as a byte array in `libggml-metal.a`. At runtime, whisper creates a Metal device and compiles kernels from the embedded source. No external `.metallib` file needed.

The Swift app must link `Metal.framework` and `MetalKit.framework` (handled in the Package.swift `linkerSettings`).

### Runtime Dependencies

**None** beyond macOS system frameworks. The whisper model file (`.bin`) is the only external file needed, which `ModelManager.swift` already handles by downloading from HuggingFace.

### Trade-offs

| Aspect | Assessment |
|--------|------------|
| Eliminates Homebrew dependency | Yes, completely |
| Metal GPU acceleration | Fully preserved (embedded Metal library) |
| Code signing issues | Eliminated (no external binaries) |
| Build complexity | Medium — one-time CMake build step, then standard `swift build` |
| Maintenance | Must update `WHISPER_VERSION` when upgrading whisper.cpp |
| Binary size | Larger (static libs add ~5-15MB), but no external files |
| Build time | First build is slower (compiling whisper.cpp from C++), subsequent builds are fast |
| WAV parsing | Must handle WAV-to-float conversion in Swift (simple, shown above) |

### Complexity: Medium

The one-time setup is the hardest part. Once the static libraries are built and the module map is in place, day-to-day development uses standard `swift build` with no extra steps.

---

## Approach 2: Re-sign the Copied Binaries Properly

### Overview

Keep the current architecture (shell out to `whisper-cli` via `Process`), but fix the code signing issue by ad-hoc signing all modified binaries after `install_name_tool` changes.

### Implementation

Update `scripts/bundle-whisper.sh` to add proper ad-hoc signing:

```bash
#!/bin/bash
set -e

DEST_DIR=".build/debug"
HOMEBREW_PREFIX="$(brew --prefix)"

# ... (existing copy and install_name_tool commands) ...

# Remove quarantine/provenance xattrs
xattr -cr "$DEST_DIR/whisper-cli" 2>/dev/null || true
xattr -cr "$DEST_DIR/libwhisper.1.dylib" 2>/dev/null || true
xattr -cr "$DEST_DIR/libggml.0.dylib" 2>/dev/null || true
xattr -cr "$DEST_DIR/libggml-base.0.dylib" 2>/dev/null || true

# Ad-hoc re-sign everything (order matters: sign libraries before the binary)
codesign --force --sign - "$DEST_DIR/libggml-base.0.dylib"
codesign --force --sign - "$DEST_DIR/libggml.0.dylib"
codesign --force --sign - "$DEST_DIR/libwhisper.1.dylib"
codesign --force --sign - "$DEST_DIR/whisper-cli"

# Also need to bundle ggml runtime backends for Metal
GGML_BACKEND_DIR="$HOMEBREW_PREFIX/opt/ggml/libexec"
mkdir -p "$DEST_DIR/ggml-backends"
for backend in "$GGML_BACKEND_DIR"/libggml-*.so; do
    cp "$backend" "$DEST_DIR/ggml-backends/"
    codesign --force --sign - "$DEST_DIR/ggml-backends/$(basename $backend)"
done

# Copy the Metal library too
if [ -f "$GGML_BACKEND_DIR/ggml-metal.metallib" ]; then
    cp "$GGML_BACKEND_DIR/ggml-metal.metallib" "$DEST_DIR/ggml-backends/"
fi

# Set GGML_BACKEND_DIR environment variable when running whisper-cli
echo "Done. Run whisper-cli with: GGML_BACKEND_DIR=./ggml-backends ./whisper-cli ..."
```

The `Transcriber.swift` would also need to set the `GGML_BACKEND_DIR` environment variable on the `Process`:

```swift
process.environment = [
    "GGML_BACKEND_DIR": execURL.deletingLastPathComponent()
        .appendingPathComponent("ggml-backends").path
]
```

### Will `codesign --force --sign -` Fix the SIGKILL?

**Probably yes, but with caveats.** The key issue is:

1. `codesign --force --sign -` performs ad-hoc signing, creating a new valid code signature. This should satisfy macOS's signature check.
2. The `com.apple.provenance` xattr is the secondary problem. If `xattr -cr` fails with "Permission denied," it may be because SIP protects the attribute. In that case, you may need to copy the file to a new location (the copy won't inherit the xattr) rather than using `cp` which preserves xattrs. Use `cat` or `dd` instead:

```bash
# Instead of: cp "$WHISPER_SRC" "$DEST_DIR/whisper-cli"
# Use:
cat "$WHISPER_SRC" > "$DEST_DIR/whisper-cli"
chmod +x "$DEST_DIR/whisper-cli"
```

This avoids copying the `com.apple.provenance` xattr entirely.

### Metal GPU Acceleration

**Partially preserved, but fragile.** The runtime-loaded backends (`libggml-metal.so`, etc.) must be copied, re-signed, and pointed to via the `GGML_BACKEND_DIR` environment variable. The `.metallib` file must also be present. If ggml changes its backend loading mechanism or file layout, this breaks.

### Trade-offs

| Aspect | Assessment |
|--------|------------|
| Eliminates Homebrew dependency | At runtime yes, but requires Homebrew at build time |
| Metal GPU acceleration | Fragile — depends on correctly bundling runtime backends |
| Code signing issues | Likely solved with `cat` + `codesign --force --sign -` |
| Build complexity | Low — just a shell script |
| Maintenance | High — must track ggml backend changes, file layouts, env vars |
| Runtime dependencies | Multiple dylibs + .so backends + .metallib file |
| Failure modes | Many: wrong backend versions, missing metallib, env var issues |

### Complexity: Low to implement, High to maintain

### Key Risk

The ggml backend loading system (`dlopen` of `.so` files from a directory) is an implementation detail that changes between versions. The `GGML_BACKEND_DIR` environment variable may or may not be supported, and the set of required `.so` files changes. Every whisper-cpp or ggml version bump could break bundling.

---

## Approach 3: Build whisper.cpp from Source as a Standalone Static Binary

### Overview

Compile `whisper-cli` itself as a fully static binary with all dependencies linked in. No dylibs needed at all.

### Implementation

```bash
#!/bin/bash
set -e

WHISPER_VERSION="v1.7.5"
BUILD_DIR="$(pwd)/vendor/whisper-build"

if [ ! -d "$BUILD_DIR/whisper.cpp" ]; then
    git clone --depth 1 --branch "$WHISPER_VERSION" \
        https://github.com/ggerganov/whisper.cpp.git "$BUILD_DIR/whisper.cpp"
fi

cd "$BUILD_DIR/whisper.cpp"

cmake -B build \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_STATIC=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-framework Metal -framework MetalKit -framework Accelerate -framework Foundation"

cmake --build build --config Release -j $(sysctl -n hw.ncpu)

# The resulting binary is at build/bin/whisper-cli
# Copy to project
cp build/bin/whisper-cli ../../.build/debug/whisper-cli
```

With `BUILD_SHARED_LIBS=OFF` and `GGML_METAL_EMBED_LIBRARY=ON`, the resulting `whisper-cli` binary should have all whisper and ggml code statically linked, and the Metal shaders embedded. The only dynamic dependencies should be system frameworks (Metal, Accelerate, libc++, libSystem).

Verify with: `otool -L whisper-cli` — should show only system libraries under `/usr/lib/` and frameworks under `/System/Library/`.

### Metal GPU Acceleration

Preserved via `GGML_METAL_EMBED_LIBRARY=ON`. The Metal shader source code is compiled and embedded as a byte array in the binary at build time.

### Code Signing

Since we built the binary ourselves (not copied from Homebrew), there is no `com.apple.provenance` xattr. We can ad-hoc sign it trivially:

```bash
codesign --force --sign - whisper-cli
```

### Trade-offs

| Aspect | Assessment |
|--------|------------|
| Eliminates Homebrew dependency | Yes, completely |
| Metal GPU acceleration | Preserved (embedded Metal library) |
| Code signing issues | Eliminated (self-built binary, no provenance xattr) |
| Build complexity | Low-Medium — straightforward CMake build |
| Maintenance | Medium — must rebuild when upgrading whisper.cpp |
| Architecture | Keeps the Process-based shelling out approach |
| Binary size | Large (30-50MB statically linked binary) |
| Failure modes | Fewer than Approach 2, more than Approach 1 |
| Upgrades | Must rebuild the binary; can't just `brew upgrade` |

### Complexity: Low-Medium

### Caveat

Static linking on macOS has a nuance: you cannot statically link system frameworks (Metal, Accelerate). The binary will still dynamically link against these system frameworks, which is fine because they ship with macOS. The key benefit is eliminating all *third-party* dylib dependencies (libwhisper, libggml, etc.).

---

## Comparison Matrix

| Criterion | Approach 1: C API (Static Lib) | Approach 2: Re-sign Binaries | Approach 3: Static Binary |
|-----------|-------------------------------|------------------------------|--------------------------|
| Eliminates Homebrew at runtime | Yes | Yes | Yes |
| Eliminates external binary | Yes | No | No |
| Metal GPU acceleration | Full | Fragile | Full |
| Code signing safety | N/A (no ext. binary) | Probably works | Works |
| Build complexity | Medium | Low | Low-Medium |
| Maintenance burden | Low | High | Medium |
| Binary size impact | +5-15MB | +20MB (binary + dylibs + backends) | +30-50MB |
| Failure modes | Fewest | Most | Few |
| Architecture cleanliness | Best (no Process, no IPC) | Worst (fragile bundling) | OK (still shells out) |
| Testing ease | Best (unit-testable) | Worst | OK |

---

## Recommendation: Approach 1 (C API Static Library)

**Approach 1 is the clear winner.** Here is why:

### 1. It eliminates the root cause, not just the symptom

The SIGKILL problem exists because we are trying to bundle and modify someone else's binary. Approach 1 eliminates external binaries entirely. There is nothing to copy, nothing to re-sign, no dylib chains to manage, no runtime backends to discover.

### 2. Metal acceleration is rock-solid

With `GGML_METAL_EMBED_LIBRARY=ON`, the Metal shaders are baked into the static library. No `.metallib` files to find at runtime, no `GGML_BACKEND_DIR` environment variables, no `dlopen` of `.so` files. It just works.

### 3. Better architecture

Calling the C API directly eliminates an entire class of problems:
- No `Process` spawning and stdout parsing
- No timeout heuristics for the subprocess
- No risk of zombie processes
- Direct error codes instead of parsing stderr
- Can keep the model loaded in memory (faster subsequent transcriptions)
- Can report progress callbacks (whisper.h supports them)
- Unit-testable without the binary being present

### 4. Smaller and faster

A static library adds 5-15MB to the app binary. A bundled `whisper-cli` with all its dylibs and backends is 20-50MB. Plus, calling the C API directly avoids process spawn overhead and model reload time on each transcription (the model stays in memory).

### 5. Manageable complexity

The implementation has three parts:
1. **One-time setup script** (`scripts/build-whisper-lib.sh`) — ~20 lines of bash
2. **Module map + shim header** (`Sources/CWhisper/`) — 3 small files
3. **Swift wrapper** (`WhisperEngine.swift`) — ~80 lines of Swift
4. **Package.swift update** — add the CWhisper target and linker settings

The whisper.cpp C API is stable and well-documented. The module map approach is standard SPM practice for wrapping C libraries.

### Implementation Order

1. Run `scripts/build-whisper-lib.sh` to build the static libraries (one-time, or when upgrading)
2. Create `Sources/CWhisper/` with module map and shim header
3. Update `Package.swift` to add the CWhisper target
4. Create `WhisperEngine.swift` with the C API wrapper
5. Update `Transcriber.swift` to use `WhisperEngine` instead of `Process`
6. Update `BundledBinary.swift` — it becomes unnecessary (can be kept as a fallback)
7. Test with `swift build && .build/debug/VoiceDictation`

### What to Add to .gitignore

```
vendor/whisper-build/
vendor/whisper-install/
```

The built static libraries (`vendor/whisper-install/`) could optionally be committed to git for convenience (so collaborators don't need CMake), but they are ~15MB so it is better to have each developer run the build script once.

---

## Appendix: Alternative Considered and Rejected

### whisper.cpp's Built-in Swift Package

whisper.cpp does have a `Package.swift` in its repo that exposes a Swift-compatible target. However, it is designed to build whisper.cpp as part of the SPM dependency graph, which means:

- SPM would need to compile the entire whisper.cpp C++ codebase on every clean build
- Metal shader compilation within SPM is not well-supported
- The `GGML_METAL_EMBED_LIBRARY` CMake flag has no SPM equivalent
- Build times would be significantly longer

The pre-built static library approach (Approach 1) gives us the benefits of native integration without the SPM-C++ compilation pain. Build the C++ once with CMake (which handles Metal compilation correctly), then link the resulting `.a` files via SPM.

### Using whisper.cpp as an SPM Package Dependency

Adding `https://github.com/ggerganov/whisper.cpp` as a `.package(url:)` dependency in Package.swift is theoretically possible but practically problematic:

- whisper.cpp's SPM support is experimental and community-maintained
- Metal support requires `GGML_METAL_EMBED_LIBRARY` which is a CMake-only feature
- C++ interop in SPM requires Swift 5.9+ `cxxInterop` settings that add complexity
- Version pinning is less reliable than our own vendored build

The vendored static library approach is more reliable for production use.
