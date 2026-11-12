import Cocoa

public protocol StatusManagerDelegate: AnyObject {
    func statusManagerDidRequestPreferences()
    /// A model was chosen in the Model submenu.
    func statusManagerDidChooseModel(_ model: ModelDescriptor)
    /// The menu is opening; the models may have changed since they were listed.
    func statusManagerWillOpenMenu()
}

/// The menu bar item: an icon and a status line showing the pipeline's
/// `DictationState`, the Model submenu, recent transcriptions and settings.
public class StatusManager: NSObject {
    public weak var delegate: StatusManagerDelegate?

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let statusMenuItem: NSMenuItem
    private let modelMenuItem: NSMenuItem
    private let modelSubmenu: NSMenu
    private let historyMenuItem: NSMenuItem
    private let historySubmenu: NSMenu
    private let launchAtLoginMenuItem: NSMenuItem
    private let keepRecordingsMenuItem: NSMenuItem

    public override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        modelMenuItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelSubmenu = NSMenu()
        modelSubmenu.addItem(NSMenuItem(title: "Loading models…", action: nil, keyEquivalent: ""))
        modelMenuItem.submenu = modelSubmenu
        historyMenuItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
        historySubmenu = NSMenu()
        historyMenuItem.submenu = historySubmenu
        launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")

        keepRecordingsMenuItem = NSMenuItem(title: "Keep recordings for comparison", action: #selector(toggleKeepRecordings(_:)), keyEquivalent: "")

        super.init()

        menu.delegate = self
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(historyMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(modelMenuItem)
        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(preferencesClicked(_:)), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        // "Open at login" is only meaningful for an installed .app bundle.
        // From the dev build, disable the toggle and say why, so it can't
        // re-introduce the stale-login-item problem.
        if LoginItemManager.isRunningFromAppBundle() {
            launchAtLoginMenuItem.target = self
            launchAtLoginMenuItem.state = PreferencesManager.shared.launchAtLogin ? .on : .off
        } else {
            launchAtLoginMenuItem.title = "Launch at Login (install app to enable)"
            launchAtLoginMenuItem.action = nil
            launchAtLoginMenuItem.target = nil
        }
        menu.addItem(launchAtLoginMenuItem)

        keepRecordingsMenuItem.target = self
        keepRecordingsMenuItem.state = PreferencesManager.shared.keepComparisonRecordings ? .on : .off
        menu.addItem(keepRecordingsMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceDictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        updateStatus(.idle)
    }

    @objc private func preferencesClicked(_ sender: Any) {
        delegate?.statusManagerDidRequestPreferences()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newValue = !PreferencesManager.shared.launchAtLogin
        LoginItemManager.shared.setEnabled(newValue)
        PreferencesManager.shared.launchAtLogin = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleKeepRecordings(_ sender: NSMenuItem) {
        let newValue = !PreferencesManager.shared.keepComparisonRecordings
        PreferencesManager.shared.keepComparisonRecordings = newValue
        sender.state = newValue ? .on : .off
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func modelChosen(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? ModelDescriptor else { return }
        delegate?.statusManagerDidChooseModel(model)
    }

    // MARK: - Models

    /// Lists every model in the Model submenu, grouped by engine, with the
    /// one dictation uses checked. The old whisper-cli models sit under a
    /// "Previous engine" header.
    public func updateModels(_ models: [ModelDescriptor], selected: ModelID) {
        let selectedName = models.first { $0.id == selected }?.displayName ?? selected.storageKey
        modelMenuItem.title = "Model: \(selectedName)"
        modelSubmenu.removeAllItems()
        var engine: EngineKind?
        for model in models {
            if model.id.engine != engine {
                if engine != nil { modelSubmenu.addItem(NSMenuItem.separator()) }
                if model.id.engine == .whisperCLI { modelSubmenu.addItem(NSMenuItem.sectionHeader(title: "Previous engine")) }
                engine = model.id.engine
            }
            let entry = Self.menuEntry(for: model)
            let item = NSMenuItem(title: entry.title, action: entry.isEnabled ? #selector(modelChosen(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = model.id == selected ? .on : .off
            item.toolTip = model.detail
            modelSubmenu.addItem(item)
        }
    }

    /// How a model reads in the Model submenu, and whether choosing it does
    /// anything. A model that is not on the Mac offers its download, which
    /// then selects it.
    static func menuEntry(for model: ModelDescriptor) -> (title: String, isEnabled: Bool) {
        switch model.state {
        case .ready:
            return (model.displayName, true)
        case .notDownloaded:
            return ("Download \(model.displayName)", true)
        case .preparing:
            return ("\(model.displayName) — preparing", true)
        case .downloading(let progress):
            return ("\(model.displayName) — downloading \(Int(progress * 100))%", false)
        case .unavailable(let reason):
            return ("\(model.displayName) — \(reason)", false)
        }
    }

    // MARK: - History

    /// Lists the newest transcripts; choosing one copies its text. A failed
    /// dictation has no text, so it shows why it failed instead.
    public func updateHistory(_ transcripts: [Transcript]) {
        historySubmenu.removeAllItems()

        if transcripts.isEmpty {
            let emptyItem = NSMenuItem(title: "No transcriptions yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            historySubmenu.addItem(emptyItem)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short

            for transcript in transcripts.prefix(10) {
                let timeAgo = formatter.localizedString(for: transcript.date, relativeTo: Date())
                guard !transcript.text.isEmpty else {
                    let reason = transcript.failure ?? "no text"
                    let item = NSMenuItem(title: "Failed — \(reason)  (\(timeAgo))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    historySubmenu.addItem(item)
                    continue
                }
                let preview = transcript.text.prefix(60) + (transcript.text.count > 60 ? "..." : "")
                let item = NSMenuItem(title: "\(preview)  (\(timeAgo))", action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = transcript.text
                item.toolTip = transcript.text
                historySubmenu.addItem(item)
            }
        }

        historyMenuItem.isHidden = !PreferencesManager.shared.historyEnabled
    }

    // MARK: - Status

    /// An SF Symbol that doesn't exist on this macOS version yields nil, and
    /// a nil button image makes the menu bar icon vanish. Never let that
    /// happen: fall back to the plain mic.
    private func symbol(_ name: String, _ description: String) -> NSImage? {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
            return image
        }
        Log.info("[STATUS] SF Symbol '\(name)' unavailable — falling back to mic.fill")
        return NSImage(systemSymbolName: "mic.fill", accessibilityDescription: description)
    }

    /// Shows the pipeline's state. The pipeline itself returns from an error
    /// to the true state, so nothing here times out.
    public func updateStatus(_ state: DictationState) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let button = statusItem.button else { return }

        switch state {
        case .idle:
            button.image = symbol("mic.fill", "VoiceDictation — Ready")
            button.contentTintColor = nil
            statusMenuItem.title = "Status: Ready"

        case .recording:
            button.image = symbol("mic.fill", "VoiceDictation — Recording")
            button.contentTintColor = .systemRed
            statusMenuItem.title = "Status: Recording..."

        case .transcribing:
            button.image = symbol("waveform", "VoiceDictation — Transcribing")
            button.contentTintColor = nil
            statusMenuItem.title = "Status: Transcribing..."

        case .cleaning:
            button.image = symbol("waveform", "VoiceDictation — Cleaning up")
            button.contentTintColor = nil
            statusMenuItem.title = "Status: Cleaning up..."

        case .preparingModel(let name):
            button.image = symbol("arrow.down.circle", "VoiceDictation — Preparing a model")
            button.contentTintColor = nil
            statusMenuItem.title = "Status: Preparing \(name)..."

        case .error(let message):
            button.image = symbol("mic.slash.fill", "VoiceDictation — Error")
            button.contentTintColor = .systemOrange
            statusMenuItem.title = "Error: \(message)"

        case .needsPermission(let permission):
            button.image = symbol("exclamationmark.triangle.fill", "VoiceDictation — Permission Needed")
            button.contentTintColor = .systemYellow
            statusMenuItem.title = "Permission needed: \(permission)"
        }
    }
}

extension StatusManager: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        delegate?.statusManagerWillOpenMenu()
    }
}
