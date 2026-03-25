import Cocoa

public enum AppStatus {
    case idle
    case recording
    case transcribing(queued: Int)
    case error(message: String)
    case downloading(progress: Double)
    case permissionNeeded(String)
}

public protocol StatusManagerDelegate: AnyObject {
    func statusManagerDidRequestPreferences()
    func statusManagerDidRequestClearHistory()
}

public class StatusManager: NSObject {
    public weak var delegate: StatusManagerDelegate?

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private let modelMenuItem: NSMenuItem
    private let historyMenuItem: NSMenuItem
    private let historySubmenu: NSMenu
    private var errorClearTimer: Timer?

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        modelMenuItem = NSMenuItem(title: "Model: \(PreferencesManager.shared.selectedModel.id)", action: nil, keyEquivalent: "")
        historyMenuItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
        historySubmenu = NSMenu()
        historyMenuItem.submenu = historySubmenu

        super.init()

        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(historyMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(modelMenuItem)
        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(preferencesClicked(_:)), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceDictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        updateStatus(.idle)
    }

    @objc private func preferencesClicked(_ sender: Any) {
        delegate?.statusManagerDidRequestPreferences()
    }

    @objc private func clearHistoryClicked(_ sender: Any) {
        delegate?.statusManagerDidRequestClearHistory()
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func updateModelDisplay() {
        modelMenuItem.title = "Model: \(PreferencesManager.shared.selectedModel.id)"
    }

    public func updateHistory(_ entries: [TranscriptionEntry]) {
        historySubmenu.removeAllItems()

        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: "No transcriptions yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            historySubmenu.addItem(emptyItem)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short

            for entry in entries.prefix(10) {
                let timeAgo = formatter.localizedString(for: entry.timestamp, relativeTo: Date())
                let preview = entry.text.prefix(60) + (entry.text.count > 60 ? "..." : "")
                let item = NSMenuItem(title: "\(preview)  (\(timeAgo))", action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = entry.text
                historySubmenu.addItem(item)
            }

            historySubmenu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistoryClicked(_:)), keyEquivalent: "")
            clearItem.target = self
            historySubmenu.addItem(clearItem)
        }

        historyMenuItem.isHidden = !PreferencesManager.shared.historyEnabled
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
