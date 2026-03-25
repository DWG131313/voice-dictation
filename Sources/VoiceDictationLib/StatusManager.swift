import Cocoa

public enum AppStatus {
    case idle
    case recording
    case transcribing(queued: Int)
    case error(message: String)
    case downloading(progress: Double)
    case permissionNeeded(String)
}

public class StatusManager {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private let modelMenuItem: NSMenuItem
    private var errorClearTimer: Timer?

    public init() {
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

    public func updateStatus(_ status: AppStatus) {
        dispatchPrecondition(condition: .onQueue(.main))
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
