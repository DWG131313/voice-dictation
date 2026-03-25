# VoiceDictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Important:** After implementation, invoke Danny's two review agents — one SWE agent and one plan reviewer agent — for code review.

**Goal:** Build a macOS menu bar app that provides system-wide push-to-talk voice transcription via whisper.cpp, pasting results into the frontmost app.

**Architecture:** Swift menu bar agent (no dock icon, no main window) with 7 components: PermissionManager, StatusManager, HotkeyManager, AudioRecorder, Transcriber, PasteEngine, ModelManager. Components communicate through delegate callbacks. The app shells out to a Homebrew-installed whisper-cpp binary for transcription.

**Tech Stack:** Swift 5.9+, macOS 13+ (Ventura), Xcode, AVAudioEngine, CGEvent API, Foundation Process, SF Symbols

**Spec:** `docs/superpowers/specs/2026-03-24-voice-dictation-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `VoiceDictation/AppDelegate.swift` | App entry point, menu bar setup, component wiring |
| `VoiceDictation/PermissionManager.swift` | Accessibility + Microphone permission checks, runtime monitoring |
| `VoiceDictation/StatusManager.swift` | Menu bar icon state machine, dropdown menu |
| `VoiceDictation/HotkeyManager.swift` | Globe key event tap, Escape cancel, protocol for swappable strategies |
| `VoiceDictation/AudioRecorder.swift` | AVAudioEngine recording to 16kHz mono WAV |
| `VoiceDictation/Transcriber.swift` | whisper-cpp CLI invocation, output parsing, queue management |
| `VoiceDictation/PasteEngine.swift` | Clipboard save/paste/restore via CGEvent |
| `VoiceDictation/ModelManager.swift` | Model download, validation, path resolution |
| `VoiceDictation/Info.plist` | LSUIElement, deployment target, bundle ID |
| `VoiceDictation/VoiceDictation.entitlements` | Hardened runtime entitlements |
| `VoiceDictationTests/TranscriberTests.swift` | Unit tests for output parsing and queue logic |
| `VoiceDictationTests/ModelManagerTests.swift` | Unit tests for path resolution and validation |

---

### Task 1: Xcode Project Scaffold

**Files:**
- Create: `VoiceDictation.xcodeproj` (via `swift package init` + Xcode project)
- Create: `VoiceDictation/AppDelegate.swift`
- Create: `VoiceDictation/Info.plist`
- Create: `VoiceDictation/VoiceDictation.entitlements`

- [ ] **Step 1: Create the project structure and .gitignore**

Create directory structure and a Swift-appropriate .gitignore:

```
mkdir -p VoiceDictation
mkdir -p VoiceDictationTests
```

Create `.gitignore`:

```
.build/
.DS_Store
*.xcodeproj/xcuserdata/
*.xcworkspace/xcuserdata/
DerivedData/
*.swp
```

- [ ] **Step 2: Create Info.plist**

Create `VoiceDictation/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VoiceDictation</string>
    <key>CFBundleIdentifier</key>
    <string>com.danny.VoiceDictation</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceDictation needs microphone access to record your voice for transcription.</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>VoiceDictation</string>
</dict>
</plist>
```

- [ ] **Step 3: Create entitlements file**

Create `VoiceDictation/VoiceDictation.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Create minimal AppDelegate with menu bar icon**

Create `VoiceDictation/AppDelegate.swift`:

```swift
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceDictation")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceDictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}
```

- [ ] **Step 5: Create Package.swift for building**

Since we want to avoid needing to open Xcode, create a `Package.swift` at the project root that builds the app as an executable. We'll handle the .app bundle structure with a build script.

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceDictation",
    platforms: [.macOS(.v13)],
    targets: [
        // Library target with all logic (testable)
        .target(
            name: "VoiceDictationLib",
            path: "VoiceDictation",
            exclude: ["main.swift", "Info.plist", "VoiceDictation.entitlements"],
            sources: [
                "StatusManager.swift",
                "PermissionManager.swift",
                "HotkeyManager.swift",
                "AudioRecorder.swift",
                "Transcriber.swift",
                "PasteEngine.swift",
                "ModelManager.swift",
                "AppDelegate.swift",
            ]
        ),
        // Thin executable — just the entry point
        .executableTarget(
            name: "VoiceDictation",
            dependencies: ["VoiceDictationLib"],
            path: "VoiceDictation",
            sources: ["main.swift"]
        ),
        .testTarget(
            name: "VoiceDictationTests",
            dependencies: ["VoiceDictationLib"],
            path: "VoiceDictationTests"
        ),
    ]
)
```

Also create `VoiceDictation/main.swift` (the thin entry point):

```swift
import Cocoa
import VoiceDictationLib

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

And remove `@main` from `AppDelegate.swift` since `main.swift` handles the entry point.

Note: The `AppDelegate` class and all other types must be declared `public` so they are visible from the executable target.

- [ ] **Step 6: Build and verify menu bar icon appears**

Run: `swift build`
Then run: `.build/debug/VoiceDictation`
Expected: App launches with no dock icon, mic icon appears in menu bar, clicking shows dropdown with "Status: Ready" and "Quit VoiceDictation".

- [ ] **Step 7: Commit**

```bash
git add .gitignore Package.swift VoiceDictation/AppDelegate.swift VoiceDictation/main.swift VoiceDictation/Info.plist VoiceDictation/VoiceDictation.entitlements
git commit -m "scaffold: project with menu bar icon and build system"
```

---

### Task 2: StatusManager — Menu Bar State Machine

**Files:**
- Create: `VoiceDictation/StatusManager.swift`
- Modify: `VoiceDictation/AppDelegate.swift`

- [ ] **Step 1: Create StatusManager with state enum**

Create `VoiceDictation/StatusManager.swift`:

```swift
import Cocoa

enum AppStatus {
    case idle
    case recording
    case transcribing(queued: Int)
    case error(message: String)
    case downloading(progress: Double)
    case permissionNeeded(String)
}

class StatusManager {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private let modelMenuItem: NSMenuItem
    private var errorClearTimer: Timer?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        modelMenuItem = NSMenuItem(title: "Model: base.en", action: nil, keyEquivalent: "")

        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(modelMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceDictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        updateStatus(.idle)
    }

    func updateStatus(_ status: AppStatus) {
        errorClearTimer?.invalidate()

        guard let button = statusItem.button else { return }

        switch status {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceDictation — Ready")
            button.contentTintColor = nil
            statusMenuItem.title = "Status: Ready"

        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceDictation — Recording")
            button.contentTintColor = .systemRed
            statusMenuItem.title = "Status: Recording..."

        case .transcribing(let queued):
            button.image = NSImage(systemSymbolName: "mic.badge.ellipsis", accessibilityDescription: "VoiceDictation — Transcribing")
            button.contentTintColor = nil
            if queued > 0 {
                statusMenuItem.title = "Status: Transcribing... (\(queued) queued)"
            } else {
                statusMenuItem.title = "Status: Transcribing..."
            }

        case .error(let message):
            button.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "VoiceDictation — Error")
            button.contentTintColor = .systemOrange
            statusMenuItem.title = "Error: \(message)"
            errorClearTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.updateStatus(.idle)
            }

        case .downloading(let progress):
            button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "VoiceDictation — Downloading")
            button.contentTintColor = nil
            let percent = Int(progress * 100)
            statusMenuItem.title = "Downloading model... \(percent)%"

        case .permissionNeeded(let permission):
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "VoiceDictation — Permission Needed")
            button.contentTintColor = .systemYellow
            statusMenuItem.title = "Permission needed: \(permission)"
        }
    }
}
```

- [ ] **Step 2: Update AppDelegate to use StatusManager**

Replace the manual status bar setup in `AppDelegate.swift` with:

```swift
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusManager: StatusManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusManager = StatusManager()
    }
}
```

- [ ] **Step 3: Build and verify state transitions**

Run: `swift build && .build/debug/VoiceDictation`
Expected: Menu bar shows mic icon, dropdown shows "Status: Ready", "Model: base.en", and "Quit".

- [ ] **Step 4: Commit**

```bash
git add VoiceDictation/StatusManager.swift VoiceDictation/AppDelegate.swift
git commit -m "feat: add StatusManager with menu bar state machine"
```

---

### Task 3: PermissionManager

**Files:**
- Create: `VoiceDictation/PermissionManager.swift`
- Modify: `VoiceDictation/AppDelegate.swift`

- [ ] **Step 1: Create PermissionManager**

Create `VoiceDictation/PermissionManager.swift`:

```swift
import Cocoa
import AVFoundation

protocol PermissionManagerDelegate: AnyObject {
    func permissionStatusChanged(accessibility: Bool, microphone: Bool)
}

class PermissionManager {
    weak var delegate: PermissionManagerDelegate?

    private var pollingTimer: Timer?
    private(set) var isAccessibilityGranted: Bool = false
    private(set) var isMicrophoneGranted: Bool = false

    var allPermissionsGranted: Bool {
        isAccessibilityGranted && isMicrophoneGranted
    }

    func checkPermissions() {
        checkAccessibility()
        checkMicrophone()
    }

    func requestPermissions() {
        // Accessibility: prompt the user via system dialog
        let options = [kAXTrustedCheckPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options)

        // Microphone: request via AVFoundation
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.isMicrophoneGranted = granted
                self?.notifyDelegate()
            }
        }
    }

    func startMonitoring() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func checkGlobeKeySetting() -> Bool {
        // Read AppleFnUsageType from com.apple.HIToolbox defaults
        // 0 = Do Nothing, 1 = Change Input Source, 2 = Show Emoji & Symbols, 3 = Start Dictation
        let fnUsageType = UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"] as? Int
        // nil or 0 means "Do Nothing" — that's what we want
        return fnUsageType == nil || fnUsageType == 0
    }

    private func checkAccessibility() {
        let wasGranted = isAccessibilityGranted
        isAccessibilityGranted = AXIsProcessTrusted()
        if wasGranted != isAccessibilityGranted {
            notifyDelegate()
        }
    }

    private func checkMicrophone() {
        let wasGranted = isMicrophoneGranted
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            isMicrophoneGranted = true
        default:
            isMicrophoneGranted = false
        }
        if wasGranted != isMicrophoneGranted {
            notifyDelegate()
        }
    }

    private func notifyDelegate() {
        delegate?.permissionStatusChanged(
            accessibility: isAccessibilityGranted,
            microphone: isMicrophoneGranted
        )
    }
}
```

- [ ] **Step 2: Wire PermissionManager into AppDelegate**

Update `AppDelegate.swift` to create PermissionManager, check permissions at launch, and respond to changes:

```swift
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusManager: StatusManager!
    private var permissionManager: PermissionManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusManager = StatusManager()
        permissionManager = PermissionManager()
        permissionManager.delegate = self

        permissionManager.checkPermissions()

        if !permissionManager.allPermissionsGranted {
            permissionManager.requestPermissions()
        }

        if !permissionManager.checkGlobeKeySetting() {
            showGlobeKeyWarning()
        }

        permissionManager.startMonitoring()
    }

    private func showGlobeKeyWarning() {
        let alert = NSAlert()
        alert.messageText = "Globe Key Configuration Needed"
        alert.informativeText = "VoiceDictation uses the Globe key for push-to-talk. Please go to System Settings > Keyboard and set \"Press Globe key to\" to \"Do Nothing\"."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension AppDelegate: PermissionManagerDelegate {
    func permissionStatusChanged(accessibility: Bool, microphone: Bool) {
        if !accessibility {
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
        } else if !microphone {
            statusManager.updateStatus(.permissionNeeded("Microphone"))
        } else {
            statusManager.updateStatus(.idle)
        }
    }
}
```

- [ ] **Step 3: Build and test permission flow**

Run: `swift build && .build/debug/VoiceDictation`
Expected: On first run, system prompts for Accessibility and Microphone. If Globe key is set to emoji/dictation, warning alert appears. Menu bar shows permission status.

- [ ] **Step 4: Commit**

```bash
git add VoiceDictation/PermissionManager.swift VoiceDictation/AppDelegate.swift
git commit -m "feat: add PermissionManager with accessibility and mic checks"
```

---

### Task 4: HotkeyManager — Globe Key Detection

**Files:**
- Create: `VoiceDictation/HotkeyManager.swift`
- Modify: `VoiceDictation/AppDelegate.swift`

- [ ] **Step 1: Create HotkeyManager protocol and Globe key implementation**

Create `VoiceDictation/HotkeyManager.swift`:

```swift
import Cocoa
import Carbon.HIToolbox

protocol HotkeyDelegate: AnyObject {
    func hotkeyDidStartPress()
    func hotkeyDidEndPress()
    func hotkeyCancelled()
}

protocol HotkeyStrategy {
    var delegate: HotkeyDelegate? { get set }
    func start()
    func stop()
}

class GlobeKeyStrategy: HotkeyStrategy {
    weak var delegate: HotkeyDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    func start() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let strategy = Unmanaged<GlobeKeyStrategy>.fromOpaque(refcon).takeUnretainedValue()
                return strategy.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap — Accessibility permission may not be granted")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged {
            let flags = event.flags
            let fnPressed = flags.contains(.maskSecondaryFn)

            if fnPressed && !isPressed {
                isPressed = true
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyDidStartPress()
                }
            } else if !fnPressed && isPressed {
                isPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyDidEndPress()
                }
            }
        }

        // Check for Escape key to cancel during recording
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == kVK_Escape && isPressed {
                isPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.hotkeyCancelled()
                }
                return nil // Consume the Escape event
            }
        }

        return Unmanaged.passUnretained(event)
    }
}

class HotkeyManager {
    weak var delegate: HotkeyDelegate? {
        didSet { strategy?.delegate = delegate }
    }
    private var strategy: HotkeyStrategy?

    func start(strategy: HotkeyStrategy? = nil) {
        self.strategy = strategy ?? GlobeKeyStrategy()
        self.strategy?.delegate = delegate
        self.strategy?.start()
    }

    func stop() {
        strategy?.stop()
    }
}
```

- [ ] **Step 2: Wire HotkeyManager into AppDelegate for testing**

Add HotkeyManager to AppDelegate and log key presses to verify Globe key detection works:

```swift
// Add to AppDelegate properties:
private var hotkeyManager: HotkeyManager!

// Add to applicationDidFinishLaunching, after permission checks:
hotkeyManager = HotkeyManager()
hotkeyManager.delegate = self
if permissionManager.isAccessibilityGranted {
    hotkeyManager.start()
}

// Add HotkeyDelegate conformance:
extension AppDelegate: HotkeyDelegate {
    func hotkeyDidStartPress() {
        print("Globe key pressed — start recording")
        statusManager.updateStatus(.recording)
    }

    func hotkeyDidEndPress() {
        print("Globe key released — stop recording, start transcription")
        statusManager.updateStatus(.transcribing(queued: 0))
        // Temporary: return to idle after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.statusManager.updateStatus(.idle)
        }
    }

    func hotkeyCancelled() {
        print("Recording cancelled")
        statusManager.updateStatus(.idle)
    }
}
```

- [ ] **Step 3: Build and manually test Globe key**

Run: `swift build && .build/debug/VoiceDictation`
Test: Hold Globe key — menu bar should turn red, console prints "Globe key pressed". Release — shows transcribing state, then returns to idle. Press Escape while holding — shows "Recording cancelled".

**If Globe key doesn't work:** Check System Settings > Keyboard > "Press Globe key to" is set to "Do Nothing". If it still doesn't work after that, this validates the risk — we'll switch to a configurable hotkey.

- [ ] **Step 4: Commit**

```bash
git add VoiceDictation/HotkeyManager.swift VoiceDictation/AppDelegate.swift
git commit -m "feat: add HotkeyManager with Globe key event tap"
```

---

### Task 5: AudioRecorder

**Files:**
- Create: `VoiceDictation/AudioRecorder.swift`
- Modify: `VoiceDictation/AppDelegate.swift`

- [ ] **Step 1: Create AudioRecorder**

Create `VoiceDictation/AudioRecorder.swift`:

```swift
import AVFoundation
import Cocoa

protocol AudioRecorderDelegate: AnyObject {
    func recordingDidStart()
    func recordingDidFinish(fileURL: URL, duration: TimeInterval)
    func recordingDidFail(error: String)
    func recordingDiscarded()
}

class AudioRecorder {
    weak var delegate: AudioRecorderDelegate?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var recordingURL: URL?
    private var recordingStartTime: Date?
    private let minimumDuration: TimeInterval = 0.5

    private let tickOnSound = NSSound(named: .init("Tink"))
    private let tickOffSound = NSSound(named: .init("Pop"))

    func startRecording() {
        let inputNode = engine.inputNode

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voice-dictation-\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        recordingURL = fileURL

        // Target format: 16kHz mono PCM 16-bit (what whisper.cpp expects)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        do {
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: outputFormat.settings
            )
        } catch {
            delegate?.recordingDidFail(error: "Failed to create audio file: \(error.localizedDescription)")
            return
        }

        // Record at hardware's native format, convert each buffer before writing
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let convertFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        converter = AVAudioConverter(from: hardwareFormat, to: convertFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let audioFile = self.audioFile,
                  let converter = self.converter else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / hardwareFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: convertFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil {
                do {
                    try audioFile.write(from: convertedBuffer)
                } catch {
                    print("Error writing audio buffer: \(error)")
                }
            }
        }

        do {
            try engine.start()
            recordingStartTime = Date()
            tickOnSound?.play()
            delegate?.recordingDidStart()
        } catch {
            cleanup()
            delegate?.recordingDidFail(error: "Microphone in use by another app")
        }
    }

    func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil

        tickOffSound?.play()

        guard let startTime = recordingStartTime,
              let fileURL = recordingURL else {
            delegate?.recordingDiscarded()
            return
        }

        let duration = Date().timeIntervalSince(startTime)

        if duration < minimumDuration {
            // Too short — accidental tap
            cleanupFile(at: fileURL)
            delegate?.recordingDiscarded()
            return
        }

        delegate?.recordingDidFinish(fileURL: fileURL, duration: duration)
        recordingStartTime = nil
    }

    func cancelRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil

        if let fileURL = recordingURL {
            cleanupFile(at: fileURL)
        }

        recordingStartTime = nil
        delegate?.recordingDiscarded()
    }

    func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanup() {
        audioFile = nil
        if let url = recordingURL {
            cleanupFile(at: url)
        }
        recordingURL = nil
        recordingStartTime = nil
    }
}
```

Note: The tap records at the hardware's native format (typically 44.1/48kHz) and uses `AVAudioConverter` to downsample each buffer to 16kHz mono before writing to the WAV file. This ensures whisper-cpp gets the format it expects.

- [ ] **Step 2: Wire AudioRecorder into AppDelegate**

Update the HotkeyDelegate methods in AppDelegate to use AudioRecorder:

```swift
// Add property:
private var audioRecorder: AudioRecorder!

// In applicationDidFinishLaunching:
audioRecorder = AudioRecorder()
audioRecorder.delegate = self

// Update HotkeyDelegate:
extension AppDelegate: HotkeyDelegate {
    func hotkeyDidStartPress() {
        statusManager.updateStatus(.recording)
        audioRecorder.startRecording()
    }

    func hotkeyDidEndPress() {
        audioRecorder.stopRecording()
    }

    func hotkeyCancelled() {
        audioRecorder.cancelRecording()
        statusManager.updateStatus(.idle)
    }
}

// Add AudioRecorderDelegate:
extension AppDelegate: AudioRecorderDelegate {
    func recordingDidStart() {
        // Already handled by hotkeyDidStartPress
    }

    func recordingDidFinish(fileURL: URL, duration: TimeInterval) {
        statusManager.updateStatus(.transcribing(queued: 0))
        print("Recording saved to \(fileURL.path), duration: \(String(format: "%.1f", duration))s")
        // TODO: send to Transcriber
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.statusManager.updateStatus(.idle)
        }
    }

    func recordingDidFail(error: String) {
        statusManager.updateStatus(.error(message: error))
    }

    func recordingDiscarded() {
        statusManager.updateStatus(.idle)
    }
}
```

- [ ] **Step 3: Build and test recording**

Run: `swift build && .build/debug/VoiceDictation`
Test: Hold Globe key, speak, release. Check console for "Recording saved to /tmp/..." with duration. Verify the WAV file exists and is playable (`afplay /tmp/voice-dictation-*.wav`). Verify tick sounds play on start/stop. Test short press (<0.5s) is discarded.

- [ ] **Step 4: Commit**

```bash
git add VoiceDictation/AudioRecorder.swift VoiceDictation/AppDelegate.swift
git commit -m "feat: add AudioRecorder with AVAudioEngine and tick sounds"
```

---

### Task 6: ModelManager

**Files:**
- Create: `VoiceDictation/ModelManager.swift`
- Create: `VoiceDictationTests/ModelManagerTests.swift`

- [ ] **Step 1: Write tests for ModelManager path resolution**

Create `VoiceDictationTests/ModelManagerTests.swift`:

```swift
import XCTest
@testable import VoiceDictation

final class ModelManagerTests: XCTestCase {
    func testModelDirectoryPath() {
        let manager = ModelManager()
        let path = manager.modelDirectoryURL.path
        XCTAssertTrue(path.contains("Application Support/VoiceDictation/models"))
    }

    func testModelFilePath() {
        let manager = ModelManager()
        let path = manager.modelFileURL.path
        XCTAssertTrue(path.hasSuffix("ggml-base.en.bin"))
    }

    func testModelNotPresentInitially() {
        // Uses a temp directory to avoid interfering with real model
        let manager = ModelManager()
        // Model may or may not exist depending on test environment
        // This test verifies the check doesn't crash
        _ = manager.isModelPresent
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `ModelManager` not defined.

- [ ] **Step 3: Create ModelManager**

Create `VoiceDictation/ModelManager.swift`:

```swift
import Foundation

protocol ModelManagerDelegate: AnyObject {
    func modelDownloadProgress(_ progress: Double)
    func modelDownloadCompleted()
    func modelDownloadFailed(error: String)
}

class ModelManager: NSObject {
    weak var delegate: ModelManagerDelegate?

    private static let modelFileName = "ggml-base.en.bin"
    private static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!
    private static let expectedMinSize: Int64 = 140_000_000 // ~148MB, use min threshold

    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession!
    private var retryCount = 0
    private static let maxRetries = 3

    var modelDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VoiceDictation/models")
    }

    var modelFileURL: URL {
        modelDirectoryURL.appendingPathComponent(Self.modelFileName)
    }

    var isModelPresent: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelFileURL.path) else { return false }
        guard let attrs = try? fm.attributesOfItem(atPath: modelFileURL.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size >= Self.expectedMinSize
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func downloadModelIfNeeded() {
        if isModelPresent {
            delegate?.modelDownloadCompleted()
            return
        }

        // Create directory
        try? FileManager.default.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)

        startDownload()
    }

    private func startDownload() {
        retryCount += 1
        downloadTask = urlSession.downloadTask(with: Self.downloadURL)
        downloadTask?.resume()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // Remove existing file if present (partial/corrupt)
            if FileManager.default.fileExists(atPath: modelFileURL.path) {
                try FileManager.default.removeItem(at: modelFileURL)
            }
            try FileManager.default.moveItem(at: location, to: modelFileURL)

            if isModelPresent {
                retryCount = 0
                delegate?.modelDownloadCompleted()
            } else {
                try? FileManager.default.removeItem(at: modelFileURL)
                handleDownloadFailure(error: "Downloaded file is too small — may be corrupted")
            }
        } catch {
            handleDownloadFailure(error: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        delegate?.modelDownloadProgress(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            handleDownloadFailure(error: error.localizedDescription)
        }
    }

    private func handleDownloadFailure(error: String) {
        if retryCount < Self.maxRetries {
            let delay = pow(2.0, Double(retryCount)) // Exponential backoff: 2, 4, 8 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startDownload()
            }
        } else {
            retryCount = 0
            delegate?.modelDownloadFailed(error: "Model download failed after \(Self.maxRetries) attempts: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add VoiceDictation/ModelManager.swift VoiceDictationTests/ModelManagerTests.swift
git commit -m "feat: add ModelManager with download, validation, and retry"
```

---

### Task 7: Transcriber — whisper-cpp CLI Wrapper

**Files:**
- Create: `VoiceDictation/Transcriber.swift`
- Create: `VoiceDictationTests/TranscriberTests.swift`

- [ ] **Step 1: Write tests for Transcriber output parsing**

Create `VoiceDictationTests/TranscriberTests.swift`:

```swift
import XCTest
@testable import VoiceDictation

final class TranscriberTests: XCTestCase {
    func testParseWhisperOutput() {
        let output = """
        [00:00:00.000 --> 00:00:03.000]   Hello, this is a test.
        [00:00:03.000 --> 00:00:05.000]   Second sentence.
        """
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseWhisperOutputNoTimestamps() {
        let output = "  Hello, this is a test.\n  Second sentence.\n"
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "Hello, this is a test. Second sentence.")
    }

    func testParseEmptyOutput() {
        let result = Transcriber.parseOutput("")
        XCTAssertEqual(result, "")
    }

    func testParseWhisperOutputWithBlankAudio() {
        let output = "[BLANK_AUDIO]\n"
        let result = Transcriber.parseOutput(output)
        XCTAssertEqual(result, "")
    }

    func testFindBinaryPath() {
        // This test verifies the resolution logic doesn't crash
        // Whether it finds a binary depends on the test environment
        _ = Transcriber.findBinaryPath()
    }

    func testTimeoutCalculation() {
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 1.0), 10.0)
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 5.0), 15.0)
        XCTAssertEqual(Transcriber.calculateTimeout(recordingDuration: 2.0), 10.0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL — `Transcriber` not defined.

- [ ] **Step 3: Create Transcriber**

Create `VoiceDictation/Transcriber.swift`:

```swift
import Foundation

protocol TranscriberDelegate: AnyObject {
    func transcriptionCompleted(text: String)
    func transcriptionFailed(error: String)
    func transcriptionQueueUpdated(count: Int)
}

class Transcriber {
    weak var delegate: TranscriberDelegate?

    private var modelPath: String
    private var queue: [(URL, TimeInterval)] = []
    private var isTranscribing = false
    private let maxQueueDepth = 3

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func transcribe(fileURL: URL, recordingDuration: TimeInterval) {
        if isTranscribing {
            if queue.count >= maxQueueDepth {
                // Drop oldest
                let dropped = queue.removeFirst()
                try? FileManager.default.removeItem(at: dropped.0)
            }
            queue.append((fileURL, recordingDuration))
            delegate?.transcriptionQueueUpdated(count: queue.count)
            return
        }

        runTranscription(fileURL: fileURL, recordingDuration: recordingDuration)
    }

    private func runTranscription(fileURL: URL, recordingDuration: TimeInterval) {
        guard let binaryPath = Self.findBinaryPath() else {
            delegate?.transcriptionFailed(error: "whisper-cpp not found. Install via: brew install whisper-cpp")
            return
        }

        isTranscribing = true
        let timeout = Self.calculateTimeout(recordingDuration: recordingDuration)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = [
                "-m", self.modelPath,
                "-f", fileURL.path,
                "--no-timestamps"
            ]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.isTranscribing = false
                    self.delegate?.transcriptionFailed(error: "Failed to run whisper-cpp: \(error.localizedDescription)")
                    self.processQueue()
                }
                return
            }

            // Timeout handling
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()

            // Clean up WAV file
            try? FileManager.default.removeItem(at: fileURL)

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self.isTranscribing = false

                if process.terminationStatus != 0 {
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errString = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    self.delegate?.transcriptionFailed(error: errString)
                } else {
                    let text = Self.parseOutput(output)
                    if !text.isEmpty {
                        self.delegate?.transcriptionCompleted(text: text)
                    }
                    // Empty text = silence, no paste needed
                }

                self.processQueue()
            }
        }
    }

    private func processQueue() {
        guard !queue.isEmpty else { return }

        let (fileURL, duration) = queue.removeFirst()
        delegate?.transcriptionQueueUpdated(count: queue.count)

        // Small delay between queued transcriptions
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.runTranscription(fileURL: fileURL, recordingDuration: duration)
        }
    }

    // MARK: - Static helpers (testable)

    static func parseOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        var result: [String] = []

        for line in lines {
            var cleaned = line

            // Remove timestamp brackets if present: [00:00:00.000 --> 00:00:03.000]
            if let bracketRange = cleaned.range(of: #"\[.*?\]"#, options: .regularExpression) {
                cleaned = String(cleaned[bracketRange.upperBound...])
            }

            cleaned = cleaned.trimmingCharacters(in: .whitespaces)

            // Skip blank audio markers
            if cleaned == "[BLANK_AUDIO]" || cleaned.isEmpty {
                continue
            }

            result.append(cleaned)
        }

        return result.joined(separator: " ")
    }

    static func findBinaryPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp"
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func calculateTimeout(recordingDuration: TimeInterval) -> TimeInterval {
        max(10.0, recordingDuration * 3.0)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS for all TranscriberTests

- [ ] **Step 5: Commit**

```bash
git add VoiceDictation/Transcriber.swift VoiceDictationTests/TranscriberTests.swift
git commit -m "feat: add Transcriber with whisper-cpp CLI wrapper and queue"
```

---

### Task 8: PasteEngine

**Files:**
- Create: `VoiceDictation/PasteEngine.swift`

- [ ] **Step 1: Create PasteEngine**

Create `VoiceDictation/PasteEngine.swift`:

```swift
import Cocoa
import Carbon.HIToolbox

class PasteEngine {
    func paste(text: String) {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard (string only for v1)
        let previousString = pasteboard.string(forType: .string)

        // 2. Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Simulate Cmd+V
        simulatePaste()

        // 4. Restore clipboard after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            pasteboard.clearContents()
            if let previous = previousString {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd + V
        guard let cmdVDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            return
        }

        cmdVDown.flags = .maskCommand
        cmdVUp.flags = .maskCommand

        cmdVDown.post(tap: .cghidEventTap)
        cmdVUp.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add VoiceDictation/PasteEngine.swift
git commit -m "feat: add PasteEngine with clipboard save/paste/restore"
```

---

### Task 9: Wire Everything Together

**Files:**
- Modify: `VoiceDictation/AppDelegate.swift`

- [ ] **Step 1: Complete AppDelegate with all components wired**

Rewrite `AppDelegate.swift` to connect all components in the full flow:

```swift
import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusManager: StatusManager!
    private var permissionManager: PermissionManager!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var transcriber: Transcriber!
    private var pasteEngine: PasteEngine!
    private var modelManager: ModelManager!
    private var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusManager = StatusManager()
        permissionManager = PermissionManager()
        permissionManager.delegate = self

        audioRecorder = AudioRecorder()
        audioRecorder.delegate = self

        pasteEngine = PasteEngine()

        modelManager = ModelManager()
        modelManager.delegate = self

        hotkeyManager = HotkeyManager()
        hotkeyManager.delegate = self

        // Register as login item (macOS 13+)
        try? SMAppService.mainApp.register()

        // Check permissions
        permissionManager.checkPermissions()

        if !permissionManager.allPermissionsGranted {
            permissionManager.requestPermissions()
        }

        // Check Globe key setting
        if !permissionManager.checkGlobeKeySetting() {
            showGlobeKeyWarning()
        }

        // Check for whisper-cpp binary at startup
        if Transcriber.findBinaryPath() == nil {
            statusManager.updateStatus(.error(message: "whisper-cpp not found. Run: brew install whisper-cpp"))
        }

        // Start permission monitoring
        permissionManager.startMonitoring()

        // Ensure model is downloaded
        modelManager.downloadModelIfNeeded()
    }

    private func showGlobeKeyWarning() {
        let alert = NSAlert()
        alert.messageText = "Globe Key Configuration Needed"
        alert.informativeText = "VoiceDictation uses the Globe key for push-to-talk. Please go to System Settings > Keyboard and set \"Press Globe key to\" to \"Do Nothing\"."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startListening() {
        guard permissionManager.isAccessibilityGranted else {
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
            return
        }

        guard Transcriber.findBinaryPath() != nil else {
            statusManager.updateStatus(.error(message: "whisper-cpp not found. Run: brew install whisper-cpp"))
            return
        }

        transcriber = Transcriber(modelPath: modelManager.modelFileURL.path)
        transcriber.delegate = self

        hotkeyManager.start()
        statusManager.updateStatus(.idle)
    }

    private func showReadyAlert() {
        // Only show on first launch
        guard isFirstLaunch else { return }
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

        let alert = NSAlert()
        alert.messageText = "VoiceDictation is Ready"
        alert.informativeText = "Hold the Globe key to dictate. Release to transcribe and paste."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - PermissionManagerDelegate
extension AppDelegate: PermissionManagerDelegate {
    func permissionStatusChanged(accessibility: Bool, microphone: Bool) {
        if !accessibility {
            hotkeyManager.stop()
            statusManager.updateStatus(.permissionNeeded("Accessibility"))
        } else if !microphone {
            statusManager.updateStatus(.permissionNeeded("Microphone"))
        } else {
            if transcriber == nil && modelManager.isModelPresent {
                startListening()
            }
        }
    }
}

// MARK: - HotkeyDelegate
extension AppDelegate: HotkeyDelegate {
    func hotkeyDidStartPress() {
        guard permissionManager.isMicrophoneGranted else {
            statusManager.updateStatus(.permissionNeeded("Microphone"))
            return
        }
        statusManager.updateStatus(.recording)
        audioRecorder.startRecording()
    }

    func hotkeyDidEndPress() {
        audioRecorder.stopRecording()
    }

    func hotkeyCancelled() {
        audioRecorder.cancelRecording()
        statusManager.updateStatus(.idle)
    }
}

// MARK: - AudioRecorderDelegate
extension AppDelegate: AudioRecorderDelegate {
    func recordingDidStart() {}

    func recordingDidFinish(fileURL: URL, duration: TimeInterval) {
        statusManager.updateStatus(.transcribing(queued: 0))
        transcriber.transcribe(fileURL: fileURL, recordingDuration: duration)
    }

    func recordingDidFail(error: String) {
        statusManager.updateStatus(.error(message: error))
    }

    func recordingDiscarded() {
        statusManager.updateStatus(.idle)
    }
}

// MARK: - TranscriberDelegate
extension AppDelegate: TranscriberDelegate {
    func transcriptionCompleted(text: String) {
        pasteEngine.paste(text: text)
        statusManager.updateStatus(.idle)
    }

    func transcriptionFailed(error: String) {
        statusManager.updateStatus(.error(message: error))
    }

    func transcriptionQueueUpdated(count: Int) {
        if count > 0 {
            statusManager.updateStatus(.transcribing(queued: count))
        }
    }
}

// MARK: - ModelManagerDelegate
extension AppDelegate: ModelManagerDelegate {
    func modelDownloadProgress(_ progress: Double) {
        statusManager.updateStatus(.downloading(progress: progress))
    }

    func modelDownloadCompleted() {
        if permissionManager.allPermissionsGranted {
            startListening()
            showReadyAlert()
        }
    }

    func modelDownloadFailed(error: String) {
        statusManager.updateStatus(.error(message: error))
    }
}
```

- [ ] **Step 2: Build the complete app**

Run: `swift build`
Expected: Compiles without errors.

- [ ] **Step 3: End-to-end manual test**

Run: `swift build && .build/debug/VoiceDictation`

Test sequence:
1. App appears in menu bar with mic icon
2. If first run: permission prompts appear, model downloads with progress in menu
3. Hold Globe key → icon turns red, tick sound plays
4. Speak a sentence
5. Release Globe key → icon shows transcribing, tick sound plays
6. After 1-2 seconds → transcribed text is pasted into frontmost text field
7. Verify clipboard is restored to previous content

Test error cases:
- Short press (<0.5s) → discarded, no transcription
- Escape while holding → cancelled
- Click menu bar icon → shows status, model info, quit

- [ ] **Step 4: Commit**

```bash
git add VoiceDictation/AppDelegate.swift
git commit -m "feat: wire all components together for full push-to-talk flow"
```

---

### Task 10: README and Final Polish

**Files:**
- Create: `README.md`
- Modify: any files with issues found during testing

- [ ] **Step 1: Create README**

Create `README.md`:

```markdown
# VoiceDictation

A macOS menu bar app for system-wide push-to-talk voice transcription. Hold the Globe key, speak, release — your words are transcribed and pasted into whatever app has focus.

Built for dictating prompts to Claude Code, but works anywhere.

## Requirements

- macOS 13+ (Ventura)
- whisper-cpp: `brew install whisper-cpp`

## Setup

1. Build and run:
   ```bash
   swift build
   .build/debug/VoiceDictation
   ```

2. Grant permissions when prompted:
   - **Accessibility** (System Settings > Privacy & Security > Accessibility)
   - **Microphone** (prompted automatically)

3. Set Globe key to "Do Nothing":
   - System Settings > Keyboard > "Press Globe key to" > "Do Nothing"

4. The app will download the Whisper base.en model (~150MB) on first launch.

## Usage

- **Hold Globe key** to record
- **Release** to transcribe and paste
- **Escape** while holding to cancel
- **Click menu bar icon** to see status

## How It Works

Records audio via AVAudioEngine, transcribes with whisper.cpp (locally, on-device), and pastes via clipboard simulation. No data leaves your machine.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with setup and usage instructions"
```

- [ ] **Step 3: Run all tests**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 4: Update PROJECTS.md**

Update `~/Dropbox/Coding Projects/Coding Environment Setup/PROJECTS.md` with a new section for VoiceDictation per the project template in CLAUDE.md.
