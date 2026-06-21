import Cocoa
import VoiceDictationLib

// Refuse to start if another instance already holds the lock. This is what
// stops multiple menu bar icons stacking up when macOS launches the app from
// more than one place at login (restored Terminal tab, login item, etc.).
let instanceGuard = SingleInstanceGuard()
guard instanceGuard.tryAcquire() else {
    FileHandle.standardError.write(
        Data("VoiceDictation is already running; exiting duplicate instance.\n".utf8)
    )
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
